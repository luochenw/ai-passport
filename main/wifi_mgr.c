// main/wifi_mgr.c —— 见 wifi_mgr.h 顶部的说明,尤其是"永远不 deinit"那一条。
#include "wifi_mgr.h"
#include "device_config.h"
#include "demo_radio.h"

#include "esp_event.h"
#include "esp_log.h"
#include "esp_netif.h"
#include "esp_wifi.h"
#include "esp_wifi_default.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"

#include <string.h>

static const char *TAG = "wifi_mgr";

// 连接失败前重试几次。ESP-IDF 不会自己重连,断了就得自己再 connect 一次。
// 3 次之后认输并报 FAILED —— 无限重试会让"密码打错了"这件事永远表现为
// "一直在连接中",用户无从判断。
#define WIFI_MGR_MAX_RETRY 3

// ---- 生命周期标志位 --------------------------------------------------------
//
// ⚠ 每一步都有自己的标志位,不能合并成一个 s_inited。
//
// 合并过一次,失败了:esp_wifi_init() 在 BLE 常驻的情况下**确实会因为内存不够
// 而失败**。用一个总标志的话,失败时它没被置上,函数返回 false;下次再进来
// 从头再走一遍 —— 而 esp_netif_create_default_wifi_sta() 上一次已经成功了,
// 这一次就撞上重复的 if_key,直接 assert 重启。
//
// 所以:做成了哪一步就记哪一步,重入时从断掉的那一步继续。
static bool s_netif_created;
static bool s_drv_inited;
static bool s_handlers_registered;
static bool s_started;

static esp_netif_t *s_netif;
static wifi_mgr_watch_fn s_on_change;

static wifi_mgr_state_t s_state = WIFI_MGR_OFF;
static int  s_retry;
static char s_ssid[WIFI_MGR_SSID_LEN];
static char s_ip[16];

static wifi_mgr_ap_t s_scan[WIFI_MGR_MAX_SCAN];
static int  s_scan_count;
static bool s_scanning;

// 用户主动断开时置上。用来区分"我自己断的"和"掉线了":前者不该自动重连,
// 后者应该。少了这个标志的话,在 app 上点"断开"会立刻被重连逻辑拉回来,
// 表现为按钮点了没反应。
static bool s_user_disconnected;

static void notify(void)
{
    if (s_on_change) s_on_change();
}

static void set_state(wifi_mgr_state_t st)
{
    if (s_state == st) return;
    s_state = st;
    notify();
}

// ---- 事件 ------------------------------------------------------------------

static void on_wifi_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)base;

    switch (id) {
    case WIFI_EVENT_STA_START:
        // start 之后才允许 connect。走到这里说明是"起来了但还没连"。
        if (s_state == WIFI_MGR_CONNECTING) esp_wifi_connect();
        break;

    case WIFI_EVENT_STA_DISCONNECTED: {
        s_ip[0] = '\0';
        if (s_user_disconnected) {
            set_state(WIFI_MGR_IDLE);
            break;
        }
        if (s_retry < WIFI_MGR_MAX_RETRY) {
            s_retry++;
            ESP_LOGW(TAG, "断开,重试第 %d 次", s_retry);
            esp_wifi_connect();
            set_state(WIFI_MGR_CONNECTING);
        } else {
            const wifi_event_sta_disconnected_t *e = data;
            ESP_LOGW(TAG, "连接失败,reason=%d", e ? e->reason : -1);
            set_state(WIFI_MGR_FAILED);
        }
        break;
    }

    case WIFI_EVENT_SCAN_DONE: {
        uint16_t num = WIFI_MGR_MAX_SCAN;
        static wifi_ap_record_t records[WIFI_MGR_MAX_SCAN];
        s_scan_count = 0;
        if (esp_wifi_scan_get_ap_records(&num, records) == ESP_OK) {
            for (int i = 0; i < (int)num && i < WIFI_MGR_MAX_SCAN; i++) {
                // SSID 可能不是以 '\0' 结尾的满 32 字节,snprintf 用 %.*s 限长,
                // 直接 strncpy 会读过界。
                snprintf(s_scan[s_scan_count].ssid, WIFI_MGR_SSID_LEN,
                         "%.32s", (const char *)records[i].ssid);
                // 隐藏 SSID 的 AP 扫出来名字是空的,列出来用户也点不了。
                if (s_scan[s_scan_count].ssid[0] == '\0') continue;
                s_scan[s_scan_count].rssi = records[i].rssi;
                s_scan[s_scan_count].secure = records[i].authmode != WIFI_AUTH_OPEN;
                s_scan_count++;
            }
        }
        s_scanning = false;
        ESP_LOGI(TAG, "扫描完成,%d 个可用网络", s_scan_count);
        notify();
        break;
    }

    default:
        break;
    }
}

