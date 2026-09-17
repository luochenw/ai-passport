// main/main.c —— FoloToy AI Passport BSP 驱动参考示例:初始化 + 菜单 + 按键分发。
//
// 菜单结构(三层):
//   顶层菜单  —— 已安装应用 / 应用商店 / 设置
//   设置子菜单 —— Wi-Fi / 蓝牙 / 开机音乐 / 音量 / 亮度 / 固件升级
//   开机音乐子页 —— 开关 / 独立音量
//
// 按键语义(全局统一):
//   上/下 短按   菜单/子菜单中=移动选中项;具体页面中=该页自定义
//   确定  短按   菜单/子菜单中=进入选中项;具体页面中=该页自定义
//   确定  长按   具体页面/设置子菜单中=返回上一层(由本文件统一拦截)
#include "bsp_i2c.h"
#include "bsp_display.h"
#include "bsp_button.h"
#include "bsp_audio.h"
#include "bsp_battery.h"
#include "bsp_pins.h"      // 错误日志里要打印 BSP_LCD_* 引脚号
#include "boot_chime.h"
#include "appstore_transfer.h"
#include "ble_hub.h"
#include "remote_ui.h"
#include "device_config.h"
#include "device_trust.h"
#include "device_trust_protocol.h"
#include "wifi_mgr.h"
#include "walkie_audio.h"
#include "demo.h"
#include "ui_pixel.h"
#include "ui_statusbar.h"
#include "ui_notify.h"
#include "ui_text_sanitize.h"
#include "lvgl.h"
#include "driver/usb_serial_jtag.h"
#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "esp_pm.h"
#include "esp_sleep.h"
#include "esp_system.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/task.h"
#include "sdkconfig.h"
#include <stdatomic.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <time.h>

static const char *TAG = "main";
static atomic_bool s_system_ready;
#define HOUSEKEEPING_STACK_BYTES 8192

static void on_key(bsp_btn_t btn, bsp_btn_ev_t ev, void *user);
static void top_menu_refresh(void);
static void enter_top_menu(void);
static void trust_ui_check(void);
static void apply_time_sync(const char *value);
static void on_walkie_activity(bool receiving);
// 通知到达时点亮屏幕。跟 wake_screen() 的区别:**不**置 s_wake_swallow ——
// 那个标志是用来吞掉"用户按键唤醒"那一下的后续事件的,而通知是设备自己
// 亮起来的,没有任何按键需要吞。用 wake_screen() 的话,用户看到通知后按的
// 第一下会被当成唤醒键吃掉,要按两次才关得掉。
static void wake_screen_for_notify(void);

// 各页依赖的硬件初始化。写成一行一个小函数而不是直接塞进表里,是因为
// probe 的签名统一是 bool(void),而各 bsp_*_init() 的签名各不相同。

// ⚠ 按键和音频不放在 probe 里。
//
// probe 的语义是"这一页需要的硬件",页面从 DEMOS[] 里删掉它就不再执行。可是
// 按键是整机基础设施:它一旦没初始化,连顶层菜单都动不了,全局逃生手势也没
// 了 —— 把它挂在"按键演示页"的 probe 上,等于"删掉那一页设备就变砖"。改成
// 精简本地页时确实差点踩中:DEMOS[] 只剩电量一项之后,编译器报
// probe_button 未使用,才发现按键初始化被一起删掉了。

// ---- 设备 -> 配套 app 的状态上报 -------------------------------------------
//
// 配置页要显示"现在连着哪个 Wi-Fi""扫到了哪些网络",这些事实只有设备知道。
// 通过 device_config 的 STATUS 通道(NOTIFY)推过去,格式跟下发方向一样是
// "<key>=<value>\n" 文本行。
//
// ⚠ 这个函数会在 **Wi-Fi 事件任务**里被调到,那个任务的栈只有两千多字节。
// 所以不要在这里开大数组 —— 扫描结果是一行一行发的,每次只占一个小缓冲区,
// 哪怕扫到二十个 AP 也不会把栈撑爆。
static const char *wifi_state_name(wifi_mgr_state_t state)
{
    switch (state) {
    case WIFI_MGR_IDLE:       return "idle";
    case WIFI_MGR_CONNECTING: return "connecting";
    case WIFI_MGR_CONNECTED:  return "connected";
    case WIFI_MGR_FAILED:     return "failed";
    default:                  return "off";
    }
}

// SSID 是任意字节,可能含有换行或 '=' —— 直接塞进行式协议里会把一行拆成两行、
// 或者让对端把名字的一半当成键。控制字符一律换成 '?',对端解析时只按**第一个**
// '=' 切,所以名字里的 '=' 不用处理。
static void sanitize_ssid(const char *in, char *out, size_t n)
{
    size_t i = 0;
    for (; in[i] && i + 1 < n; i++) {
        unsigned char c = (unsigned char)in[i];
        out[i] = (c < 0x20 || c == 0x7F) ? '?' : in[i];
    }
    out[i] = '\0';
}

// Worker callbacks only signal. Formatting and BLE retries run on cfg_watch.
static atomic_bool s_device_status_pending;
static atomic_bool s_scan_snapshot_requested;
static bool s_scan_report_pending;
static uint32_t s_reported_scan_revision;

static void report_device_status(void)
{
    atomic_store(&s_device_status_pending, true);
}

static void report_status_on_subscribe(void)
{
    atomic_store(&s_scan_snapshot_requested, true);
    report_device_status();
}

static void send_device_status(void)
{
    if (!device_config_status_ready()) return;
    wifi_mgr_snapshot_t snapshot;
    wifi_mgr_snapshot(&snapshot);
    char ssid[WIFI_MGR_SSID_LEN], selected[WIFI_MGR_SSID_LEN];
    sanitize_ssid(snapshot.ssid, ssid, sizeof(ssid));
    sanitize_ssid(snapshot.pending_ssid, selected, sizeof(selected));
    const char *scan_status = snapshot.scan_status == WIFI_MGR_SCAN_SCANNING ? "scanning" :
                              snapshot.scan_status == WIFI_MGR_SCAN_READY ? "ready" :
                              snapshot.scan_status == WIFI_MGR_SCAN_FAILED ? "failed" : "idle";
    char line[352];
    snprintf(line, sizeof(line),
             "wifi.state=%s\nwifi.ssid=%s\nwifi.ip=%s\nwifi.rssi=%d\n"
             "wifi.scanning=%d\nwifi.scan.status=%s\nwifi.selected=%s\nwifi.password_required=%d\n",
             wifi_state_name(snapshot.state), ssid, snapshot.ip, snapshot.rssi,
             snapshot.scan_status == WIFI_MGR_SCAN_SCANNING, scan_status,
             selected, snapshot.pending_secure ? 1 : 0);
    if (!device_config_report(line)) atomic_store(&s_device_status_pending, true);
    // Include empty results on reconnect and after every completed scan.
    bool force_scan = atomic_exchange(&s_scan_snapshot_requested, false);
    if (snapshot.scan_status == WIFI_MGR_SCAN_READY &&
        (force_scan || snapshot.scan_revision != s_reported_scan_revision)) {
        s_scan_report_pending = true;
        s_reported_scan_revision = snapshot.scan_revision;
    } else if (snapshot.scan_status == WIFI_MGR_SCAN_FAILED) {
        s_scan_report_pending = false;
    }
}

