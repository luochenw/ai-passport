// main/boot_image.h —— 开机画面(可选)。
#pragma once

/// 把开机画面铺满整屏。没有配开机图时什么都不做。
///
/// 要在 bsp_lvgl_init() 之后、点亮背光前后调用都行 —— 内部自己加 LVGL 锁。
void boot_image_show(void);
