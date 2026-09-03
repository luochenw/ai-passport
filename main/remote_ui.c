// main/remote_ui.c —— 见 remote_ui.h 顶部对这套架构的说明。
//
// 这一层只做三件事:收屏幕描述、解析成结构体、把按键回传给对端。它不认识
// 任何具体应用 —— "服务器面板""待办列表"这些概念只存在于对端。
#include "remote_ui.h"
#include "ui_notify.h"
#include "ble_hub.h"

#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "nvs.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *TAG = "remote_ui";

// 远程界面专用 UUID(跟 Codex、应用商店、配置那三套都不同):
//   Service:   5D8E3C40-9A72-4B15-8E63-7C4F1A2D9B80
//   SCREEN 特征(WRITE + WRITE_NO_RSP,对端 -> 设备): ...41
//   EVENT  特征(INDICATE,设备 -> 对端):            ...42
// ⚠ NimBLE 按小端存,跟 CoreBluetooth 的字符串顺序相反,这里是整体倒过来写。
static const ble_uuid128_t s_svc_uuid =
    BLE_UUID128_INIT(0x80, 0x9B, 0x2D, 0x1A, 0x4F, 0x7C, 0x63, 0x8E,
                     0x15, 0x4B, 0x72, 0x9A, 0x40, 0x3C, 0x8E, 0x5D);
static const ble_uuid128_t s_screen_uuid =
    BLE_UUID128_INIT(0x80, 0x9B, 0x2D, 0x1A, 0x4F, 0x7C, 0x63, 0x8E,
                     0x15, 0x4B, 0x72, 0x9A, 0x41, 0x3C, 0x8E, 0x5D);
static const ble_uuid128_t s_event_uuid =
    BLE_UUID128_INIT(0x80, 0x9B, 0x2D, 0x1A, 0x4F, 0x7C, 0x63, 0x8E,
                     0x15, 0x4B, 0x72, 0x9A, 0x42, 0x3C, 0x8E, 0x5D);
// MANIFEST 特征(WRITE + WRITE_NO_RSP,对端 -> 设备): ...43
// 已安装应用清单,一行一个名字。
static const ble_uuid128_t s_manifest_uuid =
    BLE_UUID128_INIT(0x80, 0x9B, 0x2D, 0x1A, 0x4F, 0x7C, 0x63, 0x8E,
                     0x15, 0x4B, 0x72, 0x9A, 0x43, 0x3C, 0x8E, 0x5D);

// 设备 -> 对端的事件号
#define REMOTE_EVT_KEY     0   // param_a = btn, param_b = ev
#define REMOTE_EVT_ACTIVE  1   // param_a = 1 进入远程界面 / 0 离开
#define REMOTE_EVT_HELLO   2   // 订阅完成,对端可以开始推屏幕了
#define REMOTE_EVT_OPEN    3   // 用户在首屏选了某个应用,param_a = 下标

// 一屏内容的上限。对端一次写入可能被 ATT 层拆成多个包,所以要在这里攒齐 ——
// 攒的依据是结尾的换行:协议规定每个元素独占一行,对端发完一屏必然以 '\n'
// 结束,收到它就说明这一屏完整了。
#define REMOTE_RX_BUF_LEN 1024

static uint16_t s_screen_chr_handle;
static uint16_t s_event_chr_handle;
static uint16_t s_manifest_chr_handle;

// ---- 已安装应用清单 --------------------------------------------------------
#define MANIFEST_RX_BUF_LEN 512
static char     s_mrx[MANIFEST_RX_BUF_LEN];
static int      s_mrx_len;
static char     s_apps[REMOTE_UI_MAX_APPS][REMOTE_UI_APP_LEN];
static char     s_icons[REMOTE_UI_MAX_APPS][REMOTE_UI_ICON_LEN];
static int      s_app_count;

static void utf8_copy(char *dst, size_t dst_size, const char *src);