// 把扫描结果推给对端。**只能从普通任务里调**,不能从 NimBLE 主机任务调。
static bool report_wifi_scan(void)
{
    int n = wifi_mgr_scan_count();
    if (!device_config_status_ready()) return false;

    // 攒够一批再发,而不是一行一个 notify。二十个网络原本要二十多次
    // notify,批完之后只要五六次 —— 光这一项就把 mbuf 的压力降下来了。
    // 上限取 168:device_config_report 内部按 180 字节切片,留一点余量让
    // 每一批都能一次发完,不会在批内再被切一刀。
    char batch[176];
    int  used = 0;
    char safe[WIFI_MGR_SSID_LEN];

    // 每一批最多重试几次。mbuf 通常在一两个连接事件内就回收了,10 次 × 30ms
    // 足够;还发不出去说明链路真的断了,丢掉这一批比无限重试好。
    #define SCAN_REPORT_RETRY 10

    bool ok = false;
    for (int r = 0; r < SCAN_REPORT_RETRY && !ok; r++) {
        ok = device_config_report("wifi.ap.begin=\n");
        if (!ok) vTaskDelay(pdMS_TO_TICKS(30));
    }
    if (!ok) return false;

    for (int i = 0; i <= n; i++) {
        char line[128];
        int len;
        if (i < n) {
            wifi_mgr_ap_t ap;
            if (!wifi_mgr_scan_entry(i, &ap)) continue;
            sanitize_ssid(ap.ssid, safe, sizeof(safe));
            // 制表符分隔字段:SSID 里几乎不可能出现它,而空格和 '-' 很常见。
            len = snprintf(line, sizeof(line), "wifi.ap=%s\t%d\t%d\n",
                           safe, ap.rssi, ap.secure ? 1 : 0);
        } else {
            // Do not commit a list assembled across two scans. A fresh begin
            // on the next attempt replaces the companion's partial list.
            wifi_mgr_snapshot_t current;
            wifi_mgr_snapshot(&current);
            if (current.scan_revision != s_reported_scan_revision ||
                current.scan_status == WIFI_MGR_SCAN_FAILED) {
                report_device_status();
                return false;
            }
            // 最后一轮:补上 end 标记。有了 begin/end 这一对,对端才能判断
            // "这一批发完了没有" —— 否则列表少一项和还没发完长得一模一样。
            len = snprintf(line, sizeof(line), "wifi.ap.end=%d\n", n);
        }
        if (len < 0) continue;
        if (len >= (int)sizeof(line)) len = (int)sizeof(line) - 1;

        if (used + len >= (int)sizeof(batch)) {
            ok = false;
            for (int r = 0; r < SCAN_REPORT_RETRY && !ok; r++) {
                ok = device_config_report(batch);
                if (!ok) vTaskDelay(pdMS_TO_TICKS(30));
            }
            used = 0;
            if (!ok) {
                ESP_LOGW(TAG, "扫描结果推送中断(链路不通),已发 %d 项", i);
                return false;
            }
        }
        memcpy(batch + used, line, (size_t)len);
        used += len;
        batch[used] = '\0';
    }

    if (used > 0) {
        ok = false;
        for (int r = 0; r < SCAN_REPORT_RETRY && !ok; r++) {
            ok = device_config_report(batch);
            if (!ok) vTaskDelay(pdMS_TO_TICKS(30));
        }
    }
    wifi_mgr_snapshot_t snapshot;
    wifi_mgr_snapshot(&snapshot);
    if (snapshot.scan_revision != s_reported_scan_revision) {
        report_device_status();
        return false;
    }
    if (ok) ESP_LOGI(TAG, "已推送 %d 个扫描结果", n);
    return ok;
    #undef SCAN_REPORT_RETRY
}

// 配套 app 发过来的**动作**(cmd.* 键,不落盘,见 device_config.h)。
static void on_config_cmd(const char *name, const char *arg)
{
    if (strcmp(name, "time") == 0) {
        apply_time_sync(arg);
        ui_statusbar_notify_config_changed();
        return;
    }
    if (strcmp(name, "notify") == 0) {
        // ⚠ 这个函数跑在 NimBLE host 任务上,**不持有 LVGL 锁**
        // (ui_statusbar.c:310 记过同一个坑)。所以这里只投递,不画。
        ui_notify_post(arg);
        // 息屏时通知不点亮屏幕就等于没发 —— 而息屏恰恰是最需要被提醒的时候。
        wake_screen_for_notify();
        return;
    }
    if (strcmp(name, "wifi") == 0) {
        if (strcmp(arg, "scan") == 0) {
            wifi_mgr_scan_start();
        } else if (strcmp(arg, "connect") == 0) {
            // 凭据用配置里刚下发的那份 —— app 是先写 wifi.ssid/wifi.pass
            // 再发这条命令的。
            wifi_mgr_connect(NULL, NULL);
        } else if (strcmp(arg, "disconnect") == 0) {
            wifi_mgr_disconnect();
        } else {
            ESP_LOGW(TAG, "未知的 wifi 命令: %s", arg);
        }
        report_device_status();
        return;
    }
    // 刻意没有 cmd.ble=disconnect:配套 app 想断开的话,它自己
    // cancelPeripheralConnection 就够了,设备这边照样会收到断连事件。绕一圈
    // 从设备发起,多一条协议、多一个失败模式,换不来任何东西。
    ESP_LOGW(TAG, "未知命令: cmd.%s=%s", name, arg);
}

// 时间同步:这台设备没有 RTC,断电就忘,而且新架构下它也不联网(数据都由
// 配套 app 取好了通过蓝牙推过来),所以没有 SNTP 这条路。时间只能由 app 在
// 连上之后下发。
//
// ⚠ 时间走的是 **cmd.time**(动作,不落盘),不是普通配置键。这一点是刻意的:
// 时间存进 NVS 的话,下次不连电脑单独开机时会被读出来当成"当前时间"拨进
// 系统时钟 —— 于是屏幕上显示的是一个**陈旧但看起来完全合理**的时间。那比
// 显示 --:-- 糟糕得多:用户没有任何线索知道它是错的。没有电脑就没有时间,
// 这是这台设备的物理事实,界面应该如实反映。
//
// tzmin(相对 UTC 的分钟偏移,东八区 = 480)则是普通配置,该存 —— 它是用户
// 所在时区这个长期事实,不会因为断电而失效。
//
// 存 UTC + 偏移而不是直接存本地时间,是因为系统时钟本身应该是 UTC:把本地
// 时间灌进 settimeofday() 会让任何依赖真实时间的东西悄悄错上几个时区。
// 偏移只在显示的那一刻加(见 ui_statusbar.c)。
static void apply_time_sync(const char *value)
{
    if (!value || !*value) return;

    long long epoch = strtoll(value, NULL, 10);
    // 2020-01-01 之前的值一律当成无效 —— 解析失败时 strtoll 返回 0,
    // 不挡一下就会把时钟拨回 1970。
    if (epoch < 1577836800LL) return;

    // 只在**差得足够多**的时候才拨钟。app 每次重连都会下发一次时间,如果
    // 每次都无条件 settimeofday(),时钟就会随着蓝牙重连反复跳 —— 而 BLE 断连
    // 重连在这个项目里是家常便饭。1 分钟以上才认,既能纠正真正的漂移,又不会
    // 让秒针一直抖。
    time_t now = time(NULL);
    long long diff = (long long)now - epoch;
    if (diff < 0) diff = -diff;
    if (diff < 60) return;

    struct timeval tv = { .tv_sec = (time_t)epoch, .tv_usec = 0 };
    if (settimeofday(&tv, NULL) == 0) {
        ESP_LOGI(TAG, "时间已同步(原先偏差 %lld 秒)", diff);
    }
}

// 把配置里的值真正应用到硬件。
//
// ⚠ 这个函数的存在是因为一个实测到的问题:音量之前只被写进 NVS,代码里
// **没有任何地方**把它交给 bsp_audio_set_volume() —— 也就是说配套 app 上那个
// 音量滑块从来就没生效过,只是存了个数字。存下来和用起来是两件事,后者容易
// 被忘掉,而且忘了不会报错。所有"配置 → 硬件"的落地都收在这里一处。
static bool apply_device_config(void)
{
    bsp_display_backlight((uint8_t)device_config_brightness());
    // ⚠ 开机音效正在放的时候不要碰音量。它自己用一个很小的固定音量放,放完
    // 会把音量交还给这里的配置值 —— 中途插一手会让音效放到一半突然变响
    // (实测过:配置里存的是 75,音效开头 5% 放着放着就跳到 75)。
    if (boot_chime_is_playing()) return false;
    if (!bsp_audio_acquire(0)) return false;
    bsp_audio_set_volume((uint8_t)device_config_volume());
    bsp_audio_release();
    return true;
}

// 配置由配套 app 随时下发,不能只在开机应用一次。这个任务盯着 revision 变化,
// 变了就重新落地一次 —— 比给 device_config 加回调注册简单,而且天然不会在
// BLE 协议栈任务里去碰音频/背光这些外设。
static void config_watch_task(void *arg)
{
    (void)arg;
    uint32_t seen = device_config_revision();
    // The first apply happens while the boot chime may still own the codec.
    // Retry until the configured volume has actually been applied.
    bool audio_pending = true;
    for (;;) {
        device_config_process_pending();
        uint32_t now = device_config_revision();
        if (now != seen) {
            seen = now;
            audio_pending = !apply_device_config();
            // 状态栏的显示项(sb.items)和时间都可能刚被改过,让它立刻重画,
            // 而不是等下一个刷新周期 —— app 上勾掉一项,设备要当场有反应。
            ui_statusbar_notify_config_changed();
            device_config_request_snapshot();
            if (audio_pending) {
                ESP_LOGI(TAG, "配置已生效:亮度 %d,音量 %d 待音频空闲后应用",
                         device_config_brightness(), device_config_volume());
            } else {
                ESP_LOGI(TAG, "配置已生效:亮度 %d,音量 %d",
                         device_config_brightness(), device_config_volume());
            }
        } else if (audio_pending) {
            audio_pending = !apply_device_config();
        }
        // 扫描结果在这里发,不在产生它的那个上下文里发 —— 理由见
        // report_device_status() 里的说明(NimBLE 主机任务里不能睡等 mbuf)。
        if (atomic_exchange(&s_device_status_pending, false)) send_device_status();
        if (s_scan_report_pending) {
            s_scan_report_pending = !report_wifi_scan();
        }
        vTaskDelay(pdMS_TO_TICKS(300));
    }
}

