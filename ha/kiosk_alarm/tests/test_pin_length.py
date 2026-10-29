"""Regression tests for strict six-digit administrator PIN validation.

Import only pure functions via AST to avoid installing a complete HA runtime.
This tests the actual functions from config_flow.py, not a duplicated validator.
"""
from __future__ import annotations

import ast
import hashlib
from pathlib import Path
import re
import unittest


CONFIG_FLOW = (
    Path(__file__).resolve().parents[1]
    / "custom_components" / "kiosk_alarm" / "config_flow.py"
)


def load_pin_helpers() -> dict:
    source = CONFIG_FLOW.read_text(encoding="utf-8")
    syntax = ast.parse(source, filename=str(CONFIG_FLOW))
    names = {"valid_pin", "pin_errors", "generate_pin_hash"}
    selected = [
        node for node in syntax.body
        if isinstance(node, ast.FunctionDef) and node.name in names
    ]
    if {node.name for node in selected} != names:
        raise AssertionError("PIN validation / hashing functions missing")
    namespace = {
        "hashlib": hashlib,
        "os": __import__("os"),
        "HASH_ITERATIONS": 600_000,
    }
    exec(
        compile(ast.Module(body=selected, type_ignores=[]),
                filename=str(CONFIG_FLOW), mode="exec"),
        namespace,
    )
    return namespace


class SixDigitPINTests(unittest.TestCase):
    @classmethod
    def setUpClass(cls):
        cls.helpers = load_pin_helpers()

    def test_only_exactly_six_ascii_digits_are_allowed(self):
        valid = self.helpers["valid_pin"]
        for pin in ("000000", "012345", "123456", "999999"):
            with self.subTest(valid=pin):
                self.assertTrue(valid(pin))
        for pin in (
            "", "0", "12345", "1234567", "12345678",
            "12345a", " 123456", "123456 ", "12 456",
            "１２３４５６", "١٢٣٤٥٦", "12345\n", None, 123456,
        ):
            with self.subTest(rejected=repr(pin)):
                self.assertFalse(valid(pin))

    def test_both_admin_fields_must_have_exactly_six_digits(self):
        errors = self.helpers["pin_errors"]
        self.assertEqual(errors({"pin": "012345", "pin_confirm": "012345"}), {})
        self.assertEqual(
            errors({"pin": "012345", "pin_confirm": "543210"}),
            {"base": "pin_mismatch"},
        )
        for entry in (
            {"pin": "1234567", "pin_confirm": "1234567"},
            {"pin": "12345", "pin_confirm": "12345"},
            {"pin": "123456", "pin_confirm": "1234567"},
            {"pin": "a23456", "pin_confirm": "a23456"},
            {"pin": 123456, "pin_confirm": 123456},
            {"pin": "123456"},
            {},
        ):
            with self.subTest(rejected=entry):
                self.assertEqual(errors(entry), {"base": "invalid_pin"})

    def test_six_digit_pin_is_hashed_with_salt_not_stored_as_plaintext(self):
        generate_hash = self.helpers["generate_pin_hash"]
        pin = "012345"
        encoded = generate_hash(pin)
        match = re.fullmatch(
            r"pbkdf2_sha256\$(\d+)\$([0-9a-f]{32})\$([0-9a-f]{64})",
            encoded,
        )
        self.assertIsNotNone(match)
        assert match is not None
        rounds = int(match.group(1))
        self.assertEqual(rounds, 600_000)
        recomputed = hashlib.pbkdf2_hmac(
            "sha256", pin.encode("ascii"), bytes.fromhex(match.group(2)),
            rounds,
        )
        self.assertEqual(recomputed.hex(), match.group(3))
        self.assertNotIn(pin, encoded)

    def test_hash_generator_fails_closed_for_invalid_pin(self):
        generate_hash = self.helpers["generate_pin_hash"]
        for pin in ("12345", "1234567", "abcdef", "１２３４５６"):
            with self.subTest(rejected=pin):
                with self.assertRaises(ValueError):
                    generate_hash(pin)


if __name__ == "__main__":
    unittest.main()
