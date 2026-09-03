// main/demo_status.c —— 系统状态看板:6 格卡片汇总运行时长、内存、电量等信息。
// 不主动启停任何外设(不碰 Wi-Fi/蓝牙),纯读取已有状态,进入即可看、无副作用。
#include "demo.h"
#include "bsp_battery.h"
#include "bsp_button.h"
#include "ui_pixel.h"
#include "lvgl.h"
#include "driver/usb_serial_jtag.h"
#include "esp_chip_info.h"
#include "esp_flash.h"
#include "esp_system.h"
#include "esp_timer.h"
#include <stdio.h>

#define TILE_COUNT 6
#define TILE_W 102
#define TILE_H 58
#define TILE_GAP 8
#define GRID_X 14
#define GRID_Y 65

static const char *CAPTIONS[TILE_COUNT] = {
    "运行时间", "USB",
    "电量",     "按键电压",
    "可用内存", "芯片",
};

static lv_obj_t   *s_scr;
static lv_obj_t   *s_value[TILE_COUNT];
static lv_timer_t *s_timer;

static void tile_create(lv_obj_t *parent, int col, int row, const char *caption,
                        lv_obj_t **value_out)
{
    int x = GRID_X + col * (TILE_W + TILE_GAP);
    int y = GRID_Y + row * (TILE_H + TILE_GAP);
    lv_obj_t *tile = ui_pixel_panel_create(parent, x, y, TILE_W, TILE_H, UI_PAPER);
    lv_obj_set_style_pad_all(tile, 6, 0);

    lv_obj_t *cap = ui_pixel_label(tile, caption, &lv_font_ui_cn_14, UI_INK_SOFT);
    lv_obj_set_pos(cap, 0, 0);

    lv_obj_t *val = ui_pixel_label(tile, "--", &lv_font_ui_cn_14, UI_ACCENT);
    lv_obj_set_pos(val, 0, 21);
    *value_out = val;
}

// lv_timer 跑在 LVGL 任务里,已持有锁,可直接操作对象。
static void tick(lv_timer_t *t) {
    (void)t;

    int64_t sec = esp_timer_get_time() / 1000000;
    int hh = (int)(sec / 3600);
    int mm = (int)((sec % 3600) / 60);
    int ss = (int)(sec % 60);
    lv_label_set_text_fmt(s_value[0], "%02d:%02d:%02d", hh, mm, ss);

    lv_label_set_text(s_value[1], usb_serial_jtag_is_connected() ? "已连接" : "未连接");

    int soc = bsp_battery_soc();
    if (soc < 0) lv_label_set_text(s_value[2], "--");
    else         lv_label_set_text_fmt(s_value[2], "%d%%", soc);

    int btn_mv = bsp_button_read_mv();
    lv_label_set_text_fmt(s_value[3], "%d mV", btn_mv);

    lv_label_set_text_fmt(s_value[4], "%u KB", (unsigned)(esp_get_free_heap_size() / 1024));

    esp_chip_info_t chip;
    esp_chip_info(&chip);
    lv_label_set_text_fmt(s_value[5], "v%d.%d", chip.revision / 100, chip.revision % 100);
}

void demo_status_enter(void) {
    s_scr = ui_pixel_screen_create("看板");

    for (int i = 0; i < TILE_COUNT; i++) {
        tile_create(s_scr, i % 2, i / 2, CAPTIONS[i], &s_value[i]);
    }

    tick(NULL);                                   // 先立刻显示一次,不用等第一个周期
    s_timer = lv_timer_create(tick, 500, NULL);
    lv_screen_load(s_scr);
}

void demo_status_exit(void) {
    if (s_timer) { lv_timer_delete(s_timer); s_timer = NULL; }
    if (s_scr) {
        lv_obj_delete(s_scr);
        s_scr = NULL;
        for (int i = 0; i < TILE_COUNT; i++) s_value[i] = NULL;
    }
}

void demo_status_key(bsp_btn_t btn, bsp_btn_ev_t ev) { (void)btn; (void)ev; }
