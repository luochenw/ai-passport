<p align="right">
  <strong>简体中文</strong> · <a href="README.md">English</a>
</p>

# AI Passport —— 配套 app 架构

基于 [FoloToy/ai-passport](https://github.com/FoloToy/ai-passport)(MIT)的衍生版本,
把应用逻辑从设备上挪走。

原版固件把每个功能都跑在 ESP32-C3 上。这个版本让设备只当**显示终端**,
应用跑在配对的 Mac 或 iPhone 上,通过 BLE 把"屏幕描述"推过去:

```
T对讲机                 标题
L房间  local            正文行
L在线  2 人
H按住下键讲话           页脚
W1                      这一屏接受按住讲话
```

固件不知道任何一个具体应用的存在 —— 它只负责画行、上报按键,然后让开。

## 为什么

ESP32-C3 只有 8MB flash、没有 PSRAM,装不下多少功能,而且每加一个都要刷一次机。
把逻辑挪到一台本来就有网络、有磁盘、有各种语言运行时的机器上之后,新加一个
"设备应用"就是写一个实现 `RemoteApp` 的 Swift 类型 —— 不改固件、不刷机、
不占分区预算。

代价也该说清楚:**设备离开配套 app 就没有用处**,只剩首屏和状态栏。

## 仓库里有什么

| 路径 | |
| --- | --- |
| `main/` | 固件:BLE 常驻、远程界面渲染、常驻状态栏、全局通知、Wi-Fi 管理、OTA |
| `mac-relay/` | 配套 app(macOS + iOS,同一个 SwiftUI target)。`Shared/` 两端都编译;`macOS/` 放 iOS 真的做不到的那部分 |
| `services/walkie-server/` | 对讲机的 Go WebSocket 服务:房间、半双工话权、实时音频转发。全内存,不落任何录音 |
| `skills/`、`docs/`、`AGENTS.md` | 开发约定和踩过的坑,给人也给 AI 助手看 |

自带两个应用作为示例:**Codex 会话浏览**,和**局域网对讲机**
(用设备的麦克风和喇叭,按住下键讲话)。

## 构建

```bash
# 固件(ESP-IDF 5.5.3)
idf.py build && idf.py -p /dev/cu.usbmodemXXXX flash

# 配套 app
mac-relay/build.sh          # macOS
mac-relay/install-ios.sh    # iOS:生成工程、签名、装机、启动

# CI 跑的全部检查
tools/validate.sh
```

约定看 `AGENTS.md`,里面记着一串**真花过调试时间**的坑:LVGL 的省略号必须配
固定高度才生效、NimBLE host 任务不持有 LVGL 锁、手动 light sleep 会掐断
BLE 和 USB-CDC,等等。

## 现状

固件、两个 app target、Go 服务都能干净构建,主机测试通过,通知链路在真机上
验证过。对讲机的真机时间比其他部分少。iOS 的 Push to Talk entitlement
**默认关闭**,因为免费 Apple 开发者账号签不了它 —— 有付费 team 且拿到
Apple 的 PTT 授权的话,设 `WALKIE_PTT=1`。

## 许可证

MIT,继承自上游项目,见 [`LICENSE`](LICENSE)。上游版权声明保留;
本仓库新增的部分同样按 MIT 提供。
