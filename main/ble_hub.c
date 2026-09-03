// main/ble_hub.c —— 见 ble_hub.h 顶部对"为什么要有这个文件"的说明。
//
// 协议栈生命周期(advertise/gap_event/on_reset/on_sync/host_task)沿用
// demo_ble.c 里已经过硬件验证的那一套,区别只有三点:
//   1. 开机启动、永不停止 —— 没有 ble_stop(),因为常驻正是这个模块的目的;
//   2. service 由各模块注册进来,不是写死在这个文件里;
//   3. 连接事件广播给所有观察者,由模块自己认领。
#include "ble_hub.h"
#include "demo_radio.h"

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "host/ble_gap.h"
#include "host/ble_hs.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include <string.h>

static const char *TAG = "ble_hub";
// 广播名跟改造之前保持一致 —— 配套 app 是按这个名字扫描的,改了就连不上。
static const char *DEVICE_NAME = "FoloPassport";

// ⚠ 这两个上限满了之后是**静默忽略**:注册函数只打一条 ESP_LOGE 就返回,
// 协议栈照常起来,症状是"对端怎么也发现不了这个新特征值",而日志早就滚过去
// 了。改成 4 的时候正好注册满 4 个,再加任何一个 service 都会撞上。
// 给足余量,这几个指针的内存代价可以忽略。
#define BLE_HUB_MAX_SERVICES  8
#define BLE_HUB_MAX_OBSERVERS 8

static const struct ble_gatt_svc_def *s_services[BLE_HUB_MAX_SERVICES];
static int s_service_count;
static const ble_hub_observer_t *s_observers[BLE_HUB_MAX_OBSERVERS];
static int s_observer_count;
static const ble_uuid128_t *s_advertised_service;

static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint8_t  s_addr_type;
static bool     s_started;

void ble_hub_register_service(const struct ble_gatt_svc_def *svcs)
{
    if (s_started) {
        // 晚于 init 注册是纯粹的编程错误:NimBLE 在 ble_gatts_count_cfg() 时就
        // 需要看到全部 service,之后再加不会生效,而且不会报错 —— 只会表现为
        // "这个功能的特征值在对端怎么也发现不了",极难排查。所以这里直接吼出来。
        ESP_LOGE(TAG, "ble_hub_init() 之后再注册 service 是无效的,已忽略");
        return;
    }
    if (s_service_count >= BLE_HUB_MAX_SERVICES) {
        ESP_LOGE(TAG, "service 注册数量超过上限 %d,已忽略", BLE_HUB_MAX_SERVICES);
        return;
    }
    s_services[s_service_count++] = svcs;
}

void ble_hub_register_observer(const ble_hub_observer_t *obs)
{
    if (s_observer_count >= BLE_HUB_MAX_OBSERVERS) {
        ESP_LOGE(TAG, "observer 注册数量超过上限 %d,已忽略", BLE_HUB_MAX_OBSERVERS);
        return;
    }
    s_observers[s_observer_count++] = obs;
}

void ble_hub_set_advertised_service(const ble_uuid128_t *uuid)
{
    if (s_started) {
        ESP_LOGE(TAG, "BLE 启动后不能再修改广播 service UUID");
        return;
    }
    s_advertised_service = uuid;
}

bool ble_hub_is_connected(void)
{
    return s_conn_handle != BLE_HS_CONN_HANDLE_NONE;
}

uint16_t ble_hub_conn_handle(void)
{
    return s_conn_handle;
}

int ble_hub_indicate(uint16_t val_handle, const void *data, int len)
{
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) return BLE_HS_ENOTCONN;
    struct os_mbuf *om = ble_hs_mbuf_from_flat(data, (uint16_t)len);
    if (!om) return BLE_HS_ENOMEM;
    return ble_gatts_indicate_custom(s_conn_handle, val_handle, om);
}

int ble_hub_notify(uint16_t val_handle, const void *data, int len)
{
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) return BLE_HS_ENOTCONN;
    struct os_mbuf *om = ble_hs_mbuf_from_flat(data, (uint16_t)len);
    if (!om) return BLE_HS_ENOMEM;
    return ble_gatts_notify_custom(s_conn_handle, val_handle, om);
}

void ble_hub_request_fast_interval(bool fast)
{
    if (s_conn_handle == BLE_HS_CONN_HANDLE_NONE) return;
    // 固件安装要连续推几千个分片,默认间隔(几十毫秒)下每一批都要多等好几个
    // 连接事件,整体会被拖到分钟级;压到 ~15ms 提速非常明显。但常开会明显抬高
    // 空闲功耗,而这是个电池设备 —— 所以只在真正传大块数据时打开。
    struct ble_gap_upd_params params = {
        .itvl_min = fast ? 6 : 24,      // 6*1.25=7.5ms / 24*1.25=30ms
        .itvl_max = fast ? 12 : 40,     // 12*1.25=15ms / 40*1.25=50ms
        .latency = 0,
        .supervision_timeout = 400,     // 400*10ms = 4s
        .min_ce_len = 0,
        .max_ce_len = 0,
    };
    int rc = ble_gap_update_params(s_conn_handle, &params);
    if (rc != 0) {
        ESP_LOGW(TAG, "调整连接间隔失败: rc=%d(不影响功能,只是快慢差别)", rc);
    }
}

