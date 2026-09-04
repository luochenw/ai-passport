<p align="right">
  <strong>简体中文</strong> · <a href="capabilities.md">English</a>
</p>

# 能力清单

一个「应用」被拆成两半:

| | 是什么 | 从哪来 |
| --- | --- | --- |
| **清单** | JSON:几屏、每屏哪些行、按键绑哪个动作 | 数据,启动时从 GitHub 拉 |
| **能力** | Swift 类:清单描述不了的那部分 | 编进 app,只能改代码加 |

必须这么切:Swift 是 AOT 编译的,iOS 也明令禁止下载并执行代码(App Store
2.5.2)。所以「从 GitHub 更新应用」只能是**取数据**。

## 加一个应用要不要改代码

只看一条:**它要的能力已经存在吗。**

| 情况 | 要做什么 |
| --- | --- |
| 复用已有能力 | 往 `mac-relay/AppManifests/` 放一份清单,跑 `tools/gen_manifest_registry.py`。**不碰代码、不重装 app** |
| 需要一种新的平台本事 | 写一个新能力(见下),再写清单 |

第二种是 iOS 的硬约束,躲不掉。第一种以前也要改代码 —— 那是实现缺陷,已经
修掉了(`DeviceSession` 现在遍历全部清单、查能力表注册,不再是三段写死的
`ManifestStore.load`)。

## 现有能力

清单里 `"capability"` 字段填这一列的 id。

### `walkie` — 实时音频

设备麦克风/喇叭 ↔ BLE ↔ WebSocket,半双工话权。

| 清单能读 | 含义 |
| --- | --- |
| `room` / `members` | 房间名、在线人数 |
| `connected` | 服务连上没有 |
| `transmitting` | 我正在讲话 |
| `speaker` | 谁在讲话(没人时为空) |
| `status` | 一句人话状态 |

动作:`beginTalk` / `endTalk`(按住下键那种,绑 `press` / `release`)。
配置:服务器地址和房间在伴侣端设置页,共享口令在钥匙串。

### `meal` — 每周菜单

拉 `services/meal` 的 HTTP/WebSocket,按点广播提醒。

| 清单能读 | 含义 |
| --- | --- |
| `installed` / `connected` | 这台设备装了没有、服务通不通 |
| `period` / `date` / `multiDay` | 当前是午/晚、哪一天、有没有多天数据 |
| `status` | 一句人话状态 |

动作:`prevDay` / `nextDay` / `togglePeriod`。

### `codex` — 子进程 + 本地文件(仅 macOS)

起 `codex` 命令行进程、扫 `~/.codex/sessions`。iOS 上两件事都做不到,
所以那边这个应用显示「本端不可用」并说明原因。

| 清单能读 | 含义 |
| --- | --- |
| `screen` | 现在该显示哪一屏(工作区/会话/阅读) |
| `workspaces` / `sessions` / `lines` | 三种列表数据 |
| `wsSel` / `sessSel` | 选中项下标 |

动作:`up` / `down` / `open` / `back` / `prevPage` / `nextPage`。

### `http` — 定时拉一个 JSON(通用)

不认识任何业务:按配置 GET 一个 JSON,把**整棵响应树**放进 `data`。
天气、CI 状态、家里的传感器、自建 API 都是同一个形状。

| 清单能读 | 含义 |
| --- | --- |
| `connected` | 上一次拉成功了没有 |
| `status` | 一句人话状态或错误 |
| `data` | 响应的整棵 JSON |

动作:`refresh`。

配置在 `~/.folotoy/apps/<清单id>.json`,**不进仓库**:

```json
{
  "url": "https://example.invalid/api/status",
  "intervalSeconds": 30,
  "headers": { "Authorization": "Bearer ..." },
  "certificateSHA256": "自签名证书的 SHA-256,可省"
}
```

填了 `certificateSHA256` 就只信那一张证书。私有部署常见 IP 直连 + 自签名,
系统校验必然过不去 —— 固定一张证书比关掉校验安全得多,后者等于对任何中间人
敞开。清单里这么用:

```json
{ "text": "CPU  {{data.cpu.percent|fixed:1}}%" },
{ "each": { "path": "data.disks", "body": [ { "text": "{{item.name}}" } ] } }
```

`mac-relay/AppManifests/status.json` 是一份可以照抄的例子。

## 还缺什么

这些今天做不到,想做得先加能力:

- **写操作。** 现有能力全是只读的(对讲的话权是唯一例外)。「按一下把灯打开」
  这类应用做不了 —— `http` 只会 GET。
- **本地存储。** 清单没法把状态写回去,所以待办列表、计数器这类做不了。
- **定时器/时钟。** 倒计时、番茄钟。纯本地,不需要网络,但现在没有。
- **通用列表导航。** 开窗、选中标记、上下「还有 N 项」这套在 `codex` 里是写死
  的,别的清单用不上,只能自己用 `each` 拼一个不一样的。
- **跑一条命令(仅 macOS)。** `codex` 已经在起子进程,但只服务它自己。

## 加一个能力

1. 在 `mac-relay/FoloCodexRelay/Shared/Apps/<名字>/` 下写一个类,实现
   `AppCapability`(`static let id`、`state()`、`perform(_:)`、`overlay`)
2. 在 `DeviceSession` 的能力表里加一行
3. 写一份清单用它

接口要**窄且稳定**。清单是从网上拉的,可能比伴侣端旧或新;能力接口频繁改,
清单就得跟着改,「从网上更新应用」的价值当场归零。宁可能力少一点、笨一点。

`tools/gen_manifest_registry.py` 会从各个 `*Capability.swift` 里抠出真实的
能力 id,清单里写了不存在的能力会当场失败 —— 否则现象是这个应用在设备上
直接不出现,没有任何报错。
