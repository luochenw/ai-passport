// main/appstore_transfer.c —— "应用商店"的传输层:目录条目分片重组、固件流式
// OTA 写入(队列 + 独立任务,把 flash 写入和蓝牙确认解耦)、批量确认/幂等重传
// 协议。界面在 demo_appstore.c,两者只通过 appstore_transfer.h 这个窄接口交互。
//
// BLE 协议栈本身不归这个文件管 —— 由 ble_hub 常驻持有,这里只注册自己的 GATT
// service 和连接事件观察者(见文件末尾的 appstore_transfer_register)。
//
// 两个特征值挂在同一个 service 下:
//   DATA(WRITE + WRITE_NO_RSP,对端 -> 设备):
//        六字节头(flags/kind/index u16/total u16)+ 分片。kind=FIRMWARE 时不
//        缓冲整条消息再分发(固件镜像有 MB 级,设备 RAM 装不下)—— 每个分片
//        收到就拷进队列,交给独立任务流式 esp_ota_write()。
//   CMD (INDICATE,设备 -> 对端):
//        三字节定长请求/通知,用来要目录、发起安装、上报进度和中止。
#include "appstore_transfer.h"
#include "ble_hub.h"
#include "demo.h"

#include "esp_log.h"
#include "esp_ota_ops.h"
#include "esp_partition.h"
#include "freertos/FreeRTOS.h"
#include "freertos/queue.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/util/util.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include <stdio.h>
#include <string.h>

static const char *TAG = "appstore_transfer";
static const char *DEVICE_NAME = "FoloPassport";   // 跟 demo_codex.c 同一个广播名

// "应用商店"协议专用的 Service/Characteristic UUID,与 demo_codex.c 那一套
// 完全独立(两边永远不会同时广播,但还是各给一套 UUID,避免混淆)。
// ⚠ 同 demo_codex.c 的提醒:NimBLE 的 BLE_UUID128_INIT(...) 按小端存储,跟
// CoreBluetooth 的 CBUUID(string:) 顺序相反 —— Mac 端直接用标准 UUID 字符
// 串,固件这边要把字符串的 16 字节整体倒过来写。
//   Service:   8C2E5A10-6B3D-4F8E-9A1C-2D7E6F4B3A90
//   DATA 特征: 8C2E5A11-6B3D-4F8E-9A1C-2D7E6F4B3A90
//   CMD  特征: 8C2E5A12-6B3D-4F8E-9A1C-2D7E6F4B3A90
static const ble_uuid128_t s_svc_uuid =
    BLE_UUID128_INIT(0x90, 0x3A, 0x4B, 0x6F, 0x7E, 0x2D, 0x1C, 0x9A,
                     0x8E, 0x4F, 0x3D, 0x6B, 0x10, 0x5A, 0x2E, 0x8C);
static const ble_uuid128_t s_data_uuid =
    BLE_UUID128_INIT(0x90, 0x3A, 0x4B, 0x6F, 0x7E, 0x2D, 0x1C, 0x9A,
                     0x8E, 0x4F, 0x3D, 0x6B, 0x11, 0x5A, 0x2E, 0x8C);
static const ble_uuid128_t s_cmd_uuid =
    BLE_UUID128_INIT(0x90, 0x3A, 0x4B, 0x6F, 0x7E, 0x2D, 0x1C, 0x9A,
                     0x8E, 0x4F, 0x3D, 0x6B, 0x12, 0x5A, 0x2E, 0x8C);

// ---- DATA 特征值六字节头的 byte1(跟 demo_codex.c 同一套框架,各自独立取值) --
#define APPSTORE_KIND_ITEM     0   // 目录条目:index/total = 第几项/总数,payload = 名字+简介
#define APPSTORE_KIND_FIRMWARE 1   // 固件分片:index/total = 第几个分片/总分片数,payload = 固件原始字节

