// main/wifi_mgr.h —— 设备端 Wi-Fi 的唯一入口。
//
// 为什么必须收成一个模块
// ──────────────────────
// 这之前仓库里有**两套**各自独立的 Wi-Fi 实现:demo_wifi.c(扫描演示页)和
// dashboard_client.c(连上去拉 HTTP)。两边各自调 esp_netif_create_default_wifi_sta()
// 和 esp_wifi_init(),各自维护一组"初始化过了没"的标志位。而 esp_netif 和
// esp_wifi 是**进程级单例**,这么用必然出事:
//
//   用户进 Wi-Fi 演示页 → 退出时 demo_wifi_exit() 调了 esp_wifi_deinit() +
//   esp_netif_destroy_default_wifi() → 面板应用再想联网 → 它自己的
//   s_wifi_inited 还是 true(它并不知道别人把底下拆了)→ 直接拿一个已经
//   失效的 netif 去连 → 挂。
//
// 反过来也一样。而且 esp_netif_create_default_wifi_sta() 撞上重复的 if_key
// 会 **assert 然后重启**,不是返回错误 —— 表现为开机就无限重启,串口刷屏,
// 极难定位。这个坑在这个项目里真实踩过一次。
//
// 所以:全仓库只有这一个文件可以碰 esp_wifi_* / esp_netif_*。
//
// 最重要的一条规则
// ────────────────
// **永远不调 esp_wifi_deinit(),永远不调 esp_netif_destroy_default_wifi()。**
//
// 关掉 Wi-Fi 用 esp_wifi_stop() —— 它是可逆的、幂等的,再 esp_wifi_start()
// 就回来了。deinit 那条路省下的那点内存,换来的是一个"第二次进来就重启"的
// 定时炸弹。这个模块的全部复杂度几乎都来自这一课。
//
// 新架构下 Wi-Fi 是可选的
// ───────────────────────
// 设备是显示终端,应用数据由配套 app 取好通过蓝牙推过来 —— 跑应用**不需要**
// Wi-Fi。所以协议栈默认不起来(省内存,BLE 常驻本来就吃掉不少),只有用户
// 在 app 上主动点"扫描"或"连接"时才惰性拉起来。
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    WIFI_MGR_OFF = 0,      // 协议栈没起来(开机默认)
    WIFI_MGR_IDLE,         // 起来了,但没在连
    WIFI_MGR_CONNECTING,
    WIFI_MGR_CONNECTED,
    WIFI_MGR_FAILED,       // 试过了,连不上(密码错/找不到 AP)
} wifi_mgr_state_t;

#define WIFI_MGR_MAX_SCAN   20
#define WIFI_MGR_SSID_LEN   33   // 32 字节 SSID + 结尾 '\0'

typedef struct {
    char ssid[WIFI_MGR_SSID_LEN];
    int  rssi;
    bool secure;        // 需要密码
} wifi_mgr_ap_t;

typedef enum {
    WIFI_MGR_SCAN_IDLE = 0,
    WIFI_MGR_SCAN_SCANNING,  // 包含等当前连接尝试结束后再扫描
    WIFI_MGR_SCAN_READY,     // 成功,scan_count 可以为 0
    WIFI_MGR_SCAN_FAILED,
} wifi_mgr_scan_status_t;

// 一次复制一致的状态,无需访问驱动。SSID 保留原始 UTF-8 字节,协议层自行转义。
typedef struct {
    wifi_mgr_state_t state;
    char ssid[WIFI_MGR_SSID_LEN];
    char ip[16];
    int rssi;
    wifi_mgr_scan_status_t scan_status;
    int scan_count;
    char pending_ssid[WIFI_MGR_SSID_LEN];
    bool pending_secure;  // 需要手机/电脑填写密码
    uint32_t revision;
    uint32_t scan_revision; // 每次扫描完成/失败递增,含 0 条和相同数量结果
} wifi_mgr_snapshot_t;

// 状态变化时被调一次。**运行在 Wi-Fi worker 里**,不要在里面做重活,
// 也不要碰 LVGL(那要 LVGL 锁)。用途是把状态转发给配套 app。
typedef void (*wifi_mgr_watch_fn)(void);

// app_main 中调用一次:创建串行 worker,不会拉起协议栈。
void wifi_mgr_init(wifi_mgr_watch_fn on_change);
void wifi_mgr_snapshot(wifi_mgr_snapshot_t *out);

// ---- 查询:随时可调,协议栈没起来时返回 OFF / 空值 -------------------------
wifi_mgr_state_t wifi_mgr_state(void);
bool             wifi_mgr_is_connected(void);
const char      *wifi_mgr_ssid(void);   // 当前连着的(或正在连的)SSID
int              wifi_mgr_rssi(void);   // 没连时返回 0
const char      *wifi_mgr_ip(void);     // 没连时返回 ""

// ---- 动作:第一次调用时惰性拉起协议栈 --------------------------------------
//
// 全部是**非阻塞**的:发起之后立刻返回,结果通过状态变化回调告知。这是刻意的
// —— 这些函数会被 BLE 的回调链调到,在那里面阻塞几秒会把整条蓝牙通道卡住。

// 用给定凭据连接。ssid 为 NULL/空时用配置里存的(device_config_wifi_ssid())。
// 返回值只表示是否接受请求;初始化/连接失败通过 snapshot 报告。
// 非空 ssid 只有与已保存 SSID 相同时才允许复用 NULL password。
bool wifi_mgr_connect(const char *ssid, const char *password);

// 断开并停止射频,保留 netif/驱动单例(下次连可重用)。
void wifi_mgr_disconnect(void);

// 发起一次扫描。结果就绪后会触发状态回调,再用下面两个函数取。
bool wifi_mgr_scan_start(void);
bool wifi_mgr_scan_busy(void);
wifi_mgr_scan_status_t wifi_mgr_scan_status(void);

// 扫描结果。返回条数;entry 可以为 NULL 只问条数。
int  wifi_mgr_scan_count(void);
bool wifi_mgr_scan_entry(int index, wifi_mgr_ap_t *out);

// 设备页选网络:开放网络直接连;同 SSID 复用已保存密码;其余加密网络
// 通过 pending_ssid/pending_secure 提示配套 app 输入密码并写入设备。
// 只复制选项并投递,不在按键/LVGL 任务里读写 NVS 或调用网络 API。
bool wifi_mgr_select_network(int index);
// Use a displayed AP snapshot so a rescan cannot silently change the selected SSID.
bool wifi_mgr_select_ap(const wifi_mgr_ap_t *ap);