static void init_shared_hardware(void)
{
    if (bsp_button_init(on_key, NULL) != ESP_OK) {
        ESP_LOGE(TAG, "按键初始化失败,设备将无法操作");
    }
    // 电量计也是整机基础设施,不再是"电量页需要的硬件"。
    //
    // ⚠ 它原来只由 DEMOS[] 里那一项的 probe 顺带初始化。首屏去掉「电量」
    // 那一项之后,如果不搬到这里,顶部状态栏的电量会永远读到 -1 而整项消失
    // —— 而且不会有任何报错。这跟按键当年那次是同一类问题:把整机要用的
    // 东西挂在某一个页面的 probe 上,删掉那个页面就连带删掉了它。
    if (bsp_battery_init() != ESP_OK) {
        ESP_LOGW(TAG, "电量计不可用,状态栏将不显示电量");
    }
    if (bsp_audio_init() == ESP_OK) {
        esp_reset_reason_t reason = esp_reset_reason();
        bool abnormal = reason == ESP_RST_PANIC || reason == ESP_RST_INT_WDT ||
                        reason == ESP_RST_TASK_WDT || reason == ESP_RST_WDT ||
                        reason == ESP_RST_BROWNOUT;
        if (device_config_boot_chime_enabled() && !abnormal) {
            boot_chime_play_async((uint8_t)device_config_volume(),
                                  (uint8_t)device_config_boot_chime_volume());
        }
    } else {
        ESP_LOGW(TAG, "音频初始化失败,跳过开机音效");
    }
}

// 一行一个页面。名字、说明、生命周期、硬件初始化全在同一行 —— 增删条目
// (做应用裁剪时经常要做)不会再让任何东西错位。
//
// 不同变体带不同的页面集合。共同的底座(常驻 BLE、NVS 配置、应用商店、
// 防砖)在所有变体里都一样,这里只决定"菜单里有哪些页"。
// 设备本地页。只留脱机也有意义的那些 —— 其余功能都由电脑推过来
// (见 remote_ui.h)。这张表现在只有一项,但结构保留着:将来要加本地功能
// (时钟、秒表这类不需要电脑的东西)在这里加一行即可。

typedef enum {
    VIEW_TOP_MENU,      // 顶层:Codex / 应用商店 / 设置
    VIEW_CODEX,         // Codex 页(启动器变体)
    VIEW_REMOTE,        // 远程界面:电脑推什么显示什么
    VIEW_APPSTORE,      // 固件升级页(整机固件 OTA,跟远程应用是两回事)
    VIEW_CONNECTIONS,   // 可信伴侣、添加伴侣与连接交接
    VIEW_SETTINGS,
    VIEW_WIFI,
} view_t;

static view_t s_view = VIEW_TOP_MENU;

// 首屏 = 已安装的应用 + 应用商店、设置。
//
// 应用列表不是写死的:配套 app 连上后会推一份"用户装了哪些应用"的清单过来
// (见 remote_ui.h),设备缓存进 NVS。所以首屏是随安装状态变的 —— 在应用
// 商店里装一个,它就出现在这里。
//
// 缓存的意义在断开电脑时:首屏照常列出装过的应用,点进去才提示需要连接,
// 而不是让整台设备退化成一块只显示"等待连接"的板子。
//
// 固定尾项两个:
//   应用商店 —— 装/卸远程应用。本身也是一屏由电脑推的界面。
//   设置     —— 本地功能(电量、固件升级),不依赖电脑。
// ⚠ 固件升级跟应用安装是两件不同的事,各占一个入口:
//   应用商店 —— 装/卸远程应用,不动固件,秒切
//   固件升级 —— 整机固件 OTA,要传几 MB、重启,有防砖机制兜底
// 混在一起会让用户以为"装个应用"也要等两分钟重刷。
// 首屏的固定项。电量曾经也在这里,后来去掉了 —— 顶部状态栏已经一直显示着
// 电量,再单开一页只是把同一个数字换个地方再写一遍。
#define TOP_FIXED_STORE    0
#define TOP_FIXED_SETTINGS 1
#define TOP_FIXED_COUNT    2
static const char *TOP_FIXED_NAMES[] = { "应用商店", "设置" };
static const char *TOP_FIXED_HINTS[] = { "安装/管理应用", "" };
// 图标用 montserrat 里的 FontAwesome 那一段 —— 中文字库 lv_font_ui_cn_14 没有
// 这段码位,拿它画图标只会出方框。
static const char *TOP_FIXED_ICONS[] = {
    LV_SYMBOL_DOWNLOAD, LV_SYMBOL_SETTINGS
};

// 首屏最多能画几行(应用 + 固定项)。
#define TOP_MAX_ROWS (REMOTE_UI_MAX_APPS + TOP_FIXED_COUNT)

// 首屏列表的几何。
#define TOP_ROW_TOP   8
#define TOP_ROW_STEP  22
#define TOP_ROW_H     20

// 装满应用时最后一行必须还在提示条上面。
//
// 写成编译期断言而不是注释里的一句"记得验算":这个约束被打破时**没有任何
// 运行期症状**可循 —— 不崩、不报错,只是最后一两行被底部提示条盖住,而且
// 只在应用装满时才出现。靠人记得去算是靠不住的,让编译器算。
_Static_assert(TOP_ROW_TOP + (TOP_MAX_ROWS - 1) * TOP_ROW_STEP + TOP_ROW_H
                   <= UI_CONTENT_BOTTOM,
               "首屏列表放不下:调小 REMOTE_UI_MAX_APPS 或 TOP_ROW_STEP");

// 当前首屏一共几项 = 已安装应用数 + 固定项。
static int top_row_count(void)
{
    return remote_ui_app_count() + TOP_FIXED_COUNT;
}

// 第 i 项的名字/说明。前面是应用,后面是固定项。
static const char *top_row_name(int i)
{
    int apps = remote_ui_app_count();
    return (i < apps) ? remote_ui_app_name(i) : TOP_FIXED_NAMES[i - apps];
}

static const char *top_row_hint(int i)
{
    int apps = remote_ui_app_count();
    return (i < apps) ? "" : TOP_FIXED_HINTS[i - apps];
}

// 当前是不是从 appslot(应用商店装的那个应用)启动的 —— app_main() 里用
// esp_ota_get_running_partition() 判断一次,后面顶层菜单的"长按确定"要靠
// 这个决定是"没有更上一级可退"还是"退回 factory 启动器"。
static bool s_running_from_appslot;

// 应用商店装完新应用后调用(main/demo_appstore.c 通过 demo.h 声明的
// main_boot_into_appslot() 调这个文件里的实现):写 bootflag、重启。
// 跟下面 return_to_launcher() 是同一个 bootflag 分区的两种写法,放一起
// 方便对照。
static void write_bootflag_and_restart(bool into_appslot)
{
    const esp_partition_t *p = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, (esp_partition_subtype_t)0x40, "bootflag");
    if (!p) {
        ESP_LOGE(TAG, "找不到 bootflag 分区,无法%s", into_appslot ? "安装新应用" : "返回启动器");
        return;
    }
    esp_err_t err = esp_partition_erase_range(p, 0, p->erase_size);
    if (err == ESP_OK && into_appslot) {
        uint8_t magic = 0xA5;   // 必须跟 recovery_boot_hook.c 的 APPSLOT_BOOT_MAGIC 一致
        err = esp_partition_write(p, 0, &magic, sizeof(magic));
    }
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "写 bootflag 失败: %s", esp_err_to_name(err));
        return;
    }
    esp_restart();
}

// main/demo.h 声明,main/demo_appstore.c 调用。
void main_boot_into_appslot(void)
{
    write_bootflag_and_restart(true);
}