// ---- CMD 特征值上设备 -> Mac 的请求号(三字节定长) --------------------------
#define APPSTORE_REQ_LIST_APPS   0
#define APPSTORE_REQ_INSTALL_APP 1   // param_a = 目录里的下标
// 复用同一个 CMD 通道:安装过程中一旦确定失败(找不到分区/esp_ota_begin 或
// esp_ota_write 出错),立刻发这个,而不是等对方把几千个分片都发完、直到
// END 标志才让 Mac 知道——不然设备这边已经在屏幕上钉住报错了,Mac 那边还在
// 傻乎乎地继续传剩下的分片,白白等好几分钟。Mac 收到后应该立刻清空还没发出
// 去的分片队列,不用等 END。
#define APPSTORE_EVT_INSTALL_ABORTED 2
// 批量确认协议:设备每写完 APPSTORE_PROGRESS_BATCH 片(或者收到一个已经写过
// 的重复分片时,立刻补发一次)就主动上报一次"已经真正写到第几片了"
// (param_a=低字节,param_b=高字节,分片数上千,一个字节不够)。Mac 端据此
// 用 write-without-response 连续发一整批再等这一次回执,不用每片都等
// ATT 层确认——回执丢了/超时就重发这一批,由于设备端对"已经写过的分片"
// 是幂等跳过(见 appstore_data_access_cb 里的重复检测),重发不会把已经
// 写成功的部分再 append 一遍、错位写坏镜像。
// 断线重连时(GAP_EVENT_SUBSCRIBE 里 s_ota_active 还是 true)也发这个,
// 让 Mac 知道接着从哪继续发,不用整个文件从头重来。
#define APPSTORE_EVT_PROGRESS 3

// 六字节头 byte0 的标志位。START/END 标记的是"整条消息/整个固件流"的首尾;
// BATCH_END 由 Mac 打在它每一批的最后一片上,是这套批量确认协议的关键:设备
// 只在写完带这个标志的分片时上报一次进度,于是每批恰好一次确认,跟对端的批次
// 边界严格对齐。
//
// ⚠ 上报时机必须由对端标定,设备自己是判断不出来的:
//   · 按"已写分片数是固定值的整数倍"上报——计数一旦因为重复分片的补报错开,
//     两边就永远差几片对不上,每批都得干等满一个超时周期才靠重发前进;
//   · 按"写入队列排空"上报——flash 写入远快于蓝牙收包,队列几乎总是空的,于是
//     退化成每片都发一次 indicate,而 indicate 是需要对端确认的完整 ATT 事务,
//     等于又变回了每片一次往返,批量传输的意义全部丧失。
// 两种都实测踩过,都比不批量还慢。
#define APPSTORE_FLAG_START     0x01
#define APPSTORE_FLAG_END       0x02
#define APPSTORE_FLAG_BATCH_END 0x04

// ---- 应用目录本地缓存 -------------------------------------------------------
#define MAX_APPS      16
#define APP_LINE_LEN  96

typedef struct {
    bool got;
    char text[APP_LINE_LEN];   // "名字 - 简介",一行显示
} app_item_t;

static app_item_t s_apps[MAX_APPS];
static int s_app_total;        // 协议里的 total 字段,0 = 还一项都没收到

// ---- 原始分片展平缓冲区:目录条目和固件分片都先落到这里 --------------------
// ⚠ 之前这里写的是 256,而 Mac 端协商出来的分片是 6 字节头 + 最多约 506 字节
// 数据、合计到 512 字节——超过 256 的部分会被 appstore_data_access_cb() 里的
// "len > sizeof(s_chunk_buf) 就截断" 防御逻辑直接砍掉,相当于每个固件分片
// 后半段几百字节的真实数据被无声丢弃,传下来的镜像从第一片起就是错位、残缺
// 的,最终必然通不过 esp_ota_end() 的校验(或者干脆在下一片直接命中错误的
// magic byte)。跟 demo_codex.c 的 CODEX_CHUNK_BUF_LEN 保持一致,给够 512。
#define APPSTORE_CHUNK_BUF_LEN 512

typedef struct {
    bool    active;
    uint8_t kind;
    uint16_t index;
    uint16_t total;
    int     len;
    char    buf[APP_LINE_LEN];
} appstore_acc_t;

static appstore_acc_t s_acc;
static uint8_t        s_chunk_buf[APPSTORE_CHUNK_BUF_LEN];

