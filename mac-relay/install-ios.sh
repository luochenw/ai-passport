#!/usr/bin/env bash
# 编译 iOS 版并装到连着的 iPhone 上(签名走 Xcode 的自动签名)。
#
#   ./install-ios.sh              自动挑第一台连着的设备
#   ./install-ios.sh <设备UDID>   指定设备
#
# 前置条件(都是一次性的,缺了会明确报错):
#   · Xcode 里登录 Apple ID —— 免费账号即可,证书由 -allowProvisioningUpdates
#     自动申请。Team ID 只在本脚本运行时从 Xcode 偏好读取,不写进工程文件。
#   · iPhone 上打开 设置 → 隐私与安全性 → 开发者模式(要重启手机)
#   · 第一次装完,在 设置 → 通用 → VPN 与设备管理 里信任那个开发者证书,
#     否则装得上但**起不来**(报 "profile has not been explicitly trusted")
set -euo pipefail
cd "$(dirname "$0")"

BUNDLE_ID="com.folotoy.codexrelay"
SCHEME="FoloCodexRelay"

TEAM="${DEVELOPMENT_TEAM:-}"
if [[ -z "$TEAM" ]]; then
    TEAM=$(defaults read com.apple.dt.Xcode IDEProvisioningTeamByIdentifier 2>/dev/null \
           | awk '/teamID[[:space:]]*=/{gsub(/[\";]/, "", $3); print $3; exit}' \
           | head -1)
fi
[[ -n "$TEAM" ]] || {
    echo "找不到 Apple Developer Team ID。先在 Xcode 登录 Apple ID，或设置 DEVELOPMENT_TEAM。" >&2
    exit 1
}

DEVICE="${1:-}"
if [[ -z "$DEVICE" ]]; then
    DEVICE=$(xcrun devicectl list devices 2>/dev/null \
             | awk '/connected/ {print $3; exit}')
    [[ -n "$DEVICE" ]] || { echo "没有连着的设备。插上 iPhone 并解锁。" >&2; exit 1; }
    echo "设备: $DEVICE"
fi

# 源文件有增删时重新生成工程(UUID 是按文件名算的,同样输入永远同样输出)
python3 ../tools/gen_ios_project.py

echo "=== 编译 + 签名 ==="
xcodebuild -project "${SCHEME}.xcodeproj" -scheme "$SCHEME" \
    -configuration Debug -destination "id=${DEVICE}" \
    DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates build \
    | grep -E "Signing Identity|BUILD SUCCEEDED|BUILD FAILED|error:"

APP=$(xcodebuild -project "${SCHEME}.xcodeproj" -scheme "$SCHEME" \
      -configuration Debug -destination "id=${DEVICE}" \
      DEVELOPMENT_TEAM="$TEAM" \
      -showBuildSettings 2>/dev/null \
      | awk -F' = ' '/ BUILT_PRODUCTS_DIR /{d=$2} / FULL_PRODUCT_NAME /{n=$2} END{print d"/"n}')
[[ -d "$APP" ]] || { echo "找不到构建产物: $APP" >&2; exit 1; }

# ⚠ 签名完整性自检 + 自愈。
#
# 打包应用配置那个脚本阶段没法声明输出(文件名是动态的),所以当
# `~/.folotoy/*.json` 变了而源码没变时,Xcode 会重跑拷贝、却认为签名
# 还是最新的 —— 产物里多了个没被签名覆盖的文件。表现是装机时报
# "invalid code signature",而错误信息跟真正的原因(动了配置)毫无关系。
# 干净重建一次就好,这里自动做掉。
if ! codesign --verify --deep "$APP" >/dev/null 2>&1; then
    echo "签名不完整(多半是配置变了但增量构建没重签),干净重建一次…"
    xcodebuild -project "${SCHEME}.xcodeproj" -scheme "$SCHEME" \
        -configuration Debug -destination "id=${DEVICE}" clean >/dev/null 2>&1
    xcodebuild -project "${SCHEME}.xcodeproj" -scheme "$SCHEME" \
        -configuration Debug -destination "id=${DEVICE}" \
        DEVELOPMENT_TEAM="$TEAM" -allowProvisioningUpdates build \
        | grep -E "BUILD SUCCEEDED|BUILD FAILED|error:"
    codesign --verify --deep "$APP" || { echo "签名仍然无效,停。" >&2; exit 1; }
fi

echo "=== 装机 ==="
xcrun devicectl device install app --device "$DEVICE" "$APP"

echo "=== 启动 ==="
# 把真实原因打出来,而不是不管三七二十一都怪"没信任"。装得上≠能启动,
# 而"起不来"至少有三种完全不同的原因,提示错了会让人查错方向。
out=$(xcrun devicectl device process launch --device "$DEVICE" "$BUNDLE_ID" 2>&1) || true
if grep -q "Launched application" <<<"$out"; then
    echo "已启动"
elif grep -q "could not be, unlocked" <<<"$out"; then
    echo "⚠ 手机锁着,启动被拒。解锁后重试(或直接点桌面图标)。"
elif grep -q "explicitly trusted" <<<"$out"; then
    echo "⚠ 开发者证书还没被信任(第一次装必须做一次):"
    echo "  iPhone: 设置 → 通用 → VPN 与设备管理 → 开发者 App → 信任"
else
    echo "⚠ 启动失败,原文如下:"
    grep -E "NSLocalizedFailureReason|BSErrorCodeDescription" <<<"$out" | head -3
fi
