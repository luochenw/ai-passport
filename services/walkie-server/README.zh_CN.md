<p align="right">
  <strong>简体中文</strong> · <a href="README.md">English</a>
</p>

# 本地伴侣服务

该服务负责房间成员管理、半双工占麦、实时音频转发，以及可选的 Apple Push to
Talk 唤醒通知。所有状态只保存在内存中，服务不会录制音频。

服务同时在仓库外保存每周菜单历史，并在工作日午餐、晚餐时段仅向已安装“吃饭”
应用且在线的伴侣端广播提醒。macOS 默认菜单状态路径为
`~/Library/Application Support/folotoy/meal-menu.json`。

## 运行

```bash
cd services/walkie-server
go run . -listen 0.0.0.0:8787
```

macOS 上可安装为登录后自动运行的本地常驻服务：

```bash
./install-macos.sh
```

伴侣应用连接 `ws://<服务器地址>:8787/v1/ws`，健康检查地址为 `/healthz`。

“吃饭”应用连接 `ws://<服务器地址>:8787/v1/meals/ws`。本机使用
`POST /v1/meals/update` 写入一周菜单，`GET /v1/meals/current` 与
`GET /v1/meals/weeks` 读取历史；本机可通过
`POST /v1/meals/remind?meal=lunch|dinner` 手动触发一次饭点提醒。

餐厅固定为北京“时尚万科中心”（`MDBD00000590`）。抓取一周菜单 JSON 后可执行：

```bash
python3 update-menu.py /path/to/week.json
```

同一周的不同日期会合并，最多保留 52 周历史。服务按 Asia/Shanghai 时区在工作日
12:10、18:10 广播；只有在线且已安装“吃饭”的客户端接收 Passport 全局卡片，
客户端收到周菜单后还会预排本地系统通知。

设置 `WALKIE_SHARED_TOKEN` 后，所有客户端必须提供相同的预共享口令。不要把
真实口令写进仓库。

iOS Push to Talk 注册信息默认保存在仓库外的当前用户配置目录。通过
`-state <路径>` 可为 `launchd`、`systemd` 或专用服务账号指定持久化位置。

## iOS 锁屏唤醒

前台或已经在运行的客户端不需要 Apple 凭据。若要在有人讲话时唤醒 iPhone，
需要配置以下全部环境变量：

```text
WALKIE_APNS_KEY_PATH
WALKIE_APNS_KEY_ID
WALKIE_APNS_TEAM_ID
WALKIE_APNS_BUNDLE_ID
WALKIE_APNS_PRODUCTION=0
```

密钥路径应指向具备 Push to Talk 权限的 Apple `.p8` Provider Key。生产 APNs
使用 `WALKIE_APNS_PRODUCTION=1`。

APNs 不承载音频，只负责唤醒应用；音频仍通过配置的 WebSocket 链路传输。

用户需要先在前台打开一次 iOS 伴侣应用，安装或重新连接对讲机，并授予所需
权限。iOS 只允许通过前台用户操作新加入 Push to Talk 频道。完成后系统可以
挂起应用并断开普通网络连接；收到 Push to Talk 通知时，客户端会被唤醒并
重连本地 WebSocket 服务，服务端会为这次重连保留一小段预滚音频。

iOS 不允许应用绕过用户的强制退出选择。如果用户从多任务界面划掉应用，需要
重新打开一次，之后才能继续期待锁屏来话。虽然音频服务位于局域网，APNs 投递
仍要求 iPhone 和本地服务所在机器都能访问互联网。
