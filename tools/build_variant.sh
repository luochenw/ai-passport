#!/usr/bin/env bash
# 构建一个应用变体,产物带上变体名,方便直接放进社区目录。
#
#   ./tools/build_variant.sh dashboard
#   ./tools/build_variant.sh launcher     # 等价于普通的 idf.py build
#
# 每个变体一个独立 build 目录和独立 sdkconfig —— 共用一个目录会让上一次变体
# 的配置残留下来(sdkconfig 是生成物,不是每次都从 defaults 重算),构建出
# 一个既不是这个变体也不是那个变体的东西,而且不会报错。
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "${repo_root}"

variant="${1:-launcher}"
build_dir="build-${variant}"
defaults="sdkconfig.defaults"

if [[ "${variant}" != "launcher" ]]; then
    extra="sdkconfig.defaults.${variant}"
    if [[ ! -f "${extra}" ]]; then
        echo "未知变体 '${variant}':找不到 ${extra}" >&2
        echo "可用变体:launcher$(ls sdkconfig.defaults.* 2>/dev/null | sed 's|sdkconfig.defaults.| |')" >&2
        exit 1
    fi
    defaults="${defaults};${extra}"
fi

if ! command -v idf.py >/dev/null 2>&1; then
    echo "idf.py 不可用,请先 source \$IDF_PATH/export.sh" >&2
    exit 1
fi

echo "构建变体: ${variant}"
SDKCONFIG_DEFAULTS="${defaults}" \
    idf.py -B "${build_dir}" -D "SDKCONFIG=${build_dir}/sdkconfig" build

bin="${build_dir}/FoloToy-AI-Passport.bin"
size=$(stat -f%z "${bin}" 2>/dev/null || stat -c%s "${bin}")
# appslot 是 0x3a0000;超了装不进去,现在就告诉开发者,别等传了一分钟才失败。
limit=$((0x3a0000))
if (( size > limit )); then
    echo "❌ 镜像 ${size} 字节,超过 appslot 上限 ${limit} 字节" >&2
    exit 1
fi

if command -v shasum >/dev/null 2>&1; then
    sha=$(shasum -a 256 "${bin}" | awk '{print $1}')
else
    sha=$(sha256sum "${bin}" | awk '{print $1}')
fi

echo
echo "产物:   ${bin}"
echo "大小:   ${size} 字节 (appslot 上限 ${limit})"
echo "sha256: ${sha}"
echo
echo "catalog.json 条目:"
printf '  { "id": "%s", "name": "%s", "description": "", "version": "v1.0.0", "size": %d, "sha256": "%s", "url": "%s.bin" }\n' \
    "${variant}" "${variant}" "${size}" "${sha}" "${variant}"
