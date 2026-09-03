#include "ui_notify.h"

#include <string.h>
#include "lvgl.h"
#include "esp_log.h"
#include "ui_pixel.h"
#include "ui_statusbar.h"
#include "appstore_transfer.h"
#include "demo.h"

static const char *TAG = "ui_notify";

// ---- 卡片尺寸 --------------------------------------------------------------
#define NF_MARGIN   14                       // 左右留白
#define NF_W        (240 - NF_MARGIN * 2)
#define NF_PAD      12
// 正文最多四行。lv_font_ui_cn_14 的 line_height 是 27(不是字号 14),
// 这个坑在 ui_statusbar.h 里记过一次,这里同样按 27 算高度。
#define NF_LINE_H   27
#define NF_BODY_H   (NF_LINE_H * 4)

// ---- 跨任务投递 ------------------------------------------------------------
// post 只写这两个,tick 只读这两个。post 可能来自 NimBLE host 任务,
// 而 tick 在 LVGL 任务里 —— 所以不能在 post 里碰任何 lv_* 对象。
static char           s_pending[UI_NOTIFY_MAX_LEN + 1];
static volatile bool  s_has_pending;
// 请求丢弃。跟 s_has_pending 一样,由非 LVGL 任务置位、LVGL 任务消费。
static volatile bool  s_drop_requested;

static lv_obj_t   *s_card;      // 非 NULL = 正钉着
static lv_obj_t   *s_label;
static lv_timer_t *s_timer;

// UTF-8 安全截断:宁可少一个字,也不要切出半个汉字变成乱码方块。
static void utf8_copy(char *dst, size_t dst_size, const char *src)
{
    size_t n = 0;
    while (src[n] && n < dst_size - 1) n++;
    // 退回到最后一个完整字符的边界
    while (n > 0 && (src[n] & 0xC0) == 0x80) n--;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

static void build_card(const char *text)
{
    if (!s_card) {
        lv_obj_t *top = lv_layer_top();

        s_card = lv_obj_create(top);
        lv_obj_remove_flag(s_card, LV_OBJ_FLAG_SCROLLABLE);
        lv_obj_remove_flag(s_card, LV_OBJ_FLAG_CLICKABLE);
        lv_obj_set_size(s_card, NF_W, NF_BODY_H + NF_PAD * 2 + NF_LINE_H);
        // 垂直居中在**内容区**里,不是整屏 —— 顶上那 22px 是状态栏的地盘,
        // 盖住它会让人以为设备失去了时间和电量显示。
        lv_obj_align(s_card, LV_ALIGN_TOP_MID, 0,
                     UI_STATUSBAR_H + (UI_CONTENT_H - (NF_BODY_H + NF_PAD * 2 + NF_LINE_H)) / 2);
        lv_obj_set_style_radius(s_card, 6, 0);
        lv_obj_set_style_pad_all(s_card, NF_PAD, 0);
        lv_obj_set_style_bg_color(s_card, lv_color_hex(UI_ACCENT_BG), 0);
        lv_obj_set_style_border_color(s_card, lv_color_hex(UI_ACCENT), 0);
        lv_obj_set_style_border_width(s_card, 2, 0);

        s_label = ui_pixel_label(s_card, "", &lv_font_ui_cn_14, UI_INK);
        lv_label_set_long_mode(s_label, LV_LABEL_LONG_WRAP);
        lv_obj_set_width(s_label, NF_W - NF_PAD * 2);
        lv_obj_set_height(s_label, NF_BODY_H);
        lv_obj_align(s_label, LV_ALIGN_TOP_LEFT, 0, 0);

        lv_obj_t *hint = ui_pixel_label(s_card, "按任意键关闭",
                                        &lv_font_ui_cn_14, UI_INK_SOFT);
        lv_obj_align(hint, LV_ALIGN_BOTTOM_LEFT, 0, 0);
    }
    lv_label_set_text(s_label, text);
    // 已经钉着一条时再来一条:直接换文字,不叠卡片。
    // 叠起来的话用户要按好几次才能清空,而且看不到底下那一页。
    lv_obj_move_foreground(s_card);
}

static void tick(lv_timer_t *t)
{
    (void)t;
    if (s_drop_requested) {
        s_drop_requested = false;
        s_has_pending = false;
        ui_notify_dismiss();     // 在 LVGL 任务里,拿着锁,可以直接删
    }
    if (!s_has_pending) return;

    // 两个场景要让路,而且是**延后不是丢弃** —— s_has_pending 保持为真,
    // 200ms 后这个定时器还会再来一次,条件一解除立刻就画:
    //
    //   · 刷固件:那一页自己在钉着进度和错误(appstore_transfer.c 的
    //     s_error_pinned),盖住它用户会以为刷机卡死了;
    //   · 录音:长按下键说话正说到一半,弹一张卡片会让人以为按错了、
    //     松手 —— 已经说的那半句就白说了。
    if (appstore_transfer_is_installing() || codex_voice_active()) return;

    s_has_pending = false;
    build_card(s_pending);
    ESP_LOGI(TAG, "显示通知(%d 字节)", (int)strlen(s_pending));
}

void ui_notify_init(void)
{
    if (s_timer) return;
    // 200ms 轮询。不用更快:通知本来就不是实时的,而且 lv_timer_ready()
    // 会在 post 时把下一次触发提到现在,实际延迟接近 0。
    s_timer = lv_timer_create(tick, 200, NULL);
}

void ui_notify_post(const char *text)
{
    if (!text || !text[0]) return;
    utf8_copy(s_pending, sizeof(s_pending), text);
    s_has_pending = true;
    // 只是置一个标志位,是安全的 —— 跟 ui_statusbar_notify_config_changed()
    // 同样的做法。真正的绘制在 LVGL 任务里。
    if (s_timer) lv_timer_ready(s_timer);
}

bool ui_notify_is_pinned(void)
{
    return s_card != NULL;
}

void ui_notify_dismiss(void)
{
    if (!s_card) return;
    lv_obj_delete(s_card);
    s_card = NULL;
    s_label = NULL;
}

void ui_notify_drop(void)
{
    // 只置标志,不碰 LVGL —— 这个函数会被 BLE 断开回调调到,
    // 那个上下文(NimBLE host 任务)不持有 LVGL 锁。
    s_drop_requested = true;
    if (s_timer) lv_timer_ready(s_timer);
}
