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
"device app" is a **JSON manifest** — screens, rows and key bindings as data,
fetched from GitHub at launch — plus a small native **capability** for the part
a manifest cannot describe (realtime audio, a subprocess, file polling). No
firmware change, no reflash, no partition budget.

Applications require a paired companion. Local Settings remain available on
Passport: Wi-Fi scanning and network selection, startup sound (off by default),
volume, brightness, firmware updates, and trusted connections. Settings starts
with Wi-Fi; the application store stays on the home screen. For a secured
network, enter its password in the companion's Wi-Fi page and write it to the
device. Passwords are not persisted or logged by the companion.

## What is here

| Path | |
| --- | --- |
| `main/` | Firmware: BLE hub, remote-UI renderer, resident status bar, global notifications, Wi-Fi manager, OTA |
| `mac-relay/` | Companion app (macOS + iOS, one SwiftUI target). `Shared/` compiles for both; `macOS/` holds what iOS genuinely cannot do |
| `services/walkie/` | Go WebSocket server for the walkie-talkie (:8787): rooms, half-duplex floor control, realtime audio forwarding. In-memory, records nothing |
| `services/meal/` | Go service for ByteDance Canteen (:8788): weekly menus, floor recommendation, scheduled reminders |
| `mac-relay/AppManifests/` | The manifests themselves, plus `registry.json` — what the companion fetches and verifies by sha256 |
| `skills/`, `docs/`, `AGENTS.md` | Conventions and traps, for humans and for AI assistants |

Three applications ship as examples: a **Codex session browser**, a
**LAN walkie-talkie** (device microphone and speaker, push-to-talk on the down
key) and a **canteen menu**. All three are manifests — the native half of each
is only what the manifest cannot express.

## Trusted connections

The Bluetooth advertising name remains the stable hardware identifier
`FoloPassport-XXXX`; a user alias is stored separately on the Passport. Before
adding a new iPhone or Mac, open **Connection Management → Add Companion** on
the Passport, select the discovered Passport in the companion app, compare the
six-digit Bluetooth code, and confirm it with the Passport OK button. Bonded
companions reconnect silently afterward. Unknown clients cannot use settings,
screens, audio, or firmware update services.

One companion can keep independent sessions with several Passports. One
Passport deliberately accepts only one companion at a time. The current owner
is sticky; walking out of range releases it for another trusted companion, and
**Connection Management** provides an explicit handoff when both companions
are nearby. Firmware updates and active audio sessions cannot be handed off.

The root `VERSION` file is the firmware release source. Development builds add
the Git revision and dirty marker. The running and bundled versions are shown
in the companion firmware panel, and the Passport firmware page shows its
running version without changing the Bluetooth advertising name.

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

Firmware, both app targets and both Go services build clean, host tests pass,
and the following are verified on hardware: four devices connected at once with
one independent session each, walkie-talkie audio between them, and a firmware
install over BLE (2 MB in 88 s). Manifests are fetched from GitHub at launch and
verified by sha256 before they are cached; a failed fetch falls back to the
built-in copy. iOS Push to Talk entitlements are **off by default**
because free Apple developer accounts cannot sign them — set `WALKIE_PTT=1` if
you have a paid team with Apple's PTT authorization.

## Attribution

GitHub ranks contributors by commit count, which is misleading here: upstream's
history spans a hundred-odd commits while the work in this repository landed in
a handful. `git blame` over the current tree tells the real story
(generated font tables excluded):

| Path | This repository | Upstream |
| --- | ---: | ---: |
| `main/` — firmware application layer | **7,203** | 952 |
| `mac-relay/` — companion app | **10,186** | 0 |
| `services/` — walkie-talkie and ByteDance Canteen servers | **2,410** | 0 |
| `tests/` | **1,184** | 83 |
| `tools/` | **630** | 522 |
| `components/` — board support | 44 | **953** |
| `docs/` — hardware guides | 64 | **5,954** |

What genuinely comes from [FoloToy/ai-passport](https://github.com/FoloToy/ai-passport):
the board-support layer (pin map, bus setup, display and audio init) and the
hardware documentation. Those are load-bearing — this fork would not boot
without them, and their authors are kept in the commit history for that reason.

Everything above the board layer — the resident BLE hub, remote-UI renderer,
status bar, notifications, Wi-Fi manager, OTA, the whole companion app and the
walkie-talkie service — was written here.

## License

MIT, inherited from the upstream project — see [`LICENSE`](LICENSE).
Upstream copyright is retained; the additions in this repository are offered
under the same terms.
