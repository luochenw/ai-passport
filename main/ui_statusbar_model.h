// main/ui_statusbar_model.h —— 状态栏里与 LVGL 无关的显示规则。
#pragma once

// Bluetooth SIG 官方品牌蓝。状态栏只在已连接时使用，未连接仍沿用主题默认色。
#define UI_STATUSBAR_BLE_CONNECTED_COLOR 0x0082FCu

// Wi-Fi 连上后用纯白，避免主题暖白让连接态看起来仍像禁用态。
#define UI_STATUSBAR_WIFI_CONNECTED_COLOR 0xFFFFFFu
