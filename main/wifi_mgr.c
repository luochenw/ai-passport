// The worker owns every Wi-Fi/netif API call and every lifecycle transition.
// Button, LVGL and NimBLE callers only copy a request into a bounded mailbox.
#include "wifi_mgr.h"
#include "wifi_mgr_model.h"
#include "device_config.h"
#include "demo_radio.h"

#include "esp_event.h"
#include "esp_heap_caps.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "esp_wifi_default.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/task.h"

#include <stdio.h>
#include <string.h>

static const char *TAG = "wifi_mgr";
#define WIFI_MGR_MAX_RETRY 3
#define WIFI_MGR_PASSWORD_LEN 65
#define WIFI_MGR_EVENT_COUNT 12
#define WIFI_MGR_CONNECT_TIMEOUT_MS 25000
#define WIFI_MGR_SCAN_TIMEOUT_MS 15000
#define WIFI_MGR_STOP_TIMEOUT_MS 3000

typedef enum { REQUEST_NONE, REQUEST_CONNECT, REQUEST_DISCONNECT, REQUEST_SELECT } request_kind_t;
typedef struct {
    request_kind_t kind;
    char ssid[WIFI_MGR_SSID_LEN];
    char password[WIFI_MGR_PASSWORD_LEN];
    bool secure;
} wifi_request_t;

typedef enum { EVENT_DISCONNECTED, EVENT_GOT_IP, EVENT_SCAN_DONE } event_kind_t;
typedef struct {
    event_kind_t kind;
    uint32_t value;
    char ip[16];
} wifi_message_t;

typedef enum { AFTER_STOP_OFF, AFTER_STOP_CONNECT, AFTER_STOP_FAILED } after_stop_t;

static portMUX_TYPE s_lock = portMUX_INITIALIZER_UNLOCKED;
static TaskHandle_t s_worker;
static QueueHandle_t s_events;
static wifi_mgr_watch_fn s_on_change;
static wifi_mgr_snapshot_t s_view;
static wifi_mgr_ap_t s_scan[WIFI_MGR_MAX_SCAN];
static wifi_mgr_ap_t s_scan_work[WIFI_MGR_MAX_SCAN];
static wifi_request_t s_request;
static bool s_request_scan;
static bool s_events_lost;
// STOP is a fence for events from the old association. It has its own mailbox
// so a full queue can never lose the event needed to complete a radio stop.
static bool s_stop_seen;

// Worker-only state. Every successful setup step survives the next step's
// failure: low memory must not cause a duplicate netif or duplicate handlers.
static esp_netif_t *s_netif;
static bool s_netif_attached;
static bool s_default_handlers;
static bool s_drv_inited;
static bool s_wifi_handler;
static bool s_ip_handler;
static bool s_started;
static bool s_stopping;
static bool s_stop_fault;
static after_stop_t s_after_stop;
static TickType_t s_stop_at;
static bool s_scan_requested;
static bool s_scan_active;
static TickType_t s_scan_at;
static bool s_want_connected;
static bool s_retry_after_scan;
static unsigned s_retry;
static bool s_connect_timer;
static TickType_t s_connect_at;
static TickType_t s_rssi_at;
static wifi_request_t s_target;
static bool s_dirty;

static void changed(void)
{
    // Caller holds s_lock. Callback is emitted once at the end of worker_step.
    ++s_view.revision;
    s_dirty = true;
}

static void publish_state(wifi_mgr_state_t state)
{
    portENTER_CRITICAL(&s_lock);
    s_view.state = state;
    if (state != WIFI_MGR_CONNECTED) {
        s_view.ip[0] = '\0';
        s_view.rssi = 0;
    }
    changed();
    portEXIT_CRITICAL(&s_lock);
}

static void publish_scan(wifi_mgr_scan_status_t status, bool completed)
{
    portENTER_CRITICAL(&s_lock);
    s_view.scan_status = status;
    if (completed) ++s_view.scan_revision;
    changed();
    portEXIT_CRITICAL(&s_lock);
}

