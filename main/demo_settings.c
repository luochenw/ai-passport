#include "demo.h"
#include "device_config.h"
#include "ui_pixel.h"
#include <stdio.h>

enum { SET_WIFI, SET_BLUETOOTH, SET_CHIME, SET_VOLUME, SET_BRIGHTNESS, SET_FIRMWARE, SET_COUNT };
static lv_obj_t *s_scr, *s_rows[SET_COUNT], *s_labels[SET_COUNT], *s_hint, *s_notice;
static lv_obj_t *s_title;
static lv_timer_t *s_timer;
static int s_selected, s_draft;
static bool s_editing, s_pending;
static bool s_music_page;
static uint32_t s_seen_revision, s_seen_failures;
static settings_destination_t s_destination;

static void render(void)
{
    lv_label_set_text(s_title, s_music_page ? "开机音乐" : "设置");
    int count = s_music_page ? 2 : SET_COUNT;
    for (int i = 0; i < SET_COUNT; i++) {
        if (i < count) lv_obj_remove_flag(s_rows[i], LV_OBJ_FLAG_HIDDEN);
        else lv_obj_add_flag(s_rows[i], LV_OBJ_FLAG_HIDDEN);
        ui_pixel_set_selected(s_rows[i], i == s_selected, true);
    }
    if (s_music_page) {
        lv_label_set_text_fmt(s_labels[0], "开机音乐  %s",
                              device_config_boot_chime_enabled() ? "开启" : "关闭");
        lv_label_set_text_fmt(s_labels[1], "开机音量  %d%%",
                              s_editing ? s_draft : device_config_boot_chime_volume());
        lv_label_set_text(s_hint, s_editing ? "上/下调整 确定保存 长按取消" : "确定修改  长按返回设置");
        return;
    }
    lv_label_set_text(s_labels[SET_WIFI], "Wi-Fi");
    lv_label_set_text(s_labels[SET_BLUETOOTH], "蓝牙");
    lv_label_set_text(s_labels[SET_CHIME], "开机音乐");
    lv_label_set_text_fmt(s_labels[SET_VOLUME], "音量  %d%%",
                          s_editing && s_selected == SET_VOLUME ? s_draft : device_config_volume());
    lv_label_set_text_fmt(s_labels[SET_BRIGHTNESS], "亮度  %d%%",
                          s_editing && s_selected == SET_BRIGHTNESS ? s_draft : device_config_brightness());
    lv_label_set_text(s_labels[SET_FIRMWARE], "固件升级");
    lv_label_set_text(s_hint, s_editing ? "上/下调整 确定保存 长按取消" : "上/下选择 确定进入 长按返回");
}

static void tick(lv_timer_t *timer)
{
    (void)timer;
    uint32_t revision = device_config_revision();
    uint32_t failures = device_config_write_failures();
    if (revision == s_seen_revision && failures == s_seen_failures) return;
    if (s_pending) {
        lv_label_set_text(s_notice, failures != s_seen_failures ? "保存失败，请重试" : "已保存到设备");
        s_pending = false;
    }
    s_seen_revision = revision;
    s_seen_failures = failures;
    render();
}

static void save(const char *key, int value)
{
    char text[12];
    snprintf(text, sizeof(text), "%d", value);
    s_seen_revision = device_config_revision();
    s_seen_failures = device_config_write_failures();
    s_pending = device_config_request_set(key, text);
    lv_label_set_text(s_notice, s_pending ? "正在保存…" : "设备忙，请重试");
}

