<p align="right">
  <a href="CHANGELOG.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# Changelog

## Unreleased

- Added long-press uninstall for installed apps on the Passport home screen.
  Uninstall requests are applied by the companion and synchronized back through
  the manifest protocol. On iOS 17, trusted Passports now use CoreBluetooth
  state restoration, remembered-peripheral retrieval, and system auto-reconnect
  so a newly advertising device can reconnect while the app is backgrounded
  when iOS permits it.

- Updated the Passport status bar: connected Bluetooth now uses the official
  Bluetooth blue, while connected Wi-Fi keeps the familiar Wi-Fi glyph in white.
  Disconnected radios retain the theme's muted color.

- Renamed the meal application to ByteDance Canteen while preserving existing
  installations and custom icons. Meal and walkie settings now accept a bare
  server IP/host with their default ports, distinguish a missing address from
  an invalid one, and explain public `wss://` deployment. Canteen menus now use
  accent-colored recommendation/outlet headings, indented dish rows, semantic
  pagination with continuation headings, and compact date/page titles.
- Enabled the user-selected IP-only `ws://` deployment mode on iOS. Service
  tokens authenticate clients, while the settings UI continues to identify
  `wss://` as the preferred Internet-facing transport.

- Added on-device Settings with Wi-Fi first and Bluetooth directly below it, a startup-sound subpage with a
  persistent switch (off by default) and independent volume, playback volume,
  brightness, and firmware updates. The application store remains on the home screen. Wi-Fi shows
  networks scanned by Passport; selecting a secured network opens password
  entry in the iOS/macOS companion, which writes the credentials to the device.
- Fixed the undersized housekeeping-task stack used by authentication timeout
  handling, deferred its UI work until initialization finishes, and removed
  manual light sleep while the BLE controller is advertising. Abnormal resets
  skip the startup sound; normal playback now drains silent audio before
  restoring the user's volume to prevent a loud final transient. Firmware
  validation checks the compiled authentication-timeout stack budget.
- Reduced Wi-Fi buffers and disabled throughput-oriented IRAM optimizations to
  make room for Wi-Fi scanning alongside the resident BLE connection on ESP32-C3.
  Network credentials remain managed by the device settings store.
- Freed additional startup RAM for Wi-Fi by allocating the mono audio DMA shape
  from boot and creating OTA/walkie queues and worker tasks only when those
  features are first used. Wi-Fi scan failures now log their exact completion,
  record-read or timeout cause; a scan timeout no longer disconnects an existing
  Wi-Fi link.

- Prevented legacy companion builds from repeatedly monopolizing Passport's
  single BLE connection. Pre-authentication access to feature subscriptions now
  shortens the HELLO grace period, and a legacy peer enters a bounded reconnect
  cooldown with rate-limited probation so a current iPhone or Mac can acquire
  the link. Authentication status formatting no longer exhausts the NimBLE host
  task stack when such a connection is rejected.

- Fixed unreadable companion labels on Passport by using display-safe names and
  supported ASCII status separators. Forgetting a companion now also updates
  the companion app's reconnect state, and an explicit pairing-discovery window
  can repair an obsolete Apple BLE key once before falling back to actionable
  system Bluetooth instructions.

- Added trusted-companion pairing and connection ownership for iOS and macOS.
  Unknown Passports are visible but require an explicit connection attempt and
  physical confirmation on the device; trusted companions reconnect through an
  encrypted BLE bond. iPhone and Mac companion names now have editable defaults
  that update live on Passport. The Bluetooth page retains up to eight paired
  devices and lets the user select, disconnect, or forget one while keeping one
  active BLE link. The companion app also supports per-device aliases and several
  independent Passport sessions without changing the BLE broadcast name.

- Added a single-source firmware version pipeline based on the root `VERSION`
  file. Development builds include the Git revision and dirty-state marker,
  release builds carry the clean version, the device reports its running
  version over BLE, and the iOS/macOS firmware panel distinguishes updates,
  reinstalls, and downgrades. Firmware validation now emits both stable and
  versioned full-image filenames and refreshes bundled size/SHA-256 metadata.

- Fixed iOS BLE firmware updates stalling at the first write-without-response
  window. The device now erases the OTA slot incrementally, the companion uses batches
  that fit the device queue, and both sides clean up an abandoned transfer so
  the device no longer remains stuck on an installation progress screen.

- Fixed the iOS bundle omitting the built-in application manifests. The
  Applications tab now keeps showing the bundled apps when the remote manifest
  registry is unavailable.

- The companion app now gives **every device a fully independent session**:
  its own app instances, browsing position, installed list, device settings
  (volume/brightness/status bar), and its own identity on the walkie server.
  Several devices stay connected and usable at once; the device bar picks
  which one the UI shows.
  Fixed along the way: two devices sharing one walkie clientId were evicted by
  the server and kicked each other every two seconds; firmware chunks sized
  against the "active" device's MTU were silently dropped by CoreBluetooth;
  plugging in a device without the meal app installed tore down another
  device's meal connection and wiped its scheduled reminders; and "rescan" on
  one device's config page undid another device's "disconnect".

- Fixed iOS server-panel requests to self-signed HTTPS endpoints by pinning the
  configured server certificate and limiting the transport exception to that
  host. Dashboard network failures now report actionable URL error codes.

- Added a weekly meal application (which restaurant it accepts is set by
  `MEAL_BUILDING` at deploy time). It keeps weekly menu history, recommends a floor for lunch and dinner,
  and broadcasts weekday reminders at 12:10 and 18:10 only to clients that have
  installed the application.

- Simplified the companion firmware panel to one bundled latest firmware and a
  single update action. Re-updating while the device is running from `appslot`
  now restarts through the factory launcher before safely rewriting `appslot`.

