// main/device_config.c —— 见 device_config.h 顶部的说明。
//
// 配置下发的 GATT 约定
// ────────────────────
// 一个 service,一个 WRITE + WRITE_NO_RSP 特征值,收的是文本行:
//
//     <key>=<value>\n
//
// 一次写入可以包含多行。key/value 都是 UTF-8。
//
// value 允许为空,含义是"这个键的值就是空",**不是删除**。这个区分是必要的:
// 读取方普遍写成 device_config_get(key, 默认值),空值如果删键,"用户明确
// 选了空"就退化成"没配过",读回来是默认值 —— 状态栏四项全不勾之后又全都
// 回来了,就是这么来的。
// 之所以用纯文本而不是二进制 TLV:配置是低频、小体积、字段会一直增加的东西,
// 文本让"加一个字段"不需要两端同时改协议版本号,调试时也能直接看懂。固件
// 传输那种高频大流量的场景才值得上二进制协议。
//
// 收到并写入 NVS 后,revision 计数 +1,应用据此知道该重新读配置了。
#include "device_config.h"
#include "ble_hub.h"

#include "esp_app_desc.h"
#include "esp_log.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "nvs.h"
#include "nvs_flash.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <stdatomic.h>

static const char *TAG = "device_config";
static const char *NVS_NAMESPACE = "devcfg";

// 配置服务 UUID(跟 Codex、应用商店那两套都不同):
//   Service: 9A4C1E20-7F5B-4A3D-8C61-1E9D4B7A2F30
//   WRITE:   9A4C1E21-7F5B-4A3D-8C61-1E9D4B7A2F30
// ⚠ NimBLE 的 BLE_UUID128_INIT 按小端存,跟 CoreBluetooth 的字符串顺序相反,
// 所以这里是把标准写法的 16 字节整体倒过来。
static const ble_uuid128_t s_svc_uuid =
    BLE_UUID128_INIT(0x30, 0x2F, 0x7A, 0x4B, 0x9D, 0x1E, 0x61, 0x8C,
                     0x3D, 0x4A, 0x5B, 0x7F, 0x20, 0x1E, 0x4C, 0x9A);
static const ble_uuid128_t s_write_uuid =
    BLE_UUID128_INIT(0x30, 0x2F, 0x7A, 0x4B, 0x9D, 0x1E, 0x61, 0x8C,
                     0x3D, 0x4A, 0x5B, 0x7F, 0x21, 0x1E, 0x4C, 0x9A);
// STATUS(NOTIFY,设备 -> 对端): 9A4C1E22-7F5B-4A3D-8C61-1E9D4B7A2F30
static const ble_uuid128_t s_status_uuid =
    BLE_UUID128_INIT(0x30, 0x2F, 0x7A, 0x4B, 0x9D, 0x1E, 0x61, 0x8C,
                     0x3D, 0x4A, 0x5B, 0x7F, 0x22, 0x1E, 0x4C, 0x9A);

static nvs_handle_t s_nvs;
static bool         s_nvs_open;
static uint32_t     s_revision;

// 热点字段做内存缓存:Wi-Fi 凭据在连接流程里会被反复读到,每次都开 NVS 读
// 一遍既慢又没必要。其余字段走 device_config_get() 直接读 NVS。
static char s_ssid[DEVICE_CONFIG_STR_MAX];
static char s_password[DEVICE_CONFIG_STR_MAX];
static int  s_volume = 60;
static int  s_brightness = 100;
static bool s_boot_chime_enabled;
static int s_boot_chime_volume = 20;
static portMUX_TYPE s_wifi_mux = portMUX_INITIALIZER_UNLOCKED;
typedef struct {
    char key[32];
    char value[DEVICE_CONFIG_STR_MAX];
} config_request_t;
static QueueHandle_t s_requests;
static uint32_t s_write_failures;
static atomic_bool s_snapshot_pending;
static bool report_settings_snapshot(void);
// device_config_get() 的返回值缓冲区。用一个静态缓冲区而不是每次 malloc,
// 是为了让调用方拿到的是普通 const char* —— 代价是"下一次调用会覆盖上一次
// 的结果",这一点在头文件里已经写明。
static char s_scratch[DEVICE_CONFIG_STR_MAX];
static device_config_cmd_fn s_cmd_handler;
static device_config_status_hook_fn s_status_hook;

