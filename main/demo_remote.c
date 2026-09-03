// main/demo_remote.c —— 远程界面的渲染层。
//
// 只做两件事:把 remote_ui 收到的屏幕快照画出来、把按键原样回传。
// 这个文件里没有任何"应用"的概念 —— 显示的是服务器面板还是待办列表,
// 完全由对端决定,设备这边一视同仁。
#include "demo.h"
#include "remote_ui.h"
#include "ble_hub.h"
#include "ui_pixel.h"
#include "ui_statusbar.h"

#include "lvgl.h"
#include <stdio.h>

#define ROW_X        14
#define ROW_W        212
#define ROW_TOP      44
#define ROW_STEP     22
// 一行文字的高度。⚠ 是 27 不是 14 —— lv_font_ui_cn_14 的 line_height 就是 27。
#define LINE_H       UI_FOOTER_H

#define BAR_H        10
// 标签基线到进度条顶端的距离。原来是 17 —— 14px 的字实际占 16px 高,等于条
// 就贴在字的下缘上,挤成一团看不出哪是哪。给它一行呼吸的余量。
#define BAR_LABEL_GAP 22
#define BAR_ROW_STEP  40   // 进度条那一行要放下标签 + 间距 + 条,比纯文本行高

static lv_obj_t   *s_scr;
static lv_obj_t   *s_title;
static lv_obj_t   *s_hint;      // 没有内容时的提示
static lv_obj_t   *s_footer;
static lv_obj_t   *s_mic;       // 录音指示,只在对端声明收语音时出现
static lv_obj_t   *s_labels[REMOTE_UI_MAX_ROWS];
static lv_obj_t   *s_bar_bg[REMOTE_UI_MAX_ROWS];
static lv_obj_t   *s_bar_fill[REMOTE_UI_MAX_ROWS];
static lv_timer_t *s_timer;
static uint32_t    s_seen_revision;
static bool        s_forced_redraw;

static void hide_all_rows(void)
{
    for (int i = 0; i < REMOTE_UI_MAX_ROWS; i++) {
        lv_obj_add_flag(s_labels[i], LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_bar_bg[i], LV_OBJ_FLAG_HIDDEN);
        lv_obj_add_flag(s_bar_fill[i], LV_OBJ_FLAG_HIDDEN);
    }
}

