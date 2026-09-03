// main/demo_ble.c —— NimBLE 可连接广播 + 自定义 GATT 数据链路测试；
// 手机/Mac App 可连接到 FoloPassport,并对 MSG_UUID 特征值读写一段文本,
// 用来验证数据链路能双向跑通(写入后设备屏幕会显示收到的内容)。
#include "demo.h"
#include "demo_radio.h"
#include "ui_pixel.h"

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/util/util.h"
#include "lvgl.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include <string.h>

static const char *TAG = "demo_ble";
static const char *DEVICE_NAME = "FoloPassport";

// 自定义 Service/Characteristic UUID(随机生成,只要跟标准 UUID 不冲突即可)。
static const ble_uuid128_t s_svc_uuid =
    BLE_UUID128_INIT(0x97, 0x97, 0x62, 0x0a, 0x30, 0x4f, 0x49, 0xcd,
                     0x86, 0xc9, 0x61, 0x54, 0x1c, 0x92, 0x8a, 0xd3);
static const ble_uuid128_t s_msg_uuid =
    BLE_UUID128_INIT(0x5e, 0x18, 0x18, 0x1a, 0xee, 0x96, 0x42, 0x59,
                     0x97, 0xd2, 0x68, 0xfc, 0xec, 0x5f, 0x79, 0xad);

#define GATT_MSG_MAX_LEN 64
static char s_msg[GATT_MSG_MAX_LEN] = "Hello from FoloPassport";
static uint16_t s_msg_val_handle;

typedef enum {
    BLE_DEMO_OFF = 0,
    BLE_DEMO_STARTING,
    BLE_DEMO_ADVERTISING,
    BLE_DEMO_CONNECTED,
    BLE_DEMO_FAILED,
} ble_demo_state_t;

static lv_obj_t *s_scr;
static lv_obj_t *s_status;
static lv_timer_t *s_timer;
static SemaphoreHandle_t s_host_stopped;
static volatile ble_demo_state_t s_state;
static volatile int s_error;
static uint8_t s_addr_type;
static bool s_initialized;
static bool s_start_requested;

static int gap_event(struct ble_gap_event *event, void *arg);

// ⚠ 这个回调跑在 NimBLE host 任务里,不是 LVGL 任务 —— 千万不要在这里直接碰
// LVGL 对象(会跟 ble_stop() 里等 host 任务退出的逻辑形成潜在锁环)。收到的内容
// 只存进 s_msg,交给 tick()(跑在 LVGL 任务)按周期读出来显示。
static int msg_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                         struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;

    if (ctxt->op == BLE_GATT_ACCESS_OP_READ_CHR) {
        int rc = os_mbuf_append(ctxt->om, s_msg, strlen(s_msg));
        return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
    }
    if (ctxt->op == BLE_GATT_ACCESS_OP_WRITE_CHR) {
        uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
        if (len >= GATT_MSG_MAX_LEN) len = GATT_MSG_MAX_LEN - 1;
        int rc = ble_hs_mbuf_to_flat(ctxt->om, s_msg, len, NULL);
        if (rc != 0) return BLE_ATT_ERR_UNLIKELY;
        s_msg[len] = '\0';
        ESP_LOGI(TAG, "收到写入: %s", s_msg);
        return 0;
    }
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &s_msg_uuid.u,
                .access_cb = msg_access_cb,
                .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_WRITE,
                .val_handle = &s_msg_val_handle,
            },
            { 0 },
        },
    },
    { 0 },
};

static int advertise(void)
{
    struct ble_hs_adv_fields fields = { 0 };
    fields.flags = BLE_HS_ADV_F_DISC_GEN | BLE_HS_ADV_F_BREDR_UNSUP;
    fields.name = (const uint8_t *)DEVICE_NAME;
    fields.name_len = strlen(DEVICE_NAME);
    fields.name_is_complete = 1;

    int rc = ble_gap_adv_set_fields(&fields);
    if (rc != 0) return rc;

    struct ble_gap_adv_params params = { 0 };
    params.conn_mode = BLE_GAP_CONN_MODE_UND;   // 可连接广播,手机才能连上来
    params.disc_mode = BLE_GAP_DISC_MODE_GEN;
    rc = ble_gap_adv_start(s_addr_type, NULL, BLE_HS_FOREVER, &params, gap_event, NULL);
    if (rc == 0) s_state = BLE_DEMO_ADVERTISING;
    return rc;
}

static int gap_event(struct ble_gap_event *event, void *arg)
{
    (void)arg;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            ESP_LOGI(TAG, "已连接,conn_handle=%d", event->connect.conn_handle);
            s_state = BLE_DEMO_CONNECTED;
        } else {
            ESP_LOGW(TAG, "连接失败,status=%d", event->connect.status);
            if (s_start_requested) advertise();   // 连接失败,广播已停,重新开始
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        ESP_LOGI(TAG, "已断开,reason=%d", event->disconnect.reason);
        if (s_start_requested) advertise();       // 断开后恢复广播,方便重复测试
        break;
    case BLE_GAP_EVENT_ADV_COMPLETE:
        if (s_start_requested) {
            int rc = advertise();
            if (rc != 0) {
                s_error = rc;
                s_state = BLE_DEMO_FAILED;
            }
        }
        break;
    default:
        break;
    }
    return 0;
}

static void on_reset(int reason)
{
    s_error = reason;
    s_state = BLE_DEMO_FAILED;
}

