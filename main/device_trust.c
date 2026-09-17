#include "device_trust.h"
#include "device_trust_index.h"
#include "device_trust_protocol.h"
#include "ble_hub.h"
#include "appstore_transfer.h"
#include "demo.h"
#include "walkie_audio.h"

#include "esp_log.h"
#include "esp_mac.h"
#include "esp_timer.h"
#include "freertos/FreeRTOS.h"
#include "freertos/semphr.h"
#include "host/ble_att.h"
#include "host/ble_gatt.h"
#include "host/ble_hs.h"
#include "host/ble_sm.h"
#include "host/ble_store.h"
#include "host/ble_uuid.h"
#include "nvs.h"
#include "store/config/ble_store_config.h"
#include <ctype.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static const char *TAG = "device_trust";
static const char *NVS_NAMESPACE = "trust";

// NimBLE's config-store header intentionally exposes read/write/delete only;
// ESP-IDF's own examples declare the sysinit entry point locally.
void ble_store_config_init(void);

// Service: 4F6C6F10-7E2A-4C59-A4B1-3D8E91C72A00
// HELLO:   4F6C6F10-7E2A-4C59-A4B1-3D8E91C72A01
// STATE:   4F6C6F10-7E2A-4C59-A4B1-3D8E91C72A02
// COMMAND: 4F6C6F10-7E2A-4C59-A4B1-3D8E91C72A03
static const ble_uuid128_t s_svc_uuid =
    BLE_UUID128_INIT(0x00, 0x2A, 0xC7, 0x91, 0x8E, 0x3D, 0xB1, 0xA4,
                     0x59, 0x4C, 0x2A, 0x7E, 0x10, 0x6F, 0x6C, 0x4F);
static const ble_uuid128_t s_hello_uuid =
    BLE_UUID128_INIT(0x01, 0x2A, 0xC7, 0x91, 0x8E, 0x3D, 0xB1, 0xA4,
                     0x59, 0x4C, 0x2A, 0x7E, 0x10, 0x6F, 0x6C, 0x4F);
static const ble_uuid128_t s_state_uuid =
    BLE_UUID128_INIT(0x02, 0x2A, 0xC7, 0x91, 0x8E, 0x3D, 0xB1, 0xA4,
                     0x59, 0x4C, 0x2A, 0x7E, 0x10, 0x6F, 0x6C, 0x4F);
static const ble_uuid128_t s_command_uuid =
    BLE_UUID128_INIT(0x03, 0x2A, 0xC7, 0x91, 0x8E, 0x3D, 0xB1, 0xA4,
                     0x59, 0x4C, 0x2A, 0x7E, 0x10, 0x6F, 0x6C, 0x4F);

#define TRUST_STORE_VERSION       2
#define TRUST_RECORD_FREE         0
#define TRUST_RECORD_ACTIVE       1
#define TRUST_RECORD_REVOKED      2
#define PAIRING_WINDOW_US         (60LL * 1000000)
#define HANDOFF_WINDOW_US         (60LL * 1000000)
#define HANDOFF_RETRY_AFTER_SEC   20
#define HANDOFF_DISCONNECT_US     (500LL * 1000)
#define AUTH_HELLO_TIMEOUT_US     (12LL * 1000000)
#define STATE_BUF_LEN             768
#define AUTH_TX_CHUNK             180
#define AUTH_TX_DEPTH             16
#define AUTH_TX_CONFIRM_TIMEOUT_US (2LL * 1000000)
#define LEGACY_PEER_COOLDOWN_US   (60LL * 1000000)
#define LEGACY_ACTIVITY_GRACE_US  (3LL * 1000000)
#define LEGACY_PROBATION_INTERVAL_US (15LL * 1000000)

typedef struct {
    uint8_t used;
    uint8_t addr_type;
    uint8_t addr[6];
    uint8_t platform;
    char id[DEVICE_TRUST_ID_MAX + 1];
    char name[DEVICE_TRUST_NAME_MAX + 1];
    char app_version[25];
} trust_record_t;

typedef struct {
    uint8_t version;
    trust_record_t records[DEVICE_TRUST_MAX_COMPANIONS];
} trust_store_t;

static nvs_handle_t s_nvs;
static bool s_nvs_open;
static SemaphoreHandle_t s_persist_mutex;
static trust_store_t s_store;
static char s_alias[DEVICE_TRUST_ALIAS_MAX + 1];
static char s_device_id[5];

static uint16_t s_state_handle;
static uint16_t s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static bool s_state_subscribed;
static bool s_authorized;
static bool s_admission_granted;
static uint32_t s_connection_generation;
static device_trust_state_t s_state = DEVICE_TRUST_IDLE;
static uint32_t s_revision;
static int64_t s_pairing_deadline;
static bool s_enrollment_active;
static int64_t s_handoff_deadline;
static int64_t s_auth_deadline;
static int s_handoff_target = -1;
// RAM-only user intent. A manually disconnected trusted companion cannot
// immediately reclaim the single BLE slot. Physical selection or opening the
// pairing window clears this fence; reboot also deliberately clears it.
static int s_manually_disconnected_slot = -1;
static bool s_disconnect_pending;
static uint16_t s_disconnect_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static int64_t s_disconnect_not_before;
static int64_t s_disconnect_force_at;
static int s_retry_after;
static char s_reason[40];

static uint32_t s_numeric_code;
static bool s_confirmation_pending;
typedef enum {
    CONFIRM_NONE = 0,
    CONFIRM_SMP_NUMERIC,
    CONFIRM_RETRUST,
} confirmation_mode_t;
static confirmation_mode_t s_confirmation_mode;
static bool s_numeric_confirmed;
static bool s_reclaim_pending;
static int s_reclaim_slot = -1;
static ble_addr_t s_reclaim_addr;
static bool s_pairing_new;
static bool s_hello_received;
static bool s_stale_bond_repair_attempted;
static uint8_t s_platform;
static char s_companion_id[DEVICE_TRUST_ID_MAX + 1];
static char s_companion_name[DEVICE_TRUST_NAME_MAX + 1];
static char s_app_version[25];
static bool s_name_update_pending;
static uint16_t s_name_update_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint32_t s_name_update_connection_generation;
static int s_name_update_slot = -1;
static char s_name_update_id[DEVICE_TRUST_ID_MAX + 1];
static char s_name_update_value[DEVICE_TRUST_NAME_MAX + 1];
static ble_addr_t s_peer_id_addr;
// The currently connected central is remembered before HELLO arrives.  This
// lets us quarantine legacy companion builds which discover and subscribe to
// feature services without ever entering the authentication protocol.
static bool s_link_peer_valid;
static ble_addr_t s_link_peer_id_addr;
static ble_addr_t s_link_peer_ota_addr;
static bool s_legacy_activity_seen;
static bool s_quarantine_active;
static int64_t s_quarantine_deadline;
static int64_t s_quarantine_next_probation;
static ble_addr_t s_quarantined_peer_id_addr;
static ble_addr_t s_quarantined_peer_ota_addr;

typedef struct {
    uint16_t len;
    uint16_t offset;
    uint8_t data[STATE_BUF_LEN];
} auth_tx_item_t;

static auth_tx_item_t s_tx_queue[AUTH_TX_DEPTH];
static uint8_t s_tx_head;
static uint8_t s_tx_tail;
static uint8_t s_tx_count;
static bool s_tx_sending;
static int64_t s_tx_started_at;
static uint32_t s_tx_generation;
static uint16_t s_tx_inflight_len;
static uint16_t s_tx_inflight_conn_handle = BLE_HS_CONN_HANDLE_NONE;
static uint32_t s_tx_inflight_conn_generation;
static uint32_t s_tx_inflight_tx_generation;
static portMUX_TYPE s_tx_mux = portMUX_INITIALIZER_UNLOCKED;
// Protects trust metadata, connection/auth state and deadlines shared by the
// NimBLE host task, the button/UI task and the housekeeping task. Never call
// NVS, NimBLE or LVGL while holding this lock.
static portMUX_TYPE s_state_mux = portMUX_INITIALIZER_UNLOCKED;

static const char *state_name(device_trust_state_t state)
{
    switch (state) {
    case DEVICE_TRUST_CONNECTED: return "connected";
    case DEVICE_TRUST_PAIRING: return "pairing";
    case DEVICE_TRUST_AWAITING_CONFIRMATION: return "awaiting_confirmation";
    case DEVICE_TRUST_AUTHORIZED: return "authorized";
    case DEVICE_TRUST_DENIED: return "denied";
    default: return "idle";
    }
}

static int trust_count_unlocked(void)
{
    int count = 0;
    for (int i = 0; i < DEVICE_TRUST_MAX_COMPANIONS; i++) {
        if (s_store.records[i].used == TRUST_RECORD_ACTIVE) count++;
    }
    return count;
}

static int trust_count_internal(void)
{
    portENTER_CRITICAL(&s_state_mux);
    int count = trust_count_unlocked();
    portEXIT_CRITICAL(&s_state_mux);
    return count;
}

static esp_err_t persist_values(const trust_store_t *store, const char *alias)
{
    esp_err_t err = nvs_set_blob(s_nvs, "peers", store, sizeof(*store));
    if (err == ESP_OK) err = nvs_set_str(s_nvs, "alias", alias);
    if (err == ESP_OK) err = nvs_commit(s_nvs);
    return err;
}

static void persist_store(void)
{
    if (!s_nvs_open) return;
    if (s_persist_mutex && xSemaphoreTake(s_persist_mutex, portMAX_DELAY) != pdTRUE) return;
    trust_store_t store;
    char alias[sizeof(s_alias)];
    portENTER_CRITICAL(&s_state_mux);
    store = s_store;
    memcpy(alias, s_alias, sizeof(alias));
    portEXIT_CRITICAL(&s_state_mux);
    esp_err_t err = persist_values(&store, alias);
    if (err != ESP_OK) ESP_LOGE(TAG, "保存信任数据失败: %s", esp_err_to_name(err));
    if (s_persist_mutex) xSemaphoreGive(s_persist_mutex);
}

static bool addr_equal(const trust_record_t *record, const ble_addr_t *addr)
{
    return record->used != TRUST_RECORD_FREE && record->addr_type == addr->type &&
           memcmp(record->addr, addr->val, sizeof(record->addr)) == 0;
}

static bool ble_addr_equal(const ble_addr_t *a, const ble_addr_t *b)
{
    return a->type == b->type && memcmp(a->val, b->val, sizeof(a->val)) == 0;
}

static bool pin_key_missing_status(int status)
{
    return status == BLE_ERR_PINKEY_MISSING ||
           status == BLE_HS_HCI_ERR(BLE_ERR_PINKEY_MISSING) ||
           status == BLE_HS_ENOENT;
}

// Must be called with s_state_mux held.
static void clear_reclaim_unlocked(void)
{
    s_reclaim_pending = false;
    s_reclaim_slot = -1;
    memset(&s_reclaim_addr, 0, sizeof(s_reclaim_addr));
}

