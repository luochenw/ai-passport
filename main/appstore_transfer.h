// main/appstore_transfer.h —— "应用商店"页的传输层:独立的第二个 NimBLE
// 外围设备/GATT service(跟 demo_codex.c 完全不共享状态)、目录条目的分片
// 重组、固件流式 OTA 写入(队列 + 独立任务解耦 flash 写入和蓝牙确认)、
// 批量确认/幂等重传协议。
//
// demo_appstore.c 只管 LVGL 界面和按键,不直接碰 BLE/OTA 细节——这个头文件
// 是两者之间的窄接口。
#pragma once

#include <stdbool.h>

typedef enum {
    APPSTORE_TRANSFER_OFF = 0,
    APPSTORE_TRANSFER_STARTING,
    APPSTORE_TRANSFER_ADVERTISING,
    APPSTORE_TRANSFER_CONNECTED,
    APPSTORE_TRANSFER_FAILED,
} appstore_transfer_state_t;

// 生命周期:全部常驻,不随页面进出起停。
//
// 这一点是刻意的,也是产品要求:对端随时可能推固件过来,那一刻用户可能正停
// 在任何界面上。如果 GATT service 和 OTA 接收任务只在"应用商店"页面才存在,
// 配套 app 就只能当遥控器用 —— 用户每次装应用都得先在设备上戳进那个页面等着。
//
//   register(): 必须在 ble_hub_init() 之前调用,注册 GATT service 和观察者。
//   init():     app_main 中调用一次,建立 OTA 接收队列和写入任务。
void appstore_transfer_register(void);
void appstore_transfer_init(void);

appstore_transfer_state_t appstore_transfer_get_state(void);
int appstore_transfer_last_error(void);   // 仅 APPSTORE_TRANSFER_FAILED 时有意义

// 应用目录——由 Mac 端对 REQ_LIST_APPS 的回应异步填充,UI 只读。
int         appstore_transfer_app_count(void);
const char *appstore_transfer_app_text(int index);

// 发起安装(index 是目录里的下标),内部会重置进度并向 Mac 发 REQ_INSTALL_APP。
void appstore_transfer_install(int index);
bool appstore_transfer_is_installing(void);
int  appstore_transfer_install_received(void);   // 已经真正写完的分片数
int  appstore_transfer_install_total(void);

// 钉住的错误提示(找不到分区/写入失败/校验失败等),需要用户按键确认。
bool        appstore_transfer_error_pending(void);
const char *appstore_transfer_error_text(void);
void        appstore_transfer_clear_error(void);   // 用户按键关闭提示时调用

// UI 用来判断这一帧要不要重绘;读一次就自动清掉,跟原来 tick() 里
// "s_dirty ? render : skip" 是同一个语义,只是搬到了这个模块自己管。
bool appstore_transfer_consume_dirty(void);
