#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef int esp_err_t;
#define ESP_OK 0
#define ESP_FAIL 1
#define ESP_ERR_NO_MEM 2
#define ESP_ERR_WIFI_CONN 3
const char *esp_err_to_name(esp_err_t error);
#define ESP_LOGW(tag, ...) ((void)(tag))
#define ESP_LOGI(tag, format, ...) do { (void)(tag); if (0) printf(format, __VA_ARGS__); } while (0)
#define MALLOC_CAP_INTERNAL 1u
#define MALLOC_CAP_8BIT 2u
size_t heap_caps_get_free_size(uint32_t caps);
size_t heap_caps_get_largest_free_block(uint32_t caps);
size_t heap_caps_get_minimum_free_size(uint32_t caps);

typedef int portMUX_TYPE;
#define portMUX_INITIALIZER_UNLOCKED 0
#define portENTER_CRITICAL(lock) ((void)(lock))
#define portEXIT_CRITICAL(lock) ((void)(lock))
typedef uint32_t TickType_t;
typedef void *TaskHandle_t;
typedef void *QueueHandle_t;
#define pdTRUE 1
#define pdPASS 1
#define pdMS_TO_TICKS(ms) ((TickType_t)(ms))
QueueHandle_t xQueueCreate(unsigned count, size_t size);
int xQueueSend(QueueHandle_t queue, const void *item, TickType_t wait);
int xQueueReceive(QueueHandle_t queue, void *item, TickType_t wait);
void vQueueDelete(QueueHandle_t queue);
int xTaskCreate(void (*entry)(void *), const char *name, unsigned stack, void *arg,
                unsigned priority, TaskHandle_t *handle);
void xTaskNotifyGive(TaskHandle_t task);
uint32_t ulTaskNotifyTake(int clear, TickType_t wait);
TickType_t xTaskGetTickCount(void);

typedef const char *esp_event_base_t;
#define WIFI_EVENT ((esp_event_base_t)1)
#define IP_EVENT ((esp_event_base_t)2)
#define ESP_EVENT_ANY_ID -1
#define WIFI_EVENT_STA_STOP 1
#define WIFI_EVENT_STA_DISCONNECTED 2
#define WIFI_EVENT_SCAN_DONE 3
#define IP_EVENT_STA_GOT_IP 4
typedef struct { uint16_t reason; } wifi_event_sta_disconnected_t;
typedef struct { uint32_t status; } wifi_event_sta_scan_done_t;
esp_err_t esp_event_handler_instance_register(esp_event_base_t base, int32_t id,
    void (*handler)(void *, esp_event_base_t, int32_t, void *), void *arg, void *instance);

typedef struct { int dummy; } esp_netif_t;
typedef struct { int dummy; } esp_netif_config_t;
typedef struct { uint32_t addr; } fake_ip_t;
typedef struct { fake_ip_t ip; } esp_netif_ip_info_t;
typedef struct { esp_netif_t *esp_netif; esp_netif_ip_info_t ip_info; } ip_event_got_ip_t;
#define ESP_NETIF_DEFAULT_WIFI_STA() { 0 }
#define IPSTR "%u.%u.%u.%u"
#define IP2STR(ip) 10u, 0u, 0u, (unsigned)((ip)->addr)
esp_netif_t *esp_netif_new(const esp_netif_config_t *config);
esp_err_t esp_netif_attach_wifi_station(esp_netif_t *netif);
esp_err_t esp_wifi_set_default_wifi_sta_handlers(void);
esp_err_t esp_netif_get_ip_info(esp_netif_t *netif, esp_netif_ip_info_t *ip);

typedef struct {
    int nvs_enable, static_rx_buf_num, dynamic_rx_buf_num, tx_buf_type;
    int static_tx_buf_num, dynamic_tx_buf_num, cache_tx_buf_num;
    uint64_t feature_caps;
    int rx_mgmt_buf_type, rx_mgmt_buf_num, mgmt_sbuf_num;
    int ampdu_rx_enable, ampdu_tx_enable, amsdu_tx_enable, rx_ba_win;
} wifi_init_config_t;
#define CONFIG_FEATURE_CACHE_TX_BUF_BIT (1u << 1)
#define WIFI_INIT_CONFIG_DEFAULT() { 0 }
#define WIFI_STORAGE_RAM 1
#define WIFI_MODE_STA 1
#define WIFI_IF_STA 1
#define WIFI_AUTH_OPEN 0
typedef struct { unsigned char ssid[32]; int rssi; int authmode; } wifi_ap_record_t;
typedef struct { struct { unsigned char ssid[32]; unsigned char password[64]; } sta; } wifi_config_t;
esp_err_t esp_wifi_init(const wifi_init_config_t *config);
esp_err_t esp_wifi_set_storage(int storage);
esp_err_t esp_wifi_set_mode(int mode);
esp_err_t esp_wifi_start(void);
esp_err_t esp_wifi_stop(void);
esp_err_t esp_wifi_connect(void);
esp_err_t esp_wifi_set_config(int interface, const wifi_config_t *config);
esp_err_t esp_wifi_scan_start(const void *config, bool block);
esp_err_t esp_wifi_scan_stop(void);
esp_err_t esp_wifi_scan_get_ap_num(uint16_t *total);
esp_err_t esp_wifi_scan_get_ap_record(wifi_ap_record_t *record);
esp_err_t esp_wifi_clear_ap_list(void);
esp_err_t esp_wifi_sta_get_ap_info(wifi_ap_record_t *record);
