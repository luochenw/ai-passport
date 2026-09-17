<p align="right">
  <a href="build-and-test.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# Build and Test

Use ESP-IDF 5.5.3. On a clean machine or when the toolchain is missing, follow
the [environment bootstrap](environment-setup.md) first.

> Prefer `./tools/validate.sh --firmware` for firmware builds and flash its
> verified `build/FoloToy-AI-Passport-full.bin` at offset `0x0` only when the
> target is blank or the merged byte range ends before protected `cardid`.
> On a provisioned device, prefer mini-program install or segmented
> `idf.py flash`. Treat
> `idf.py build` and `idf.py flash` as incremental development commands, not the
> default delivery path.

```bash
source <path-to-esp-idf-v5.5.3>/export.sh
idf.py --version             # must report ESP-IDF v5.5.3
./tools/validate.sh --firmware # preferred: build and verify merged 0x0 image
idf.py set-target esp32c3     # fresh checkout or changed target
idf.py build                  # optional incremental application build
idf.py flash monitor          # optional incremental application flash
idf.py fullclean              # remove stale generated build state only
```

`idf.py fullclean` does not fully synchronize an existing `sdkconfig` with
changed defaults. Preserve intentional local settings, then run
`idf.py set-target esp32c3` when the target or tracked defaults must be
regenerated.

The tracked `dependencies.lock` pins Managed Component resolution. After changing an `idf_component.yml`, regenerate the lock with ESP-IDF 5.5.3, review version changes, and commit it with the manifest. An ordinary build must not leave an unexplained lock-file diff.

Firmware validation uses a fresh temporary build directory and an isolated `sdkconfig` generated from the tracked defaults. It does not consume or overwrite a developer's root `sdkconfig`, and it copies only the verified merged image to `build/FoloToy-AI-Passport-full.bin`. The gate also enforces the [mini-program BLE compatibility contract](ble-recovery-compatibility.md): protected partition addresses, application size, partition-table MD5, absence of protected payload data, and the Recovery bootloader hook.

The root `VERSION` file is the firmware version source of truth. Normal local
and branch builds embed `<version>-dev+g<short-sha>` (plus `.dirty` when the
worktree has changes) in `esp_app_desc_t`. Release builds set
`FOLO_FIRMWARE_RELEASE=1` and embed the clean version. Validation emits both the
stable `FoloToy-AI-Passport-full.bin` alias and a
`FoloToy-AI-Passport-v<resolved-version>-full.bin` artifact, then updates the
companion's `AppCatalog/catalog.json` version, byte size, and SHA-256 from the
exact app image copied into the catalog.
The macOS, scripted iOS, and generated Xcode build paths validate that bundled
image against the catalog before packaging, so a clean checkout must build the
firmware once before building a companion app with firmware-update support.

The baseline also has a hardware-independent logic test:

```bash
cc -std=c11 -Wall -Wextra -Werror -Imain \
  tests/test_ui_pixel_math.c main/ui_pixel_math.c \
  -o /tmp/test_ui_pixel_math
/tmp/test_ui_pixel_math
```

Use the unified validation entry point:

```bash
./tools/validate.sh --static    # repository checks, workflows, links, secrets, host tests
./tools/validate.sh --firmware  # build, merge-bin, offsets, and BLE compatibility
./tools/validate.sh             # complete gate; requires an activated ESP-IDF environment
```

CI calls the same script. Fix the shared script or environment if local and CI behavior differs; do not duplicate command sequences in workflows.

Hardware-affecting changes must also run the applicable on-device checklist in the hardware guide. Report compilation separately from physical-device validation.

Never upload the app-only `build/FoloToy-AI-Passport.bin` to the community. Only
the validated `build/FoloToy-AI-Passport-full.bin` contains the structure the
mini-program can inspect and transform safely.
