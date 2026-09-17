<p align="right">
  <strong>简体中文</strong> · <a href="README.md">English</a>
</p>

# 字节餐厅服务

保存每周菜单历史、按菜品推荐楼层，并在工作日午餐/晚餐时段向已安装“字节餐厅”应用
且在线的伴侣端广播提醒。菜单状态保存在仓库外，macOS 默认路径是
`~/Library/Application Support/folotoy/meal-menu.json`。

**独立的二进制、独立的端口。**它以前是对讲服务里的几个 `/v1/meals/*` 路由。
拆开的理由很实在：两件事没有任何共同状态，而挂在一起意味着改一次菜单解析要
重启所有人的对讲。

## 运行

```bash
cd services/meal
go run . -listen 0.0.0.0:8788
```

macOS 上装成登录后自动运行的常驻服务：

```bash
./install-macos.sh
```

伴侣端的“字节餐厅”应用连接 `ws://<服务器地址>:8788/v1/meals/ws`，健康检查在
`/healthz`。
设置中也可直接填写 `<服务器地址>:8788`，客户端会补全 `ws://` 和 WebSocket
路径。iPhone 上的 `127.0.0.1` 指向手机自身，必须填写手机能够访问的地址。
只有公网 IP 时也可直接填写，例如 `203.0.113.8:8788`，客户端会使用
`ws://` 连接。该模式为明文传输，适合当前测试部署。

公网运行时设置独立的共享口令：

```bash
MEAL_SHARED_TOKEN='请换成长随机口令' go run . -listen 0.0.0.0:8788
```

设置了 `MEAL_SHARED_TOKEN` 后，WebSocket 客户端必须在第一条 `join` 消息中
携带相同的 `token`；伴侣端设置页中的口令只保存在系统钥匙串。留空环境变量
表示关闭鉴权。

## 写入菜单

本机用 `POST /v1/meals/update` 写入一周菜单，`GET /v1/meals/current` 与
`GET /v1/meals/weeks` 读取历史；`POST /v1/meals/remind?meal=lunch|dinner`
手动触发一次提醒。

启用共享口令后，两个 GET 读取接口使用 Bearer 鉴权：

```bash
curl -H 'Authorization: Bearer 请换成长随机口令' \
  http://127.0.0.1:8788/v1/meals/current
```

本机写入与手动提醒接口仍只接受 loopback 请求，不使用 Bearer 口令。

抓取一周菜单 JSON 之后：

```bash
python3 update-menu.py /path/to/week.json
```

同一周的不同日期会合并，最多保留 52 周历史。服务按 Asia/Shanghai 时区在工作日
12:10、18:10 广播；只有在线且已安装“字节餐厅”的客户端会收到 Passport 全局卡片，
客户端收到周菜单后还会预排本地系统通知。

## 配置

`MEAL_BUILDING` 决定这个服务只接受哪一栋楼的菜单。**不设就不校验**，菜单文件
里写什么就是什么。

设置下面两个环境变量后，服务会在启动时立即从 Aplus 拉取一次菜单，之后默认每
30 分钟同步一次：

```bash
APLUS_SESSION_ID='<仅填写 session_id 的值>'
APLUS_BUILDING_CODE='<楼宇编码>'
```

可用 `APLUS_POLL_INTERVAL=1h` 调整间隔。登录态和楼宇编码只从环境变量读取，
不会写进菜单状态或日志。`session_id` 是服务端维护的不透明会话，无法从其内容
推算准确过期时间；同步遇到普通网络错误或 Aplus 服务错误时不会判定它过期。
systemd 部署附带 `update-aplus-session.sh`：脚本会关闭终端回显读取新值，更新受
保护的环境文件，并只重启字节餐厅服务。

将飞书群自定义机器人的 webhook 配置为 `APLUS_TOKEN_NOTIFY_URL=https://...` 后，
Aplus 返回 HTTP 401/403 或明确的未登录/登录失效响应时，服务会发送一次飞书文本
消息。成功同步后才会重置通知状态，避免每轮轮询重复提醒。请求使用飞书 webhook
协议：

```json
{
  "msg_type": "text",
  "content": {
    "text": "Aplus 登录态已失效，请刷新 APLUS_SESSION_ID\n时间：2026-09-08T12:00:00+08:00"
  }
}
```

服务会同时检查 HTTP 状态码和飞书响应中的 `code`。通知 URL 只从环境变量读取，
不会写进状态或日志。`APLUS_TOKEN_NOTIFY_URL` 也兼容 `ws://`/`wss://` 地址并发送
通用 JSON 事件；其他通知协议可通过替换 `aplusAuthNotifier` 实现接入。

⚠ 不要把具体的楼名写回代码里。这是公开仓库，写死等于把部署者在哪儿上班一起
公开了 —— 而且对别人也没用，他们的食堂不叫这个名字。

## 路径

`-state <路径>` 指定菜单历史的持久化位置，给 `launchd`、`systemd` 或专用
服务账号用。
