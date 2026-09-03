---
name: build-an-app
description: 为 FoloToy AI Passport 写一个应用。应用跑在配套 Mac app 里,设备只当显示终端 —— 不用碰 C、不用刷固件、不可能把设备写成砖。讲清楚边界在哪、平台已经给了什么、怎么验证、什么情况下才需要动固件。
---

<p align="right">
  <strong>简体中文</strong> · <a href="SKILL.md">English</a>
</p>

# 给 AI Passport 写一个应用

看完这篇你应该能回答三个问题:**应用到底是什么、哪些线不能碰、怎么让别人也能装上你的应用。**

---

## 1. 应用是什么

**一个应用 = 配套 app 里的一个 Swift 类型,实现 `RemoteApp` 协议。**

不是固件,不是插件,不是脚本。它跑在电脑上,设备只是它的一块屏幕和三个按键。

```
   电脑(配套 app)                          设备
┌───────────────────────┐               ┌──────────────┐
│  你的应用             │  屏幕描述文本  │              │
│  ・取数据             │ ────────────► │  照着画出来  │
│  ・算状态             │               │              │
│  ・决定显示什么       │ ◄──────────── │  按键回传    │
└───────────────────────┘   按键事件     └──────────────┘
```

这意味着:

* **应用在设备上不占空间**,想装几个装几个(上限 8 个,见 §2.1),切换是瞬间的;
* **不需要 Wi-Fi、HTTP、JSON** —— 那些都在电脑那一端做完了;
* **不用碰 C 和 ESP-IDF**,也**不可能把设备写成砖**;
* 改一行代码重启配套 app 就生效,不用等两分钟刷固件。

### 曾经不是这样

早先的设计是"一个应用 = 一份完整固件,烧进 `appslot` 分区再重启过去"。那条路真的跑通过,但代价大到不成立:每个应用都要自带一份 LVGL、字体、BLE 协议栈,于是一个只显示几行数字的面板也有 **1.9MB** —— 其中 95% 是跟别的应用一模一样的基础设施;`appslot` 只有一个槽,所以还只能装一个,换应用要重刷两分钟。

留下这段是因为仓库里还有那套机制的痕迹(`appslot` 分区、`demo_appstore.c`、配套 app 的「固件」标签页)。**那套现在专门用来升级设备固件本身,跟装应用是两件不同的事**,别混起来。

---

## 2. 硬边界

**下面每一条都对应一个真实发生过的问题,不是风格偏好。**

### 2.1 一屏能放多少

| 约束 | 数值 | 超了会怎样 |
|---|---|---|
| 一屏的行数 | 12 行 | 多的行被**静默丢弃** |
| 一行的字节数 | 64 字节(UTF-8,中文一字 3 字节 ≈ 21 字) | 超出部分截断 |
| 一屏总字节 | 1000 字节 | 截到最后一个完整行 |
| 首屏能列出的已安装应用 | 8 个 | 第 9 个装了但**设备上看不见** |

最后一条尤其要当心:设备的首屏槽位是固定数组,收到超长清单只会截断,不报错。配套 app 里 `RemoteAppHost.maxInstalled` 会先挡住并明确告诉用户,**改这个数必须同时改固件的 `REMOTE_UI_MAX_APPS`**,而且固件里有一条 `_Static_assert` 会在放不下时直接编译失败。

### 2.2 按键只有三个,而且枚举值不能猜

```swift
enum RemoteButton: UInt8 { case up = 0; case down = 1; case ok = 2 }
enum RemoteButtonEvent: UInt8 {
    case press = 0; case click = 1; case double = 2
    case long = 3;  case hold = 4;  case longUp = 5
}
```

这些数值必须跟固件 `components/bsp/include/bsp_button.h` 里的 `bsp_btn_t` / `bsp_btn_ev_t` **逐个对上**。

⚠ 这里错过一次:按"上/确定/下"和"单击/长按/双击"的直觉顺序编号,而固件里实际是"上/下/确定"和"按下/单击/双击/长按/连发"。后果是下键和确定键互换、双击被当成长按 —— **不会有任何报错**,只是按下去做的事不对。`tests/test_button_enum_sync.c` 现在会 grep 这份 Swift 源码跟 C 头文件比对,把这件事钉死了。

