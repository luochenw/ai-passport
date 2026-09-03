// main/ui_statusbar.c —— 顶部状态栏的实现。见 ui_statusbar.h 的架构说明。
#include "ui_statusbar.h"

#include "bsp_battery.h"
#include "ble_hub.h"
#include "device_config.h"
#include "ui_pixel.h"
#include "wifi_mgr.h"

#include "driver/usb_serial_jtag.h"
#include "esp_log.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "lvgl.h"

#include <stdio.h>
#include <string.h>
#include <time.h>

static const char *TAG = "statusbar";

#define SB_PAD_X      10   // 左右边距
#define SB_GAP         8   // 图标之间的间距

// 电量采样周期。10 秒足够 —— 电池百分比不会比这更快地变化,而每次采样都是
// 一次 I2C 往返。
#define SB_BATT_PERIOD_MS 10000

static lv_obj_t *s_bar;
static lv_obj_t *s_batt;
static lv_obj_t *s_ble;
static lv_obj_t *s_wifi;
static lv_obj_t *s_clock;
static lv_timer_t *s_timer;

// ---- 充电判断 --------------------------------------------------------------
//
// ⚠ 这块板子**没有**充电状态信号,充电与否只能推断。
//
// 硬件上没有把充电 IC 的状态脚接到 MCU(bsp_pins.h 里根本没有这一项,GPIO 也
// 已经用满了),而 CW2017 是电压型电量计 —— 它不测电流,寄存器里也就没有
// "正在充电"这个位。所以只有两条间接证据:
//
//   1. USB 连着主机 → 一定在供电。usb_serial_jtag_is_connected() 是靠主机发的
//      SOF 帧判断的,插在电脑上必为真。
//      ⚠ 插一个不带数据的充电头时它是**假**的 —— 那种情况只能靠第 2 条。
//   2. 电量在涨 → 一定在充。CW2017 的 SOC 只有充电时才会上升。
//      代价是慢:充电时 SOC 大概几分钟才动一格,所以要跟足够久之前的值比。
//
// 两条都拿不到证据就认为没在充。宁可慢一点才认出来,也不要在没充电的时候
// 显示一个闪电 —— 那会让人以为插好了,回来发现根本没充上。
#define SB_CHARGE_WINDOW 18      // 18 × 10s = 3 分钟,SOC 涨一格的典型时间量级

static volatile bool s_charging;
static int s_soc_ring[SB_CHARGE_WINDOW];
static int s_soc_ring_i;
static int s_soc_ring_n;

// 每次采样后调一次,更新充电判断。只在 battery_task 里调(单线程)。
static void update_charging(int soc)
{
    if (soc < 0) {           // 没有电量计的板子,谈不上充电状态
        s_charging = false;
        return;
    }

    // 环形缓冲里存的是 SB_CHARGE_WINDOW 个采样点,拿"最老的那个"跟现在比。
    int oldest = (s_soc_ring_n >= SB_CHARGE_WINDOW) ? s_soc_ring[s_soc_ring_i] : -1;
    s_soc_ring[s_soc_ring_i] = soc;
    s_soc_ring_i = (s_soc_ring_i + 1) % SB_CHARGE_WINDOW;
    if (s_soc_ring_n < SB_CHARGE_WINDOW) s_soc_ring_n++;

    if (usb_serial_jtag_is_connected()) {
        s_charging = true;            // 插着电脑,一定在供电
    } else if (oldest >= 0 && soc > oldest) {
        s_charging = true;            // 电量在涨,一定在充
    } else if (oldest >= 0) {
        // 窗口攒满了、既没插 USB、电量也没涨 —— 没有证据,就当没在充。
        s_charging = false;
    }
    // oldest < 0(窗口还没攒满)且没插 USB:证据不足,保持上一次的判断,
    // 不要在开机头三分钟里乱跳。
}