static void clear_selection(void)
{
    portENTER_CRITICAL(&s_lock);
    s_view.pending_ssid[0] = '\0';
    s_view.pending_secure = false;
    changed();
    portEXIT_CRITICAL(&s_lock);
}

static void enqueue_event(const wifi_message_t *message)
{
    if (xQueueSend(s_events, message, 0) != pdTRUE) {
        portENTER_CRITICAL(&s_lock);
        s_events_lost = true;
        portEXIT_CRITICAL(&s_lock);
    }
    xTaskNotifyGive(s_worker);
}

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    (void)base;
    if (id == WIFI_EVENT_STA_STOP) {
        portENTER_CRITICAL(&s_lock);
        s_stop_seen = true;
        portEXIT_CRITICAL(&s_lock);
        xTaskNotifyGive(s_worker);
    } else if (id == WIFI_EVENT_STA_DISCONNECTED) {
        const wifi_event_sta_disconnected_t *event = data;
        wifi_message_t message = { .kind = EVENT_DISCONNECTED,
                                  .value = event ? event->reason : 0 };
        enqueue_event(&message);
    } else if (id == WIFI_EVENT_SCAN_DONE) {
        const wifi_event_sta_scan_done_t *event = data;
        wifi_message_t message = { .kind = EVENT_SCAN_DONE,
                                  .value = event ? event->status : 1 };
        enqueue_event(&message);
    }
}

static void on_ip_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg;
    (void)base;
    if (id != IP_EVENT_STA_GOT_IP || !data) return;
    const ip_event_got_ip_t *event = data;
    if (event->esp_netif != s_netif) return;
    wifi_message_t message = { .kind = EVENT_GOT_IP, .value = event->ip_info.ip.addr };
    snprintf(message.ip, sizeof(message.ip), IPSTR, IP2STR(&event->ip_info.ip));
    enqueue_event(&message);
}

static void log_wifi_memory(const char *stage)
{
    ESP_LOGI(TAG, "%s: internal free=%u largest=%u minimum=%u bytes", stage,
             (unsigned)heap_caps_get_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
             (unsigned)heap_caps_get_largest_free_block(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT),
             (unsigned)heap_caps_get_minimum_free_size(MALLOC_CAP_INTERNAL | MALLOC_CAP_8BIT));
}

static bool bring_up(void)
{
    if (s_started) return true;
    esp_err_t err = demo_radio_network_prepare();
    if (err != ESP_OK) goto failed;

    if (!s_netif) {
        // The convenience create_default_wifi_sta() asserts on allocation and
        // handler errors. Use its fallible steps directly so BLE memory pressure
        // produces an error message, not a reset and another boot chime.
        esp_netif_config_t config = ESP_NETIF_DEFAULT_WIFI_STA();
        s_netif = esp_netif_new(&config);
        if (!s_netif) { err = ESP_ERR_NO_MEM; goto failed; }
    }
    if (!s_netif_attached) {
        err = esp_netif_attach_wifi_station(s_netif);
        if (err != ESP_OK) goto failed;
        s_netif_attached = true;
    }
    if (!s_default_handlers) {
        err = esp_wifi_set_default_wifi_sta_handlers();
        if (err != ESP_OK) goto failed;
        s_default_handlers = true;
    }
    if (!s_drv_inited) {
        wifi_init_config_t config = WIFI_INIT_CONFIG_DEFAULT();
        // Preserve this board's RAM budget even when an incremental build still
        // has a previous sdkconfig. Driver NVS is unnecessary: device_config
        // already owns the saved credentials. This skips NVS open/load work at
        // init; the driver's base configuration block still needs internal RAM.
        config.nvs_enable = 0;
        config.static_rx_buf_num = 4;
        config.dynamic_rx_buf_num = 8;
        config.tx_buf_type = 1; // Allocate TX buffers only while sending.
        config.static_tx_buf_num = 0;
        config.dynamic_tx_buf_num = 8;
        config.cache_tx_buf_num = 0;
        config.feature_caps &= ~((uint64_t)CONFIG_FEATURE_CACHE_TX_BUF_BIT);
        config.rx_mgmt_buf_type = 0; // Static: avoid scan-time heap fragmentation.
        config.rx_mgmt_buf_num = 3;
        config.mgmt_sbuf_num = 8;
        config.ampdu_rx_enable = 0;
        config.ampdu_tx_enable = 0;
        config.amsdu_tx_enable = 0;
        config.rx_ba_win = 0;
        log_wifi_memory("Before Wi-Fi init");
        err = esp_wifi_init(&config);
        if (err != ESP_OK) goto failed;
        s_drv_inited = true;
        log_wifi_memory("After Wi-Fi init");
    }
    if (!s_wifi_handler) {
        err = esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                                  on_wifi_event, NULL, NULL);
        if (err != ESP_OK) goto failed;
        s_wifi_handler = true;
    }
    if (!s_ip_handler) {
        err = esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                                  on_ip_event, NULL, NULL);
        if (err != ESP_OK) goto failed;
        s_ip_handler = true;
    }
    err = esp_wifi_set_storage(WIFI_STORAGE_RAM);
    if (err != ESP_OK) goto failed;
    err = esp_wifi_set_mode(WIFI_MODE_STA);
    if (err != ESP_OK) goto failed;
    err = esp_wifi_start();
    if (err != ESP_OK) goto failed;
    s_started = true;
    log_wifi_memory("After Wi-Fi start");
    return true;