还要知道:**长按「确定」被设备拦截用作返回上一层**,永远不会传到你的应用里。应用内部要"返回",用双击确定。

### 2.3 `render()` 必须廉价、不能阻塞

`render()` 会被反复调用。**不要在里面发网络请求、读大文件、等锁。**

正确的做法是:后台拿数据,拿到之后调 `requestPush()` 通知框架重推一屏。

```swift
private func refresh() {
    URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
        self?.queue.async {
            self?.rows = parse(data)     // 先更新自己的状态
            self?.requestPush?()         // 再让框架重画
        }
    }.resume()
}
```

`render()` 和 `handleKey()` 跑在框架的串行队列上,你自己的定时器/网络回调跑在别的队列 —— **两边都会碰你的状态,自己加锁**(`NSLock` 或一个自己的串行队列都行)。

### 2.4 凭据永远不进仓库

这个仓库有密钥扫描(`tools/check_repo.py`),而且社区里的代码是公开的。

**应用自己的参数(接口地址、账号口令)归应用自己管**,不要摊到配套 app 的「配置」页上 —— 那一页只放属于硬件本身的设置(音量、亮度、Wi-Fi、状态栏)。

现成的做法参考 `DashboardApp.swift`:读 `~/.folotoy/dashboard.json`(`chmod 600`),仓库里只留一份不含真实值的说明。日志里**只打键名,不打值**。

### 2.5 后台应用不许推屏

框架已经挡住了:`requestPush()` 只有在你的应用**正处于前台**时才真的推。但你自己的定时器该停还是要停 —— `setActive(false)` 里把它关掉,不然用户离开之后你还在每 5 秒发一次网络请求。

### 2.6 麦克风在设备上,不能由电脑代劳

语音是唯一一个必须留在固件里的能力:采样、ADPCM 编码、分片推送,这条链路的起点在硬件那一侧。

应用能做的只是**声明意图**:

```swift
var s = Screen()
s.mic = true          // 协议里的 M1
```

设备收到之后自己把"长按下键"接到录音上,音频经 Codex 那条 AUDIO 通道流回电脑转写。参考 `CodexApp.swift`。

---

## 3. 屏幕描述协议

对端推一段纯文本,一行一个元素:

```
T<标题>              顶部标题
L<文本>              一行正文
B<百分比>|<标签>     一条进度条(0..100)
H<提示>              底部按键提示
M<0|1>               这一屏收不收语音输入
```

**不要手写这个格式**,用 `Screen`:

```swift
var s = Screen()
s.title = "服务器"
s.text("CPU 12%   内存 4.2G")
s.bar("磁盘", percent: 78)
s.spacer()
s.footer = "上/下翻页  确定刷新"
```

`Screen` 会替你处理换行和竖线的转义 —— 手拼字符串很容易漏掉,而那类错误在设备上表现为"某一行莫名其妙不显示"。

**未识别的行类型会被设备忽略**,不会崩。所以将来加新元素时,老固件只是显示不出新东西,不会挂。

---

## 4. 写一个应用

三步。

### 4.1 实现 `RemoteApp`

```swift
import Foundation

final class MyApp: RemoteApp {
    let name = "我的应用"          // 显示在首屏和商店里
    let detail = "一句话说明"       // 商店列表的第二行
    var requestPush: (() -> Void)?

    private let queue = DispatchQueue(label: "com.example.myapp")
    private var timer: DispatchSourceTimer?
    private var lines: [String] = []

    func render() -> Screen {
        var s = Screen()
        s.title = name
        for l in lines { s.text(l) }
        s.footer = "确定刷新"
        return s
    }

    func handleKey(_ b: RemoteButton, _ e: RemoteButtonEvent) -> Bool {
        guard b == .ok, e == .click else { return false }
        refresh()
        return false            // 数据还没到,现在重画没意义
    }

    func setActive(_ active: Bool) {
        if active { startTimer() } else { stopTimer() }
    }
}
```

`handleKey` 的返回值是"**现在**要不要立刻重推一屏":选中项移动了 → `true`;发起了一次异步刷新 → `false`(等数据到了走 `requestPush`)。

### 4.2 注册

