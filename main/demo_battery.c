// main/demo_battery.c —— CW2017 电量与电压,每秒刷新。
#include "demo.h"
#include "bsp_battery.h"
#include "ui_pixel.h"
#include "lvgl.h"

static lv_obj_t   *s_scr, *s_soc, *s_mv;
static lv_timer_t *s_timer;

// lv_timer 跑在 LVGL 任务里,已持有锁,可直接操作对象。
static void tick(lv_timer_t *t) {
    (void)t;
    int soc = bsp_battery_soc();
    int mv  = bsp_battery_mv();

    if (soc < 0) lv_label_set_text(s_soc, "-- %");
    else         lv_label_set_text_fmt(s_soc, "%d %%", soc);

    if (mv < 0)  lv_label_set_text(s_mv, "-- mV");
    else         lv_label_set_text_fmt(s_mv, "%d mV", mv);

    // 低电量变红,便于一眼判断
    lv_obj_set_style_text_color(s_soc,
        (soc >= 0 && soc < 20) ? lv_color_hex(UI_RED) : lv_color_hex(UI_SAGE_DK), 0);
}

void demo_battery_enter(void) {
    s_scr = ui_pixel_screen_create("电量");
    lv_obj_t *panel = ui_pixel_panel_create(s_scr, 24, 76, 192, 168, UI_PAPER);

    s_soc = lv_label_create(panel);
    lv_obj_set_style_text_font(s_soc, &lv_font_ui_cn_14, 0);
    lv_obj_set_style_text_color(s_soc, lv_color_hex(UI_INK), 0);
    lv_obj_align(s_soc, LV_ALIGN_TOP_MID, 0, 12);
    lv_label_set_text(s_soc, "-- %");

    s_mv = lv_label_create(panel);
    lv_obj_set_style_text_font(s_mv, &lv_font_ui_cn_14, 0);
    lv_obj_set_style_text_color(s_mv, lv_color_hex(UI_INK_SOFT), 0);
    lv_obj_align(s_mv, LV_ALIGN_TOP_MID, 0, 46);
    lv_label_set_text(s_mv, "-- mV");

    lv_obj_t *battery = lv_obj_create(panel);
    lv_obj_remove_flag(battery, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_pos(battery, 38, 86);
    lv_obj_set_size(battery, 100, 38);
    lv_obj_set_style_radius(battery, 0, 0);
    lv_obj_set_style_border_width(battery, 1, 0);
    lv_obj_set_style_pad_all(battery, 0, 0);
    lv_obj_set_style_bg_color(battery, lv_color_hex(UI_ACCENT_BG), 0);
    lv_obj_set_style_border_color(battery, lv_color_hex(UI_ACCENT), 0);

    tick(NULL);                                   // 先立刻显示一次,不用等 1 秒
    s_timer = lv_timer_create(tick, 1000, NULL);
    lv_screen_load(s_scr);
}

void demo_battery_exit(void) {
    if (s_timer) { lv_timer_delete(s_timer); s_timer = NULL; }
    if (s_scr) { lv_obj_delete(s_scr); s_scr = NULL; s_soc = s_mv = NULL; }
}

void demo_battery_key(bsp_btn_t btn, bsp_btn_ev_t ev) { (void)btn; (void)ev; }