// ---- 固件安装状态 -----------------------------------------------------------
// esp_ota_write() 是真正的 flash 写入,耗时比蓝牙一次 ATT 往返长得多。早期
// 版本直接在 appstore_data_access_cb()(跑在 NimBLE host 任务里)里同步调用
// 它——这样一来,这次蓝牙写入的确认(ATT response)要等 flash 写完才能发出
// 去,等于每个分片都被 flash 操作拖慢,实测下来比蓝牙链路本身能跑的速度慢
// 了一个数量级还不止。现在把"收分片"和"写 flash"拆成两个独立任务:
// appstore_data_access_cb() 只管收、拷贝进队列、立刻回 ATT 响应;真正的
// esp_ota_write() 挪到 ota_write_task() 里异步做,两边只通过队列打交道。
#define OTA_CHUNK_DATA_MAX   (APPSTORE_CHUNK_BUF_LEN - 6)   // 单个分片最大原始字节数
#define OTA_QUEUE_DEPTH      12                             // 缓冲量,吸收 flash 偶尔跟不上的抖动

typedef struct {
    uint8_t data[OTA_CHUNK_DATA_MAX];
    int     len;
    bool    is_end;
    bool    is_batch_end;   // 见 APPSTORE_FLAG_BATCH_END
} ota_chunk_msg_t;

static QueueHandle_t    s_ota_queue;
static TaskHandle_t     s_ota_task;
static esp_ota_handle_t s_ota_handle;
static bool             s_ota_active;      // 是否已经 esp_ota_begin() 成功、还没 esp_ota_end()
static bool             s_ota_failed;      // 这次安装过程中是否已经出过错(出错后续分片直接丢弃)
static bool             s_abort_sent;      // 这次安装是否已经通知过 Mac 中止,避免每个分片都重发一遍
static int              s_install_total;   // 本次安装总分片数(来自协议 total 字段)
static int              s_install_received;// 已经实际写完 flash 的分片数,用于显示进度
// 已经收进队列的分片数。跟 s_install_received 之间隔着 s_ota_queue 这个异步
// 队列,所以两者会短暂不相等 —— 判断"下一片该是谁"必须用这个,而向对端上报
// "从哪继续发"也必须用这个(对端要接着发的是还没被收下的那一片)。
static int              s_install_accepted;

// ---- 错误提示:钉住直到用户按键确认(跟 demo_codex.c 的 s_error_pinned 是同
// 一个模式,但这里是完全独立的一份状态 —— 两个页面不共享任何东西)。
static volatile bool s_error_pinned;
static char          s_error_text[160];

static volatile bool s_dirty;   // UI 用 appstore_transfer_consume_dirty() 读一次就清

static void codex_utf8_copy(char *dst, size_t dst_size, const char *src);  // 前置声明,定义在下面

// 把 src 安全截断拷贝进 dst(绝不会在多字节 UTF-8 字符中间截断)。跟
// demo_codex.c 里的同名函数逻辑完全一致,各自独立一份,避免跨文件依赖内部
// 静态函数。
static void codex_utf8_copy(char *dst, size_t dst_size, const char *src)
{
    if (dst_size == 0) return;
    size_t n = strlen(src);
    if (n > dst_size - 1) n = dst_size - 1;
    while (n > 0 && ((unsigned char)src[n] & 0xC0) == 0x80) {
        n--;
    }
    memcpy(dst, src, n);
    dst[n] = '\0';
}

static int app_known_count(void)
{
    if (s_app_total > 0) {
        return s_app_total > MAX_APPS ? MAX_APPS : s_app_total;
    }
    int c = 0;
    for (int i = 0; i < MAX_APPS; i++) {
        if (s_apps[i].got) c = i + 1;
    }
    return c;
}

static void reset_app_cache(void)
{
    for (int i = 0; i < MAX_APPS; i++) {
        s_apps[i].got = false;
        s_apps[i].text[0] = '\0';
    }
    s_app_total = 0;
}

static uint16_t s_data_chr_val_handle;
static uint16_t s_cmd_chr_val_handle;