// Must be called with s_state_mux held.  A legacy app reconnects every two
// seconds, so merely shortening the HELLO timeout still lets it repeatedly win
// the device's single BLE slot.  Remember both the identity and over-the-air
// addresses: bonded peers are stable by identity, while an unbonded macOS
// central is only recognizable by its current private OTA address.
static void quarantine_current_peer_unlocked(int64_t now)
{
    if (!s_link_peer_valid) return;
    s_quarantined_peer_id_addr = s_link_peer_id_addr;
    s_quarantined_peer_ota_addr = s_link_peer_ota_addr;
    s_quarantine_deadline = now + LEGACY_PEER_COOLDOWN_US;
    s_quarantine_next_probation = now + LEGACY_PROBATION_INTERVAL_US;
    s_quarantine_active = true;
}

// Must be called with s_state_mux held.
static bool peer_is_quarantined_unlocked(const struct ble_gap_conn_desc *desc,
                                         int64_t now)
{
    if (!s_quarantine_active) return false;
    if (now >= s_quarantine_deadline) {
        s_quarantine_active = false;
        s_quarantine_deadline = 0;
        s_quarantine_next_probation = 0;
        return false;
    }
    return ble_addr_equal(&desc->peer_id_addr, &s_quarantined_peer_id_addr) ||
           ble_addr_equal(&desc->peer_ota_addr, &s_quarantined_peer_ota_addr);
}

static int find_by_addr_unlocked(const ble_addr_t *addr)
{
    for (int i = 0; i < DEVICE_TRUST_MAX_COMPANIONS; i++) {
        if (addr_equal(&s_store.records[i], addr)) return i;
    }
    return -1;
}

static int find_by_id_unlocked(const char *id)
{
    for (int i = 0; i < DEVICE_TRUST_MAX_COMPANIONS; i++) {
        if (s_store.records[i].used == TRUST_RECORD_ACTIVE &&
            strcmp(s_store.records[i].id, id) == 0) return i;
    }
    return -1;
}

static uint8_t used_mask_unlocked(void)
{
    uint8_t mask = 0;
    for (int i = 0; i < DEVICE_TRUST_MAX_COMPANIONS; i++) {
        if (s_store.records[i].used == TRUST_RECORD_ACTIVE) mask |= (uint8_t)(1u << i);
    }
    return mask;
}

static int first_free_unlocked(void)
{
    for (int i = 0; i < DEVICE_TRUST_MAX_COMPANIONS; i++) {
        if (s_store.records[i].used == TRUST_RECORD_FREE) return i;
    }
    // Revoked tombstones keep the old bond available for seamless re-enrolment,
    // but are the only entries that may be reclaimed for a genuinely new peer.
    for (int i = 0; i < DEVICE_TRUST_MAX_COMPANIONS; i++) {
        if (s_store.records[i].used == TRUST_RECORD_REVOKED) return i;
    }
    return -1;
}

static int ordinal_by_id(const char *id)
{
    portENTER_CRITICAL(&s_state_mux);
    int slot = find_by_id_unlocked(id);
    int ordinal = device_trust_ordinal_from_slot(used_mask_unlocked(), slot);
    portEXIT_CRITICAL(&s_state_mux);
    return ordinal;
}

static void copy_utf8_field(char *dst, size_t dst_size,
                            const uint8_t *src, size_t src_len)
{
    if (src_len >= dst_size) src_len = dst_size - 1;
    memcpy(dst, src, src_len);
    dst[src_len] = '\0';
    // Line-oriented state never reflects raw control bytes.
    for (size_t i = 0; i < src_len; i++) {
        if ((unsigned char)dst[i] < 0x20 || dst[i] == 0x7f) dst[i] = ' ';
    }
}

static void pct_encode(const char *src, char *dst, size_t dst_size)
{
    static const char hex[] = "0123456789ABCDEF";
    size_t out = 0;
    for (size_t i = 0; src && src[i] && out + 1 < dst_size; i++) {
        unsigned char c = (unsigned char)src[i];
        bool safe = isalnum(c) || c == '-' || c == '_' || c == '.' || c == '~';
        if (safe) {
            dst[out++] = (char)c;
        } else if (out + 3 < dst_size) {
            dst[out++] = '%';
            dst[out++] = hex[c >> 4];
            dst[out++] = hex[c & 0xf];
        } else {
            break;
        }
    }
    dst[out] = '\0';
}

static int build_state(char *buf, size_t size,
                       uint16_t *out_conn_handle, uint32_t *out_tx_generation)
{
    bool authorized;
    device_trust_state_t state;
    int64_t pairing_deadline;
    int64_t handoff_deadline;
    int handoff_target;
    int retry_after;
    int trusted_count;
    uint8_t platform;
    char raw_alias[sizeof(s_alias)];
    char raw_id[sizeof(s_companion_id)];
    char raw_name[sizeof(s_companion_name)];
    char raw_app[sizeof(s_app_version)];
    char raw_handoff[DEVICE_TRUST_ID_MAX + 1] = "";
    char raw_reason[sizeof(s_reason)];

    portENTER_CRITICAL(&s_state_mux);
    authorized = s_authorized;
    state = s_state;
    pairing_deadline = s_pairing_deadline;
    handoff_deadline = s_handoff_deadline;
    handoff_target = s_handoff_target;
    retry_after = s_retry_after;
    memcpy(raw_reason, s_reason, sizeof(raw_reason));
    trusted_count = trust_count_unlocked();
    memcpy(raw_alias, s_alias, sizeof(raw_alias));
    memcpy(raw_id, s_companion_id, sizeof(raw_id));
    memcpy(raw_name, s_companion_name, sizeof(raw_name));
    memcpy(raw_app, s_app_version, sizeof(raw_app));
    platform = s_platform;
    if (handoff_target >= 0 && handoff_target < DEVICE_TRUST_MAX_COMPANIONS &&
        s_store.records[handoff_target].used == TRUST_RECORD_ACTIVE) {
        memcpy(raw_handoff, s_store.records[handoff_target].id, sizeof(raw_handoff));
    }
    if (out_conn_handle) *out_conn_handle = s_conn_handle;
    if (out_tx_generation) {
        // Lock order is always state -> tx when both are needed.
        portENTER_CRITICAL(&s_tx_mux);
        *out_tx_generation = s_tx_generation;
        portEXIT_CRITICAL(&s_tx_mux);
    }
    portEXIT_CRITICAL(&s_state_mux);

    int64_t now = esp_timer_get_time();
    int64_t pairing_us = pairing_deadline - now;
    int pairing_remaining = pairing_us > 0 ? (int)((pairing_us + 999999) / 1000000) : 0;
    if (!authorized) {
        // Before bond authentication, do not disclose the user-assigned alias,
        // previous/current companion metadata or handoff target. The peer only
        // needs enough information to drive the physical pairing flow.
        return snprintf(buf, size,
                        "v=1\nstate=%s\nid=%s\npairing.remaining=%d\n"
                        "handoff.remaining=%d\nretry_after=%d\nreason=%s\n",
                        state_name(state), s_device_id, pairing_remaining,
                        handoff_deadline > now
                            ? (int)((handoff_deadline - now + 999999) / 1000000) : 0,
                        retry_after, raw_reason);
    }
    char alias[DEVICE_TRUST_ALIAS_MAX * 3 + 1];
    char id[DEVICE_TRUST_ID_MAX * 3 + 1];
    char name[DEVICE_TRUST_NAME_MAX * 3 + 1];
    char handoff[DEVICE_TRUST_ID_MAX * 3 + 1] = "";
    pct_encode(raw_alias, alias, sizeof(alias));
    pct_encode(raw_id, id, sizeof(id));
    pct_encode(raw_name, name, sizeof(name));
    pct_encode(raw_handoff, handoff, sizeof(handoff));
    int64_t handoff_us = handoff_deadline - now;
    int handoff_seconds = handoff_us > 0 ? (int)((handoff_us + 999999) / 1000000) : 0;
    return snprintf(buf, size,
                    "v=1\nstate=%s\nid=%s\nalias=%s\ncurrent.id=%s\n"
                    "current.platform=%u\ncurrent.name=%s\ncurrent.app=%s\n"
                    "pairing.remaining=%d\ntrusted.count=%d\nhandoff.target=%s\n"
                    "handoff.remaining=%d\nretry_after=%d\nreason=%s\n",
                    state_name(state), s_device_id, alias, id, platform, name,
                    raw_app, pairing_remaining, trusted_count,
                    handoff, handoff_seconds,
                    retry_after,
                    raw_reason);
}

static void auth_tx_clear(void)
{
    portENTER_CRITICAL(&s_tx_mux);
    s_tx_head = s_tx_tail = s_tx_count = 0;
    s_tx_sending = false;
    s_tx_started_at = 0;
    s_tx_inflight_len = 0;
    s_tx_inflight_conn_handle = BLE_HS_CONN_HANDLE_NONE;
    s_tx_inflight_conn_generation = 0;
    s_tx_inflight_tx_generation = 0;
    s_tx_generation++;
    portEXIT_CRITICAL(&s_tx_mux);
}

// Replace stale queued snapshots without invalidating an indication that
// NimBLE already owns. The current logical item must finish first so the
// companion never receives the beginning of one line-oriented snapshot joined
// to the beginning of another. The fresh snapshot is appended immediately
// after this retained head item by the caller.
static void auth_tx_prepare_refresh(void)
{
    portENTER_CRITICAL(&s_tx_mux);
    if (s_tx_sending && s_tx_count > 0) {
        s_tx_count = 1;
        s_tx_tail = (uint8_t)((s_tx_head + 1) % AUTH_TX_DEPTH);
    } else {
        s_tx_head = s_tx_tail = s_tx_count = 0;
        s_tx_sending = false;
        s_tx_started_at = 0;
        s_tx_inflight_len = 0;
        s_tx_inflight_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        s_tx_inflight_conn_generation = 0;
        s_tx_inflight_tx_generation = 0;
        s_tx_generation++;
    }
    portEXIT_CRITICAL(&s_tx_mux);
}

static void auth_tx_set_subscribed(bool subscribed)
{
    portENTER_CRITICAL(&s_tx_mux);
    s_state_subscribed = subscribed;
    s_tx_head = s_tx_tail = s_tx_count = 0;
    s_tx_sending = false;
    s_tx_started_at = 0;
    s_tx_inflight_len = 0;
    s_tx_inflight_conn_handle = BLE_HS_CONN_HANDLE_NONE;
    s_tx_inflight_conn_generation = 0;
    s_tx_inflight_tx_generation = 0;
    s_tx_generation++;
    portEXIT_CRITICAL(&s_tx_mux);
}

static bool auth_tx_enqueue(const void *data, int len,
                            uint16_t expected_conn_handle,
                            uint32_t expected_generation)
{
    if (len <= 0 || len > STATE_BUF_LEN) return false;
    portENTER_CRITICAL(&s_state_mux);
    bool same_connection = s_conn_handle == expected_conn_handle;
    portEXIT_CRITICAL(&s_state_mux);
    if (!same_connection) return false;
    bool queued = false;
    portENTER_CRITICAL(&s_tx_mux);
    if (s_state_subscribed && s_tx_generation == expected_generation &&
        s_tx_count < AUTH_TX_DEPTH) {
        auth_tx_item_t *item = &s_tx_queue[s_tx_tail];
        item->len = (uint16_t)len;
        item->offset = 0;
        memcpy(item->data, data, (size_t)len);
        s_tx_tail = (uint8_t)((s_tx_tail + 1) % AUTH_TX_DEPTH);
        s_tx_count++;
        queued = true;
    }
    portEXIT_CRITICAL(&s_tx_mux);
    if (!queued) ESP_LOGW(TAG, "认证状态发送队列已满,等待对端0x07重取");
    return queued;
}