static void render(void)
{
    remote_screen_t scr;
    bool have = remote_ui_snapshot(&scr);
    hide_all_rows();

    if (!have) {
        lv_obj_remove_flag(s_hint, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(s_hint,
            ble_hub_is_connected() ? "已连接,等待电脑推送内容…"
                                   : "等待电脑连接…\n\n请确认配套 app 正在运行");
        lv_label_set_text(s_title, "远程");
        lv_label_set_text(s_footer, "长按确定返回");
        return;
    }
    lv_obj_add_flag(s_hint, LV_OBJ_FLAG_HIDDEN);

    lv_label_set_text(s_title, scr.title[0] ? scr.title : "远程");
    lv_label_set_text(s_footer, scr.footer[0] ? scr.footer : "长按确定返回");

    // 录音指示:只在对端声明这一屏收语音时才出现。正在录的时候变成实心红点,
    // 否则是一句提示 —— 没有反馈的话,用户按住下键说完一句完全不知道设备到底
    // 有没有在听。
    if (scr.walkie) {
        lv_obj_remove_flag(s_mic, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(s_mic, "按住下键讲话");
        lv_obj_set_style_text_color(s_mic, lv_color_hex(UI_MUTED), 0);
    } else if (scr.mic) {
        lv_obj_remove_flag(s_mic, LV_OBJ_FLAG_HIDDEN);
        bool rec = codex_voice_active();
        lv_label_set_text(s_mic, rec ? "● 正在录音…" : "长按下键说话");
        lv_obj_set_style_text_color(s_mic, lv_color_hex(rec ? UI_RED : UI_MUTED), 0);
    } else {
        lv_obj_add_flag(s_mic, LV_OBJ_FLAG_HIDDEN);
    }

    int y = ROW_TOP;
    for (int i = 0; i < scr.row_count; i++) {
        // 整行放得下才画。
        //
        // ⚠ 两个都容易搞错的地方:
        // 1. 比的是**内容区**坐标,不是屏幕绝对坐标 —— 顶部状态栏那一条已经
        //    从可用高度里扣掉了(UI_CONTENT_BOTTOM),再写死 320 会多算一行。
        // 2. 要按**整行高度**判断,不能只看行起点。进度条那种行比纯文本行高
        //    一截,起点合法但条画出来正好压在底部提示上 —— 而且只有内容恰好
        //    排到最后一行时才出现。
        int row_h = (scr.rows[i].kind == REMOTE_ROW_BAR) ? BAR_ROW_STEP : ROW_STEP;
        if (y + row_h > UI_CONTENT_BOTTOM) break;

        if (scr.rows[i].kind == REMOTE_ROW_BAR) {
            lv_obj_remove_flag(s_labels[i], LV_OBJ_FLAG_HIDDEN);
            lv_label_set_text_fmt(s_labels[i], "%s %d%%",
                                  scr.rows[i].text, scr.rows[i].percent);
            lv_obj_set_pos(s_labels[i], ROW_X, y);

            lv_obj_remove_flag(s_bar_bg[i], LV_OBJ_FLAG_HIDDEN);
            lv_obj_set_pos(s_bar_bg[i], ROW_X, y + BAR_LABEL_GAP);
            lv_obj_set_size(s_bar_bg[i], ROW_W, BAR_H);

            int w = ROW_W * scr.rows[i].percent / 100;
            if (w < 2 && scr.rows[i].percent > 0) w = 2;  // 有值就画出来一点
            lv_obj_remove_flag(s_bar_fill[i], LV_OBJ_FLAG_HIDDEN);
            lv_obj_set_pos(s_bar_fill[i], ROW_X, y + BAR_LABEL_GAP);
            lv_obj_set_size(s_bar_fill[i], w, BAR_H);
            // 高占用变红:磁盘快满、内存吃紧要一眼看出来,而不是让用户
            // 自己去读数字再判断。
            lv_obj_set_style_bg_color(s_bar_fill[i],
                lv_color_hex(scr.rows[i].percent >= 85 ? UI_RED : UI_ACCENT), 0);
            y += BAR_ROW_STEP;
        } else {
            lv_obj_remove_flag(s_labels[i], LV_OBJ_FLAG_HIDDEN);
            lv_label_set_text(s_labels[i], scr.rows[i].text);
            lv_obj_set_pos(s_labels[i], ROW_X, y);
            y += ROW_STEP;
        }
    }
}

static void tick(lv_timer_t *timer)
{
    (void)timer;
    uint32_t rev = remote_ui_revision();
    if (rev != s_seen_revision || s_forced_redraw) {
        s_seen_revision = rev;
        s_forced_redraw = false;
        render();
        return;
    }
    // 还没收到过内容时,连接状态本身就是要显示的信息,状态一变就重绘。
    if (rev == 0) {
        static bool last_connected;
        bool now = ble_hub_is_connected();
        if (now != last_connected) { last_connected = now; render(); }
    }
}

void demo_remote_enter(void)
{
    s_scr = ui_pixel_screen_create("远程");

    s_title = lv_label_create(s_scr);
    lv_obj_set_pos(s_title, ROW_X, 14);
    lv_obj_set_width(s_title, ROW_W);
    // ⚠ LONG_DOT 必须配一个**固定高度**才有用。
    //
    // 看 LVGL 的实现(lv_label.c 的 LV_LABEL_LONG_MODE_DOTS 分支):省略号只在
    // `文本高度 > label 高度` 时才加。而 label 的默认高度是 LV_SIZE_CONTENT ——
    // 它会自己长高去装下换行后的文本,于是这个条件**永远不成立**:照样换行,
    // 一个省略号都没有。只设 LONG_DOT 等于没设。
    //
    // 把高度钉死成一行,文本一超就真的被截成省略号了。
    lv_label_set_long_mode(s_title, LV_LABEL_LONG_DOT);
    lv_obj_set_height(s_title, LINE_H);
    lv_obj_set_style_text_font(s_title, &lv_font_ui_cn_14, 0);
    lv_obj_set_style_text_color(s_title, lv_color_hex(UI_ACCENT), 0);
    lv_label_set_text(s_title, "远程");

    s_hint = lv_label_create(s_scr);
    lv_obj_set_pos(s_hint, ROW_X, 60);
    lv_obj_set_width(s_hint, ROW_W);
    lv_label_set_long_mode(s_hint, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_font(s_hint, &lv_font_ui_cn_14, 0);
    lv_obj_set_style_text_color(s_hint, lv_color_hex(UI_INK_SOFT), 0);
    lv_label_set_text(s_hint, "等待电脑连接…");

    for (int i = 0; i < REMOTE_UI_MAX_ROWS; i++) {
        s_labels[i] = lv_label_create(s_scr);
        lv_obj_set_width(s_labels[i], ROW_W);
        lv_label_set_long_mode(s_labels[i], LV_LABEL_LONG_DOT);
        // 同上:LONG_DOT 得配固定高度才生效。不钉高度的话,一行长文本会换成
        // 两行、把下一行盖住 —— 而行距只有 22,叠得严严实实。
        lv_obj_set_height(s_labels[i], LINE_H);
        lv_obj_set_style_text_font(s_labels[i], &lv_font_ui_cn_14, 0);
        lv_obj_set_style_text_color(s_labels[i], lv_color_hex(UI_INK), 0);
        lv_obj_add_flag(s_labels[i], LV_OBJ_FLAG_HIDDEN);

        s_bar_bg[i] = ui_pixel_panel_create(s_scr, ROW_X, 0, ROW_W, BAR_H, UI_PAPER);
        lv_obj_add_flag(s_bar_bg[i], LV_OBJ_FLAG_HIDDEN);
        s_bar_fill[i] = ui_pixel_panel_create(s_scr, ROW_X, 0, 1, BAR_H, UI_ACCENT);
        lv_obj_add_flag(s_bar_fill[i], LV_OBJ_FLAG_HIDDEN);
    }

    // 底部两行同样要限宽 + 省略号。ui_pixel_label 建出来的 label 是
    // LV_SIZE_CONTENT 的:文本一长就朝两边撑,居中对齐之下会同时溢出屏幕
    // 左右两边 —— 不会换行,但左右各被切掉一截,中间那段还看不出被切过。
    s_footer = ui_pixel_label(s_scr, "长按确定返回", &lv_font_ui_cn_14, UI_MUTED);
    lv_obj_set_width(s_footer, ROW_W);
    lv_label_set_long_mode(s_footer, LV_LABEL_LONG_DOT);
    lv_obj_set_height(s_footer, LINE_H);
    lv_obj_set_style_text_align(s_footer, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(s_footer, LV_ALIGN_BOTTOM_MID, 0, -8);

    s_mic = ui_pixel_label(s_scr, "", &lv_font_ui_cn_14, UI_MUTED);
    lv_obj_set_width(s_mic, ROW_W);
    lv_label_set_long_mode(s_mic, LV_LABEL_LONG_DOT);
    lv_obj_set_height(s_mic, LINE_H);
    lv_obj_set_style_text_align(s_mic, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(s_mic, LV_ALIGN_BOTTOM_MID, 0, -8 - UI_FOOTER_H);
    lv_obj_add_flag(s_mic, LV_OBJ_FLAG_HIDDEN);

    s_seen_revision = 0;
    s_forced_redraw = true;
    s_timer = lv_timer_create(tick, 150, NULL);
    lv_screen_load(s_scr);
    remote_ui_set_active(true);   // 告诉对端可以开始推了
}

void demo_remote_exit(void)
{
    // ⚠ 先停录音,再拆页面。
    //
    // 这一页不只被按键操作退出:main.c 的 install_push_check() 跑在
    // usb_keepalive_task 里,对端一推固件安装,它就会在**任意时刻**把这一页
    // 拆掉切去进度页 —— 跟用户是不是正按着下键说话毫无关系。
    //
    // 不在这里停的话,录音任务会一直跑到 15 秒硬上限:麦克风开着、持续往
    // AUDIO 特征值推分片,跟固件传输抢同一条 BLE 链路;而用户松手时视图已经
    // 换了,那个 LONG_UP 会被别的页面吞掉,谁也不会来收尾。
    codex_voice_stop();

    remote_ui_set_active(false);  // 让对端知道没人看了,可以停掉轮询省电
    if (s_timer) {
        lv_timer_delete(s_timer);
        s_timer = NULL;
    }
    if (s_scr) {
        lv_obj_delete(s_scr);
        s_scr = NULL;
        s_title = s_hint = s_footer = s_mic = NULL;
        for (int i = 0; i < REMOTE_UI_MAX_ROWS; i++) {
            s_labels[i] = s_bar_bg[i] = s_bar_fill[i] = NULL;
        }
    }
}

void demo_remote_key(bsp_btn_t btn, bsp_btn_ev_t ev)
{
    // 对讲模式必须使用物理按下/抬起边沿。等到 LONG 才开始会白白损失
    // CONFIG_BUTTON_LONG_PRESS_TIME_MS(当前 500ms),短按甚至根本说不出去。
    // DOWN 的 CLICK/LONG/HOLD/LONG_UP 都吞掉,避免一次动作被重复解释。
    remote_screen_t scr;
    if (remote_ui_snapshot(&scr) && scr.walkie && btn == BSP_BTN_DOWN) {
        if (ev == BSP_BTN_PRESS || ev == BSP_BTN_RELEASE) {
            remote_ui_send_key(btn, ev);
        }
        return;
    }

    // 语音是唯一一个**设备自己处理、不回传**的手势。
    //
    // 为什么它必须在这里被截住:麦克风在设备上,录音的起停是硬件动作,发给
    // 对端再让它发回一条"开始录音"的命令会平白多一个来回,而按住说话这件事
    // 对延迟很敏感。对端的角色只是在屏幕描述里声明"我这一屏收语音"(M1),
    // 具体怎么触发由设备决定。
    if (remote_ui_snapshot(&scr) && scr.mic && btn == BSP_BTN_DOWN) {
        if (ev == BSP_BTN_LONG) {
            codex_voice_start();
            s_forced_redraw = true;      // 让指示灯立刻亮起来
            return;
        }
        if (ev == BSP_BTN_LONG_UP) {
            codex_voice_stop();
            s_forced_redraw = true;
            return;
        }
    }

    // 其余的原样回传,不在设备上解释语义 —— 上/下是翻页还是选中、确定是刷新
    // 还是打开,全由对端当前跑的那个应用决定。长按确定已经被 main.c 拦截用作
    // 返回上一层,不会走到这里。
    if (ev == BSP_BTN_CLICK || ev == BSP_BTN_HOLD || ev == BSP_BTN_DOUBLE) {
        remote_ui_send_key(btn, ev);
    }
}
