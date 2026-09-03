// main/demo_appstore.c —— "固件升级"页的界面层:应用列表、安装进度、错误提示。
//
// 这个文件只管 LVGL 和按键。BLE 服务、分片重组、固件流式 OTA 写入、批量确认
// 协议全部在 appstore_transfer.c 里,两者之间只通过 appstore_transfer.h 那个
// 窄接口打交道 —— 这里不 include 任何 NimBLE/esp_ota 头文件,也拿不到那边的
// 任何内部状态。
#include "appstore_transfer.h"
#include "demo.h"
#include "ui_pixel.h"
#include "ui_statusbar.h"

#include "lvgl.h"
#include <stdbool.h>

// ---- 列表布局 ---------------------------------------------------------------
#define APPSTORE_LIST_VISIBLE_ROWS 5
#define APPSTORE_LIST_ROW_X        14
#define APPSTORE_LIST_ROW_Y0       44
#define APPSTORE_LIST_ROW_W        212
#define APPSTORE_LIST_ROW_H        32
#define APPSTORE_LIST_ROW_STEP     34

typedef enum {
    APPSTORE_VIEW_LIST = 0,     // 浏览应用目录
    APPSTORE_VIEW_INSTALLING,   // 正在接收/写入选中的应用
} appstore_view_t;

static appstore_view_t s_view;
static int             s_app_sel;    // 当前选中项
static bool            s_ui_dirty;   // 纯 UI 状态(选中项/视图)变化引起的重绘

static lv_obj_t *s_scr;
static lv_obj_t *s_status;
static lv_obj_t *s_footer;
static lv_obj_t *s_list_cards[APPSTORE_LIST_VISIBLE_ROWS];
static lv_obj_t *s_list_rows[APPSTORE_LIST_VISIBLE_ROWS];
static lv_obj_t *s_progress_label;   // APPSTORE_VIEW_INSTALLING 专用,居中显示进度/错误
static lv_timer_t *s_timer;

static void move_selection(int *sel, int count, bool up)
{
    if (count <= 0) return;
    if (up) {
        if (*sel > 0) (*sel)--;
    } else {
        if (*sel < count - 1) (*sel)++;
    }
    s_ui_dirty = true;
}