static void auth_tx_kick(void)
{
    uint8_t bytes[AUTH_TX_CHUNK];
    uint16_t chunk;
    uint16_t conn_handle;
    uint32_t conn_generation;
    uint32_t generation;
    portENTER_CRITICAL(&s_state_mux);
    conn_handle = s_conn_handle;
    conn_generation = s_connection_generation;
    portEXIT_CRITICAL(&s_state_mux);
    uint16_t mtu = conn_handle != BLE_HS_CONN_HANDLE_NONE ? ble_att_mtu(conn_handle) : 23;
    portENTER_CRITICAL(&s_tx_mux);
    if (s_tx_sending || s_tx_count == 0 || !s_state_subscribed ||
        conn_handle == BLE_HS_CONN_HANDLE_NONE) {
        portEXIT_CRITICAL(&s_tx_mux);
        return;
    }
    auth_tx_item_t *item = &s_tx_queue[s_tx_head];
    generation = s_tx_generation;
    uint16_t limit = mtu > 3 ? (uint16_t)(mtu - 3) : 20;
    if (limit > AUTH_TX_CHUNK) limit = AUTH_TX_CHUNK;
    chunk = item->len - item->offset;
    if (chunk > limit) chunk = limit;
    memcpy(bytes, item->data + item->offset, chunk);
    s_tx_sending = true;
    s_tx_started_at = esp_timer_get_time();
    s_tx_inflight_len = chunk;
    s_tx_inflight_conn_handle = conn_handle;
    s_tx_inflight_conn_generation = conn_generation;
    s_tx_inflight_tx_generation = generation;
    portEXIT_CRITICAL(&s_tx_mux);

    struct os_mbuf *om = ble_hs_mbuf_from_flat(bytes, chunk);
    if (!om) {
        portENTER_CRITICAL(&s_tx_mux);
        if (s_tx_sending && s_tx_generation == generation &&
            s_tx_inflight_conn_handle == conn_handle &&
            s_tx_inflight_conn_generation == conn_generation &&
            s_tx_inflight_tx_generation == generation) {
            s_tx_sending = false;
            s_tx_started_at = 0;
            s_tx_inflight_len = 0;
            s_tx_inflight_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        }
        portEXIT_CRITICAL(&s_tx_mux);
        return;
    }

    // Allocation can yield long enough for a disconnect and a new connection
    // to reuse the same numeric handle. Revalidate both generations immediately
    // before handing the private state bytes to NimBLE.
    portENTER_CRITICAL(&s_state_mux);
    portENTER_CRITICAL(&s_tx_mux);
    bool still_current = s_conn_handle == conn_handle &&
                         s_connection_generation == conn_generation &&
                         s_state_subscribed && s_tx_sending &&
                         s_tx_generation == generation &&
                         s_tx_inflight_conn_handle == conn_handle &&
                         s_tx_inflight_conn_generation == conn_generation &&
                         s_tx_inflight_tx_generation == generation;
    portEXIT_CRITICAL(&s_tx_mux);
    portEXIT_CRITICAL(&s_state_mux);
    if (!still_current) {
        os_mbuf_free_chain(om);
        // The queue itself may already belong to the replacement connection
        // (the numeric handle can be reused). Release only the in-flight claim
        // made by this exact kick, leaving the uncommitted head for the next
        // tick to send with the new connection generation.
        portENTER_CRITICAL(&s_tx_mux);
        if (s_tx_sending && s_tx_generation == generation &&
            s_tx_inflight_conn_handle == conn_handle &&
            s_tx_inflight_conn_generation == conn_generation &&
            s_tx_inflight_tx_generation == generation) {
            s_tx_sending = false;
            s_tx_started_at = 0;
            s_tx_inflight_len = 0;
            s_tx_inflight_conn_handle = BLE_HS_CONN_HANDLE_NONE;
            s_tx_inflight_conn_generation = 0;
            s_tx_inflight_tx_generation = 0;
        }
        portEXIT_CRITICAL(&s_tx_mux);
        return;
    }

    int rc = ble_gatts_indicate_custom(conn_handle, s_state_handle, om);
    portENTER_CRITICAL(&s_tx_mux);
    if (generation != s_tx_generation) {
        // A disconnect, resubscribe or explicit 0x07 refresh replaced the
        // queue while this send was outside the critical section.
        portEXIT_CRITICAL(&s_tx_mux);
        return;
    } else if (rc != 0) {
        s_tx_sending = false; // keep the head item for the next tick
        s_tx_started_at = 0;
        s_tx_inflight_len = 0;
        s_tx_inflight_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        s_tx_inflight_conn_generation = 0;
        s_tx_inflight_tx_generation = 0;
    }
    portEXIT_CRITICAL(&s_tx_mux);
    if (rc != 0) {
        if (rc != BLE_HS_ENOTCONN && rc != BLE_HS_ENOMEM) {
            ESP_LOGW(TAG, "发送认证状态失败: rc=%d", rc);
        }
    }
}

static void notify_text(const char *text, int len,
                        uint16_t expected_conn_handle,
                        uint32_t expected_generation)
{
    // auth_tx_kick() fragments this logical text block to the negotiated ATT
    // MTU. The companion accumulates until '\n', so frame boundaries are not
    // semantic boundaries.
    auth_tx_enqueue(text, len, expected_conn_handle, expected_generation);
    auth_tx_kick();
}

static void queue_state_snapshot(void)
{
    char *buf = malloc(STATE_BUF_LEN);
    if (!buf) {
        ESP_LOGE(TAG, "认证状态缓冲分配失败");
        return;
    }
    uint16_t conn_handle;
    uint32_t generation;
    int len = build_state(buf, STATE_BUF_LEN, &conn_handle, &generation);
    if (len > 0) notify_text(buf, len < STATE_BUF_LEN ? len : STATE_BUF_LEN - 1,
                             conn_handle, generation);
    free(buf);
}

static void notify_state(const char *reason)
{
    portENTER_CRITICAL(&s_state_mux);
    snprintf(s_reason, sizeof(s_reason), "%s", reason ? reason : "");
    portEXIT_CRITICAL(&s_state_mux);
    queue_state_snapshot();
}

static void notify_trusted_list(void)
{
    trust_store_t store;
    uint16_t conn_handle;
    uint32_t generation;
    portENTER_CRITICAL(&s_state_mux);
    if (!s_authorized) {
        portEXIT_CRITICAL(&s_state_mux);
        return;
    }
    store = s_store;
    conn_handle = s_conn_handle;
    portENTER_CRITICAL(&s_tx_mux);
    generation = s_tx_generation;
    portEXIT_CRITICAL(&s_tx_mux);
    portEXIT_CRITICAL(&s_state_mux);
    char id[DEVICE_TRUST_ID_MAX * 3 + 1];
    char name[DEVICE_TRUST_NAME_MAX * 3 + 1];
    char line[400];
    for (int i = 0; i < DEVICE_TRUST_MAX_COMPANIONS; i++) {
        trust_record_t record = store.records[i];
        if (record.used != TRUST_RECORD_ACTIVE) continue;
        pct_encode(record.id, id, sizeof(id));
        pct_encode(record.name, name, sizeof(name));
        int len = snprintf(line, sizeof(line), "trusted=%s\t%u\t%s\n",
                           id, record.platform, name);
        if (len > 0) notify_text(line, len, conn_handle, generation);
    }
}

// Runs only from the housekeeping task. GATT callbacks merely replace this
// single-slot request, so they never block the NimBLE host task on flash I/O.
static void process_pending_name_update(void)
{
    uint16_t conn_handle;
    uint32_t connection_generation;
    int slot;
    char expected_id[DEVICE_TRUST_ID_MAX + 1];
    char name[DEVICE_TRUST_NAME_MAX + 1];

    portENTER_CRITICAL(&s_state_mux);
    if (!s_name_update_pending) {
        portEXIT_CRITICAL(&s_state_mux);
        return;
    }
    conn_handle = s_name_update_conn_handle;
    connection_generation = s_name_update_connection_generation;
    slot = s_name_update_slot;
    memcpy(expected_id, s_name_update_id, sizeof(expected_id));
    memcpy(name, s_name_update_value, sizeof(name));
    s_name_update_pending = false;
    portEXIT_CRITICAL(&s_state_mux);

    if (!s_nvs_open || !s_persist_mutex ||
        xSemaphoreTake(s_persist_mutex, portMAX_DELAY) != pdTRUE) {
        notify_state("companion_name_save_failed");
        return;
    }

    trust_store_t store;
    char alias[sizeof(s_alias)];
    bool current = false;
    portENTER_CRITICAL(&s_state_mux);
    if (s_authorized && s_admission_granted && !s_disconnect_pending &&
        s_conn_handle == conn_handle &&
        s_connection_generation == connection_generation &&
        slot >= 0 && slot < DEVICE_TRUST_MAX_COMPANIONS &&
        s_store.records[slot].used == TRUST_RECORD_ACTIVE &&
        strcmp(s_store.records[slot].id, expected_id) == 0) {
        store = s_store;
        memcpy(alias, s_alias, sizeof(alias));
        memset(store.records[slot].name, 0, sizeof(store.records[slot].name));
        memcpy(store.records[slot].name, name, strlen(name));
        current = true;
    }
    portEXIT_CRITICAL(&s_state_mux);

    esp_err_t err = current ? persist_values(&store, alias) : ESP_ERR_INVALID_STATE;
    bool committed = false;
    if (err == ESP_OK) {
        portENTER_CRITICAL(&s_state_mux);
        if (slot >= 0 && slot < DEVICE_TRUST_MAX_COMPANIONS &&
            s_store.records[slot].used == TRUST_RECORD_ACTIVE &&
            strcmp(s_store.records[slot].id, expected_id) == 0) {
            memset(s_store.records[slot].name, 0,
                   sizeof(s_store.records[slot].name));
            memcpy(s_store.records[slot].name, name, strlen(name));
            if (s_conn_handle == conn_handle &&
                s_connection_generation == connection_generation) {
                memset(s_companion_name, 0, sizeof(s_companion_name));
                memcpy(s_companion_name, name, strlen(name));
            }
            s_revision++;
            committed = true;
        }
        portEXIT_CRITICAL(&s_state_mux);
    }
    xSemaphoreGive(s_persist_mutex);

    if (committed) {
        notify_state("companion_name_changed");
        notify_trusted_list();
    } else if (current) {
        ESP_LOGE(TAG, "保存伴侣名称失败: %s", esp_err_to_name(err));
        notify_state("companion_name_save_failed");
    }
}

static void set_state(device_trust_state_t state, const char *reason)
{
    portENTER_CRITICAL(&s_state_mux);
    if (state == DEVICE_TRUST_DENIED) {
        // A rejected or degraded connection must lose access before its final
        // status is queued. The delayed disconnect exists only to deliver that
        // status; it is not an authorization grace period.
        s_authorized = false;
        s_admission_granted = false;
    }
    s_state = state;
    s_revision++;
    snprintf(s_reason, sizeof(s_reason), "%s", reason ? reason : "");
    portEXIT_CRITICAL(&s_state_mux);
    queue_state_snapshot();
}