failed:
    ESP_LOGW(TAG, "Wi-Fi startup failed: %s", esp_err_to_name(err));
    log_wifi_memory("Wi-Fi startup failure");
    return false;
}

static void fail_connection(void)
{
    s_want_connected = false;
    s_retry_after_scan = false;
    s_connect_timer = false;
    memset(&s_target, 0, sizeof(s_target));
    publish_state(WIFI_MGR_FAILED);
}

static void start_attempt(void)
{
    if (!s_connect_timer) {
        s_connect_at = xTaskGetTickCount();
        s_connect_timer = true;
    }
    esp_err_t err = esp_wifi_connect();
    if (err != ESP_OK) {
        // ESP_ERR_WIFI_CONN is an internal driver error, not success.
        ESP_LOGW(TAG, "Wi-Fi connect failed: %s", esp_err_to_name(err));
        fail_connection();
    } else {
        publish_state(WIFI_MGR_CONNECTING);
    }
}

static void finish_stop(void)
{
    s_stopping = false;
    if (s_after_stop != AFTER_STOP_CONNECT) {
        publish_state(s_after_stop == AFTER_STOP_OFF ? WIFI_MGR_OFF : WIFI_MGR_FAILED);
        memset(&s_target, 0, sizeof(s_target));
        return;
    }
    if (!bring_up()) { fail_connection(); return; }
    wifi_config_t config = { 0 };
    // Full 32-byte SSIDs and full 64-byte PSKs occupy the complete IDF fields.
    memcpy(config.sta.ssid, s_target.ssid, strlen(s_target.ssid));
    memcpy(config.sta.password, s_target.password, strlen(s_target.password));
    esp_err_t err = esp_wifi_set_config(WIFI_IF_STA, &config);
    memset(config.sta.password, 0, sizeof(config.sta.password));
    memset(&s_target, 0, sizeof(s_target));
    if (err != ESP_OK) { fail_connection(); return; }
    start_attempt();
}

static void stop_for(after_stop_t after)
{
    s_after_stop = after;
    s_retry_after_scan = false;
    s_connect_timer = false;
    s_scan_requested = false;
    if (s_scan_active) {
        // A cancelled scan will not reach scan_finished(). Release its driver
        // results here, before stopping STA makes clear_ap_list unavailable.
        esp_wifi_scan_stop();
        esp_wifi_clear_ap_list();
    }
    if (s_scan_active || wifi_mgr_scan_busy()) {
        s_scan_active = false;
        publish_scan(wifi_mgr_scan_count() ? WIFI_MGR_SCAN_READY : WIFI_MGR_SCAN_IDLE, false);
    }
    if (s_stopping) return; // A newer request replaces the action after this stop.
    if (s_stop_fault) {
        s_after_stop = AFTER_STOP_FAILED;
        fail_connection();
        return;
    }
    if (!s_started) { finish_stop(); return; }

    portENTER_CRITICAL(&s_lock);
    s_stop_seen = false;
    portEXIT_CRITICAL(&s_lock);
    s_stopping = true;
    s_stop_at = xTaskGetTickCount();
    esp_err_t err = esp_wifi_stop();
    if (err != ESP_OK) {
        s_stopping = false;
        ESP_LOGW(TAG, "Wi-Fi stop failed: %s", esp_err_to_name(err));
        fail_connection();
        return;
    }
    s_started = false;
    // Do not start the next association until STA_STOP has crossed the event
    // loop. Old DISCONNECTED/GOT_IP/SCAN_DONE events are ignored while stopping.
}

