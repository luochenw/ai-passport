// main/device_config.h —— 设备配置:一份所有应用共享的、跨应用切换不丢的设置。
//
// 为什么单独做一层
// ────────────────
// NVS 分区在 0x9000,**既不在 factory 里也不在 appslot 里**。这意味着写进
// NVS 的东西在换应用之后依然存在 —— 这正是"配置一次,所有应用都能用"能够
// 成立的物理基础,也是这个模块存在的全部理由。
//
// 谁来填这些值
// ────────────
// 主要由配套 app 通过 BLE 下发(见本文件末尾的 GATT 约定)。原因很实际:
// 这台设备只有三个按键,让用户在上面输入一个 Wi-Fi 密码是酷刑;而在电脑上
// 敲一行字是天经地义的事。设备端只保留只读展示和音量这类一维调节。
//
// ⚠ 凭据永远不进源码。仓库有密钥扫描,而且社区里的代码是公开的 —— Wi-Fi
// 密码、接口口令这类东西只能在运行期通过这条通道下发到 NVS。
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define DEVICE_CONFIG_STR_MAX 96

// 打开 NVS 命名空间并把已保存的值读进内存缓存。app_main 里调一次。
void device_config_init(void);

// 注册配置服务的 GATT service。必须在 ble_hub_init() 之前调用。
void device_config_ble_register(void);

// ---- 读:所有应用都可以直接用 ----------------------------------------------
// 返回的指针指向内部缓存,调用方不要持有过长时间(下一次配置下发会改写它)。
const char *device_config_wifi_ssid(void);
const char *device_config_wifi_password(void);
void device_config_wifi_copy(char *ssid, size_t ssid_size,
                             char *password, size_t password_size);
// 通用键值:给各个应用放自己的配置(比如某个应用的接口地址和口令)。
// key 建议用 "<应用名>.<字段>" 的形式,避免不同应用互相踩。
// 找不到时返回 fallback(可以是 NULL)。
const char *device_config_get(const char *key, const char *fallback);

int  device_config_volume(void);        // 0..100
bool device_config_boot_chime_enabled(void); // Default off; stored on Passport.
int  device_config_boot_chime_volume(void);  // Independent startup volume, default 20.
bool device_config_has_wifi(void);      // ssid 非空才算配过

// 屏幕亮度 0..100。
//
// ⚠ 下限被刻意钳在 DEVICE_CONFIG_MIN_BRIGHTNESS 而不是 0:背光真给 0 就是
// 全灭,而这台设备只有三个按键、没有任何本地入口能把亮度调回来 —— 在配套
// app 上把滑块拖到底就等于把屏幕永久关死,只能重刷固件。
#define DEVICE_CONFIG_MIN_BRIGHTNESS 10
int  device_config_brightness(void);

// ---- 写:一般由配套 app 下发触发,设备端只有音量会主动写 -------------------
void device_config_set_volume(int volume);
void device_config_set_brightness(int brightness);
bool device_config_set(const char *key, const char *value);

// Non-blocking local settings writes. The configuration worker drains them;
// button/LVGL callbacks must not perform NVS I/O.
bool device_config_request_set(const char *key, const char *value);
void device_config_process_pending(void);
void device_config_request_snapshot(void);
uint32_t device_config_write_failures(void);

// 配置变更计数。应用可以缓存这个值,发现变了就重新读一遍配置 —— 比每帧都
// 去 NVS 读要便宜得多,也不需要回调注册。
uint32_t device_config_revision(void);

// ---- 设备 -> 配套 app 的状态上报(STATUS 特征值,NOTIFY) -------------------
//
// 为什么必须有这条反向通道:配置页要显示"当前连了哪个 Wi-Fi""扫到了哪些
// AP""蓝牙连着谁",这些事实只有设备知道。原来的配置 service 只有 WRITE,
// 是纯单向的,那些界面在旧协议下根本不可能实现。
//
// 格式跟下发方向一致,也是文本行 "<key>=<value>\n",这样两端用同一套解析,
// 加字段不需要动协议版本号。
// 固件版本通过 `firmware.version=<esp_app_desc_t.version>` 上报；它来自根目录
// VERSION 和构建时的 Git 标识，不写入 NVS，也不允许对端修改。
//
// 一次可以推多行。超过一个 ATT 包会自动分片,对端靠结尾换行判断收齐。
// 返回 false 表示这一批没发出去。最常见的原因是 NimBLE 的 mbuf 池被占满
// (rc=6 / BLE_HS_ENOMEM)—— 连续快速 notify 时会真实发生,实测在推送 20 个
// Wi-Fi 扫描结果时必现。调用方拿到 false 应当**等一会儿再重试**,而不是当作
// 永久失败丢掉:mbuf 会随着已排队的包发出去而释放。
//
// ⚠ 重试的等待只能发生在**非 NimBLE 主机任务**里。在主机任务里睡等于挡住了
// 那些会释放 mbuf 的发送完成回调,越等越没有。
bool device_config_report(const char *lines);

// 便捷版:报一个键值对。
void device_config_report_kv(const char *key, const char *value);

// 对端是否已经订阅了状态通道。没订阅时上报是浪费,调用方可以先问一下。
bool device_config_status_ready(void);

// ---- 动作通道:cmd.* -------------------------------------------------------
//
// 有些东西从配套 app 发过来是**命令**而不是配置:"现在重新扫一遍 Wi-Fi"、
// "断开当前蓝牙连接"。它们没有"当前值"可言,存进 NVS 是错的 —— 存了之后
// 每次开机都会莫名其妙自己扫一次,而且 NVS 里会留下一堆语义为"曾经点过一次
// 按钮"的垃圾键。
//
// 约定:键名以 "cmd." 开头的一律**不落盘**,而是转成一次回调。
//   cmd.wifi=scan        重新扫描
//   cmd.wifi=connect     用当前 wifi.ssid / wifi.pass 连接
//   cmd.wifi=disconnect  断开
//
// 处理器由 main.c 注册,而不是让 device_config 直接调 wifi_mgr —— 配置层
// 不应该知道有 Wi-Fi 这回事,否则以后每加一种设备能力都要改这个文件。
typedef void (*device_config_cmd_fn)(const char *name, const char *arg);
void device_config_set_cmd_handler(device_config_cmd_fn fn);

// 对端刚订阅上状态通道时被调一次,用来补报那些 device_config 自己不知道的
// 状态(Wi-Fi 连着谁、扫到了什么)。
//
// 为什么要有这个钩子:对端订阅之后如果不补一份快照,它要等到下一次状态**变化**
// 才知道设备现在什么样 —— 而"一直连着同一个 Wi-Fi"恰恰是不会变化的,界面上
// 就会永远空着。同样地,这里用回调而不是让 device_config 直接去问 wifi_mgr,
// 是为了不让配置层认识具体的设备能力。
typedef void (*device_config_status_hook_fn)(void);
void device_config_set_status_hook(device_config_status_hook_fn fn);