static void on_ip_event(void *arg, esp_event_base_t base, int32_t id, void *data)
{
    (void)arg; (void)base;
    if (id != IP_EVENT_STA_GOT_IP) return;
    const ip_event_got_ip_t *e = data;
    snprintf(s_ip, sizeof(s_ip), IPSTR, IP2STR(&e->ip_info.ip));
    s_retry = 0;
    ESP_LOGI(TAG, "已连接 %s,IP %s", s_ssid, s_ip);
    set_state(WIFI_MGR_CONNECTED);
}

// ---- 惰性拉起 --------------------------------------------------------------
//
// 分步、每步幂等。任何一步失败都**保留已经做成的那几步的标志位**,
// 下次重入从断点继续,绝不重做已经成功的步骤。
static bool bring_up(void)
{
    if (s_started) return true;

    // netif 和默认事件循环是**全机共享**的底座(NimBLE 那边也要),归 demo_radio
    // 一处管,它自己是幂等的。这里不重复造一份 —— 两个模块各自守一份"初始化
    // 过了没"的标志,正是这个文件顶部那段事故的成因。
    esp_err_t err = demo_radio_network_prepare();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "网络底座准备失败: %s", esp_err_to_name(err));
        return false;
    }

    if (!s_netif_created) {
        // ⚠ 这一句撞上重复的 if_key 是 **assert 重启**,不是返回错误。
        // 所以标志位必须紧挨着成功之后置上,中间不能插任何可能失败并提前
        // return 的逻辑。
        s_netif = esp_netif_create_default_wifi_sta();
        if (!s_netif) {
            ESP_LOGE(TAG, "创建 STA netif 失败");
            return false;
        }
        s_netif_created = true;
    }

    if (!s_drv_inited) {
        wifi_init_config_t cfg = WIFI_INIT_CONFIG_DEFAULT();
        err = esp_wifi_init(&cfg);
        if (err != ESP_OK) {
            // BLE 常驻已经占了不少内存,这一步是真的会失败的。失败就失败,
            // 但上面那个 netif 已经建好了,标志位留着 —— 下次重入不会再建
            // 一遍(那才是会重启的那条路)。
            ESP_LOGE(TAG, "esp_wifi_init 失败: %s(内存不足?BLE 常驻会占用较多)",
                     esp_err_to_name(err));
            return false;
        }
        s_drv_inited = true;
    }

    if (!s_handlers_registered) {
        err = esp_event_handler_instance_register(WIFI_EVENT, ESP_EVENT_ANY_ID,
                                                  on_wifi_event, NULL, NULL);
        if (err == ESP_OK) {
            err = esp_event_handler_instance_register(IP_EVENT, IP_EVENT_STA_GOT_IP,
                                                      on_ip_event, NULL, NULL);
        }
        if (err != ESP_OK) {
            ESP_LOGE(TAG, "注册事件回调失败: %s", esp_err_to_name(err));
            return false;
        }
        s_handlers_registered = true;
    }

    // 凭据只存在 NVS(device_config)里,不需要 Wi-Fi 驱动再存一份 —— 存两份
    // 就会有"哪份是真的"的问题。
    esp_wifi_set_storage(WIFI_STORAGE_RAM);
    if (esp_wifi_set_mode(WIFI_MODE_STA) != ESP_OK) return false;

    err = esp_wifi_start();
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_wifi_start 失败: %s", esp_err_to_name(err));
        return false;
    }
    s_started = true;
    set_state(WIFI_MGR_IDLE);
    ESP_LOGI(TAG, "Wi-Fi 协议栈已拉起");
    return true;
}

// ---- 对外 ------------------------------------------------------------------

