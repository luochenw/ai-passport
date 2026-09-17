// Exercise the real worker with deterministic driver/event-loop stand-ins.
// Every network API asserts worker context, including APIs reached on retry.
#include <assert.h>
#include <stdlib.h>
#include <sys/wait.h>
#include <unistd.h>
#include "../main/wifi_mgr.c"

static bool f_worker;
static bool f_associated;
static TickType_t f_now;
static int f_new_calls, f_attach_calls, f_init_calls, f_wifi_handlers, f_ip_handlers;
static int f_start_calls, f_stop_calls, f_connect_calls, f_scan_calls, f_clear_calls;
static int f_new_failures, f_init_failures, f_ip_failures, f_scan_failure, f_connect_failure;
static int f_ap_count, f_ap_cursor;
static wifi_ap_record_t f_aps[32];
static wifi_config_t f_config;
static esp_netif_t f_netif;
static char f_saved_ssid[33], f_saved_pass[65];

typedef struct {
    unsigned count, size, used, first;
    unsigned char bytes[WIFI_MGR_EVENT_COUNT * sizeof(wifi_message_t)];
} fake_queue_t;

const char *esp_err_to_name(esp_err_t error) { (void)error; return "simulated"; }
size_t heap_caps_get_free_size(uint32_t caps) { (void)caps; return 40000; }
size_t heap_caps_get_largest_free_block(uint32_t caps) { (void)caps; return 30000; }
size_t heap_caps_get_minimum_free_size(uint32_t caps) { (void)caps; return 20000; }
QueueHandle_t xQueueCreate(unsigned count, size_t size)
{
    fake_queue_t *queue = calloc(1, sizeof(*queue));
    assert(queue && count * size <= sizeof(queue->bytes));
    queue->count = count;
    queue->size = (unsigned)size;
    return queue;
}
int xQueueSend(QueueHandle_t handle, const void *item, TickType_t wait)
{
    (void)wait;
    fake_queue_t *queue = handle;
    if (queue->used == queue->count) return 0;
    unsigned at = (queue->first + queue->used++) % queue->count;
    memcpy(queue->bytes + at * queue->size, item, queue->size);
    return pdTRUE;
}
int xQueueReceive(QueueHandle_t handle, void *item, TickType_t wait)
{
    (void)wait;
    fake_queue_t *queue = handle;
    if (queue->used == 0) return 0;
    memcpy(item, queue->bytes + queue->first * queue->size, queue->size);
    queue->first = (queue->first + 1) % queue->count;
    --queue->used;
    return pdTRUE;
}
void vQueueDelete(QueueHandle_t queue) { free(queue); }
int xTaskCreate(void (*entry)(void *), const char *name, unsigned stack, void *arg,
                unsigned priority, TaskHandle_t *handle)
{
    (void)entry; (void)name; (void)stack; (void)arg; (void)priority;
    *handle = (void *)1;
    return pdPASS;
}
void xTaskNotifyGive(TaskHandle_t task) { assert(task); }
uint32_t ulTaskNotifyTake(int clear, TickType_t wait) { (void)clear; (void)wait; return 1; }
TickType_t xTaskGetTickCount(void) { return f_now; }
esp_err_t demo_radio_network_prepare(void) { assert(f_worker); return ESP_OK; }
esp_netif_t *esp_netif_new(const esp_netif_config_t *config)
{
    (void)config; assert(f_worker); ++f_new_calls;
    if (f_new_failures > 0) { --f_new_failures; return NULL; }
    return &f_netif;
}
esp_err_t esp_netif_attach_wifi_station(esp_netif_t *netif)
{ assert(f_worker && netif == &f_netif); ++f_attach_calls; return ESP_OK; }
esp_err_t esp_wifi_set_default_wifi_sta_handlers(void) { assert(f_worker); return ESP_OK; }
esp_err_t esp_event_handler_instance_register(esp_event_base_t base, int32_t id,
    void (*handler)(void *, esp_event_base_t, int32_t, void *), void *arg, void *instance)
{
    (void)id; (void)handler; (void)arg; (void)instance; assert(f_worker);
    if (base == WIFI_EVENT) ++f_wifi_handlers;
    if (base == IP_EVENT) {
        ++f_ip_handlers;
        if (f_ip_failures > 0) { --f_ip_failures; return ESP_ERR_NO_MEM; }
    }
    return ESP_OK;
}
esp_err_t esp_wifi_init(const wifi_init_config_t *config)
{
    assert(f_worker); ++f_init_calls;
    // The no-PSRAM board disables duplicate credential storage and bounds the
    // throughput buffers while BLE and the screen are running.
    assert(config->nvs_enable == 0);
    assert(config->static_rx_buf_num == 4 && config->dynamic_rx_buf_num == 8);
    assert(config->tx_buf_type == 1 && config->static_tx_buf_num == 0);
    assert(config->dynamic_tx_buf_num == 8 && config->cache_tx_buf_num == 0);
    assert(config->ampdu_rx_enable == 0 && config->ampdu_tx_enable == 0);
    assert(config->rx_ba_win == 0 && config->rx_mgmt_buf_num == 3);
    if (f_init_failures > 0) { --f_init_failures; return ESP_ERR_NO_MEM; }
    return ESP_OK;
}
esp_err_t esp_wifi_set_storage(int storage) { (void)storage; assert(f_worker); return ESP_OK; }
esp_err_t esp_wifi_set_mode(int mode) { (void)mode; assert(f_worker); return ESP_OK; }
esp_err_t esp_wifi_start(void) { assert(f_worker); ++f_start_calls; return ESP_OK; }
esp_err_t esp_wifi_stop(void) { assert(f_worker); ++f_stop_calls; f_associated = false; return ESP_OK; }
esp_err_t esp_wifi_connect(void)
{ assert(f_worker); ++f_connect_calls; return f_connect_failure ? ESP_ERR_WIFI_CONN : ESP_OK; }
esp_err_t esp_wifi_set_config(int interface, const wifi_config_t *config)
{ (void)interface; assert(f_worker); f_config = *config; return ESP_OK; }
esp_err_t esp_wifi_scan_start(const void *config, bool block)
{
    (void)config; assert(f_worker && !block); ++f_scan_calls;
    f_ap_cursor = 0;
    return f_scan_failure ? ESP_FAIL : ESP_OK;
}
esp_err_t esp_wifi_scan_stop(void) { assert(f_worker); return ESP_OK; }
esp_err_t esp_wifi_scan_get_ap_num(uint16_t *total)
{ assert(f_worker); *total = (uint16_t)f_ap_count; return ESP_OK; }
esp_err_t esp_wifi_scan_get_ap_record(wifi_ap_record_t *record)
{ assert(f_worker && f_ap_cursor < f_ap_count); *record = f_aps[f_ap_cursor++]; return ESP_OK; }
esp_err_t esp_wifi_clear_ap_list(void) { assert(f_worker); ++f_clear_calls; return ESP_OK; }
esp_err_t esp_wifi_sta_get_ap_info(wifi_ap_record_t *record)
{
    assert(f_worker);
    if (!f_associated) return ESP_FAIL;
    memset(record, 0, sizeof(*record));
    memcpy(record->ssid, f_config.sta.ssid, 32);
    record->rssi = -42;
    return ESP_OK;
}
esp_err_t esp_netif_get_ip_info(esp_netif_t *netif, esp_netif_ip_info_t *ip)
{ assert(f_worker && netif == &f_netif); ip->ip.addr = 2; return ESP_OK; }
void device_config_wifi_copy(char *ssid, size_t ssid_size, char *password, size_t password_size)
{
    snprintf(ssid, ssid_size, "%s", f_saved_ssid);
    snprintf(password, password_size, "%s", f_saved_pass);
}

