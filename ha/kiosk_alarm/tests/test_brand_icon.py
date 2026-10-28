"""Verify local Home Assistant brand PNGs without requiring image libraries."""
from __future__ import annotations

from pathlib import Path
import struct
import unittest
import zlib


BRAND = (
    Path(__file__).resolve().parents[1]
    / "custom_components"
    / "kiosk_alarm"
    / "brand"
)


class BrandIconTests(unittest.TestCase):
    """Validate source assets before they are copied into production."""

    def test_icons_are_real_transparent_pngs_with_expected_dimensions(self):
        for name, expected_size, expected_bit_depth in (
            ("icon.png", 256, 8),
            ("icon@2x.png", 512, 1),
        ):
            with self.subTest(name=name):
                png = (BRAND / name).read_bytes()
                self.assertTrue(png.startswith(b"\x89PNG\r\n\x1a\n"))
                offset = 8
                chunks = {}
                while offset < len(png):
                    size = struct.unpack(">I", png[offset:offset+4])[0]
                    tag = png[offset+4:offset+8]
                    payload = png[offset+8:offset+8+size]
                    stored_crc = struct.unpack(
                        ">I", png[offset+8+size:offset+12+size]
                    )[0]
                    self.assertEqual(
                        stored_crc, zlib.crc32(tag + payload) & 0xFFFFFFFF
                    )
                    chunks.setdefault(tag, []).append(payload)
                    offset += 12 + size
                    if tag == b"IEND":
                        break
                self.assertEqual(offset, len(png))
                width, height, bits, color_type, _, _, _ = struct.unpack(
                    ">IIBBBBB", chunks[b"IHDR"][0]
                )
                self.assertEqual((width, height), (expected_size, expected_size))
                self.assertEqual(bits, expected_bit_depth)
                self.assertEqual(color_type, 3)  # indexed color
                self.assertIn(b"PLTE", chunks)
                self.assertIn(b"tRNS", chunks)  # transparent background
                self.assertEqual(chunks[b"tRNS"][0][0], 0)
                raw = zlib.decompress(b"".join(chunks[b"IDAT"]))
                self.assertEqual(
                    len(raw),
                    expected_size * (1 + (expected_size * bits + 7) // 8),
                )

    def test_license_and_editable_source_are_included(self):
        self.assertIn("Pictogrammers", (BRAND / "LICENSE").read_text())
        self.assertIn("mdi:shield-lock", (BRAND / "NOTICE.md").read_text())
        source = (BRAND / "source.svg").read_text()
        self.assertIn('fill="#008C9B"', source)
        self.assertIn('viewBox="0 0 24 24"', source)


if __name__ == "__main__":
    unittest.main()
