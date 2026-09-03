// Bootloader hook shared by every AI Passport community firmware derivative.
// Holding the UP-key ADC GPIO low for five seconds boots the factory-installed
// permanent Recovery image. This project never owns or writes that image.
//
// This file also carries this project's OWN, independent app-switching hook
// (unrelated to Recovery, added nowhere near it): if `main/demo_appstore.c`
// has written the APPSLOT_BOOT_MAGIC byte into the `bootflag` data partition,
// boot `appslot` instead of `factory` this one time. `main/main.c` clears that
// byte and reboots back to `factory` when the user long-presses OK at the top
// menu while running from `appslot`. Both new partitions live in the free gap
// between `cardid` (ends 0x35a000) and `recovery` (starts 0x700000) -- see
// `partitions.csv` -- so none of the ble-recovery-compatibility.md mandatory
// offsets/sizes for factory/cardid/recovery are touched.
#include "bootloader_common.h"
#include "bootloader_config.h"
#include "bootloader_utility.h"
#include "bootloader_flash_priv.h"
#include "esp_image_format.h"
#include "esp_log.h"

#define RECOVERY_BUTTON_GPIO  0
#define RECOVERY_HOLD_SECONDS 5
#define RECOVERY_OFFSET       0x700000
#define RECOVERY_SIZE         0x100000

// 必须跟 partitions.csv 里 bootflag/appslot 两行的偏移/大小完全一致,以及
// main/demo_appstore.c 写入时用的 magic 值完全一致(三处都是手写的裸常量,
// 因为 bootloader 阶段的构建看不到运行时 esp_partition 的分区表 API)。
#define APPSLOT_FLAG_OFFSET   0x35a000
#define APPSLOT_BOOT_MAGIC    0xA5
#define APPSLOT_OFFSET        0x360000
#define APPSLOT_SIZE          0x3a0000

// bootflag 分区的字节布局(整个分区只用到开头 8 字节,其余保留):
//   [0] magic    —— APPSLOT_BOOT_MAGIC 表示"下次启动去 appslot"
//   [4] attempts —— 已经尝试启动 appslot 多少次,还没被应用确认过
// 都放在各自 4 字节对齐的位置上,因为 bootloader_flash_read/write 要求地址、
// 长度、缓冲区三者都 4 字节对齐(不对齐会直接返回错误,不是读到脏数据)。
#define APPSLOT_ATTEMPTS_OFFSET (APPSLOT_FLAG_OFFSET + 4)
// 连续这么多次"跳过去了但应用没能确认自己起来了"就放弃,强制回 factory。
// esp_image_verify() 只能挡住镜像结构/校验和层面的损坏,挡不住"镜像完全合法、
// 但一跑起来就 panic / 看门狗复位"——那种情况同样会变成无限重启循环,而且
// 因为设备起不来、USB CDC 来不及枚举,连串口都不会出现,USB 也救不了。
#define APPSLOT_MAX_BOOT_ATTEMPTS 3

void bootloader_hooks_include(void)
{
}

