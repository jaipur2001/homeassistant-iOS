"""Fail-closed alarm acknowledgement for the Home Assistant iPad kiosk.

The existing alarm shutdown sequence remains in script.alarmansage_quittieren.
That script MUST start with the consume_grant guard installed by apply_guards.py.
Without this guard, Home Assistant's normal script service remains an unprotected
alternative, regardless of whether the PIN-protected HTTP endpoint is installed.
"""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import logging
import re
import secrets
from datetime import datetime, timedelta, timezone
from time import monotonic

from aiohttp import web
import voluptuous as vol

from homeassistant.components.http import KEY_HASS_USER, HomeAssistantView
from homeassistant.config_entries import SOURCE_IMPORT, ConfigEntry
from homeassistant.const import EVENT_STATE_CHANGED
from homeassistant.core import (
    Context,
    Event,
    HomeAssistant,
    ServiceCall,
    ServiceResponse,
    SupportsResponse,
    callback,
)
from homeassistant.helpers.storage import Store
from homeassistant.helpers.typing import ConfigType

DOMAIN = "kiosk_alarm"
_LOGGER = logging.getLogger(__name__)
_HASH = re.compile(r"^pbkdf2_sha256\$([0-9]{5,8})\$([0-9a-f]{32})\$([0-9a-f]{64})$")
_PIN_FORMAT = re.compile(r"^[0-9]{6}$")
_GRANT_FORMAT = re.compile(r"^[0-9a-f]{64}$")
_GRANT_LIFETIME_SECONDS = 10.0
_ATTEMPT_LIMIT = 3
_LOCKOUT_MINUTES = 5

CONFIG_SCHEMA = vol.Schema(
    {
        DOMAIN: vol.Schema(
            {
                vol.Required("pin_hash"): vol.Match(_HASH.pattern),
                vol.Optional(
                    "script_entity_id",
                    default="script.alarmansage_quittieren",
                ): vol.Match(r"^script\.[a-z0-9_]+$"),
                vol.Optional("trusted_user_ids", default=[]): [
                    vol.All(str, vol.Length(min=16, max=128))
                ],
                vol.Optional(
                    "mobile_action",
                    default="ALARM_QUITTIEREN",
                ): vol.All(str, vol.Length(min=1, max=128)),
                vol.Optional(
                    "dashboard_button_entity_id",
                    default="input_button.alarmansage_quittieren",
                ): vol.Match(r"^input_button\.[a-z0-9_]+$"),
            }
        )
    },
    extra=vol.ALLOW_EXTRA,
)


async def async_setup(hass: HomeAssistant, config: ConfigType) -> bool:
    """Register a fail-closed guard and migrate YAML into an admin-managed entry."""
    async def consume_grant(call: ServiceCall) -> ServiceResponse:
        controller = hass.data.get(DOMAIN)
        if controller is None:
            return {"allowed": False}
        return await controller.async_consume_grant(call)

    hass.services.async_register(
        DOMAIN,
        "consume_grant",
        consume_grant,
        schema=vol.Schema(
            {vol.Optional("grant", default=""): vol.All(str, vol.Length(max=128))}
        ),
        supports_response=SupportsResponse.ONLY,
    )
    hass.http.register_view(KioskAlarmAcknowledgeView(hass))

    if DOMAIN in config:
        # Never replace a prior admin-changed Config Entry with an older YAML hash.
        hass.async_create_task(
            hass.config_entries.flow.async_init(
                DOMAIN,
                context={"source": SOURCE_IMPORT},
                data=config[DOMAIN],
            )
        )
    return True