static void render_list(void)
{
    int count = appstore_transfer_app_count();
    int scroll_top = 0;
    if (s_app_sel >= APPSTORE_LIST_VISIBLE_ROWS) {
        scroll_top = s_app_sel - APPSTORE_LIST_VISIBLE_ROWS + 1;
    }
    for (int r = 0; r < APPSTORE_LIST_VISIBLE_ROWS; r++) {
        int idx = scroll_top + r;
        if (idx >= count) {
            lv_obj_add_flag(s_list_cards[r], LV_OBJ_FLAG_HIDDEN);
            continue;
        }
        lv_obj_remove_flag(s_list_cards[r], LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(s_list_rows[r], appstore_transfer_app_text(idx));
        ui_pixel_set_selected(s_list_cards[r], idx == s_app_sel, true);
    }
}

static void render_installing(void)
{
    if (appstore_transfer_error_pending()) {
        lv_label_set_text(s_progress_label, appstore_transfer_error_text());
        lv_obj_set_style_text_color(s_progress_label, lv_color_hex(UI_RED), 0);
    } else {
        int total = appstore_transfer_install_total();
        lv_label_set_text_fmt(s_progress_label, "正在安装...\n%d/%d",
                              appstore_transfer_install_received(), total > 0 ? total : 1);
        lv_obj_set_style_text_color(s_progress_label, lv_color_hex(UI_INK_SOFT), 0);
    }
    lv_obj_set_style_text_align(s_progress_label, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(s_progress_label, LV_ALIGN_CENTER, 0, 0);
}

static void render_content(void)
{
    bool listing = (s_view == APPSTORE_VIEW_LIST);
    bool pinned  = appstore_transfer_error_pending();

    if (listing) {
        lv_obj_add_flag(s_progress_label, LV_OBJ_FLAG_HIDDEN);
        for (int r = 0; r < APPSTORE_LIST_VISIBLE_ROWS; r++) {
            lv_obj_remove_flag(s_list_cards[r], LV_OBJ_FLAG_HIDDEN);
        }
        render_list();
        lv_label_set_text(s_footer, pinned ? "按任意键关闭" : "上/下选择  确定升级");
    } else {
        for (int r = 0; r < APPSTORE_LIST_VISIBLE_ROWS; r++) {
            lv_obj_add_flag(s_list_cards[r], LV_OBJ_FLAG_HIDDEN);
        }
        lv_obj_remove_flag(s_progress_label, LV_OBJ_FLAG_HIDDEN);
        render_installing();
        lv_label_set_text(s_footer, pinned ? "按任意键关闭" : "请稍候,不要断开连接");
    }
}

static void tick(lv_timer_t *timer)
{
    (void)timer;
    switch (appstore_transfer_get_state()) {
    case APPSTORE_TRANSFER_STARTING:
        lv_obj_remove_flag(s_status, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(s_status, "正在启动蓝牙...");
        break;
    case APPSTORE_TRANSFER_ADVERTISING:
        lv_obj_remove_flag(s_status, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(s_status, "正在广播,等待连接");
        break;
    case APPSTORE_TRANSFER_CONNECTED:
        if (s_view == APPSTORE_VIEW_LIST) {
            lv_obj_remove_flag(s_status, LV_OBJ_FLAG_HIDDEN);
            lv_label_set_text(s_status,
                appstore_transfer_app_count() > 0 ? "选择要安装的固件" : "加载中");
        } else {
            lv_obj_add_flag(s_status, LV_OBJ_FLAG_HIDDEN);
        }
        break;
    case APPSTORE_TRANSFER_FAILED:
        lv_obj_remove_flag(s_status, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text_fmt(s_status, "蓝牙失败: %d", appstore_transfer_last_error());
        break;
    default:
        break;
    }

    // 安装可以由对端直接发起(Mac 上点"安装"就开始推固件,不需要先在设备上
    // 按确定)—— 这时设备这边没有经过下面 demo_appstore_key() 的那条路径,
    // 视图还停在列表上。靠传输层"是否正在安装"这个事实把界面切过去,而不是
    // 靠"用户按过确定"这个动作,两种发起方式就都能正确显示进度了。
    if (s_view == APPSTORE_VIEW_LIST && appstore_transfer_is_installing()) {
        s_view = APPSTORE_VIEW_INSTALLING;
        s_ui_dirty = true;
    }

    // 两个来源:传输层的数据变化(收到目录条目/进度推进/出错),以及本文件
    // 自己的界面状态变化(选中项移动/视图切换)。任一有变化就重绘一次。
    bool transfer_dirty = appstore_transfer_consume_dirty();
    if (transfer_dirty || s_ui_dirty) {
        s_ui_dirty = false;
        render_content();
    }
}

void demo_appstore_enter(void)
{
    s_scr = ui_pixel_screen_create("固件升级");

    s_status = lv_label_create(s_scr);
    lv_obj_set_pos(s_status, 14, 14);
    lv_obj_set_width(s_status, 208);
    // 跟 demo_remote.c 的标题同一个道理:LVGL 默认 LV_LABEL_LONG_WRAP,状态
    // 一长就换到第二行,而列表第一行在 y=44、这行字在 y=14 只有 30px 的位置,
    // 换出来的第二行正好压在列表上。这里的状态都是一句话,占一行就够。
    lv_label_set_long_mode(s_status, LV_LABEL_LONG_DOT);
    // LONG_DOT 要配固定高度才生效,理由见 demo_remote.c 里那段说明。
    lv_obj_set_height(s_status, UI_FOOTER_H);
    lv_obj_set_style_text_font(s_status, &lv_font_ui_cn_14, 0);
    lv_obj_set_style_text_color(s_status, lv_color_hex(UI_INK_SOFT), 0);
    lv_label_set_text(s_status, "正在启动蓝牙...");

    for (int r = 0; r < APPSTORE_LIST_VISIBLE_ROWS; r++) {
        int y = APPSTORE_LIST_ROW_Y0 + r * APPSTORE_LIST_ROW_STEP;
        lv_obj_t *card = ui_pixel_panel_create(s_scr, APPSTORE_LIST_ROW_X, y,
                                               APPSTORE_LIST_ROW_W, APPSTORE_LIST_ROW_H, UI_PAPER);
        lv_obj_t *row = lv_label_create(card);
        lv_obj_set_style_text_font(row, &lv_font_ui_cn_14, 0);
        lv_obj_set_style_text_color(row, lv_color_hex(UI_INK), 0);
        lv_obj_align(row, LV_ALIGN_LEFT_MID, 9, 0);
        lv_obj_add_flag(card, LV_OBJ_FLAG_HIDDEN);
        s_list_cards[r] = card;
        s_list_rows[r] = row;
    }

    s_progress_label = lv_label_create(s_scr);
    lv_obj_set_width(s_progress_label, 190);
    lv_label_set_long_mode(s_progress_label, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_font(s_progress_label, &lv_font_ui_cn_14, 0);
    lv_obj_add_flag(s_progress_label, LV_OBJ_FLAG_HIDDEN);

    s_footer = ui_pixel_label(s_scr, "上/下选择  确定升级", &lv_font_ui_cn_14, UI_MUTED);
    lv_obj_align(s_footer, LV_ALIGN_BOTTOM_MID, 0, -8);

    s_view = APPSTORE_VIEW_LIST;
    s_app_sel = 0;
    s_ui_dirty = true;

    s_timer = lv_timer_create(tick, 100, NULL);
    lv_screen_load(s_scr);
}

void demo_appstore_exit(void)
{
    if (s_timer) {
        lv_timer_delete(s_timer);
        s_timer = NULL;
    }
    if (s_scr) {
        lv_obj_delete(s_scr);
        s_scr = NULL;
    }
}

void demo_appstore_key(bsp_btn_t btn, bsp_btn_ev_t ev)
{
    // 错误提示钉住时优先级最高,吞掉所有按键,只有真正的一次按键动作才关闭
    // 它 —— 跟 demo_codex.c 里 s_error_pinned 的处理是同一个模式。
    if (appstore_transfer_error_pending()) {
        if (ev == BSP_BTN_CLICK || ev == BSP_BTN_LONG || ev == BSP_BTN_DOUBLE) {
            appstore_transfer_clear_error();
            s_view = APPSTORE_VIEW_LIST;   // 装失败回到列表,不是继续停在安装画面
            s_ui_dirty = true;
        }
        return;
    }

    if (s_view != APPSTORE_VIEW_LIST) {
        return;   // 正在安装:不响应任何按键(也没有可以取消的中间状态)
    }

    bool up_down = (btn == BSP_BTN_UP || btn == BSP_BTN_DOWN);
    bool nav = up_down && (ev == BSP_BTN_CLICK || ev == BSP_BTN_HOLD);
    bool ok_click = (btn == BSP_BTN_OK && ev == BSP_BTN_CLICK);

    if (nav) {
        move_selection(&s_app_sel, appstore_transfer_app_count(), btn == BSP_BTN_UP);
    } else if (ok_click) {
        if (appstore_transfer_app_count() > 0) {
            s_view = APPSTORE_VIEW_INSTALLING;
            s_ui_dirty = true;
            appstore_transfer_install(s_app_sel);
        }
    }
}
