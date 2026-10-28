"""Unit tests for zero-reformat, fail-closed migration of live YAML."""
from __future__ import annotations

import importlib.util
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

import yaml

ROOT = Path(__file__).resolve().parents[1]
SPEC = importlib.util.spec_from_file_location("apply_guards", ROOT / "apply_guards.py")
assert SPEC and SPEC.loader
module = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(module)

SCRIPTS = """\
priorisierte_alarmwiedergabe:
  alias: Alarm Controller
  sequence:
  - alias: Alarmauflage
    parallel:
    - sequence:
      - alias: Browser popup
        action: browser_mod.popup
        data:
          tag: alarmansage
          title: Alarm
          right_button: QUITTIEREN
          right_button_variant: danger
          right_button_appearance: filled
          right_button_close: false
          right_button_action:
            action: script.alarmansage_quittieren
    - sequence:
      - repeat:
          for_each: []
          sequence:
          - action: notify.mobile_app_ipad01
            data:
              message: alert
              data:
                actions:
                - action: ALARM_QUITTIEREN
                  title: QUITTIEREN
                  authenticationRequired: true
                  destructive: true
alarmansage_quittieren:
  alias: Alarmansage quittieren
  mode: restart
  variables:
    alarm_echo_players: []
  sequence:
  - alias: Stop Echo
    action: media_player.media_stop
    target:
      entity_id: media_player.demo
  - alias: Reset active flag
    action: input_boolean.turn_off
    target:
      entity_id: input_boolean.alarmansage_aktiv
other_script:
  alias: Unrelated
  sequence:
  - delay: 1
"""

# This is deliberately a *text* fixture with the exact old browser_mod push
# snippets. Migration must preserve unrelated config without parsing/reserializing.
AUTOMATIONS = """\
- id: '1787816100270'
  alias: Alarmansage – Quittierung über Dashboard
  triggers:
  - trigger: state
    entity_id: input_button.alarmansage_quittieren
  actions:
  - action: script.turn_on
    target:
      entity_id: script.alarmansage_quittieren
- id: '24680'
  alias: Unrelated lighting
  triggers:
  - trigger: time
    at: '20:00:00'
  actions:
  - action: light.turn_on
    target:
      entity_id: light.test
- id: '1789632695059'
  alias: Alarm - Mobile Quittierung
  triggers:
  - trigger: event
    event_type: mobile_app_notification_action
  actions:
  - action: script.alarmansage_quittieren
- id: '1789633560127'
  alias: Alarm - Push Quittierung
  triggers:
  - trigger: event
    event_type: mobile_app_notification_action
  actions:
  - action: script.alarmansage_quittieren
"""


class MigrationTests(unittest.TestCase):
    def test_guard_first_and_original_actions_retained(self) -> None:
        output, notes = module.patch_scripts(SCRIPTS)
        parsed = yaml.safe_load(output)
        script = parsed["alarmansage_quittieren"]
        first, second, third = script["sequence"][:3]
        self.assertEqual(first["action"], "kiosk_alarm.consume_grant")
        self.assertEqual(first["response_variable"], "kiosk_alarm_authorization")
        self.assertEqual(second["condition"], "template")
        self.assertIn("authorization.allowed", second["value_template"])
        self.assertEqual(third["action"], "media_player.media_stop")
        self.assertEqual(script["sequence"][-1]["action"], "input_boolean.turn_off")
        self.assertEqual(parsed["other_script"]["sequence"], [{"delay": 1}])
        self.assertNotIn("right_button_action:", output)
        self.assertNotIn("destructive: true", output)
        self.assertTrue(any("PIN-Guard" in note for note in notes))

    def test_script_migration_is_idempotent(self) -> None:
        first, _ = module.patch_scripts(SCRIPTS)
        second, _ = module.patch_scripts(first)
        self.assertEqual(first, second)

    def test_bad_existing_guard_fails_closed(self) -> None:
        damaged = SCRIPTS.replace(
            "  sequence:\n  - alias: Stop Echo",
            "  sequence:\n  - alias: Wrong step\n    action: kiosk_alarm.consume_grant\n"
            "  - alias: Stop Echo",
        )
        with self.assertRaisesRegex(ValueError, "unvollständig"):
            module.patch_scripts(damaged)

    def test_missing_target_script_refused(self) -> None:
        with self.assertRaisesRegex(ValueError, "Genau ein Skript"):
            module.patch_scripts("other_script:\n  sequence:\n  - delay: 1\n")

    def test_remove_only_known_direct_automation_handlers(self) -> None:
        output, notes = module.patch_automations(AUTOMATIONS)
        parsed = yaml.safe_load(output)
        self.assertEqual(len(parsed), 1)
        self.assertEqual(parsed[0]["id"], "24680")
        self.assertEqual(len([note for note in notes if "entfernt" in note]), 3)

    def test_unexpected_automation_change_refused(self) -> None:
        changed = AUTOMATIONS.replace(
            "entity_id: script.alarmansage_quittieren",
            "entity_id: script.other",
        )
        with self.assertRaisesRegex(ValueError, "verändert"):
            module.patch_automations(changed)

    def test_dry_run_and_backup(self) -> None:
        with tempfile.TemporaryDirectory() as directory:
            config = Path(directory)
            (config / "scripts.yaml").write_text(SCRIPTS, encoding="utf-8")
            (config / "automations.yaml").write_text(AUTOMATIONS, encoding="utf-8")
            run = lambda *args: subprocess.run(
                [sys.executable, str(ROOT / "apply_guards.py"),
                 "--config", str(config), *args],
                text=True, capture_output=True, check=True
            )
            self.assertIn("DRY RUN", run().stdout)
            self.assertEqual((config / "scripts.yaml").read_text(encoding="utf-8"), SCRIPTS)
            self.assertIn("Migration geschrieben", run("--apply").stdout)
            self.assertIn(
                "kiosk_alarm.consume_grant",
                (config / "scripts.yaml").read_text(encoding="utf-8"),
            )
            self.assertEqual(
                len(list(config.glob("scripts.yaml.pre-kiosk80-*.bak"))), 1
            )
            self.assertEqual(
                len(list(config.glob("automations.yaml.pre-kiosk80-*.bak"))), 1
            )
            self.assertIn("Dateien mit Änderungen: 0", run().stdout)


if __name__ == "__main__":
    unittest.main()
