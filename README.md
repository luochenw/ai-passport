<p align="right">
  <a href="README.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# AI Passport — companion-app architecture

A derivative of [FoloToy/ai-passport](https://github.com/FoloToy/ai-passport)
(MIT) that moves application logic off the device.

The stock firmware runs each feature on the ESP32-C3 itself. This fork keeps
the device as a **display terminal** and runs the applications on a paired
Mac or iPhone, which pushes screens over BLE as short text descriptions:

```
TWalkie-talkie          title
LRoom   local           a body row
LOnline 2               another row
HHold DOWN to talk      footer
W1                      this screen accepts push-to-talk
```

The firmware knows nothing about any particular application — it renders rows,
reports key events, and stays out of the way.

## Why

An ESP32-C3 with 8 MB of flash and no PSRAM cannot hold many features at once,
and every new one costs a firmware flash. Moving the logic to a machine that
already has the network, the disk and the language runtimes means a new
"device app" is a Swift type conforming to `RemoteApp` — no firmware change,
no reflash, no partition budget.

The cost is honest and worth stating: **the device does nothing useful on its
own.** Without a paired computer it shows a home screen and a status bar.

## What is here

| Path | |
| --- | --- |
| `main/` | Firmware: BLE hub, remote-UI renderer, resident status bar, global notifications, Wi-Fi manager, OTA |
| `mac-relay/` | Companion app (macOS + iOS, one SwiftUI target). `Shared/` compiles for both; `macOS/` holds what iOS genuinely cannot do |
| `services/walkie-server/` | Go WebSocket server for the walkie-talkie: rooms, half-duplex floor control, realtime audio forwarding. In-memory, records nothing |
| `skills/`, `docs/`, `AGENTS.md` | Conventions and traps, for humans and for AI assistants |

Two applications ship as examples: a **Codex session browser** and a
**LAN walkie-talkie** (device microphone and speaker, push-to-talk on the
down key).

## Build

```bash
# Firmware (ESP-IDF 5.5.3)
idf.py build && idf.py -p /dev/cu.usbmodemXXXX flash

# Companion app
mac-relay/build.sh          # macOS
mac-relay/install-ios.sh    # iOS: generate project, sign, install, launch

# Everything the CI gate runs
tools/validate.sh
```

`AGENTS.md` is the entry point for conventions — including a list of traps that
each cost real debugging time (LVGL ellipsis needing an explicit height, the
NimBLE host task not holding the LVGL lock, manual light sleep killing BLE and
USB-CDC, and others).

## Status

Firmware, both app targets and the Go service build clean, host tests pass, and
the notification path is verified on hardware. The walkie-talkie has had less
device time than the rest. iOS Push to Talk entitlements are **off by default**
because free Apple developer accounts cannot sign them — set `WALKIE_PTT=1` if
you have a paid team with Apple's PTT authorization.

## License

MIT, inherited from the upstream project — see [`LICENSE`](LICENSE).
Upstream copyright is retained; the additions in this repository are offered
under the same terms.
