// main/demo_codex.c —— "Codex" 会话浏览器页(协议 v2)。
// 作为 NimBLE 外围设备广播,Mac 端 App(FoloCodexRelay)负责把 ~/.codex/sessions
// 下的工作区(workspace)/会话(session)/分页内容算好、推送过来;设备只管
// "请求 - 展示 - 翻页/选择",不做任何 JSONL 解析。
//
// 两个特征值挂在同一个 service 下:
//   DATA(WRITE,   Mac -> 设备): 结构化屏幕内容,六字节头 + UTF-8 分片,
//                               沿用 v1 的 START/END 分片重组机制。index/total
//                               各占 2 字节(小端)—— 单字节最多只能数到 255,
//                               单个会话超过 255 页时会直接把翻页卡死,见下方
//                               codex_acc_t 定义处的说明。
//   CMD (INDICATE,设备 -> Mac): 三字节定长请求,设备主动发起
//                               "看工作区列表/看会话列表/打开会话/翻页"。
// 连接管理部分(advertise/gap_event 的 CONNECT/DISCONNECT/ADV_COMPLETE 分支/
// on_reset/on_sync/host_task/ble_start/ble_stop)照抄 demo_ble.c 里已经过硬件
// 验证的那一套,只是 gap_event 里多加了 BLE_GAP_EVENT_SUBSCRIBE 分支。
//
// 页面内部是一个私有的三态视图机(READING/WORKSPACES/SESSIONS),完全在本文件
// 内部维护,不影响 main.c 里 VIEW_CODEX 这个外层状态,main.c 仍然只认
// demo_codex_enter/exit/key 这三个函数。
#include "ble_hub.h"
#include "demo.h"
#include "demo_radio.h"
#include "ui_pixel.h"

#include "bsp_audio.h"
#include "esp_log.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "freertos/task.h"
#include "host/ble_gap.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "host/ble_uuid.h"
#include "host/util/util.h"
#include "lvgl.h"
#include "nimble/nimble_port.h"
#include "nimble/nimble_port_freertos.h"
#include "services/gap/ble_svc_gap.h"
#include "services/gatt/ble_svc_gatt.h"
#include <stdio.h>
#include <string.h>

static const char *TAG = "demo_codex";
static const char *DEVICE_NAME = "FoloPassport";   // 与 demo_ble.c 相同的广播名

// "Codex 浏览器" 协议 v2 专用的 Service/Characteristic UUID,与 demo_ble.c 里
// 测试用的那一对完全独立。
//
// ⚠ NimBLE 的 BLE_UUID128_INIT(...) 按小端存储,和 CoreBluetooth 用
// CBUUID(string:) 解析标准 UUID 字符串时的顺序正好相反 —— 固件这边要把
// 字符串的 16 字节整体倒过来写。Swift/CoreBluetooth 那边直接用标准 UUID
// 字符串本身,不用倒序。
//   Service:   7D860E11-CECE-4DC5-85BF-088EBDADC109 (v1 沿用,不变)
//   DATA 特征: 2B2AF9BA-21D2-4767-9281-04A909C52C45 (v1 沿用,不变)
//   CMD  特征: C3889419-D487-476F-B171-7378F0102A97 (v2 新增,下面这个反转
//              字节数组是协议文档给的,原样照抄,没有重新计算)
//   AUDIO特征: 0596975F-B995-439C-A41B-3DFA7AA8A81F (语音输入新增,下面这个
//              反转字节数组同样是协议文档给的,原样照抄,没有重新计算)
static const ble_uuid128_t s_svc_uuid =
    BLE_UUID128_INIT(0x09, 0xC1, 0xAD, 0xBD, 0x8E, 0x08, 0xBF, 0x85,
                     0xC5, 0x4D, 0xCE, 0xCE, 0x11, 0x0E, 0x86, 0x7D);
static const ble_uuid128_t s_data_uuid =
    BLE_UUID128_INIT(0x45, 0x2C, 0xC5, 0x09, 0xA9, 0x04, 0x81, 0x92,
                     0x67, 0x47, 0xD2, 0x21, 0xBA, 0xF9, 0x2A, 0x2B);
static const ble_uuid128_t s_cmd_uuid =
    BLE_UUID128_INIT(0x97, 0x2A, 0x10, 0xF0, 0x78, 0x73, 0x71, 0xB1,
                     0x6F, 0x47, 0x87, 0xD4, 0x19, 0x94, 0x88, 0xC3);
static const ble_uuid128_t s_audio_uuid =
    BLE_UUID128_INIT(0x1F, 0xA8, 0xA8, 0x7A, 0xFA, 0x3D, 0x1B, 0xA4,
                     0x9C, 0x43, 0x95, 0xB9, 0x5F, 0x97, 0x96, 0x05);

// ---- DATA 特征值上 Mac -> 设备的消息 kind(协议 v2 六字节头的 byte1) --------
#define CODEX_KIND_WORKSPACE_ITEM 0
#define CODEX_KIND_SESSION_ITEM   1
#define CODEX_KIND_PAGE_USER      2
#define CODEX_KIND_PAGE_ASSISTANT 3
#define CODEX_KIND_STATUS         4
#define CODEX_KIND_ERROR          5   // 语音发送失败等需要用户确认的提示,见 s_error_pinned

// ---- CMD 特征值上设备 -> Mac 的请求号(三字节定长,不分片) -----------------
#define CODEX_REQ_ACTIVE_SESSION  0
#define CODEX_REQ_LIST_WORKSPACES 1
#define CODEX_REQ_LIST_SESSIONS   2
#define CODEX_REQ_OPEN_SESSION    3
#define CODEX_REQ_PAGE            4

// ---- AUDIO 特征值上设备 -> Mac 的语音分片 flags(byte0) --------------------
#define CODEX_VOICE_FLAG_START 0x01   // 这次说话的第一个分片
#define CODEX_VOICE_FLAG_END   0x02   // 最后一个分片(可以是空 payload)

// ---- IMA ADPCM 编码(标准算法 + 标准表,设备端编、Mac 端解,字节兼容) -------
// 每路编码(每次长按说话)独立维护 predictor/step_index,不跨话音复用 ——
// 状态放在 voice_record_task() 的局部变量里,天然满足这一点。
static const int16_t IMA_STEP_TABLE[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
    34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
    157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544, 598, 658,
    724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066, 2272, 2499, 2749, 3024,
    3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635, 13899,
    15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767
};
static const int8_t IMA_INDEX_TABLE[16] = {
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8
};

typedef struct {
    int32_t predictor;
    int     step_index;
} adpcm_state_t;

// 编码单个 16bit PCM 采样,返回 4bit code(低 4 位有效)。标准 IMA ADPCM
// 编码算法,跟协议文档给的伪代码逐行对应,方便跟 Mac 端解码器核对。
static uint8_t adpcm_encode_sample(adpcm_state_t *st, int16_t sample)
{
    int step = IMA_STEP_TABLE[st->step_index];
    int diff = (int)sample - st->predictor;
    uint8_t code = 0;
    if (diff < 0) { code = 8; diff = -diff; }

    int vpdiff = step >> 3;
    if (diff >= step) { code |= 4; diff -= step; vpdiff += step; }
    step >>= 1;
    if (diff >= step) { code |= 2; diff -= step; vpdiff += step; }
    step >>= 1;
    if (diff >= step) { code |= 1; vpdiff += step; }

    if (code & 8) st->predictor -= vpdiff;
    else          st->predictor += vpdiff;
    if (st->predictor > 32767)       st->predictor = 32767;
    else if (st->predictor < -32768) st->predictor = -32768;

    st->step_index += IMA_INDEX_TABLE[code];
    if (st->step_index < 0)       st->step_index = 0;
    else if (st->step_index > 88) st->step_index = 88;

    return code;
}

