#include "device_trust_protocol.h"
#include <assert.h>
#include <string.h>

int main(void)
{
    const char *iphone = "我的 iPhone";
    const char *mac = "工作 Mac";
    assert(device_trust_companion_name_valid((const uint8_t *)iphone, strlen(iphone)));
    assert(device_trust_companion_name_valid((const uint8_t *)mac, strlen(mac)));
    assert(!device_trust_companion_name_valid(NULL, 0));
    assert(!device_trust_companion_name_valid((const uint8_t *)"", 0));
    assert(!device_trust_companion_name_valid((const uint8_t *)"   ", 3));
    assert(!device_trust_companion_name_valid((const uint8_t *)"bad\nname", 8));

    const uint8_t truncated[] = { 0xe6, 0x88 };
    const uint8_t overlong[] = { 0xe0, 0x80, 0x80 };
    const uint8_t surrogate[] = { 0xed, 0xa0, 0x80 };
    const uint8_t too_large[] = { 0xf4, 0x90, 0x80, 0x80 };
    assert(!device_trust_companion_name_valid(truncated, sizeof(truncated)));
    assert(!device_trust_companion_name_valid(overlong, sizeof(overlong)));
    assert(!device_trust_companion_name_valid(surrogate, sizeof(surrogate)));
    assert(!device_trust_companion_name_valid(too_large, sizeof(too_large)));

    assert(DEVICE_TRUST_CMD_SET_ALIAS == 0x01);
    assert(DEVICE_TRUST_CMD_YIELD == 0x06);
    assert(DEVICE_TRUST_CMD_REFRESH == 0x07);
    assert(DEVICE_TRUST_CMD_SET_COMPANION_NAME == 0x08);

    assert(device_trust_slot_admission(2, -1, -1) == DEVICE_TRUST_SLOT_ALLOWED);
    assert(device_trust_slot_admission(2, 2, -1) ==
           DEVICE_TRUST_SLOT_MANUALLY_DISCONNECTED);
    assert(device_trust_slot_admission(2, 2, 2) == DEVICE_TRUST_SLOT_ALLOWED);
    assert(device_trust_slot_admission(1, -1, 2) == DEVICE_TRUST_SLOT_NOT_SELECTED);
    assert(device_trust_slot_admission(2, -1, 2) == DEVICE_TRUST_SLOT_ALLOWED);
    assert(device_trust_slot_admission(-1, 2, 2) == DEVICE_TRUST_SLOT_ALLOWED);

    assert(device_trust_window_first(0, 10, 7) == 0);
    assert(device_trust_window_first(6, 10, 7) == 0);
    assert(device_trust_window_first(7, 10, 7) == 1);
    assert(device_trust_window_first(9, 10, 7) == 3);
    assert(device_trust_window_first(99, 10, 7) == 3);
    assert(device_trust_window_first(3, 4, 7) == 0);
    return 0;
}