static void apply_request(wifi_request_t *request)
{
    if (request->kind == REQUEST_DISCONNECT) {
        s_want_connected = false;
        clear_selection();
        stop_for(AFTER_STOP_OFF);
        return;
    }
    if (request->kind == REQUEST_SELECT) {
        char saved_ssid[WIFI_MGR_SSID_LEN];
        char saved_password[WIFI_MGR_PASSWORD_LEN];
        device_config_wifi_copy(saved_ssid, sizeof(saved_ssid),
                                saved_password, sizeof(saved_password));
        wifi_mgr_ap_t ap = { .secure = request->secure };
        memcpy(ap.ssid, request->ssid, sizeof(ap.ssid));
        wifi_mgr_credential_choice_t choice = wifi_mgr_choose_credentials(
            &ap, saved_ssid, saved_password);
        if (choice == WIFI_MGR_USE_SAVED) {
            memcpy(request->password, saved_password, sizeof(request->password));
        }
        memset(saved_password, 0, sizeof(saved_password));
        if (choice == WIFI_MGR_ASK_PASSWORD) {
            portENTER_CRITICAL(&s_lock);
            memcpy(s_view.pending_ssid, request->ssid, sizeof(s_view.pending_ssid));
            s_view.pending_secure = true;
            changed();
            portEXIT_CRITICAL(&s_lock);
            return;
        }
    }
    clear_selection();
    s_target = *request;
    s_retry = 0;
    s_want_connected = true;
    portENTER_CRITICAL(&s_lock);
    memcpy(s_view.ssid, request->ssid, sizeof(s_view.ssid));
    portEXIT_CRITICAL(&s_lock);
    publish_state(WIFI_MGR_CONNECTING);
    stop_for(AFTER_STOP_CONNECT);
}

static void scan_finished(uint32_t status)
{
    if (!s_scan_active || s_stopping) return;
    s_scan_active = false;
    uint16_t total = 0;
    esp_err_t err = status == 0 ? esp_wifi_scan_get_ap_num(&total) : ESP_FAIL;
    if (status != 0) {
        ESP_LOGW(TAG, "Wi-Fi scan completion failed: status=%lu", (unsigned long)status);
        log_wifi_memory("After failed Wi-Fi scan");
    } else if (err != ESP_OK) {
        ESP_LOGW(TAG, "Read Wi-Fi scan count failed: %s", esp_err_to_name(err));
    } else {
        ESP_LOGI(TAG, "Wi-Fi scan completed: raw AP count=%u", (unsigned)total);
    }
    int count = 0;
    wifi_ap_record_t record;
    if (err == ESP_OK) {
        // Reading one record at a time frees driver memory incrementally and
        // avoids a second large array of IDF records on this no-PSRAM board.
        for (uint16_t i = 0; i < total; ++i) {
            err = esp_wifi_scan_get_ap_record(&record);
            if (err != ESP_OK) {
                ESP_LOGW(TAG, "Read Wi-Fi scan record %u/%u failed: %s",
                         (unsigned)i, (unsigned)total, esp_err_to_name(err));
                break;
            }
            count = wifi_mgr_merge_ap(s_scan_work, count, record.ssid, record.rssi,
                                      record.authmode != WIFI_AUTH_OPEN);
        }
    }
    esp_wifi_clear_ap_list(); // Required on empty, failed and truncated scans too.
    portENTER_CRITICAL(&s_lock);
    s_view.scan_count = err == ESP_OK ? count : 0;
    if (err == ESP_OK) memcpy(s_scan, s_scan_work, (size_t)count * sizeof(s_scan[0]));
    portEXIT_CRITICAL(&s_lock);
    publish_scan(err == ESP_OK ? WIFI_MGR_SCAN_READY : WIFI_MGR_SCAN_FAILED, true);
    if (s_retry_after_scan && s_want_connected) {
        s_retry_after_scan = false;
        start_attempt();
    }
}

