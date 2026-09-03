// main/demo_wifi.c —— Wi-Fi 状态与扫描结果的**显示页**。
//
// ⚠ 这个文件以前自己拥有一整套 Wi-Fi 生命周期(create netif / wifi_init /
// start / scan,退出时还 deinit + destroy_default_wifi)。那是错的:esp_netif
// 和 esp_wifi 是进程级单例,而当时仓库里还有第二个模块(面板的数据层)也在
// 做同样的事。两边各自的"初始化过了没"标志互相看不见,结果是
//
//   先看面板、再进这一页 → 这里无条件 esp_netif_create_default_wifi_sta()
//   → 撞上已经存在的 if_key → IDF 内部 assert → **直接重启**
//
// 反过来先进这一页再看面板,这里退出时的 deinit 会把驱动从面板脚下抽走,
// 而面板那边的总闸标志没有任何清零路径,只能重启恢复。
//
// 现在生命周期全部归 wifi_mgr 管(见 wifi_mgr.h),这个文件退化成一个纯粹的
// 观察者:只读状态、只发起扫描,一行 esp_wifi_* 都不碰,更不负责关掉它。
#include "demo.h"
#include "ui_pixel.h"
#include "wifi_mgr.h"

#include "lvgl.h"
#include <stdio.h>
#include <string.h>

#define WIFI_RESULT_COUNT 6   // 一屏能舒服地列出几条

static lv_obj_t   *s_scr;
static lv_obj_t   *s_status;
static lv_obj_t   *s_results;
static lv_timer_t *s_timer;

// 上一次画出来的状态,用来避免每 200ms 重排一次整块文本。
static wifi_mgr_state_t s_seen_state = (wifi_mgr_state_t)-1;
static int              s_seen_count = -1;
static bool             s_seen_busy;

static void render(void)
{
    switch (wifi_mgr_state()) {
    case WIFI_MGR_OFF:
        lv_label_set_text(s_status, "Wi-Fi 未启动\n按确定扫描附近网络");
        break;
    case WIFI_MGR_IDLE:
        lv_label_set_text(s_status, wifi_mgr_scan_busy() ? "正在扫描…" : "未连接\n按确定重新扫描");
        break;
    case WIFI_MGR_CONNECTING:
        lv_label_set_text(s_status, "正在连接…");
        break;
    case WIFI_MGR_CONNECTED: {
        char buf[96];
        snprintf(buf, sizeof(buf), "已连接 %s\n%s  %d dBm",
                 wifi_mgr_ssid(), wifi_mgr_ip(), wifi_mgr_rssi());
        lv_label_set_text(s_status, buf);
        break;
    }
    case WIFI_MGR_FAILED:
        lv_label_set_text(s_status, "连接失败\n在电脑上检查密码后重试");
        break;
    }

    int n = wifi_mgr_scan_count();
    if (n == 0) {
        lv_label_set_text(s_results,
            wifi_mgr_scan_busy() ? "" : "还没有扫描结果");
        return;
    }

    // 一次拼好整块文本再设一次 label —— 逐行 set_text 会让这块区域重绘 n 次。
    char list[WIFI_RESULT_COUNT * 40 + 1];
    int off = 0;
    for (int i = 0; i < n && i < WIFI_RESULT_COUNT; i++) {
        wifi_mgr_ap_t ap;
        if (!wifi_mgr_scan_entry(i, &ap)) break;
        int w = snprintf(list + off, sizeof(list) - off, "%4d  %s%s\n",
                         ap.rssi, ap.ssid, ap.secure ? "" : "  (开放)");
        if (w < 0 || (size_t)w >= sizeof(list) - off) break;
        off += w;
    }
    list[off] = '\0';
    lv_label_set_text(s_results, list);
}

static void tick(lv_timer_t *timer)
{
    (void)timer;
    // Wi-Fi 的状态变化来自另一个任务,这里轮询比让 wifi_mgr 的回调直接碰 LVGL
    // 安全得多 —— 那个回调跑在 Wi-Fi 事件任务里,没有 LVGL 锁。
    wifi_mgr_state_t st = wifi_mgr_state();
    int  n    = wifi_mgr_scan_count();
    bool busy = wifi_mgr_scan_busy();
    if (st == s_seen_state && n == s_seen_count && busy == s_seen_busy) return;
    s_seen_state = st;
    s_seen_count = n;
    s_seen_busy  = busy;
    render();
}

void demo_wifi_enter(void)
{
    s_scr = ui_pixel_screen_create("Wi-Fi");
    lv_obj_t *panel = ui_pixel_panel_create(s_scr, 12, 20, 216, 190, UI_PAPER);

    s_status = lv_label_create(panel);
    lv_obj_set_width(s_status, 190);
    lv_label_set_long_mode(s_status, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_font(s_status, &lv_font_ui_cn_14, 0);
    lv_obj_set_style_text_color(s_status, lv_color_hex(UI_ACCENT_DK), 0);
    lv_obj_align(s_status, LV_ALIGN_TOP_LEFT, 2, 2);

    s_results = lv_label_create(panel);
    lv_obj_set_width(s_results, 190);
    lv_label_set_long_mode(s_results, LV_LABEL_LONG_DOT);
    lv_obj_set_style_text_font(s_results, &lv_font_ui_cn_14, 0);
    lv_obj_set_style_text_color(s_results, lv_color_hex(UI_INK), 0);
    lv_obj_align(s_results, LV_ALIGN_TOP_LEFT, 2, 62);

    s_seen_state = (wifi_mgr_state_t)-1;   // 强制第一帧渲染
    s_timer = lv_timer_create(tick, 200, NULL);
    lv_screen_load(s_scr);
}

void demo_wifi_exit(void)
{
    if (s_timer) {
        lv_timer_delete(s_timer);
        s_timer = NULL;
    }
    // ⚠ 刻意什么都不关。协议栈是 wifi_mgr 的,不是这一页的 —— 退出一个只读
    // 页面就把整机的网络拆掉,正是本文件顶部说的那个事故。
    if (s_scr) {
        lv_obj_delete(s_scr);
        s_scr = NULL;
        s_status = s_results = NULL;
    }
}

void demo_wifi_key(bsp_btn_t btn, bsp_btn_ev_t ev)
{
    if (btn != BSP_BTN_OK || ev != BSP_BTN_CLICK) return;
    if (wifi_mgr_scan_busy()) return;
    wifi_mgr_scan_start();
}
