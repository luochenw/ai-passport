#!/usr/bin/env python3
"""生成 mac-relay/AppManifests/registry.json。

伴侣端启动时会去 GitHub 拉这份目录,再按里面的 sha256 校验每份清单;
校验不过就丢弃,退回内置版本。这条规则的代价是:**目录一旦过期,所有
清单都会被静默拒绝** —— 现象只是"从网上更新应用没生效",没有任何报错,
而且退回的内置版本看起来一切正常。改完清单忘了重新生成目录,几乎不可能
靠肉眼发现。

所以这个脚本存在的意义不是"省得手算哈希",是让 `--check` 能进
validate.sh —— 让忘记这一步在 CI 里当场失败,而不是留到真机上。

用法:
    tools/gen_manifest_registry.py            # 重新生成
    tools/gen_manifest_registry.py --check    # 只检查是否最新(CI 用)
"""

import hashlib
import json
import pathlib
import sys

ROOT = pathlib.Path(__file__).resolve().parent.parent
MANIFEST_DIR = ROOT / "mac-relay" / "AppManifests"
REGISTRY = MANIFEST_DIR / "registry.json"


def build() -> str:
    entries = []
    for path in sorted(MANIFEST_DIR.glob("*.json")):
        if path.name == REGISTRY.name:
            continue
        raw = path.read_bytes()
        try:
            manifest = json.loads(raw)
        except json.JSONDecodeError as exc:
            sys.exit(f"{path.name} 不是合法 JSON:{exc}")
        for field in ("id", "name", "capability", "screens"):
            if field not in manifest:
                sys.exit(f"{path.name} 缺字段 {field}")
        if manifest["id"] != path.stem:
            # 伴侣端按 id 落盘缓存,文件名对不上 id 会让缓存和目录指向两份
            # 不同的东西。
            sys.exit(f"{path.name} 的 id 是 {manifest['id']},和文件名不一致")
        entries.append({
            "id": manifest["id"],
            "name": manifest["name"],
            # 相对路径:换个镜像、换个分支只要改 base,不用重写整份目录。
            "url": path.name,
            # ⚠ 摘要算的是**文件原始字节**,不是重新序列化的 JSON ——
            # 伴侣端校验的也是收到的原始响应体。任何一边做了格式化,
            # 两边就永远对不上。
            "sha256": hashlib.sha256(raw).hexdigest(),
        })
    return json.dumps(entries, ensure_ascii=False, indent=2) + "\n"


def main() -> None:
    want = build()
    if "--check" in sys.argv:
        have = REGISTRY.read_text(encoding="utf-8") if REGISTRY.exists() else ""
        if have != want:
            sys.exit(
                "registry.json 和 AppManifests/ 里的清单对不上。\n"
                "改过清单之后要跑一次:tools/gen_manifest_registry.py\n"
                "不然伴侣端会因为摘要不符**静默丢弃**所有拉下来的清单。"
            )
        print(f"registry.json: 最新({len(json.loads(want))} 份清单)")
        return
    REGISTRY.write_text(want, encoding="utf-8")
    print(f"已生成 {REGISTRY.relative_to(ROOT)}({len(json.loads(want))} 份清单)")


if __name__ == "__main__":
    main()