static bool save_integer(const char *key, int value, int minimum, int *cached)
{
    if (value < minimum) value = minimum;
    if (value > 100) value = 100;
    if (!s_nvs_open || nvs_set_i32(s_nvs, key, value) != ESP_OK ||
        nvs_commit(s_nvs) != ESP_OK) return false;
    *cached = value;
    s_revision++;
    return true;
}

static void load_cached(void)
{
    if (!s_nvs_open) return;
    char ssid[sizeof(s_ssid)] = "";
    char password[sizeof(s_password)] = "";
    size_t len = sizeof(ssid);
    if (nvs_get_str(s_nvs, "wifi.ssid", ssid, &len) != ESP_OK) ssid[0] = '\0';
    len = sizeof(password);
    if (nvs_get_str(s_nvs, "wifi.pass", password, &len) != ESP_OK) password[0] = '\0';
    portENTER_CRITICAL(&s_wifi_mux);
    memcpy(s_ssid, ssid, sizeof(s_ssid));
    memcpy(s_password, password, sizeof(s_password));
    portEXIT_CRITICAL(&s_wifi_mux);
    int32_t v = 60;
    if (nvs_get_i32(s_nvs, "volume", &v) == ESP_OK) s_volume = (int)v;
    int32_t b = 100;
    if (nvs_get_i32(s_nvs, "brightness", &b) == ESP_OK) s_brightness = (int)b;
    if (s_brightness < DEVICE_CONFIG_MIN_BRIGHTNESS) s_brightness = DEVICE_CONFIG_MIN_BRIGHTNESS;
    if (s_brightness > 100) s_brightness = 100;
    if (s_volume < 0) s_volume = 0;
    if (s_volume > 100) s_volume = 100;
    uint8_t chime = 0;
    // NVS keys have a 15-character limit; keep the public protocol descriptive.
    if (nvs_get_u8(s_nvs, "boot_chime", &chime) != ESP_OK) chime = 0;
    s_boot_chime_enabled = chime == 1;
    int32_t chime_volume = 20;
    if (nvs_get_i32(s_nvs, "boot_volume", &chime_volume) != ESP_OK) chime_volume = 20;
    s_boot_chime_volume = chime_volume < 0 ? 0 : chime_volume > 100 ? 100 : chime_volume;
}

void device_config_init(void)
{
    if (!s_requests) s_requests = xQueueCreate(4, sizeof(config_request_t));
    // nvs_flash_init() 可能已经被别的模块调过(BLE 也需要 NVS),重复调用是
    // 安全的,返回 ESP_ERR_NVS_NO_FREE_PAGES 时才需要擦了重来。
    esp_err_t err = nvs_flash_init();
    if (err == ESP_ERR_NVS_NO_FREE_PAGES || err == ESP_ERR_NVS_NEW_VERSION_FOUND) {
        ESP_LOGW(TAG, "NVS 需要重新初始化: %s", esp_err_to_name(err));
        nvs_flash_erase();
        err = nvs_flash_init();
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "NVS 初始化失败: %s,配置功能不可用", esp_err_to_name(err));
        return;
    }
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &s_nvs) != ESP_OK) {
        ESP_LOGE(TAG, "打开 NVS 命名空间失败,配置功能不可用");
        return;
    }
    s_nvs_open = true;
    load_cached();
    ESP_LOGI(TAG, "配置就绪(Wi-Fi %s,音量 %d)",
             s_ssid[0] ? "已配置" : "未配置", s_volume);
}

const char *device_config_wifi_ssid(void)     { return s_ssid; }
const char *device_config_wifi_password(void) { return s_password; }
bool        device_config_has_wifi(void)      { return s_ssid[0] != '\0'; }
int         device_config_volume(void)        { return s_volume; }
int         device_config_brightness(void)    { return s_brightness; }
bool        device_config_boot_chime_enabled(void) { return s_boot_chime_enabled; }
int         device_config_boot_chime_volume(void) { return s_boot_chime_volume; }
uint32_t    device_config_revision(void)      { return s_revision; }
uint32_t    device_config_write_failures(void) { return s_write_failures; }

