#!/usr/bin/env python3
import json
from pathlib import Path
import subprocess
import sys
import tempfile


ROOT = Path(__file__).resolve().parents[1]
SCRIPT = ROOT / "mac-relay" / "bundle-app-configs.py"


with tempfile.TemporaryDirectory() as raw_tmp:
    tmp = Path(raw_tmp)
    standard = tmp / "home" / ".folotoy" / "apps"
    legacy = tmp / "home" / ".folotoy"
    output = tmp / "FoloCodexRelay.app"
    standard.mkdir(parents=True)
    (standard / "meal.json").write_text(
        json.dumps({"server": "203.0.113.8:8788", "token": "must-not-leak",
                    "authRequired": True}),
        encoding="utf-8",
    )
    (standard / "walkie.json").write_text(
        json.dumps({"server": "198.51.100.7:8787", "token": "also-secret",
                    "authRequired": True}),
        encoding="utf-8",
    )
    # The standard apps/ location wins over this legacy fallback.
    (legacy / "meal.json").write_text(
        json.dumps({"server": "192.0.2.9:9999"}), encoding="utf-8"
    )

    subprocess.run(
        [sys.executable, str(SCRIPT), str(output), "--home", str(tmp / "home")],
        check=True,
    )

    assert json.loads((output / "meal.json").read_text()) == {
        "server": "203.0.113.8:8788", "authRequired": True
    }
    assert json.loads((output / "walkie.json").read_text()) == {
        "server": "198.51.100.7:8787", "authRequired": True
    }
    bundled = (output / "meal.json").read_text() + (output / "walkie.json").read_text()
    assert "token" not in bundled
    assert "must-not-leak" not in bundled
    assert "also-secret" not in bundled

    (standard / "walkie.json").unlink()
    missing = subprocess.run(
        [sys.executable, str(SCRIPT), str(output), "--home", str(tmp / "home")]
    )
    assert missing.returncode != 0
    assert not (output / "walkie.json").exists()

print("bundle app configs: PASS")
