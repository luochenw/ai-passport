#!/usr/bin/env python3
"""Compile the real boot-chime source against deterministic audio/task fakes."""

from __future__ import annotations

import os
from pathlib import Path
import shlex
import subprocess
import tempfile


ROOT = Path(__file__).resolve().parent.parent
HEADERS = {
    "esp_err.h": "#pragma once\ntypedef int esp_err_t;\n#define ESP_OK 0\n",
    "esp_log.h": ("#pragma once\n"
                  "#define ESP_LOGW(tag, ...) ((void)(tag))\n"
                  "#define ESP_LOGE(tag, ...) ((void)(tag))\n"),
    "freertos/FreeRTOS.h": ("#pragma once\n#include <stdint.h>\n"
                            "#define pdPASS 1\n#define pdMS_TO_TICKS(ms) (ms)\n"),
    "freertos/task.h": ("#pragma once\n#include <stdint.h>\n"
                        "typedef void (*TaskFunction_t)(void *);\n"
                        "int xTaskCreate(TaskFunction_t, const char *, uint32_t, void *, "
                        "unsigned, void *);\n"
                        "void vTaskDelete(void *);\nvoid vTaskDelay(uint32_t);\n"),
}

HARNESS = r'''
#include "boot_chime.h"
#include "bsp_audio.h"
#include "freertos/task.h"
#include <assert.h>
#include <stdio.h>
#include <string.h>

// Three writes are needed, including a partial last chunk. Exact assembler
// names match ESP-IDF's EMBED_FILES symbols on both ELF and Mach-O hosts.
__asm__(".text\n"
        ".globl _binary_boot_chime_pcm_start\n"
        "_binary_boot_chime_pcm_start:\n"
        ".fill 1025,2,1000\n"
        ".globl _binary_boot_chime_pcm_end\n"
        "_binary_boot_chime_pcm_end:\n");

struct event { char kind; unsigned value; };
static struct event events[128];
static unsigned event_count;
static unsigned creates;
static TaskFunction_t pending;
static bool create_ok, acquire_ok, format_ok, fail_audio, fail_silence;

static void record(char kind, unsigned value) {
    assert(event_count < sizeof(events) / sizeof(events[0]));
    events[event_count++] = (struct event){ kind, value };
}

static void reset(void) {
    assert(!boot_chime_is_playing());
    assert(!pending);
    memset(events, 0, sizeof(events));
    event_count = creates = 0;
    create_ok = acquire_ok = format_ok = true;
    fail_audio = fail_silence = false;
}

int xTaskCreate(TaskFunction_t task, const char *name, uint32_t stack,
                void *arg, unsigned priority, void *handle) {
    (void)name; (void)stack; (void)arg; (void)priority; (void)handle;
    creates++;
    if (!create_ok) return 0;
    assert(!pending);
    pending = task;
    return 1;
}

void vTaskDelete(void *task) { (void)task; record('X', 0); }
void vTaskDelay(uint32_t ticks) { record('D', ticks); }
bool bsp_audio_acquire(uint32_t timeout) { record('A', timeout); return acquire_ok; }
void bsp_audio_release(void) { record('R', 0); }

esp_err_t bsp_audio_set_format(uint32_t hz, uint8_t bits, uint8_t channels) {
    assert(hz == 16000 && bits == 16 && channels == 1);
    record('F', hz);
    return format_ok ? ESP_OK : -1;
}

void bsp_audio_set_volume(uint8_t percent) { record('V', percent); }

esp_err_t bsp_audio_write(const void *pcm, size_t bytes) {
    const unsigned char *data = pcm;
    bool silence = true;
    for (size_t i = 0; i < bytes; i++) if (data[i]) silence = false;
    record(silence ? 'S' : 'P', (unsigned)bytes);
    return (silence ? fail_silence : fail_audio) ? -1 : ESP_OK;
}

static void run_pending(void) {
    assert(pending && boot_chime_is_playing());
    TaskFunction_t task = pending;
    pending = NULL;
    task(NULL);
    assert(!boot_chime_is_playing());
    assert(event_count && events[event_count - 1].kind == 'X');
}

static unsigned count(char kind) {
    unsigned result = 0;
    for (unsigned i = 0; i < event_count; i++) result += events[i].kind == kind;
    return result;
}

static void assert_drained(unsigned initial_volume, unsigned restored_volume) {
    assert(count('V') == 2 && count('D') == 1 && count('R') == 1);
    assert(events[2].kind == 'V' && events[2].value == initial_volume);
    unsigned silent_bytes = 0;
    bool silence_seen = false, delayed = false;
    for (unsigned i = 3; i < event_count; i++) {
        struct event event = events[i];
        if (event.kind == 'P') assert(!silence_seen && !delayed);
        if (event.kind == 'S') {
            assert(!delayed);
            silence_seen = true;
            silent_bytes += event.value;
        }
        if (event.kind == 'D') {
            // BSP has six 240-frame DMA descriptors (90 ms at 16 kHz).
            assert(silent_bytes >= 6 * 240 * sizeof(int16_t));
            assert(event.value >= 90);
            delayed = true;
        }
        if (event.kind == 'V') {
            assert(delayed && event.value == restored_volume);
            assert(events[i + 1].kind == 'R');
        }
    }
    assert(delayed);
}

int main(void) {
    reset();
    boot_chime_play_async(60, 0);
    assert(!pending && !boot_chime_is_playing() && creates == 0);

    reset();
    boot_chime_play_async(60, 20);
    assert(boot_chime_is_playing() && creates == 1);
    boot_chime_play_async(90, 75); // Cannot create a second task or replace either gain.
    assert(creates == 1);
    run_pending();
    assert(count('P') == 3);
    assert_drained(20, 60);

    reset();
    boot_chime_play_async(10, 75);
    run_pending();
    assert_drained(75, 10); // Startup gain is independent of ordinary playback gain.

    reset();
    boot_chime_play_async(0, 20);
    run_pending();
    assert_drained(20, 0); // Muting ordinary audio must not mute startup music.

    reset();
    boot_chime_play_async(255, 255);
    run_pending();
    assert_drained(100, 100); // Clamp each input to the codec's supported range.

    reset();
    create_ok = false;
    boot_chime_play_async(60, 20);
    assert(creates == 1 && !pending && !boot_chime_is_playing());
    create_ok = true;
    boot_chime_play_async(60, 20);
    run_pending(); // A failed task creation must not poison later playback.

    reset();
    acquire_ok = false;
    boot_chime_play_async(60, 20);
    run_pending();
    assert(count('R') == 0 && count('F') == 0 && count('P') == 0);

    reset();
    format_ok = false;
    boot_chime_play_async(60, 20);
    run_pending();
    assert(count('R') == 1 && count('V') == 0 && count('P') == 0);

    reset();
    fail_audio = true;
    boot_chime_play_async(60, 20);
    run_pending();
    assert(count('P') == 1);
    assert_drained(20, 60);

    reset();
    fail_silence = true;
    boot_chime_play_async(60, 20);
    run_pending();
    // On a failed drain, never restore a louder gain over queued PCM.
    assert(events[event_count - 3].kind == 'V');
    assert(events[event_count - 3].value == 0);
    assert(events[event_count - 2].kind == 'R');
    assert(count('D') == 1);

    puts("boot chime source tests: PASS (10 scenarios)");
    return 0;
}
'''


def main() -> None:
    with tempfile.TemporaryDirectory(prefix="passport-boot-chime-") as directory:
        work = Path(directory)
        for name, source in HEADERS.items():
            target = work / name
            target.parent.mkdir(parents=True, exist_ok=True)
            target.write_text(source)
        harness = work / "harness.c"
        harness.write_text(HARNESS)
        executable = work / "test_boot_chime"
        subprocess.run([
            *shlex.split(os.environ.get("CC", "cc")),
            "-std=gnu11", "-Wall", "-Wextra", "-Werror",
            f"-I{work}", f"-I{ROOT / 'main'}", f"-I{ROOT / 'components/bsp/include'}",
            str(ROOT / "main/boot_chime.c"), str(harness), "-o", str(executable),
        ], check=True)
        subprocess.run([str(executable)], check=True)


if __name__ == "__main__":
    main()