void device_config_wifi_copy(char *ssid, size_t ssid_size,
                             char *password, size_t password_size)
{
    portENTER_CRITICAL(&s_wifi_mux);
    if (ssid && ssid_size) strlcpy(ssid, s_ssid, ssid_size);
    if (password && password_size) strlcpy(password, s_password, password_size);
    portEXIT_CRITICAL(&s_wifi_mux);
}

bool device_config_request_set(const char *key, const char *value)
{
    if (!s_requests || !key || !value) return false;
    config_request_t request = {0};
    if (strlen(key) >= sizeof(request.key) || strlen(value) >= sizeof(request.value)) return false;
    strlcpy(request.key, key, sizeof(request.key));
    strlcpy(request.value, value, sizeof(request.value));
    return xQueueSend(s_requests, &request, 0) == pdTRUE;
}

void device_config_process_pending(void)
{
    config_request_t request;
    while (s_requests && xQueueReceive(s_requests, &request, 0) == pdTRUE) {
        if (!device_config_set(request.key, request.value)) s_write_failures++;
    }
    if (device_config_status_ready() && atomic_exchange(&s_snapshot_pending, false) &&
        !report_settings_snapshot()) atomic_store(&s_snapshot_pending, true);
}

void device_config_request_snapshot(void) { atomic_store(&s_snapshot_pending, true); }

const char *device_config_get(const char *key, const char *fallback)
{
    if (!s_nvs_open || !key) return fallback;
    size_t len = sizeof(s_scratch);
    if (nvs_get_str(s_nvs, key, s_scratch, &len) != ESP_OK) return fallback;
    return s_scratch;
}

void device_config_set_cmd_handler(device_config_cmd_fn fn)
{
    s_cmd_handler = fn;
}

void device_config_set_status_hook(device_config_status_hook_fn fn)
{
    s_status_hook = fn;
}

bool device_config_set(const char *key, const char *value)
{
    if (!key) return false;

    // cmd.* 是动作不是配置,不落盘 —— 见头文件里的说明。这一条要放在
    // s_nvs_open 检查**之前**:NVS 打不开的时候配置功能确实废了,但"断开蓝牙"
    // 这种命令跟 NVS 一点关系都没有,没道理跟着一起失效。
    if (strncmp(key, "cmd.", 4) == 0) {
        if (s_cmd_handler) {
            s_cmd_handler(key + 4, value ? value : "");
        } else {
            ESP_LOGW(TAG, "收到命令 %s 但没有处理器", key);
        }
        return true;
    }

    if (!s_nvs_open) return false;

    if (strcmp(key, "boot_chime.volume") == 0) {
        if (!value || !value[0]) return false;
        char *end;
        long volume = strtol(value, &end, 10);
        if (*end || volume < 0 || volume > 100) return false;
        return save_integer("boot_volume", (int)volume, 0, &s_boot_chime_volume);
    }

    if (strcmp(key, "boot_chime.enabled") == 0) {
        if (!value || (strcmp(value, "0") != 0 && strcmp(value, "1") != 0)) return false;
        bool enabled = value[0] == '1';
        if (nvs_set_u8(s_nvs, "boot_chime", enabled ? 1 : 0) != ESP_OK ||
            nvs_commit(s_nvs) != ESP_OK) return false;
        s_boot_chime_enabled = enabled;
        s_revision++;
        return true;
    }

    // volume 在 NVS 里是 i32,不是字符串 —— 配置通道是纯文本的,如果照直
    // 当字符串存下去,写进去的是 "75" 而读的时候 nvs_get_i32 找不到这个
    // 类型的键,于是永远读回旧值。实测过一次:下发 volume=75、重启,设备
    // 报告的还是 60,而且没有任何报错。这里转成整数走同一条写入路径,
    // 保证"怎么写的"和"怎么读的"只有一份真相。
    if (strcmp(key, "volume") == 0) {
        if (!value || value[0] == '\0') return false;
        return save_integer(key, atoi(value), 0, &s_volume);
    }
    // 亮度同理:存的是 i32,照字符串写进去 nvs_get_i32 读不到这个类型的键,
    // 于是"下发了但没反应",而且不报错不打日志。
    if (strcmp(key, "brightness") == 0) {
        if (!value || value[0] == '\0') return false;
        return save_integer(key, atoi(value), DEVICE_CONFIG_MIN_BRIGHTNESS, &s_brightness);
    }

    if (strcmp(key, "wifi.ssid") == 0 || strcmp(key, "wifi.pass") == 0) {
        size_t maximum = strcmp(key, "wifi.ssid") == 0 ? 32 : 64;
        if (value && (strlen(value) > maximum || strpbrk(value, "\r\n\t"))) return false;
    }

    // 空值**存成空串**,不删键。
    //
    // ⚠ 这里原来是 nvs_erase_key。看着等价,其实把"用户明确选了空"和"用户
    // 从来没配过"混成了同一种状态 —— 而读取方普遍写成
    // device_config_get(key, 默认值),键不存在就回退到默认值。于是状态栏
    // 四项全不勾、app 下发 sb.items= 之后,设备读回来的是默认的
    // "battery,ble,wifi,time",四项原封不动地回来了,而且没有任何报错。
    //
    // 存空串就能把这两件事分开:键在、值为空 = 明确的空。对其他键也没有
    // 副作用 —— wifi.pass 存空串和键不存在,读出来都是 ""。
    esp_err_t err = nvs_set_str(s_nvs, key, value ? value : "");
    if (err == ESP_OK) err = nvs_commit(s_nvs);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "写配置失败 %s: %s", key, esp_err_to_name(err));
        return false;
    }

    // 热点字段同步刷新内存缓存,避免"写完了但读出来还是旧的"。
    if (strcmp(key, "wifi.ssid") == 0 || strcmp(key, "wifi.pass") == 0) {
        load_cached();
    }
    s_revision++;
    // 不打印 value —— 它可能是 Wi-Fi 密码或接口口令,串口日志会被贴到 issue 里。
    ESP_LOGI(TAG, "配置已更新: %s(revision=%u)", key, (unsigned)s_revision);
    return true;
}