// 把清单里的一行拆成图标和名字。格式是 "<图标>\t<名字>",没有制表符的话
// 整行就是名字、图标为空(兼容旧版配套 app 推过来的清单)。
static void split_manifest_line(const char *line, char *icon, char *name)
{
    const char *tab = strchr(line, '\t');
    if (tab) {
        size_t n = (size_t)(tab - line);
        if (n >= REMOTE_UI_ICON_LEN) n = REMOTE_UI_ICON_LEN - 1;
        memcpy(icon, line, n);
        icon[n] = '\0';
        utf8_copy(name, REMOTE_UI_APP_LEN, tab + 1);
    } else {
        icon[0] = '\0';
        utf8_copy(name, REMOTE_UI_APP_LEN, line);
    }
}
static uint32_t s_manifest_rev;
static nvs_handle_t s_launcher_nvs;
static bool     s_launcher_nvs_open;

static char     s_rx[REMOTE_RX_BUF_LEN];
static int      s_rx_len;

static remote_screen_t   s_screen;
static uint32_t          s_revision;
static SemaphoreHandle_t s_lock;
static volatile bool     s_active;
static volatile uint8_t  s_open_index;

static void send_event(uint8_t evt, uint8_t a, uint8_t b)
{
    uint8_t payload[3] = { evt, a, b };
    int rc = ble_hub_indicate(s_event_chr_handle, payload, sizeof(payload));
    if (rc != 0 && rc != BLE_HS_ENOTCONN) {
        ESP_LOGW(TAG, "回传事件失败: evt=%d rc=%d", evt, rc);
    }
}

void remote_ui_send_key(bsp_btn_t btn, bsp_btn_ev_t ev)
{
    send_event(REMOTE_EVT_KEY, (uint8_t)btn, (uint8_t)ev);
}

void remote_ui_set_active(bool active)
{
    s_active = active;
    send_event(REMOTE_EVT_ACTIVE, active ? 1 : 0, 0);
}

// 安全截断拷贝:绝不在多字节 UTF-8 字符中间切断。
//
// 屏幕上的每一行、标题、应用名都是对端(或用户)给的文本,长度不受这边控制。
// 裸 snprintf 按**字节**截断,一个中文字占 3 字节,正好被切在中间时屏幕上
// 显示的是乱码方块 —— 而编译器的 -Wformat-truncation 只提醒"可能截断",
// 完全不会提示截断会出乱码。
//
// ⚠ 凡是把外来文本拷进定长缓冲的地方都要走这里,不要图省事用 snprintf。
static void utf8_copy(char *dst, size_t dst_size, const char *src)
{
    if (dst_size == 0) return;
    size_t n = strlen(src);
    if (n > dst_size - 1) n = dst_size - 1;
    // 退到一个字符边界上:UTF-8 续字节的高两位是 10。
    while (n > 0 && ((unsigned char)src[n] & 0xC0) == 0x80) n--;
    memcpy(dst, src, n);
    dst[n] = '\0';
}

// 解析一行,填进 dst。返回 false 表示这行不认识(直接忽略,不是错误 ——
// 见头文件里关于前向兼容的说明)。
static bool parse_line(char *line, remote_screen_t *dst)
{
    if (line[0] == '\0') return false;
    char tag = line[0];
    char *body = line + 1;

    // 去掉行尾的 \r(对端可能用 CRLF)
    size_t n = strlen(body);
    while (n > 0 && (body[n-1] == '\r' || body[n-1] == '\n')) body[--n] = '\0';

    switch (tag) {
    case 'T':
        utf8_copy(dst->title, sizeof(dst->title), body);
        return true;
    case 'H':
        utf8_copy(dst->footer, sizeof(dst->footer), body);
        return true;
    case 'L':
        if (dst->row_count >= REMOTE_UI_MAX_ROWS) return false;
        dst->rows[dst->row_count].kind = REMOTE_ROW_TEXT;
        utf8_copy(dst->rows[dst->row_count].text,
                  sizeof(dst->rows[dst->row_count].text), body);
        dst->row_count++;
        return true;
    case 'B': {
        if (dst->row_count >= REMOTE_UI_MAX_ROWS) return false;
        // "B<百分比>|<标签>"
        char *bar = strchr(body, '|');
        int percent = atoi(body);
        if (percent < 0) percent = 0;
        if (percent > 100) percent = 100;
        dst->rows[dst->row_count].kind = REMOTE_ROW_BAR;
        dst->rows[dst->row_count].percent = percent;
        utf8_copy(dst->rows[dst->row_count].text,
                  sizeof(dst->rows[dst->row_count].text), bar ? bar + 1 : "");
        dst->row_count++;
        return true;
    }
    case 'M':
        // 这一屏收不收语音。不是"画什么",而是"启用设备上的哪个能力" ——
        // 麦克风在设备这一侧,对端只能声明意图。
        dst->mic = (body[0] == '1');
        return true;
    case 'W':
        // 实时 PTT 需要 PRESS/RELEASE 的低延迟边沿。跟 M1 的本地录音不同,
        // 是否真的开始采集要等对端服务授予占麦权,所以这里只声明按键模式。
        dst->walkie = (body[0] == '1');
        return true;
    default:
        return false;   // 未知类型:忽略,让老固件不会被新元素弄崩
    }
}

