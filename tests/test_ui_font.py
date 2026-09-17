#!/usr/bin/env python3
"""Focused coverage and Flash-budget checks for the generated UI font."""

from __future__ import annotations

import importlib.util
import re
import unittest
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FONT_SOURCE = ROOT / "main/ui_font_cn_14.c"
SPEC = importlib.util.spec_from_file_location("gen_ui_font", ROOT / "tools/gen_ui_font.py")
assert SPEC and SPEC.loader
GENERATOR = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(GENERATOR)

# Measured from the previous generated object on ESP32-C3.  The new broad
# coverage may add at most 200 KiB of read-only data and no proportional RAM.
PREVIOUS_FLASH_BYTES = 152_171
MAX_FLASH_BYTES = PREVIOUS_FLASH_BYTES + 200 * 1024


def array_body(source: str, declaration: str) -> str:
    match = re.search(declaration + r"\s*=\s*\{(.*?)\n\};", source, re.S)
    if not match:
        raise AssertionError(f"array not found: {declaration}")
    return match.group(1)


def estimated_flash_bytes(source: str) -> int:
    bitmap = array_body(source, r"glyph_bitmap\[\]")
    bitmap_bytes = len(re.findall(r"\b0x[0-9a-fA-F]+\b", bitmap))

    descriptors = array_body(source, r"glyph_dsc\[\]")
    descriptor_count = len(re.findall(r"\{\s*\.bitmap_index", descriptors))

    uint16_values = 0
    uint8_values = 0
    int8_values = 0
    for kind, _name, body in re.findall(
        r"static const (uint16_t|uint8_t|int8_t)\s+([A-Za-z0-9_]+)\[\]\s*=\s*\{(.*?)\n\};",
        source,
        re.S,
    ):
        values = len(re.findall(r"(?<![A-Za-z0-9_])-?(?:0x[0-9a-fA-F]+|\d+)", body))
        if kind == "uint16_t":
            uint16_values += values
        elif kind == "uint8_t":
            uint8_values += values
        else:
            int8_values += values

    cmaps = array_body(source, r"cmaps\[\]")
    cmap_count = len(re.findall(r"\{\s*\.range_start", cmaps))

    # ESP32-C3 sizes from LVGL 9's generated types: glyph descriptor 16,
    # cmap 24, font 36, font descriptor 24, kern descriptor/pairs 24 total.
    return (
        bitmap_bytes
        + descriptor_count * 16
        + uint16_values * 2
        + uint8_values
        + int8_values
        + cmap_count * 24
        + 36
        + 24
        + 24
    )


class UIFontCoverageTest(unittest.TestCase):
    @classmethod
    def setUpClass(cls) -> None:
        cls.source = FONT_SOURCE.read_text(encoding="utf-8")
        cls.codepoints = GENERATOR.generated_codepoints(FONT_SOURCE)

    def test_gb2312_repertoire_is_complete(self) -> None:
        repertoire = GENERATOR.gb2312_characters()
        self.assertEqual(len(repertoire), 7_445)
        self.assertEqual(sum("\u4e00" <= ch <= "\u9fff" for ch in repertoire), 6_763)
        self.assertTrue(set(map(ord, repertoire)).issubset(self.codepoints))

    def test_reported_menu_regressions_are_covered(self) -> None:
        for character in "鲍烩炖":
            with self.subTest(character=character):
                self.assertIn(ord(character), self.codepoints)

    def test_existing_punctuation_is_preserved(self) -> None:
        expected = set(map(ord, GENERATOR.EXTRA_PUNCTUATION))
        self.assertTrue(expected.issubset(self.codepoints))
        self.assertIn(ord("•"), self.codepoints)

    def test_existing_line_metrics_are_preserved(self) -> None:
        self.assertRegex(self.source, r"\.line_height = 27,")
        self.assertRegex(self.source, r"\.base_line = 8,")

    def test_flash_growth_stays_within_budget(self) -> None:
        estimate = estimated_flash_bytes(self.source)
        self.assertLessEqual(estimate, MAX_FLASH_BYTES)
        print(
            f"font Flash estimate: {estimate} bytes "
            f"(delta {estimate - PREVIOUS_FLASH_BYTES:+d})"
        )


if __name__ == "__main__":
    unittest.main()
