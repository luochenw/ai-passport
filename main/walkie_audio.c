#include "walkie_audio.h"

#include "ble_hub.h"
#include "bsp_audio.h"
#include "walkie_codec.h"

#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"
#include "host/ble_att.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"

#include <string.h>

static const char *TAG = "walkie_audio";

// Service: 8CC419BC-14D3-462B-88AD-F78E6FDA03F6
// CONTROL: 8CC419BD-14D3-462B-88AD-F78E6FDA03F6 (companion -> device)
// UPLINK:  8CC419BE-14D3-462B-88AD-F78E6FDA03F6 (device -> companion)
// DOWNLINK:8CC419BF-14D3-462B-88AD-F78E6FDA03F6 (companion -> device)
// STATUS:  8CC419C0-14D3-462B-88AD-F78E6FDA03F6 (device -> companion)
//
// NimBLE stores 128-bit UUID bytes in reverse order.
static const ble_uuid128_t s_service_uuid =
    BLE_UUID128_INIT(0xF6, 0x03, 0xDA, 0x6F, 0x8E, 0xF7, 0xAD, 0x88,
                     0x2B, 0x46, 0xD3, 0x14, 0xBC, 0x19, 0xC4, 0x8C);
static const ble_uuid128_t s_control_uuid =
    BLE_UUID128_INIT(0xF6, 0x03, 0xDA, 0x6F, 0x8E, 0xF7, 0xAD, 0x88,
                     0x2B, 0x46, 0xD3, 0x14, 0xBD, 0x19, 0xC4, 0x8C);
static const ble_uuid128_t s_uplink_uuid =
    BLE_UUID128_INIT(0xF6, 0x03, 0xDA, 0x6F, 0x8E, 0xF7, 0xAD, 0x88,
                     0x2B, 0x46, 0xD3, 0x14, 0xBE, 0x19, 0xC4, 0x8C);
static const ble_uuid128_t s_downlink_uuid =
    BLE_UUID128_INIT(0xF6, 0x03, 0xDA, 0x6F, 0x8E, 0xF7, 0xAD, 0x88,
                     0x2B, 0x46, 0xD3, 0x14, 0xBF, 0x19, 0xC4, 0x8C);
static const ble_uuid128_t s_status_uuid =
    BLE_UUID128_INIT(0xF6, 0x03, 0xDA, 0x6F, 0x8E, 0xF7, 0xAD, 0x88,
                     0x2B, 0x46, 0xD3, 0x14, 0xC0, 0x19, 0xC4, 0x8C);

#define WALKIE_CONTROL_START 1
#define WALKIE_CONTROL_STOP  2

#define WALKIE_STATUS_READY      0
#define WALKIE_STATUS_TX_STARTED 1
#define WALKIE_STATUS_TX_STOPPED 2
#define WALKIE_STATUS_ERROR      3

#define WALKIE_RX_QUEUE_DEPTH 6

typedef struct {
    uint16_t len;
    uint8_t bytes[WALKIE_AUDIO_FRAME_MAX_SIZE];
} walkie_rx_message_t;

static uint16_t s_uplink_handle;
static uint16_t s_status_handle;
static QueueHandle_t s_rx_queue;
static TaskHandle_t s_worker_task;
static portMUX_TYPE s_worker_create_lock = portMUX_INITIALIZER_UNLOCKED;
static bool s_worker_creating;
// 单次发话的硬上限,见下面循环里的说明。
#define WALKIE_TX_MAX_US (60 * 1000000LL)

static volatile bool s_tx_requested;
static volatile bool s_tx_active;
static volatile bool s_rx_active;
static volatile bool s_rx_abort_requested;
static uint16_t s_tx_stream_id;
static bool s_rx_lock_held;
static int64_t s_rx_last_frame_us;
static walkie_audio_activity_fn s_activity_hook;

static int16_t s_pcm[WALKIE_AUDIO_FRAME_SAMPLES];
static uint8_t s_frame[WALKIE_AUDIO_FRAME_MAX_SIZE];

static void worker_task(void *arg);