// 把攒齐的一整屏文本解析成结构体并提交。
static void commit_screen(void)
{
    remote_screen_t parsed = { 0 };
    char *cursor = s_rx;
    while (cursor && *cursor) {
        char *nl = strchr(cursor, '\n');
        if (nl) *nl = '\0';
        parse_line(cursor, &parsed);
        cursor = nl ? nl + 1 : NULL;
    }

    xSemaphoreTake(s_lock, portMAX_DELAY);
    s_screen = parsed;
    s_revision++;
    xSemaphoreGive(s_lock);
}

// ---- 应用清单:解析、缓存、读取 --------------------------------------------

// 注:UTF-8 安全截断的 utf8_copy() 已经提到本文件前部 —— parse_line() 里
// 每一行屏幕文本也要用它,原来放在这里只服务应用名是不够的。

static void load_manifest_from_nvs(void)
{
    if (!s_launcher_nvs_open) return;
    char buf[MANIFEST_RX_BUF_LEN];
    size_t len = sizeof(buf);
    if (nvs_get_str(s_launcher_nvs, "apps", buf, &len) != ESP_OK) return;

    s_app_count = 0;
    char *cursor = buf;
    while (cursor && *cursor && s_app_count < REMOTE_UI_MAX_APPS) {
        char *nl = strchr(cursor, '\n');
        if (nl) *nl = '\0';
        if (cursor[0]) {
            split_manifest_line(cursor, s_icons[s_app_count], s_apps[s_app_count]);
            s_app_count++;
        }
        cursor = nl ? nl + 1 : NULL;
    }
    s_manifest_rev++;
    ESP_LOGI(TAG, "从缓存恢复了 %d 个已安装应用", s_app_count);
}

