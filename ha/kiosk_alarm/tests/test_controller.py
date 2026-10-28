"""In-memory tests for PIN lockout, one-use grants, trusted events and REST."""
import asyncio
import hashlib
import importlib.util
import json
from pathlib import Path
import secrets
import sys
import types
import unittest
from types import SimpleNamespace


def fake_module(name):
    result = types.ModuleType(name)
    sys.modules[name] = result
    return result


fake_module("homeassistant")
fake_module("homeassistant.components")
http = fake_module("homeassistant.components.http")
http.KEY_HASS_USER = "hass_user"
http.HomeAssistantView = object
const = fake_module("homeassistant.const")
const.EVENT_STATE_CHANGED = "state_changed"
core = fake_module("homeassistant.core")
core.HomeAssistant = object
core.ServiceCall = object
core.ServiceResponse = dict
core.SupportsResponse = SimpleNamespace(ONLY=1)
core.callback = lambda fn: fn


class Context:
    def __init__(self, user_id=None):
        self.user_id = user_id


core.Context = Context
core.Event = object
fake_module("homeassistant.helpers")
storage = fake_module("homeassistant.helpers.storage")


class Store:
    def __init__(self, hass, version, key):
        self.hass, self.key = hass, key

    async def async_load(self):
        return self.hass.storage.get(self.key)

    async def async_save(self, data):
        self.hass.storage[self.key] = dict(data)


storage.Store = Store
fake_module("homeassistant.helpers.typing").ConfigType = dict
source = Path(__file__).resolve().parents[1] / "custom_components/kiosk_alarm/__init__.py"
spec = importlib.util.spec_from_file_location("kiosk_alarm_under_test", source)
assert spec and spec.loader
alarm = importlib.util.module_from_spec(spec)
spec.loader.exec_module(alarm)

TRUSTED = "a" * 32
KIOSK = "b" * 32


def pin_hash(pin):
    salt = secrets.token_bytes(16)
    result = hashlib.pbkdf2_hmac("sha256", pin.encode(), salt, 10000)
    return "pbkdf2_sha256$10000$" + salt.hex() + "$" + result.hex()


class FakeHass:
    def __init__(self):
        self.storage = {}
        self.active = True
        self.states = SimpleNamespace(
            is_state=lambda entity, state: self.active and
            entity == "input_boolean.alarmansage_aktiv" and state == "on"
        )
        self.calls = 0
        self.guard_enabled = True
        self.events = []
        self.bus = SimpleNamespace(async_fire=lambda *args, **kw:
                                   self.events.append((args, kw)))
        self.services = SimpleNamespace(
            has_service=lambda domain, name: domain == "script" and
            name == "alarmansage_quittieren", async_call=self.async_call
        )
        self.auth = SimpleNamespace(async_get_user=self.get_user)
        self.tasks = []

    async def get_user(self, user_id):
        return SimpleNamespace(id=user_id) if user_id == TRUSTED else None

    async def async_add_executor_job(self, fn, *args):
        return fn(*args)

    def async_create_task(self, coro):
        task = asyncio.create_task(coro)
        self.tasks.append(task)
        return task

    async def async_call(self, domain, service, data, blocking=True):
        self.calls += 1
        if self.guard_enabled:
            answer = await self.controller.async_consume_grant(
                SimpleNamespace(data={"grant": data.get("kiosk_alarm_grant", "")})
            )
            if answer["allowed"]:
                self.active = False


class FakeRequest:
    def __init__(self, body):
        self.content = json.dumps(body).encode()
        self.content_length = len(self.content)

    def __getitem__(self, key):
        return SimpleNamespace(id=KIOSK)

    async def read(self):
        return self.content

    async def json(self):
        return json.loads(self.content)


