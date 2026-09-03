#!/usr/bin/env bash
# 编译 FoloCodexRelay.app —— 把 Codex 会话内容通过 BLE 转发到 FoloToy AI Passport 设备。
# 用法: ./build.sh   构建完成后用 open build/FoloCodexRelay.app 启动。
set -euo pipefail
cd "$(dirname "$0")"

APP="build/FoloCodexRelay.app"
rm -rf "$APP"
mkdir -p "$APP/Contents/MacOS"
cp FoloCodexRelay/Info.plist "$APP/Contents/Info.plist"

# 源码按平台边界分目录。分界线是**操作系统能力**,不是框架:
#   Shared/  三端(macOS / iOS / iPadOS)都能编的 —— 入口、界面、BLE、
#            语音、ADPCM、全部应用逻辑。
#   macOS/   只有 macOS 上成立的:起子进程跑 `codex exec`(iOS 内核禁止
#            fork/exec)、读 ~/.codex/sessions(iOS 沙盒里没有这个目录)。
#            换 SwiftUI、Catalyst、"Designed for iPad" 都改变不了这两条。
# 顶层已经没有源码了 —— 入口是 Shared/RelayApp.swift 的 @main。
#
# iOS 构建只需要去掉 macOS/ 这一组(见 mac-relay/project.yml)。
# 递归收集:源码按「框架 / 能力 / 每个应用一个文件夹」分层放,不是平铺。
# 用 find 而不是 ls glob —— 加一个应用就是新建一个文件夹,构建脚本不用改。
SOURCES=$(find FoloCodexRelay/Shared FoloCodexRelay/macOS -name '*.swift' | sort)
# 不再链接 AppKit:入口已经从 NSApplication/NSWindow 换成 SwiftUI 的
# @main App + WindowGroup,全工程一处 AppKit 都不用了。
swiftc $SOURCES \
    -o "$APP/Contents/MacOS/FoloCodexRelay" \
    -framework CoreBluetooth -framework Foundation \
    -framework Speech -framework AVFoundation \
    -framework SwiftUI -framework UserNotifications

# 应用商店的本地目录(v1:静态文件,不接后端),跟着 app 一起分发。放在
# Contents/Resources 下(不是 MacOS 下)—— codesign 会把 Contents/MacOS 里
#除可执行文件以外的东西当成"未签名的子组件"报错,Resources 才是普通数据
# 文件该待的地方。AppStore.swift 的 resolveCatalogDir() 会优先找源码旁边
# 那份(开发时直接跑 swiftc 产物),找不到就退回这里(双击打包好的 .app 时)。
# 内置清单跟着 app 走。这一份是**兜底**:第一次装、没网、GitHub 打不开的
# 时候,应用必须照常能用。从网上更新是锦上添花,不能是运行的前提。
mkdir -p "$APP/Contents/Resources/AppManifests"
cp AppManifests/*.json "$APP/Contents/Resources/AppManifests/" 2>/dev/null || true

mkdir -p "$APP/Contents/Resources/AppCatalog"
cp -R AppCatalog/. "$APP/Contents/Resources/AppCatalog/" 2>/dev/null || true

# 应用配置**默认不进构建产物**。
#
# 以前这一步是无条件的:把 ~/.folotoy/*.json 全部拷进 Contents/Resources。
# 理由是 iOS 沙盒里没有家目录,bundle 是唯一两端都成立的位置。代价是口令
# 躺在产物里,那个 .app 就再也不能发给别人 —— 而这个代价是默认承担的,
# 谁构建谁中招。
#
# 现在默认不拷,产物干净、可以随便发。自己要往 iPhone 上装、需要把配置
# 带进去的时候显式开:
#
#     FOLO_BUNDLE_CONFIG=1 ./build.sh
#
# macOS 上完全不需要开 —— 它直接读 ~/.folotoy/apps/。
if [ "${FOLO_BUNDLE_CONFIG:-0}" = "1" ]; then
    shopt -s nullglob
    cfgs=("$HOME"/.folotoy/apps/*.json "$HOME"/.folotoy/*.json)
    shopt -u nullglob
    if [ ${#cfgs[@]} -gt 0 ]; then
        cp "${cfgs[@]}" "$APP/Contents/Resources/" 2>/dev/null || true
        echo "⚠ 已把应用配置打进 bundle(含口令),这个产物不要发给别人:"
        echo "  $(printf '%s ' "${cfgs[@]##*/}")"
    else
        echo "FOLO_BUNDLE_CONFIG=1 但 ~/.folotoy/ 下没有 .json,什么都没打包"
    fi
else
    echo "应用配置未打包(产物干净)。要带进 iOS 构建:FOLO_BUNDLE_CONFIG=1 ./build.sh"
fi

# 用本机已有的本地签名身份签名,而不是让 swiftc 默认落到 adhoc(每次编译哈希都变,
# 每次都要重新过一遍蓝牙授权)。这个身份是这台机器上已经建立并信任过的(之前给
# FloatingClock 项目用的那个),只是复用,不改任何系统信任设置。
codesign --force --sign "FloatingClock Dev" --identifier com.folotoy.codexrelay "$APP"

echo "构建完成: $APP"
echo "启动: open $APP"