static bool auth_tx_idle(void)
{
    bool idle;
    portENTER_CRITICAL(&s_tx_mux);
    idle = !s_tx_sending && s_tx_count == 0;
    portEXIT_CRITICAL(&s_tx_mux);
    return idle;
}

static void disconnect_after_state_for(uint16_t expected_conn_handle,
                                       int delay_ms, int retry_after)
{
    int64_t now = esp_timer_get_time();
    portENTER_CRITICAL(&s_state_mux);
    if (expected_conn_handle == BLE_HS_CONN_HANDLE_NONE ||
        s_conn_handle != expected_conn_handle) {
        portEXIT_CRITICAL(&s_state_mux);
        return;
    }
    s_retry_after = retry_after;
    s_disconnect_pending = true;
    s_disconnect_conn_handle = expected_conn_handle;
    s_disconnect_not_before = now + (int64_t)delay_ms * 1000;
    // A broken subscription must not hold the only connection forever.
    s_disconnect_force_at = now + 3000000;
    portEXIT_CRITICAL(&s_state_mux);
}

static void revoke_business_authorization(void)
{
    portENTER_CRITICAL(&s_state_mux);
    s_authorized = false;
    s_admission_granted = false;
    if (s_state == DEVICE_TRUST_AUTHORIZED) s_state = DEVICE_TRUST_CONNECTED;
    s_revision++;
    portEXIT_CRITICAL(&s_state_mux);
}

static void deny_connection(uint16_t conn_handle, const char *reason, int retry_after)
{
    int64_t now = esp_timer_get_time();
    portENTER_CRITICAL(&s_state_mux);
    if (conn_handle != s_conn_handle) {
        portEXIT_CRITICAL(&s_state_mux);
        return;
    }
    s_authorized = false;
    s_admission_granted = false;
    s_confirmation_pending = false;
    s_confirmation_mode = CONFIRM_NONE;
    s_numeric_confirmed = false;
    clear_reclaim_unlocked();
    s_state = DEVICE_TRUST_DENIED;
    s_retry_after = retry_after;
    snprintf(s_reason, sizeof(s_reason), "%s", reason ? reason : "denied");
    s_revision++;
    s_disconnect_pending = true;
    s_disconnect_conn_handle = conn_handle;
    s_disconnect_not_before = now + 100000;
    s_disconnect_force_at = now + 3000000;
    portEXIT_CRITICAL(&s_state_mux);
    queue_state_snapshot();
}

static void remember_current_peer(void)
{
    char log_name[DEVICE_TRUST_NAME_MAX + 1];
    char log_id[DEVICE_TRUST_ID_MAX + 1];
    portENTER_CRITICAL(&s_state_mux);
    uint16_t conn_handle = s_conn_handle;
    int index = find_by_addr_unlocked(&s_peer_id_addr);
    if (index < 0) index = first_free_unlocked();
    if (index < 0) {
        portEXIT_CRITICAL(&s_state_mux);
        ESP_LOGE(TAG, "可信伴侣已满(%d),拒绝新增", DEVICE_TRUST_MAX_COMPANIONS);
        deny_connection(conn_handle, "trust_store_full", 0);
        return;
    }
    trust_record_t *r = &s_store.records[index];
    memset(r, 0, sizeof(*r));
    r->used = TRUST_RECORD_ACTIVE;
    r->addr_type = s_peer_id_addr.type;
    memcpy(r->addr, s_peer_id_addr.val, sizeof(r->addr));
    r->platform = s_platform;
    memcpy(r->id, s_companion_id, sizeof(r->id));
    memcpy(r->name, s_companion_name, sizeof(r->name));
    memcpy(r->app_version, s_app_version, sizeof(r->app_version));
    memcpy(log_name, r->name, sizeof(log_name));
    memcpy(log_id, r->id, sizeof(log_id));
    portEXIT_CRITICAL(&s_state_mux);
    persist_store();
    ESP_LOGI(TAG, "已信任伴侣 %s (%s)", log_name, log_id);
}

static void authorize_current_peer(uint16_t conn_handle)
{
    portENTER_CRITICAL(&s_state_mux);
    if (!s_admission_granted || s_disconnect_pending || !s_hello_received ||
        s_conn_handle != conn_handle) {
        portEXIT_CRITICAL(&s_state_mux);
        return;
    }
    bool should_remember = find_by_addr_unlocked(&s_peer_id_addr) < 0 || s_pairing_new;
    portEXIT_CRITICAL(&s_state_mux);
    if (should_remember) remember_current_peer();
    bool metadata_changed = false;
    portENTER_CRITICAL(&s_state_mux);
    if (!s_admission_granted || s_disconnect_pending ||
        s_conn_handle != conn_handle) {
        portEXIT_CRITICAL(&s_state_mux);
        return;
    }
    int trusted = find_by_addr_unlocked(&s_peer_id_addr);
    if (trusted < 0) {
        portEXIT_CRITICAL(&s_state_mux);
        return;
    }
    trust_record_t *r = &s_store.records[trusted];
    if (r->platform != s_platform || strcmp(r->name, s_companion_name) != 0 ||
        strcmp(r->app_version, s_app_version) != 0) {
        r->platform = s_platform;
        memcpy(r->name, s_companion_name, sizeof(r->name));
        memcpy(r->app_version, s_app_version, sizeof(r->app_version));
        metadata_changed = true;
    }
    s_authorized = true;
    s_auth_deadline = 0;
    if (!s_enrollment_active) s_pairing_deadline = 0;
    s_confirmation_pending = false;
    s_confirmation_mode = CONFIRM_NONE;
    s_numeric_confirmed = false;
    clear_reclaim_unlocked();
    s_handoff_target = -1;
    s_handoff_deadline = 0;
    s_retry_after = 0;
    s_state = DEVICE_TRUST_AUTHORIZED;
    s_reason[0] = '\0';
    s_revision++;
    portEXIT_CRITICAL(&s_state_mux);
    if (metadata_changed) persist_store();
    queue_state_snapshot();
    notify_trusted_list();
}

static int hello_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                           struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr_handle; (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_UNLIKELY;
    portENTER_CRITICAL(&s_state_mux);
    bool current_connection = conn_handle == s_conn_handle;
    bool hello_allowed = current_connection && !s_disconnect_pending && !s_hello_received;
    portEXIT_CRITICAL(&s_state_mux);
    if (!hello_allowed) return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;

    uint8_t hello[5 + DEVICE_TRUST_ID_MAX + DEVICE_TRUST_NAME_MAX + 24];
    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len < 6 || len > sizeof(hello) ||
        ble_hs_mbuf_to_flat(ctxt->om, hello, len, NULL) != 0) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    size_t id_len = hello[1], name_len = hello[3], app_len = hello[4];
    if (hello[0] != 1 || id_len == 0 || id_len > DEVICE_TRUST_ID_MAX ||
        name_len > DEVICE_TRUST_NAME_MAX || app_len > 24 ||
        5 + id_len + name_len + app_len != len) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    const uint8_t *name_bytes = hello + 5 + id_len;
    if (!device_trust_companion_name_valid(name_bytes, name_len)) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }

    char hello_id[DEVICE_TRUST_ID_MAX + 1] = { 0 };
    char hello_name[DEVICE_TRUST_NAME_MAX + 1] = { 0 };
    char hello_app[25] = { 0 };
    const uint8_t *p = hello + 5;
    copy_utf8_field(hello_id, sizeof(hello_id), p, id_len); p += id_len;
    copy_utf8_field(hello_name, sizeof(hello_name), p, name_len); p += name_len;
    copy_utf8_field(hello_app, sizeof(hello_app), p, app_len);

    struct ble_gap_conn_desc desc;
    if (ble_gap_conn_find(conn_handle, &desc) != 0) return BLE_ATT_ERR_UNLIKELY;
    int64_t now = esp_timer_get_time();
    portENTER_CRITICAL(&s_state_mux);
    int peer_slot = find_by_addr_unlocked(&desc.peer_id_addr);
    bool peer_revoked = peer_slot >= 0 &&
                        s_store.records[peer_slot].used == TRUST_RECORD_REVOKED;
    int trusted = peer_slot >= 0 &&
                  s_store.records[peer_slot].used == TRUST_RECORD_ACTIVE
                      ? peer_slot : -1;
    bool handoff_match = s_handoff_target < 0 ||
        addr_equal(&s_store.records[s_handoff_target], &desc.peer_id_addr);
    bool may_pair = s_pairing_deadline > now;
    int replacement_slot = first_free_unlocked();
    bool replacement_revoked = replacement_slot >= 0 &&
        s_store.records[replacement_slot].used == TRUST_RECORD_REVOKED;
    bool store_full = replacement_slot < 0;
    int same_id_slot = find_by_id_unlocked(hello_id);
    bool duplicate_id = same_id_slot >= 0 && same_id_slot != trusted;
    bool identity_changed = trusted >= 0 &&
        strcmp(s_store.records[trusted].id, hello_id) != 0;
    bool pairing_new = trusted < 0 || identity_changed;
    bool enrollment_active = s_enrollment_active && may_pair;
    device_trust_slot_admission_t slot_admission = device_trust_slot_admission(
        trusted, s_manually_disconnected_slot, s_handoff_target);
    int enrollment_remaining = may_pair
        ? (int)((s_pairing_deadline - now + 999999) / 1000000) : 0;
    s_pairing_new = pairing_new;
    portEXIT_CRITICAL(&s_state_mux);

    if (!appstore_transfer_peer_can_resume(desc.peer_id_addr.type,
                                           desc.peer_id_addr.val)) {
        // OTA progress is resumable, but only by the bonded owner that started
        // the write. A second trusted companion must not take over the same
        // sequential esp_ota handle.
        deny_connection(conn_handle, "ota_owned_by_another_companion", 10);
        return 0;
    }

    if (slot_admission == DEVICE_TRUST_SLOT_MANUALLY_DISCONNECTED) {
        deny_connection(conn_handle, "manual_disconnect", 5);
        return 0;
    }

    if (enrollment_active && trusted >= 0 && !identity_changed) {
        // Enrollment reserves the only slot for a genuinely new companion.
        // Every already trusted owner backs off for the remaining window.
        deny_connection(conn_handle, "enrollment_reserved", enrollment_remaining);
        return 0;
    }

    // A directed handoff is exclusive: even an already trusted old owner must
    // not reclaim the single BLE slot during the 60-second target window.
    bool selected_target_mismatch = !handoff_match ||
        slot_admission == DEVICE_TRUST_SLOT_NOT_SELECTED;
    if (selected_target_mismatch || (trusted < 0 && !may_pair)) {
        ESP_LOGW(TAG, "拒绝陌生伴侣 %s: 未开启配对窗口", hello_name);
        deny_connection(conn_handle,
                        selected_target_mismatch
                            ? "handoff_target_mismatch" : "pairing_window_closed",
                        selected_target_mismatch ? enrollment_remaining : 0);
        return 0;
    }
    if (trusted < 0 && store_full) {
        // Reject before SMP starts. Letting NimBLE's round-robin bond store
        // accept a ninth peer would evict an old bond while our metadata still
        // claimed that peer was trusted.
        deny_connection(conn_handle, "trust_store_full", 0);
        return 0;
    }
    if (duplicate_id) {
        // Companion IDs are display/command metadata rather than the security
        // principal, but allowing two bonds to share one would make forget and
        // handoff ambiguous. The user can forget the stale entry first.
        deny_connection(conn_handle, "companion_id_conflict", 0);
        return 0;
    }
    if (identity_changed) {
        // The BLE identity is the authority. A changed installation id is metadata,
        // but require a new physical confirmation rather than silently accepting it.
        if (!may_pair) {
            deny_connection(conn_handle, "companion_identity_changed", 0);
            return 0;
        }
    }

    // Reserve (but do not delete) a revoked tombstone for a genuinely new peer.
    // The bond is reclaimed only after the person accepts the numeric comparison;
    // a rejected or abandoned HELLO must not consume old recovery records.
    if (trusted < 0 && !peer_revoked && replacement_revoked) {
        portENTER_CRITICAL(&s_state_mux);
        if (replacement_slot >= 0 && replacement_slot < DEVICE_TRUST_MAX_COMPANIONS &&
            s_store.records[replacement_slot].used == TRUST_RECORD_REVOKED) {
            s_reclaim_slot = replacement_slot;
            s_reclaim_addr.type = s_store.records[replacement_slot].addr_type;
            memcpy(s_reclaim_addr.val, s_store.records[replacement_slot].addr,
                   sizeof(s_reclaim_addr.val));
            s_reclaim_pending = true;
        }
        portEXIT_CRITICAL(&s_state_mux);
    }

    // Only now, after every admission policy has passed, may SMP callbacks
    // authorize this connection. This closes the delay-before-disconnect race
    // on every rejection path.
    portENTER_CRITICAL(&s_state_mux);
    bool still_current = conn_handle == s_conn_handle && !s_disconnect_pending &&
                         !s_hello_received;
    if (still_current) {
        memcpy(s_companion_id, hello_id, sizeof(s_companion_id));
        memcpy(s_companion_name, hello_name, sizeof(s_companion_name));
        memcpy(s_app_version, hello_app, sizeof(s_app_version));
        s_platform = hello[2];
        s_peer_id_addr = desc.peer_id_addr;
        s_pairing_new = pairing_new;
        s_hello_received = true;
        s_admission_granted = true;
        s_legacy_activity_seen = false;
        if (peer_is_quarantined_unlocked(&desc, now)) {
            // A current companion build proved itself within the probation
            // window.  Do not keep punishing the OS identity for an older app
            // binary that may previously have used it.
            s_quarantine_active = false;
            s_quarantine_deadline = 0;
            s_quarantine_next_probation = 0;
        }
        // The short deadline protects the slot before HELLO. After admission,
        // give the person a full minute to compare and press the hardware key.
        s_auth_deadline = now + PAIRING_WINDOW_US;
    }
    portEXIT_CRITICAL(&s_state_mux);
    if (!still_current) return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;

    // A bonded central can restore encryption before it discovers and writes
    // HELLO. In that ordering ENC_CHANGE has already happened, so authorize
    // here instead of waiting for an event that will not repeat.
    if (trusted >= 0 && !pairing_new && desc.sec_state.encrypted &&
        desc.sec_state.authenticated && desc.sec_state.bonded) {
        portENTER_CRITICAL(&s_state_mux);
        bool still_current = conn_handle == s_conn_handle && !s_disconnect_pending;
        if (still_current) s_admission_granted = true;
        portEXIT_CRITICAL(&s_state_mux);
        if (!still_current) return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
        authorize_current_peer(conn_handle);
        return 0;
    }
    if ((peer_revoked || identity_changed) && desc.sec_state.encrypted &&
        desc.sec_state.authenticated && desc.sec_state.bonded) {
        portENTER_CRITICAL(&s_state_mux);
        bool still_current = conn_handle == s_conn_handle &&
                             s_admission_granted && !s_disconnect_pending;
        if (still_current) {
            s_confirmation_pending = true;
            s_confirmation_mode = CONFIRM_RETRUST;
            s_numeric_code = 0;
            s_auth_deadline = now + PAIRING_WINDOW_US;
        }
        portEXIT_CRITICAL(&s_state_mux);
        if (!still_current) return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
        set_state(DEVICE_TRUST_AWAITING_CONFIRMATION, "retrust_confirmation");
        return 0;
    }
    // The NimBLE bond database and our metadata can diverge after a partial
    // restore. Never adopt such an already encrypted link as a new owner:
    // remove the orphan bond and reconnect so numeric comparison really runs.
    if ((trusted < 0 || identity_changed) && desc.sec_state.encrypted) {
        ble_store_util_delete_peer(&desc.peer_id_addr);
        deny_connection(conn_handle, "reconnect_for_pairing", 0);
        return 0;
    }
    set_state(DEVICE_TRUST_PAIRING, NULL);
    int rc = ble_gap_security_initiate(conn_handle);
    if (rc != 0 && rc != BLE_HS_EALREADY) {
        ESP_LOGW(TAG, "启动安全连接失败: rc=%d", rc);
        deny_connection(conn_handle, "security_start_failed", 0);
    }
    return 0;
}

