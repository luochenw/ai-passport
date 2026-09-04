// main/boot_image.c —— 把嵌进固件的 RGB565 开机图铺满整屏。
//
// 图片本身**不在仓库里**:`assets/boot_image.rgb565` 被 .gitignore 挡着。
// 理由是它通常是张私人照片(逐像素副本,人脸和水印都在里面),而这个仓库是
// 公开的。所以嵌入是**可选的** —— 没有那个文件时 CMake 不定义
// HAVE_BOOT_IMAGE,这个文件整体退化成一个空函数,克隆下来照常能编译。
//
// 自己要一张:tools/gen_boot_image.py <图片>

#include "boot_image.h"

#include "bsp_display.h"
#include "esp_log.h"

static const char *TAG = "boot_image";

#if HAVE_BOOT_IMAGE

#include "lvgl.h"

// EMBED_FILES 生成的符号,跟开机音效那份 PCM 同一个机制。
extern const uint8_t boot_image_rgb565_start[] asm("_binary_boot_image_rgb565_start");
extern const uint8_t boot_image_rgb565_end[]   asm("_binary_boot_image_rgb565_end");

#define BOOT_IMAGE_W 240
#define BOOT_IMAGE_H 320

/// 停留多久,然后淡出多久。
///
/// ⚠ 不是在这里 sleep 3 秒。那样会把后面所有初始化(配置、音效、BLE、页面)
/// 整体往后推 3 秒 —— 开机反而更慢,而用户看到的还是同一张图。
/// 正确的做法是:图画在**顶层**,初始化照常跑,3 秒后它自己退场。那 3 秒
/// 本来就是设备在忙的时间,等于白捡。
#define BOOT_IMAGE_HOLD_MS 3000
#define BOOT_IMAGE_FADE_MS 300

/// 停留时间到了,把顶层那张图删掉。
///
/// 定时器回调在 LVGL 自己的任务里跑,锁已经由 esp_lvgl_port 持着,
/// 这里再去 bsp_lvgl_lock 会死锁。
static void boot_image_dismiss(lv_timer_t *timer)
{
    lv_obj_t *img = lv_timer_get_user_data(timer);
    if (img) lv_obj_delete(img);
    lv_timer_delete(timer);
    ESP_LOGI(TAG, "开机画面已退场");
}

void boot_image_show(void)
{
    const size_t bytes = (size_t)(boot_image_rgb565_end - boot_image_rgb565_start);
    const size_t want = (size_t)BOOT_IMAGE_W * BOOT_IMAGE_H * 2;
    if (bytes != want) {
        // 尺寸对不上就干脆不画。画出来会是一屏错位的雪花,而那个现象很容易被
        // 当成屏幕坏了或者 SPI 接线问题去查 —— 实际只是图没按 240x320 生成。
        ESP_LOGE(TAG, "开机图大小不对:%u 字节,期望 %u(要 %dx%d RGB565)",
                 (unsigned)bytes, (unsigned)want, BOOT_IMAGE_W, BOOT_IMAGE_H);
        return;
    }

    if (!bsp_lvgl_lock(500)) {
        ESP_LOGW(TAG, "拿不到 LVGL 锁,跳过开机图");
        return;
    }

    static const lv_image_dsc_t dsc = {
        .header = {
            .magic = LV_IMAGE_HEADER_MAGIC,
            .cf = LV_COLOR_FORMAT_RGB565,
            .w = BOOT_IMAGE_W,
            .h = BOOT_IMAGE_H,
            .stride = BOOT_IMAGE_W * 2,
        },
        .data_size = (uint32_t)(BOOT_IMAGE_W * BOOT_IMAGE_H * 2),
        .data = boot_image_rgb565_start,
    };

    // ⚠ 画在 lv_layer_top(),不是 lv_screen_active()。
    //
    // 顶层不受"清屏"影响 —— 后面各个页面初始化时会往活动屏幕上建控件、也可能
    // 整屏清掉重来,开机图要是在那上面,会在这 3 秒里被随机抹掉或盖住,而具体
    // 什么时候没,取决于哪个页面先初始化完。放顶层就跟它们完全无关。
    lv_obj_t *img = lv_image_create(lv_layer_top());
    lv_image_set_src(img, &dsc);
    lv_obj_center(img);
    // 立刻刷出去,不等下一次 LVGL 定时器。开机图的意义就是填住"上电到界面
    // 建好"这段空窗,晚一个周期出现就没意义了。
    lv_refr_now(NULL);

    // 停 3 秒再淡出。淡出的动画和删除是两件事:fade_out 只动透明度,对象还在,
    // 所以要另外挂一个一次性定时器把它删掉 —— 不删的话它会以 0 透明度一直
    // 挂在顶层,吃掉每一帧的合成开销,而且看不出来。
    lv_obj_fade_out(img, BOOT_IMAGE_FADE_MS, BOOT_IMAGE_HOLD_MS);
    lv_timer_t *t = lv_timer_create(boot_image_dismiss,
                                    BOOT_IMAGE_HOLD_MS + BOOT_IMAGE_FADE_MS, img);
    lv_timer_set_repeat_count(t, 1);

    bsp_lvgl_unlock();
    ESP_LOGI(TAG, "开机画面已显示(%dx%d),停留 %d ms 后淡出",
             BOOT_IMAGE_W, BOOT_IMAGE_H, BOOT_IMAGE_HOLD_MS);
}

#else   // 没配开机图

void boot_image_show(void)
{
    ESP_LOGD(TAG, "没有 assets/boot_image.rgb565,跳过开机画面");
}

#endif
