#pragma once

#include "wifi_mgr.h"
#include <string.h>

typedef enum {
    WIFI_MGR_USE_OPEN,
    WIFI_MGR_USE_SAVED,
    WIFI_MGR_ASK_PASSWORD,
} wifi_mgr_credential_choice_t;

static inline bool wifi_mgr_ssid_supported(const unsigned char *ssid, size_t length)
{
    if (!ssid || length == 0 || length >= WIFI_MGR_SSID_LEN) return false;
    for (size_t i = 0; i < length; ++i) {
        if (ssid[i] < 32 || ssid[i] == 127) return false;
    }
    return true;
}

static inline wifi_mgr_credential_choice_t wifi_mgr_choose_credentials(
    const wifi_mgr_ap_t *ap, const char *saved_ssid, const char *saved_password)
{
    if (!ap->secure) return WIFI_MGR_USE_OPEN;
    if (saved_ssid && saved_password && saved_password[0] &&
        strcmp(ap->ssid, saved_ssid) == 0) return WIFI_MGR_USE_SAVED;
    return WIFI_MGR_ASK_PASSWORD;
}

// Driver SSIDs have at most 32 bytes and need not end in NUL. Merge repeated
// BSSIDs while keeping open and protected networks with the same name separate.
// Strongest signal first, including when a duplicate arrives later.
static inline int wifi_mgr_merge_ap(wifi_mgr_ap_t *list, int count,
                                    const unsigned char *ssid, int rssi, bool secure)
{
    wifi_mgr_ap_t ap = { .rssi = rssi, .secure = secure };
    size_t len = 0;
    while (len < WIFI_MGR_SSID_LEN - 1 && ssid[len]) ++len;
    // The current BLE protocol is line based. Do not show an altered name that
    // the companion cannot write back exactly (e.g. SSIDs containing LF/tab).
    if (!wifi_mgr_ssid_supported(ssid, len)) return count;
    memcpy(ap.ssid, ssid, len);

    for (int i = 0; i < count; ++i) {
        if (list[i].secure != secure || strcmp(list[i].ssid, ap.ssid) != 0) continue;
        if (list[i].rssi >= rssi) return count;
        for (int j = i; j + 1 < count; ++j) list[j] = list[j + 1];
        --count;
        break;
    }
    int insert = 0;
    while (insert < count && list[insert].rssi >= rssi) ++insert;
    if (insert >= WIFI_MGR_MAX_SCAN) return count;
    if (count < WIFI_MGR_MAX_SCAN) ++count;
    for (int i = count - 1; i > insert; --i) list[i] = list[i - 1];
    list[insert] = ap;
    return count;
}