static void on_sync(void)
{
    int rc = ble_hs_util_ensure_addr(0);
    if (rc == 0) rc = ble_hs_id_infer_auto(0, &s_addr_type);
    if (rc == 0 && s_start_requested) rc = advertise();
    if (rc != 0) {
        s_error = rc;
        s_state = BLE_DEMO_FAILED;
    }
}

static void host_task(void *arg)
{
    (void)arg;
    nimble_port_run();
    if (s_host_stopped) xSemaphoreGive(s_host_stopped);
    nimble_port_freertos_deinit();
}

static esp_err_t ble_start(void)
{
    if (s_initialized) {
        s_error = ESP_ERR_INVALID_STATE;
        s_state = BLE_DEMO_FAILED;
        return ESP_ERR_INVALID_STATE;
    }

    s_state = BLE_DEMO_STARTING;
    esp_err_t err = demo_radio_nvs_prepare();
    if (err != ESP_OK) {
        s_error = err;
        s_state = BLE_DEMO_FAILED;
        return err;
    }

    err = nimble_port_init();
    if (err != ESP_OK) {
        s_error = err;
        s_state = BLE_DEMO_FAILED;
        return err;
    }
    s_initialized = true;
    s_host_stopped = xSemaphoreCreateBinary();
    if (!s_host_stopped) {
        nimble_port_deinit();
        s_initialized = false;
        s_error = ESP_ERR_NO_MEM;
        s_state = BLE_DEMO_FAILED;
        return ESP_ERR_NO_MEM;
    }

    ble_svc_gap_init();
    ble_svc_gatt_init();
    int rc = ble_svc_gap_device_name_set(DEVICE_NAME);
    if (rc == 0) rc = ble_gatts_count_cfg(s_gatt_svcs);
    if (rc == 0) rc = ble_gatts_add_svcs(s_gatt_svcs);
    if (rc != 0) {
        vSemaphoreDelete(s_host_stopped);
        s_host_stopped = NULL;
        nimble_port_deinit();
        s_initialized = false;
        s_error = rc;
        s_state = BLE_DEMO_FAILED;
        return ESP_FAIL;
    }

    ble_hs_cfg.reset_cb = on_reset;
    ble_hs_cfg.sync_cb = on_sync;
    s_start_requested = true;
    nimble_port_freertos_init(host_task);
    return ESP_OK;
}

static void ble_stop(void)
{
    s_start_requested = false;
    if (!s_initialized) return;

    ble_gap_adv_stop();
    int rc = nimble_port_stop();
    if (rc == 0 && s_host_stopped) {
        // host callback 不访问 LVGL；即使页面 exit 持有 LVGL 锁也不会形成锁环。
        xSemaphoreTake(s_host_stopped, portMAX_DELAY);
    }
    if (rc == 0) {
        nimble_port_deinit();
        s_initialized = false;
    } else {
        ESP_LOGE(TAG, "nimble_port_stop 失败: %d", rc);
    }
    if (!s_initialized && s_host_stopped) {
        vSemaphoreDelete(s_host_stopped);
        s_host_stopped = NULL;
    }
    s_state = BLE_DEMO_OFF;
}

static void tick(lv_timer_t *timer)
{
    (void)timer;
    switch (s_state) {
    case BLE_DEMO_STARTING:
        lv_label_set_text(s_status, "正在启动蓝牙...");
        break;
    case BLE_DEMO_ADVERTISING:
        lv_label_set_text(s_status, "正在广播\n\n名称: FoloPassport\n\n用手机扫描即可连接\n\n确定:重新广播");
        break;
    case BLE_DEMO_CONNECTED:
        lv_label_set_text_fmt(s_status, "已连接\n\n收到:\n%s", s_msg);
        break;
    case BLE_DEMO_FAILED:
        lv_label_set_text_fmt(s_status, "蓝牙失败: %d", s_error);
        s_state = BLE_DEMO_OFF;
        break;
    default:
        break;
    }
}

void demo_ble_enter(void)
{
    s_scr = ui_pixel_screen_create("蓝牙");
    lv_obj_t *panel = ui_pixel_panel_create(s_scr, 22, 70, 196, 180, UI_PAPER);
    s_status = lv_label_create(panel);
    lv_obj_set_width(s_status, 168);
    lv_obj_set_style_text_align(s_status, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_set_style_text_font(s_status, &lv_font_ui_cn_14, 0);
    lv_obj_set_style_text_color(s_status, lv_color_hex(UI_INK), 0);
    lv_obj_center(s_status);
    lv_label_set_text(s_status, "正在启动蓝牙...");
    s_timer = lv_timer_create(tick, 100, NULL);
    lv_screen_load(s_scr);
    ble_start();
}

void demo_ble_exit(void)
{
    if (s_timer) {
        lv_timer_delete(s_timer);
        s_timer = NULL;
    }
    ble_stop();
    if (s_scr) {
        lv_obj_delete(s_scr);
        s_scr = NULL;
        s_status = NULL;
    }
}

void demo_ble_key(bsp_btn_t btn, bsp_btn_ev_t ev)
{
    if (btn != BSP_BTN_OK || ev != BSP_BTN_CLICK || !s_initialized) return;
    ble_gap_adv_stop();
    int rc = advertise();
    if (rc != 0) {
        s_error = rc;
        s_state = BLE_DEMO_FAILED;
    }
}