static void return_to_launcher_from_appslot(void)
{
    write_bootflag_and_restart(false);
}

void main_restart_to_factory_for_update(void)
{
    write_bootflag_and_restart(false);
}

// 向 bootloader 确认"这次 appslot 应用真的活着跑起来了":把启动尝试计数清零。
// bootloader 每次跳进 appslot 之前都会把这个计数 +1,连续
// APPSLOT_MAX_BOOT_ATTEMPTS 次没被清零就强制回 factory —— 那是防"镜像合法
// 但一跑起来就崩"导致无限重启的最后一道防线(那种情况设备起不来、USB CDC
// 来不及枚举,连串口都不会出现,插线也救不了)。
//
// 调用时机很关键:必须晚到"能证明系统真的可用"(app_main 已经把屏幕、按键
// 这些基础设施都初始化完了),又必须早到"用户还没来得及做任何操作"。放在
// app_main 末尾正好符合这两条。放太早(比如刚进 app_main 就清)会把崩溃循环
// 判成成功启动,保护就失效了。
static void confirm_appslot_boot_ok(void)
{
    const esp_partition_t *p = esp_partition_find_first(
        ESP_PARTITION_TYPE_DATA, (esp_partition_subtype_t)0x40, "bootflag");
    if (!p) return;

    uint32_t words[2] = { 0 };
    if (esp_partition_read(p, 0, words, sizeof(words)) != ESP_OK) return;
    if ((words[0] & 0xFF) != 0xA5) return;   // 不是从 appslot 启动的,没什么要确认
    if ((words[1] & 0xFF) == 0) return;      // 已经是 0,不用为了写同样的值再擦一次

    // 整扇区擦除,所以 magic 要跟着一起写回去,不能只清计数那一个字。
    if (esp_partition_erase_range(p, 0, p->erase_size) != ESP_OK) return;
    uint32_t rewrite[2] = { 0xA5, 0 };
    if (esp_partition_write(p, 0, rewrite, sizeof(rewrite)) != ESP_OK) {
        ESP_LOGE(TAG, "清除 appslot 启动计数失败,下次启动可能被误判为崩溃");
    }
}
static lv_obj_t *s_top_scr;
static lv_obj_t *s_top_cards[TOP_MAX_ROWS];
static lv_obj_t *s_top_rows[TOP_MAX_ROWS];
// 每行左边的图标。首屏上"你装的应用"和"设备自带的功能"是两类东西,混在一列里
// 长得一模一样时,用户得逐行读文字才能分辨。
//
// 图标 + 配色分开这两类:应用是陶土橙的 ▶(可以打开的东西),设备功能是
// 鼠尾草绿的下载/刷新图标(对设备本身做的事)。
static lv_obj_t *s_top_icons[TOP_MAX_ROWS];
static int s_top_sel;

// ---- 蓝牙 / 首次配对确认 -------------------------------------------------
#define TRUST_UI_VISIBLE_ROWS 7
#define TRUST_UI_ROW_HEIGHT   29
#define TRUST_UI_ROW_STEP     32
static lv_obj_t *s_trust_scr;
static lv_obj_t *s_trust_cards[TRUST_UI_VISIBLE_ROWS];
static lv_obj_t *s_trust_labels[TRUST_UI_VISIBLE_ROWS];
static lv_obj_t *s_trust_hint;
static int s_trust_sel;
static lv_obj_t *s_pairing_overlay;
static lv_obj_t *s_pairing_peer_label;
static lv_obj_t *s_pairing_code_label;
static lv_obj_t *s_pairing_hint_label;
static uint32_t s_trust_ui_revision;

static void trust_connections_refresh(void)
{
    device_trust_snapshot_t snapshot;
    device_trust_snapshot(&snapshot);
    int count = 2 + device_trust_count();
    if (s_trust_sel >= count) s_trust_sel = count - 1;
    if (s_trust_sel < 0) s_trust_sel = 0;
    int first = device_trust_window_first(s_trust_sel, count,
                                          TRUST_UI_VISIBLE_ROWS);

    for (int row = 0; row < TRUST_UI_VISIBLE_ROWS; row++) {
        int index = first + row;
        if (index >= count) {
            lv_obj_add_flag(s_trust_cards[row], LV_OBJ_FLAG_HIDDEN);
            continue;
        }
        lv_obj_remove_flag(s_trust_cards[row], LV_OBJ_FLAG_HIDDEN);
        if (index == 0) {
            char safe_name[DEVICE_TRUST_NAME_MAX + 1];
            ui_text_sanitize_copy(safe_name, sizeof(safe_name),
                                  snapshot.companion_name);
            lv_label_set_text_fmt(s_trust_labels[row], "当前: %s",
                                  snapshot.authorized && safe_name[0]
                                      ? safe_name : "未连接");
        } else if (index == 1) {
            if (snapshot.pairing_discovery_active) {
                lv_label_set_text_fmt(s_trust_labels[row], "开启配对发现  %ds",
                                      snapshot.pairing_seconds);
            } else {
                lv_label_set_text(s_trust_labels[row], "开启配对发现");
            }
        } else {
            char id[DEVICE_TRUST_ID_MAX + 1];
            char name[DEVICE_TRUST_NAME_MAX + 1];
            char safe_name[DEVICE_TRUST_NAME_MAX + 1];
            uint8_t platform = 0;
            device_trust_companion(index - 2, id, sizeof(id), name, sizeof(name), &platform);
            ui_text_sanitize_copy(safe_name, sizeof(safe_name), name[0] ? name : id);
            bool current = snapshot.authorized && strcmp(id, snapshot.companion_id) == 0;
            lv_label_set_text_fmt(s_trust_labels[row], "%s%s%s",
                                  current ? "* " : "", safe_name[0] ? safe_name : "未命名",
                                  platform == 1 ? " / iPhone" : platform == 2 ? " / Mac" : "");
        }
        ui_pixel_set_selected(s_trust_cards[row], index == s_trust_sel, true);
    }
    lv_label_set_text_fmt(s_trust_hint,
                          "确定 连接/断开    %d/%d\n双击 忘记    长按 返回",
                          s_trust_sel + 1, count);
}