// 把 n 个 16bit PCM 采样编码成 IMA ADPCM,两个采样拼一字节(先编码的采样放
// 低 4 位、后编码的放高 4 位,跟标准 IMA ADPCM WAV 的编码顺序一致)。n 为奇数
// 时(只会发生在整段话最后一批不足 VOICE_CHUNK_SAMPLES 的情况)最后半字节的
// 高 4 位补 0。返回写入 out 的字节数。
static int adpcm_encode_block(adpcm_state_t *st, const int16_t *pcm, int n, uint8_t *out)
{
    int outlen = 0;
    for (int i = 0; i < n; i += 2) {
        uint8_t lo = adpcm_encode_sample(st, pcm[i]);
        uint8_t hi = (i + 1 < n) ? adpcm_encode_sample(st, pcm[i + 1]) : 0;
        out[outlen++] = (uint8_t)(lo | (hi << 4));
    }
    return outlen;
}

// ---- 工作区列表本地缓存 ----------------------------------------------------
#define MAX_WORKSPACES     24
#define WORKSPACE_NAME_LEN 48

typedef struct {
    bool got;                          // 这一项是否已经收到
    char name[WORKSPACE_NAME_LEN];
} workspace_item_t;

static workspace_item_t s_workspaces[MAX_WORKSPACES];
static int s_workspace_total;          // 协议里的 total 字段,0 = 还一项都没收到
static int s_workspace_sel;            // 当前选中项(UI 状态)

// ---- 会话列表本地缓存 ------------------------------------------------------
#define MAX_SESSIONS     24
#define SESSION_LINE_LEN 80

typedef struct {
    bool got;
    char text[SESSION_LINE_LEN];
} session_item_t;

static session_item_t s_sessions[MAX_SESSIONS];
static int s_session_total;
static int s_session_sel;
static int s_selected_workspace_idx;   // WORKSPACES -> SESSIONS 时记住的工作区下标

// ---- READING 页面缓存:只存"当前这一页",不缓存整个会话 --------------------
// 缓存整份会话是 Mac 侧的职责,设备只需要知道"现在这一页长什么样"。
//
// ⚠ 大小必须能装下 Mac 侧一整页的最坏情况,不能只按"看起来够用"估:协议
// 文档规定 Mac 按最多 280 个 UTF-8 *字符*(不是字节)切页,而一个字符在
// UTF-8 里最多编码成 4 字节(常见中文字符本身就是 3 字节)——280 * 4 = 1120
// 字节才是真正的上限,300 字节对中文内容(281 个汉字页 ≈ 840 字节起)会在
// 分片重组时被无声截断,直接违反协议"完整文本、不因设备 buffer 小丢内容"
// 的设计目标。
#define CODEX_MSG_MAX_LEN 1120  // 单页文本最多保留的字节数(280 字符 × 4 字节/字符)

typedef struct {
    bool    has_data;          // 是否已经收到过至少一页(决定要不要显示"加载中")
    uint8_t kind;               // CODEX_KIND_PAGE_USER/PAGE_ASSISTANT/STATUS
    int     index;
    int     total;
    char    text[CODEX_MSG_MAX_LEN + 1];
} reading_page_t;

static reading_page_t s_reading;

// ---- 语音发送失败提示:钉住直到用户按键确认 --------------------------------
// 之前语音发送失败只写进 Mac 侧日志,设备上一点反应都没有;后来改成借用
// CODEX_KIND_STATUS 走 s_reading 显示,但 Mac 侧 1 秒一次的自动刷新
// (checkForUpdates 检测到会话文件变化就会重新 push 真实内容——哪怕这次
// codex exec resume 最终失败,失败前往往已经把用户这句话写进了会话文件,
// 所以文件确实变了)会在下一个 tick 就把提示盖掉,用户根本来不及看清。
// 所以单独开一个不受自动刷新影响的"钉住"状态:收到 CODEX_KIND_ERROR 只
// 改这里,完全不碰 s_reading,直到 demo_codex_key() 收到一次按键才清掉。
#define CODEX_ERROR_MAX_LEN 256
static volatile bool s_error_pinned;
static char          s_error_text[CODEX_ERROR_MAX_LEN + 1];

// ---- 分片重组:单条正在拼的逻辑消息 ----------------------------------------
// 每次 BLE 写入是一个 chunk:byte0 flags(bit0=START bit1=END),byte1 kind,
// byte2-3 index(小端 u16),byte4-5 total(小端 u16),byte6.. 是这段文本的原始
// UTF-8 字节(无长度前缀、无 NUL)。同一时刻只维护一条正在拼接的消息,START
// 时清空重来,END 时收尾并按 kind 分发。
//
// index/total 曾经各只占 1 字节(单字节最多数到 255):一个长会话轻松超过
// 255 页,超过之后 Mac 侧 sendCurrentPage() 把 index/total 钳到 255 再发,
// 设备这边的翻页判断 `index < total - 1` 就会恒为假,DOWN 翻页从此彻底
// 失效,状态栏也会显示错误的页码——这不是按键状态机的 bug,是协议本身数不
// 下去了,所以在这里把这两个字段各扩到 2 字节。
#define CODEX_CHUNK_BUF_LEN 512   // 单次属性写入的展平缓冲区,覆盖常见 MTU

typedef struct {
    bool     active;             // 是否已经收到 START、还没收到 END
    uint8_t  kind;
    uint16_t index;
    uint16_t total;
    int      len;
    char     buf[CODEX_MSG_MAX_LEN + 1];
} codex_acc_t;

static codex_acc_t s_acc;
static uint8_t     s_chunk_buf[CODEX_CHUNK_BUF_LEN];

// ---- 本页私有的三态视图机 ---------------------------------------------------
typedef enum {
    CODEX_VIEW_READING = 0,     // 默认视图:显示"当前会话"某一页
    CODEX_VIEW_WORKSPACES,      // 工作区列表,可上下选择
    CODEX_VIEW_SESSIONS,        // 某工作区下的会话列表,可上下选择
} codex_view_t;

static codex_view_t s_view;
static volatile bool s_dirty;   // tick() 用来判断内容区要不要重绘

// 把 src 安全截断拷贝进 dst(大小 dst_size,含结尾 NUL),绝不会在一个多字节
// UTF-8 字符中间截断 —— 从候选截断点往回退,直到不处于某个多字节序列内部。
// 用于把分片重组缓冲区(最长 300 字节)里的文本装进更小的列表项缓冲区
// (工作区名 48 字节 / 会话摘要行 80 字节)时做防御性截断。
static void codex_utf8_copy(char *dst, size_t dst_size, const char *src)
{
    if (dst_size == 0) return;
    size_t n = strlen(src);
    if (n > dst_size - 1) n = dst_size - 1;
    while (n > 0 && ((unsigned char)src[n] & 0xC0) == 0x80) {
        n--;                     // 退回去,直到不在某个多字节字符中间
    }
    memcpy(dst, src, n);
    dst[n] = '\0';
}

