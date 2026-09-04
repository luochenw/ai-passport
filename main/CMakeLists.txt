# 开机画面是**可选的**:assets/boot_image.rgb565 被 .gitignore 挡着,因为它
# 通常是张私人照片,而这个仓库是公开的。文件不在就不嵌,boot_image.c 那边
# 会退化成空函数 —— 克隆下来照常能编译,不会因为少一个私人文件而挂掉。
#
# 自己要一张:tools/gen_boot_image.py <图片>
set(EMBEDDED_ASSETS "../assets/music/boot_chime.pcm")
if(EXISTS "${CMAKE_CURRENT_LIST_DIR}/../assets/boot_image.rgb565")
    list(APPEND EMBEDDED_ASSETS "../assets/boot_image.rgb565")
    set(BOOT_IMAGE_PRESENT TRUE)
    message(STATUS "boot image: enabled (assets/boot_image.rgb565)")
else()
    set(BOOT_IMAGE_PRESENT FALSE)
    message(STATUS "boot image: not configured, skipped")
endif()

idf_component_register(
    SRCS "main.c"
         "ui_font_cn_14.c"
         "ui_font_cn_20.c"
         "ui_pixel.c"
         "ui_statusbar.c"
         "ui_notify.c"
         "ui_pixel_math.c"
         "demo_display.c"
         "demo_button.c"
         "demo_audio.c"
         "demo_battery.c"
         "demo_radio.c"
         "demo_wifi.c"
         "demo_ble.c"
         "demo_low_power.c"
         "demo_status.c"
         "demo_codex.c"
         "demo_appstore.c"
         "appstore_transfer.c"
         "ble_hub.c"
         "remote_ui.c"
         "demo_remote.c"
         "device_config.c"
         "wifi_mgr.c"
         "boot_chime.c"
         "walkie_codec.c"
         "walkie_audio.c"
         "boot_image.c"
    INCLUDE_DIRS "."
    EMBED_FILES ${EMBEDDED_ASSETS}
    REQUIRES app_update bsp bt esp_driver_usb_serial_jtag esp_event esp_hw_support esp_netif esp_pm esp_timer esp_wifi nvs_flash spi_flash
)

# ⚠ 用 target_compile_definitions,不要用 add_compile_definitions。
# 后者是**目录级**属性,ESP-IDF 会把它序列化进 build_properties.temp.cmake,
# 那一步不带引号 —— 结果是 CMake 报一句
#   "Argument not separated from preceding token by whitespace"
# 然后整个 configure 失败,而错误信息完全指不到这里。
if(BOOT_IMAGE_PRESENT)
    target_compile_definitions(${COMPONENT_LIB} PRIVATE HAVE_BOOT_IMAGE=1)
endif()
