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

# ⚠ 清单必须进 bundle,否则 iPhone 上一个应用都没有。
#
# ManifestStore 按三档找清单:缓存 → 源码树旁边的 AppManifests/ → bundle。
# 第二档是 `#if os(macOS)`,iOS 上直接是 nil;第一档在新装的机器上是空的。
# 所以 iOS 只剩 bundle 这一档 —— 不拷进来,ManifestStore.load() 每个应用都
# 返回 nil,DeviceSession 一个都注册不上,界面上就是一份空列表。
#
# macOS 上不会暴露这个问题:源码树那一档永远命中,所以本机怎么跑都正常。
mkdir -p "$APP/AppManifests"
cp AppManifests/*.json "$APP/AppManifests/" 2>/dev/null || true

# 应用自己的配置随构建打进 bundle。
#
# 为什么要这一步:iOS 沙盒里没有家目录,`~/.folotoy/*.json` 那条路只在
# macOS 上成立。bundle 两端都有,所以把配置在构建时拷进去,应用一行平台
# 判断都不用写(见 DashboardApp.config)。
#
# ⚠ 这意味着口令会躺在构建产物里。自己用没问题,但**产物不能随便发给
# 别人**。仓库里始终没有这些文件。
# ⚠ 只拷**还存在的应用**的配置,不要 `cp ~/.folotoy/*.json`。
#
# 无差别拷的后果:面板应用删掉之后,它的 dashboard.json(里面有 NAS 地址和
# 凭据)照样被打进每一个构建产物,躺在手机上,而已经没有任何代码会读它。
# 白白多一份带凭据的文件在产物里。
#
# 判据用 AppManifests/ 里有哪些清单 —— 应用没了清单也就没了,配置自然
# 跟着不再打包。新老两个位置都找:apps/<id>.json 是现在的,<id>.json 是
# 单文件时代的老位置。
packed=""
for manifest in AppManifests/*.json; do
    id="$(basename "$manifest" .json)"
    [[ "$id" == "registry" ]] && continue
    for candidate in "$HOME/.folotoy/apps/$id.json" "$HOME/.folotoy/$id.json"; do
        if [[ -f "$candidate" ]]; then
            cp "$candidate" "$APP/$id.json"
            packed="$packed $id.json"
            break
        fi
    done
done
if [[ -n "$packed" ]]; then
    echo "已打包应用配置:$packed"
else
    echo "注意: ~/.folotoy/ 下没有对应的配置,需要配置的应用会显示「未配置」"
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