// 电量由独立任务采样,状态栏定时器只读这个缓存。
//
// ⚠ 不要在 LVGL 定时器里直接调 bsp_battery_soc():LVGL 定时器跑在 lvgl_port
// 任务里、**持有 LVGL 锁**,而那个函数是一次 I2C 事务,芯片不应答时要等满
// 100ms 超时。等于每 10 秒把整个 UI 锁死 100ms —— 表现为按键偶尔"粘一下"。
// 采样搬到自己的任务里,定时器这边就只是读一个 int。
static volatile int s_soc = -1;

// 采样期间持住,挡住 main.c 那边的手动 light sleep。见头文件的说明。
static SemaphoreHandle_t s_sample_mux;

// 上一次真正画上去的内容。LVGL 的 lv_label_set_text() 不做比较,每次调用都会
// 重新分配并让这块区域失效重绘 —— 状态栏一秒刷一次,不比较的话就是一秒一次
// 无谓的重绘。
static char s_last_batt[16];
static char s_last_ble[8];
static char s_last_wifi[8];
static char s_last_clock[12];

static void battery_task(void *arg)
{
    (void)arg;
    for (;;) {
        // 只把**这一次 I2C 事务**圈起来,不要把 vTaskDelay 也圈进去 ——
        // 那样休眠端要等满 10 秒才可能拿到锁,等于永远睡不着。
        if (xSemaphoreTake(s_sample_mux, portMAX_DELAY) == pdTRUE) {
            int soc = bsp_battery_soc();
            s_soc = soc;
            xSemaphoreGive(s_sample_mux);
            update_charging(soc);
        }
        vTaskDelay(pdMS_TO_TICKS(SB_BATT_PERIOD_MS));
    }
}

bool ui_statusbar_pause_sampling(void)
{
    if (!s_sample_mux) return true;   // 状态栏还没起来,没有采样要挡
    // 200ms 足够等完一次 I2C 事务(超时上限 100ms)。等不到说明总线上有别的
    // 事在做,这一轮就别睡了。
    return xSemaphoreTake(s_sample_mux, pdMS_TO_TICKS(200)) == pdTRUE;
}

void ui_statusbar_resume_sampling(void)
{
    if (s_sample_mux) xSemaphoreGive(s_sample_mux);
}

// 显示项开关。配置里存的是一个逗号分隔的名字列表(键 sb.items),
// 比如 "battery,ble,time" —— 没列出来的就不显示。
//
// 用一个键装一份列表而不是四个布尔键:配置页上是一组复选框,一次性整体下发
// 比四次写入简单,设备这边也少三次 NVS 提交。
static bool item_on(const char *name)
{
    const char *list = device_config_get("sb.items", "battery,ble,wifi,time");
    size_t n = strlen(name);
    const char *p = list;
    while (*p) {
        while (*p == ',' || *p == ' ') p++;
        const char *start = p;
        while (*p && *p != ',') p++;
        size_t len = (size_t)(p - start);
        // 逐个 token 比,不能用 strstr —— 那样 "wifi" 会命中一个叫
        // "wifi_extra" 的项,加新项的时候会莫名其妙互相影响。
        if (len == n && strncmp(start, name, n) == 0) return true;
    }
    return false;
}

// 电量图标:按档位挑,而不是画一个自定义进度条。这块屏上 14px 高的条谁也看
// 不清,图标 + 数字更直接。
static const char *battery_symbol(int soc)
{
    if (soc >= 90) return LV_SYMBOL_BATTERY_FULL;
    if (soc >= 65) return LV_SYMBOL_BATTERY_3;
    if (soc >= 40) return LV_SYMBOL_BATTERY_2;
    if (soc >= 15) return LV_SYMBOL_BATTERY_1;
    return LV_SYMBOL_BATTERY_EMPTY;
}