static void process_event(const wifi_message_t *message)
{
    if (s_stopping || !s_started) return;
    switch (message->kind) {
    case EVENT_SCAN_DONE:
        scan_finished(message->value);
        break;
    case EVENT_DISCONNECTED:
        if (!s_want_connected) break;
        if (s_retry >= WIFI_MGR_MAX_RETRY) {
            ESP_LOGW(TAG, "Wi-Fi connection failed, reason=%u", (unsigned)message->value);
            fail_connection();
            break;
        }
        ++s_retry;
        publish_state(WIFI_MGR_CONNECTING);
        if (s_scan_active) s_retry_after_scan = true;
        else start_attempt();
        break;
    case EVENT_GOT_IP: {
        if (!s_want_connected) break;
        wifi_ap_record_t ap;
        esp_netif_ip_info_t ip;
        if (esp_wifi_sta_get_ap_info(&ap) != ESP_OK ||
            strncmp((const char *)ap.ssid, s_view.ssid, 32) != 0 ||
            esp_netif_get_ip_info(s_netif, &ip) != ESP_OK ||
            ip.ip.addr != message->value) break;
        s_retry = 0;
        s_connect_timer = false;
        s_retry_after_scan = false;
        portENTER_CRITICAL(&s_lock);
        memcpy(s_view.ip, message->ip, sizeof(s_view.ip));
        s_view.rssi = ap.rssi;
        s_view.state = WIFI_MGR_CONNECTED;
        changed();
        portEXIT_CRITICAL(&s_lock);
        break;
    }
    }
}

static void maybe_start_scan(void)
{
    if (!s_scan_requested || s_scan_active || s_stopping ||
        (s_want_connected && wifi_mgr_state() == WIFI_MGR_CONNECTING)) return;
    s_scan_requested = false;
    if (s_stop_fault || !bring_up()) {
        publish_scan(WIFI_MGR_SCAN_FAILED, true);
        if (!s_started) publish_state(WIFI_MGR_FAILED);
        return;
    }
    if (!s_want_connected && (wifi_mgr_state() != WIFI_MGR_FAILED || !s_view.ssid[0])) {
        publish_state(WIFI_MGR_IDLE);
    }
    esp_err_t err = esp_wifi_scan_start(NULL, false);
    if (err != ESP_OK) {
        ESP_LOGW(TAG, "Wi-Fi scan failed: %s", esp_err_to_name(err));
        esp_wifi_clear_ap_list();
        publish_scan(WIFI_MGR_SCAN_FAILED, true);
        return;
    }
    s_scan_active = true;
    s_scan_at = xTaskGetTickCount();
    publish_scan(WIFI_MGR_SCAN_SCANNING, false);
}

