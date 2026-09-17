// Wi-Fi settings is a viewer/controller of the process-wide manager. Leaving
// the page only deletes its timer and objects; the radio remains independently
// owned by wifi_mgr. All methods here run under the main LVGL lock.
#include "demo.h"
#include "ui_pixel.h"
#include "wifi_mgr.h"

#include "lvgl.h"
#include <stdio.h>
#include <string.h>

#define WIFI_VISIBLE_ROWS 4

static lv_obj_t *s_scr, *s_status, *s_position;
static lv_obj_t *s_rows[WIFI_VISIBLE_ROWS];
static lv_obj_t *s_names[WIFI_VISIBLE_ROWS];
static lv_obj_t *s_details[WIFI_VISIBLE_ROWS];
static lv_timer_t *s_timer;
static wifi_mgr_ap_t s_networks[WIFI_MGR_MAX_SCAN];
static int s_count, s_selected, s_first;
static uint32_t s_seen_revision, s_seen_scan;
static bool s_action_failed;

static void display_ssid(char *out, size_t capacity, const char *ssid)
{
    size_t i = 0;
    for (; i + 1 < capacity && ssid[i]; ++i) {
        unsigned char c = (unsigned char)ssid[i];
        out[i] = c < 32 || c == 127 ? ' ' : (char)c;
    }
    out[i] = '\0';
}

static void refresh_networks(const wifi_mgr_snapshot_t *snapshot)
{
    if (snapshot->scan_revision == s_seen_scan) return;
    // Keep focus on the same SSID (or action) when another endpoint rescans.
    int action = s_selected >= s_count ? s_selected - s_count : -1;
    wifi_mgr_ap_t previous = { 0 };
    if (action < 0 && s_selected < s_count) previous = s_networks[s_selected];
    s_count = 0;
    for (int i = 0; i < snapshot->scan_count && i < WIFI_MGR_MAX_SCAN; ++i) {
        if (wifi_mgr_scan_entry(i, &s_networks[s_count])) ++s_count;
    }
    s_selected = action >= 0 ? s_count + action : 0;
    if (action < 0) {
        for (int i = 0; i < s_count; ++i) {
            if (previous.secure == s_networks[i].secure &&
                strcmp(previous.ssid, s_networks[i].ssid) == 0) s_selected = i;
        }
    }
    // The initial automatic scan should focus its first network, not leave the
    // cursor on the rescan button that was visible while the list was empty.
    if (s_seen_scan == UINT32_MAX || (s_seen_scan == 0 && s_count > 0)) s_selected = 0;
    s_seen_scan = snapshot->scan_revision;
}

static void render(void)
{
    wifi_mgr_snapshot_t snapshot;
    wifi_mgr_snapshot(&snapshot);
    refresh_networks(&snapshot);
    s_seen_revision = snapshot.revision;
    char status[160], ssid[WIFI_MGR_SSID_LEN];
    display_ssid(ssid, sizeof(ssid), snapshot.ssid);
    if (s_action_failed) {
        snprintf(status, sizeof(status), "Wi-Fi 暂不可用\n请稍后重试");
    } else if (snapshot.pending_ssid[0] && snapshot.pending_secure) {
        snprintf(status, sizeof(status), "请在手机/电脑输入密码\n并点 写入到设备");
    } else if (snapshot.scan_status == WIFI_MGR_SCAN_SCANNING) {
        snprintf(status, sizeof(status), "%s\n可用网络将自动更新",
                 snapshot.state == WIFI_MGR_CONNECTING ? "连接完成后扫描..." : "正在扫描附近网络...");
    } else if (snapshot.scan_status == WIFI_MGR_SCAN_FAILED) {
        snprintf(status, sizeof(status), "扫描失败\n请选择重新扫描");
    } else if (snapshot.state == WIFI_MGR_CONNECTING) {
        snprintf(status, sizeof(status), "正在连接\n%s", ssid);
    } else if (snapshot.state == WIFI_MGR_FAILED) {
        snprintf(status, sizeof(status), "连接失败，请检查密码\n在手机/电脑写入后重试");
    } else if (snapshot.state == WIFI_MGR_CONNECTED) {
        snprintf(status, sizeof(status), "已连接 %s\n%s", ssid, snapshot.ip);
    } else if (snapshot.scan_status == WIFI_MGR_SCAN_READY && s_count == 0) {
        snprintf(status, sizeof(status), "未发现可用网络\n请靠近路由器后重新扫描");
    } else {
        snprintf(status, sizeof(status), "未连接 / %d 个网络\n选择网络，按确定连接", s_count);
    }
    lv_label_set_text(s_status, status);
    bool failure = s_action_failed || snapshot.scan_status == WIFI_MGR_SCAN_FAILED ||
                   snapshot.state == WIFI_MGR_FAILED;
    lv_obj_set_style_text_color(s_status, lv_color_hex(failure ? UI_RED : UI_INK_SOFT), 0);

    int total = s_count + 2;
    if (s_selected >= total) s_selected = total - 1;
    if (s_selected < s_first) s_first = s_selected;
    if (s_selected >= s_first + WIFI_VISIBLE_ROWS) s_first = s_selected - WIFI_VISIBLE_ROWS + 1;
    if (s_first > total - WIFI_VISIBLE_ROWS) s_first = total - WIFI_VISIBLE_ROWS;
    if (s_first < 0) s_first = 0;
    for (int row = 0; row < WIFI_VISIBLE_ROWS; ++row) {
        int index = s_first + row;
        if (index >= total) {
            lv_obj_add_flag(s_rows[row], LV_OBJ_FLAG_HIDDEN);
            continue;
        }
        lv_obj_remove_flag(s_rows[row], LV_OBJ_FLAG_HIDDEN);
        ui_pixel_mark(s_rows[row], index == s_selected);
        if (index < s_count) {
            display_ssid(ssid, sizeof(ssid), s_networks[index].ssid);
            lv_label_set_text(s_names[row], ssid);
            const char *detail = s_networks[index].secure ? "密码" : "开放";
            if (snapshot.state == WIFI_MGR_CONNECTED &&
                strcmp(s_networks[index].ssid, snapshot.ssid) == 0) detail = "已连";
            lv_label_set_text(s_details[row], detail);
        } else {
            lv_label_set_text(s_names[row], index == s_count ? "重新扫描" : "断开连接");
            lv_label_set_text(s_details[row], "");
        }
    }
    lv_label_set_text_fmt(s_position, "%d/%d", s_selected + 1, total);
}