// 构造 3 字节请求 mbuf,通过 CMD 特征值 indicate 给 Mac。跟 demo_codex.c 的
// codex_send_cmd() 是同一个模式,各自一份独立实现。
static void appstore_send_cmd(uint8_t req, uint8_t param_a, uint8_t param_b)
{
    uint8_t payload[3] = { req, param_a, param_b };
    int rc = ble_hub_indicate(s_cmd_chr_val_handle, payload, sizeof(payload));
    if (rc != 0) {
        ESP_LOGW(TAG, "发送 CMD 请求失败: req=%d rc=%d", req, rc);
    }
}

// 上报"已经真正写到第几片了"(s_install_received),用 2 字节小端塞进
// CMD indicate 现成的 param_a/param_b 里——分片数上千,1 字节装不下。
static void appstore_send_progress(void)
{
    uint16_t received = (uint16_t)s_install_accepted;
    appstore_send_cmd(APPSTORE_EVT_PROGRESS,
                      (uint8_t)(received & 0xFF), (uint8_t)(received >> 8));
}

// 找到 appslot 分区。跟 bootloader 那边的裸偏移不是同一套查找方式 ——
// 这里是完整 app 上下文,直接按 label 查分区表,不用手写偏移。
static const esp_partition_t *find_appslot_partition(void)
{
    return esp_partition_find_first(ESP_PARTITION_TYPE_APP,
                                    ESP_PARTITION_SUBTYPE_APP_OTA_0, "appslot");
}

static void appstore_dispatch_item(void)
{
    s_acc.buf[s_acc.len] = '\0';
    if (s_acc.index < MAX_APPS) {
        s_apps[s_acc.index].got = true;
        codex_utf8_copy(s_apps[s_acc.index].text, sizeof(s_apps[s_acc.index].text), s_acc.buf);
    }
    s_app_total = s_acc.total;
    s_dirty = true;
}

// 收完最后一个固件分片:esp_ota_end() 做镜像合法性校验,通过就写 bootflag
// 重启切过去(main_boot_into_appslot() 内部调用 esp_restart(),不会返回);
// 不通过就钉住错误提示,留在安装中的状态,不动 appslot 的启动标记 ——
// 保证一次写坏的镜像不会真的被启动。
static void appstore_finish_install(void)
{
    s_ota_active = false;
    if (s_ota_failed) {
        esp_ota_end(s_ota_handle);   // 即使已知失败也要收尾一下句柄,不留资源
        s_error_pinned = true;
        snprintf(s_error_text, sizeof(s_error_text), "安装失败:写入过程出错");
        s_dirty = true;
        return;
    }
    esp_err_t err = esp_ota_end(s_ota_handle);
    if (err != ESP_OK) {
        ESP_LOGE(TAG, "esp_ota_end 失败: %s", esp_err_to_name(err));
        s_error_pinned = true;
        snprintf(s_error_text, sizeof(s_error_text), "安装失败:镜像校验未通过");
        s_dirty = true;
        return;
    }
    ESP_LOGI(TAG, "固件写入完成,校验通过,即将重启切换到新应用");
    main_boot_into_appslot();   // 不会返回
}

