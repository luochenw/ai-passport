#!/usr/bin/env python3
"""Host tests for generated companion firmware metadata."""

from __future__ import annotations

import hashlib
import importlib.util
import json
import tempfile
from pathlib import Path


ROOT = Path(__file__).resolve().parent.parent
SPEC = importlib.util.spec_from_file_location(
    "update_firmware_catalog", ROOT / "tools" / "update_firmware_catalog.py"
)
assert SPEC and SPEC.loader
MODULE = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(MODULE)


def main() -> None:
    with tempfile.TemporaryDirectory() as directory:
        root = Path(directory)
        firmware = root / "firmware.bin"
        catalog_path = root / "catalog.json"
        payload = bytearray(256)
        payload[MODULE.APP_DESC_OFFSET : MODULE.APP_DESC_OFFSET + 4] = \
            MODULE.APP_DESC_MAGIC.to_bytes(4, "little")
        version = b"0.1.0-dev+g1234567"
        payload[MODULE.APP_DESC_VERSION_OFFSET : MODULE.APP_DESC_VERSION_OFFSET + len(version)] = version
        payload = bytes(payload)
        firmware.write_bytes(payload)

        catalog = MODULE.build_catalog(firmware, "0.1.0-dev+g1234567")
        MODULE.write_catalog(catalog_path, catalog)
        decoded = json.loads(catalog_path.read_text(encoding="utf-8"))

        assert decoded[0]["version"] == "0.1.0-dev+g1234567"
        assert decoded[0]["size"] == len(payload)
        assert decoded[0]["sha256"] == hashlib.sha256(payload).hexdigest()
        assert decoded[0]["bin"] == "current-firmware.bin"
        assert MODULE.embedded_version(firmware) == "0.1.0-dev+g1234567"

    print("firmware catalog tests: PASS")


if __name__ == "__main__":
    main()
