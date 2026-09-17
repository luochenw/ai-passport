<p align="right">
  <a href="README.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# ByteDance Canteen service

Stores weekly canteen menus, recommends a floor per dish, and broadcasts
weekday lunch/dinner reminders to connected companion clients that have the
meal application installed. Menu history lives outside the repository; on macOS
it defaults to `~/Library/Application Support/folotoy/meal-menu.json`.

**Its own binary on its own port.** This used to be a handful of
`/v1/meals/*` routes inside the walkie service. They were split because the two
share no state, and bundling them meant a change to the menu parser restarted
everyone's walkie.

## Run

```bash
cd services/meal
go run . -listen 0.0.0.0:8788
```

On macOS, install it as a persistent login service:

```bash
./install-macos.sh
```

The companion app's ByteDance Canteen application connects to
`ws://<server-address>:8788/v1/meals/ws`; health checks are at `/healthz`.
The settings field also accepts `<server-address>:8788`; the client supplies
the `ws://` scheme and WebSocket path. On iPhone, `127.0.0.1` means the phone,
so use an address reachable from the phone. With only a public IP, enter an
address such as `203.0.113.8:8788`; the client connects over plaintext
`ws://`, which is intended for the current test deployment.

Set a separate shared token when exposing the service publicly:

```bash
MEAL_SHARED_TOKEN='replace-with-a-long-random-token' go run . -listen 0.0.0.0:8788
```

When `MEAL_SHARED_TOKEN` is set, WebSocket clients must send the same `token`
in their first `join` message. The companion stores this value only in the
system Keychain. An empty server token disables authentication.

## Ingesting menus

Local ingestion uses `POST /v1/meals/update`; `GET /v1/meals/current` and
`GET /v1/meals/weeks` expose the stored history, and
`POST /v1/meals/remind?meal=lunch|dinner` fires one reminder by hand.

With a shared token enabled, both GET endpoints use Bearer authentication:

```bash
curl -H 'Authorization: Bearer replace-with-a-long-random-token' \
  http://127.0.0.1:8788/v1/meals/current
```

Local update and manual-reminder endpoints remain loopback-only and do not use
the Bearer token.

After capturing a weekly JSON:

```bash
python3 update-menu.py /path/to/week.json
```

The service merges days into the same week, keeps up to 52 weeks of history,
and sends weekday reminders at 12:10 and 18:10 Asia/Shanghai time. Only online
clients that report the meal application as installed receive the realtime
global card; clients also schedule local notifications after receiving a week.

## Configuration

`MEAL_BUILDING` decides which building's menus this service accepts. **Leave it
unset and no check is applied** — whatever the menu file says is taken as-is.

Set both variables below to enable direct Aplus collection. The service syncs
once at startup and every 30 minutes afterward:

```bash
APLUS_SESSION_ID='<the session_id value only>'
APLUS_BUILDING_CODE='<building code>'
```

`APLUS_POLL_INTERVAL=1h` changes the interval. Credentials are read only from
the environment and are never written to menu state or logs. `session_id` is
an opaque server-side session, so its exact expiry cannot be derived locally.
Network and ordinary API failures are not treated as authentication expiry.
The systemd deployment includes `update-aplus-session.sh`, which reads a new
value without terminal echo, updates the protected environment file, and
restarts only the canteen service.

Set a Feishu custom bot webhook as `APLUS_TOKEN_NOTIFY_URL=https://...`. An HTTP
401/403 or an explicit logged-out/expired-session API response then sends one
Feishu text message. A successful menu sync resets the notification latch. The
request uses Feishu's webhook protocol:

```json
{
  "msg_type": "text",
  "content": {
    "text": "Aplus \u767b\u5f55\u6001\u5df2\u5931\u6548\uff0c\u8bf7\u5237\u65b0 APLUS_SESSION_ID\n\u65f6\u95f4\uff1a2026-09-08T12:00:00+08:00"
  }
}
```

The service checks both the HTTP status and Feishu response `code`. The URL is
read only from the environment and is never written to state or logs.
`APLUS_TOKEN_NOTIFY_URL` also accepts `ws://`/`wss://` for the generic JSON
event. Other protocols can replace `aplusAuthNotifier` without changing menu
collection.

⚠ Do not hard-code a specific building back into the source. This is a public
repository: hard-coding one publishes where the operator works, and it is
useless to everyone else, whose canteen has a different name.

## Paths

`-state <path>` sets where menu history is persisted, for `launchd`, `systemd`
or a dedicated service account.