void device_config_set_brightness(int brightness)
{
    // 钳住下限:0 是全灭,而设备上没有任何入口能把它调回来。见头文件说明。
    save_integer("brightness", brightness, DEVICE_CONFIG_MIN_BRIGHTNESS, &s_brightness);
}

void device_config_set_volume(int volume)
{
    save_integer("volume", volume, 0, &s_volume);
}

// ---- BLE 配置下发 -----------------------------------------------------------

#define CONFIG_WRITE_BUF_LEN 512

static uint16_t s_write_chr_val_handle;
static uint16_t s_status_chr_val_handle;
static uint8_t  s_write_buf[CONFIG_WRITE_BUF_LEN];
static bool     s_status_subscribed;

// 解析 "<key>=<value>" 单行并落盘。行内没有 '=' 的直接忽略(不是错误 —— 对端
// 可能发了空行或注释)。
static bool apply_line(char *line)
{
    while (*line == ' ' || *line == '\r') line++;
    if (*line == '\0' || *line == '#') return true;

    char *eq = strchr(line, '=');
    if (!eq) {
        ESP_LOGW(TAG, "配置行缺少 '=',忽略");
        return false;
    }
    *eq = '\0';
    char *key = line;
    char *value = eq + 1;

    // 去掉 value 末尾的 \r(对端可能用 CRLF)
    size_t vlen = strlen(value);
    while (vlen > 0 && (value[vlen-1] == '\r' || value[vlen-1] == '\n')) {
        value[--vlen] = '\0';
    }
    if (strlen(key) == 0) return false;

    return device_config_set(key, value);
}

static int config_write_cb(uint16_t conn_handle, uint16_t attr_handle,
                           struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr_handle;
    (void)arg;

    if (!ble_hub_is_authorized_conn(conn_handle)) return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_UNLIKELY;

    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len == 0) return 0;
    if (len >= sizeof(s_write_buf)) return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    if (ble_hs_mbuf_to_flat(ctxt->om, s_write_buf, len, NULL) != 0) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    s_write_buf[len] = '\0';

    // 一次写入可以带多行,逐行处理。
    char *cursor = (char *)s_write_buf;
    while (cursor && *cursor) {
        char *nl = strchr(cursor, '\n');
        if (nl) *nl = '\0';
        if (!apply_line(cursor)) return BLE_ATT_ERR_UNLIKELY;
        cursor = nl ? nl + 1 : NULL;
    }
    return 0;
}

