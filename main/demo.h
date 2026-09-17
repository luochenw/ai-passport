// main/demo.h —— 每个演示页实现的统一接口。
// 新增一个演示页 = 实现这几个函数 + 在 main.c 的 DEMOS[] 里加一行。
#pragma once

#include "bsp_button.h"
#include <stdbool.h>

typedef struct {
    const char *name;
    const char *hint;                             // 菜单里显示的一行说明
    void (*enter)(void);                          // 建自己的屏并载入
    void (*exit)(void);                           // 删屏、停定时器、释放资源
    void (*key)(bsp_btn_t btn, bsp_btn_ev_t ev);  // 收按键(长按确定已被 main 拦截)
    // 这一页依赖的硬件初始化。返回 false 表示这页不可用,菜单里标 [FAIL] 且
    // 不允许进入。NULL 表示不需要额外初始化(总是可用)。
    //
    // ⚠ 这个字段的存在是为了消灭一个真实的坑:早先每页可用与否记在一个
    // s_ok[] 数组里,而它是在 app_main() 里用字面下标一条条赋值的
    // (s_ok[0]=…; s_ok[1]=…; … s_ok[7]=…)。DEMOS[] 里删掉或插入任何一行,
    // 这些下标就跟条目错位了 —— 不会报错,只会表现为"某一页明明好的却进不去,
    // 另一页坏的却能进",而做应用裁剪恰恰要频繁增删条目。现在初始化函数跟
    // 条目绑在同一行,增删条目不可能再错位。
    bool (*probe)(void);
} demo_entry_t;

// 各演示页(定义在各自的 .c 里)
void demo_display_enter(void); void demo_display_exit(void);
void demo_display_key(bsp_btn_t btn, bsp_btn_ev_t ev);

void demo_button_enter(void);  void demo_button_exit(void);
void demo_button_key(bsp_btn_t btn, bsp_btn_ev_t ev);

void demo_audio_enter(void);   void demo_audio_exit(void);
void demo_audio_key(bsp_btn_t btn, bsp_btn_ev_t ev);

void demo_battery_enter(void); void demo_battery_exit(void);
void demo_battery_key(bsp_btn_t btn, bsp_btn_ev_t ev);

void demo_wifi_enter(void);    void demo_wifi_exit(void);
void demo_wifi_key(bsp_btn_t btn, bsp_btn_ev_t ev);

typedef enum {
    SETTINGS_DEST_NONE, SETTINGS_DEST_WIFI, SETTINGS_DEST_FIRMWARE, SETTINGS_DEST_CONNECTIONS
} settings_destination_t;
void demo_settings_enter(void);
void demo_settings_exit(void);
void demo_settings_key(bsp_btn_t btn, bsp_btn_ev_t ev);
bool demo_settings_back(void);
settings_destination_t demo_settings_take_destination(void);

void demo_ble_enter(void);     void demo_ble_exit(void);
void demo_ble_key(bsp_btn_t btn, bsp_btn_ev_t ev);

void demo_low_power_enter(void); void demo_low_power_exit(void);
void demo_low_power_key(bsp_btn_t btn, bsp_btn_ev_t ev);

void demo_status_enter(void);  void demo_status_exit(void);
void demo_status_key(bsp_btn_t btn, bsp_btn_ev_t ev);

// 注册 Codex 的 GATT service 到常驻 BLE。必须在 ble_hub_init() 之前调用。
// 远程界面(设备当显示终端,应用逻辑在配套 app)。见 remote_ui.h。
void demo_remote_enter(void); void demo_remote_exit(void);
void demo_remote_key(bsp_btn_t btn, bsp_btn_ev_t ev);


void codex_ble_register(void);

// ---- 语音输入:这件事只能留在固件里 ----------------------------------------
//
// 应用逻辑全都搬到了配套 app 那边,唯独语音不行 —— 麦克风长在设备上,采样、
// ADPCM 编码、分片推送这条链路的起点在硬件这一侧,没法"由电脑代劳"。所以
// 它是设备端保留的少数几个真能力之一。
//
// 音频走的是 Codex 那个 GATT service 的 AUDIO 特征值(NOTIFY),对端已经有
// 完整的解码 + 转写管线。
//
// ⚠ 这三个函数以前是 demo_codex.c 内部的 static,唯一的触发点埋在一个**已经
// 不可达**的页面里(那个页面的 enter 没有任何调用方)—— 于是协议、编码、
// Mac 侧管线全都活着,却没有任何办法把录音启动起来。暴露出来之后,由
// demo_remote.c 在对端声明"这一屏收语音"时接上按键。
void codex_voice_start(void);
void codex_voice_stop(void);
bool codex_voice_active(void);
void demo_codex_enter(void);   void demo_codex_exit(void);
void demo_codex_key(bsp_btn_t btn, bsp_btn_ev_t ev);

void demo_appstore_enter(void); void demo_appstore_exit(void);
void demo_appstore_key(bsp_btn_t btn, bsp_btn_ev_t ev);

// main.c 提供,demo_appstore.c 装完新应用后调用:写 bootflag、重启进 appslot。
// 声明放这里而不是单独开头文件,是因为这本来就是 demo.h 承载的
// "main.c <-> 各 demo 页" 窄接口的一部分,不需要为一个函数单开一个头。
void main_boot_into_appslot(void);

// Updating an appslot image while executing from that same partition is unsafe
// and rejected by esp_ota_begin(). Clear the boot flag and restart into the
// factory launcher first; the companion retains its transfer session and
// retries from chunk zero after BLE reconnects.
void main_restart_to_factory_for_update(void);
