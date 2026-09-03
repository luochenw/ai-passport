<p align="right">
  <a href="AGENTS.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# Repository Guidelines for AI Agents

This file is the only mandatory entry point for AI-assisted work in this repository. Read task-specific documents from the routing table below; do not load every README by default.

## Project and safety baseline

- Target: ESP32-C3, 8 MB Flash, no PSRAM, ESP-IDF 5.5.3.
- Preserve mini-program BLE install compatibility: the 3 MB application limit,
  `cardid` at `0x356000`, permanent Recovery at `0x700000`, and the five-second
  UP-key bootloader hook are mandatory template contracts.
- Preserve existing user changes. Start with `git status --short --branch`; never overwrite or clean unrelated files.
- Hardware facts follow this priority: product specifications and measured results → `components/bsp/include/bsp_pins.h` → BSP headers and implementation → hardware guide → README/demo code. If a task requires a hardware detail not defined by these sources, ask the user instead of guessing.
- Reusable board logic belongs in `components/bsp`; pages, state machines, animations, and application tasks belong in `main`.
- LVGL is not thread-safe. Code outside the LVGL task must hold `bsp_lvgl_lock()` while accessing LVGL objects.
- Button callbacks must stay non-blocking. Audio, storage, networking, and other slow operations belong in worker tasks.
- A demo must stop every task, timer, callback, and event handler that can access its UI before deleting the screen.
- Keep testable state machines, protocols, timing, and layout calculations independent from ESP-IDF/LVGL and cover them with host tests.
- Never commit credentials, device QR secrets, private keys, personal data, or unsanitized logs.
- Every maintained Markdown document uses English at its default `.md` path and Simplified Chinese in a paired `.zh_CN.md` file. Keep both versions aligned and retain reciprocal language links.

## Task-specific context routing

| Task | Read before editing |
| --- | --- |
| Any code change | `docs/development/ai-guide.md`, relevant headers and neighboring implementation |
| Environment bootstrap or missing toolchain | `docs/development/engineering/environment-setup.md` |
| BSP, pins, buses, display, audio, battery | `docs/hardware-design/AI_HARDWARE_DEVELOPMENT_GUIDE.md`, `components/bsp/include/bsp_pins.h` |
| Demo or menu | `main/demo.h`, `main/main.c`, the nearest `main/demo_*.c` implementation |
| Build, test, dependencies, partitions | `docs/development/engineering/build-and-test.md`, `docs/development/engineering/ble-recovery-compatibility.md`, `sdkconfig.defaults`, `partitions.csv` |
| CI or release | the matching file in `docs/development/ci/CI-*.md` and `.github/workflows/` |
| Project completion | `docs/development/release/project-completion.md` (then the `issue-suggestions` or `experience-pr` skill) |
| Documentation | `docs/contribution/doc-conventions.md`, `docs/README.md` |
| Commit or PR | `docs/contribution/commit-and-pr.md` |
| Companion app, device apps, notifications | `mac-relay/FoloCodexRelay/Shared/RemoteApps.swift`, `main/remote_ui.h`, `main/ui_notify.h` |

Use `docs/README.md` for the product overview and the documentation index. For the detailed AI development workflow — context setup, source-of-truth priority, application/BSP boundary, runtime invariants, material placement, and delivery format — read `docs/development/ai-guide.md`. Fork-specific workflow is in `docs/fork-guide.md` and is not required for ordinary upstream development.

## Companion app (`mac-relay/`)

The device is a **display terminal**: application logic runs on the Mac/iPhone
and is pushed over BLE as screen-description text. A "device app" is a Swift
type conforming to `RemoteApp`, not firmware.

- **`Shared/` must compile for iOS.** The split is by *capability*, not by
  platform name. Anything the iPhone genuinely cannot do — spawning a process,
  reading `~/.codex/sessions` — goes in `macOS/`. Verify with:

  ```bash
  SDK=$(xcrun --sdk iphoneos --show-sdk-path)
  swiftc $(ls mac-relay/FoloCodexRelay/Shared/*.swift) -o /tmp/ios-check \
    -target arm64-apple-ios17.0 -sdk "$SDK" \
    -framework CoreBluetooth -framework Foundation -framework Speech \
    -framework AVFoundation -framework SwiftUI
  ```

- **Do not lift an app's internals into the framework.** Whether an app takes
  user-visible parameters is that app's own design decision. Adding config
  schemas, settings forms, or per-app fields to the `RemoteApp` protocol has
  been explicitly rejected.
- **Secrets never reach persistent storage in plaintext** — not the repository,
  not logs (record key names, never values), and not `UserDefaults`, whose
  backing plist is world-readable to any process running as the user. The
  established precedent is the Wi-Fi password in `DeviceConfig.swift`: memory
  only, never persisted, never logged.
- **Only the foreground app may push a screen** (`RemoteAppHost` guards on
  `current === app`). A background app that needs the user's attention calls
  the injected `notify?(_:)`, which reaches the device through the `cmd.notify`
  channel and draws a pinned card on `lv_layer_top()`.
- **Every device gets a fully independent `DeviceSession`** — its own
  `RemoteAppHost`, its own freshly constructed app instances, its own browsing
  position, and its own identity on the walkie server. Three connected devices
  means three sessions all running; the UI merely **picks one to display**
  (`SessionRouter.selectedID`). The test: anything describing *this device or
  the person in front of it* belongs in `DeviceSession`; anything describing
  *this Mac's radio, what this Mac has installed, or a once-per-system
  resource* stays in `AppCore`.