static void enter_connections(void)
{
    s_view = VIEW_CONNECTIONS;
    s_trust_scr = ui_pixel_screen_create("蓝牙");
    for (int i = 0; i < TRUST_UI_VISIBLE_ROWS; i++) {
        int y = 5 + i * TRUST_UI_ROW_STEP;
        s_trust_cards[i] = ui_pixel_panel_create(
            s_trust_scr, 10, y, 220, TRUST_UI_ROW_HEIGHT, UI_PAPER);
        lv_obj_set_style_pad_all(s_trust_cards[i], 0, 0);
        s_trust_labels[i] = lv_label_create(s_trust_cards[i]);
        lv_obj_set_style_text_font(s_trust_labels[i], &lv_font_ui_cn_14, 0);
        lv_obj_set_style_text_color(s_trust_labels[i], lv_color_hex(UI_INK), 0);
        lv_obj_align(s_trust_labels[i], LV_ALIGN_LEFT_MID, 4, 0);
        lv_label_set_long_mode(s_trust_labels[i], LV_LABEL_LONG_DOT);
        lv_obj_set_size(s_trust_labels[i], 210, 27);
    }
    s_trust_hint = ui_pixel_label(s_trust_scr, "", &lv_font_ui_cn_14, UI_MUTED);
    lv_obj_set_size(s_trust_hint, 224, 54);
    lv_label_set_long_mode(s_trust_hint, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_align(s_trust_hint, LV_TEXT_ALIGN_CENTER, 0);
    lv_obj_align(s_trust_hint, LV_ALIGN_BOTTOM_MID, 0, -5);
    trust_connections_refresh();
    lv_screen_load(s_trust_scr);
}

// GAP/NimBLE callbacks never touch LVGL. The one-second housekeeping task
// notices the plain-data revision and creates/removes this overlay under the
// LVGL lock.
static void trust_ui_check(void)
{
    device_trust_snapshot_t snapshot;
    device_trust_snapshot(&snapshot);
    bool changed = snapshot.revision != s_trust_ui_revision;
    bool countdown = s_view == VIEW_CONNECTIONS && snapshot.pairing_discovery_active;
    if (!changed && !countdown &&
        (!!s_pairing_overlay == snapshot.confirmation_pending)) return;
    if (!bsp_lvgl_lock(500)) return;
    s_trust_ui_revision = snapshot.revision;

    if (snapshot.confirmation_pending && !s_pairing_overlay) {
        s_pairing_overlay = lv_obj_create(lv_layer_top());
        lv_obj_set_size(s_pairing_overlay, 232, 286);
        lv_obj_center(s_pairing_overlay);
        lv_obj_set_style_bg_color(s_pairing_overlay, lv_color_hex(UI_PAPER), 0);
        lv_obj_set_style_border_color(s_pairing_overlay, lv_color_hex(UI_ACCENT), 0);
        lv_obj_set_style_border_width(s_pairing_overlay, 3, 0);

        lv_obj_t *title = ui_pixel_label(s_pairing_overlay, "新的连接请求",
                                         &lv_font_ui_cn_20, UI_INK);
        lv_obj_align(title, LV_ALIGN_TOP_MID, 0, 12);
        s_pairing_peer_label = ui_pixel_label(s_pairing_overlay, "",
                                               &lv_font_ui_cn_14, UI_INK_SOFT);
        lv_obj_set_width(s_pairing_peer_label, 190);
        lv_obj_set_style_text_align(s_pairing_peer_label, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_align(s_pairing_peer_label, LV_ALIGN_TOP_MID, 0, 54);
        s_pairing_code_label = lv_label_create(s_pairing_overlay);
        lv_obj_set_style_text_font(s_pairing_code_label, &lv_font_montserrat_20, 0);
        lv_obj_set_style_text_color(s_pairing_code_label, lv_color_hex(UI_ACCENT), 0);
        lv_obj_align(s_pairing_code_label, LV_ALIGN_CENTER, 0, -10);
        s_pairing_hint_label = ui_pixel_label(
            s_pairing_overlay, "核对两端数字\n确定 = 信任    上 = 拒绝",
            &lv_font_ui_cn_14, UI_MUTED);
        lv_obj_set_style_text_align(s_pairing_hint_label, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_align(s_pairing_hint_label, LV_ALIGN_BOTTOM_MID, 0, -16);
        wake_screen_for_notify();
    }
    if (snapshot.confirmation_pending && s_pairing_overlay) {
        // The overlay can survive an A-disconnect/B-connect sequence between
        // housekeeping ticks. Always refresh peer and code from the newest
        // revision so the physical OK key can never appear to confirm A while
        // the pending SMP transaction actually belongs to B.
        const char *platform = snapshot.platform == 1 ? "iPhone / iPad" :
                               snapshot.platform == 2 ? "Mac" : "未知平台";
        char safe_peer_name[DEVICE_TRUST_NAME_MAX + 1];
        ui_text_sanitize_copy(safe_peer_name, sizeof(safe_peer_name),
                              snapshot.companion_name);
        lv_label_set_text_fmt(s_pairing_peer_label,
                              snapshot.confirmation_retrust
                                  ? "重新信任\n%s\n%s / App %s"
                                  : "%s\n%s / App %s",
                              safe_peer_name[0] ? safe_peer_name : "未知伴侣",
                              platform,
                              snapshot.app_version[0] ? snapshot.app_version : "?");
        if (snapshot.confirmation_retrust) {
            lv_label_set_text(s_pairing_code_label, "TRUST");
            lv_label_set_text(s_pairing_hint_label,
                              "此伴侣之前已被忘记\n确定 = 重新信任    上 = 拒绝");
        } else {
            lv_label_set_text_fmt(s_pairing_code_label, "%06lu",
                                  (unsigned long)snapshot.numeric_code);
            lv_label_set_text(s_pairing_hint_label,
                              "核对两端数字\n确定 = 信任    上 = 拒绝");
        }
    } else if (!snapshot.confirmation_pending && s_pairing_overlay) {
        lv_obj_delete(s_pairing_overlay);
        s_pairing_overlay = NULL;
        s_pairing_peer_label = NULL;
        s_pairing_code_label = NULL;
        s_pairing_hint_label = NULL;
    }
    if ((changed || countdown) && s_view == VIEW_CONNECTIONS && s_trust_scr) {
        trust_connections_refresh();
    }
    bsp_lvgl_unlock();
}

static esp_pm_lock_handle_t s_usb_pm_lock;
static int64_t s_last_activity_us;

// ---- 息屏 ------------------------------------------------------------------
//
// ⚠ 息屏和 light sleep 是**两件事**,代价完全不同,必须分开判断:
//
//   关背光    —— 省的是这块板子上最大的一项电,而且跟射频毫无关系。
//                蓝牙照常连着,电脑照常推屏,只是没人看而已。任何时候都能做。
//   light sleep —— 省的是 CPU 那点电,但会**掐断常驻 BLE**(这块板子的 BLE
//                控制器没开 modem sleep,CONFIG_BT_CTRL_SLEEP_MODE_EFF=0),
//                Wi-Fi 也会因为错过 beacon 而掉线。
//
// 早先这两件事写在一个分支里,于是"为了保住蓝牙链路而不睡"顺带把背光也一起
// 保住了 —— 而蓝牙基本一直连着,等于息屏这个功能整个没了。
static bool s_screen_off;

// 唤醒那一次按下产生的后续事件也要吞掉。
//
// 不吞的话,用户"按一下看看屏幕"会顺带把菜单翻一格、或者直接进了某个应用 ——
// 唤醒和操作是两件事,第一下只该负责点亮。
static bool s_wake_swallow;

// 把屏点回来。返回 true 表示这一次确实是从息屏状态唤醒的。
static bool wake_screen(void)
{
    if (!s_screen_off) return false;
    s_screen_off = false;
    s_wake_swallow = true;
    // 恢复成**用户配置的**亮度,不是写死的 100 —— 写死会把配套 app 上刚调好
    // 的亮度悄悄顶掉,而且只在息屏唤醒之后才发生,很难联想到是这里干的。
    bsp_display_backlight((uint8_t)device_config_brightness());
    s_last_activity_us = esp_timer_get_time();
    return true;
}

static void on_walkie_activity(bool receiving)
{
    if (receiving) wake_screen_for_notify();
}

static void wake_screen_for_notify(void)
{
    if (!s_screen_off) return;
    s_screen_off = false;
    bsp_display_backlight((uint8_t)device_config_brightness());
    s_last_activity_us = esp_timer_get_time();
}

#define USB_KEEPALIVE_PERIOD_MS 1000

// Idle home/settings screens may turn off their backlight. Radio power is
// managed by ESP-IDF's automatic PM, which observes the controller's locks.
static void idle_sleep_check(void)
{
    bool browsing_menu = (s_view == VIEW_TOP_MENU || s_view == VIEW_SETTINGS);
    if (!browsing_menu || usb_serial_jtag_is_connected()) return;

    int64_t idle_us = esp_timer_get_time() - s_last_activity_us;
    if (idle_us < (int64_t)CONFIG_IDLE_SLEEP_TIMEOUT_SEC * 1000000) return;

    // ---- 第一步:息屏。跟射频无关,任何情况下都做 ----
    if (!s_screen_off) {
        s_screen_off = true;
        bsp_display_backlight(0);
        ESP_LOGI(TAG, "闲置 %d 秒,息屏", CONFIG_IDLE_SLEEP_TIMEOUT_SEC);
    }

    // A disconnected BLE controller is still advertising. Manual light sleep
    // ignores its PM locks and can interrupt the controller or I2S DMA. Keep
    // advertising available with the screen off; automatic PM honors locks.
}

// 配套 app 可以在任何时刻直接把固件推过来 —— 用户那一刻可能正停在任何界面
// 上(BLE 是常驻的,不再要求先进"应用商店"页)。这里把界面自动切到安装进度
// 页,否则屏幕上什么都不显示,用户只会看到设备"莫名其妙卡了一下然后重启"。
//
// 只负责"没在应用商店页时切过去";已经在那一页的话,页面自己的 tick 会处理
// 列表→进度的切换,这里不重复干预。
static void install_push_check(void)
{
    if (s_view == VIEW_APPSTORE || !appstore_transfer_is_installing()) return;
    if (!bsp_lvgl_lock(500)) return;

    ESP_LOGI(TAG, "检测到对端推送安装,自动切到应用商店进度页");
    switch (s_view) {
    case VIEW_CODEX:         demo_codex_exit();      break;
    case VIEW_REMOTE:        demo_remote_exit();     break;
    case VIEW_TOP_MENU:      lv_obj_delete(s_top_scr);      s_top_scr = NULL;      break;
    case VIEW_CONNECTIONS:   lv_obj_delete(s_trust_scr);    s_trust_scr = NULL;    break;
    case VIEW_SETTINGS:      demo_settings_exit(); break;
    case VIEW_WIFI:          demo_wifi_exit(); break;
    default: break;
    }
    s_view = VIEW_APPSTORE;
    demo_appstore_enter();
    bsp_lvgl_unlock();
    // 固件安装是要看进度的,屏幕黑着等于没有进度可看 —— 而这一页是电脑那边
    // 主动推过来的,用户此刻很可能正好没在碰设备、屏幕已经息了。
    wake_screen();
}

// 电脑推来新的应用清单时,如果用户正停在首屏,要立刻重绘 —— 否则在应用
// 商店里装完一个应用,退回首屏却看不到它,得再退进一次才出现。
static void manifest_check(void)
{
    static uint32_t seen;
    uint32_t now = remote_ui_manifest_revision();
    if (now == seen) return;
    seen = now;
    if (s_view != VIEW_TOP_MENU || !s_top_scr) return;
    if (!bsp_lvgl_lock(500)) return;
    top_menu_refresh();
    bsp_lvgl_unlock();
}

// USB 在线守护:插着 USB 时保持电源管理不进入自动 light sleep,
// 并在重新枚举后把背光恢复为全亮。状态变化时才操作,避免干扰用户调光。
// 同时复用这个每秒一次的循环顺带检查菜单闲置自动休眠。
static void usb_keepalive_task(void *arg)
{
    (void)arg;
    bool prev = usb_serial_jtag_is_connected();
    if (prev && s_usb_pm_lock) {
        esp_pm_lock_acquire(s_usb_pm_lock);
    }
    for (;;) {
        bool now = usb_serial_jtag_is_connected();
        if (now != prev) {
            ESP_LOGI(TAG, "USB 状态变化: %s", now ? "connected" : "disconnected");
            if (now) {
                // 插上 USB 说明有人在跟这台设备打交道,点亮屏幕。
                // wake_screen() 会恢复成用户配置的亮度;要是本来就亮着,
                // 它什么都不做。
                if (atomic_load(&s_system_ready) && !wake_screen()) {
                    bsp_display_backlight((uint8_t)device_config_brightness());
                }
                if (s_usb_pm_lock) esp_pm_lock_acquire(s_usb_pm_lock);
            } else {
                if (s_usb_pm_lock) esp_pm_lock_release(s_usb_pm_lock);
            }
            prev = now;
        }
        // This task starts before peripherals, trust state and LVGL exist.
        // Its early job is only the USB PM lock; no page may be touched yet.
        if (atomic_load(&s_system_ready)) {
            install_push_check();
            manifest_check();
            device_trust_tick();
            trust_ui_check();
            idle_sleep_check();
            static unsigned health_ticks;
            if (++health_ticks == 60) {
                health_ticks = 0;
                ESP_LOGI(TAG, "运行健康: housekeeping剩余栈=%u bytes, 最小空闲堆=%u bytes",
                         (unsigned)uxTaskGetStackHighWaterMark(NULL),
                         (unsigned)esp_get_minimum_free_heap_size());
            }
        }
        vTaskDelay(pdMS_TO_TICKS(USB_KEEPALIVE_PERIOD_MS));
    }
}

// 刷新顶层三张卡片的文字和选中态。
static void top_menu_refresh(void) {
    int count = top_row_count();
    if (s_top_sel >= count) s_top_sel = count - 1;
    if (s_top_sel < 0) s_top_sel = 0;

    int apps = remote_ui_app_count();
    for (int i = 0; i < TOP_MAX_ROWS; i++) {
        if (i >= count) {
            lv_obj_add_flag(s_top_cards[i], LV_OBJ_FLAG_HIDDEN);
            continue;   // 图标是卡片的子对象,卡片藏了它自然跟着藏
        }
        lv_obj_remove_flag(s_top_cards[i], LV_OBJ_FLAG_HIDDEN);

        // 应用:陶土橙的 ▶ + 正常亮度的名字 —— "可以打开的东西"。
        // 设备功能:鼠尾草绿的下载/刷新图标 + 压暗一档的名字 —— "对设备做的事"。
        // 图标和配色一起分开这两类,一眼就能看出来,不用逐行读文字。
        bool is_app = (i < apps);
        // 应用的图标由配套 app 决定(用户可以在那边挑),没给就退回默认的 ▶。
        const char *icon = is_app ? remote_ui_app_icon(i) : TOP_FIXED_ICONS[i - apps];
        if (!icon[0]) icon = LV_SYMBOL_PLAY;
        lv_label_set_text(s_top_icons[i], icon);
        lv_obj_set_style_text_color(s_top_icons[i],
                                    lv_color_hex(is_app ? UI_ACCENT : UI_SAGE), 0);
        lv_obj_set_style_text_color(s_top_rows[i],
                                    lv_color_hex(is_app ? UI_INK : UI_INK_SOFT), 0);

        const char *hint = top_row_hint(i);
        if (hint[0]) {
            lv_label_set_text_fmt(s_top_rows[i], "%s  %s", top_row_name(i), hint);
        } else {
            lv_label_set_text(s_top_rows[i], top_row_name(i));
        }
        ui_pixel_set_selected(s_top_cards[i], i == s_top_sel, true);
    }
}

static void enter_top_menu(void) {
    s_view = VIEW_TOP_MENU;
    s_top_scr = ui_pixel_screen_create("FoloToy");

    // 首屏项数是变的(已安装应用 + 两个固定项),所以按上限建好卡片,
    // top_menu_refresh() 再按当前实际项数显示/隐藏。
    //
    // 行距按 TOP_MAX_ROWS 全满算(上面那条 _Static_assert 守着)。起点从 40
    // 提到 8 是因为首屏没有标题,原来那段空白纯属浪费。
    for (int i = 0; i < TOP_MAX_ROWS; i++) {
        int y = TOP_ROW_TOP + i * TOP_ROW_STEP;
        s_top_cards[i] = ui_pixel_panel_create(s_top_scr, 14, y, 212, TOP_ROW_H, UI_PAPER);
        // 图标单独一个 label:它要用 montserrat(FontAwesome 码位在那儿),
        // 而名字要用中文字库,两种字体没法放在同一个 label 里。
        s_top_icons[i] = lv_label_create(s_top_cards[i]);
        lv_obj_set_style_text_font(s_top_icons[i], &lv_font_montserrat_14, 0);
        lv_obj_align(s_top_icons[i], LV_ALIGN_LEFT_MID, 2, 0);

        s_top_rows[i] = lv_label_create(s_top_cards[i]);
        lv_obj_set_style_text_font(s_top_rows[i], &lv_font_ui_cn_14, 0);
        lv_obj_set_style_text_color(s_top_rows[i], lv_color_hex(UI_INK), 0);
        lv_obj_align(s_top_rows[i], LV_ALIGN_LEFT_MID, 24, 0);
    }

    lv_obj_t *foot = ui_pixel_label(s_top_scr, "确定进入  APP长按卸载",
                                    &lv_font_ui_cn_14, UI_MUTED);
    lv_obj_align(foot, LV_ALIGN_BOTTOM_MID, 0, -8);

    top_menu_refresh();
    lv_screen_load(s_top_scr);
}

// 按键回调运行在 button 组件的任务里,操作 LVGL 必须加锁。
// 全局逃生手势:在 appslot 应用里,任何界面下按住"确定"不放约 3 秒,直接
// 回到 factory 启动器。
//
// 为什么必须有这个:返回启动器原本只挂在"顶层菜单长按确定"这一条路径上,
// 也就是说它依赖每个应用都老实实现了"长按确定逐级返回"。一个应用只要漏掉
// 这一条(比如做成单一全屏界面、自己吃掉所有按键),用户就再也回不去了 ——
// 而且 UP 键进 Recovery 也救不回来:Recovery 不会清 bootflag,重启后
// bootloader 依然跳向那个应用,最后只能接 USB 用 esptool 擦。
//
// 所以这条路径放在按键分发的最上游、应用自己的 handler 之前,应用在结构上
// 就无法把它吃掉。这是给第三方应用开发者的安全网,不是给用户的常用操作。
#define ESCAPE_HOLD_TICKS 6   // BSP_BTN_HOLD 的节拍约 500ms,6 拍 ≈ 3 秒

static void on_key(bsp_btn_t btn, bsp_btn_ev_t ev, void *user) {
    (void)user;
    if (!atomic_load(&s_system_ready)) return;
    s_last_activity_us = esp_timer_get_time();

    // 息屏状态下的第一下只负责点亮屏幕,不往下传。
    if (wake_screen()) return;
    if (s_wake_swallow) {
        // 唤醒那一次按下还会接着产生 CLICK / LONG / LONG_UP,一并吞掉,
        // 松手之后才恢复正常。否则"按一下看看屏幕"会顺带翻一格菜单。
        if (ev == BSP_BTN_CLICK || ev == BSP_BTN_LONG_UP) s_wake_swallow = false;
        return;
    }

    // 有通知钉着时,任何键都只负责关掉它,并且吞掉不往下传。
    //
    // 这样就不需要给通知**分配**任何手势 —— 上/下/确定的单击双击已经被
    // 各个应用的 handleKey 占满了,再抢一个必然跟某个应用打架。通知只是
    // 把所有手势临时借走一次。跟上面 s_wake_swallow 是同一个思路。
    if (ui_notify_is_pinned()) {
        if (bsp_lvgl_lock(500)) {
            ui_notify_dismiss();
            bsp_lvgl_unlock();
        }
        return;
    }

    // Pairing confirmation is a modal physical-presence check. While it is
    // visible no underlying app receives keys: OK accepts, UP rejects.
    device_trust_snapshot_t trust_snapshot;
    device_trust_snapshot(&trust_snapshot);
    if (trust_snapshot.confirmation_pending) {
        if (btn == BSP_BTN_OK && ev == BSP_BTN_CLICK) {
            device_trust_confirm_pairing(true);
        } else if (btn == BSP_BTN_UP && ev == BSP_BTN_CLICK) {
            device_trust_confirm_pairing(false);
        }
        return;
    }

    if (s_running_from_appslot && btn == BSP_BTN_OK) {
        static int hold_ticks;
        if (ev == BSP_BTN_HOLD) {
            if (++hold_ticks >= ESCAPE_HOLD_TICKS) {
                hold_ticks = 0;
                ESP_LOGI(TAG, "全局逃生手势:长按确定,返回 factory 启动器");
                return_to_launcher_from_appslot();   // 内部 esp_restart(),不返回
            }
        } else {
            hold_ticks = 0;   // 松开或换成别的事件就重新计数,避免误触
        }
    }

    if (!bsp_lvgl_lock(500)) return;

    switch (s_view) {
    case VIEW_CODEX:
        if (btn == BSP_BTN_OK && ev == BSP_BTN_LONG) {     // 返回顶层菜单
            demo_codex_exit();
            enter_top_menu();
        } else {
            demo_codex_key(btn, ev);
        }
        break;

    case VIEW_REMOTE:
        if (btn == BSP_BTN_OK && ev == BSP_BTN_LONG) {     // 返回顶层菜单
            demo_remote_exit();
            enter_top_menu();
        } else {
            demo_remote_key(btn, ev);
        }
        break;

    case VIEW_APPSTORE:
        if (btn == BSP_BTN_OK && ev == BSP_BTN_LONG) {
            demo_appstore_exit();
            s_view = VIEW_SETTINGS;
            demo_settings_enter();
        } else {
            demo_appstore_key(btn, ev);
        }
        break;

    case VIEW_CONNECTIONS:
        if (btn == BSP_BTN_OK && ev == BSP_BTN_LONG) {
            lv_obj_delete(s_trust_scr);
            s_trust_scr = NULL;
            s_view = VIEW_SETTINGS;
            demo_settings_enter();
            break;
        }
        if ((btn == BSP_BTN_UP || btn == BSP_BTN_DOWN) &&
            (ev == BSP_BTN_PRESS || ev == BSP_BTN_HOLD)) {
            int count = 2 + device_trust_count();
            s_trust_sel = (btn == BSP_BTN_UP)
                    ? (s_trust_sel + count - 1) % count
                    : (s_trust_sel + 1) % count;
            trust_connections_refresh();
        }
        if (btn == BSP_BTN_OK && ev == BSP_BTN_CLICK) {
            if (s_trust_sel == 0) {
                device_trust_disconnect_current();
            } else if (s_trust_sel == 1) {
                device_trust_open_pairing_window();
            } else if (s_trust_sel >= 2) {
                device_trust_snapshot_t snapshot;
                char id[DEVICE_TRUST_ID_MAX + 1];
                device_trust_snapshot(&snapshot);
                if (device_trust_companion(s_trust_sel - 2, id, sizeof(id),
                                           NULL, 0, NULL) &&
                    (!snapshot.authorized ||
                     strcmp(id, snapshot.companion_id) != 0)) {
                    device_trust_handoff(s_trust_sel - 2);
                }
            }
            trust_connections_refresh();
        }
        if (btn == BSP_BTN_OK && ev == BSP_BTN_DOUBLE && s_trust_sel >= 2) {
            device_trust_forget(s_trust_sel - 2);
            trust_connections_refresh();
        }
        break;

    case VIEW_WIFI:
        if (btn == BSP_BTN_OK && ev == BSP_BTN_LONG) {
            demo_wifi_exit();
            s_view = VIEW_SETTINGS;
            demo_settings_enter();
        } else {
            demo_wifi_key(btn, ev);
        }
        break;

    case VIEW_SETTINGS:
        if (btn == BSP_BTN_OK && ev == BSP_BTN_LONG) {
            if (demo_settings_back()) {
                demo_settings_exit();
                enter_top_menu();
            }
        } else {
            demo_settings_key(btn, ev);
            settings_destination_t destination = demo_settings_take_destination();
            if (destination == SETTINGS_DEST_NONE) break;
            demo_settings_exit();
            if (destination == SETTINGS_DEST_WIFI) {
                s_view = VIEW_WIFI;
                demo_wifi_enter();
            } else if (destination == SETTINGS_DEST_FIRMWARE) {
                s_view = VIEW_APPSTORE;
                demo_appstore_enter();
            } else if (destination == SETTINGS_DEST_CONNECTIONS) {
                enter_connections();
            }
        }
        break;

    case VIEW_TOP_MENU:
        // MANIFEST 在 NimBLE 任务里落地，而常规重绘由 housekeeping 每秒轮询。
        // 因此装卸后的短窗口里，屏幕还可能画着旧行，但
        // remote_ui_app_count() 已经是新值。若此时直接按确定，旧清单里的最后
        // 一个 App 行会被当成固定的“应用商店”行，发送 0xFE；旧下标也可能在
        // companion 的新清单里指向另一个应用。每个首屏按键先按最新清单重绘，
        // 保证用户看到的行和下面解释下标时使用的是同一版列表。
        top_menu_refresh();

        // 从 appslot(应用商店装的应用)启动时,顶层菜单已经是"最上面一层",
        // 再长按确定就是明确要退出这个应用、回到 factory 的启动器 —— 跟
        // VIEW_DEMO/VIEW_CODEX/VIEW_APPSTORE 里"长按确定退一层"是同一个
        // 手势,只是在顶层这里再多退一级(退到另一个分区、重启)。跑在
        // factory 本身时顶层菜单没有更上一级可退,长按确定不做任何事。
        if (btn == BSP_BTN_OK && ev == BSP_BTN_LONG) {
            if (s_running_from_appslot) {
                return_to_launcher_from_appslot();
            } else if (s_top_sel < remote_ui_app_count()) {
                // 卸载请求交给 companion 处理。设备不先删本地缓存，等对端按
                // MANIFEST 通道回推权威清单，断链时也不会出现两端各一份状态。
                remote_ui_uninstall_app((uint8_t)s_top_sel);
            }
            break;
        }
        if ((btn == BSP_BTN_UP || btn == BSP_BTN_DOWN) &&
            (ev == BSP_BTN_PRESS || ev == BSP_BTN_HOLD)) {
            int count = top_row_count();
            s_top_sel = (btn == BSP_BTN_UP)
                    ? (s_top_sel + count - 1) % count
                    : (s_top_sel + 1) % count;
            top_menu_refresh();
        }
        if (btn == BSP_BTN_OK && ev == BSP_BTN_CLICK) {
            lv_obj_delete(s_top_scr);
            s_top_scr = NULL;
            int apps = remote_ui_app_count();
            if (s_top_sel < apps) {
                // 选中的是一个已安装应用:告诉电脑打开它,然后进远程界面等
                // 它推屏。没连电脑的话远程界面会显示"等待连接",用户至少
                // 知道这个应用需要电脑,而不是按下去毫无反应。
                remote_ui_open_app((uint8_t)s_top_sel);
                s_view = VIEW_REMOTE;
                demo_remote_enter();
            } else if (s_top_sel - apps == TOP_FIXED_STORE) {
                // 应用商店本身也是一屏由电脑推的界面。
                remote_ui_open_app(REMOTE_UI_OPEN_STORE);
                s_view = VIEW_REMOTE;
                demo_remote_enter();
            } else if (s_top_sel - apps == TOP_FIXED_SETTINGS) {
                s_view = VIEW_SETTINGS;
                demo_settings_enter();
            }
        }
        break;
    }
    bsp_lvgl_unlock();
}

void app_main(void) {
    ESP_LOGI(TAG, "FoloToy AI Passport BSP demo 启动");
    ESP_LOGI(TAG, "复位原因: %d (power=1 software=3 panic=4 watchdog=5/6/7 brownout=9)",
             (int)esp_reset_reason());

    const esp_partition_t *running = esp_ota_get_running_partition();
    s_running_from_appslot = running && strcmp(running->label, "appslot") == 0;
    ESP_LOGI(TAG, "当前运行分区: %s", running ? running->label : "(未知)");

    // 启动阶段全程只开动态调频,不开 light sleep —— 原因见 app_main 末尾注释。
    esp_pm_config_t pm_cfg = {
        .max_freq_mhz = 160,
        .min_freq_mhz = 80,
        .light_sleep_enable = false,
    };
    esp_err_t pm_cfg_err = esp_pm_configure(&pm_cfg);
    if (pm_cfg_err != ESP_OK) {
        ESP_LOGW(TAG, "PM 动态调频配置失败(%s)", esp_err_to_name(pm_cfg_err));
    }

    esp_err_t pm_err = esp_pm_lock_create(ESP_PM_NO_LIGHT_SLEEP, 0,
                                          "usb_keepalive", &s_usb_pm_lock);
    if (pm_err != ESP_OK) {
        ESP_LOGW(TAG, "PM lock 创建失败(%s),仍按无自动休眠方式运行",
                 esp_err_to_name(pm_err));
        s_usb_pm_lock = NULL;
    }

    // 尽早启动 usb_keepalive_task,让它赶在下面这堆外设初始化之前就把锁
    // 持住(USB 插着时)。之前这个任务是在整个 app_main 快结束时才创建的,
    // 等于初始化阶段完全没有这层保护,是导致下面这条 bug 的另一半原因。
    if (xTaskCreate(usb_keepalive_task, "usb_keepalive", HOUSEKEEPING_STACK_BYTES,
                    NULL, 5, NULL) != pdPASS) {
        ESP_LOGE(TAG, "USB keepalive 任务创建失败");
    }

    esp_sleep_wakeup_cause_t wakeup = esp_sleep_get_wakeup_cause();
    if (wakeup != ESP_SLEEP_WAKEUP_UNDEFINED) {
        ESP_LOGI(TAG, "休眠唤醒原因: %d", wakeup);
    }

    bsp_i2c_init();
    bsp_i2c_scan();

    // 屏幕是本 demo 的 UI 载体,失败就没有菜单可言 —— 打清楚日志后退出,
    // 不做"串口菜单"降级(那会让本文件复杂一倍,违背参考示例的初衷)。
    if (bsp_display_init() != ESP_OK || !bsp_lvgl_init()) {
        ESP_LOGE(TAG, "显示/LVGL 初始化失败,demo 无法继续。"
                      "检查 SPI 接线(MOSI=%d SCLK=%d CS=%d DC=%d BL=%d)",
                 BSP_LCD_MOSI, BSP_LCD_SCLK, BSP_LCD_CS, BSP_LCD_DC, BSP_LCD_BL);
        return;
    }
    bsp_display_backlight(100);

    // 配置要先读出来:init_shared_hardware() 里播开机音效,而音效放完需要把
    // 音量恢复成用户配置的值 —— 那个值得先在手上。
    device_config_init();
    device_trust_init();

    init_shared_hardware();

    // 配置先于 BLE 起来:配置服务本身是 BLE 的一个 service,而且 Wi-Fi 凭据
    // 这类值在后面页面初始化时就可能被读到。
    apply_device_config();   // 把存下来的亮度落到硬件上(音量交给开机音效收尾)
    if (xTaskCreate(config_watch_task, "cfg_watch", 4096, NULL, 3, NULL) != pdPASS) {
        ESP_LOGE(TAG, "配置任务创建失败");
    }

    // BLE 常驻:所有模块先把自己的 GATT service 注册进来,再一次性把协议栈
    // 拉起来。注册必须早于 ble_hub_init() —— NimBLE 在 ble_gatts_count_cfg()
    // 时就要看到全部 service,之后再加不会生效也不会报错,只会表现为"对端
    // 怎么也发现不了这个特征值"。
    //
    // 常驻的意义:配套 app 在任何界面下都能连上并直接推送安装,不需要用户先
    // 在设备上戳进"应用商店"页面等着。
    // Wi-Fi 归一个模块管(见 wifi_mgr.h)。没有保存凭据时保持惰性；已有凭据
    // 则在整机和 BLE 都就绪后自动恢复上次连接。
    wifi_mgr_init(report_device_status);
    device_config_set_cmd_handler(on_config_cmd);
    device_config_set_status_hook(report_status_on_subscribe);

    device_config_ble_register();
    device_trust_register();
    remote_ui_register();
    codex_ble_register();
    appstore_transfer_register();
    walkie_audio_register();
    walkie_audio_init();
    walkie_audio_set_activity_hook(on_walkie_activity);
    ble_hub_init();
    appstore_transfer_init();

    // 状态栏建在 lv_layer_top() 上,跟具体 screen 无关,所以只在这里建一次;
    // 放在第一屏之前,免得开机瞬间闪一下没有状态栏的画面。
    if (bsp_lvgl_lock(1000)) {
        ui_statusbar_init();
        ui_notify_init();
        enter_top_menu();
        bsp_lvgl_unlock();
        s_last_activity_us = esp_timer_get_time();
        atomic_store(&s_system_ready, true);
    }

    if (device_config_has_wifi()) {
        if (wifi_mgr_connect(NULL, NULL)) {
            ESP_LOGI(TAG, "已提交上次保存的 Wi-Fi 自动连接");
        } else {
            ESP_LOGW(TAG, "无法提交 Wi-Fi 自动连接,可在设置中重新配置");
        }
    }

    // ⚠ 到这里所有外设(I2C/显示/LVGL/按键/音频/电量计)都已初始化完毕,
    // 才是打开 light sleep 的安全时机。实测过提前开:
    //   1) 一开始就开,会在 bsp_i2c_scan() 期间把 I2C 挂死——ESP-IDF v5.5.3
    //      的 i2c_master_probe() 内部完全没有 acquire/release 任何 pm_lock
    //      (这跟走设备句柄的 i2c_master_transmit() 不一样,那个在
    //      s_i2c_transaction_start() 里会正确加锁),扫 128 个地址期间只要
    //      真的睡过去一次,I2C 外设状态就丢了,下一次探测直接卡死。
    //   2) 挪到 bsp_i2c_scan() 之后开,I2C 那关是过了,但当时 usb_keepalive_task
    //      还没创建(在这次改之前,它是本函数最后才起的),USB 插着也没人持锁
    //      挡住休眠,又在紧接着的 bsp_display_init()/bsp_lvgl_init() 撞上了同一
    //      类"事务被 light sleep 打断"的问题。
    //   另外 ESP32-C3 本身还有一个已知问题(espressif/esp-idf#8507):light sleep
    //   会打断 USB-Serial-JTAG/CDC 连接——这也是为什么 usb_keepalive_task 必须
    //   赶在这之前就跑起来、把锁持住,USB 插着时才能真正挡住 light sleep。
    // 现在的顺序是:先把 usb_keepalive_task 提到最前面创建、全部外设初始化期间
    // 都不开 light sleep,等一切就绪、真正进入空闲循环前才打开——这样启动阶段
    // 完全不会被打断,USB 插着时也有锁保护,只有断开 USB 真正闲下来才会休眠。
    pm_cfg.light_sleep_enable = true;
    pm_cfg_err = esp_pm_configure(&pm_cfg);
    if (pm_cfg_err != ESP_OK) {
        ESP_LOGW(TAG, "PM light sleep 配置失败(%s)", esp_err_to_name(pm_cfg_err));
    }

    ESP_LOGI(TAG, "就绪:首屏 %d 项(已安装应用 %d 个 + 固定项 %d)",
             top_row_count(), remote_ui_app_count(), TOP_FIXED_COUNT);

    // 走到这里说明屏幕、按键、菜单全都起来了,系统确实可用 —— 这时才有资格
    // 向 bootloader 确认"appslot 应用启动成功",把启动尝试计数清零。
    if (s_running_from_appslot) {
        confirm_appslot_boot_ok();
    }
}
