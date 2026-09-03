#!/usr/bin/env python3
"""Add the configured dashboard host as an ATS exception to a built iOS app."""

from __future__ import annotations

import json
import plistlib
import sys
from pathlib import Path
from urllib.parse import urlsplit


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: configure_ios_dashboard_ats.py INFO_PLIST DASHBOARD_JSON",
              file=sys.stderr)
        return 2

    info_path = Path(sys.argv[1])
    config_path = Path(sys.argv[2])
    try:
        with info_path.open("rb") as source:
            info = plistlib.load(source)
    except (OSError, ValueError, plistlib.InvalidFileException) as exc:
        print(f"configure dashboard ATS: {exc}", file=sys.stderr)
        return 1

    ats = info.setdefault("NSAppTransportSecurity", {})
    if not config_path.is_file():
        ats.pop("NSExceptionDomains", None)
        with info_path.open("wb") as destination:
            plistlib.dump(info, destination, fmt=plistlib.FMT_BINARY)
        return 0

    try:
        config = json.loads(config_path.read_text(encoding="utf-8"))
        host = urlsplit(config.get("url", "")).hostname
    except (OSError, ValueError) as exc:
        print(f"configure dashboard ATS: {exc}", file=sys.stderr)
        return 1

    if not host:
        print("configure dashboard ATS: dashboard URL has no host", file=sys.stderr)
        return 1

    ats["NSExceptionDomains"] = {host: {
        "NSExceptionAllowsInsecureHTTPLoads": True,
        "NSIncludesSubdomains": False,
    }}
    with info_path.open("wb") as destination:
        plistlib.dump(info, destination, fmt=plistlib.FMT_BINARY)
    print(f"已配置服务器面板 ATS 主机: {host}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