// "已经收到的条数":total 已知(>0)时直接用 total(超出本地容量按容量截断);
// total 还未知时(一项都没收到)按已经收到的最大下标 + 1 估算。
static int workspace_known_count(void)
{
    if (s_workspace_total > 0) {
        return s_workspace_total > MAX_WORKSPACES ? MAX_WORKSPACES : s_workspace_total;
    }
    int c = 0;
    for (int i = 0; i < MAX_WORKSPACES; i++) {
        if (s_workspaces[i].got) c = i + 1;
    }
    return c;
}

static int session_known_count(void)
{
    if (s_session_total > 0) {
        return s_session_total > MAX_SESSIONS ? MAX_SESSIONS : s_session_total;
    }
    int c = 0;
    for (int i = 0; i < MAX_SESSIONS; i++) {
        if (s_sessions[i].got) c = i + 1;
    }
    return c;
}

static void reset_workspace_cache(void)
{
    for (int i = 0; i < MAX_WORKSPACES; i++) {
        s_workspaces[i].got = false;
        s_workspaces[i].name[0] = '\0';
    }
    s_workspace_total = 0;
    s_workspace_sel = 0;
}

static void reset_session_cache(void)
{
    for (int i = 0; i < MAX_SESSIONS; i++) {
        s_sessions[i].got = false;
        s_sessions[i].text[0] = '\0';
    }
    s_session_total = 0;
    s_session_sel = 0;
}

static void clear_reading_cache(void)
{
    s_reading.has_data = false;
    s_reading.kind = CODEX_KIND_STATUS;
    s_reading.index = 0;
    s_reading.total = 0;
    s_reading.text[0] = '\0';
}

// ⚠ 下面这个函数只操作普通 C 结构体/数组,不碰任何 LVGL 对象 —— 它是从
// codex_data_access_cb() 里调用的,而那个回调跑在 NimBLE host 任务里,不是
// LVGL 任务,直接碰 LVGL 对象会有数据竞争、也可能跟 ble_stop() 的收尾逻辑
// 形成潜在锁环。真正的界面刷新交给 tick()(跑在 LVGL 任务)按周期读取这里
// 写好的数据。
static void codex_dispatch_message(void)
{
    s_acc.buf[s_acc.len] = '\0';

    switch (s_acc.kind) {
    case CODEX_KIND_WORKSPACE_ITEM:
        if (s_acc.index < MAX_WORKSPACES) {
            s_workspaces[s_acc.index].got = true;
            codex_utf8_copy(s_workspaces[s_acc.index].name,
                           sizeof(s_workspaces[s_acc.index].name), s_acc.buf);
        }
        s_workspace_total = s_acc.total;
        s_dirty = true;
        break;

    case CODEX_KIND_SESSION_ITEM:
        if (s_acc.index < MAX_SESSIONS) {
            s_sessions[s_acc.index].got = true;
            codex_utf8_copy(s_sessions[s_acc.index].text,
                           sizeof(s_sessions[s_acc.index].text), s_acc.buf);
        }
        s_session_total = s_acc.total;
        s_dirty = true;
        break;

    case CODEX_KIND_PAGE_USER:
    case CODEX_KIND_PAGE_ASSISTANT:
    case CODEX_KIND_STATUS:
        s_reading.has_data = true;
        s_reading.kind = s_acc.kind;
        s_reading.index = s_acc.index;
        s_reading.total = s_acc.total;
        memcpy(s_reading.text, s_acc.buf, (size_t)s_acc.len + 1);   // 含结尾 NUL
        s_dirty = true;
        break;

    case CODEX_KIND_ERROR:
        // 故意不碰 s_reading —— 钉住的错误提示盖在上面显示,底下的真实内容
        // 原封不动,松开(用户按键确认)之后直接露出来,不用重新请求一遍。
        codex_utf8_copy(s_error_text, sizeof(s_error_text), s_acc.buf);
        s_error_pinned = true;
        s_dirty = true;
        break;

    default:
        ESP_LOGW(TAG, "未知的消息 kind: %d,忽略", s_acc.kind);
        break;
    }
}

// ⚠ 这个回调跑在 NimBLE host 任务里,不是 LVGL 任务 —— 千万不要在这里直接碰
// LVGL 对象(会跟 ble_stop() 里等 host 任务退出的逻辑形成潜在锁环)。收到的
// 分片只拼进 s_acc/各列表缓存这些普通 C 结构体,交给 tick()(跑在 LVGL 任务)
// 按周期读出来显示。
static int codex_data_access_cb(uint16_t conn_handle, uint16_t attr_handle,
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
        return BLE_ATT_ERR_UNLIKELY;           // 六字节头都不够,忽略这次写入
    }
    if (len > sizeof(s_chunk_buf)) {
        len = sizeof(s_chunk_buf);             // 防御性截断,理论上不会超过协商的 MTU
    }
    int rc = ble_hs_mbuf_to_flat(ctxt->om, s_chunk_buf, len, NULL);
    if (rc != 0) {
        return BLE_ATT_ERR_UNLIKELY;
    }

    uint8_t     flags    = s_chunk_buf[0];
    uint8_t     kind     = s_chunk_buf[1];
    uint16_t    index    = (uint16_t)s_chunk_buf[2] | ((uint16_t)s_chunk_buf[3] << 8);
    uint16_t    total    = (uint16_t)s_chunk_buf[4] | ((uint16_t)s_chunk_buf[5] << 8);
    const char *frag     = (const char *)&s_chunk_buf[6];
    int         frag_len = (int)len - 6;
    bool        is_start = (flags & 0x01) != 0;
    bool        is_end   = (flags & 0x02) != 0;

    if (is_start) {
        // 新消息开始:不管上一条是否已经收到 END 都直接重置 —— 正常不会
        // 发生,只是防御性处理,避免两条消息的内容被拼到一起。
        s_acc.active = true;
        s_acc.kind = kind;
        s_acc.index = index;
        s_acc.total = total;
        s_acc.len = 0;
    }

    if (s_acc.active && frag_len > 0) {
        int room = CODEX_MSG_MAX_LEN - s_acc.len;
        int copy = frag_len < room ? frag_len : room;
        if (copy > 0) {
            memcpy(s_acc.buf + s_acc.len, frag, copy);
            s_acc.len += copy;
        }
        // 超过 CODEX_MSG_MAX_LEN 的部分直接丢弃,但继续等 END,不提前结束。
    }

    if (is_end && s_acc.active) {
        codex_dispatch_message();
        s_acc.active = false;
        s_acc.len = 0;
    }

    return 0;
}

// CMD 特征值只用于设备向 Mac 发送 indicate,协议上不需要被读/写。但 NimBLE
// 的 ble_gatts_chr_is_sane() 在注册阶段要求每个特征值的 access_cb 非空
// (见 nimble/nimble/host/src/ble_gatts.c),所以这里放一个永远不会被真正
// 触发的桩函数 —— 这个特征值没有 READ/WRITE 属性,peer 也就没有合法的
// 途径能走到这个回调里。
static int codex_cmd_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                               struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)ctxt;
    (void)arg;
    return BLE_ATT_ERR_UNLIKELY;
}

// AUDIO 特征值跟 CMD 一样只用于设备 -> Mac 的 notify,同样的原因需要一个
// 非空、但永远不会被真正触发的 access_cb 桩函数。
static int codex_audio_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                                 struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle;
    (void)attr_handle;
    (void)ctxt;
    (void)arg;
    return BLE_ATT_ERR_UNLIKELY;
}