// 只在文本真的变了才写回去,顺带把可见性一起处理掉。
static void set_item(lv_obj_t *label, char *cache, size_t cache_len,
                     bool visible, const char *text, uint32_t color)
{
    if (!visible) {
        lv_obj_add_flag(label, LV_OBJ_FLAG_HIDDEN);
        cache[0] = '\0';   // 下次显示出来时必定重写,不会命中过期的缓存
        return;
    }
    lv_obj_remove_flag(label, LV_OBJ_FLAG_HIDDEN);
    lv_obj_set_style_text_color(label, lv_color_hex(color), 0);
    if (strncmp(cache, text, cache_len) == 0) return;
    snprintf(cache, cache_len, "%s", text);
    lv_label_set_text(label, text);
}

// 左侧图标是按显示项动态排布的:关掉电量之后蓝牙要顶上来,不能留个空洞。
static void layout_left(void)
{
    int x = SB_PAD_X;
    lv_obj_t *items[] = { s_batt, s_ble, s_wifi };
    for (size_t i = 0; i < sizeof(items) / sizeof(items[0]); i++) {
        if (lv_obj_has_flag(items[i], LV_OBJ_FLAG_HIDDEN)) continue;
        lv_obj_set_pos(items[i], x, 0);
        lv_obj_update_layout(items[i]);
        x += lv_obj_get_width(items[i]) + SB_GAP;
    }
}

static void refresh(lv_timer_t *timer)
{
    (void)timer;

    // ---- 电量 ----
    int soc = s_soc;
    // 没有电量计的板子(bsp_battery_init() 返回 NOT_FOUND)读出来一直是 -1。
    // 那种情况下显示一个空的电池壳只会让人以为没电了,不如整项不显示。
    bool batt_on = item_on("battery") && soc >= 0;
    bool charging = s_charging;
    char batt[20] = "";
    uint32_t batt_color = UI_INK_SOFT;
    if (batt_on) {
        if (charging) {
            // 充电时用闪电取代电量档位图标,而不是并排画两个 —— 顶栏一共
            // 240px 还要放蓝牙/Wi-Fi/时间,并排会把后面的挤出去。
            // 绿色跟平时的暖灰拉开,一眼能看出状态变了。
            snprintf(batt, sizeof(batt), "%s %d%%", LV_SYMBOL_CHARGE, soc);
            batt_color = UI_SAGE;
        } else {
            snprintf(batt, sizeof(batt), "%s %d%%", battery_symbol(soc), soc);
            // 低电量标红。充电时不标红 —— 电量低但正在充,不是需要着急的事。
            batt_color = (soc <= 15) ? UI_RED : UI_INK_SOFT;
        }
    }
    set_item(s_batt, s_last_batt, sizeof(s_last_batt), batt_on, batt, batt_color);

    // ---- 蓝牙 ----
    bool ble_conn = ble_hub_is_connected();
    set_item(s_ble, s_last_ble, sizeof(s_last_ble),
             item_on("ble"), LV_SYMBOL_BLUETOOTH,
             ble_conn ? UI_ACCENT : UI_MUTED);

    // ---- Wi-Fi ----
    set_item(s_wifi, s_last_wifi, sizeof(s_last_wifi),
             item_on("wifi"), LV_SYMBOL_WIFI,
             wifi_mgr_is_connected() ? UI_SAGE : UI_MUTED);

    layout_left();

    // ---- 时间 ----
    //
    // 这台设备没有 RTC,断电就忘。时间由配套 app 通过配置通道下发(键 time =
    // UTC 秒,tzmin = 相对 UTC 的分钟偏移),main.c 的 apply_device_config()
    // 负责 settimeofday()。没同步过的时候显示 --:--,而不是显示 1970 年 —— 
    // 一个明显错误的时间比没有时间更容易让人误判。
    bool clock_on = item_on("time");
    char clock[12] = "--:--";
    if (clock_on) {
        time_t now = time(NULL);
        // 2020-01-01 之前一律当成"没同步过"。开机后 time() 从 0 开始走,
        // 光看非零判断不出来。
        if (now > 1577836800) {
            long tz = strtol(device_config_get("tzmin", "0"), NULL, 10);
            time_t local = now + tz * 60;
            struct tm tm_local;
            gmtime_r(&local, &tm_local);   // 偏移已经加过了,这里按 UTC 拆
            snprintf(clock, sizeof(clock), "%02d:%02d", tm_local.tm_hour, tm_local.tm_min);
        }
    }
    set_item(s_clock, s_last_clock, sizeof(s_last_clock), clock_on, clock, UI_INK_SOFT);
    if (clock_on) lv_obj_align(s_clock, LV_ALIGN_RIGHT_MID, -SB_PAD_X, 0);
}

