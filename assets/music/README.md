<p align="right">
  <a href="README.zh_CN.md">简体中文</a> · <strong>English</strong>
</p>

# Music and Sound Effects

Store reusable music and sound-effect sources here.

- Document the source, license, sample rate, bit depth, channels, conversion command, and destination.
- Prefer 16 kHz, 16-bit mono PCM when it matches the current BSP audio path.
- Check Flash and internal-RAM cost before embedding audio; stream or chunk long recordings.
- Do not commit media without redistribution permission.

## Assets

- `boot_chime.pcm`: boot-time startup sound, embedded via `main/CMakeLists.txt`
  `EMBED_FILES` and played by [`main/boot_chime.c`](../../main/boot_chime.c) on
  boot. Source: user-provided local clip, ~4.6 s, redistribution rights not
  verified — confirm licensing before committing or distributing this file.
  Format: 16 kHz, 16-bit, mono, raw PCM (`s16le`), 146,688 bytes. Converted
  with `ffmpeg -i <source> -ar 16000 -ac 1 -f s16le boot_chime.pcm`.