static void tick(lv_timer_t *timer)
{
    (void)timer;
    wifi_mgr_snapshot_t snapshot;
    wifi_mgr_snapshot(&snapshot);
    if (snapshot.revision == s_seen_revision) return;
    s_action_failed = false;
    render();
}

void demo_wifi_enter(void)
{
    s_count = s_selected = s_first = 0;
    s_seen_revision = s_seen_scan = UINT32_MAX;
    s_action_failed = false;
    s_scr = ui_pixel_screen_create("Wi-Fi");
    lv_obj_t *title = ui_pixel_label(s_scr, "Wi-Fi 网络", &lv_font_ui_cn_14, UI_INK);
    lv_obj_set_pos(title, 16, 2);
    s_position = ui_pixel_label(s_scr, "", &lv_font_montserrat_14, UI_MUTED);
    lv_obj_set_pos(s_position, 183, 9);

    s_status = ui_pixel_label(s_scr, "", &lv_font_ui_cn_14, UI_INK_SOFT);
    lv_obj_set_pos(s_status, 16, 32);
    lv_obj_set_size(s_status, 208, 54);
    lv_label_set_long_mode(s_status, LV_LABEL_LONG_DOT);
    for (int row = 0; row < WIFI_VISIBLE_ROWS; ++row) {
        s_rows[row] = ui_pixel_panel_create(s_scr, 12, 94 + row * 37, 216, 34, UI_PAPER);
        lv_obj_set_style_pad_all(s_rows[row], 0, 0);
        s_names[row] = ui_pixel_label(s_rows[row], "", &lv_font_ui_cn_14, UI_INK);
        lv_obj_set_pos(s_names[row], 6, 2);
        lv_obj_set_size(s_names[row], 152, 27);
        lv_label_set_long_mode(s_names[row], LV_LABEL_LONG_DOT);
        s_details[row] = ui_pixel_label(s_rows[row], "", &lv_font_ui_cn_14, UI_INK_SOFT);
        lv_obj_set_pos(s_details[row], 172, 2);
        lv_obj_set_size(s_details[row], 36, 27);
    }
    lv_obj_t *footer = ui_pixel_label(s_scr, "上下选择 | 确定连接 | 长按返回", &lv_font_ui_cn_14, UI_MUTED);
    lv_obj_align(footer, LV_ALIGN_BOTTOM_MID, 0, -8);
    s_action_failed = !wifi_mgr_scan_start();
    render();
    s_timer = lv_timer_create(tick, 150, NULL);
    lv_screen_load(s_scr);
}

void demo_wifi_exit(void)
{
    if (s_timer) { lv_timer_delete(s_timer); s_timer = NULL; }
    if (s_scr) { lv_obj_delete(s_scr); s_scr = NULL; }
    s_status = s_position = NULL;
    // No manager callback holds any page pointer. The radio/worker remains
    // available to the companion after the user returns to Settings.
}

void demo_wifi_key(bsp_btn_t btn, bsp_btn_ev_t ev)
{
    if (ev != BSP_BTN_CLICK || !s_scr) return;
    s_action_failed = false;
    if (btn == BSP_BTN_UP) {
        s_selected = (s_selected + s_count + 1) % (s_count + 2);
    } else if (btn == BSP_BTN_DOWN) {
        s_selected = (s_selected + 1) % (s_count + 2);
    } else if (btn == BSP_BTN_OK) {
        if (s_selected < s_count) {
            // Use exactly the SSID shown when the button was pressed. A scan
            // result arriving concurrently must not change this selection.
            s_action_failed = !wifi_mgr_select_ap(&s_networks[s_selected]);
        } else if (s_selected == s_count) {
            s_action_failed = !wifi_mgr_scan_start();
        } else {
            wifi_mgr_disconnect();
        }
    }
    render();
}