static int state_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                           struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)conn_handle; (void)attr_handle; (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_READ_CHR) return BLE_ATT_ERR_UNLIKELY;
    // The initial pre-auth read and subsequent fragmented notifications must
    // never share the companion's line accumulator at the same time. Once
    // authorized, callers use COMMAND 0x07 for a serialized full refresh.
    if (device_trust_is_authorized()) return BLE_ATT_ERR_READ_NOT_PERMITTED;
    char *buf = malloc(STATE_BUF_LEN);
    if (!buf) return BLE_ATT_ERR_INSUFFICIENT_RES;
    int len = build_state(buf, STATE_BUF_LEN, NULL, NULL);
    if (len >= STATE_BUF_LEN) len = STATE_BUF_LEN - 1;
    int rc = len > 0 ? os_mbuf_append(ctxt->om, buf, (uint16_t)len) : -1;
    free(buf);
    return rc == 0 ? 0 : BLE_ATT_ERR_INSUFFICIENT_RES;
}

static int command_access_cb(uint16_t conn_handle, uint16_t attr_handle,
                             struct ble_gatt_access_ctxt *ctxt, void *arg)
{
    (void)attr_handle; (void)arg;
    if (ctxt->op != BLE_GATT_ACCESS_OP_WRITE_CHR) return BLE_ATT_ERR_UNLIKELY;
    if (!device_trust_is_authorized_conn(conn_handle)) return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;

    uint8_t cmd[1 + DEVICE_TRUST_ID_MAX + 1];
    uint16_t len = OS_MBUF_PKTLEN(ctxt->om);
    if (len < 1 || len > sizeof(cmd) || ble_hs_mbuf_to_flat(ctxt->om, cmd, len, NULL) != 0) {
        return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
    }
    char value[DEVICE_TRUST_ID_MAX + 1];
    copy_utf8_field(value, sizeof(value), cmd + 1, len - 1);
    switch (cmd[0]) {
    case DEVICE_TRUST_CMD_SET_ALIAS:
        if (len - 1 > DEVICE_TRUST_ALIAS_MAX || !device_trust_set_alias(value)) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        break;
    // Opening enrollment is intentionally physical-only (Passport's
    // Bluetooth page). A trusted companion cannot remotely make
    // the device discoverable to a new owner.
    case DEVICE_TRUST_CMD_OPEN_PAIRING: return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
    case DEVICE_TRUST_CMD_FORGET: {
        int ordinal = ordinal_by_id(value);
        if (ordinal < 0 || !device_trust_forget(ordinal)) return BLE_ATT_ERR_UNLIKELY;
        break;
    }
    case DEVICE_TRUST_CMD_FORGET_ALL: device_trust_forget_all(); break;
    case DEVICE_TRUST_CMD_HANDOFF: {
        int ordinal = ordinal_by_id(value);
        if (ordinal < 0 || !device_trust_handoff(ordinal)) return BLE_ATT_ERR_UNLIKELY;
        break;
    }
    case DEVICE_TRUST_CMD_YIELD:
        if (!device_trust_disconnect_current()) return BLE_ATT_ERR_WRITE_NOT_PERMITTED;
        break;
    case DEVICE_TRUST_CMD_REFRESH:
        auth_tx_prepare_refresh();
        notify_state(NULL);
        notify_trusted_list();
        break;
    case DEVICE_TRUST_CMD_SET_COMPANION_NAME: {
        size_t name_len = len - 1;
        if (name_len > DEVICE_TRUST_NAME_MAX ||
            !device_trust_companion_name_valid(cmd + 1, name_len)) {
            return BLE_ATT_ERR_INVALID_ATTR_VALUE_LEN;
        }
        bool accepted = false;
        portENTER_CRITICAL(&s_state_mux);
        int slot = find_by_addr_unlocked(&s_peer_id_addr);
        if (s_authorized && s_admission_granted && !s_disconnect_pending &&
            s_conn_handle == conn_handle && slot >= 0 &&
            s_store.records[slot].used == TRUST_RECORD_ACTIVE) {
            accepted = true;
            s_name_update_pending = true;
            s_name_update_conn_handle = conn_handle;
            s_name_update_connection_generation = s_connection_generation;
            s_name_update_slot = slot;
            memcpy(s_name_update_id, s_store.records[slot].id,
                   sizeof(s_name_update_id));
            memset(s_name_update_value, 0, sizeof(s_name_update_value));
            memcpy(s_name_update_value, value, name_len);
        }
        portEXIT_CRITICAL(&s_state_mux);
        if (!accepted) return BLE_ATT_ERR_INSUFFICIENT_AUTHOR;
        break;
    }
    default: return BLE_ATT_ERR_REQ_NOT_SUPPORTED;
    }
    return 0;
}

static const struct ble_gatt_svc_def s_gatt_svcs[] = {
    {
        .type = BLE_GATT_SVC_TYPE_PRIMARY,
        .uuid = &s_svc_uuid.u,
        .characteristics = (struct ble_gatt_chr_def[]) {
            { .uuid = &s_hello_uuid.u, .access_cb = hello_access_cb,
              .flags = BLE_GATT_CHR_F_WRITE },
            { .uuid = &s_state_uuid.u, .access_cb = state_access_cb,
              .flags = BLE_GATT_CHR_F_READ | BLE_GATT_CHR_F_INDICATE,
              .val_handle = &s_state_handle },
            { .uuid = &s_command_uuid.u, .access_cb = command_access_cb,
              .flags = BLE_GATT_CHR_F_WRITE },
            { 0 },
        },
    },
    { 0 },
};