static uint16_t s_data_chr_val_handle;
static uint16_t s_cmd_chr_val_handle;
static uint16_t s_audio_chr_val_handle;

// 构造 3 字节请求 mbuf,通过 CMD 特征值 indicate 给 Mac。按键触发的几处
// (READING 翻页/进入 WORKSPACES/进入 SESSIONS/打开会话)和订阅触发的那一处
// 都走这个 helper。没有连接时静默跳过 —— indicate 失败不是致命错误,只记
// 一条日志。
static void codex_send_cmd(uint8_t req, uint8_t param_a, uint8_t param_b)
{
    if (!ble_hub_is_connected()) {
        return;
    }
    uint8_t payload[3] = { req, param_a, param_b };
    struct os_mbuf *om = ble_hs_mbuf_from_flat(payload, sizeof(payload));
    if (!om) {
        ESP_LOGW(TAG, "构造 CMD indicate mbuf 失败(内存不足)");
        return;
    }
    // ble_gatts_indicate_custom() 无论成功与否都会消费掉这个 mbuf,不用手动释放。
    int rc = ble_gatts_indicate_custom(ble_hub_conn_handle(), s_cmd_chr_val_handle, om);
    if (rc != 0) {
        ESP_LOGW(TAG, "发送 CMD 请求失败: req=%d rc=%d", req, rc);
    }
}

// ---- READING 视图:长按 DOWN 说话 -> 流式 ADPCM 编码 -> AUDIO 特征值 notify ----
// 只在 CODEX_VIEW_READING 生效,由 demo_codex_key() 触发/终止,详见文件末尾。
#define VOICE_SAMPLE_RATE    16000
#define VOICE_CHUNK_SAMPLES  512                          // 每批读取的采样数,跟 demo_audio.c 的 CHUNK_SAMPLES 一致
#define VOICE_ADPCM_BYTES    (VOICE_CHUNK_SAMPLES / 2)     // 2 个采样拼 1 字节
#define VOICE_MAX_RECORD_US  (15LL * 1000 * 1000)          // 15 秒硬上限,到点当普通松开处理,不是错误
#define VOICE_MIN_ATT_MTU    23                            // BLE 规范里的最小 ATT MTU,查询异常时的保底值
#define VOICE_TASK_JOIN_MS   500                           // demo_codex_exit() 等录音任务收尾的超时(一批采样才 32ms,足够)

// 只被 voice_record_task() 自己读写(同一时刻只有一个录音任务在跑),不需要
// volatile/跨任务同步。放文件静态而不是任务局部变量,省一份任务栈空间。
static int16_t s_voice_pcm[VOICE_CHUNK_SAMPLES];
static uint8_t s_voice_adpcm[VOICE_ADPCM_BYTES];
static bool    s_voice_sent_start;

// s_voice_recording:是否应该继续录 —— demo_codex_key() 和 voice_record_task()
// 都会读写,volatile。s_voice_task_busy:录音任务是否还活着(从创建到它真正
// 自我删除前),防止上一次任务还没收尾干净时又并发起第二个。s_voice_task_done:
// 任务退出前 give 一次,demo_codex_exit() 借此等它真正结束,而不是掐了就走
// (那样 ble_stop() 把 NimBLE 栈拆掉后,任务如果还在跑到 notify 调用会踩坏内存)。
static volatile bool     s_voice_recording;
static volatile bool     s_voice_task_busy;
static SemaphoreHandle_t s_voice_task_done;

// 把 data[0..len) 按当前协商 ATT MTU 拆成一条或多条 notify 发出去。START 位
// 只打在整个说话会话的第一个分片上(s_voice_sent_start 记录);END 由
// voice_send_end() 单独发,这里不处理。len 可以是 0。
// ⚠ 只能从 voice_record_task() 里调用 —— 只碰 NimBLE API 和本节这几个
// task-私有状态,不碰 LVGL,遵循 codex_send_cmd() 已验证过的"按键/后台任务
// 直接发 BLE"的并发约束。
static void voice_send_data(const uint8_t *data, int len)
{
    if (!ble_hub_is_connected()) {
        return;
    }

    uint16_t mtu = ble_att_mtu(ble_hub_conn_handle());
    if (mtu < VOICE_MIN_ATT_MTU) mtu = VOICE_MIN_ATT_MTU;
    int max_payload = (int)mtu - 3 /* ATT opcode+handle */ - 1 /* 本协议 flags 字节 */;
    if (max_payload > VOICE_ADPCM_BYTES) max_payload = VOICE_ADPCM_BYTES;
    if (max_payload < 1) max_payload = 1;

    int off = 0;
    do {
        int n = len - off;
        if (n > max_payload) n = max_payload;

        uint8_t frame[1 + VOICE_ADPCM_BYTES];
        frame[0] = s_voice_sent_start ? 0 : CODEX_VOICE_FLAG_START;
        s_voice_sent_start = true;
        if (n > 0) memcpy(frame + 1, data + off, n);

        struct os_mbuf *om = ble_hs_mbuf_from_flat(frame, 1 + n);
        if (!om) {
            ESP_LOGW(TAG, "构造 AUDIO notify mbuf 失败(内存不足)");
            return;
        }
        // ble_gatts_notify_custom() 无论成功与否都会消费掉这个 mbuf。丢包
        // (rc != 0)不是致命错误 —— notify 本来就不保证送达,只记日志。
        int rc = ble_gatts_notify_custom(ble_hub_conn_handle(), s_audio_chr_val_handle, om);
        if (rc != 0) {
            ESP_LOGW(TAG, "发送语音分片失败: rc=%d", rc);
        }
        off += n;
    } while (off < len);
}

// 收尾:发一个只有 END 位的空分片(如果这次说话一个数据分片都没发出去过,
// 顺便把 START 位也带上,让 Mac 端至少能收到一次边界标记)。
static void voice_send_end(void)
{
    if (!ble_hub_is_connected()) {
        return;
    }
    uint8_t flags = CODEX_VOICE_FLAG_END | (s_voice_sent_start ? 0 : CODEX_VOICE_FLAG_START);
    uint8_t frame[1] = { flags };
    struct os_mbuf *om = ble_hs_mbuf_from_flat(frame, sizeof(frame));
    if (!om) {
        ESP_LOGW(TAG, "构造 AUDIO END mbuf 失败(内存不足)");
        return;
    }
    int rc = ble_gatts_notify_custom(ble_hub_conn_handle(), s_audio_chr_val_handle, om);
    if (rc != 0) {
        ESP_LOGW(TAG, "发送语音结束分片失败: rc=%d", rc);
    }
}