// 真正做 esp_ota_write() 的地方,独立任务,只通过 s_ota_queue 跟
// appstore_data_access_cb() 打交道——这样蓝牙那边收到分片可以立刻回 ATT
// 响应,不用等 flash 写完。
//
// xQueueReceive 用 200ms 超时而不是 portMAX_DELAY:正常情况下超时后什么也
// 不做,直接继续等;唯一的作用是在"生产者那边判定失败、队列也已经空了、
// 但真正的 END 分片因为生产者提前不再入队而永远不会来"这种情况下,还能
// 定期醒过来发现 s_ota_failed 已经变 true、自己收尾一次——不然会一直卡在
// xQueueReceive 上永远等不到东西,错误提示也永远钉不上屏幕。
// appstore_finish_install() 内部把 s_ota_active 置回 false,这个判断本身
// 保证了只会真正收尾一次,不会跟 msg.is_end 那条路径重复调用。
static void ota_write_task(void *arg)
{
    (void)arg;
    for (;;) {
        ota_chunk_msg_t msg;
        if (xQueueReceive(s_ota_queue, &msg, pdMS_TO_TICKS(200)) == pdTRUE) {
            if (s_ota_active && !s_ota_failed && msg.len > 0) {
                esp_err_t err = esp_ota_write(s_ota_handle, msg.data, (size_t)msg.len);
                if (err != ESP_OK) {
                    ESP_LOGE(TAG, "esp_ota_write 失败: %s", esp_err_to_name(err));
                    s_ota_failed = true;
                }
            }
            if (s_ota_failed && !s_abort_sent) {
                s_abort_sent = true;
                appstore_send_cmd(APPSTORE_EVT_INSTALL_ABORTED, 0, 0);
            }
            s_install_received++;
            s_dirty = true;
            // 每写完一批就上报一次进度,Mac 那边攒够一批 write-without-response
            // 之后就是在等这个——不用每片都等 ATT 层确认,靠这个周期性回执
            // 知道"这批真的写完了,可以发下一批了"。
            // 每批恰好上报一次:Mac 攒够一批 write-without-response 全部发出后
            // 就在等这一条,收到才发下一批,不用每片都等 ATT 层确认。上报时机
            // 完全由对端打在最后一片上的 BATCH_END 标志决定,理由见该宏的注释。
            if (!s_ota_failed && msg.is_batch_end) {
                appstore_send_progress();
            }
            if (msg.is_end) {
                if (!s_ota_failed) appstore_send_progress();   // 最后一批不满一个批量周期,补发一次
                appstore_finish_install();
            }
        }
        if (s_ota_failed && s_ota_active) {
            appstore_finish_install();
        }
    }
}