static void worker_step(void)
{
    wifi_request_t request;
    bool scan, lost;
    portENTER_CRITICAL(&s_lock);
    request = s_request;
    memset(&s_request, 0, sizeof(s_request));
    scan = s_request_scan;
    s_request_scan = false;
    lost = s_events_lost;
    s_events_lost = false;
    portEXIT_CRITICAL(&s_lock);

    if (request.kind != REQUEST_NONE) apply_request(&request);
    memset(&request, 0, sizeof(request));
    if (scan && !s_scan_active) {
        s_scan_requested = true;
        publish_scan(WIFI_MGR_SCAN_SCANNING, false);
    }
    if (lost) {
        ESP_LOGW(TAG, "Wi-Fi event queue full; stopping safely");
        fail_connection();
        stop_for(AFTER_STOP_FAILED);
        publish_scan(WIFI_MGR_SCAN_FAILED, true);
    }
    wifi_message_t message;
    while (xQueueReceive(s_events, &message, 0) == pdTRUE) process_event(&message);
    bool stopped;
    portENTER_CRITICAL(&s_lock);
    stopped = s_stop_seen;
    s_stop_seen = false;
    portEXIT_CRITICAL(&s_lock);
    if (stopped && (s_stopping || s_stop_fault)) {
        s_stop_fault = false;
        finish_stop();
    }

    TickType_t now = xTaskGetTickCount();
    if (s_stopping && now - s_stop_at >= pdMS_TO_TICKS(WIFI_MGR_STOP_TIMEOUT_MS)) {
        // Never start into an uncertain event epoch. A late STOP can release
        // this fence; until then requests fail visibly instead of racing it.
        s_stopping = false;
        s_stop_fault = true;
        s_after_stop = AFTER_STOP_FAILED;
        fail_connection();
        if (s_scan_requested) publish_scan(WIFI_MGR_SCAN_FAILED, true);
        s_scan_requested = false;
    }
    if (s_connect_timer && now - s_connect_at >= pdMS_TO_TICKS(WIFI_MGR_CONNECT_TIMEOUT_MS)) {
        bool scan_waiting = s_scan_requested;
        fail_connection();
        stop_for(AFTER_STOP_FAILED);
        s_scan_requested = scan_waiting;
        if (scan_waiting) publish_scan(WIFI_MGR_SCAN_SCANNING, false);
    }
    if (s_scan_active && now - s_scan_at >= pdMS_TO_TICKS(WIFI_MGR_SCAN_TIMEOUT_MS)) {
        ESP_LOGW(TAG, "Wi-Fi scan timed out after %d ms", WIFI_MGR_SCAN_TIMEOUT_MS);
        log_wifi_memory("After Wi-Fi scan timeout");
        esp_wifi_scan_stop();
        esp_wifi_clear_ap_list();
        s_scan_active = false;
        s_retry_after_scan = false;
        publish_scan(WIFI_MGR_SCAN_FAILED, true);
    }
    maybe_start_scan();
    if (wifi_mgr_is_connected() && now - s_rssi_at >= pdMS_TO_TICKS(2000)) {
        s_rssi_at = now;
        wifi_ap_record_t ap;
        if (esp_wifi_sta_get_ap_info(&ap) == ESP_OK) {
            portENTER_CRITICAL(&s_lock);
            if (s_view.rssi != ap.rssi) { s_view.rssi = ap.rssi; changed(); }
            portEXIT_CRITICAL(&s_lock);
        }
    }
    if (s_dirty) {
        s_dirty = false;
        if (s_on_change) s_on_change();
    }
}

static void worker(void *arg)
{
    (void)arg;
    for (;;) {
        ulTaskNotifyTake(pdTRUE, pdMS_TO_TICKS(100));
        worker_step();
    }
}

void wifi_mgr_init(wifi_mgr_watch_fn on_change)
{
    s_on_change = on_change;
    if (s_worker) return;
    s_events = xQueueCreate(WIFI_MGR_EVENT_COUNT, sizeof(wifi_message_t));
    if (!s_events || xTaskCreate(worker, "wifi_mgr", 4096, NULL, 4, &s_worker) != pdPASS) {
        if (s_events) vQueueDelete(s_events);
        s_events = NULL;
        publish_state(WIFI_MGR_FAILED);
        ESP_LOGW(TAG, "Insufficient memory for Wi-Fi worker");
    }
}

void wifi_mgr_snapshot(wifi_mgr_snapshot_t *out)
{
    if (!out) return;
    portENTER_CRITICAL(&s_lock);
    *out = s_view;
    portEXIT_CRITICAL(&s_lock);
}

