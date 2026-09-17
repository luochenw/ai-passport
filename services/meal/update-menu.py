#!/usr/bin/env python3
"""Submit one fixed-building weekly menu to the local companion service."""

from __future__ import annotations

import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from pathlib import Path


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("menu", type=Path, help="weekly menu JSON file")
    parser.add_argument(
        "--server",
        default="http://127.0.0.1:8788",
        help="local ByteDance Canteen service base URL",
    )
    args = parser.parse_args()

    try:
        payload = json.loads(args.menu.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        print(f"read menu: {exc}", file=sys.stderr)
        return 2

    want = os.environ.get("MEAL_BUILDING", "")
    if want and payload.get("building") != want:
        print(f"menu building must be {want}", file=sys.stderr)
        return 2

    data = json.dumps(payload, ensure_ascii=False).encode("utf-8")
    request = urllib.request.Request(
        args.server.rstrip("/") + "/v1/meals/update",
        data=data,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urllib.request.urlopen(request, timeout=15) as response:
            result = json.load(response)
    except (urllib.error.URLError, json.JSONDecodeError) as exc:
        print(f"update menu: {exc}", file=sys.stderr)
        return 1

    print(json.dumps(result, ensure_ascii=False))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