`Shared/AppCore.swift` 里加一行:

```swift
remoteHost.register(MyApp())
```

### 4.3 加进构建

`mac-relay/build.sh` 的 `swiftc` 那一行末尾加上你的文件。

装/卸在配套 app 的「应用」标签页,或者在设备上进「应用商店」按确定。

---

## 5. 验证

**设备不在手边也能验大半。** 这是这套架构最实际的好处之一。

### 5.1 跑一遍闸门

```bash
./tools/validate.sh --static
```

这一档跑仓库一致性检查、按键枚举同步检查、以及应用商店逻辑的宿主机回归测试。改了协议或者商店逻辑,这里会告诉你。

### 5.2 不接设备驱动你的应用

配套 app 跑起来之后,往 `/tmp/folo_remote_sim` 写命令就能模拟设备的动作:

```bash
# 首屏选中第 0 项(254 = 应用商店)
echo "open 0" > /tmp/folo_remote_sim

# 一次按键:btn 0=上 1=下 2=确定,ev 1=单击 2=双击
echo "key 1 1" > /tmp/folo_remote_sim

# 把当前这一屏完整打进日志
echo "dump" > /tmp/folo_remote_sim

# 看当前装了哪些
echo "installed" > /tmp/folo_remote_sim
```

日志在 `/tmp/folo_codex_relay.log`。`dump` 出来的就是设备会收到的原文,一行不差。

### 5.3 给自己的逻辑写宿主机测试

`tests/test_remote_apps.swift` 是现成的样板:用一个假的 `RemoteApp`、一份临时的 `UserDefaults`,把"装 → 上首屏 → 商店不再列出 → 卸载"整条链路跑一遍。

值得测的是那些**失败起来没有声音**的地方 —— 界面少一行、清单没推出去、装到第 9 个被悄悄丢掉。这些在真机上要一步步试才能发现。

### 5.4 上真机之前

- 一屏内容在最长的情况下也没超 12 行;
- 每一行在中文下也没超 64 字节;
- 离开应用之后定时器真的停了(看日志有没有继续刷);
- 断开蓝牙再连上,应用能自己恢复;
- 凭据没有出现在仓库里、也没有出现在日志里。

---

## 6. 什么时候才需要动固件

**绝大多数应用不需要。** 只有当你要用一个设备上**还没有**的硬件能力时才需要 —— 比如新的传感器、新的显示元素。

如果确实要动,这几条是硬的:

### 6.1 Wi-Fi 只有一个所有者

全仓库只有 `main/wifi_mgr.c` 可以碰 `esp_wifi_*` / `esp_netif_*`。

**永远不要调 `esp_wifi_deinit()` 或 `esp_netif_destroy_default_wifi()`。** 关掉用 `esp_wifi_stop()`,它是可逆幂等的。

原因:`esp_netif_create_default_wifi_sta()` 撞上重复的 if_key 会 **assert 然后重启**,不是返回错误 —— 表现为开机无限重启,串口刷屏,极难定位。这个坑真实踩过,而且是两个模块各自维护"初始化过了没"的标志、互相看不见导致的。

### 6.2 BLE 只有一个协议栈

所有 GATT service 通过 `ble_hub_register_service()` 注册,而且**必须在 `ble_hub_init()` 之前**。之后再注册不会生效也不会报错,只表现为"对端怎么也发现不了这个特征值"。

`BLE_HUB_MAX_SERVICES` / `BLE_HUB_MAX_OBSERVERS` 上限是 8,满了同样是**静默忽略**(只打一条 `ESP_LOGE`)。

### 6.3 分区表不能动

`factory` / `cardid` / `recovery` 三个分区的偏移和大小**一个字节都不能改** —— 它们是官方小程序 BLE 刷机流程的一部分,改了用户就失去了官方的救砖途径。`tools/verify_firmware.py` 会逐字段校验,还会字面检查 bootloader 二进制里必须包含 `"UP held: booting permanent recovery"` 这句日志。

### 6.4 改完必须跑

```bash
./tools/validate.sh --all
```

---

## 7. 一句话总结

写应用碰不到上面第 6 节的任何一条。**那正是这套架构的目的**:让写应用这件事跟"可能把设备弄坏"彻底脱钩。
