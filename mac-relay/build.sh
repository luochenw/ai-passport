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
SOURCES=$(ls FoloCodexRelay/Shared/*.swift FoloCodexRelay/macOS/*.swift)
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
mkdir -p "$APP/Contents/Resources/AppCatalog"
cp -R AppCatalog/. "$APP/Contents/Resources/AppCatalog/" 2>/dev/null || true

# 应用自己的配置随构建打进 bundle。
#
# 为什么要这一步:iOS 沙盒里没有家目录,`~/.folotoy/*.json` 那条路只在
# macOS 上成立。bundle 两端都有,所以把配置在构建时拷进去,应用一行平台
# 判断都不用写(见 DashboardApp.config)。
#
# ⚠ 这意味着口令会躺在构建产物里。自己用没问题,但**产物不能随便发给
# 别人**。仓库里始终没有这些文件。
if compgen -G "$HOME/.folotoy/*.json" > /dev/null; then
    cp "$HOME"/.folotoy/*.json "$APP/Contents/Resources/" 2>/dev/null || true
    echo "已打包应用配置: $(ls -1 "$HOME"/.folotoy/*.json | xargs -n1 basename | tr '\n' ' ')"
else
    echo "注意: ~/.folotoy/ 下没有 .json,需要配置的应用会显示「未配置」"
fi

# 用本机已有的本地签名身份签名,而不是让 swiftc 默认落到 adhoc(每次编译哈希都变,
# 每次都要重新过一遍蓝牙授权)。这个身份是这台机器上已经建立并信任过的(之前给
# FloatingClock 项目用的那个),只是复用,不改任何系统信任设置。
codesign --force --sign "FloatingClock Dev" --identifier com.folotoy.codexrelay "$APP"

echo "构建完成: $APP"
echo "启动: open $APP"