class ControllerTests(unittest.IsolatedAsyncioTestCase):
    async def asyncSetUp(self):
        self.hass = FakeHass()
        self.controller = alarm.KioskAlarmController(
            self.hass, pin_hash("246802"), "script.alarmansage_quittieren",
            {TRUSTED}, "ALARM_QUITTIEREN", "input_button.alarmansage_quittieren"
        )
        self.hass.controller = self.controller
        await self.controller.async_initialize()

    async def test_wrong_pin_three_attempt_lockout_persists(self):
        self.assertEqual(await self.controller.async_check_pin("111111"), 403)
        self.assertEqual(await self.controller.async_check_pin("222222"), 403)
        self.assertEqual(await self.controller.async_check_pin("333333"), 429)
        self.assertEqual(await self.controller.async_check_pin("246802"), 429)
        self.assertEqual(
            self.hass.storage["kiosk_alarm_pin_attempts"]["failed_attempts"], 3
        )
        other = alarm.KioskAlarmController(
            self.hass, pin_hash("246802"), "script.alarmansage_quittieren",
            set(), "ALARM_QUITTIEREN", "input_button.alarmansage_quittieren"
        )
        await other.async_initialize()
        self.assertEqual(await other.async_check_pin("246802"), 429)

    async def test_correct_pin_resets_counter(self):
        self.assertEqual(await self.controller.async_check_pin("111111"), 403)
        self.assertEqual(await self.controller.async_check_pin("246802"), 200)
        self.assertEqual(
            self.hass.storage["kiosk_alarm_pin_attempts"]["failed_attempts"], 0
        )

    async def test_grant_single_use_and_expiry(self):
        token = secrets.token_hex(32)
        self.controller._grants[token] = alarm.monotonic() + 10
        call = SimpleNamespace(data={"grant": token})
        self.assertTrue((await self.controller.async_consume_grant(call))["allowed"])
        self.assertFalse((await self.controller.async_consume_grant(call))["allowed"])
        expired = secrets.token_hex(32)
        self.controller._grants[expired] = alarm.monotonic() - 1
        self.assertFalse((await self.controller.async_consume_grant(
            SimpleNamespace(data={"grant": expired})
        ))["allowed"])

    async def test_protected_script_returns_success_only_after_reset(self):
        self.assertTrue(await self.controller.async_acknowledge("kiosk_pin", KIOSK))
        self.assertFalse(self.hass.active)
        self.assertEqual(self.hass.calls, 1)
        self.assertEqual(len(self.hass.events), 1)

    async def test_guard_failure_is_not_success(self):
        self.hass.guard_enabled = False
        self.assertFalse(await self.controller.async_acknowledge("kiosk_pin", KIOSK))
        self.assertTrue(self.hass.active)
        self.assertEqual(len(self.hass.events), 0)

    async def test_untrusted_mobile_event_rejected(self):
        fake_event = SimpleNamespace(context=Context(KIOSK))
        self.controller.dispatch_trusted_event(fake_event, "mobile_action")
        self.assertEqual(self.hass.calls, 0)

    async def test_trusted_mobile_event_accepted(self):
        fake_event = SimpleNamespace(context=Context(TRUSTED))
        self.controller.dispatch_trusted_event(fake_event, "mobile_action")
        await asyncio.gather(*self.hass.tasks)
        self.assertFalse(self.hass.active)
        self.assertEqual(self.hass.calls, 1)

    async def test_http_wrong_correct_and_inactive(self):
        view = alarm.KioskAlarmAcknowledgeView(self.controller)
        self.assertEqual((await view.post(FakeRequest({"pin": "junk"}))).status, 400)
        self.assertEqual((await view.post(FakeRequest({"pin": "123456"}))).status, 403)
        result = await view.post(FakeRequest({"pin": "246802"}))
        self.assertEqual(result.status, 200)
        self.assertEqual(json.loads(result.text), {"ok": True})
        self.assertEqual((await view.post(FakeRequest({"pin": "246802"}))).status, 409)


if __name__ == "__main__":
    unittest.main()