// 独立任务:每次"长按 DOWN 说话"创建一个,循环 读采样->编码->notify,直到
// s_voice_recording 被 demo_codex_key() 置回 false,或者累计时长超过 15 秒
// 硬上限(此时自己把 s_voice_recording 置 false,按正常松开收尾,不是报错)。
// 音频收发要放独立任务、不能占用按键回调/LVGL 任务这条约束照抄 demo_audio.c。
static void voice_record_task(void *arg)
{
    (void)arg;

    adpcm_state_t st = { .predictor = 0, .step_index = 0 };   // 每次说话从头初始化,不跨话音复用
    bool audio_acquired = false;
    s_voice_sent_start = false;

    if (!bsp_audio_acquire(500)) {
        ESP_LOGW(TAG, "语音录制:音频设备正忙");
        s_voice_recording = false;
        goto done;
    }
    audio_acquired = true;

    if (bsp_audio_set_format(VOICE_SAMPLE_RATE, 16, 1) != ESP_OK) {
        ESP_LOGE(TAG, "语音录制:设置音频格式失败");
        s_voice_recording = false;
        goto done;
    }

    {
        int64_t start_us = esp_timer_get_time();
        while (s_voice_recording) {
            if (esp_timer_get_time() - start_us >= VOICE_MAX_RECORD_US) {
                ESP_LOGI(TAG, "语音录制:达到 15 秒硬上限,按松开处理");
                s_voice_recording = false;
                break;
            }
            if (bsp_audio_read(s_voice_pcm, sizeof(s_voice_pcm)) != ESP_OK) {
                ESP_LOGW(TAG, "语音录制:读取音频失败,提前结束本次录音");
                s_voice_recording = false;
                break;
            }
            int n = adpcm_encode_block(&st, s_voice_pcm, VOICE_CHUNK_SAMPLES, s_voice_adpcm);
            voice_send_data(s_voice_adpcm, n);
        }
    }

done:
    voice_send_end();
    if (audio_acquired) bsp_audio_release();
    s_voice_task_busy = false;
    if (s_voice_task_done) xSemaphoreGive(s_voice_task_done);
    vTaskDelete(NULL);
}

// DOWN 长按(BSP_BTN_LONG)命中时由 demo_codex_key() 调用。运行在按键回调
// 里,已经持有 LVGL 锁(main.c 的 on_key()),但这里只碰普通 C 变量和
// xTaskCreate(),不碰 LVGL 对象。
void codex_voice_start(void)
{
    // 清掉上一次录音留下的"已完成"信号,确保 demo_codex_exit() 将来
    // xSemaphoreTake() 等到的是*这次*任务的收尾,而不是历史残留。
    if (s_voice_task_done) xSemaphoreTake(s_voice_task_done, 0);

    s_voice_recording = true;
    s_voice_task_busy = true;
    if (xTaskCreate(voice_record_task, "codex_voice", 4096, NULL, 4, NULL) != pdPASS) {
        ESP_LOGE(TAG, "语音录制任务创建失败(内存不足)");
        s_voice_recording = false;
        s_voice_task_busy = false;
        // 任务没建成,不会有人来 give 这个信号量了,自己补上,别让将来的
        // demo_codex_exit() 对着一个不存在的任务空等 500ms。
        if (s_voice_task_done) xSemaphoreGive(s_voice_task_done);
    }
}

void codex_voice_stop(void)
{
    // 只置标志,不强杀任务:录音任务下一次检查这个标志会自己收尾、把最后
    // 半个分片和 END 标记发完。强杀会让对端永远等不到 END,那一句话就卡在
    // 转写管线里不出来。
    s_voice_recording = false;
}

bool codex_voice_active(void)
{
    return s_voice_recording;
}

static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            {
                // DATA:Mac -> 设备,只写(with response),六字节头分片重组。
                .uuid = &s_data_uuid.u,
                .access_cb = codex_data_access_cb,
                .flags = BLE_GATT_CHR_F_WRITE,
                .val_handle = &s_data_chr_val_handle,
            },
            {
                // CMD:设备 -> Mac,只 indicate(不是 notify —— 要链路层确认,
                // 降低请求丢包风险)。CoreBluetooth 订阅方式和 notify 完全
                //一样,都是 setNotifyValue(true, for:)。
                .uuid = &s_cmd_uuid.u,
                .access_cb = codex_cmd_access_cb,
                .flags = BLE_GATT_CHR_F_INDICATE,
                .val_handle = &s_cmd_chr_val_handle,
            },
            {
                // AUDIO:设备 -> Mac,只 notify(不是 indicate ——语音是连续
                // 流,要吞吐量,丢一两个包只是转写质量打折扣,不值得每包等
                // 链路层确认)。READING 视图长按 DOWN 说话时,由录音任务
                // (main/demo_codex.c 的 voice_record_task())持续调用。
                .uuid = &s_audio_uuid.u,
                .access_cb = codex_audio_access_cb,
                .flags = BLE_GATT_CHR_F_NOTIFY,
                .val_handle = &s_audio_chr_val_handle,
            },
            { 0 },
        },
    },
    { 0 },
};

typedef enum {
    CODEX_STATE_OFF = 0,
    CODEX_STATE_STARTING,
    CODEX_STATE_ADVERTISING,
    CODEX_STATE_CONNECTED,
    CODEX_STATE_FAILED,
} codex_state_t;

// ---- 接入常驻 BLE(见 ble_hub.h) -------------------------------------------
// 这个模块以前自己拥有一整套 NimBLE 协议栈,随 Codex 页面的进出而起停。改成
// 由 ble_hub 常驻持有之后:
//   · 不会再因为用户切了个页面就断链、重连、重新走一遍服务发现;
//   · 也不会再和"应用商店"抢协议栈 —— 以前是靠 main.c 的 view 状态机保证两
//     个页面互斥才没撞车,那是个很脆的隐式约束。
// 这里只保留自己的 GATT service 定义和连接事件回调。

static void on_ble_subscribe(uint16_t attr_handle, bool subscribed)
{
    if (attr_handle != s_cmd_chr_val_handle || !subscribed) return;
    // 对端完成服务发现后订阅 CMD indicate,这一刻(而不是 CONNECT 时,那时
    // 对端还没订阅,indicate 必然失败)才是发首次请求的正确时机。每次重连都
    // 会重新走一遍订阅流程,自动重新触发,不需要额外逻辑。
    ESP_LOGI(TAG, "对端已订阅 CMD indicate,发送 REQ_ACTIVE_SESSION");
    codex_send_cmd(CODEX_REQ_ACTIVE_SESSION, 0, 0);
}

static const ble_hub_observer_t s_ble_observer = {
    .on_subscribe = on_ble_subscribe,
};

void codex_ble_register(void)
{
    ble_hub_register_service(s_gatt_svcs);
    ble_hub_register_observer(&s_ble_observer);
}

// ---- LVGL 对象 --------------------------------------------------------------
#define CODEX_ROW_W            190   // READING 内容 label 的换行宽度
#define CODEX_READING_SCROLL_STEP 60 // 上/下一次滚动的像素量,约 3~4 行
#define CODEX_LIST_VISIBLE_ROWS 7    // WORKSPACES/SESSIONS 一屏能放几行
#define CODEX_LIST_ROW_X        14
#define CODEX_LIST_ROW_Y0       40
#define CODEX_LIST_ROW_W       212
#define CODEX_LIST_ROW_H        32
#define CODEX_LIST_ROW_STEP     34

static lv_obj_t   *s_scr;
static lv_obj_t   *s_status;                        // 顶部一行状态/位置提示
static lv_obj_t   *s_reading_panel;                 // READING:面板容器
static lv_obj_t   *s_reading_label;                 // READING:当前页内容(单个 label)
static lv_obj_t   *s_list_cards[CODEX_LIST_VISIBLE_ROWS];   // WORKSPACES/SESSIONS 共用的行卡片
static lv_obj_t   *s_list_rows[CODEX_LIST_VISIBLE_ROWS];    // 对应的行文字
static lv_obj_t   *s_footer;                        // 底部按键提示
static lv_timer_t *s_timer;

