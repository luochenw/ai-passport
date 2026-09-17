#include "wifi_mgr_model.h"
#include <assert.h>
#include <stdio.h>

static void test_credentials(void)
{
    wifi_mgr_ap_t ap = { .ssid = "Office", .secure = true };
    assert(wifi_mgr_choose_credentials(&ap, "Home", "old-password") == WIFI_MGR_ASK_PASSWORD);
    assert(wifi_mgr_choose_credentials(&ap, "Office", "") == WIFI_MGR_ASK_PASSWORD);
    assert(wifi_mgr_choose_credentials(&ap, "Office", "saved-password") == WIFI_MGR_USE_SAVED);
    ap.secure = false;
    assert(wifi_mgr_choose_credentials(&ap, "Office", "saved-password") == WIFI_MGR_USE_OPEN);
}

static void test_results(void)
{
    wifi_mgr_ap_t list[WIFI_MGR_MAX_SCAN] = { 0 };
    int n = wifi_mgr_merge_ap(list, 0, (const unsigned char *)"", -10, true);
    assert(n == 0);
    n = wifi_mgr_merge_ap(list, n, (const unsigned char *)"bad\nname", -10, true);
    assert(n == 0);
    n = wifi_mgr_merge_ap(list, n, (const unsigned char *)"Office", -70, true);
    n = wifi_mgr_merge_ap(list, n, (const unsigned char *)"Cafe", -50, false);
    n = wifi_mgr_merge_ap(list, n, (const unsigned char *)"Office", -90, true);
    assert(n == 2 && strcmp(list[0].ssid, "Cafe") == 0 && list[1].rssi == -70);
    n = wifi_mgr_merge_ap(list, n, (const unsigned char *)"Office", -40, true);
    assert(n == 2 && strcmp(list[0].ssid, "Office") == 0 && list[0].rssi == -40);
    n = wifi_mgr_merge_ap(list, n, (const unsigned char *)"Office", -30, false);
    assert(n == 3 && !list[0].secure && list[1].secure);

    unsigned char full_ssid[32];
    memset(full_ssid, 'x', sizeof(full_ssid));
    n = wifi_mgr_merge_ap(list, n, full_ssid, -20, true);
    assert(n == 4 && strlen(list[0].ssid) == 32);
    assert(list[0].ssid[32] == '\0');
    for (int i = 0; i < 40; ++i) {
        char ssid[16];
        snprintf(ssid, sizeof(ssid), "AP-%d", i);
        n = wifi_mgr_merge_ap(list, n, (const unsigned char *)ssid, -100 + i, true);
    }
    assert(n == WIFI_MGR_MAX_SCAN);
    for (int i = 1; i < n; ++i) assert(list[i - 1].rssi >= list[i].rssi);
    n = wifi_mgr_merge_ap(list, n, (const unsigned char *)"strongest", -1, false);
    assert(n == WIFI_MGR_MAX_SCAN && strcmp(list[0].ssid, "strongest") == 0);
    assert(!wifi_mgr_ssid_supported((const unsigned char *)"a\tb", 3));
    assert(!wifi_mgr_ssid_supported((const unsigned char *)"a\rb", 3));
}

int main(void)
{
    test_credentials();
    test_results();
    puts("Wi-Fi model tests: PASS");
    return 0;
}