static void step(void) { f_worker = true; worker_step(); f_worker = false; }
static void event(int id)
{
    wifi_event_sta_disconnected_t disconnected = { .reason = 201 };
    wifi_event_sta_scan_done_t scan = { .status = 0 };
    on_wifi_event(NULL, WIFI_EVENT, id, id == WIFI_EVENT_SCAN_DONE ? (void *)&scan : (void *)&disconnected);
}
static void got_ip(void)
{
    f_associated = true;
    ip_event_got_ip_t ip = { .esp_netif = &f_netif, .ip_info.ip.addr = 2 };
    on_ip_event(NULL, IP_EVENT, IP_EVENT_STA_GOT_IP, &ip);
    step();
    assert(wifi_mgr_is_connected());
}
static void connect_first(void)
{
    wifi_mgr_init(NULL);
    assert(wifi_mgr_connect("first", "password"));
    assert(f_new_calls == 0 && f_connect_calls == 0);
    step();
    assert(f_connect_calls == 1 && wifi_mgr_state() == WIFI_MGR_CONNECTING);
}

static void test_partial_startup(void)
{
    wifi_mgr_init(NULL);
    f_new_failures = 1;
    assert(wifi_mgr_scan_start()); step();
    assert(wifi_mgr_scan_status() == WIFI_MGR_SCAN_FAILED && f_new_calls == 1);
    f_init_failures = 1;
    assert(wifi_mgr_scan_start()); step();
    assert(f_new_calls == 2 && f_attach_calls == 1 && f_init_calls == 1);
    f_ip_failures = 1;
    assert(wifi_mgr_scan_start()); step();
    assert(f_new_calls == 2 && f_init_calls == 2 && f_wifi_handlers == 1);
    assert(wifi_mgr_scan_start()); step();
    assert(f_new_calls == 2 && f_init_calls == 2 && f_wifi_handlers == 1 && f_ip_handlers == 2);
    assert(f_scan_calls == 1);
    event(WIFI_EVENT_SCAN_DONE); step();
    assert(wifi_mgr_scan_status() == WIFI_MGR_SCAN_READY && wifi_mgr_scan_count() == 0);
    wifi_mgr_snapshot_t snapshot; wifi_mgr_snapshot(&snapshot);
    assert(snapshot.scan_revision == 4 && f_clear_calls == 1);
}