// 取 WORKSPACES(is_workspace=true)或 SESSIONS(false)列表里第 idx 项的显示
// 文本;还没收到就先显示占位符,不留空白行。
static const char *codex_list_item_text(bool is_workspace, int idx)
{
    if (is_workspace) {
        return s_workspaces[idx].got ? s_workspaces[idx].name : "...";
    }
    return s_sessions[idx].got ? s_sessions[idx].text : "...";
}

// lv_timer 跑在 LVGL 任务里,已持有锁,可以直接操作对象。
static void render_reading(void)
{
    // 每次都是"新到的一页"内容(render_reading 只在 s_dirty 时被调用,不是
    // 每个 tick 都跑),回到顶部重新开始读,不保留上一页滚动到一半的位置。
    lv_obj_scroll_to_y(s_reading_panel, 0, LV_ANIM_OFF);

    // 钉住的错误提示优先级最高,盖住下面的真实内容,直到用户按键确认。
    if (s_error_pinned) {
        lv_label_set_text(s_reading_label, s_error_text);
        lv_obj_set_style_text_color(s_reading_label, lv_color_hex(UI_RED), 0);
        lv_obj_set_style_text_align(s_reading_label, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_align(s_reading_label, LV_ALIGN_CENTER, 0, 0);
        return;
    }

    if (!s_reading.has_data) {
        lv_label_set_text(s_reading_label, "加载中");
        lv_obj_set_style_text_color(s_reading_label, lv_color_hex(UI_INK_SOFT), 0);
        lv_obj_set_style_text_align(s_reading_label, LV_TEXT_ALIGN_CENTER, 0);
        lv_obj_align(s_reading_label, LV_ALIGN_CENTER, 0, 0);
        return;
    }

    uint32_t color;
    bool centered;
    const char *prefix;

    switch (s_reading.kind) {
    case CODEX_KIND_PAGE_USER:
        color = UI_ACCENT;
        centered = false;
        prefix = "Me: ";
        break;
    case CODEX_KIND_PAGE_ASSISTANT:
        color = UI_INK;
        centered = false;
        prefix = "Codex: ";
        break;
    default:    // CODEX_KIND_STATUS:一次性短提示,居中显示、不加前缀
        color = UI_INK_SOFT;
        centered = true;
        prefix = NULL;
        break;
    }

    // ⚠ 不用 snprintf 现拼一份"前缀+正文"的完整副本 —— s_reading.text 最长
    // 可达 CODEX_MSG_MAX_LEN(1120)字节,拼接缓冲区跟着开到超过 1KB 的栈变量,
    // 白白占用本函数所在的 LVGL 任务栈。直接把 label 设成前缀,再用
    // lv_label_ins_text() 在 LVGL 自己管理的内部缓冲区里原地追加正文,
    // 不需要本地大缓冲区。
    if (prefix) {
        lv_label_set_text(s_reading_label, prefix);
        lv_label_ins_text(s_reading_label, LV_LABEL_POS_LAST, s_reading.text);
    } else {
        lv_label_set_text(s_reading_label, s_reading.text);
    }
    lv_obj_set_style_text_color(s_reading_label, lv_color_hex(color), 0);
    lv_obj_set_style_text_align(s_reading_label,
        centered ? LV_TEXT_ALIGN_CENTER : LV_TEXT_ALIGN_LEFT, 0);
    // ⚠ 每次都显式调用 lv_obj_align() 重新声明对齐方式,而不是只在居中分支
    // 调 lv_obj_align/center、在左对齐分支改用 lv_obj_set_pos —— LVGL 的
    // "align" 是持久样式属性,set_pos 并不会清掉上一次留下的居中对齐,两种
    // 调用混用会导致换回左对齐分支时位置仍然被居中样式接管。
    lv_obj_align(s_reading_label,
        centered ? LV_ALIGN_CENTER : LV_ALIGN_TOP_LEFT, 0, 0);
}

static void render_list(bool is_workspace, int count, int sel)
{
    if (count <= 0) {
        for (int r = 0; r < CODEX_LIST_VISIBLE_ROWS; r++) {
            lv_obj_add_flag(s_list_cards[r], LV_OBJ_FLAG_HIDDEN);
        }
        return;
    }

    // 滚动窗口跟随选中项:窗口大小固定 CODEX_LIST_VISIBLE_ROWS,起点取
    // "让 sel 落在窗口最后一行" 和 "不超过列表末尾" 之间的较小值,再夹在
    // [0, count-VISIBLE_ROWS] 内 —— 选中项因此始终落在可视窗口内。
    int scroll_top = sel - (CODEX_LIST_VISIBLE_ROWS - 1);
    if (scroll_top < 0) scroll_top = 0;
    int max_top = count - CODEX_LIST_VISIBLE_ROWS;
    if (max_top < 0) max_top = 0;
    if (scroll_top > max_top) scroll_top = max_top;

    for (int r = 0; r < CODEX_LIST_VISIBLE_ROWS; r++) {
        int idx = scroll_top + r;
        if (idx >= count) {
            lv_obj_add_flag(s_list_cards[r], LV_OBJ_FLAG_HIDDEN);
            continue;
        }
        lv_obj_remove_flag(s_list_cards[r], LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(s_list_rows[r], codex_list_item_text(is_workspace, idx));
        ui_pixel_set_selected(s_list_cards[r], idx == sel, true);
    }
}

static void render_content(void)
{
    bool reading = (s_view == CODEX_VIEW_READING);

    if (reading) {
        lv_obj_remove_flag(s_reading_panel, LV_OBJ_FLAG_HIDDEN);
        for (int r = 0; r < CODEX_LIST_VISIBLE_ROWS; r++) {
            lv_obj_add_flag(s_list_cards[r], LV_OBJ_FLAG_HIDDEN);
        }
        render_reading();
    } else {
        lv_obj_add_flag(s_reading_panel, LV_OBJ_FLAG_HIDDEN);
        bool is_workspace = (s_view == CODEX_VIEW_WORKSPACES);
        int count = is_workspace ? workspace_known_count() : session_known_count();
        int sel = is_workspace ? s_workspace_sel : s_session_sel;
        render_list(is_workspace, count, sel);
    }

    switch (s_view) {
    case CODEX_VIEW_READING:
        lv_label_set_text(s_footer,
            s_error_pinned ? "按任意键关闭" : "上/下翻页  确定 浏览会话");
        break;
    case CODEX_VIEW_WORKSPACES:
        lv_label_set_text(s_footer, "上/下选择  确定查看会话  双击返回");
        break;
    case CODEX_VIEW_SESSIONS:
        lv_label_set_text(s_footer, "上/下选择  确定打开会话  双击返回");
        break;
    }
}

static void tick(lv_timer_t *timer)
{
    (void)timer;
    // 连接状态现在由常驻的 ble_hub 持有 —— 这个页面不再自己起停协议栈,
    // 也就不再有"正在启动/广播失败"这类只有栈拥有者才知道的中间状态。
    switch (ble_hub_is_connected() ? CODEX_STATE_CONNECTED : CODEX_STATE_ADVERTISING) {
    case CODEX_STATE_STARTING:
        lv_obj_remove_flag(s_status, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(s_status, "正在启动蓝牙...");
        break;
    case CODEX_STATE_ADVERTISING:
        lv_obj_remove_flag(s_status, LV_OBJ_FLAG_HIDDEN);
        lv_label_set_text(s_status, "正在广播,等待连接");
        break;
    case CODEX_STATE_CONNECTED:
        // 钉住的错误提示优先级最高,顶部这行让位给"按键关闭"的提示。
        if (s_error_pinned) {
            lv_obj_remove_flag(s_status, LV_OBJ_FLAG_HIDDEN);
            lv_label_set_text(s_status, "发送失败  按任意键关闭");
            break;
        }
        // 正在录音:顶部这行整体让位给录音提示,直到松开(BSP_BTN_LONG_UP)
        // 或到 15 秒硬上限自动结束 —— 结束后 s_voice_recording 变回 false,
        // 下一次 tick() 自然回落到下面按视图显示的正常逻辑,不需要额外的
        // "恢复"代码。
        if (s_voice_recording) {
            lv_obj_remove_flag(s_status, LV_OBJ_FLAG_HIDDEN);
            lv_label_set_text(s_status, "录音中...松开发送");
            break;
        }
        // 已连接:顶部这行按当前视图切换用途——READING 显示页码(STATUS 类
        // 型的页不显示,直接隐藏,交给内容区自己居中显示提示文字),
        // WORKSPACES/SESSIONS 数据没到齐前显示"加载中"。
        switch (s_view) {
        case CODEX_VIEW_READING:
            if (!s_reading.has_data) {
                lv_obj_remove_flag(s_status, LV_OBJ_FLAG_HIDDEN);
                lv_label_set_text(s_status, "加载中");
            } else if (s_reading.kind == CODEX_KIND_STATUS) {
                lv_obj_add_flag(s_status, LV_OBJ_FLAG_HIDDEN);
            } else {
                lv_obj_remove_flag(s_status, LV_OBJ_FLAG_HIDDEN);
                lv_label_set_text_fmt(s_status, "第 %d/%d 页",
                                      s_reading.index + 1, s_reading.total);
            }
            break;
        case CODEX_VIEW_WORKSPACES:
            lv_obj_remove_flag(s_status, LV_OBJ_FLAG_HIDDEN);
            lv_label_set_text(s_status,
                workspace_known_count() > 0 ? "选择工作区" : "加载中");
            break;
        case CODEX_VIEW_SESSIONS:
            lv_obj_remove_flag(s_status, LV_OBJ_FLAG_HIDDEN);
            lv_label_set_text(s_status,
                session_known_count() > 0 ? "选择会话" : "加载中");
            break;
        }
        break;
    default:
        break;
    }

    if (s_dirty) {
        s_dirty = false;
        render_content();
    }
}

void demo_codex_enter(void)
{
    s_scr = ui_pixel_screen_create("Codex");

    s_status = lv_label_create(s_scr);
    lv_obj_set_pos(s_status, 14, 14);
    lv_obj_set_width(s_status, 208);
    lv_obj_set_style_text_font(s_status, &lv_font_ui_cn_14, 0);
    lv_obj_set_style_text_color(s_status, lv_color_hex(UI_INK_SOFT), 0);
    lv_label_set_text(s_status, "正在启动蓝牙...");

    // READING 视图:面板 + 单个内容 label(左上角正常段落 / 面板居中的
    // 加载中或状态提示,两种模式共用同一个 label,靠 render_reading() 切换)。
    s_reading_panel = ui_pixel_panel_create(s_scr, 12, 40, 216, 268, UI_PAPER);
    lv_obj_set_style_border_width(s_reading_panel, 0, 0);   // 不需要外边框
    // ui_pixel_panel_create()(经由 block())默认关掉了滚动 —— 这里的正文
    // 长度不保证能塞进一屏,是这几个面板里唯一需要能滚动查看的,所以显式
    // 加回来;只允许竖向滚动,避免跟换行宽度产生的横向留白冲突。
    lv_obj_add_flag(s_reading_panel, LV_OBJ_FLAG_SCROLLABLE);
    lv_obj_set_scroll_dir(s_reading_panel, LV_DIR_VER);
    s_reading_label = lv_label_create(s_reading_panel);
    lv_obj_set_width(s_reading_label, CODEX_ROW_W);
    lv_label_set_long_mode(s_reading_label, LV_LABEL_LONG_WRAP);
    lv_obj_set_style_text_font(s_reading_label, &lv_font_ui_cn_14, 0);

    // WORKSPACES/SESSIONS 共用的滚动列表行,视觉上照抄 main.c 里"设置"子菜单
    // 的列表行(卡片 + label,选中项用 ui_pixel_set_selected 高亮)。
    for (int r = 0; r < CODEX_LIST_VISIBLE_ROWS; r++) {
        int y = CODEX_LIST_ROW_Y0 + r * CODEX_LIST_ROW_STEP;
        lv_obj_t *card = ui_pixel_panel_create(s_scr, CODEX_LIST_ROW_X, y,
                                               CODEX_LIST_ROW_W, CODEX_LIST_ROW_H, UI_PAPER);
        lv_obj_t *row = lv_label_create(card);
        lv_obj_set_style_text_font(row, &lv_font_ui_cn_14, 0);
        lv_obj_set_style_text_color(row, lv_color_hex(UI_INK), 0);
        lv_obj_align(row, LV_ALIGN_LEFT_MID, 9, 0);
        lv_obj_add_flag(card, LV_OBJ_FLAG_HIDDEN);
        s_list_cards[r] = card;
        s_list_rows[r] = row;
    }

    s_footer = ui_pixel_label(s_scr, "上/下翻页  确定 浏览会话", &lv_font_ui_cn_14, UI_MUTED);
    lv_obj_align(s_footer, LV_ALIGN_BOTTOM_MID, 0, -8);

    // 每次进页面都从空状态开始,避免上一次连接残留的数据造成困惑。
    s_view = CODEX_VIEW_READING;
    reset_workspace_cache();
    reset_session_cache();
    clear_reading_cache();
    s_selected_workspace_idx = 0;
    memset(&s_acc, 0, sizeof(s_acc));
    s_dirty = true;

    // 语音录制状态同样每次进页面重置一次(正常情况下 exit() 已经等录音任务
    // 收尾干净了,这里只是防御性地保证不带着上一次的残留状态进来)。
    s_voice_recording = false;
    s_voice_task_busy = false;
    if (!s_voice_task_done) s_voice_task_done = xSemaphoreCreateBinary();
    s_error_pinned = false;   // 同样不带着上一次的残留错误提示进来

    s_timer = lv_timer_create(tick, 100, NULL);
    lv_screen_load(s_scr);
}

void demo_codex_exit(void)
{
    if (s_timer) {
        lv_timer_delete(s_timer);
        s_timer = NULL;
    }

    // 有录音任务在跑(或者刚被要求停但还没收尾)就先等它真正退出再走。
    // BLE 栈现在是常驻的、不会被这里拆掉,所以已经没有"任务还在跑就把
    // NimBLE 拆了"这类踩内存的风险了;但仍然要等它收尾 —— 否则任务会继续
    // 往一个已经删掉的界面推数据,而且下次进页面时状态是脏的。任务一批采样
    // 只需 32ms,VOICE_TASK_JOIN_MS(500ms)绰绰有余;真超时了也只是继续
    // 往下走,不会卡死退出流程。
    if (s_voice_recording || s_voice_task_busy) {
        s_voice_recording = false;
        if (s_voice_task_done) {
            if (xSemaphoreTake(s_voice_task_done, pdMS_TO_TICKS(VOICE_TASK_JOIN_MS)) != pdTRUE) {
                ESP_LOGW(TAG, "等待语音录制任务收尾超时,继续退出流程");
            }
        }
    }
    if (s_voice_task_done) {
        vSemaphoreDelete(s_voice_task_done);
        s_voice_task_done = NULL;
    }

    if (s_scr) {
        lv_obj_delete(s_scr);
        s_scr = NULL;
        s_status = NULL;
        s_reading_panel = NULL;
        s_reading_label = NULL;
        for (int r = 0; r < CODEX_LIST_VISIBLE_ROWS; r++) {
            s_list_cards[r] = NULL;
            s_list_rows[r] = NULL;
        }
        s_footer = NULL;
    }
}

// 上下移动选中项:clamp 在 [0, count-1],不像菜单那样首尾循环 —— count<=0
// (一项都还没收到)时什么也不做。
static void move_selection(int *sel, int count, bool up)
{
    if (count <= 0) return;
    if (up) {
        if (*sel > 0) (*sel)--;
    } else {
        if (*sel < count - 1) (*sel)++;
    }
    s_dirty = true;
}

// ⚠ OK 长按(BSP_BTN_LONG)已经被 main.c 全局拦截,用来退出 Codex 页回到顶层
// 菜单,这里永远收不到那个组合,不用处理。
// 上/下这里响应 CLICK 或 HOLD(不是 PRESS)—— 用 PRESS 会导致一次点按同时
// 触发 PRESS 和随后的 CLICK,变成重复翻页/移动两次;HOLD 是长按后的持续
// 节拍触发,CLICK 是点按抬起,两者都不会跟另一者重叠计数。
void demo_codex_key(bsp_btn_t btn, bsp_btn_ev_t ev)
{
    // 错误提示钉住时优先级最高:吞掉 READING 视图里的所有按键,只有真正的
    // 一次按键动作(CLICK/LONG/DOUBLE,不是 PRESS/HOLD 这种瞬时/连发事件)
    // 才会把它关掉,关掉本身也不再往下走(避免这次按键同时被当成翻页/进入
    // 会话列表处理)。只在 READING 生效,因为提示本来也只在这个视图里画,
    // 不然用户切到别的视图会发现按键全部失灵,却根本看不到是什么挡住了。
    if (s_view == CODEX_VIEW_READING && s_error_pinned) {
        if (ev == BSP_BTN_CLICK || ev == BSP_BTN_LONG || ev == BSP_BTN_DOUBLE) {
            s_error_pinned = false;
            s_dirty = true;
        }
        return;
    }

    // READING 视图专属的"长按 DOWN 说话"手势:命中 LONG 开始录音、LONG_UP
    // 结束录音,两个分支各自 return,不影响下面的翻页逻辑。
    //
    // 注意:不再吞掉录音期间的其它 DOWN 事件。之前会在录音期间屏蔽
    // BSP_BTN_HOLD,但 HOLD 正是这个功能加入前 READING 视图唯一的"长按连续
    // 下翻"手势——长按超过 CONFIG_BUTTON_LONG_PRESS_TIME_MS(500ms)会先触发
    // 一次 LONG 进入录音,之后每次 HOLD 都被吞掉,导致长按 DOWN 彻底不能翻页
    // 了。滚动只碰 LVGL 面板对象,录音是独立任务只看 s_voice_recording/BLE,
    // 两者互不干扰,放行即可两者都要。
    if (s_view == CODEX_VIEW_READING && btn == BSP_BTN_DOWN) {
        if (ev == BSP_BTN_LONG && !s_voice_recording && !s_voice_task_busy) {
            codex_voice_start();
            return;
        }
        if (ev == BSP_BTN_LONG_UP && s_voice_recording) {
            s_voice_recording = false;   // 任务下一次检查这个标志会自然收尾、发 END,不用在这里强行杀任务
            return;
        }
    }

    bool up_down = (btn == BSP_BTN_UP || btn == BSP_BTN_DOWN);
    bool nav = up_down && (ev == BSP_BTN_CLICK || ev == BSP_BTN_HOLD);
    bool ok_click = (btn == BSP_BTN_OK && ev == BSP_BTN_CLICK);
    bool ok_double = (btn == BSP_BTN_OK && ev == BSP_BTN_DOUBLE);
    bool up = (btn == BSP_BTN_UP);

    switch (s_view) {
    case CODEX_VIEW_READING:
        if (nav) {
            // 一页的正文不保证能塞进一屏,所以上/下先在当前页里滚动;只有
            // 已经滚到这页的顶/底、再按同一个方向,才去翻上一页/下一页。
            if (up) {
                if (lv_obj_get_scroll_y(s_reading_panel) > 0) {
                    lv_obj_scroll_by(s_reading_panel, 0, CODEX_READING_SCROLL_STEP, LV_ANIM_OFF);
                } else if (s_reading.has_data && s_reading.index > 0) {
                    codex_send_cmd(CODEX_REQ_PAGE, 0, 0);   // 0 = 上一页
                }
            } else {
                if (lv_obj_get_scroll_bottom(s_reading_panel) > 0) {
                    lv_obj_scroll_by(s_reading_panel, 0, -CODEX_READING_SCROLL_STEP, LV_ANIM_OFF);
                } else if (s_reading.has_data && s_reading.index < s_reading.total - 1) {
                    codex_send_cmd(CODEX_REQ_PAGE, 1, 0);   // 1 = 下一页
                }
            }
        } else if (ok_click) {
            reset_workspace_cache();
            s_view = CODEX_VIEW_WORKSPACES;
            s_dirty = true;
            codex_send_cmd(CODEX_REQ_LIST_WORKSPACES, 0, 0);
        }
        // ok_double:READING 已经是最外层,无操作。
        break;

    case CODEX_VIEW_WORKSPACES:
        if (nav) {
            move_selection(&s_workspace_sel, workspace_known_count(), up);
        } else if (ok_click) {
            if (workspace_known_count() > 0) {
                s_selected_workspace_idx = s_workspace_sel;
                reset_session_cache();
                s_view = CODEX_VIEW_SESSIONS;
                s_dirty = true;
                codex_send_cmd(CODEX_REQ_LIST_SESSIONS, (uint8_t)s_selected_workspace_idx, 0);
            }
        } else if (ok_double) {
            // 工作区列表缓存还在,直接切回 READING,复原原来那页,不发请求。
            s_view = CODEX_VIEW_READING;
            s_dirty = true;
        }
        break;

    case CODEX_VIEW_SESSIONS:
        if (nav) {
            move_selection(&s_session_sel, session_known_count(), up);
        } else if (ok_click) {
            if (session_known_count() > 0) {
                clear_reading_cache();
                s_view = CODEX_VIEW_READING;
                s_dirty = true;
                codex_send_cmd(CODEX_REQ_OPEN_SESSION,
                               (uint8_t)s_selected_workspace_idx, (uint8_t)s_session_sel);
            }
        } else if (ok_double) {
            // 工作区列表缓存还在,直接切回 WORKSPACES,不发请求。
            s_view = CODEX_VIEW_WORKSPACES;
            s_dirty = true;
        }
        break;
    }
}