static int gap_event(struct ble_gap_event *event, void *arg);

static int advertise(void)
{
    struct ble_hs_adv_fields fields = { 0 };
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    if (s_advertised_service) {
        fields.uuids128 = (ble_uuid128_t *)s_advertised_service;
        fields.num_uuids128 = 1;
        fields.uuids128_is_complete = 0;
    }

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) return rc;

    struct ble_hs_adv_fields response = { 0 };
    response.name = (const uint8_t *)DEVICE_NAME;
    response.name_len = strlen(DEVICE_NAME);
    response.name_is_complete = 1;
    rc = ble_gap_adv_rsp_set_fields(&response);
    if (rc != 0) return rc;

    struct ble_gap_adv_params params = { 0 };
    params.conn_mode = BLE_GAP_CONN_MODE_UND;   // 可连接广播
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    return ble_gap_adv_start(s_addr_type, NULL, BLE_HS_FOREVER, &params, gap_event, NULL);
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            ESP_LOGI(TAG, "已连接,conn_handle=%d", event->connect.conn_handle);
            s_conn_handle = event->connect.conn_handle;
            for (int i = 0; i < s_observer_count; i++) {
                if (s_observers[i]->on_connect) {
                    s_observers[i]->on_connect(event->connect.conn_handle);
                }
            }
        } else {
            ESP_LOGW(TAG, "连接失败,status=%d", event->connect.status);
            advertise();   // 连接失败广播就停了,必须重新开,否则再也连不上
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "已断开,reason=%d", event->disconnect.reason);
        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        for (int i = 0; i < s_observer_count; i++) {
            if (s_observers[i]->on_disconnect) s_observers[i]->on_disconnect();
        }
        advertise();       // 断开后立刻恢复广播,方便对端自动重连
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        advertise();
        break;
    case BLE_GAP_EVENT_SUBSCRIBE: {
        // 原样广播给所有模块,由它们自己比对 attr_handle 认领 —— hub 不认识
        // 任何模块的特征值语义。对端完成服务发现后订阅的这一刻,是模块发送
        // 首次请求的唯一正确时机(CONNECT 时对端还没订阅,发出去必然失败)。
        //
        // ⚠ indicate 和 notify 两种订阅都要认。早先这里只看 cur_indicate,
        // 于是任何用 NOTIFY 的特征值订阅后都收不到这个回调 —— 模块里那句
        // "对端订阅好了,可以开始推了"永远不执行,表现为功能完全没反应,
        // 而且没有任何错误可查。
        bool now_subscribed = event->subscribe.cur_indicate || event->subscribe.cur_notify;
        bool was_subscribed = event->subscribe.prev_indicate || event->subscribe.prev_notify;
        for (int i = 0; i < s_observer_count; i++) {
            if (s_observers[i]->on_subscribe) {
                s_observers[i]->on_subscribe(event->subscribe.attr_handle,
                                             !was_subscribed && now_subscribed);
            }
        }
        break;
    }
    default:
        break;
    }
    return 0;
}

static void on_reset(int reason)
{
    ESP_LOGE(TAG, "BLE 协议栈复位,reason=%d", reason);
}

static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc == 0) rc = ble_hs_id_infer_auto(0, &s_addr_type);
    if (rc == 0) rc = advertise();
    if (rc != 0) ESP_LOGE(TAG, "启动广播失败: rc=%d", rc);
}

static void host_task(void *arg)
{
    (void)arg;
    nimble_port_run();
    nimble_port_freertos_deinit();
}

void ble_hub_init(void)
{
    if (s_started) return;

    esp_err_t err = demo_radio_nvs_prepare();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "NVS 准备失败: %s,BLE 不可用", esp_err_to_name(err));
        return;
    }
    err = nimble_port_init();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "nimble_port_init 失败: %s", esp_err_to_name(err));
        return;
    }

    ble_svc_gap_init();
    ble_svc_gatt_init();
    int rc = ble_svc_gap_device_name_set(DEVICE_NAME);
    for (int i = 0; rc == 0 && i < s_service_count; i++) {
        rc = ble_gatts_count_cfg(s_services[i]);
        if (rc == 0) rc = ble_gatts_add_svcs(s_services[i]);
    }
    if (rc != 0) {
        ESP_LOGE(TAG, "注册 GATT service 失败: rc=%d", rc);
        return;
    }

    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;
    s_started = true;
    nimble_port_freertos_init(host_task);
    ESP_LOGI(TAG, "BLE 常驻启动,已注册 %d 组 service", s_service_count);
}
