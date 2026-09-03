// main/ui_statusbar.h —— 常驻顶部状态栏。
//
// 为什么画在 lv_layer_top() 而不是每个页面自己画
// ──────────────────────────────────────────────
// lv_layer_top() 是**跟 screen 无关**的一层,永远盖在当前 screen 之上。页面
// 切换(lv_screen_load)和页面退出时的 lv_obj_delete(scr) 都碰不到它。这意味着:
//
//   · 状态栏只创建一次,不需要每个页面记得建、记得删;
//   · 不会出现"某个页面忘了加状态栏"这种必然会发生的疏漏;
//   · 页面切换时状态栏不闪 —— 它根本没被重建过。
//
// 代价是页面内容必须给它让出顶部这条。这件事由 ui_pixel_screen_create() 统一
// 用 pad_top 处理:LVGL 里子对象的坐标是相对**父对象内容区**的
// (lv_obj_move_to() 会加上 parent 的 space_top),所以给 screen 设一个 pad_top,
// 全部页面内容自动整体下移,页面代码一行都不用改。
//
// ⚠ 唯一的例外是**硬编码了屏幕高度 320** 的地方 —— 那些算的是绝对高度,
// 不会自动跟着缩。可用高度现在是 320 - UI_STATUSBAR_H,用 UI_CONTENT_H。
#pragma once

#include <stdbool.h>

// 状态栏高度。页面内容区的原点就在这条下面。
#define UI_STATUSBAR_H 22

// 页面可用内容高度(屏幕 320 减去状态栏)。页面里凡是要跟屏幕底部比较的
// 地方都用它,不要再写 320。
#define UI_CONTENT_H   (320 - UI_STATUSBAR_H)

// 底部提示条占掉的高度。
//
// ⚠ 27 不是笔误,也不是字号:lv_font_ui_cn_14 的 **line_height 是 27**
// (ui_font_cn_14.c 里那个结构体),不是直觉上的 14 或 16。按字号估算这一条
// 的高度会少算一半 —— 表现为列表最后一行正好被提示条盖住,而且只在项数
// 装满时才出现,平时根本看不出来。
#define UI_FOOTER_H       27
// 各页 lv_obj_align(foot, LV_ALIGN_BOTTOM_MID, 0, -8) 里的那个 8。
#define UI_FOOTER_MARGIN   8

// 页面内容能画到的最下沿(内容区坐标)。再往下就压到提示条上了。
// 末尾再留 4px 让两者之间有条缝,不至于贴脸。
#define UI_CONTENT_BOTTOM  (UI_CONTENT_H - UI_FOOTER_H - UI_FOOTER_MARGIN - 4)

// 开机调一次(要在 LVGL 初始化之后)。建好状态栏并起刷新定时器。
void ui_statusbar_init(void);

// 配置变了(显示项开关、时间同步)之后调一次,立刻重画。
// 不调也没关系,下一个刷新周期(1 秒)自己会跟上 —— 这个函数只是让 app 上
// 勾掉一项之后设备立刻有反应,而不是等一下才变。
void ui_statusbar_notify_config_changed(void);

// ---- 与手动 light sleep 的互斥 ---------------------------------------------
//
// 电量采样是一次 I2C 往返。而 main.c 的闲置休眠调的是**手动**
// esp_light_sleep_start() —— 它不看任何 pm lock,所以正常的
// ESP_PM_NO_LIGHT_SLEEP 锁在这里是无效的,必须两边显式握手。
//
// 睡在 I2C 事务中间会把总线状态丢掉,之后所有 I2C 设备(电量计、音频 codec)
// 一起失联。这个项目在 i2c_master_probe 上踩过一模一样的坑。
//
// pause 返回 false 表示"采样正在进行中,现在别睡",调用方应当放弃这一轮。
// 成功之后必须配对调用 resume,否则电量读数会永久停在最后一次采样值。
bool ui_statusbar_pause_sampling(void);
void ui_statusbar_resume_sampling(void);