// 对讲任务直到第一次真正收发音频时才需要。用互斥锁串行化 CONTROL_START
// 和 DOWNLINK 两条创建路径；创建失败会删除半成品，下一次写入可以重试。
static bool ensure_worker(void)
{
    portENTER_CRITICAL(&s_worker_create_lock);
    if (s_rx_queue && s_worker_task) {
        portEXIT_CRITICAL(&s_worker_create_lock);
        return true;
    }
    if (s_worker_creating || s_worker_task) {
        // 另一条写入路径正在创建时立即失败，让对端稍后重试；不要在 NimBLE
        // 回调里等待动态分配或任务调度。
        portEXIT_CRITICAL(&s_worker_create_lock);
        return false;
    }
    s_worker_creating = true;
    portEXIT_CRITICAL(&s_worker_create_lock);

    QueueHandle_t queue = xQueueCreate(WALKIE_RX_QUEUE_DEPTH,
                                       sizeof(walkie_rx_message_t));
    if (!queue) {
        ESP_LOGE(TAG, "创建对讲播放队列失败,等待下一次写入重试");
        portENTER_CRITICAL(&s_worker_create_lock);
        s_worker_creating = false;
        portEXIT_CRITICAL(&s_worker_create_lock);
        return false;
    }
    // worker_task 启动后立即读取全局队列，所以必须在 xTaskCreate 前发布句柄。
    portENTER_CRITICAL(&s_worker_create_lock);
    s_rx_queue = queue;
    portEXIT_CRITICAL(&s_worker_create_lock);

    TaskHandle_t task = NULL;
    if (xTaskCreate(worker_task, "walkie_audio", 4096, NULL, 5, &task) != pdPASS) {
        ESP_LOGE(TAG, "创建对讲音频任务失败,等待下一次写入重试");
        portENTER_CRITICAL(&s_worker_create_lock);
        s_rx_queue = NULL;
        s_worker_creating = false;
        portEXIT_CRITICAL(&s_worker_create_lock);
        vQueueDelete(queue);
        return false;
    }
    portENTER_CRITICAL(&s_worker_create_lock);
    s_worker_task = task;
    s_worker_creating = false;
    portEXIT_CRITICAL(&s_worker_create_lock);
    return true;
}

static void send_status(uint8_t event, uint8_t code)
{
    const uint8_t payload[] = { WALKIE_AUDIO_PROTOCOL_VERSION, event, code };
    int rc = ble_hub_notify(s_status_handle, payload, sizeof(payload));
    if (rc != 0 && rc != BLE_HS_ENOTCONN) {
        ESP_LOGW(TAG, "状态通知失败:event=%u rc=%d", event, rc);
    }
}

static void send_uplink_frame(uint16_t sequence, uint8_t flags,
                              const int16_t *pcm, uint16_t sample_count)
{
    size_t len = walkie_audio_frame_encode(s_tx_stream_id, sequence, flags,
                                           pcm, sample_count,
                                           s_frame, sizeof(s_frame));
    if (len == 0) {
        ESP_LOGW(TAG, "编码上行音频帧失败");
        return;
    }

    uint16_t mtu = ble_att_mtu(ble_hub_conn_handle());
    if (mtu < 23 || len > (size_t)mtu - 3) {
        ESP_LOGW(TAG, "ATT MTU %u 装不下 %u 字节音频帧", mtu, (unsigned)len);
        return;
    }
    int rc = ble_hub_notify(s_uplink_handle, s_frame, (int)len);
    if (rc != 0 && rc != BLE_HS_ENOTCONN && rc != BLE_HS_ENOMEM) {
        ESP_LOGW(TAG, "发送上行音频失败:rc=%d", rc);
    }
}

