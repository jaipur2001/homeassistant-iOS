"""Check service documentation to prevent a noisy HA startup log regression."""
from __future__ import annotations

import json
from pathlib import Path
import unittest

import yaml


COMPONENT = (
    Path(__file__).resolve().parents[1]
    / "custom_components"
    / "kiosk_alarm"
)


class ServiceMetadataTests(unittest.TestCase):
    """HA must find metadata for every registered integration service."""

    def test_internal_grant_service_is_documented(self):
        with (COMPONENT / "services.yaml").open(encoding="utf-8") as file:
            definitions = yaml.safe_load(file)
        self.assertIsInstance(definitions, dict)
        self.assertEqual(set(definitions), {"consume_grant"})
        grant = definitions["consume_grant"]["fields"]["grant"]
        self.assertFalse(grant["required"])
        self.assertEqual(grant["selector"]["text"]["type"], "password")

    def test_translations_exist_without_pin_reset_service(self):
        for filename in ("strings.json", "translations/de.json"):
            with self.subTest(filename=filename):
                with (COMPONENT / filename).open(encoding="utf-8") as file:
                    messages = json.load(file)
                service = messages["services"]["consume_grant"]
                self.assertTrue(service["name"])
                self.assertTrue(service["description"])
                self.assertTrue(service["fields"]["grant"]["name"])
                self.assertEqual(set(messages["services"]), {"consume_grant"})


if __name__ == "__main__":
    unittest.main()
