"""Administrator-only PIN management via Home Assistant configuration flows.

HA enforces admin permissions on config-entry option flow APIs. Kiosks cannot
configure or change the PIN through an ordinary service or REST route.
"""
from __future__ import annotations

import hashlib
import os

import voluptuous as vol

from homeassistant import config_entries
from homeassistant.core import callback
from homeassistant.helpers.selector import (
    TextSelector,
    TextSelectorConfig,
    TextSelectorType,
)

from . import DOMAIN

HASH_ITERATIONS = 600_000


def valid_pin(pin: object) -> bool:
    """Accept exactly six ASCII digits, including leading zeros."""
    return isinstance(pin, str) and len(pin) == 6 and pin.isascii() and pin.isdecimal()


def generate_pin_hash(pin: str) -> str:
    """Use only from an executor. Never store or log the raw PIN."""
    if not valid_pin(pin):
        raise ValueError("PIN must consist of six ASCII digits")
    salt = os.urandom(16)
    hashed = hashlib.pbkdf2_hmac("sha256", pin.encode("ascii"), salt, HASH_ITERATIONS)
    return "pbkdf2_sha256$" + str(HASH_ITERATIONS) + "$" + salt.hex() + "$" + hashed.hex()


def pin_form_schema() -> vol.Schema:
    """Require two masked fields without pre-filling the previous PIN."""
    return vol.Schema(
        {
            vol.Required("pin"): TextSelector(
                TextSelectorConfig(type=TextSelectorType.PASSWORD)
            ),
            vol.Required("pin_confirm"): TextSelector(
                TextSelectorConfig(type=TextSelectorType.PASSWORD)
            ),
        }
    )


def pin_errors(data: dict) -> dict[str, str]:
    """Validate without echoing either input."""
    if not valid_pin(data.get("pin")) or not valid_pin(data.get("pin_confirm")):
        return {"base": "invalid_pin"}
    if data["pin"] != data["pin_confirm"]:
        return {"base": "pin_mismatch"}
    return {}


class KioskAlarmConfigFlow(config_entries.ConfigFlow, domain=DOMAIN):
    """Create one controller through HA UI or import legacy YAML once."""

    VERSION = 1

    async def async_step_import(self, import_data: dict) -> config_entries.ConfigFlowResult:
        """Preserve existing YAML settings without replacing admin-changed options."""
        await self.async_set_unique_id("primary")
        self._abort_if_unique_id_configured()
        return self.async_create_entry(title="Kiosk Alarm PIN", data=dict(import_data))

    async def async_step_user(
        self, user_input: dict | None = None
    ) -> config_entries.ConfigFlowResult:
        """Initialize from HA's admin-only configuration UI."""
        await self.async_set_unique_id("primary")
        self._abort_if_unique_id_configured()
        errors = {}
        if user_input is not None:
            errors = pin_errors(user_input)
            if not errors:
                hashed = await self.hass.async_add_executor_job(
                    generate_pin_hash, user_input["pin"]
                )
                return self.async_create_entry(
                    title="Kiosk Alarm PIN",
                    data={
                        "pin_hash": hashed,
                        "script_entity_id": "script.alarmansage_quittieren",
                        "trusted_user_ids": [],
                        "mobile_action": "ALARM_QUITTIEREN",
                        "dashboard_button_entity_id": "input_button.alarmansage_quittieren",
                    },
                )
        return self.async_show_form(
            step_id="user", data_schema=pin_form_schema(), errors=errors
        )

    @staticmethod
    @callback
    def async_get_options_flow(config_entry: config_entries.ConfigEntry) -> KioskAlarmOptionsFlow:
        """Home Assistant restricts the corresponding options APIs to admins."""
        return KioskAlarmOptionsFlow()


class KioskAlarmOptionsFlow(config_entries.OptionsFlow):
    """Rotate the PIN and keep other configuration options unchanged."""

    async def async_step_init(
        self, user_input: dict | None = None
    ) -> config_entries.ConfigFlowResult:
        errors = {}
        if user_input is not None:
            errors = pin_errors(user_input)
            if not errors:
                hashed = await self.hass.async_add_executor_job(
                    generate_pin_hash, user_input["pin"]
                )
                return self.async_create_entry(
                    title="",
                    data={**self.config_entry.options, "pin_hash": hashed},
                )
        return self.async_show_form(
            step_id="init", data_schema=pin_form_schema(), errors=errors
        )