static void test_switch_and_disconnect(void)
{
    connect_first(); got_ip();
    assert(wifi_mgr_connect("second", "second-pass")); step();
    assert(f_stop_calls == 1 && f_connect_calls == 1);
    // A newer target while waiting for STOP must replace the previous target.
    assert(wifi_mgr_connect("third", "third-pass")); step();
    event(WIFI_EVENT_STA_DISCONNECTED); step();
    assert(f_connect_calls == 1);
    event(WIFI_EVENT_STA_STOP); step();
    assert(f_connect_calls == 2 && strcmp((const char *)f_config.sta.ssid, "third") == 0);
    got_ip();
    wifi_mgr_disconnect(); step();
    event(WIFI_EVENT_STA_DISCONNECTED); event(WIFI_EVENT_STA_STOP); step();
    assert(f_connect_calls == 2 && wifi_mgr_state() == WIFI_MGR_OFF);
    assert(wifi_mgr_scan_start()); step();
    assert(f_new_calls == 1 && f_init_calls == 1 && f_scan_calls == 1);
}

static void test_scan_during_connect(void)
{
    connect_first();
    assert(wifi_mgr_scan_start()); step();
    assert(f_scan_calls == 0 && wifi_mgr_scan_busy());
    got_ip();
    assert(f_scan_calls == 1);
    // Connection lost during a background scan: retry waits for SCAN_DONE.
    event(WIFI_EVENT_STA_DISCONNECTED); step();
    assert(f_connect_calls == 1);
    event(WIFI_EVENT_SCAN_DONE); step();
    assert(f_connect_calls == 2 && !wifi_mgr_scan_busy());
    event(WIFI_EVENT_STA_DISCONNECTED); step();
    event(WIFI_EVENT_STA_DISCONNECTED); step();
    event(WIFI_EVENT_STA_DISCONNECTED); step();
    assert(f_connect_calls == 4 && wifi_mgr_state() == WIFI_MGR_FAILED);
}

static void test_timeout_and_queue_pressure(void)
{
    connect_first();
    assert(wifi_mgr_scan_start()); step();
    f_now = WIFI_MGR_CONNECT_TIMEOUT_MS + 1; step();
    assert(f_stop_calls == 1);
    event(WIFI_EVENT_STA_STOP); step();
    assert(f_scan_calls == 1);
    for (int i = 0; i < WIFI_MGR_EVENT_COUNT + 2; ++i) event(WIFI_EVENT_STA_DISCONNECTED);
    step();
    assert(f_stop_calls == 2);
    event(WIFI_EVENT_STA_STOP); step();
    assert(wifi_mgr_scan_status() == WIFI_MGR_SCAN_FAILED && wifi_mgr_state() == WIFI_MGR_FAILED);
    assert(wifi_mgr_scan_start()); step();
    assert(f_scan_calls == 2);
}