// ⚠ 这个回调跑在 NimBLE host 任务里,不是 LVGL 任务 —— 不碰任何 LVGL 对象。
// kind=FIRMWARE 时不再直接调 esp_ota_write()(那是同步 flash 写入,会拖慢
// 这次 ATT 响应)——只把分片拷进 s_ota_queue,交给 ota_write_task() 异步
// 处理,自己立刻回响应。
static int appstore_data_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                                   struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)arg;

    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) {
        return BLE_ATT_ERR_UNLIKELY;
    }

    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len < 6) {
        return BLE_ATT_ERR_UNLIKELY;
    }
    if (len > sizeof(s_chunk_buf)) {
        len = sizeof(s_chunk_buf);
    }
    int rc = ble_hs_mbuf_to_flat(ctxt->om, s_chunk_buf, len, NULL);
    if (rc != 0) {
        return BLE_ATT_ERR_UNLIKELY;
    }

    uint8_t     flags    = s_chunk_buf[0];
    uint8_t     kind     = s_chunk_buf[1];
    uint16_t    index    = (uint16_t)s_chunk_buf[2] | ((uint16_t)s_chunk_buf[3] << 8);
    uint16_t    total    = (uint16_t)s_chunk_buf[4] | ((uint16_t)s_chunk_buf[5] << 8);
    const uint8_t *frag  = &s_chunk_buf[6];
    int         frag_len = (int)len - 6;
    bool        is_start = (flags & APPSTORE_FLAG_START) != 0;
    bool        is_end   = (flags & APPSTORE_FLAG_END) != 0;
    bool        is_batch_end = (flags & APPSTORE_FLAG_BATCH_END) != 0;

    if (kind == APPSTORE_KIND_ITEM) {
        if (is_start) {
            s_acc.active = true;
            s_acc.kind = kind;
            s_acc.index = index;
            s_acc.total = total;
            s_acc.len = 0;
        }
        if (s_acc.active && frag_len > 0) {
            int room = (int)sizeof(s_acc.buf) - 1 - s_acc.len;
            int copy = frag_len < room ? frag_len : room;
            if (copy > 0) {
                memcpy(s_acc.buf + s_acc.len, frag, copy);
                s_acc.len += copy;
            }
        }
        if (is_end && s_acc.active) {
            appstore_dispatch_item();
            s_acc.active = false;
            s_acc.len = 0;
        }
        return 0;
    }

    if (kind == APPSTORE_KIND_FIRMWARE) {
        // 只在真正第一次开始时才 esp_ota_begin()。如果 s_ota_active 已经是
        // true,说明这是一次重传抵达的 chunk 0(Mac 那边等批量确认超时、把
        // 整批——包括开头这片——重新发了一遍),绝不能再调一次
        // esp_ota_begin()(会把已经写进去的部分整个擦掉!),直接落到下面
        // 当普通分片处理,交给下面"已经写过就跳过"那段逻辑接住。
        if (is_start && !s_ota_active) {
            s_install_total = total;
            s_install_received = 0;
            s_install_accepted = 0;
            s_ota_failed = false;
            s_abort_sent = false;
            const esp_partition_t *part = find_appslot_partition();
            if (!part) {
                ESP_LOGE(TAG, "找不到 appslot 分区");
                s_ota_failed = true;
                s_error_pinned = true;
                snprintf(s_error_text, sizeof(s_error_text), "安装失败:找不到安装分区");
                s_dirty = true;
            } else {
                const esp_partition_t *running = esp_ota_get_running_partition();
                if (running && running->address == part->address) {
                    // ESP-IDF forbids erasing/writing the currently executing
                    // partition. Return to the factory launcher first. The Mac
                    // keeps its install session alive; after BLE reconnects its
                    // existing timeout/retry path sends chunk zero again.
                    ESP_LOGI(TAG, "当前运行于 appslot,先重启回 factory 再更新");
                    main_restart_to_factory_for_update();   // 成功时不会返回
                    return 0;
                }
                esp_err_t err = esp_ota_begin(part, OTA_SIZE_UNKNOWN, &s_ota_handle);
                if (err != ESP_OK) {
                    // esp_ota_begin() 还没成功过,s_ota_active 从没变过 true——
                    // 这里直接同步收尾/报错,不走 ota_write_task() 那条路径
                    // (那边靠 s_ota_active 才知道"有没有一个真句柄需要
                    // esp_ota_end()",这里从一开始就没有,不能让它去调)。
                    ESP_LOGE(TAG, "esp_ota_begin 失败: %s", esp_err_to_name(err));
                    s_ota_failed = true;
                    s_error_pinned = true;
                    snprintf(s_error_text, sizeof(s_error_text), "安装失败:无法开始写入");
                    s_dirty = true;
                } else {
                    s_ota_active = true;
                }
            }
            if (s_ota_failed && !s_abort_sent) {
                s_abort_sent = true;
                appstore_send_cmd(APPSTORE_EVT_INSTALL_ABORTED, 0, 0);
            }
        }

        // esp_ota_write() 是纯顺序 append:它只会把数据接在上一次写入的末尾,
        // 完全不认分片编号。所以这里必须严格只接受"正好是下一片"的那一片,
        // 编号对不上的一律拒收并立刻补发一次进度,让对端从正确的位置重来。
        //
        // ⚠ 只挡住"编号更小"的重复分片是不够的 —— 那样会放过编号更大的跳跃,
        // 而跳跃的分片会被若无其事地 append 到当前位置上,镜像从此整段错位。
        // 实测就是这么坏掉的:发送端一个竞态导致某一批被从中间重发,其中编号
        // 大于当前进度的那些分片全被当成新数据写了进去,最终镜像六个段的结构
        // 和长度全都正常、只有校验和对不上,bootloader 直接判定不可启动。
        //
        // 比较的是 s_install_accepted(已收进队列的)而不是 s_install_received
        // (已真正写完 flash 的):两者之间隔着一个异步队列,用后者会把还在队列
        // 里排队、其实完全合法的后续分片误判成跳跃全部拒收,传输直接卡死。
        if (s_ota_active && !s_ota_failed && index != (uint16_t)s_install_accepted) {
            appstore_send_progress();
            return 0;
        }

        // 只管把这个分片的原始字节拷进队列、立刻回响应——真正的 flash 写入
        // 交给 ota_write_task() 异步做,这次 ATT 响应不会被 flash 操作拖慢。
        if (s_ota_active && !s_ota_failed) {
            ota_chunk_msg_t msg;
            msg.len = frag_len > 0 ? frag_len : 0;
            if (msg.len > (int)sizeof(msg.data)) msg.len = (int)sizeof(msg.data);  // 防御性,理论上不会触发
            if (msg.len > 0) memcpy(msg.data, frag, (size_t)msg.len);
            msg.is_end = is_end;
            msg.is_batch_end = is_batch_end;
            // 超时而不是一直等:队列满说明 flash 写入速度长期跟不上蓝牙收
            // 分片的速度,继续囤下去只会越攒越多,不如直接判定这次安装失败。
            if (xQueueSend(s_ota_queue, &msg, pdMS_TO_TICKS(500)) == pdTRUE) {
                s_install_accepted++;
            } else {
                ESP_LOGE(TAG, "OTA 写入队列已满(flash 写入跟不上),判定安装失败");
                s_ota_failed = true;
                if (!s_abort_sent) {
                    s_abort_sent = true;
                    appstore_send_cmd(APPSTORE_EVT_INSTALL_ABORTED, 0, 0);
                }
                // 这个分片真的丢了(没进队列),ota_write_task() 不会知道
                // "收到过 is_end"——但它自己的 200ms 超时轮询会发现
                // s_ota_failed 已经变 true,照样能收尾、钉住错误提示,不用
                // 在这里越俎代庖去调 esp_ota_end()(那样跟消费任务可能同时
                // 摸同一个 handle,产生竞态)。
            }
        }

        // 失败之后这条也照样回 ATT 层错误,而不是 0(成功)——不管
        // esp_ota_write() 有没有真的写进去都无条件回 0 的话,Mac 端看到的是
        // "每一片都正常 ACK 了",完全不知道设备这边已经放弃写入,只能干等
        // CMD 中止通知那一条独立信道慢慢传过去。现在双保险:ATT 层错误让
        // CoreBluetooth 的 didWriteValueFor 立刻报错、Mac 自己的分片队列
        // 清空逻辑马上生效,不用完全依赖那条中止通知。
        return s_ota_failed ? BLE_ATT_ERR_UNLIKELY : 0;
    }

    ESP_LOGW(TAG, "未知的消息 kind: %d,忽略", kind);
    return 0;
}