// 把收齐的清单解析出来,内容真的变了才落盘。
static void commit_manifest(void)
{
    // ⚠ 先把原文拷一份:下面的解析会把 '\n' 就地改成 '\0',拿改过的缓冲区
    // 去 nvs_set_str() 只会存进第一行 —— 重启后应用列表凭空少掉一大截,
    // 而且当时看不出是哪一步的问题。
    // static:这个函数跑在 NimBLE host 任务栈上,512 字节的栈帧叠上下面
    // 的 parsed/parsed_icons 已经不算小了。放静态区不会有重入问题 ——
    // 写回调本来就是 host 任务串行调的。
    static char raw[MANIFEST_RX_BUF_LEN];
    snprintf(raw, sizeof(raw), "%s", s_mrx);

    char parsed[REMOTE_UI_MAX_APPS][REMOTE_UI_APP_LEN];
    char parsed_icons[REMOTE_UI_MAX_APPS][REMOTE_UI_ICON_LEN];
    int count = 0;
    char *cursor = s_mrx;
    while (cursor && *cursor && count < REMOTE_UI_MAX_APPS) {
        char *nl = strchr(cursor, '\n');
        if (nl) *nl = '\0';
        // 去掉可能的 \r
        size_t n = strlen(cursor);
        while (n > 0 && cursor[n-1] == '\r') cursor[--n] = '\0';
        if (cursor[0]) {
            split_manifest_line(cursor, parsed_icons[count], parsed[count]);
            count++;
        }
        cursor = nl ? nl + 1 : NULL;
    }

    // 图标变了也算变了 —— 用户在配套 app 上换个图标,设备上得跟着变,
    // 而且要落盘,不然重启又回到旧图标。
    bool changed = (count != s_app_count);
    for (int i = 0; !changed && i < count; i++) {
        if (strcmp(parsed[i], s_apps[i]) != 0 ||
            strcmp(parsed_icons[i], s_icons[i]) != 0) changed = true;
    }

    s_app_count = count;
    for (int i = 0; i < count; i++) {
        utf8_copy(s_apps[i], REMOTE_UI_APP_LEN, parsed[i]);
        snprintf(s_icons[i], REMOTE_UI_ICON_LEN, "%s", parsed_icons[i]);
    }
    s_manifest_rev++;

    // ⚠ 只在内容真的变了才写 flash。电脑每次连上都会推一遍清单,拿
    // "推过来了"当写入条件的话,每天插拔几十次就是几十次 flash 擦写。
    if (changed && s_launcher_nvs_open) {
        if (nvs_set_str(s_launcher_nvs, "apps", raw) == ESP_OK) {
            nvs_commit(s_launcher_nvs);
            ESP_LOGI(TAG, "应用清单已更新并缓存:%d 个", count);
        } else {
            // 原来无论成没成都打"已缓存",写失败时日志会骗人:下次开机
            // 首屏是旧的,而日志信誓旦旦说存过了。
            ESP_LOGW(TAG, "应用清单已更新但写 NVS 失败:%d 个", count);
        }
    }
}

static int manifest_write_cb(uint16_t conn_handle, uint16_t attr_handle,
                             struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle; (void)attr_handle; (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_UNLIKELY;

    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len == 0) return 0;
    if (s_mrx_len + len >= (int)sizeof(s_mrx)) {
        ESP_LOGW(TAG, "清单超长,丢弃");
        s_mrx_len = 0;
        return 0;
    }
    if (ble_hs_mbuf_to_flat(ctxt->om, s_mrx + s_mrx_len, len, NULL) != 0) {
        s_mrx_len = 0;
        return BLE_ATT_ERR_UNLIKELY;
    }
    s_mrx_len += len;
    s_mrx[s_mrx_len] = '\0';

    // ⚠ 哨兵是空行(连着两个换行),不是单个换行。清单是按 ATT 包收的,
    // 一个包的最后一个字节是换行,只说明这一包正好断在行尾,不说明清单
    // 收齐了。用单换行做判据的话,清单一超过单包容量(iOS 的 ATT MTU
    // 只有 185,一份满清单必然拆成几包),设备就会把前半份当完整清单
    // 落盘 —— 而且后半包要是丢了,NVS 里就永久留着这份残缺清单。
    if (s_mrx_len >= 2 && s_mrx[s_mrx_len - 1] == '\n'
                       && s_mrx[s_mrx_len - 2] == '\n') {
        commit_manifest();
        s_mrx_len = 0;
    }
    return 0;
}

int remote_ui_app_count(void) { return s_app_count; }

const char *remote_ui_app_name(int index)
{
    if (index < 0 || index >= s_app_count) return "";
    return s_apps[index];
}

const char *remote_ui_app_icon(int index)
{
    if (index < 0 || index >= s_app_count) return "";
    return s_icons[index];
}

uint32_t remote_ui_manifest_revision(void) { return s_manifest_rev; }

void remote_ui_open_app(uint8_t index)
{
    s_open_index = index;
    send_event(REMOTE_EVT_OPEN, index, 0);
}

