// main/boot_chime.c —— 播放嵌入固件的开机音乐 PCM(assets/music/boot_chime.pcm)。
// 采样格式需与转换命令一致,见 assets/music/README.md。
#include "boot_chime.h"
#include "bsp_audio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include <stdint.h>
#include <stddef.h>

static const char *TAG = "boot_chime";

#define SAMPLE_RATE     16000
#define CHUNK_SAMPLES     512   // 每次写入的采样数,控制临时缓冲大小

// 开机音效的音量。刻意跟用户配置的播放音量分开:开机提示音是每次上电都会
// 响一次的东西,按正常播放音量放会很吵。
#define BOOT_CHIME_VOLUME 5

// EMBED_FILES 生成的符号名取自文件名,见 main/CMakeLists.txt。
extern const uint8_t boot_chime_pcm_start[] asm("_binary_boot_chime_pcm_start");
extern const uint8_t boot_chime_pcm_end[]   asm("_binary_boot_chime_pcm_end");

// 音效播完之后要恢复成的音量(用户在配套 app 里配的那个)。
// 由 boot_chime_play_async() 的调用方传进来,这个模块自己不去读配置 ——
// 它只管放一段 PCM,不该知道 NVS 和配置系统的存在。
static uint8_t s_restore_volume;
static volatile bool s_playing;

bool boot_chime_is_playing(void) { return s_playing; }

static void boot_chime_task(void *arg) {
    (void)arg;
    size_t total = (size_t)(boot_chime_pcm_end - boot_chime_pcm_start);

    if (!bsp_audio_acquire(1000)) {
        ESP_LOGW(TAG, "音频设备忙,跳过开机音乐");
        s_playing = false;
        vTaskDelete(NULL);
        return;
    }
    if (bsp_audio_set_format(SAMPLE_RATE, 16, 1) != ESP_OK) {
        ESP_LOGE(TAG, "设置采样格式失败,跳过开机音乐");
        s_playing = false;
        bsp_audio_release();
        vTaskDelete(NULL);
        return;
    }
    bsp_audio_set_volume(BOOT_CHIME_VOLUME);

    for (size_t off = 0; off < total; off += CHUNK_SAMPLES * sizeof(int16_t)) {
        size_t n = total - off;
        if (n > CHUNK_SAMPLES * sizeof(int16_t)) n = CHUNK_SAMPLES * sizeof(int16_t);
        bsp_audio_write(boot_chime_pcm_start + off, n);
    }

    // 放完把音量交还给用户的设置。不做这一步的话,开机后第一次播别的东西
    // 会是这里的 5%,听起来像"没声音"。
    bsp_audio_set_volume(s_restore_volume);
    bsp_audio_release();
    s_playing = false;
    vTaskDelete(NULL);
}

void boot_chime_play_async(uint8_t restore_volume) {
    s_restore_volume = restore_volume;
    s_playing = true;
    if (xTaskCreate(boot_chime_task, "boot_chime", 4096, NULL, 4, NULL) != pdPASS) {
        ESP_LOGW(TAG, "创建开机音乐任务失败");
        s_playing = false;
    }
}