void device_trust_init(void)
{
    trust_store_t store = { .version = TRUST_STORE_VERSION };
    bool migrated = false;
    char alias[sizeof(s_alias)] = "";
    if (!s_persist_mutex) s_persist_mutex = xSemaphoreCreateMutex();
    uint8_t mac[6] = { 0 };
    if (esp_read_mac(mac, ESP_MAC_BASE) == ESP_OK) {
        snprintf(s_device_id, sizeof(s_device_id), "%02X%02X", mac[4], mac[5]);
    } else {
        snprintf(s_device_id, sizeof(s_device_id), "????");
    }
    if (nvs_open(NVS_NAMESPACE, NVS_READWRITE, &s_nvs) != ESP_OK) {
        ESP_LOGE(TAG, "打开 NVS 失败,信任关系不会持久化");
        return;
    }
    s_nvs_open = true;
    size_t size = sizeof(store);
    esp_err_t store_err = nvs_get_blob(s_nvs, "peers", &store, &size);
    if (store_err == ESP_OK && size == sizeof(store) && store.version == 1) {
        for (int i = 0; i < DEVICE_TRUST_MAX_COMPANIONS; i++) {
            store.records[i].used = store.records[i].used
                ? TRUST_RECORD_ACTIVE : TRUST_RECORD_FREE;
        }
        store.version = TRUST_STORE_VERSION;
        migrated = true;
    } else if (store_err != ESP_OK || size != sizeof(store) ||
               store.version != TRUST_STORE_VERSION) {
        memset(&store, 0, sizeof(store));
        store.version = TRUST_STORE_VERSION;
    }
    size = sizeof(alias);
    if (nvs_get_str(s_nvs, "alias", alias, &size) != ESP_OK) alias[0] = '\0';
    portENTER_CRITICAL(&s_state_mux);
    s_store = store;
    memcpy(s_alias, alias, sizeof(s_alias));
    int count = trust_count_unlocked();
    portEXIT_CRITICAL(&s_state_mux);
    if (migrated) persist_store();
    ESP_LOGI(TAG, "连接信任就绪: %d 个伴侣,别名=%s", count,
             alias[0] ? alias : "(未设置)");
}

void device_trust_register(void)
{
    ble_hub_register_service(s_gatt_svcs);
}

void device_trust_configure_host(void)
{
    ble_hs_cfg.store_status_cb = ble_store_util_status_rr;
    ble_hs_cfg.sm_io_cap = BLE_SM_IO_CAP_DISP_YES_NO;
    ble_hs_cfg.sm_bonding = 1;
    ble_hs_cfg.sm_mitm = 1;
    ble_hs_cfg.sm_sc = 1;
    ble_hs_cfg.sm_our_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_hs_cfg.sm_their_key_dist = BLE_SM_PAIR_KEY_DIST_ENC | BLE_SM_PAIR_KEY_DIST_ID;
    ble_store_config_init();
}

int device_trust_gap_event(struct ble_gap_event *event)
{
    struct ble_gap_conn_desc desc;
    bool hello_received;
    switch (event->type) {
    case BLE_GAP_EVENT_CONNECT:
        if (event->connect.status == 0) {
            int64_t now = esp_timer_get_time();
            bool quarantined = false;
            bool reject_quarantined = false;
            int retry_after = 0;
            bool have_desc = ble_gap_conn_find(event->connect.conn_handle, &desc) == 0;
            portENTER_CRITICAL(&s_state_mux);
            s_conn_handle = event->connect.conn_handle;
            s_connection_generation++;
            s_authorized = false;
            s_admission_granted = false;
            s_hello_received = false;
            s_confirmation_pending = false;
            s_confirmation_mode = CONFIRM_NONE;
            s_numeric_confirmed = false;
            clear_reclaim_unlocked();
            s_pairing_new = false;
            s_stale_bond_repair_attempted = false;
            s_companion_id[0] = s_companion_name[0] = s_app_version[0] = '\0';
            s_platform = 0;
            s_retry_after = 0;
            s_auth_deadline = now + AUTH_HELLO_TIMEOUT_US;
            s_legacy_activity_seen = false;
            s_link_peer_valid = have_desc;
            if (have_desc) {
                s_link_peer_id_addr = desc.peer_id_addr;
                s_link_peer_ota_addr = desc.peer_ota_addr;
                quarantined = peer_is_quarantined_unlocked(&desc, now);
                if (quarantined) {
                    if (now >= s_quarantine_next_probation) {
                        // Periodically allow one short probation so the same
                        // OS identity can recover after upgrading its app.
                        s_quarantine_next_probation =
                            now + LEGACY_PROBATION_INTERVAL_US;
                        s_legacy_activity_seen = true;
                        s_auth_deadline = now + LEGACY_ACTIVITY_GRACE_US;
                    } else {
                        reject_quarantined = true;
                        int64_t remain = s_quarantine_next_probation - now;
                        retry_after = remain > 0
                            ? (int)((remain + 999999) / 1000000) : 1;
                    }
                }
            }
            portEXIT_CRITICAL(&s_state_mux);
            if (reject_quarantined) {
                deny_connection(event->connect.conn_handle,
                                "legacy_client_backoff", retry_after);
                auth_tx_clear();
                int rc = ble_gap_terminate(event->connect.conn_handle,
                                           BLE_ERR_REM_USER_CONN_TERM);
                if (rc != 0 && rc != BLE_HS_ENOTCONN) {
                    ESP_LOGW(TAG, "断开冷却中的旧版伴侣失败: rc=%d", rc);
                }
            } else {
                set_state(DEVICE_TRUST_CONNECTED,
                          quarantined ? "legacy_client_probation" : NULL);
            }
        }
        break;
    case BLE_GAP_EVENT_DISCONNECT:
        portENTER_CRITICAL(&s_state_mux);
        s_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        s_connection_generation++;
        s_authorized = false;
        s_admission_granted = false;
        s_confirmation_pending = false;
        s_confirmation_mode = CONFIRM_NONE;
        s_numeric_confirmed = false;
        clear_reclaim_unlocked();
        s_hello_received = false;
        s_stale_bond_repair_attempted = false;
        s_link_peer_valid = false;
        s_legacy_activity_seen = false;
        s_auth_deadline = 0;
        s_disconnect_pending = false;
        s_disconnect_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        s_disconnect_not_before = 0;
        s_disconnect_force_at = 0;
        s_retry_after = 0;
        s_name_update_pending = false;
        portEXIT_CRITICAL(&s_state_mux);
        auth_tx_set_subscribed(false);
        set_state(DEVICE_TRUST_IDLE, NULL);
        break;
    case BLE_GAP_EVENT_SUBSCRIBE:
        if (event->subscribe.attr_handle != s_state_handle &&
            (event->subscribe.cur_indicate || event->subscribe.cur_notify)) {
            int64_t now = esp_timer_get_time();
            portENTER_CRITICAL(&s_state_mux);
            bool legacy_access = event->subscribe.conn_handle == s_conn_handle &&
                                 !s_authorized && !s_hello_received &&
                                 !s_disconnect_pending;
            if (legacy_access) {
                // CoreBluetooth can restore old CCCD subscriptions before the
                // updated app has rediscovered AUTH.  Treat this as evidence,
                // not an immediate conviction: HELLO gets a short grace period.
                s_legacy_activity_seen = true;
                int64_t grace_deadline = now + LEGACY_ACTIVITY_GRACE_US;
                if (!s_auth_deadline || s_auth_deadline > grace_deadline) {
                    s_auth_deadline = grace_deadline;
                }
            }
            portEXIT_CRITICAL(&s_state_mux);
            if (legacy_access) {
                ESP_LOGW(TAG, "未认证伴侣订阅业务特征值,缩短 HELLO 宽限期");
            }
        }
        if (event->subscribe.attr_handle == s_state_handle) {
            bool subscribed = event->subscribe.cur_indicate;
            auth_tx_set_subscribed(subscribed);
            if (subscribed) {
                // Do not notify here. The companion sends HELLO only after this
                // subscription succeeds, and HELLO queues the first state transition.
                // This keeps one ordered notify stream in its line accumulator.
            }
        }
        break;
    case BLE_GAP_EVENT_NOTIFY_TX:
        if (event->notify_tx.attr_handle == s_state_handle) {
            portENTER_CRITICAL(&s_state_mux);
            uint32_t connection_generation = s_connection_generation;
            uint16_t current_conn_handle = s_conn_handle;
            portEXIT_CRITICAL(&s_state_mux);
            bool kick_next = false;
            bool failed = false;
            portENTER_CRITICAL(&s_tx_mux);
            bool matches = s_tx_sending && event->notify_tx.indication &&
                           event->notify_tx.conn_handle == s_tx_inflight_conn_handle &&
                           current_conn_handle == s_tx_inflight_conn_handle &&
                           connection_generation == s_tx_inflight_conn_generation &&
                           s_tx_generation == s_tx_inflight_tx_generation;
            if (matches && event->notify_tx.status == BLE_HS_EDONE && s_tx_count > 0) {
                auth_tx_item_t *head = &s_tx_queue[s_tx_head];
                head->offset = (uint16_t)(head->offset + s_tx_inflight_len);
                if (head->offset >= head->len) {
                    s_tx_head = (uint8_t)((s_tx_head + 1) % AUTH_TX_DEPTH);
                    s_tx_count--;
                }
                s_tx_sending = false;
                s_tx_started_at = 0;
                s_tx_inflight_len = 0;
                s_tx_inflight_conn_handle = BLE_HS_CONN_HANDLE_NONE;
                s_tx_inflight_conn_generation = 0;
                s_tx_inflight_tx_generation = 0;
                kick_next = true;
            } else if (matches && event->notify_tx.status != 0) {
                // Keep the uncommitted fragment. A failed indication means the
                // ordered auth stream cannot be trusted; disconnect instead of
                // blindly replaying it into an uncertain link.
                s_tx_sending = false;
                s_tx_started_at = 0;
                s_tx_inflight_len = 0;
                s_tx_inflight_conn_handle = BLE_HS_CONN_HANDLE_NONE;
                s_tx_inflight_conn_generation = 0;
                s_tx_inflight_tx_generation = 0;
                failed = true;
            }
            portEXIT_CRITICAL(&s_tx_mux);
            if (failed) {
                ble_gap_terminate(event->notify_tx.conn_handle,
                                  BLE_ERR_REM_USER_CONN_TERM);
            } else if (kick_next) {
                auth_tx_kick();
            }
        }
        break;
    case BLE_GAP_EVENT_PASSKEY_ACTION:
        portENTER_CRITICAL(&s_state_mux);
        hello_received = s_hello_received && s_admission_granted &&
                         !s_disconnect_pending &&
                         event->passkey.conn_handle == s_conn_handle;
        portEXIT_CRITICAL(&s_state_mux);
        if (event->passkey.params.action != BLE_SM_IOACT_NUMCMP || !hello_received) {
            ESP_LOGW(TAG, "拒绝不支持的配对动作: %d", event->passkey.params.action);
            deny_connection(event->passkey.conn_handle,
                            "numeric_comparison_required", 0);
            break;
        }
        portENTER_CRITICAL(&s_state_mux);
        s_numeric_code = event->passkey.params.numcmp;
        s_confirmation_pending = true;
        s_confirmation_mode = CONFIRM_SMP_NUMERIC;
        s_numeric_confirmed = false;
        portEXIT_CRITICAL(&s_state_mux);
        set_state(DEVICE_TRUST_AWAITING_CONFIRMATION, NULL);
        break;
    case BLE_GAP_EVENT_ENC_CHANGE:
        if (event->enc_change.status != 0) {
            int64_t now = esp_timer_get_time();
            portENTER_CRITICAL(&s_state_mux);
            bool repair_stale_bond =
                pin_key_missing_status(event->enc_change.status) &&
                event->enc_change.conn_handle == s_conn_handle &&
                !s_disconnect_pending && s_pairing_deadline > now &&
                !s_stale_bond_repair_attempted;
            bool repair_has_hello = repair_stale_bond &&
                                    s_hello_received && s_admission_granted;
            if (repair_stale_bond) s_stale_bond_repair_attempted = true;
            portEXIT_CRITICAL(&s_state_mux);
            if (repair_stale_bond) {
                ESP_LOGW(TAG, "系统仍持有已忘记的旧 BLE 密钥,尝试重新配对");
                set_state(repair_has_hello ? DEVICE_TRUST_PAIRING : DEVICE_TRUST_CONNECTED,
                          "repairing_system_bond");
                if (repair_has_hello) {
                    int rc = ble_gap_security_initiate(event->enc_change.conn_handle);
                    if (rc != 0 && rc != BLE_HS_EALREADY) {
                        deny_connection(event->enc_change.conn_handle,
                                        "stale_system_bond", 0);
                    }
                }
                break;
            }
            ESP_LOGW(TAG, "安全连接失败: status=%d", event->enc_change.status);
            deny_connection(event->enc_change.conn_handle,
                            pin_key_missing_status(event->enc_change.status)
                                ? "stale_system_bond" : "security_failed", 0);
            break;
        }
        if (ble_gap_conn_find(event->enc_change.conn_handle, &desc) != 0 ||
            !desc.sec_state.encrypted || !desc.sec_state.authenticated ||
            !desc.sec_state.bonded) {
            ESP_LOGW(TAG, "安全连接失败: status=%d", event->enc_change.status);
            deny_connection(event->enc_change.conn_handle, "security_failed", 0);
            break;
        }
        // Bonded reconnects often encrypt before service discovery. Keep the
        // business surface closed until HELLO identifies the companion UI.
        portENTER_CRITICAL(&s_state_mux);
        hello_received = s_hello_received && s_admission_granted &&
                         !s_disconnect_pending &&
                         event->enc_change.conn_handle == s_conn_handle;
        if (hello_received) s_peer_id_addr = desc.peer_id_addr;
        portEXIT_CRITICAL(&s_state_mux);
        if (!hello_received) break;
        portENTER_CRITICAL(&s_state_mux);
        bool needs_retrust = s_pairing_new && !s_numeric_confirmed;
        if (needs_retrust) {
            s_confirmation_pending = true;
            s_confirmation_mode = CONFIRM_RETRUST;
            s_numeric_code = 0;
            s_auth_deadline = esp_timer_get_time() + PAIRING_WINDOW_US;
        }
        portEXIT_CRITICAL(&s_state_mux);
        if (needs_retrust) {
            set_state(DEVICE_TRUST_AWAITING_CONFIRMATION, "retrust_confirmation");
            break;
        }
        authorize_current_peer(event->enc_change.conn_handle);
        break;
    case BLE_GAP_EVENT_REPEAT_PAIRING: {
        int64_t repeat_now = esp_timer_get_time();
        portENTER_CRITICAL(&s_state_mux);
        bool repeat_allowed = s_pairing_deadline > repeat_now &&
                              event->repeat_pairing.conn_handle == s_conn_handle &&
                              s_admission_granted && !s_disconnect_pending;
        portEXIT_CRITICAL(&s_state_mux);
        if (!repeat_allowed) return BLE_GAP_REPEAT_PAIRING_IGNORE;
        if (ble_gap_conn_find(event->repeat_pairing.conn_handle, &desc) == 0) {
            ble_store_util_delete_peer(&desc.peer_id_addr);
            return BLE_GAP_REPEAT_PAIRING_RETRY;
        }
        return BLE_GAP_REPEAT_PAIRING_IGNORE;
    }
    default:
        break;
    }
    return 0;
}