// STATUS 只用于设备 -> 对端的 notify,不需要被读写,但 NimBLE 要求非空
// access_cb。
static int status_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                            struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle; (void)attr_handle; (void)ctxt; (void)arg;
    return BLE_ATT_ERR_UNLIKELY;
}

bool device_config_status_ready(void)
{
    return s_status_subscribed && ble_hub_is_connected();
}

bool device_config_report(const char *lines)
{
    if (!lines || !lines[0] || !device_config_status_ready()) return false;

    // 一次 notify 装不下就分片发。对端跟设备侧解析下发方向时一样,靠结尾的
    // 换行判断这一批收齐了 —— 所以绝不能在行中间切断,只在换行处切。
    size_t total = strlen(lines);
    size_t sent = 0;
    while (sent < total) {
        size_t chunk = total - sent;
        if (chunk > 180) {                       // 保守值,远小于协商 MTU
            chunk = 180;
            // 回退到这一段里最后一个换行,保证每次发出去的都是整行。
            size_t back = chunk;
            while (back > 0 && lines[sent + back - 1] != '\n') back--;
            if (back > 0) chunk = back;          // 找不到换行就只能硬切
        }
        int rc = ble_hub_notify(s_status_chr_val_handle, lines + sent, (int)chunk);
        if (rc != 0) {
            // rc=6 是 BLE_HS_ENOMEM:mbuf 池满了。这不是永久错误,调用方
            // 等一会儿重试就好 —— 所以这里只打 debug,不再刷 warning。
            ESP_LOGD(TAG, "状态上报未发出: rc=%d", rc);
            return false;
        }
        sent += chunk;
    }
    return true;
}

void device_config_report_kv(const char *key, const char *value)
{
    if (!key) return;
    char line[DEVICE_CONFIG_STR_MAX * 2];
    snprintf(line, sizeof(line), "%s=%s\n", key, value ? value : "");
    device_config_report(line);
}

static bool report_settings_snapshot(void)
{
    const esp_app_desc_t *app = esp_app_get_description();
    char items[DEVICE_CONFIG_STR_MAX] = "battery,ble,wifi,time";
    size_t length = sizeof(items);
    if (s_nvs_open) nvs_get_str(s_nvs, "sb.items", items, &length);
    char snapshot[320];
    snprintf(snapshot, sizeof(snapshot),
             "firmware.version=%s\nvolume=%d\nbrightness=%d\nboot_chime.enabled=%d\nboot_chime.volume=%d\nsb.items=%s\n",
             app ? app->version : "unknown", s_volume, s_brightness,
             s_boot_chime_enabled ? 1 : 0, s_boot_chime_volume, items);
    return device_config_report(snapshot);
}

static void on_ble_subscribe(uint16_t attr_handle, bool subscribed)
{
    if (attr_handle != s_status_chr_val_handle) return;
    s_status_subscribed = subscribed;
    if (subscribed) {
        // 对端刚订阅上,先把当前状态推一遍 —— 否则它要等到下一次状态变化
        // 才知道设备是什么样子,界面上会空一段时间。
        device_config_request_snapshot();
        // 剩下的状态(Wi-Fi 之类)配置层不知道,交给上面注册的钩子补。
        if (s_status_hook) s_status_hook();
    }
}

static void on_ble_disconnect(void)
{
    s_status_subscribed = false;
}

static const ble_hub_observer_t s_observer = {
    .on_subscribe = on_ble_subscribe,
    .on_disconnect = on_ble_disconnect,
};

static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &s_write_uuid.u,
                .access_cb = config_write_cb,
                // 同时声明两种写:配置量小,两种都支持不增加复杂度,而漏掉
                // WRITE_NO_RSP 会让对端的 without-response 写入被
                // CoreBluetooth 静默丢弃(这个坑在固件传输上踩过一次)。
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
                .val_handle = &s_write_chr_val_handle,
            },
            {
                .uuid = &s_status_uuid.u,
                .access_cb = status_access_cb,
                .flags = BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_status_chr_val_handle,
            },
            { 0 },
        },
    },
    { 0 },
};

void device_config_ble_register(void)
{
    ble_hub_register_service(s_gatt_svcs);
    ble_hub_register_observer(&s_observer);
}
