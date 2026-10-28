"""PIN-protected kiosk alarm acknowledgement API.

Deployment: copy custom_components/kiosk_alarm to /config/custom_components/kiosk_alarm.
Configuration is read from configuration.yaml and never exposed through an entity.
"""
from __future__ import annotations

import asyncio
import hashlib
import hmac
import logging
import re
from datetime import datetime, timedelta, timezone

from aiohttp import web
import voluptuous as vol

from homeassistant.components.http import HomeAssistantView
from homeassistant.core import HomeAssistant, ServiceCall
from homeassistant.helpers.storage import Store

DOMAIN = "kiosk_alarm"
_LOGGER = logging.getLogger(__name__)
_HASH = re.compile(r"^pbkdf2_sha256\$([0-9]{5,8})\$([0-9a-f]{32})\$([0-9a-f]{64})$")
CONFIG_SCHEMA = vol.Schema(
    {
        DOMAIN: vol.Schema(
            {
                vol.Required("pin_hash"): vol.Match(_HASH.pattern),
                vol.Optional("script_entity_id", default="script.alarmansage_quittieren"): vol.Match(
                    r"^script\.[a-z0-9_]+$"
                ),
            }
        )
    },
    extra=vol.ALLOW_EXTRA,
)


async def async_setup(hass: HomeAssistant, config: dict) -> bool:
    """Register the authenticated API view only if explicitly configured."""
    if DOMAIN not in config:
        return True

    settings = config[DOMAIN]
    view = KioskAlarmAcknowledgeView(
        hass, settings["pin_hash"], settings["script_entity_id"]
    )
    await view.async_initialize()
    hass.http.register_view(view)
    _LOGGER.info("Kiosk alarm PIN endpoint registered")
    return True


class KioskAlarmAcknowledgeView(HomeAssistantView):
    """Authenticate kiosk PIN before calling the existing acknowledgement script."""

    url = "/api/kiosk_alarm/acknowledge"
    name = "api:kiosk_alarm:acknowledge"
    requires_auth = True

    def __init__(self, hass: HomeAssistant, pin_hash: str, script_entity_id: str) -> None:
        self._hass = hass
        self._pin_hash = pin_hash
        self._script_entity_id = script_entity_id
        self._lock = asyncio.Lock()
        self._store = Store(hass, 1, "kiosk_alarm_pin_attempts")
        self._failed_attempts = 0
        self._blocked_until = None

    async def async_initialize(self) -> None:
        """Restore the lockout state across Home Assistant restarts."""
        saved = await self._store.async_load() or {}
        self._failed_attempts = max(0, min(int(saved.get("failed_attempts", 0)), 3))
        timestamp = saved.get("blocked_until")
        if isinstance(timestamp, str):
            try:
                parsed = datetime.fromisoformat(timestamp)
                if parsed.tzinfo is not None:
                    self._blocked_until = parsed.astimezone(timezone.utc)
            except ValueError:
                pass

    async def _save(self) -> None:
        await self._store.async_save(
            {
                "failed_attempts": self._failed_attempts,
                "blocked_until": (
                    self._blocked_until.isoformat() if self._blocked_until else None
                ),
            }
        )

    async def post(self, request: web.Request) -> web.Response:
        """Return success only after the server accepted the PIN."""
        try:
            if request.content_length is not None and request.content_length > 1024:
                return web.json_response({"ok": False}, status=400)
            body = await request.json()
        except (ValueError, web.HTTPException):
            return web.json_response({"ok": False}, status=400)

        if not isinstance(body, dict):
            return web.json_response({"ok": False}, status=400)
        pin = body.get("pin")
        if not isinstance(pin, str) or not re.fullmatch(r"[0-9]{6}", pin):
            return web.json_response({"ok": False}, status=400)

        async with self._lock:
            now = datetime.now(timezone.utc)
            if self._blocked_until is not None and now < self._blocked_until:
                return web.json_response({"ok": False}, status=429)

            if self._blocked_until is not None:
                self._blocked_until = None
                self._failed_attempts = 0

            match = _HASH.fullmatch(self._pin_hash)
            if match is None:
                return web.json_response({"ok": False}, status=503)
            rounds = int(match.group(1))
            salt = bytes.fromhex(match.group(2))
            expected = bytes.fromhex(match.group(3))
            actual = await self._hass.async_add_executor_job(
                hashlib.pbkdf2_hmac, "sha256", pin.encode("ascii"), salt, rounds
            )

            if not hmac.compare_digest(actual, expected):
                self._failed_attempts += 1
                if self._failed_attempts >= 3:
                    self._blocked_until = now + timedelta(minutes=5)
                    _LOGGER.warning(
                        "Kiosk alarm PIN locked after repeated failed attempts"
                    )
                else:
                    _LOGGER.warning("Kiosk alarm PIN rejected")
                await self._save()
                return web.json_response(
                    {"ok": False}, status=429 if self._blocked_until else 403
                )

            # Reset and persist the failure counter before invoking the existing script.
            self._failed_attempts = 0
            self._blocked_until = None
            await self._save()

            if not self._hass.states.get(self._script_entity_id):
                _LOGGER.error("Configured alarm acknowledgement script does not exist")
                return web.json_response({"ok": False}, status=503)

            try:
                await self._hass.services.async_call(
                    "script",
                    "turn_on",
                    {"entity_id": self._script_entity_id},
                    blocking=True,
                )
            except Exception:
                _LOGGER.exception("Alarm acknowledgement script could not be started")
                return web.json_response({"ok": False}, status=503)

        _LOGGER.info("Kiosk alarm acknowledged with verified PIN")
        return web.json_response({"ok": True})
