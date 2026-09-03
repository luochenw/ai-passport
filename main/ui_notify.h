#pragma once

#include <stdbool.h>

// 全局通知层
// ==========
//
// 解决的问题:**只有前台应用能推屏**(配套 app 的 RemoteAppHost 里
// `guard self.current === app`)。后台应用有事要说 —— 面板发现磁盘满了、
// Codex 任务跑完了 —— 现在没有任何通道能到达用户。
//
// 为什么画在 lv_layer_top() 而不是让应用自己推一屏
// ────────────────────────────────────────────────
// lv_layer_top() 跟当前 screen 无关,页面切换和 lv_obj_delete(scr) 都碰不到
// 它(状态栏就在这一层)。所以通知**不需要前台应用配合**,也不会破坏它的
// 状态 —— 用户消掉通知之后,底下那一页原封不动。
//
// 为什么是屏幕中央一张卡片,而不是状态栏上一行小字
// ────────────────────────────────────────────────
// 22px 的一条在桌上放着根本不会被注意到。通知的全部意义就是被看见,所以
// 占住屏幕中央,并且**钉住不自动消失**,直到用户按一下键。
//
// 这个"钉住 + 吞掉按键"不是新发明:demo_codex.c 的 s_error_pinned 和
// appstore_transfer.c 里那份是同一个模式,只是它们各自实现、只在自己那一页
// 有效。这里是全局版本,拦在 main.c 的 on_key 最前面。
//
// ⚠ 线程约定
// ──────────
// ui_notify_post() 可以在**任何任务**里调,它只拷字符串 + 置标志,不碰 LVGL。
// 真正的绘制发生在 LVGL 自己的定时器回调里。这一条是硬要求:通知从
// device_config 的 cmd 通道进来,那个上下文(NimBLE host 任务)**不持有
// LVGL 锁** —— ui_statusbar.c:310 那段注释记的就是同一个坑。

// 一条通知的最大长度(UTF-8 字节)。超了按字符边界截断,不会切出半个汉字。
#define UI_NOTIFY_MAX_LEN 96

// 建通知层。要在 LVGL 起来之后调一次(跟 ui_statusbar_init 一起)。
void ui_notify_init(void);

// 投递一条通知。任何任务都能调,不需要持有 LVGL 锁。
// 传空字符串等于什么都不做。
void ui_notify_post(const char *text);

// 当前有没有钉着的通知。on_key 用它决定要不要吞掉这一次按键。
bool ui_notify_is_pinned(void);

// 消掉当前通知。**必须持有 LVGL 锁**时调用。
void ui_notify_dismiss(void);

// 丢弃当前通知,连同还没画出来的那一条。任何任务都能调,不需要 LVGL 锁。
//
// 用途:BLE 断开时清场。设备同一时刻只能连一端
// (CONFIG_BT_NIMBLE_MAX_CONNECTIONS=1),所以两端之间**必然**隔着一次断连。
// 在那一刻清掉,就得到一条结构性成立的保证:
//
//     设备上永远不会显示一条来自当前没连着的那一端的通知。
//
// 不需要任何握手协议,也不需要给通知打来源标记。
void ui_notify_drop(void);