// CMD 特征值只用于设备 -> Mac 的 indicate,不需要真的被读/写,但 NimBLE 的
// ble_gatts_chr_is_sane() 要求非空 access_cb,放个桩函数(跟 demo_codex.c
// 里 codex_cmd_access_cb() 同样的原因)。
static int appstore_cmd_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                                  struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)ctxt;
    (void)arg;
    return BLE_ATT_ERR_UNLIKELY;
}

static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                .uuid = &s_data_uuid.u,
                .access_cb = appstore_data_access_cb,
                // Mac 端固件分片走 write-without-response,必须同时声明
                // WRITE_NO_RSP——否则 CoreBluetooth 发现这个特征值时
                // properties 里没有 writeWithoutResponse 这一位,批量发送
                // 协议会在发完第一批前静默卡死,不产生任何日志或错误。
                .flags = BLE_GATT_CHR_F_WRITE | BLE_GATT_CHR_F_WRITE_NO_RSP,
                .val_handle = &s_data_chr_val_handle,
            },
            {
                .uuid = &s_cmd_uuid.u,
                .access_cb = appstore_cmd_access_cb,
                .flags = BLE_GATT_CHR_F_INDICATE,
                .val_handle = &s_cmd_chr_val_handle,
            },
            { 0 },
        },
    },
    { 0 },
};

// ---- 接入常驻 BLE(见 ble_hub.h) -------------------------------------------
// 这个模块以前自己拥有一整套 NimBLE 协议栈,随"应用商店"页面的进出而起停。
// 那样带来一个致命的产品后果:设备不停在那个页面时,这个 GATT service 根本
// 没在广播,配套 app 连都连不上 —— "在电脑上点一下就装过去"根本无从谈起。
// 现在协议栈由 ble_hub 常驻持有,这里只注册 service 和观察者。
//
// 相应地,OTA 接收能力(队列 + 写入任务)也必须常驻而不是随页面创建:对端
// 随时可能推固件过来,那一刻用户可能正停在任何界面上,没有任务在跑就等于
// 分片全部丢弃。

