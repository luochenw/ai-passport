<p align="right">
  <a href="capabilities.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# Capabilities

An "app" is split in two:

| | What it is | Where it comes from |
| --- | --- | --- |
| **Manifest** | JSON: how many screens, which rows, which key runs which action | Data, fetched from GitHub at launch |
| **Capability** | A Swift type: the part a manifest cannot describe | Compiled into the app; only a code change adds one |

The split is forced: Swift is AOT-compiled and iOS forbids downloading and
running code (App Store 2.5.2). "Update apps from GitHub" can therefore only
mean **fetching data**.

## Does a new app need a code change

One question decides it: **does the capability it needs already exist?**

| Case | What to do |
| --- | --- |
| Reuses an existing capability | Drop a manifest in `mac-relay/AppManifests/`, run `tools/gen_manifest_registry.py`. **No code change, no reinstall** |
| Needs a new platform ability | Write a capability (below), then the manifest |

The second case is an iOS constraint and cannot be avoided. The first case used
to require a code change too -- that was an implementation gap, now fixed:
`DeviceSession` iterates every manifest and looks the capability up in a table,
instead of three hardcoded `ManifestStore.load` calls.

## What exists today

The `"capability"` field in a manifest takes one of these ids.

### `walkie` -- realtime audio

Device microphone and speaker over BLE to a WebSocket server, half-duplex floor
control.

| Readable from a manifest | Meaning |
| --- | --- |
| `room` / `members` | Room name, how many are online |
| `connected` | Is the server reachable |
| `transmitting` | I am talking right now |
| `speaker` | Who is talking (empty when nobody is) |
| `status` | One line of human-readable state |

Actions: `beginTalk` / `endTalk` (bind them to `press` / `release`).
Configuration: server and room live in the companion's settings pane, the shared
token lives in the keychain.

### `meal` -- weekly canteen menu

Polls the `services/meal` HTTP/WebSocket service and broadcasts reminders.

| Readable from a manifest | Meaning |
| --- | --- |
| `installed` / `connected` | Is it installed on this device, is the service up |
| `period` / `date` / `multiDay` | Lunch or dinner, which day, is there more than one day |
| `status` | One line of human-readable state |

Actions: `prevDay` / `nextDay` / `togglePeriod`.

### `codex` -- subprocess and local files (macOS only)

Spawns the `codex` CLI and scans `~/.codex/sessions`. iOS can do neither, so the
app reports itself unavailable there, with the reason.

| Readable from a manifest | Meaning |
| --- | --- |
| `screen` | Which screen to show (workspaces / sessions / reading) |
| `workspaces` / `sessions` / `lines` | The three kinds of list data |
| `wsSel` / `sessSel` | Index of the selected row |

Actions: `up` / `down` / `open` / `back` / `prevPage` / `nextPage`.

### `http` -- poll a JSON endpoint (generic)

Knows nothing about any domain: it GETs a JSON document on a timer and puts the
**whole response tree** under `data`. Weather, CI status, a sensor at home, your
own API -- all the same shape.

| Readable from a manifest | Meaning |
| --- | --- |
| `connected` | Did the last fetch succeed |
| `status` | One line of state, or the error |
| `data` | The entire JSON response |

Actions: `refresh`.

Configuration lives in `~/.folotoy/apps/<manifest id>.json` and **never enters
the repository**:

```json
{
  "url": "https://example.invalid/api/status",
  "intervalSeconds": 30,
  "headers": { "Authorization": "Bearer ..." },
  "certificateSHA256": "SHA-256 of a self-signed leaf certificate, optional"
}
```

With `certificateSHA256` set, only that one certificate is trusted. Private
deployments are commonly reached by IP with a self-signed certificate, where
system validation cannot pass -- pinning one certificate is far safer than
disabling validation, which opens the door to any machine in the middle. In a
manifest:

```json
{ "text": "CPU  {{data.cpu.percent|fixed:1}}%" },
{ "each": { "path": "data.disks", "body": [ { "text": "{{item.name}}" } ] } }
```

`mac-relay/AppManifests/status.json` is a worked example to copy.

## What is missing

These are not possible today and need a new capability first:

- **Writes.** Every capability is read-only (the walkie floor request is the one
  exception). "Press a key to turn the light on" cannot be built -- `http` only
  ever GETs.
- **Local storage.** A manifest cannot write state back, so a todo list or a
  counter cannot be built.
- **Timers and clocks.** Countdowns, pomodoros. Purely local, no network needed,
  and not there.
- **Generic list navigation.** Windowing, the selection marker and the "N more"
  hints are hardcoded inside `codex`; another manifest cannot reuse them and has
  to assemble a different-looking list out of `each`.
- **Running a command (macOS only).** `codex` already spawns a subprocess, but
  only for itself.

## Adding a capability

1. Write a type under `mac-relay/FoloCodexRelay/Shared/Apps/<name>/` conforming
   to `AppCapability` (`static let id`, `state()`, `perform(_:)`, `overlay`)
2. Add one line to the capability table in `DeviceSession`
3. Write a manifest that uses it

Keep the interface **narrow and stable**. Manifests are fetched from the network
and may be older or newer than the companion; if a capability's interface churns,
every manifest has to follow, and "update apps from the network" loses its value
immediately. Prefer fewer, dumber capabilities.

`tools/gen_manifest_registry.py` extracts the real capability ids from the
`*Capability.swift` files, so a manifest naming a capability that does not exist
fails there -- otherwise the symptom is that the app silently never appears on
the device, with no error anywhere.
