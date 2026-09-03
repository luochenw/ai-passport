<p align="right">
  <a href="README.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# Local Companion Service

This service provides room membership, half-duplex floor control, realtime
audio forwarding, and optional Apple Push to Talk wake notifications. It keeps
all state in memory and never records audio.

It also stores weekly meal menus outside the repository and broadcasts weekday
lunch and dinner reminders to connected companion clients that have installed
the meal application. Menu history defaults to
`~/Library/Application Support/folotoy/meal-menu.json` on macOS.

## Run

```bash
cd services/walkie-server
go run . -listen 0.0.0.0:8787
```

On macOS, install the persistent local service with:

```bash
./install-macos.sh
```

The companion app connects to `ws://<server-address>:8787/v1/ws`. Health checks
are available at `/healthz`.

Meal clients use `ws://<server-address>:8787/v1/meals/ws`. Local menu ingestion
uses `POST /v1/meals/update`; `GET /v1/meals/current` and
`GET /v1/meals/weeks` expose the stored menu history. Local manual reminder
checks use `POST /v1/meals/remind?meal=lunch|dinner`.

Which restaurant this service accepts menus for is set by the `MEAL_BUILDING`
environment variable at deploy time; leave it unset and no check is applied —
whatever the menu file says is taken as-is. Submit a captured weekly JSON with:

```bash
python3 update-menu.py /path/to/week.json
```

The service merges days into the same week, keeps up to 52 weeks of history,
and sends weekday reminders at 12:10 and 18:10 Asia/Shanghai time. Only online
clients that report the meal application as installed receive the realtime
global card; clients also schedule local notifications after receiving a week.

Set `WALKIE_SHARED_TOKEN` to require the same pre-shared token from every
client. Do not place the token in this repository.

iOS Push to Talk registrations are stored outside the repository at the
platform user-config location. Override it with `-state <path>` when the service
runs under `launchd`, `systemd`, or a dedicated service account.

## iOS lock-screen wake

Foreground and already-running clients work without Apple credentials. To wake
an iPhone for incoming Push to Talk audio, configure all of these environment
variables:

```text
WALKIE_APNS_KEY_PATH
WALKIE_APNS_KEY_ID
WALKIE_APNS_TEAM_ID
WALKIE_APNS_BUNDLE_ID
WALKIE_APNS_PRODUCTION=0
```

The key path must point to an Apple `.p8` provider key with Push to Talk
permission. Use `WALKIE_APNS_PRODUCTION=1` for production APNs.

The server sends no audio through APNs. The notification only wakes the app;
audio remains on the configured WebSocket connection.

The user must open the iOS companion app in the foreground once, install or
reconnect the walkie-talkie app, and grant the requested permissions. iOS only
allows a new Push to Talk channel to be joined through foreground user action.
After that, the system may suspend the app and disconnect its ordinary network
socket; an incoming Push to Talk notification wakes it and this client
reconnects to the local WebSocket service. The server retains a short audio
pre-roll for that reconnect.

No iOS app can override a user's force-quit choice. If the user swipes the app
away, reopen it before expecting lock-screen delivery again. APNs delivery also
requires internet access from both the iPhone and the local server, even though
the audio service itself remains on the local network.
