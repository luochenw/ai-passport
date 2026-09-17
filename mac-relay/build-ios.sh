#!/usr/bin/env bash
# 编译 iOS 版 FoloCodexRelay。
#
#   ./build-ios.sh            编译到 iOS 模拟器并装进当前启动的模拟器
#   ./build-ios.sh --device   编译真机版(需要签名身份,见下)
#
# 为什么不用 .xcodeproj:这个仓库的风格是自带脚本、不引额外依赖(Mac 版的
# build.sh 也是直接调 swiftc)。iOS 的 .app 就是一个目录加一份 Info.plist,
# 手工组装完全可行,而且比一个几千行、没法 review 的 pbxproj 更容易看懂。
set -euo pipefail
cd "$(dirname "$0")"

MODE="${1:---simulator}"

# Keep the bundled firmware and its visible metadata inseparable. A clean
# checkout intentionally has no generated BIN and must build firmware first.
python3 ../tools/update_firmware_catalog.py --check \
    --firmware AppCatalog/current-firmware.bin \
    --catalog AppCatalog/catalog.json

# 只编 Shared/。macOS/ 那两个文件(HeadlessCodexSender 起子进程跑 codex、
# CodexBrowserModel 读 ~/.codex/sessions)在 iOS 上根本不成立 —— 前者被内核
# 禁止,后者沙盒里没有那个目录。它们不参与 iOS 构建,而 Shared/ 里没有任何
# 一处引用它们(CodexApp 通过 CodexBackend 协议解耦,iOS 上注入 nil)。
SOURCES=$(find FoloCodexRelay/Shared -name '*.swift' | sort)

if [[ "$MODE" == "--device" ]]; then
    SDK=$(xcrun --sdk iphoneos --show-sdk-path)
    TARGET="arm64-apple-ios17.0"
    APP="build-ios/FoloCodexRelay.app"
else
    SDK=$(xcrun --sdk iphonesimulator --show-sdk-path)
    # 模拟器在 Apple Silicon 上也是 arm64,但三元组结尾必须是 -simulator,
    # 否则链接器会去找真机的 framework 变体然后报一堆看不懂的符号错误。
    TARGET="arm64-apple-ios17.0-simulator"
    APP="build-ios-sim/FoloCodexRelay.app"
fi

rm -rf "$APP"
mkdir -p "$APP"
# iOS 的 bundle 是扁的:可执行文件和 Info.plist 都直接放在 .app 根下,
# 没有 macOS 那层 Contents/MacOS。
cp FoloCodexRelay/Info-iOS.plist "$APP/Info.plist"

swiftc $SOURCES \
    -o "$APP/FoloCodexRelay" \
    -target "$TARGET" \
    -sdk "$SDK" \
    -framework CoreBluetooth -framework Foundation \
    -framework Speech -framework AVFoundation \
    -framework SwiftUI -framework PushToTalk -framework UserNotifications

mkdir -p "$APP/AppCatalog"
cp -R AppCatalog/. "$APP/AppCatalog/" 2>/dev/null || true

mkdir -p "$APP/AppManifests"
cp -R AppManifests/. "$APP/AppManifests/" 2>/dev/null || true

# iOS 只能从 bundle 读取首次启动配置。显式开启时，从标准本地目录提取
# meal/walkie 的 server 字段；token 等字段始终丢弃，仍由应用写入钥匙串。
if [ "${FOLO_BUNDLE_CONFIG:-0}" = "1" ]; then
    python3 bundle-app-configs.py "$APP"
else
    rm -f "$APP/meal.json" "$APP/walkie.json"
    echo "应用服务地址未打包。需要时用 FOLO_BUNDLE_CONFIG=1 ./build-ios.sh"
fi

if [[ "$MODE" == "--device" ]]; then
    # ⚠ 这条分支只产出**没签名**的 .app,装不进真机。
    #
    # 真机装机走 .xcodeproj,不走这里:自动签名(申请开发证书、创建描述
    # 文件、把这台设备注册进去)是 Xcode 构建系统的一部分,命令行手工
    # codesign 那条路要自己拼 entitlements、自己嵌描述文件,又长又脆,
    # 而且证书 7 天一过期就得重来一遍。
    #
    #   python3 ../tools/gen_ios_project.py     # 源文件有增删时重跑
    #   xcodebuild -project FoloCodexRelay.xcodeproj -scheme FoloCodexRelay \
    #       -destination "id=<设备UDID>" -allowProvisioningUpdates build
    #   xcrun devicectl device install app --device <设备UDID> <产物路径>
    #
    # 保留这条分支是因为它有独立价值:不需要签名、不需要下真机部署组件
    # (那个 7GB+),就能验证"iOS 真机 SDK 编不编得过"。
    echo "构建完成(未签名): $APP"
    echo "⚠ 这份装不进真机。真机装机请走 FoloCodexRelay.xcodeproj,见本脚本注释。"
else
    echo "构建完成: $APP"
    echo "装进模拟器: xcrun simctl install booted $APP"
fi