void demo_settings_enter(void)
{
    s_scr = ui_pixel_screen_create("设置");
    s_destination = SETTINGS_DEST_NONE;
    s_editing = s_pending = false;
    s_music_page = false;
    s_seen_revision = device_config_revision();
    s_seen_failures = device_config_write_failures();
    s_title = ui_pixel_label(s_scr, "设置", &lv_font_ui_cn_14, UI_INK);
    lv_obj_set_pos(s_title, 16, 2);
    for (int i = 0; i < SET_COUNT; i++) {
        s_rows[i] = ui_pixel_panel_create(s_scr, 10, 32 + i * 32, 220, 29, UI_PAPER);
        lv_obj_set_style_pad_all(s_rows[i], 0, 0);
        s_labels[i] = ui_pixel_label(s_rows[i], "", &lv_font_ui_cn_14, UI_INK);
        lv_obj_set_size(s_labels[i], 204, 27);
        lv_label_set_long_mode(s_labels[i], LV_LABEL_LONG_DOT);
        lv_obj_align(s_labels[i], LV_ALIGN_LEFT_MID, 7, 0);
    }
    s_notice = ui_pixel_label(s_scr, "", &lv_font_ui_cn_14, UI_SAGE);
    lv_obj_set_pos(s_notice, 16, 226);
    s_hint = ui_pixel_label(s_scr, "", &lv_font_ui_cn_14, UI_MUTED);
    lv_obj_set_width(s_hint, 224);
    lv_obj_set_style_text_align(s_hint, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(s_hint, LV_ALIGN_BOTTOM_MID, 0, -6);
    render();
    s_timer = lv_timer_create(tick, 200, NULL);
    lv_screen_load(s_scr);
}

void demo_settings_exit(void)
{
    if (s_timer) lv_timer_delete(s_timer);
    s_timer = NULL;
    if (s_scr) lv_obj_delete(s_scr);
    s_scr = NULL;
}

bool demo_settings_back(void)
{
    if (s_editing) {
        s_editing = false;
        lv_label_set_text(s_notice, "已取消");
    } else if (s_music_page) {
        s_music_page = false;
        s_selected = SET_CHIME;
        lv_label_set_text(s_notice, "");
    } else {
        return true;
    }
    render();
    return false;
}

settings_destination_t demo_settings_take_destination(void)
{
    settings_destination_t destination = s_destination;
    s_destination = SETTINGS_DEST_NONE;
    return destination;
}

void demo_settings_key(bsp_btn_t btn, bsp_btn_ev_t ev)
{
    if (s_pending) return;
    if ((btn == BSP_BTN_UP || btn == BSP_BTN_DOWN) && (ev == BSP_BTN_PRESS || ev == BSP_BTN_HOLD)) {
        int direction = btn == BSP_BTN_UP ? -1 : 1;
        if (s_editing) {
            int minimum = !s_music_page && s_selected == SET_BRIGHTNESS ? DEVICE_CONFIG_MIN_BRIGHTNESS : 0;
            s_draft += direction * 5;
            if (s_draft < minimum) s_draft = minimum;
            if (s_draft > 100) s_draft = 100;
        } else {
            int count = s_music_page ? 2 : SET_COUNT;
            s_selected = (s_selected + direction + count) % count;
            lv_label_set_text(s_notice, "");
        }
        render();
    }
    if (btn != BSP_BTN_OK || ev != BSP_BTN_CLICK) return;
    if (s_editing) {
        save(s_music_page ? "boot_chime.volume" : s_selected == SET_VOLUME ? "volume" : "brightness", s_draft);
        s_editing = false;
    } else if (s_music_page) {
        if (s_selected == 0) save("boot_chime.enabled", !device_config_boot_chime_enabled());
        else { s_draft = device_config_boot_chime_volume(); s_editing = true; }
    } else {
        switch (s_selected) {
        case SET_WIFI: s_destination = SETTINGS_DEST_WIFI; break;
        case SET_FIRMWARE: s_destination = SETTINGS_DEST_FIRMWARE; break;
        case SET_BLUETOOTH: s_destination = SETTINGS_DEST_CONNECTIONS; break;
        case SET_CHIME:
            s_music_page = true;
            s_selected = 0;
            lv_label_set_text(s_notice, "音量独立于普通播放音量");
            break;
        case SET_VOLUME: s_draft = device_config_volume(); s_editing = true; break;
        case SET_BRIGHTNESS: s_draft = device_config_brightness(); s_editing = true; break;
        default: break;
        }
    }
    render();
}