void wifi_mgr_init(wifi_mgr_watch_fn on_change)
{
    s_on_change = on_change;
    // 刻意不拉起协议栈:新架构下跑应用不需要 Wi-Fi,开机就起等于白白吃掉
    // 十几 KB 内存和一份射频功耗。用户真要用的时候再起。
}

wifi_mgr_state_t wifi_mgr_state(void)   { return s_state; }
bool wifi_mgr_is_connected(void)        { return s_state == WIFI_MGR_CONNECTED; }
const char *wifi_mgr_ssid(void)         { return s_ssid; }
const char *wifi_mgr_ip(void)           { return s_ip; }
int wifi_mgr_scan_count(void)           { return s_scan_count; }
bool wifi_mgr_scan_busy(void)           { return s_scanning; }

int wifi_mgr_rssi(void)
{
    if (s_state != WIFI_MGR_CONNECTED) return 0;
    wifi_ap_record_t ap;
    if (esp_wifi_sta_get_ap_info(&ap) != ESP_OK) return 0;
    return ap.rssi;
}

bool wifi_mgr_scan_entry(int index, wifi_mgr_ap_t *out)
{
    if (index < 0 || index >= s_scan_count) return false;
    if (out) *out = s_scan[index];
    return true;
}

bool wifi_mgr_connect(const char *ssid, const char *password)
{
    if (!ssid || !*ssid) ssid = device_config_wifi_ssid();
    if (!password)       password = device_config_wifi_password();
    if (!ssid || !*ssid) {
        ESP_LOGW(TAG, "没有 SSID,不发起连接");
        return false;
    }
    if (!bring_up()) return false;

    // 扫描和连接不能同时进行,先把扫描停掉。不停的话 esp_wifi_connect()
    // 会返回 ESP_ERR_WIFI_STATE,而那个错误码传上去只会显示"连接失败",
    // 用户完全猜不到是因为刚点过扫描。
    if (s_scanning) {
        esp_wifi_scan_stop();
        s_scanning = false;
    }

    snprintf(s_ssid, sizeof(s_ssid), "%s", ssid);

    wifi_config_t wc = { 0 };
    snprintf((char *)wc.sta.ssid, sizeof(wc.sta.ssid), "%s", ssid);
    snprintf((char *)wc.sta.password, sizeof(wc.sta.password), "%s", password ? password : "");
    if (esp_wifi_set_config(WIFI_IF_STA, &wc) != ESP_OK) return false;

    s_retry = 0;
    s_user_disconnected = false;
    s_ip[0] = '\0';
    set_state(WIFI_MGR_CONNECTING);

    esp_err_t err = esp_wifi_connect();
    if (err != ESP_OK && err != ESP_ERR_WIFI_CONN) {
        ESP_LOGE(TAG, "esp_wifi_connect 失败: %s", esp_err_to_name(err));
        set_state(WIFI_MGR_FAILED);
        return false;
    }
    // 不打印密码 —— 串口日志会被贴进 issue 里。
    ESP_LOGI(TAG, "正在连接 %s", ssid);
    return true;
}

void wifi_mgr_disconnect(void)
{
    if (!s_started) return;
    // 先置标志再断开:WIFI_EVENT_STA_DISCONNECTED 会立刻在事件任务里触发,
    // 顺序反了的话那边会当成"意外掉线"而自动重连,把用户刚点的断开又连回去。
    s_user_disconnected = true;
    s_retry = WIFI_MGR_MAX_RETRY;
    esp_wifi_disconnect();
    s_ip[0] = '\0';
    set_state(WIFI_MGR_IDLE);
    ESP_LOGI(TAG, "已按用户要求断开");
}

bool wifi_mgr_scan_start(void)
{
    if (!bring_up()) return false;
    if (s_scanning) return true;   // 已经在扫了,不重复发起

    s_scan_count = 0;
    // false = 非阻塞,结果由 WIFI_EVENT_SCAN_DONE 送来。阻塞版会在这里卡
    // 好几秒,而这个函数是被 BLE 回调链调到的。
    esp_err_t err = esp_wifi_scan_start(NULL, false);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "发起扫描失败: %s", esp_err_to_name(err));
        return false;
    }
    s_scanning = true;
    notify();
    return true;
}
