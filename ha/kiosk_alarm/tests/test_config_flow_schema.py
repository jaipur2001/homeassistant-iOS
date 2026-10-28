"""Regression test: HA PIN forms must not depend on unsupported vol.Secret."""
from __future__ import annotations

import ast
from pathlib import Path
import unittest

import voluptuous as vol


CONFIG_FLOW = (
    Path(__file__).resolve().parents[1]
    / "custom_components"
    / "kiosk_alarm"
    / "config_flow.py"
)


class FakeTextSelectorConfig:
    """Sufficient public selector behavior for schema construction tests."""

    def __init__(self, *, type: str) -> None:
        self.type = type


class FakeTextSelector:
    def __init__(self, config: FakeTextSelectorConfig) -> None:
        self.config = config

    def __call__(self, value: object) -> str:
        if not isinstance(value, str):
            raise vol.Invalid("Expected text")
        return value


class PINFormSchemaTests(unittest.TestCase):
    def test_form_uses_supported_required_markers_and_masked_selectors(self):
        source = CONFIG_FLOW.read_text(encoding="utf-8")
        self.assertNotIn("vol.Secret(", source)

        syntax = ast.parse(source, filename=str(CONFIG_FLOW))
        forms = [
            node
            for node in syntax.body
            if isinstance(node, ast.FunctionDef) and node.name == "pin_form_schema"
        ]
        self.assertEqual(len(forms), 1)
        namespace = {
            "vol": vol,
            "TextSelector": FakeTextSelector,
            "TextSelectorConfig": FakeTextSelectorConfig,
            "TextSelectorType": type("TextSelectorType", (), {"PASSWORD": "password"}),
        }
        exec(
            compile(
                ast.Module(body=forms, type_ignores=[]),
                filename=str(CONFIG_FLOW),
                mode="exec",
            ),
            namespace,
        )
        schema = namespace["pin_form_schema"]()
        self.assertEqual(
            schema({"pin": "012345", "pin_confirm": "012345"}),
            {"pin": "012345", "pin_confirm": "012345"},
        )
        fields = {key.schema: selector for key, selector in schema.schema.items()}
        self.assertEqual(set(fields), {"pin", "pin_confirm"})
        self.assertTrue(
            all(selector.config.type == "password" for selector in fields.values())
        )
        with self.assertRaises(vol.MultipleInvalid):
            schema({"pin": "012345"})


if __name__ == "__main__":
    unittest.main()