static void on_ble_connect(uint16_t conn_handle)
{
    (void)conn_handle;
}

static void on_ble_disconnect(void)
{
    // 安装中途断连不清任何状态:s_install_accepted 要留着,对端重连后靠它
    // 从正确的位置续传,不用把几 MB 整个重传一遍。
    s_dirty = true;
}

static void on_ble_subscribe(uint16_t attr_handle, bool subscribed)
{
    if (attr_handle != s_cmd_chr_val_handle || !subscribed) return;

    // 对端完成服务发现后订阅 CMD indicate,这一刻才是发首次请求的正确时机
    // (CONNECT 时对端还没订阅,indicate 必然失败)。但如果这是"安装中途断线
    // 后重连",要发的不是"列一下目录",而是当前进度 —— 让对端知道接着从哪
    // 继续发,不用把几千个分片从头重传。
    if (s_ota_active && !s_ota_failed) {
        ESP_LOGI(TAG, "对端重新订阅,安装仍在进行中,补发当前进度 (%d/%d)",
                 s_install_accepted, s_install_total);
        appstore_send_progress();
    } else {
        appstore_send_cmd(APPSTORE_REQ_LIST_APPS, 0, 0);
    }
}

static const ble_hub_observer_t s_ble_observer = {
    .on_connect = on_ble_connect,
    .on_disconnect = on_ble_disconnect,
    .on_subscribe = on_ble_subscribe,
};

void appstore_transfer_register(void)
{
    ble_hub_register_service(s_gatt_svcs);
    ble_hub_register_observer(&s_ble_observer);
}

void appstore_transfer_init(void)
{
    reset_app_cache();
    memset(&s_acc, 0, sizeof(s_acc));
    s_ota_active = false;
    s_ota_failed = false;
    s_error_pinned = false;
    s_install_total = 0;
    s_install_received = 0;
    s_install_accepted = 0;
    s_dirty = true;

    if (!s_ota_queue) {
        s_ota_queue = xQueueCreate(OTA_QUEUE_DEPTH, sizeof(ota_chunk_msg_t));
    }
    if (!s_ota_task && s_ota_queue) {
        xTaskCreate(ota_write_task, "appstore_ota", 4096, NULL, 4, &s_ota_task);
    }
}

// ---- appstore_transfer.h 对外接口 -------------------------------------------

// 状态查询现在直接反映 ble_hub 的连接状态 —— 这个模块不再自己起停协议栈,
// 所以也不再有"正在启动/广播失败"这类只有栈拥有者才知道的中间状态。
appstore_transfer_state_t appstore_transfer_get_state(void)
{
    return ble_hub_is_connected() ? APPSTORE_TRANSFER_CONNECTED
                                  : APPSTORE_TRANSFER_ADVERTISING;
}

int appstore_transfer_last_error(void)
{
    // 协议栈的错误现在由 ble_hub 负责记录和打印,这个模块不再持有它们。
    // 保留这个函数只是为了让界面层的签名不变。
    return 0;
}

int appstore_transfer_app_count(void)
{
    return app_known_count();
}

const char *appstore_transfer_app_text(int index)
{
    return s_apps[index].got ? s_apps[index].text : "...";
}

void appstore_transfer_install(int index)
{
    s_install_total = 0;
    s_install_received = 0;
    s_dirty = true;
    appstore_send_cmd(APPSTORE_REQ_INSTALL_APP, (uint8_t)index, 0);
}

bool appstore_transfer_is_installing(void)
{
    return s_install_total > 0 || s_ota_active;
}

int appstore_transfer_install_received(void)
{
    return s_install_received;
}

int appstore_transfer_install_total(void)
{
    return s_install_total;
}

bool appstore_transfer_error_pending(void)
{
    return s_error_pinned;
}

const char *appstore_transfer_error_text(void)
{
    return s_error_text;
}

void appstore_transfer_clear_error(void)
{
    s_error_pinned = false;
    s_dirty = true;
}

bool appstore_transfer_consume_dirty(void)
{
    if (!s_dirty) return false;
    s_dirty = false;
    return true;
}
