#!/usr/bin/env python3
"""Build bundle-safe app config files from the user's local configuration.

Only the public server address and a non-secret authentication-required flag
are copied. Shared tokens stay in Keychain and must never become part of an
application bundle.
"""

from __future__ import annotations

import argparse
import json
from pathlib import Path
import sys
from typing import Dict, Optional


APP_IDS = ("meal", "walkie")


def source_for(app_id: str, home: Path) -> Optional[Path]:
    candidates = (
        home / ".folotoy" / "apps" / f"{app_id}.json",
        home / ".folotoy" / f"{app_id}.json",
    )
    return next((path for path in candidates if path.is_file()), None)


def safe_server_config(source: Path) -> Dict[str, object]:
    value = json.loads(source.read_text(encoding="utf-8"))
    if not isinstance(value, dict):
        raise ValueError("配置顶层必须是 JSON 对象")
    server = value.get("server")
    if not isinstance(server, str) or not server.strip():
        raise ValueError("缺少非空 server 字段")
    server = server.strip()
    # Credentials embedded in a URL are still credentials.  Reject them even
    # though arbitrary sibling fields (including token) are already discarded.
    if any(marker in server for marker in ("@", "?", "#", "\n", "\r")):
        raise ValueError("server 不能包含凭证、查询参数、片段或换行")
    result: Dict[str, object] = {"server": server}
    if value.get("authRequired") is True:
        result["authRequired"] = True
    return result


def main() -> int:
    parser = argparse.ArgumentParser()
    parser.add_argument("destination", type=Path)
    parser.add_argument("--home", type=Path, default=Path.home())
    args = parser.parse_args()

    args.destination.mkdir(parents=True, exist_ok=True)
    failures = 0
    for app_id in APP_IDS:
        output = args.destination / f"{app_id}.json"
        output.unlink(missing_ok=True)
        source = source_for(app_id, args.home)
        if source is None:
            print(f"未找到本地配置: {app_id}.json", file=sys.stderr)
            failures += 1
            continue
        try:
            config = safe_server_config(source)
        except (OSError, json.JSONDecodeError, ValueError) as error:
            print(f"跳过无效配置 {app_id}.json: {error}", file=sys.stderr)
            failures += 1
            continue
        output.write_text(
            json.dumps(config, ensure_ascii=False, indent=2) + "\n",
            encoding="utf-8",
        )
        output.chmod(0o600)
        print(f"已打包安全配置: {app_id}.json（不含凭据）")
    return 1 if failures else 0


if __name__ == "__main__":
    raise SystemExit(main())
