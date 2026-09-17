---
name: build-an-app
description: Build an app for the FoloToy AI Passport. Apps run in the companion Mac app; the device is a display terminal — no C, no firmware flashing, no way to brick the device. Covers the hard boundaries, what the platform already gives you, how to verify without hardware, and the rare cases that do need firmware changes.
---

<p align="right">
  <a href="SKILL.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# Build an AI Passport App

By the end you should be able to answer three questions: **what an app actually is, which lines must never be crossed, and how to get yours installable by others.**

---

## 1. What an app is

**One app = one Swift type in the companion app that conforms to `RemoteApp`.**

Not firmware, not a plugin, not a script. It runs on the computer; the device is its screen and three buttons.

```
   Computer (companion app)                 Device
┌───────────────────────┐   screen text   ┌──────────────┐
│  your app             │ ──────────────► │  draws it    │
│  · fetches data       │                 │              │
│  · computes state     │ ◄────────────── │  sends keys  │
│  · decides what shows │   key events    └──────────────┘
└───────────────────────┘
```

Which means:

* **apps take no space on the device** — install as many as you like (8 max, see §2.1), switching is instant;
* **no Wi-Fi, HTTP or JSON needed** — all of that happens on the computer side;
* **no C, no ESP-IDF**, and **no way to brick the device**;
* change a line, restart the companion app, done — no two-minute reflash.

### It used to be different

The original design was "one app = one complete firmware image, written into the `appslot` partition, reboot into it". That path actually worked, but the cost made it untenable: every app carried its own copy of LVGL, the fonts and the BLE stack, so a panel showing a few numbers was **1.9MB** — 95% of it identical infrastructure. `appslot` holds exactly one image, so you could only have one app, and switching meant a two-minute reflash.

