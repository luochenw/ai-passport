<p align="right">
  <strong>简体中文</strong> · <a href="README.md">English</a>
</p>

# 音乐/音效资源（Music / Sound Effects）

本目录存放项目可复用的音乐与音效资源。

## 如何使用

- 音频文件（如 `.wav`、`.mp3`、固件可用的编码格式）复制到本目录，并在本项目 `README.md` 记录采样率、时长、用途与来源。
- 与固件集成时，参考 [`components/bsp/include/bsp_audio.h`](../../components/bsp/include/bsp_audio.h) 音频接口，确认播放路径、任务上下文与内存占用。
- 音频文件占用 Flash 与内存，集成前请评估 ESP32-C3 无 PSRAM 的限制。

## 目录说明

> 当前为空骨架，用于存放后续加入的音乐/音效资源。加入资源时请同步更新本 `README.md` 的索引。

## 资源索引

- `boot_chime.pcm`：开机音乐，通过 `main/CMakeLists.txt` 的 `EMBED_FILES`
  嵌入固件，由 [`main/boot_chime.c`](../../main/boot_chime.c) 在开机时播放。
  来源：用户提供的本地音频片段，约 4.6 秒，转载权限未核实——提交或分发前
  请先确认版权。格式：16 kHz、16 位、单声道原始 PCM（`s16le`），146,688
  字节。转换命令：`ffmpeg -i <source> -ar 16000 -ac 1 -f s16le boot_chime.pcm`。
