<p align="right">
  <strong>简体中文</strong> · <a href="README.md">English</a>
</p>

# 吃饭服务

保存每周菜单历史、按菜品推荐楼层，并在工作日午餐/晚餐时段向已安装“吃饭”应用
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

伴侣端的“吃饭”应用连接 `ws://<服务器地址>:8788/v1/meals/ws`，健康检查在
`/healthz`。

## 写入菜单

本机用 `POST /v1/meals/update` 写入一周菜单，`GET /v1/meals/current` 与
`GET /v1/meals/weeks` 读取历史；`POST /v1/meals/remind?meal=lunch|dinner`
手动触发一次提醒。

抓取一周菜单 JSON 之后：

```bash
python3 update-menu.py /path/to/week.json
```

同一周的不同日期会合并，最多保留 52 周历史。服务按 Asia/Shanghai 时区在工作日
12:10、18:10 广播；只有在线且已安装“吃饭”的客户端会收到 Passport 全局卡片，
客户端收到周菜单后还会预排本地系统通知。

## 配置

`MEAL_BUILDING` 决定这个服务只接受哪一栋楼的菜单。**不设就不校验**，菜单文件
里写什么就是什么。

⚠ 不要把具体的楼名写回代码里。这是公开仓库，写死等于把部署者在哪儿上班一起
公开了 —— 而且对别人也没用，他们的食堂不叫这个名字。

## 路径

`-state <路径>` 指定菜单历史的持久化位置，给 `launchd`、`systemd` 或专用
服务账号用。