This history matters because the repo still contains that machinery (`appslot` partition, `demo_appstore.c`, the companion app's **Firmware** tab). **That path now exists solely to update the device firmware itself, which is a different thing from installing an app.** Don't conflate them.

---

## 2. Hard boundaries

**Every item below is a mistake that has actually been made, not a style preference.**

### 2.1 What fits on one screen

| Constraint | Limit | What happens if you exceed it |
|---|---|---|
| Rows per screen | 12 | extra rows are **silently dropped** |
| Bytes per row | 64 (UTF-8; CJK is 3 bytes/char ≈ 21 chars) | truncated |
| Bytes per screen | 1000 | cut at the last complete row |
| Installed apps on the home screen | 8 | the 9th installs but is **invisible on the device** |

That last one deserves care: the device's home-screen slots are a fixed array, and an over-long manifest is truncated without an error. `RemoteAppHost.maxInstalled` in the companion app blocks it first and tells the user why. **Changing that number requires changing the firmware's `REMOTE_UI_MAX_APPS` too** — and there is a `_Static_assert` in the firmware that fails the build if the list no longer fits on screen.

### 2.2 Three buttons, and the enum values are not guessable

```swift
enum RemoteButton: UInt8 { case up = 0; case down = 1; case ok = 2 }
enum RemoteButtonEvent: UInt8 {
    case press = 0; case click = 1; case double = 2
    case long = 3;  case hold = 4;  case longUp = 5
}
```

These must match `bsp_btn_t` / `bsp_btn_ev_t` in `components/bsp/include/bsp_button.h` **value for value**.

⚠ This was gotten wrong once: numbered by the intuitive "up/ok/down" and "click/long/double" order, while the firmware actually uses "up/down/ok" and "press/click/double/long/hold". The result was the down and OK buttons swapped and double-press read as long-press — **with no error of any kind**, just buttons doing the wrong thing. `tests/test_button_enum_sync.c` now greps this Swift source and compares it against the C header, so it can't drift again.

Also note: **long-pressing OK is intercepted by the device as "go back one level"** and never reaches your app. For in-app "back", use double-click OK.

### 2.3 `render()` must be cheap and non-blocking

`render()` is called repeatedly. **Do not make network requests, read large files, or wait on locks inside it.**

Fetch in the background, then call `requestPush()` when the data lands:

```swift
private func refresh() {
    URLSession.shared.dataTask(with: req) { [weak self] data, _, _ in
        self?.queue.async {
            self?.rows = parse(data)     // update your state first
            self?.requestPush?()         // then ask the framework to redraw
        }
    }.resume()
}
```

`render()` and `handleKey()` run on the framework's serial queue; your timers and network callbacks run on other queues — **both touch your state, so lock it yourself** (an `NSLock` or your own serial queue both work).

### 2.4 Credentials never enter the repo

This repo has a secret scanner (`tools/check_repo.py`), and community code here is public.

**An app's own parameters (endpoint URLs, account credentials) belong to that app.** Don't spread them onto the companion app's **Config** tab — that page holds only settings that belong to the hardware itself (volume, brightness, Wi-Fi, status bar).

Recommended pattern: read `~/.folotoy/<app>.json` (`chmod 600`) and keep only a value-free description in the repo; put secrets in the keychain (see `WalkieClient` for a worked example). Logs record **key names only, never values**.

### 2.5 Background apps must not push

The framework already blocks this: `requestPush()` only pushes when your app is actually in the foreground. But still stop your own timers — turn them off in `setActive(false)`, or you'll keep making a network request every 5 seconds after the user has left.

### 2.6 The microphone lives on the device and cannot be done for it

Voice is the one capability that must stay in firmware: sampling, ADPCM encoding and chunked streaming all start on the hardware side.

All an app can do is **declare intent**:

```swift
var s = Screen()
s.mic = true          // M1 in the protocol
```

The device then wires "long-press down" to recording on its own, and the audio streams back over the Codex AUDIO channel for transcription. See `CodexApp.swift`.

---

## 3. The screen-description protocol

The computer pushes plain text, one element per line:

```
T<title>              top title
L<text>               one line of body text
B<percent>|<label>    a progress bar (0..100)
S<row>|<style>        optional row color (body/accent/secondary)
H<hint>               bottom key hint
M<0|1>                does this screen accept voice input
```

**Don't hand-write this format** — use `Screen`:

```swift
var s = Screen()
s.title = "Server"
s.text("Overview", style: .accent)
s.text("CPU 12%   RAM 4.2G")
s.bar("Disk", percent: 78)
s.spacer()
s.footer = "up/down page   OK refresh"
```

`Screen` handles newline and pipe escaping for you — hand-built strings drop those easily, and that class of bug shows up on the device as "one line mysteriously doesn't appear".

Styled text keeps its original `L` row and adds optional `S` metadata. Older
firmware ignores `S` and still shows the complete text in the default color;
newer firmware also accepts screens that omit `S`.

**Unrecognized line types are ignored by the device**, never fatal. So when new element types are added later, old firmware simply doesn't show them instead of crashing.

---

## 4. Writing one

Three steps.

### 4.1 Conform to `RemoteApp`

```swift
import Foundation

final class MyApp: RemoteApp {
    let name = "My App"             // shown on the home screen and in the store
    let detail = "one-line summary" // second line in the store list
    var requestPush: (() -> Void)?

    private let queue = DispatchQueue(label: "com.example.myapp")
    private var timer: DispatchSourceTimer?
    private var lines: [String] = []

    func render() -> Screen {
        var s = Screen()
        s.title = name
        for l in lines { s.text(l) }
        s.footer = "OK to refresh"
        return s
    }

    func handleKey(_ b: RemoteButton, _ e: RemoteButtonEvent) -> Bool {
        guard b == .ok, e == .click else { return false }
        refresh()
        return false            // data isn't here yet; redrawing now shows nothing new
    }

    func setActive(_ active: Bool) {
        if active { startTimer() } else { stopTimer() }
    }
}
```

`handleKey`'s return value means "redraw **right now**": selection moved → `true`; started an async refresh → `false` (let `requestPush` handle it when the data arrives).

### 4.2 Register it

One line in `Shared/AppCore.swift`:

```swift
remoteHost.register(MyApp())
```

### 4.3 Add it to the build

Append your file to the `swiftc` line in `mac-relay/build.sh`.

Install and uninstall from the companion app's **Apps** tab, or on the device itself: open the App Store entry on the home screen and press OK.

---

## 5. Verifying

**Most of this can be verified without the device in hand.** That's one of the most practical wins of this architecture.

### 5.1 Run the gate

```bash
./tools/validate.sh --static
```

This runs the repo consistency checks, the button-enum sync check, and the host-side regression test for the app-store logic. If you changed the protocol or the store logic, this will tell you.

### 5.2 Drive your app with no device attached

With the companion app running, write commands to `/tmp/folo_remote_sim` to simulate what the device would do:

```bash
# pick home-screen item 0 (254 = the app store)
echo "open 0" > /tmp/folo_remote_sim

# one key press: btn 0=up 1=down 2=OK, ev 1=click 2=double
echo "key 1 1" > /tmp/folo_remote_sim

# dump the current screen verbatim into the log
echo "dump" > /tmp/folo_remote_sim

# list what's installed
echo "installed" > /tmp/folo_remote_sim
```

The log is at `/tmp/folo_codex_relay.log`. What `dump` prints is byte-for-byte what the device would receive.

### 5.3 Write a host test for your own logic

`tests/test_remote_apps.swift` is a working template: a fake `RemoteApp`, a throwaway `UserDefaults`, and the whole "install → appears on home screen → store stops listing it → uninstall" chain exercised end to end.

The things worth testing are the ones that **fail silently** — a missing row, a manifest that never got pushed, the 9th app quietly dropped. Those take step-by-step trial on real hardware to notice.

### 5.4 Before going to real hardware

- the screen stays within 12 rows even in the longest case;
- no row exceeds 64 bytes, CJK included;
- timers actually stop after leaving the app (check the log);
- disconnect and reconnect Bluetooth — the app recovers on its own;
- no credentials in the repo, none in the logs.

---

## 6. When you do need to touch firmware

**Almost no app does.** Only when you need a hardware capability the device doesn't have yet — a new sensor, a new display element.

If you must, these are hard rules:

### 6.1 Wi-Fi has exactly one owner

`main/wifi_mgr.c` is the only file in the repo allowed to touch `esp_wifi_*` / `esp_netif_*`.

**Never call `esp_wifi_deinit()` or `esp_netif_destroy_default_wifi()`.** Use `esp_wifi_stop()` — it is reversible and idempotent.

Why: `esp_netif_create_default_wifi_sta()` hitting a duplicate if_key **asserts and reboots** rather than returning an error — presenting as an endless boot loop with the serial console scrolling, and very hard to trace. This has actually happened here, caused by two modules each keeping their own "already initialized" flag with no visibility into the other.

### 6.2 There is exactly one BLE stack

Register every GATT service through `ble_hub_register_service()`, and **before `ble_hub_init()`**. Registering later neither works nor errors — it just presents as "the peer can never discover this characteristic".

`BLE_HUB_MAX_SERVICES` / `BLE_HUB_MAX_OBSERVERS` cap at 8, and overflowing is likewise **silently ignored** (one `ESP_LOGE` and nothing else).

### 6.3 The partition table is frozen

The offsets and sizes of `factory` / `cardid` / `recovery` must not change **by a single byte** — they are part of the official mini-program's BLE flashing contract, and changing them costs the user their official un-brick path. `tools/verify_firmware.py` checks them field by field, and also literally checks that the bootloader binary still contains the log line `"UP held: booting permanent recovery"`.

### 6.4 Then run

```bash
./tools/validate.sh --all
```

---

## 7. In one sentence

Writing an app touches none of section 6. **That is the entire point of this architecture**: it decouples "writing an app" from "possibly breaking the device".