- Added a local-first walkie-talkie application with half-duplex room control,
  realtime BLE audio transport, a local WebSocket relay, and iOS Push to Talk
  integration for supported background and lock-screen delivery. Its companion
  settings open from the walkie-talkie item in the Applications list instead
  of occupying a separate top-level tab.

- Added the supplied 80-byte CW2017 profile for the specified 520 mAh cell, including content/update-flag checks, verified writes, the required restart sequence, and bounded SOC-readiness polling.

- Reorganized the documentation by function area with a dual entry point: the root `AGENTS.md` is now a thin router (hard constraints + task routing only) and the detailed AI workflow lives in `docs/development/ai-guide.md`; `agent-guide.md` was folded in. `docs/development/` gained a second level (`engineering/`, `ci/`, `release/`), and the `plays/` application archive and `experiences/` moved into a `docs/reference/` area with a dedicated README. Removed `docs/software-design/` (empty scaffold); folded the three `assets/{fonts,images,music}/README` leaves into the `assets/` README; flattened the six `project-completion` sub-documents into a single file; and unified each directory to a single README, eliminating every `INDEX` file and a duplicated experience index. All cross-references and bibliographic links were updated; no content was dropped.

- Made mini-program BLE install compatibility a template-level invariant: fixed
  protected `cardid`/Recovery partitions, retained the five-second UP-key
  Recovery boot hook, and added CI validation for merged-image structure,
  partition MD5/ranges, the 3 MB app limit, and protected payload exclusion.
- Documented a release-title convention for multi-app releases: name tags as `v<version>-<app-name>` (e.g. `v0.1.0-voice-keychain`) so the release title carries the version and the app, and confirm the title after the release is published so a release list is scannable by app.
- Added a post-release follow-up workflow: an `issue-suggestions` skill for filing user feedback as issues against the upstream project, an `experience-pr` skill for submitting reusable development experience as a documentation PR, a `docs/experiences/` directory for per-entry experience files, and supporting `project-completion`, `file-issues`, and experience-index documents.
- Simplified the tracked repository root: moved GitHub-recognized community documents into `.github/`, moved the changelog into `docs/`, updated every reference, and added a root-document allowlist to repository checks.
- Repository-wide language policy: every maintained Markdown default `.md` file is English, Simplified Chinese uses a paired `.zh_CN.md`, and both provide language switches. Static checks reject missing peers, missing switches, and Chinese prose in English defaults.
- Phase one of the AI development workflow: streamlined task-based context routing, unified local/CI validation, added PR checks and a template, and committed the dependency lock for reproducible builds.
- PR review fixes: pinned GitHub Actions to full commit SHAs, split build/release jobs by least privilege, disabled persisted sync checkout credentials, added Feature Request and Usage Question forms, clarified private security-report fallback, and corrected stale README, CI-trigger, and branch descriptions.
- Changed commit titles, PR titles, and PR bodies from Chinese-default to English; updated the Chinese punctuation rule so it no longer applies to PR descriptions.
- Reworked `build-firmware.yml` to pass `SDKCONFIG_DEFAULTS=sdkconfig.defaults`, enable `partitions.csv`, preserve the 8 MB image header, merge a flashable `FoloToy-AI-Passport-full.bin`, publish only that artifact, and use Actions cache v5.
- Integrated upstream PR #6 to resolve PR #4 conflicts: Wi-Fi, Bluetooth LE, radio lifecycle, and low-power demos; a 3 MB factory partition; build/menu/configuration updates; hardware-guide coverage; and bilingual capability tables.
- Defined English imperative Conventional Commit formatting for both commits and PR titles.
- Removed stale sync-workflow template comments and generalized an irrelevant Redis TTL rule to cache components.
- Added Chinese punctuation, credential safety, and recoverable file-deletion conventions.
- Expanded source-comment requirements for functions, state, ownership, concurrency, timing, registers, and magic values.
- Removed AI execution instructions from product READMEs so they remain human-facing product and repository overviews.
- Added `docs/development/agent-guide.md` as the focused AI workflow guide.
- Updated `AGENTS.md`, `docs/INDEX.md`, and the development index for the agent guide.
- Documented why the root README path is reserved for fork owners and how GitHub README precedence supports it.
- Created `main-update` from the upstream-aligned baseline and combined the repository-structure, firmware-CI, and upstream-sync work.
- Corrected the merged documentation index, workflow path, project tree, and CI references.
- Moved CI documentation from software design to `docs/development/`.
- Moved fork-only documentation assets from `assets/docs/` to `docs/assets/`.
- Moved the upstream English/Chinese project READMEs under `docs/` and renamed the documentation catalog to `docs/INDEX.md`.
- Initialized `AGENTS.md`, `CLAUDE.md`, and `CHANGELOG.md`.
- Standardized the initial project README language filenames.
- Added the `docs/`, `assets/`, and `skills/` directory structure.
- Moved the upstream hardware guide into `docs/hardware-design/`.
- Standardized subdirectory README capitalization and introduced fork conventions.
- Allowed fork-owned root README and supplemental documentation content on fork `main`.
- Added and documented the fork-only supplemental-document directory.
- Moved the build CI document to its dedicated CI branch before consolidation.
- Documented clean-`main` reasons, the direct-development exception, and Actions enablement for forks.
- Split the original agent rules into contribution, development, and fork documents with a compact root index.
- Updated software-design and project README references for the new documentation structure.
- Added the documentation catalog and task-triggered routing based on the earlier repository model.
- Added bilingual contribution, code-of-conduct, security, and support documents tailored to this ESP-IDF and fork workflow.