// ⚠ 跑在 NimBLE host 任务里,不碰任何 LVGL 对象。
static int screen_write_cb(uint16_t conn_handle, uint16_t attr_handle,
                           struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;

    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_UNLIKELY;

    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len == 0) return 0;

    // 一屏放不下就丢掉重来,而不是截断后当成完整的一屏渲染出去 ——
    // 截断会让用户看到半行乱码,还不如维持上一屏不动。
    if (s_rx_len + len >= (int)sizeof(s_rx)) {
        ESP_LOGW(TAG, "屏幕描述超过 %d 字节,丢弃这一屏", (int)sizeof(s_rx));
        s_rx_len = 0;
        return 0;
    }

    if (ble_hs_mbuf_to_flat(ctxt->om, s_rx + s_rx_len, len, NULL) != 0) {
        s_rx_len = 0;
        return BLE_ATT_ERR_UNLIKELY;
    }
    s_rx_len += len;
    s_rx[s_rx_len] = '\0';

    // 对端一次写入可能被 ATT 拆成几个包,以换行结尾才算这一屏收齐。
    if (s_rx[s_rx_len - 1] == '\n') {
        commit_screen();
        s_rx_len = 0;
    }
    return 0;
}

// EVENT 特征只用于设备 -> 对端的 indicate,但 NimBLE 要求非空 access_cb。
static int event_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                           struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle; (void)attr_handle; (void)ctxt; (void)arg;
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &s_screen_uuid.u,
                .access_cb = screen_write_cb,
                // 两种写都声明:漏掉 WRITE_NO_RSP 会让对端的
                // without-response 写入被 CoreBluetooth 静默丢弃(固件传输
                // 上踩过一次,表现是完全没有日志的假死)。
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
                .val_handle = &s_screen_chr_handle,
            },
            {
                .uuid = &s_event_uuid.u,
                .access_cb = event_access_cb,
                .flags = BLE_GATT_CHR_F_INDICATE,
                .val_handle = &s_event_chr_handle,
            },
            {
                .uuid = &s_manifest_uuid.u,
                .access_cb = manifest_write_cb,
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
                .val_handle = &s_manifest_chr_handle,
            },
            { 0 },
        },
    },
    { 0 },
};

static void on_ble_subscribe(uint16_t attr_handle, bool subscribed)
{
    if (attr_handle != s_event_chr_handle || !subscribed) return;
    // 对端订阅完成的这一刻才是发第一条的正确时机(CONNECT 时它还没订阅,
    // indicate 必然失败)。告诉它设备就绪,可以开始推屏幕了。
    send_event(REMOTE_EVT_HELLO, s_active ? 1 : 0, s_open_index);
}

static void on_ble_disconnect(void)
{
    s_mrx_len = 0;
    // 断连时清掉半截的接收缓冲,否则重连后新的一屏会接在残留字节后面,
    // 解析出一堆乱行。已经渲染好的那一屏保留 —— 界面上继续显示旧数据,
    // 比整屏变空白有用。
    s_rx_len = 0;
    // 通知**不能**照着"保留旧数据"那条处理。屏幕上那一屏是"上次看到的
    // 状态",过期了也还有参考价值;而通知是"刚刚发生了一件事",它一旦
    // 跨过断连活下来,下一个连上来的人会看到一条不属于他那一端的消息 ——
    // 而他既不知道那是谁发的,也没法去源头确认。直接丢掉。
    ui_notify_drop();
}

static const ble_hub_observer_t s_observer = {
    .on_subscribe = on_ble_subscribe,
    .on_disconnect = on_ble_disconnect,
};

void remote_ui_register(void)
{
    if (!s_lock) s_lock = xSemaphoreCreateMutex();
    // 独立命名空间,跟 device_config 的配置分开 —— 这是"装了哪些应用",
    // 不是设置。依赖 device_config_init() 已经调过 nvs_flash_init()。
    if (!s_launcher_nvs_open &&
        nvs_open("launcher", NVS_READWRITE, &s_launcher_nvs) == ESP_OK) {
        s_launcher_nvs_open = true;
        load_manifest_from_nvs();
    }
    ble_hub_register_service(s_gatt_svcs);
    ble_hub_register_observer(&s_observer);
}

bool remote_ui_snapshot(remote_screen_t *out)
{
    if (!out || !s_lock) return false;
    xSemaphoreTake(s_lock, portMAX_DELAY);
    bool have = (s_revision > 0);
    if (have) *out = s_screen;
    xSemaphoreGive(s_lock);
    return have;
}

uint32_t remote_ui_revision(void) { return s_revision; }
