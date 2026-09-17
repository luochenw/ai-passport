#!/usr/bin/env python3
"""Write companion firmware metadata from the exact application image built."""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import tempfile
from pathlib import Path


APP_DESC_OFFSET = 0x20
APP_DESC_MAGIC = 0xABCD5432
APP_DESC_VERSION_OFFSET = APP_DESC_OFFSET + 16
APP_DESC_VERSION_SIZE = 32


def embedded_version(firmware: Path) -> str:
    """Read ESP-IDF's esp_app_desc_t.version from an app-only image."""
    payload = firmware.read_bytes()
    end = APP_DESC_VERSION_OFFSET + APP_DESC_VERSION_SIZE
    if len(payload) < end:
        raise ValueError("firmware is too short to contain esp_app_desc_t")
    magic = int.from_bytes(payload[APP_DESC_OFFSET : APP_DESC_OFFSET + 4], "little")
    if magic != APP_DESC_MAGIC:
        raise ValueError("firmware does not contain esp_app_desc_t at offset 0x20")
    raw = payload[APP_DESC_VERSION_OFFSET:end].split(b"\0", 1)[0]
    version = raw.decode("ascii", "strict")
    if not version:
        raise ValueError("firmware has an empty embedded version")
    return version


def build_catalog(firmware: Path, version: str) -> list[dict[str, object]]:
    """Return catalog metadata whose size and digest describe ``firmware``."""
    payload = firmware.read_bytes()
    return [
        {
            "name": "FoloToy AI Passport",
            "description": "App 内置的当前固件",
            "version": version,
            "size": len(payload),
            "sha256": hashlib.sha256(payload).hexdigest(),
            "bin": "current-firmware.bin",
        }
    ]


def write_catalog(catalog_path: Path, catalog: list[dict[str, object]]) -> None:
    """Atomically replace a catalog so an interrupted build cannot leave half JSON."""
    catalog_path.parent.mkdir(parents=True, exist_ok=True)
    rendered = json.dumps(catalog, ensure_ascii=False, indent=2) + "\n"
    with tempfile.NamedTemporaryFile(
        mode="w", encoding="utf-8", dir=catalog_path.parent, delete=False
    ) as handle:
        handle.write(rendered)
        temporary = Path(handle.name)
    os.replace(temporary, catalog_path)


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("--firmware", type=Path, required=True)
    parser.add_argument("--catalog", type=Path, required=True)
    parser.add_argument("--version")
    parser.add_argument("--check", action="store_true")
    args = parser.parse_args()

    if not args.firmware.is_file():
        parser.error(f"firmware does not exist: {args.firmware}")
    try:
        image_version = embedded_version(args.firmware)
    except (OSError, UnicodeDecodeError, ValueError) as error:
        parser.error(str(error))
    version = args.version or image_version
    if args.version is not None and args.version != image_version:
        parser.error(
            f"catalog version {args.version!r} does not match firmware version {image_version!r}"
        )
    if not version or len(version.encode("utf-8")) > 31:
        parser.error("version must contain 1-31 UTF-8 bytes")

    expected = build_catalog(args.firmware, version)
    if args.check:
        try:
            actual = json.loads(args.catalog.read_text(encoding="utf-8"))
        except (OSError, json.JSONDecodeError) as error:
            parser.error(f"cannot read catalog: {error}")
        if actual != expected:
            parser.error("catalog metadata does not match the bundled firmware")
        print(f"Firmware catalog: PASS ({version})")
        return 0

    write_catalog(args.catalog, expected)
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
