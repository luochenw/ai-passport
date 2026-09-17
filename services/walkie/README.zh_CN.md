<p align="right">
  <strong>简体中文</strong> · <a href="README.md">English</a>
</p>

# 对讲服务

该服务负责房间成员管理、半双工占麦、实时音频转发，以及可选的 Apple Push to
Talk 唤醒通知。所有状态只保存在内存中，服务不会录制音频。

## 运行

```bash
cd services/walkie
go run . -listen 0.0.0.0:8787
```

macOS 上可安装为登录后自动运行的本地常驻服务：

```bash
./install-macos.sh
```

伴侣应用连接 `ws://<服务器地址>:8787/v1/ws`，健康检查地址为 `/healthz`。

局域网测试时可直接填写 `<服务器 IP>:8787`。正式公网部署建议只运行一个常驻服务
进程，在前面使用带受信任证书的域名反向代理，仅开放 80/443，并在客户端填写
`wss://talk.example.com/v1/ws`。务必设置 `WALKIE_SHARED_TOKEN`；不设置时，
知道地址和房间名的任何人都能加入、收听和请求讲话。同一房间和口令的客户端
可以互通，同一时刻只允许一人讲话。该服务的房间状态在单进程内存中，不能直接
水平扩容成多个副本。

吃饭是**另一个服务**，见 [`services/meal/`](../meal/README.zh_CN.md)。

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