bool device_trust_is_authorized(void)
{
    portENTER_CRITICAL(&s_state_mux);
    bool authorized = s_authorized && s_admission_granted &&
                      !s_disconnect_pending && s_conn_handle != BLE_HS_CONN_HANDLE_NONE;
    portEXIT_CRITICAL(&s_state_mux);
    return authorized;
}

bool device_trust_is_authorized_conn(uint16_t conn_handle)
{
    portENTER_CRITICAL(&s_state_mux);
    bool authorized = s_authorized && s_admission_granted &&
                      !s_disconnect_pending && conn_handle == s_conn_handle;
    portEXIT_CRITICAL(&s_state_mux);
    return authorized;
}

bool device_trust_authorized_link(uint16_t *conn_handle, uint32_t *generation)
{
    if (!conn_handle) return false;
    portENTER_CRITICAL(&s_state_mux);
    bool authorized = s_authorized && s_admission_granted &&
                      !s_disconnect_pending &&
                      s_conn_handle != BLE_HS_CONN_HANDLE_NONE;
    if (authorized) {
        *conn_handle = s_conn_handle;
        if (generation) *generation = s_connection_generation;
    }
    portEXIT_CRITICAL(&s_state_mux);
    return authorized;
}

bool device_trust_authorized_link_matches(uint16_t conn_handle, uint32_t generation)
{
    portENTER_CRITICAL(&s_state_mux);
    bool matches = s_authorized && s_admission_granted && !s_disconnect_pending &&
                   s_conn_handle == conn_handle && s_connection_generation == generation;
    portEXIT_CRITICAL(&s_state_mux);
    return matches;
}

void device_trust_tick(void)
{
    process_pending_name_update();
    int64_t now = esp_timer_get_time();
    bool tx_stalled = false;
    uint16_t stalled_conn_handle = BLE_HS_CONN_HANDLE_NONE;
    uint32_t stalled_conn_generation = 0;
    portENTER_CRITICAL(&s_tx_mux);
    if (s_tx_sending && now - s_tx_started_at >= AUTH_TX_CONFIRM_TIMEOUT_US) {
        tx_stalled = true;
        stalled_conn_handle = s_tx_inflight_conn_handle;
        stalled_conn_generation = s_tx_inflight_conn_generation;
    }
    portEXIT_CRITICAL(&s_tx_mux);
    if (tx_stalled) {
        portENTER_CRITICAL(&s_state_mux);
        bool same_connection = s_conn_handle == stalled_conn_handle &&
                               s_connection_generation == stalled_conn_generation;
        portEXIT_CRITICAL(&s_state_mux);
        if (same_connection) {
            ble_gap_terminate(stalled_conn_handle, BLE_ERR_REM_USER_CONN_TERM);
        } else {
            auth_tx_clear();
        }
    } else {
        auth_tx_kick();
    }

    bool auth_expired = false;
    bool reject_confirmation = false;
    uint16_t auth_expired_conn = BLE_HS_CONN_HANDLE_NONE;
    bool pairing_expired = false;
    bool handoff_expired = false;
    bool disconnect_due = false;
    uint16_t disconnect_conn_handle = BLE_HS_CONN_HANDLE_NONE;
    int64_t disconnect_force_at = 0;
    portENTER_CRITICAL(&s_state_mux);
    if (s_auth_deadline && now >= s_auth_deadline && !s_authorized) {
        s_auth_deadline = 0;
        // Expiry and revocation are one atomic transition. Otherwise a late
        // PASSKEY/ENC_CHANGE event can authorize the peer in the gap before
        // the delayed disconnect is armed below.
        s_authorized = false;
        s_admission_granted = false;
        s_state = DEVICE_TRUST_DENIED;
        s_revision++;
        bool missing_hello = !s_hello_received;
        snprintf(s_reason, sizeof(s_reason), "%s",
                 missing_hello && s_legacy_activity_seen
                     ? "legacy_client" :
                 missing_hello ? "hello_timeout" : "confirmation_timeout");
        if (missing_hello) quarantine_current_peer_unlocked(now);
        auth_expired = true;
        auth_expired_conn = s_conn_handle;
        reject_confirmation = s_confirmation_pending &&
                              s_confirmation_mode == CONFIRM_SMP_NUMERIC;
        s_confirmation_pending = false;
        s_confirmation_mode = CONFIRM_NONE;
        s_numeric_confirmed = false;
        clear_reclaim_unlocked();
        s_retry_after = missing_hello
            ? (int)(LEGACY_PEER_COOLDOWN_US / 1000000) : 0;
        s_disconnect_pending = true;
        s_disconnect_conn_handle = s_conn_handle;
        s_disconnect_not_before = now + 100000;
        s_disconnect_force_at = now + 3000000;
    }
    if (s_pairing_deadline && now >= s_pairing_deadline) {
        s_pairing_deadline = 0;
        s_enrollment_active = false;
        s_revision++;
        snprintf(s_reason, sizeof(s_reason), "%s", "pairing_window_expired");
        pairing_expired = true;
    }
    if (s_handoff_deadline && now >= s_handoff_deadline) {
        s_handoff_deadline = 0;
        s_handoff_target = -1;
        s_revision++;
        snprintf(s_reason, sizeof(s_reason), "%s", "handoff_window_expired");
        handoff_expired = true;
    }
    if (s_disconnect_pending && now >= s_disconnect_not_before) {
        disconnect_due = true;
        disconnect_conn_handle = s_disconnect_conn_handle;
        disconnect_force_at = s_disconnect_force_at;
    }
    portEXIT_CRITICAL(&s_state_mux);

    if (auth_expired) {
        if (reject_confirmation) {
            struct ble_sm_io io = { .action = BLE_SM_IOACT_NUMCMP };
            io.numcmp_accept = 0;
            ble_sm_inject_io(auth_expired_conn, &io);
        }
        queue_state_snapshot();
    }
    if (pairing_expired) queue_state_snapshot();
    if (handoff_expired) queue_state_snapshot();
    if (disconnect_due && (auth_tx_idle() || now >= disconnect_force_at)) {
        portENTER_CRITICAL(&s_state_mux);
        bool still_due = s_disconnect_pending && now >= s_disconnect_not_before &&
                         s_conn_handle == disconnect_conn_handle;
        if (still_due) {
            s_disconnect_pending = false;
            s_disconnect_conn_handle = BLE_HS_CONN_HANDLE_NONE;
        }
        portEXIT_CRITICAL(&s_state_mux);
        if (!still_due) return;
        ble_gap_terminate(disconnect_conn_handle, BLE_ERR_REM_USER_CONN_TERM);
    }
}

void device_trust_snapshot(device_trust_snapshot_t *out)
{
    if (!out) return;
    int64_t now = esp_timer_get_time();
    memset(out, 0, sizeof(*out));
    portENTER_CRITICAL(&s_state_mux);
    out->state = s_state;
    out->revision = s_revision;
    out->numeric_code = s_numeric_code;
    int64_t remain = s_pairing_deadline - now;
    out->pairing_seconds = remain > 0 ? (int)((remain + 999999) / 1000000) : 0;
    out->pairing_discovery_active = s_enrollment_active && remain > 0;
    out->authorized = s_authorized;
    out->confirmation_pending = s_confirmation_pending;
    out->confirmation_retrust = s_confirmation_mode == CONFIRM_RETRUST;
    out->platform = s_platform;
    memcpy(out->companion_id, s_companion_id, sizeof(out->companion_id));
    memcpy(out->companion_name, s_companion_name, sizeof(out->companion_name));
    memcpy(out->app_version, s_app_version, sizeof(out->app_version));
    memcpy(out->alias, s_alias, sizeof(out->alias));
    portEXIT_CRITICAL(&s_state_mux);
}