static void record_session(void)
{
    if (!bsp_audio_acquire(500)) {
        ESP_LOGW(TAG, "音频设备忙,无法开始讲话");
        s_tx_requested = false;
        send_status(WALKIE_STATUS_ERROR, 1);
        return;
    }
    if (bsp_audio_set_format(WALKIE_AUDIO_SAMPLE_RATE, 16, 1) != ESP_OK) {
        bsp_audio_release();
        s_tx_requested = false;
        send_status(WALKIE_STATUS_ERROR, 2);
        return;
    }
    uint16_t mtu = ble_att_mtu(ble_hub_conn_handle());
    if (mtu < WALKIE_AUDIO_FRAME_MAX_SIZE + 3) {
        ESP_LOGW(TAG, "ATT MTU %u 太小,实时对讲至少需要 %u", mtu,
                 WALKIE_AUDIO_FRAME_MAX_SIZE + 3);
        bsp_audio_release();
        s_tx_requested = false;
        send_status(WALKIE_STATUS_ERROR, 4);
        return;
    }

    uint16_t sequence = 0;
    bool first = true;
    s_tx_active = true;
    ble_hub_request_fast_interval(true);
    send_status(WALKIE_STATUS_TX_STARTED, 0);

    // 硬上限。s_tx_requested 只有两条清除路径:对端写 CONTROL STOP,和 BLE
    // 断开。而 STOP 依赖「设备 RELEASE 事件 → indicate 上报 → 伴侣端 endTalk
    // → 写回 STOP」整整一圈,这一圈中间任何一环断掉(伴侣端 app 被杀、页面
    // 被通知卡片顶掉、indicate 丢包),麦克风就会**一直开着往房间广播**,而
    // 屏幕上还停在「正在讲话」,用户没有任何线索。
    //
    // 一句话说完几秒钟,60 秒是个正常人说不完、又不会打断正常使用的界限。
    // 到点就当作对端已经没了,自己收尾。
    const int64_t deadline = esp_timer_get_time() + WALKIE_TX_MAX_US;
    while (s_tx_requested && ble_hub_is_connected()) {
        if (esp_timer_get_time() > deadline) {
            ESP_LOGW(TAG, "发话超过 %d 秒仍未收到停止,自行结束(防止麦克风一直开着)",
                     (int)(WALKIE_TX_MAX_US / 1000000));
            break;
        }
        if (bsp_audio_read(s_pcm, sizeof(s_pcm)) != ESP_OK) {
            ESP_LOGW(TAG, "读取对讲麦克风失败");
            break;
        }
        send_uplink_frame(sequence++, first ? WALKIE_AUDIO_FLAG_START : 0,
                          s_pcm, WALKIE_AUDIO_FRAME_SAMPLES);
        first = false;
    }

    send_uplink_frame(sequence, WALKIE_AUDIO_FLAG_END, NULL, 0);
    ble_hub_request_fast_interval(false);
    s_tx_requested = false;
    s_tx_active = false;
    bsp_audio_release();
    send_status(WALKIE_STATUS_TX_STOPPED, 0);
}

static void play_frame(const walkie_rx_message_t *msg)
{
    walkie_audio_frame_info_t info;
    size_t samples = 0;
    if (!walkie_audio_frame_decode(msg->bytes, msg->len, &info,
                                   s_pcm, WALKIE_AUDIO_FRAME_SAMPLES, &samples)) {
        ESP_LOGW(TAG, "收到无效的下行音频帧,len=%u", msg->len);
        return;
    }

    if ((info.flags & WALKIE_AUDIO_FLAG_START) || (samples > 0 && !s_rx_active)) {
        if (!s_rx_lock_held) {
            if (!bsp_audio_acquire(100)) {
                ESP_LOGW(TAG, "音频设备忙,丢弃下行话音");
                return;
            }
            s_rx_lock_held = true;
        }
        s_rx_active = true;
        s_rx_last_frame_us = esp_timer_get_time();
        ble_hub_request_fast_interval(true);
        if (s_activity_hook) s_activity_hook(true);
    }
    if (samples > 0 && !s_tx_active && s_rx_lock_held) {
        if (bsp_audio_set_format(WALKIE_AUDIO_SAMPLE_RATE, 16, 1) == ESP_OK) {
            bsp_audio_write(s_pcm, samples * sizeof(s_pcm[0]));
        }
        s_rx_last_frame_us = esp_timer_get_time();
    }
    if (info.flags & WALKIE_AUDIO_FLAG_END) {
        s_rx_active = false;
        if (s_rx_lock_held) {
            bsp_audio_release();
            s_rx_lock_held = false;
        }
        ble_hub_request_fast_interval(false);
        if (s_activity_hook) s_activity_hook(false);
    }
}

static void worker_task(void *arg)
{
    (void)arg;
    walkie_rx_message_t msg;
    for (;;) {
        if (s_rx_abort_requested ||
            (s_rx_lock_held && esp_timer_get_time() - s_rx_last_frame_us > 500000)) {
            s_rx_abort_requested = false;
            s_rx_active = false;
            if (s_rx_lock_held) {
                bsp_audio_release();
                s_rx_lock_held = false;
            }
            ble_hub_request_fast_interval(false);
            if (s_activity_hook) s_activity_hook(false);
        }
        if (s_tx_requested && !s_tx_active) {
            record_session();
            continue;
        }
        if (xQueueReceive(s_rx_queue, &msg, pdMS_TO_TICKS(20)) == pdTRUE) {
            play_frame(&msg);
        }
    }
}