async def async_setup_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Start the protected alarm controller from a persisted config entry."""
    if DOMAIN in hass.data:
        _LOGGER.error("Refusing to start a second kiosk alarm controller")
        return False

    settings = {**entry.data, **entry.options}
    pin_hash = settings.get("pin_hash")
    if not isinstance(pin_hash, str) or _HASH.fullmatch(pin_hash) is None:
        _LOGGER.error("Kiosk alarm config entry has no valid PIN hash")
        return False

    controller = KioskAlarmController(
        hass,
        pin_hash=pin_hash,
        script_entity_id=settings.get(
            "script_entity_id", "script.alarmansage_quittieren"
        ),
        trusted_user_ids=set(settings.get("trusted_user_ids", [])),
        mobile_action=settings.get("mobile_action", "ALARM_QUITTIEREN"),
        dashboard_button_entity_id=settings.get(
            "dashboard_button_entity_id", "input_button.alarmansage_quittieren"
        ),
    )
    await controller.async_initialize()
    hass.data[DOMAIN] = controller

    @callback
    def on_mobile_action(event: Event) -> None:
        if event.data.get("action") == controller.mobile_action:
            controller.dispatch_trusted_event(event, "mobile_action")

    @callback
    def on_button_state(event: Event) -> None:
        if event.data.get("entity_id") != controller.dashboard_button_entity_id:
            return
        if event.data.get("new_state") is not None:
            controller.dispatch_trusted_event(event, "dashboard_button")

    entry.async_on_unload(
        hass.bus.async_listen("mobile_app_notification_action", on_mobile_action)
    )
    entry.async_on_unload(
        hass.bus.async_listen(EVENT_STATE_CHANGED, on_button_state)
    )
    entry.async_on_unload(entry.add_update_listener(_async_options_updated))
    _LOGGER.info(
        "Kiosk alarm protection loaded; %d trusted HA user IDs configured",
        len(controller.trusted_user_ids),
    )
    return True


async def _async_options_updated(hass: HomeAssistant, entry: ConfigEntry) -> None:
    """Activate changed PIN hashes without a Home Assistant restart."""
    controller = hass.data.get(DOMAIN)
    if controller is not None:
        pin_hash = entry.options.get("pin_hash", entry.data["pin_hash"])
        await controller.async_replace_pin_hash(pin_hash)


async def async_unload_entry(hass: HomeAssistant, entry: ConfigEntry) -> bool:
    """Refuse PIN acknowledgements if this entry is disabled or removed."""
    hass.data.pop(DOMAIN, None)
    return True

class KioskAlarmController:
    """Validate PINs or trusted event identities and issue one-use script grants."""

    def __init__(
        self,
        hass: HomeAssistant,
        pin_hash: str,
        script_entity_id: str,
        trusted_user_ids: set[str],
        mobile_action: str,
        dashboard_button_entity_id: str,
    ) -> None:
        self.hass = hass
        self._pin_hash = pin_hash
        self._script_entity_id = script_entity_id
        self.trusted_user_ids = trusted_user_ids
        self.mobile_action = mobile_action
        self.dashboard_button_entity_id = dashboard_button_entity_id
        self._pin_lock = asyncio.Lock()
        self._ack_lock = asyncio.Lock()
        self._grants: dict[str, float] = {}
        self._store = Store(hass, 1, "kiosk_alarm_pin_attempts")
        self._failed_attempts = 0
        self._blocked_until: datetime | None = None

    async def async_initialize(self) -> None:
        """Persist lockouts across HA restarts; never persist the PIN or grants."""
        saved = await self._store.async_load() or {}
        try:
            self._failed_attempts = max(
                0, min(int(saved.get("failed_attempts", 0)), _ATTEMPT_LIMIT)
            )
        except (TypeError, ValueError):
            self._failed_attempts = 0
        timestamp = saved.get("blocked_until")
        if isinstance(timestamp, str):
            try:
                parsed = datetime.fromisoformat(timestamp)
                if parsed.tzinfo is not None:
                    self._blocked_until = parsed.astimezone(timezone.utc)
            except ValueError:
                pass

    async def _async_save_lockout(self) -> None:
        await self._store.async_save(
            {
                "failed_attempts": self._failed_attempts,
                "blocked_until": (
                    self._blocked_until.isoformat() if self._blocked_until else None
                ),
            }
        )

    @property
    def alarm_active(self) -> bool:
        return self.hass.states.is_state("input_boolean.alarmansage_aktiv", "on")

    async def async_check_pin(self, pin: str) -> int:
        """Return 200, 403, or 429; validate exclusively on the server."""
        async with self._pin_lock:
            now = datetime.now(timezone.utc)
            if self._blocked_until is not None:
                if now < self._blocked_until:
                    return 429
                self._blocked_until = None
                self._failed_attempts = 0

            match = _HASH.fullmatch(self._pin_hash)
            if match is None:
                return 503

            actual = await self.hass.async_add_executor_job(
                hashlib.pbkdf2_hmac,
                "sha256",
                pin.encode("ascii"),
                bytes.fromhex(match.group(2)),
                int(match.group(1)),
            )
            expected = bytes.fromhex(match.group(3))
            if not hmac.compare_digest(actual, expected):
                self._failed_attempts += 1
                if self._failed_attempts >= _ATTEMPT_LIMIT:
                    self._blocked_until = now + timedelta(minutes=_LOCKOUT_MINUTES)
                    _LOGGER.warning("Kiosk alarm PIN locked after failed attempts")
                else:
                    _LOGGER.warning("Kiosk alarm PIN rejected")
                await self._async_save_lockout()
                return 429 if self._blocked_until else 403

            self._blocked_until = None
            self._failed_attempts = 0
            await self._async_save_lockout()
            return 200

    async def async_replace_pin_hash(self, pin_hash: str) -> None:
        """Apply a new admin-generated PIN hash and reset previous lockouts."""
        if _HASH.fullmatch(pin_hash) is None:
            raise ValueError("Invalid PIN hash")
        async with self._pin_lock:
            if self._pin_hash == pin_hash:
                return
            self._pin_hash = pin_hash
            self._failed_attempts = 0
            self._blocked_until = None
            await self._async_save_lockout()
            _LOGGER.warning("Kiosk alarm PIN changed via administrator settings")

    async def async_consume_grant(self, call: ServiceCall) -> ServiceResponse:
        """Only one-use, short-lived random grants authorize the script."""
        grant = call.data.get("grant", "")
        if _GRANT_FORMAT.fullmatch(grant) is None:
            return {"allowed": False}

        now = monotonic()
        deadline = self._grants.pop(grant, None)
        # Prune stale grants; this dictionary is never persisted or exposed.
        for key, expiry in list(self._grants.items()):
            if expiry < now:
                self._grants.pop(key, None)
        return {"allowed": deadline is not None and now < deadline}

    async def async_acknowledge(self, source: str, user_id: str | None) -> bool:
        """Run the unchanged shutdown sequence only with an internal one-use grant."""
        async with self._ack_lock:
            if not self.alarm_active:
                return False
            script_service = self._script_entity_id.partition(".")[2]
            if not self.hass.services.has_service("script", script_service):
                _LOGGER.error("Alarm acknowledgement script unavailable")
                return False

            grant = secrets.token_hex(32)
            self._grants[grant] = monotonic() + _GRANT_LIFETIME_SECONDS
            try:
                # Direct script.<name> waits until its entire sequence finishes.
                # Grant is consumed by the FIRST step, before any shutdown actions.
                await self.hass.services.async_call(
                    "script",
                    script_service,
                    {"kiosk_alarm_grant": grant},
                    blocking=True,
                )
            except Exception:
                _LOGGER.exception("Protected alarm acknowledgement script failed")
                return False
            finally:
                self._grants.pop(grant, None)

            # A successful service call is not proof of a successful acknowledgement.
            if self.alarm_active:
                _LOGGER.error("Alarm remains active after acknowledgement script")
                return False

            self.hass.bus.async_fire(
                "kiosk_alarm_acknowledged",
                {"source": source},
                context=Context(user_id=user_id) if user_id else Context(),
            )
            _LOGGER.warning("Alarm acknowledged through protected path: %s", source)
            return True

    @callback
    def dispatch_trusted_event(self, event: Event, source: str) -> None:
        """Reject arbitrary event fires; require the original HA user identity."""
        user_id = event.context.user_id
        if user_id is None or user_id not in self.trusted_user_ids:
            _LOGGER.warning("Unauthorized alarm acknowledgement event ignored")
            return
        if not self.alarm_active:
            return
        self.hass.async_create_task(self._async_trusted_acknowledge(source, user_id))

    async def _async_trusted_acknowledge(self, source: str, user_id: str) -> None:
        user = await self.hass.auth.async_get_user(user_id)
        if user is None:
            _LOGGER.warning("Alarm action ignored: trusted user no longer exists")
            return
        await self.async_acknowledge(source, user_id)


class KioskAlarmAcknowledgeView(HomeAssistantView):
    """PIN-only endpoint; HA session authentication alone never acknowledges."""

    url = "/api/kiosk_alarm/acknowledge"
    name = "api:kiosk_alarm:acknowledge"
    requires_auth = True

    def __init__(self, hass: HomeAssistant) -> None:
        self._hass = hass

    async def post(self, request: web.Request) -> web.Response:
        """Handle a bounded six-digit PIN request."""
        controller = self._hass.data.get(DOMAIN)
        if controller is None:
            return web.json_response({"ok": False}, status=503)
        user = request[KEY_HASS_USER]
        if request.content_length is not None and request.content_length > 128:
            return web.json_response({"ok": False}, status=400)
        try:
            raw = await request.read()
            if len(raw) > 128:
                return web.json_response({"ok": False}, status=400)
            body = await request.json()
        except (ValueError, web.HTTPException):
            return web.json_response({"ok": False}, status=400)

        if not isinstance(body, dict):
            return web.json_response({"ok": False}, status=400)
        pin = body.get("pin")
        if not isinstance(pin, str) or _PIN_FORMAT.fullmatch(pin) is None:
            return web.json_response({"ok": False}, status=400)
        if not controller.alarm_active:
            return web.json_response({"ok": False}, status=409)

        pin_status = await controller.async_check_pin(pin)
        if pin_status != 200:
            return web.json_response({"ok": False}, status=pin_status)
        ok = await controller.async_acknowledge("kiosk_pin", user.id)
        return web.json_response({"ok": ok}, status=200 if ok else 503)