void device_trust_confirm_pairing(bool accept)
{
    portENTER_CRITICAL(&s_state_mux);
    if (!s_confirmation_pending || !s_admission_granted || s_disconnect_pending ||
        s_conn_handle == BLE_HS_CONN_HANDLE_NONE) {
        portEXIT_CRITICAL(&s_state_mux);
        return;
    }
    uint16_t conn_handle = s_conn_handle;
    uint32_t connection_generation = s_connection_generation;
    confirmation_mode_t mode = s_confirmation_mode;
    bool reclaim_pending = s_reclaim_pending;
    int reclaim_slot = s_reclaim_slot;
    ble_addr_t reclaim_addr = s_reclaim_addr;
    s_confirmation_pending = false;
    s_confirmation_mode = CONFIRM_NONE;
    if (mode == CONFIRM_SMP_NUMERIC && accept) s_numeric_confirmed = true;
    portEXIT_CRITICAL(&s_state_mux);
    if (mode == CONFIRM_RETRUST) {
        if (accept) {
            struct ble_gap_conn_desc desc;
            bool secure = ble_gap_conn_find(conn_handle, &desc) == 0 &&
                          desc.sec_state.encrypted &&
                          desc.sec_state.authenticated && desc.sec_state.bonded;
            portENTER_CRITICAL(&s_state_mux);
            secure = secure && s_conn_handle == conn_handle &&
                     s_connection_generation == connection_generation &&
                     s_admission_granted && !s_disconnect_pending;
            portEXIT_CRITICAL(&s_state_mux);
            if (secure) {
                authorize_current_peer(conn_handle);
            } else {
                deny_connection(conn_handle, "retrust_link_not_secure", 0);
            }
        } else {
            deny_connection(conn_handle, "user_rejected", 0);
        }
        return;
    }
    if (mode == CONFIRM_SMP_NUMERIC && accept && reclaim_pending) {
        int delete_rc = ble_store_util_delete_peer(&reclaim_addr);
        if (delete_rc != 0 && delete_rc != BLE_HS_ENOENT) {
            ESP_LOGW(TAG, "确认后回收旧 BLE bond 失败: rc=%d", delete_rc);
            deny_connection(conn_handle, "trust_store_reclaim_failed", 0);
            return;
        }
        portENTER_CRITICAL(&s_state_mux);
        bool still_current = s_conn_handle == conn_handle &&
                             s_connection_generation == connection_generation &&
                             s_reclaim_pending && s_reclaim_slot == reclaim_slot &&
                             reclaim_slot >= 0 &&
                             reclaim_slot < DEVICE_TRUST_MAX_COMPANIONS &&
                             s_store.records[reclaim_slot].used == TRUST_RECORD_REVOKED &&
                             s_store.records[reclaim_slot].addr_type == reclaim_addr.type &&
                             memcmp(s_store.records[reclaim_slot].addr,
                                    reclaim_addr.val, sizeof(reclaim_addr.val)) == 0;
        if (still_current) {
            memset(&s_store.records[reclaim_slot], 0,
                   sizeof(s_store.records[reclaim_slot]));
            clear_reclaim_unlocked();
            s_revision++;
        }
        portEXIT_CRITICAL(&s_state_mux);
        if (!still_current) {
            deny_connection(conn_handle, "trust_store_reclaim_race", 0);
            return;
        }
        persist_store();
    }
    struct ble_sm_io io = { .action = BLE_SM_IOACT_NUMCMP };
    io.numcmp_accept = accept ? 1 : 0;
    int rc = ble_sm_inject_io(conn_handle, &io);
    if (!accept || rc != 0) {
        portENTER_CRITICAL(&s_state_mux);
        s_numeric_confirmed = false;
        portEXIT_CRITICAL(&s_state_mux);
        deny_connection(conn_handle,
                        accept ? "confirmation_failed" : "user_rejected", 0);
    } else {
        set_state(DEVICE_TRUST_PAIRING, NULL);
    }
}

int device_trust_count(void) { return trust_count_internal(); }

bool device_trust_companion(int index, char *id, size_t id_size,
                            char *name, size_t name_size, uint8_t *platform)
{
    int seen = 0;
    bool found = false;
    trust_record_t record = { 0 };
    portENTER_CRITICAL(&s_state_mux);
    for (int i = 0; i < DEVICE_TRUST_MAX_COMPANIONS; i++) {
        trust_record_t *r = &s_store.records[i];
        if (r->used != TRUST_RECORD_ACTIVE) continue;
        if (seen++ != index) continue;
        record = *r;
        found = true;
        break;
    }
    portEXIT_CRITICAL(&s_state_mux);
    if (found) {
        if (id && id_size) snprintf(id, id_size, "%s", record.id);
        if (name && name_size) snprintf(name, name_size, "%s", record.name);
        if (platform) *platform = record.platform;
    }
    return found;
}

bool device_trust_open_pairing_window(void)
{
    if (appstore_transfer_is_active() || codex_voice_active() ||
        walkie_audio_is_transmitting() || walkie_audio_is_receiving()) {
        notify_state("busy");
        return false;
    }
    int64_t deadline = esp_timer_get_time() + PAIRING_WINDOW_US;
    portENTER_CRITICAL(&s_state_mux);
    s_pairing_deadline = deadline;
    s_enrollment_active = true;
    s_handoff_target = -1;
    s_handoff_deadline = 0;
    s_manually_disconnected_slot = -1;
    s_revision++;
    uint16_t conn_handle = s_conn_handle;
    portEXIT_CRITICAL(&s_state_mux);
    if (conn_handle != BLE_HS_CONN_HANDLE_NONE) {
        // With MAX_CONNECTIONS=1 the new companion cannot even connect while
        // the old owner holds the slot. Tell the current owner to back off,
        // then release it after the queued state has actually gone out.
        disconnect_after_state_for(conn_handle,
                                   (int)(HANDOFF_DISCONNECT_US / 1000), 60);
        notify_state("yield");
        revoke_business_authorization();
    } else {
        notify_state("pairing_window_open");
    }
    return true;
}

bool device_trust_disconnect_current(void)
{
    if (appstore_transfer_is_active() || codex_voice_active() ||
        walkie_audio_is_transmitting() || walkie_audio_is_receiving()) {
        notify_state("busy");
        return false;
    }
    portENTER_CRITICAL(&s_state_mux);
    uint16_t conn_handle = s_authorized && s_admission_granted &&
                           !s_disconnect_pending
        ? s_conn_handle : BLE_HS_CONN_HANDLE_NONE;
    int slot = conn_handle != BLE_HS_CONN_HANDLE_NONE
        ? find_by_addr_unlocked(&s_peer_id_addr) : -1;
    if (slot >= 0 && s_store.records[slot].used == TRUST_RECORD_ACTIVE) {
        s_manually_disconnected_slot = slot;
        s_handoff_target = -1;
        s_handoff_deadline = 0;
        s_pairing_deadline = 0;
        s_enrollment_active = false;
        s_revision++;
    } else {
        slot = -1;
    }
    portEXIT_CRITICAL(&s_state_mux);
    if (conn_handle == BLE_HS_CONN_HANDLE_NONE || slot < 0) return false;

    // Queue the authenticated yield first so the companion can stop its own
    // auto-reconnect loop. device_trust_tick() terminates GAP after the ordered
    // indication drains; no bond or trust record is removed.
    disconnect_after_state_for(conn_handle,
                               (int)(HANDOFF_DISCONNECT_US / 1000), 10);
    notify_state("manual_disconnect");
    revoke_business_authorization();
    return true;
}

bool device_trust_set_alias(const char *alias)
{
    if (!alias) return false;
    size_t len = strlen(alias);
    if (len > DEVICE_TRUST_ALIAS_MAX) return false;
    portENTER_CRITICAL(&s_state_mux);
    memset(s_alias, 0, sizeof(s_alias));
    memcpy(s_alias, alias, len);
    s_revision++;
    portEXIT_CRITICAL(&s_state_mux);
    persist_store();
    notify_state("alias_changed");
    return true;
}

bool device_trust_forget(int index)
{
    bool current = false;
    uint16_t conn_handle = BLE_HS_CONN_HANDLE_NONE;
    portENTER_CRITICAL(&s_state_mux);
    int slot = device_trust_slot_from_ordinal(used_mask_unlocked(), index);
    if (slot >= 0) {
        trust_record_t *r = &s_store.records[slot];
        current = s_authorized && s_conn_handle != BLE_HS_CONN_HANDLE_NONE &&
                  addr_equal(r, &s_peer_id_addr);
        if (current) conn_handle = s_conn_handle;
        r->used = TRUST_RECORD_REVOKED;
        r->platform = 0;
        memset(r->id, 0, sizeof(r->id));
        memset(r->name, 0, sizeof(r->name));
        memset(r->app_version, 0, sizeof(r->app_version));
        if (s_manually_disconnected_slot == slot) s_manually_disconnected_slot = -1;
        if (s_handoff_target == slot) {
            s_handoff_target = -1;
            s_handoff_deadline = 0;
            s_pairing_deadline = 0;
            s_enrollment_active = false;
        }
        s_revision++;
    }
    portEXIT_CRITICAL(&s_state_mux);
    if (slot >= 0) {
        persist_store();
        notify_state(current ? "current_companion_forgotten"
                             : "trusted_companion_forgotten");
        if (current) {
            disconnect_after_state_for(conn_handle, 100, 0);
            revoke_business_authorization();
        }
        return true;
    }
    return false;
}

bool device_trust_forget_all(void)
{
    uint16_t conn_handle;
    portENTER_CRITICAL(&s_state_mux);
    conn_handle = s_conn_handle;
    for (int i = 0; i < DEVICE_TRUST_MAX_COMPANIONS; i++) {
        trust_record_t *r = &s_store.records[i];
        if (r->used != TRUST_RECORD_ACTIVE) continue;
        r->used = TRUST_RECORD_REVOKED;
        r->platform = 0;
        memset(r->id, 0, sizeof(r->id));
        memset(r->name, 0, sizeof(r->name));
        memset(r->app_version, 0, sizeof(r->app_version));
    }
    s_pairing_deadline = 0;
    s_enrollment_active = false;
    s_manually_disconnected_slot = -1;
    s_handoff_target = -1;
    s_handoff_deadline = 0;
    s_revision++;
    portEXIT_CRITICAL(&s_state_mux);
    persist_store();
    notify_state("all_companions_forgotten");
    disconnect_after_state_for(conn_handle, 100, 0);
    revoke_business_authorization();
    return true;
}

bool device_trust_handoff(int index)
{
    if (appstore_transfer_is_active() || codex_voice_active() ||
        walkie_audio_is_transmitting() || walkie_audio_is_receiving()) {
        notify_state("busy");
        return false;
    }
    uint16_t conn_handle;
    portENTER_CRITICAL(&s_state_mux);
    conn_handle = s_conn_handle;
    int slot = device_trust_slot_from_ordinal(used_mask_unlocked(), index);
    if (slot >= 0) {
        s_handoff_target = slot;
        s_manually_disconnected_slot = -1;
        s_enrollment_active = false;
        s_handoff_deadline = esp_timer_get_time() + HANDOFF_WINDOW_US;
        s_pairing_deadline = s_handoff_deadline;
        s_revision++;
    }
    portEXIT_CRITICAL(&s_state_mux);
    if (slot >= 0) {
        disconnect_after_state_for(conn_handle,
                                   (int)(HANDOFF_DISCONNECT_US / 1000),
                                   HANDOFF_RETRY_AFTER_SEC);
        notify_state("handoff");
        revoke_business_authorization();
        return true;
    }
    return false;
}
