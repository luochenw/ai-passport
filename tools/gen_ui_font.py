#!/usr/bin/env python3
"""Generate the 14 px Passport UI font from the GB2312 repertoire.

The device receives user and service supplied text, so a corpus-derived subset
eventually turns valid menu words into missing-glyph boxes.  GB2312 is a small,
stable floor for Simplified Chinese: 6,763 Han characters plus 682 symbols.

Run this after ESP-IDF has fetched the managed LVGL component::

    python3 tools/gen_ui_font.py

The generated C file is committed; building the firmware does not require npm.
"""

from __future__ import annotations

import argparse
import re
import subprocess
from pathlib import Path


ROOT = Path(__file__).resolve().parents[1]
FONT = ROOT / "managed_components/lvgl__lvgl/scripts/built_in_font/SourceHanSansSC-Normal.otf"
OUTPUT = ROOT / "main/ui_font_cn_14.c"
CONVERTER_VERSION = "1.5.3"

# Glyphs present in the previous UI font but outside GB2312.  These are useful
# layout/typographic marks and cost very little compared with the Han set.
EXTRA_PUNCTUATION = (
    "\u2002\u2003\u2010\u2011\u2012\u2013\u2014\u201a\u201e\u2020\u2021\u2022"
    "\u2025\u2027\u2035\u2039\u203a\u203c\u2042\u2047\u2048\u2049\u2051"
    "\u3004\u3012\u3018\u3019\u301a\u301b\u301c\u301d\u301e\u301f\u3020"
    # U+3031/U+3032 retain the established 27 px line metrics used by the
    # device layouts. Removing them silently changes line_height to 18.
    "\u3030\u3031\u3032\u3036\u3037\u303d\u303e\u303f\uff5f\uff60\uff61\uff62\uff63"
    "\uff64\uff65\uffe2\uffe4\uffe6\uffe8\uffe9\uffea\uffeb\uffec\uffed\uffee"
)


def gb2312_characters() -> str:
    """Return every assigned two-byte GB2312 character, in Unicode order."""
    characters: set[str] = set()
    for lead in range(0xA1, 0xF8):
        for trail in range(0xA1, 0xFF):
            try:
                characters.add(bytes((lead, trail)).decode("gb2312"))
            except UnicodeDecodeError:
                pass
    return "".join(sorted(characters, key=ord))


def font_symbols() -> str:
    return "".join(sorted(set(gb2312_characters() + EXTRA_PUNCTUATION), key=ord))


def generated_codepoints(path: Path = OUTPUT) -> set[int]:
    source = path.read_text(encoding="utf-8")
    return {int(value, 16) for value in re.findall(r"/\* U\+([0-9A-F]+) ", source)}


def verify_output(path: Path = OUTPUT) -> None:
    expected = set(range(0x20, 0x7F)) | {ord(ch) for ch in font_symbols()}
    actual = generated_codepoints(path)
    missing = sorted(expected - actual)
    if missing:
        preview = " ".join(f"U+{value:04X}" for value in missing[:12])
        raise SystemExit(f"generated font is missing {len(missing)} glyphs: {preview}")


def generate() -> None:
    if not FONT.is_file():
        raise SystemExit(
            f"source font not found: {FONT.relative_to(ROOT)}; "
            "fetch the ESP-IDF managed components first"
        )
    command = [
        "npx",
        "--yes",
        f"lv_font_conv@{CONVERTER_VERSION}",
        "--size",
        "14",
        "--bpp",
        "1",
        "--format",
        "lvgl",
        "--font",
        str(FONT.relative_to(ROOT)),
        "-r",
        "0x20-0x7E",
        "--symbols",
        font_symbols(),
        "--lv-include",
        "lvgl.h",
        "--lv-font-name",
        "lv_font_ui_cn_14",
        "-o",
        str(OUTPUT.relative_to(ROOT)),
    ]
    subprocess.run(command, cwd=ROOT, check=True)
    verify_output()
    print(
        f"generated {len(generated_codepoints())} glyphs -> "
        f"{OUTPUT.relative_to(ROOT)}"
    )


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument(
        "--check",
        action="store_true",
        help="check the committed font instead of regenerating it",
    )
    args = parser.parse_args()
    if args.check:
        verify_output()
        print(f"font coverage: PASS ({len(generated_codepoints())} glyphs)")
    else:
        generate()


if __name__ == "__main__":
    main()