static int control_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                             struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (!ble_hub_is_authorized_conn(conn_handle)) return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
    (void)attr_handle;
    (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_UNLIKELY;

    uint8_t payload[4] = { 0 };
    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len < 2 || len > sizeof(payload) ||
        ble_hs_mbuf_to_flat(ctxt->om, payload, len, NULL) != 0) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    if (payload[0] != WALKIE_AUDIO_PROTOCOL_VERSION) {
        return BLE_ATT_ERR_UNLIKELY;
    }

    if (payload[1] == WALKIE_CONTROL_START && len >= 4) {
        if (!ensure_worker()) {
            send_status(WALKIE_STATUS_ERROR, 5);
            return BLE_ATT_ERR_INSUFFICIENT_RES;
        }
        if (s_rx_active || (s_rx_queue && uxQueueMessagesWaiting(s_rx_queue) > 0)) {
            send_status(WALKIE_STATUS_ERROR, 3);
            return 0;
        }
        s_tx_stream_id = (uint16_t)payload[2] | ((uint16_t)payload[3] << 8);
        s_tx_requested = true;
    } else if (payload[1] == WALKIE_CONTROL_STOP) {
        s_tx_requested = false;
    }
    return 0;
}

static int downlink_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                              struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    if (!ble_hub_is_authorized_conn(conn_handle)) return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
    (void)attr_handle;
    (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_UNLIKELY;
    if (s_tx_requested || s_tx_active) return 0;

    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len < WALKIE_AUDIO_FRAME_HEADER_SIZE || len > WALKIE_AUDIO_FRAME_MAX_SIZE) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }

    walkie_rx_message_t msg = { .len = len };
    if (ble_hs_mbuf_to_flat(ctxt->om, msg.bytes, len, NULL) != 0) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    walkie_audio_frame_info_t info;
    if (!walkie_audio_frame_decode(msg.bytes, msg.len, &info, NULL, 0, NULL)) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    if (!ensure_worker()) {
        send_status(WALKIE_STATUS_ERROR, 5);
        return BLE_ATT_ERR_INSUFFICIENT_RES;
    }

    if (info.flags & WALKIE_AUDIO_FLAG_START) {
        // A new stream supersedes queued tail audio from the previous one and
        // must keep its START marker even when the playback queue was full.
        xQueueReset(s_rx_queue);
    }
    if (xQueueSend(s_rx_queue, &msg, 0) != pdTRUE) {
        // Realtime audio must stay current. Drop the oldest queued frame instead
        // of increasing latency without bound.
        walkie_rx_message_t discarded;
        xQueueReceive(s_rx_queue, &discarded, 0);
        xQueueSend(s_rx_queue, &msg, 0);
    }
    return 0;
}

static int readonly_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                              struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)ctxt;
    (void)arg;
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_service_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &s_control_uuid.u,
                .access_cb = control_access_cb,
                .flags = BLE_GATT_CHR_F_WRITE,
            },
            {
                .uuid = &s_uplink_uuid.u,
                .access_cb = readonly_access_cb,
                .flags = BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_uplink_handle,
            },
            {
                .uuid = &s_downlink_uuid.u,
                .access_cb = downlink_access_cb,
                .flags = BLE_GATT_CHR_F_WRITE_NO_RSP,
            },
            {
                .uuid = &s_status_uuid.u,
                .access_cb = readonly_access_cb,
                .flags = BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_status_handle,
            },
            { 0 },
        },
    },
    { 0 },
};

static void on_disconnect(void)
{
    s_tx_requested = false;
    s_rx_abort_requested = true;
    if (s_rx_queue) xQueueReset(s_rx_queue);
}

static void on_subscribe(uint16_t attr_handle, bool subscribed)
{
    if (attr_handle == s_status_handle && subscribed) {
        send_status(WALKIE_STATUS_READY, 0);
    }
}

static const ble_hub_observer_t s_observer = {
    .on_disconnect = on_disconnect,
    .on_subscribe = on_subscribe,
};

void walkie_audio_register(void)
{
    ble_hub_register_service(s_gatt_svcs);
    ble_hub_register_observer(&s_observer);
    ble_hub_set_advertised_service(&s_service_uuid);
}

void walkie_audio_init(void)
{
    // 静态状态已经初始化。队列和 4096-byte worker stack 由首次
    // CONTROL_START 或合法 DOWNLINK 写入按需创建。
}

void walkie_audio_set_activity_hook(walkie_audio_activity_fn fn)
{
    s_activity_hook = fn;
}

bool walkie_audio_is_transmitting(void)
{
    return s_tx_active;
}

bool walkie_audio_is_receiving(void)
{
    return s_rx_active;
}
