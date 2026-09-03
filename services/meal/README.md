<p align="right">
  <a href="README.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# Meal service

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

The companion app's meal application connects to
`ws://<server-address>:8788/v1/meals/ws`; health checks are at `/healthz`.

## Ingesting menus

Local ingestion uses `POST /v1/meals/update`; `GET /v1/meals/current` and
`GET /v1/meals/weeks` expose the stored history, and
`POST /v1/meals/remind?meal=lunch|dinner` fires one reminder by hand.

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

⚠ Do not hard-code a specific building back into the source. This is a public
repository: hard-coding one publishes where the operator works, and it is
useless to everyone else, whose canteen has a different name.

## Paths

`-state <path>` sets where menu history is persisted, for `launchd`, `systemd`
or a dedicated service account.