wifi_mgr_state_t wifi_mgr_state(void)
{
    portENTER_CRITICAL(&s_lock);
    wifi_mgr_state_t state = s_view.state;
    portEXIT_CRITICAL(&s_lock);
    return state;
}
bool wifi_mgr_is_connected(void) { return wifi_mgr_state() == WIFI_MGR_CONNECTED; }
const char *wifi_mgr_ssid(void) { return s_view.ssid; }
const char *wifi_mgr_ip(void) { return s_view.ip; }
int wifi_mgr_rssi(void)
{
    portENTER_CRITICAL(&s_lock);
    int rssi = s_view.rssi;
    portEXIT_CRITICAL(&s_lock);
    return rssi;
}
int wifi_mgr_scan_count(void)
{
    portENTER_CRITICAL(&s_lock);
    int count = s_view.scan_count;
    portEXIT_CRITICAL(&s_lock);
    return count;
}
wifi_mgr_scan_status_t wifi_mgr_scan_status(void)
{
    portENTER_CRITICAL(&s_lock);
    wifi_mgr_scan_status_t status = s_view.scan_status;
    portEXIT_CRITICAL(&s_lock);
    return status;
}
bool wifi_mgr_scan_busy(void) { return wifi_mgr_scan_status() == WIFI_MGR_SCAN_SCANNING; }

bool wifi_mgr_scan_entry(int index, wifi_mgr_ap_t *out)
{
    portENTER_CRITICAL(&s_lock);
    bool valid = index >= 0 && index < s_view.scan_count;
    if (valid && out) *out = s_scan[index];
    portEXIT_CRITICAL(&s_lock);
    return valid;
}

static bool submit(const wifi_request_t *request)
{
    if (!s_worker) return false;
    portENTER_CRITICAL(&s_lock);
    s_request = *request; // Latest connection intent wins; disconnect cannot be dropped.
    if (request->kind != REQUEST_SELECT) s_request_scan = false;
    portEXIT_CRITICAL(&s_lock);
    xTaskNotifyGive(s_worker);
    return true;
}

bool wifi_mgr_connect(const char *ssid, const char *password)
{
    wifi_request_t request = { .kind = REQUEST_CONNECT };
    char saved_ssid[WIFI_MGR_SSID_LEN];
    char saved_password[WIFI_MGR_PASSWORD_LEN];
    device_config_wifi_copy(saved_ssid, sizeof(saved_ssid),
                            saved_password, sizeof(saved_password));
    if (!ssid || !ssid[0]) ssid = saved_ssid;
    if (!password && strcmp(ssid, saved_ssid) == 0) password = saved_password;
    size_t ssid_len = strlen(ssid);
    size_t password_len = password ? strlen(password) : WIFI_MGR_PASSWORD_LEN;
    bool valid = wifi_mgr_ssid_supported((const unsigned char *)ssid, ssid_len) &&
                 password_len < WIFI_MGR_PASSWORD_LEN;
    if (valid) {
        memcpy(request.ssid, ssid, ssid_len);
        memcpy(request.password, password, password_len);
    }
    memset(saved_password, 0, sizeof(saved_password));
    bool accepted = valid && submit(&request);
    memset(&request, 0, sizeof(request));
    return accepted;
}

void wifi_mgr_disconnect(void)
{
    wifi_request_t request = { .kind = REQUEST_DISCONNECT };
    submit(&request);
}

bool wifi_mgr_scan_start(void)
{
    if (!s_worker) return false;
    portENTER_CRITICAL(&s_lock);
    s_request_scan = true;
    portEXIT_CRITICAL(&s_lock);
    xTaskNotifyGive(s_worker);
    return true;
}

bool wifi_mgr_select_network(int index)
{
    wifi_mgr_ap_t ap;
    if (!wifi_mgr_scan_entry(index, &ap)) return false;
    return wifi_mgr_select_ap(&ap);
}

bool wifi_mgr_select_ap(const wifi_mgr_ap_t *ap)
{
    if (!ap || !memchr(ap->ssid, '\0', sizeof(ap->ssid)) ||
        !wifi_mgr_ssid_supported((const unsigned char *)ap->ssid, strlen(ap->ssid))) return false;
    wifi_request_t request = { .kind = REQUEST_SELECT, .secure = ap->secure };
    memcpy(request.ssid, ap->ssid, sizeof(request.ssid));
    return submit(&request);
}