- **App instances cannot be shared across sessions.** `RemoteApp`'s
  `requestPush` and `notify` are single-slot assignments, so a shared instance
  lets the second host's injection **silently overwrite** the first: that app
  on the first device stops pushing anything, with no error. The same trap bit
  `MealClient.onSnapshot`, which is now multicast.
- **Every relay callback carries a device id; every send takes an explicit
  target.** Per-device callbacks (characteristic discovery, notifications,
  write callbacks) must resolve `links[p.identifier]`. A set of `active?.xxx`
  compatibility proxies used to live here and has been **deleted entirely**:
  leave one behind and the next change quietly regresses to single-device, with
  no compiler complaint — it builds, logs nothing, and only shows up with two
  real devices.
- **There is no "active device" in the relay any more.** `displayedID` only
  paints the UI and takes part in no routing. The old `makeActive` stole focus
  on any key press: a colleague pressing a button on device B yanked the window
  you were looking at.
- **Walkie identity must be per device.** The server evicts a same-`clientId`
  connection in the same room (`services/walkie/main.go:296-308`), so
  two devices sharing one id kick each other every two seconds.
  `walkie.client-id.<deviceUUID>` / `walkie.name.<deviceUUID>` are per device;
  server address, room and the keychain token stay **global** (the token is a
  room password, compared once at join, `main.go:286`). The default nickname is
  derived from the advertised name, or the roster shows two identical rows.
- **⚠ Never broadcast a walkie CONTROL frame.** On the device `CONTROL_START`
  means "*you* start transmitting" (`main/walkie_audio.c:261` sets
  `s_tx_requested` and opens the mic), not "someone is speaking". Broadcasting
  it opens every microphone in the room. The playback side needs no control
  frame at all — `downlink_access_cb` plays whatever arrives.
- **Do not loop A's uplink back to B locally.** Each device is its own client
  on the server, which already relays A's speech to B (`main.go:464` excludes
  only the speaker). A local loopback on top is double audio plus echo, and it
  bypasses the server's floor arbitration — A's voice reaches B's speaker even
  when A never got the floor.
- **The installed-app list is per device** (`remote.installed.<deviceUUID>`,
  seeded once from the single-device `remote.installed`). The device computes
  `REMOTE_EVT_OPEN` indices from *its own cached copy*, so what we send and what
  indices mean must be the same list, or a pick opens the wrong app.
- Screen-text invariants: titles and single-line rows must be collapsed with
  `DeviceText.fitOneLine`; one line budgets 26 half-widths (CJK counts as 2).
- `RemoteAppHost` owns a serial queue; `@Published` may only be mutated on the
  main thread.

Build and install:

```bash
mac-relay/build.sh        # macOS app
mac-relay/install-ios.sh  # iOS: generate project, sign, install, launch
```

## Device-side traps that cost real debugging time

- **`LV_LABEL_LONG_DOT` does nothing without an explicit height.** Ellipsis is
  applied only when the text is taller than the label; the default
  `LV_SIZE_CONTENT` grows to fit, so the condition never holds.
- **`lv_font_ui_cn_14.line_height` is 27, not 14.** Row-height arithmetic that
  assumes the point size silently overlaps the footer.
- **`cmd.*` config writes and BLE callbacks run on the NimBLE host task, which
  does not hold the LVGL lock.** Copy the payload, set a flag, and let an
  `lv_timer` do the drawing (`ui_statusbar.c` and `ui_notify.c` both do this).
- **Rapid consecutive notifies exhaust the NimBLE mbuf pool** (`rc=6`,
  `BLE_HS_ENOMEM`) and silently drop data. Batch, and retry on ENOMEM.
- **`CONFIG_BT_NIMBLE_MAX_CONNECTIONS=1`, and the device stops advertising once
  connected.** While one endpoint holds the link, the other cannot even
  discover the device.
- **Manual `esp_light_sleep_start()` ignores power-management locks** and kills
  BLE, Wi-Fi, and USB-CDC. Screen-off and light sleep are therefore separate
  steps in `idle_sleep_check()`; only the second one requires that no radio
  link exists.

## Services (`services/`)

`walkie-server` is a stateful Go WebSocket service: room membership and
half-duplex floor control live in one process's memory (`rooms map[string]*room`
behind a mutex). It is **not** a candidate for FaaS — independent function
instances would each hold a disjoint set of rooms, so two clients could join
"the same" room and never hear each other. A long-running container is the
correct deployment target.

## Required validation and delivery

Run the smallest relevant check while iterating, then run the complete gate before delivery:

```bash
./tools/validate.sh --static    # repository checks + host tests
./tools/validate.sh --firmware  # ESP-IDF build + merged-image verification
./tools/validate.sh             # complete gate
```

The complete gate requires an activated ESP-IDF 5.5.3 environment. Do not describe a successful build as hardware validation. Final delivery must report these fields separately:

```text
Build: PASS / FAIL / NOT RUN
Host tests: PASS / FAIL / NOT RUN
Device tests: PASS / FAIL / NOT RUN
Unverified: remaining board, instrument, or user checks
```

Create commits and push only when the user requests them or the active workflow explicitly requires them. Record user-visible changes in `docs/CHANGELOG.md`; internal refactors, CI maintenance, typo fixes, and generated-file refreshes do not require a changelog entry.

Community guidance is in `.github/CONTRIBUTING.md`, `.github/CODE_OF_CONDUCT.md`, `.github/SECURITY.md`, and `.github/SUPPORT.md`.
