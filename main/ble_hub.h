// main/ble_hub.h —— 全设备唯一的 BLE 外围设备实例。
//
// 为什么要有这个文件
// ─────────────────
// 早期 demo_codex.c 和 demo_appstore.c 各自拥有一整套 NimBLE 协议栈
// (nimble_port_init/advertise/gap_event/host_task/ble_start/ble_stop 各一份),
// 靠"main.c 的 view 状态机保证两个页面互斥"来避免它们同时运行。那样能跑,但
// 有一个致命的产品后果:
//
//   **BLE 服务只在用户正好停在对应页面时才存在。**
//
// 也就是说,设备停在启动器菜单上时,应用商店的 GATT service 根本没在广播,
// 配套 app 连都连不上,更不用说"在电脑上点一下就把应用装过去"。用户每次想
// 装应用都得先在设备上戳进应用商店页面等着 —— 这不是配套 app,这是遥控器。
//
// 现在改成:开机就把 NimBLE 拉起来,所有模块的 GATT service 一次性全部注册,
// 广播常开。页面进出只影响界面,不再影响连接。于是:
//   · 任何界面下,配套 app 都能连上并直接推送安装;
//   · 语音输入这类功能也不再因为切了个页面就断链;
//   · 少了一整套"起停整个协议栈"的时序,断连/重连的边界情况少了一大半。
//
// 使用方式
// ────────
// 模块在 ble_hub_init() **之前**注册自己的 service 和观察者,由 main.c 统一
// 编排(哪个变体包含哪些模块,就在 main.c 里调哪几个注册函数)。注册必须早于
// init,是因为 NimBLE 要求 ble_gatts_count_cfg() 时就能看到全部 service 定义。
#pragma once

#include "host/ble_gatt.h"
#include "host/ble_uuid.h"
#include <stdbool.h>
#include <stdint.h>

// 各模块关心的连接事件。模块自己判断 attr_handle 是不是自己的特征值 —— hub
// 不认识任何模块的语义,只负责把事件原样广播出去。
typedef struct {
    void (*on_connect)(uint16_t conn_handle);
    void (*on_disconnect)(void);
    void (*on_subscribe)(uint16_t attr_handle, bool subscribed);
} ble_hub_observer_t;

// ---- 以下三个必须在 ble_hub_init() 之前调用 --------------------------------
// 注册一组 GATT service(以 { 0 } 结尾的数组,生命周期必须是静态的)。
void ble_hub_register_service(const struct ble_gatt_svc_def *svcs);
// Select one service UUID for the advertising packet. The device name moves to
// scan response data so iOS can perform service-filtered background discovery.
void ble_hub_set_advertised_service(const ble_uuid128_t *uuid);
// 注册连接事件观察者(结构体生命周期必须是静态的)。
void ble_hub_register_observer(const ble_hub_observer_t *obs);

// 启动协议栈并开始广播。整个进程生命周期内只调用一次,之后不再停止 ——
// 没有对应的 deinit,这是刻意的:BLE 常驻正是这个模块存在的意义。
void ble_hub_init(void);

// ---- 运行期 ----------------------------------------------------------------
bool     ble_hub_is_connected(void);
uint16_t ble_hub_conn_handle(void);   // 未连接时返回 BLE_HS_CONN_HANDLE_NONE

// 发送 indicate / notify。未连接时直接返回非 0,不会崩。
int ble_hub_indicate(uint16_t val_handle, const void *data, int len);
int ble_hub_notify(uint16_t val_handle, const void *data, int len);

// True only after LE Secure Connections completed and the peer identity is in
// Passport's trusted-companion store. Feature GATT write callbacks must gate
// on this; the authentication service itself deliberately remains reachable.
bool ble_hub_is_authorized_conn(uint16_t conn_handle);

// 请求缩短/恢复连接间隔。传大块数据(固件安装)前打开,传完关掉 ——
// 常开会明显增加空闲功耗,而这个设备是电池供电的。
void ble_hub_request_fast_interval(bool fast);