static void test_selection(void)
{
    wifi_mgr_init(NULL);
    snprintf(f_saved_ssid, sizeof(f_saved_ssid), "saved");
    snprintf(f_saved_pass, sizeof(f_saved_pass), "old-password");
    wifi_mgr_ap_t ap = { .ssid = "new", .secure = true };
    assert(wifi_mgr_select_ap(&ap)); step();
    wifi_mgr_snapshot_t snapshot; wifi_mgr_snapshot(&snapshot);
    assert(strcmp(snapshot.pending_ssid, "new") == 0 && snapshot.pending_secure && f_new_calls == 0);
    ap.secure = false;
    assert(wifi_mgr_select_ap(&ap)); step();
    assert(f_connect_calls == 1 && f_config.sta.password[0] == '\0');
    assert(!wifi_mgr_connect("another", NULL));
    assert(!wifi_mgr_connect("bad\nname", "password"));
    assert(wifi_mgr_connect("saved", NULL)); step();
    event(WIFI_EVENT_STA_STOP); step();
    assert(strcmp((const char *)f_config.sta.password, "old-password") == 0);
    wifi_mgr_snapshot(&snapshot);
    assert(snapshot.pending_ssid[0] == '\0' && !snapshot.pending_secure);
}

static void test_late_stop_and_full_credentials(void)
{
    connect_first();
    assert(wifi_mgr_connect("second", "password")); step();
    f_now += WIFI_MGR_STOP_TIMEOUT_MS + 1; step();
    assert(wifi_mgr_state() == WIFI_MGR_FAILED);
    assert(wifi_mgr_connect("third", "password")); step();
    event(WIFI_EVENT_STA_STOP); step();
    assert(f_connect_calls == 1 && wifi_mgr_state() == WIFI_MGR_FAILED);

    char ssid[33], password[65];
    memset(ssid, 's', 32); ssid[32] = '\0';
    memset(password, 'a', 64); password[64] = '\0';
    assert(wifi_mgr_connect(ssid, password)); step();
    assert(f_connect_calls == 2);
    assert(memcmp(f_config.sta.ssid, ssid, 32) == 0);
    assert(memcmp(f_config.sta.password, password, 64) == 0);
    f_connect_failure = 1;
    assert(wifi_mgr_connect("failed", "password")); step();
    event(WIFI_EVENT_STA_STOP); step();
    assert(wifi_mgr_state() == WIFI_MGR_FAILED);
}

static void test_scan_failure_and_replacement(void)
{
    wifi_mgr_init(NULL);
    f_ap_count = 3;
    memcpy(f_aps[0].ssid, "Cafe", 5); f_aps[0].rssi = -80;
    memcpy(f_aps[1].ssid, "Cafe", 5); f_aps[1].rssi = -50;
    memcpy(f_aps[2].ssid, "bad\nname", 9); f_aps[2].rssi = -30;
    assert(wifi_mgr_scan_start()); step();
    event(WIFI_EVENT_SCAN_DONE); step();
    wifi_mgr_ap_t ap;
    assert(wifi_mgr_scan_count() == 1 && wifi_mgr_scan_entry(0, &ap) && ap.rssi == -50);
    f_scan_failure = 1;
    assert(wifi_mgr_scan_start()); step();
    assert(wifi_mgr_scan_status() == WIFI_MGR_SCAN_FAILED);
    f_scan_failure = 0;
    assert(wifi_mgr_scan_start()); step();
    wifi_event_sta_scan_done_t error = { .status = 1 };
    on_wifi_event(NULL, WIFI_EVENT, WIFI_EVENT_SCAN_DONE, &error); step();
    wifi_mgr_snapshot_t snapshot; wifi_mgr_snapshot(&snapshot);
    assert(snapshot.scan_status == WIFI_MGR_SCAN_FAILED && snapshot.scan_count == 0);
    assert(snapshot.scan_revision == 3 && f_clear_calls == 3);
}

int main(void)
{
    void (*tests[])(void) = { test_partial_startup, test_switch_and_disconnect,
        test_scan_during_connect, test_timeout_and_queue_pressure, test_selection,
        test_late_stop_and_full_credentials, test_scan_failure_and_replacement };
    for (size_t i = 0; i < sizeof(tests) / sizeof(tests[0]); ++i) {
        pid_t child = fork();
        assert(child >= 0);
        if (child == 0) { tests[i](); _exit(0); }
        int status;
        assert(waitpid(child, &status, 0) == child);
        assert(WIFEXITED(status) && WEXITSTATUS(status) == 0);
    }
    puts("Wi-Fi worker tests: PASS");
    return 0;
}