void bootloader_after_init(void)
{
    if (bootloader_common_check_long_hold_gpio(
            RECOVERY_BUTTON_GPIO, RECOVERY_HOLD_SECONDS) == GPIO_LONG_HOLD) {
        ESP_LOGI("recovery_boot", "UP held: booting permanent recovery at 0x%x",
                 RECOVERY_OFFSET);
        bootloader_state_t state = { 0 };
        state.factory.offset = RECOVERY_OFFSET;
        state.factory.size = RECOVERY_SIZE;
        bootloader_utility_load_boot_image(&state, FACTORY_INDEX);
        return;
    }

    // bootloader_flash_read() requires the source address, the length AND the destination
    // buffer to all be 4-byte aligned; reading a single byte into a bare uint8_t fails
    // outright ("src_addr 0x35a000, size 0x1 or dest 0x3fcde3ff not 4-byte aligned"), the
    // read returns an error, and boot silently falls through to factory -- so a firmware
    // that installed and verified perfectly still never actually started. Read one aligned
    // word into an aligned buffer and pick the byte out of it instead. The flag lives at
    // the very start of the partition, so it is byte 0 of that word.
    uint32_t flag_word = 0;
    uint8_t flag = 0;
    if (bootloader_flash_read(APPSLOT_FLAG_OFFSET, &flag_word, sizeof(flag_word), true) == ESP_OK) {
        flag = (uint8_t)(flag_word & 0xFF);
    }
    if (flag == APPSLOT_BOOT_MAGIC) {
        // 启动尝试计数:每次真的要跳过去之前先 +1 写回 flash,应用成功跑起来
        // 后由 main.c 清零。所以这个计数的含义是"跳过去了、但应用从没确认过
        // 自己活着的次数"。连续超过上限就强制回 factory —— 这是 esp_image_verify()
        // 之外的第二道防线,专门挡"镜像合法但运行时崩溃"导致的无限重启。
        //
        // 计数写在 flash 而不是 RTC 内存里,是为了让掉电重插也保留 —— 崩溃循环
        // 常常伴随用户拔插电源,如果一掉电就清零,就永远达不到上限、永远救不回来。
        uint32_t attempts_word = 0;
        uint32_t attempts = 0;
        if (bootloader_flash_read(APPSLOT_ATTEMPTS_OFFSET, &attempts_word,
                                  sizeof(attempts_word), true) == ESP_OK) {
            attempts = attempts_word & 0xFF;
            if (attempts == 0xFF) attempts = 0;   // 擦除后的空白 flash 视为 0 次
        }

        if (attempts >= APPSLOT_MAX_BOOT_ATTEMPTS) {
            ESP_LOGE("appslot_boot",
                     "appslot failed to confirm boot %u times, falling back to factory",
                     (unsigned)attempts);
            return;
        }

        // 先记账再跳:顺序反了就等于没有保护 —— 跳转成功后 bootloader 不再有
        // 机会执行任何代码,崩溃重启回来时计数还是旧的,会永远循环下去。
        // bootloader_flash_erase_sector() 会把整个 4KB 扇区擦掉,所以 magic 也
        // 得跟着一起重写回去,不能只写计数那一个字。
        uint32_t rewrite[2] = { APPSLOT_BOOT_MAGIC, attempts + 1 };
        if (bootloader_flash_erase_sector(APPSLOT_FLAG_OFFSET / 0x1000) == ESP_OK) {
            bootloader_flash_write(APPSLOT_FLAG_OFFSET, rewrite, sizeof(rewrite), false);
        }

        // ⚠ 跳过去之前必须先自己校验一遍镜像,不能直接跳。
        // bootloader_utility_load_boot_image() 校验失败时不会返回、也不会退回
        // factory —— 它认定"没有可启动的分区"就直接复位,而复位后这个钩子又
        // 会再次读到同一个 bootflag、再次跳向同一个坏镜像,于是变成谁也打断
        // 不了的启动死循环:设备起不来,USB CDC 来不及枚举,串口都消失,只
        // 能靠物理按住 UP 键进 Recovery 才能救回来。一个传输过程中出问题的
        // 镜像不该有能力把设备变成砖。
        //
        // 先 esp_image_verify() 只校验不加载,失败就当作没设过这个标记,让下面
        // 什么都不做、原路正常启动 factory —— 用户回到启动器,还能重新安装。
        const esp_partition_pos_t appslot_pos = {
            .offset = APPSLOT_OFFSET,
            .size = APPSLOT_SIZE,
        };
        esp_image_metadata_t appslot_meta = { 0 };
        esp_err_t verify_err = esp_image_verify(ESP_IMAGE_VERIFY, &appslot_pos, &appslot_meta);
        if (verify_err != ESP_OK) {
            ESP_LOGE("appslot_boot",
                     "bootflag set but appslot image is invalid (err=0x%x), booting factory instead",
                     verify_err);
            return;
        }
        ESP_LOGI("appslot_boot", "bootflag set: booting appslot at 0x%x", APPSLOT_OFFSET);
        bootloader_state_t state = { 0 };
        state.factory.offset = APPSLOT_OFFSET;
        state.factory.size = APPSLOT_SIZE;
        bootloader_utility_load_boot_image(&state, FACTORY_INDEX);
    }
}
