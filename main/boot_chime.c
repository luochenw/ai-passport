// main/boot_chime.c —— 播放嵌入固件的开机音乐 PCM(assets/music/boot_chime.pcm)。
// 采样格式需与转换命令一致,见 assets/music/README.md。
#include "boot_chime.h"
#include "bsp_audio.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "esp_log.h"
#include <stdint.h>
#include <stddef.h>
#include <stdatomic.h>

static const char *TAG = "boot_chime";

#define SAMPLE_RATE     16000
#define CHUNK_SAMPLES     512   // 每次写入的采样数,控制临时缓冲大小

// BSP TX has 6 x 240 frames: 90 ms at 16 kHz. Queue more than one full
// DMA ring of silence, then allow the outstanding ring to finish before
// restoring the user's volume. A write only queues samples; it is not a drain.
#define SILENCE_CHUNKS 4
#define DRAIN_MS 100
static const int16_t s_silence[CHUNK_SAMPLES];

// EMBED_FILES 生成的符号名取自文件名,见 main/CMakeLists.txt。
extern const uint8_t boot_chime_pcm_start[] asm("_binary_boot_chime_pcm_start");
extern const uint8_t boot_chime_pcm_end[]   asm("_binary_boot_chime_pcm_end");

// 音效播完之后要恢复成的音量(用户在配套 app 里配的那个)。
// 由 boot_chime_play_async() 的调用方传进来,这个模块自己不去读配置 ——
// 它只管放一段 PCM,不该知道 NVS 和配置系统的存在。
static uint8_t s_restore_volume;
static uint8_t s_chime_volume;
static atomic_bool s_playing;

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
    bsp_audio_set_volume(s_chime_volume);

    for (size_t off = 0; off < total; off += CHUNK_SAMPLES * sizeof(int16_t)) {
        size_t n = total - off;
        if (n > CHUNK_SAMPLES * sizeof(int16_t)) n = CHUNK_SAMPLES * sizeof(int16_t);
        if (bsp_audio_write(boot_chime_pcm_start + off, n) != ESP_OK) {
            ESP_LOGW(TAG, "开机音乐写入失败,结束播放");
            break;
        }
    }

    bool drained = true;
    for (int i = 0; i < SILENCE_CHUNKS; i++) {
        if (bsp_audio_write(s_silence, sizeof(s_silence)) != ESP_OK) {
            drained = false;
            break;
        }
    }
    vTaskDelay(pdMS_TO_TICKS(DRAIN_MS));
    // Never amplify an undrained tail on a failed I2S write.
    bsp_audio_set_volume(drained ? s_restore_volume : 0);
    bsp_audio_release();
    s_playing = false;
    vTaskDelete(NULL);
}

void boot_chime_play_async(uint8_t restore_volume, uint8_t chime_volume) {
    if (!chime_volume || atomic_exchange(&s_playing, true)) return;
    // The two gains are independent: ordinary audio may be muted while the
    // user still wants an audible startup chime, or vice versa.
    s_restore_volume = restore_volume > 100 ? 100 : restore_volume;
    s_chime_volume = chime_volume > 100 ? 100 : chime_volume;
    if (xTaskCreate(boot_chime_task, "boot_chime", 4096, NULL, 4, NULL) != pdPASS) {
        ESP_LOGW(TAG, "创建开机音乐任务失败");
        s_playing = false;
    }
}