void ui_statusbar_init(void)
{
    if (s_bar) return;

    // lv_layer_top():跟 screen 无关的一层,永远盖在当前 screen 上面。
    // 页面切换和 lv_obj_delete(scr) 都碰不到它,所以状态栏只建这一次。
    lv_obj_t *top = lv_layer_top();
    lv_obj_remove_flag(top, LV_OBJ_FLAG_SCROLLABLE);

    s_bar = lv_obj_create(top);
    lv_obj_remove_flag(s_bar, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_remove_flag(s_bar, LV_OBJ_FLAG_CLICKABLE);
    lv_obj_set_pos(s_bar, 0, 0);
    lv_obj_set_size(s_bar, 240, UI_STATUSBAR_H);
    lv_obj_set_style_radius(s_bar, 0, 0);
    lv_obj_set_style_pad_all(s_bar, 0, 0);
    // 纯黑,跟机身底色一致 —— 状态栏落在圆角取景框**外面**那一条上,
    // 视觉上属于机身而不是屏幕内容。
    lv_obj_set_style_bg_color(s_bar, lv_color_hex(0x000000), 0);
    lv_obj_set_style_border_width(s_bar, 0, 0);

    // 全部用 montserrat:这一条里只有符号和数字,没有中文。中文字库
    // (lv_font_ui_cn_14)里没有 FontAwesome 那段码位,用它图标会变成方框。
    const lv_font_t *font = &lv_font_montserrat_14;

    s_batt  = ui_pixel_label(s_bar, "", font, UI_INK_SOFT);
    s_ble   = ui_pixel_label(s_bar, LV_SYMBOL_BLUETOOTH, font, UI_MUTED);
    s_wifi  = ui_pixel_label(s_bar, LV_SYMBOL_WIFI, font, UI_MUTED);
    s_clock = ui_pixel_label(s_bar, "--:--", font, UI_INK_SOFT);
    lv_obj_align(s_batt,  LV_ALIGN_LEFT_MID, SB_PAD_X, 0);
    lv_obj_align(s_ble,   LV_ALIGN_LEFT_MID, SB_PAD_X, 0);
    lv_obj_align(s_wifi,  LV_ALIGN_LEFT_MID, SB_PAD_X, 0);
    lv_obj_align(s_clock, LV_ALIGN_RIGHT_MID, -SB_PAD_X, 0);

    s_sample_mux = xSemaphoreCreateMutex();
    if (!s_sample_mux) {
        // 建不出互斥量就干脆不采样。宁可状态栏少一项,也不要留一条会在
        // light sleep 里把 I2C 总线睡坏的路径。
        ESP_LOGE(TAG, "采样互斥量创建失败,电量项停用");
    } else {
        xTaskCreate(battery_task, "sb_batt", 2560, NULL, 2, NULL);
    }

    s_timer = lv_timer_create(refresh, 1000, NULL);
    refresh(NULL);
    ESP_LOGI(TAG, "状态栏已就绪");
}

void ui_statusbar_notify_config_changed(void)
{
    // 只在 LVGL 任务里改 UI。这个函数会被配置监听任务调到,那个任务没有
    // LVGL 锁 —— 所以这里不直接重画,而是把定时器的下一次触发提到现在。
    // lv_timer_ready() 本身只是置一个标志位,是安全的。
    if (s_timer) lv_timer_ready(s_timer);
}
