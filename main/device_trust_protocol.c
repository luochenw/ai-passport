#include "device_trust_protocol.h"

bool device_trust_companion_name_valid(const uint8_t *bytes, size_t len)
{
    if (!bytes || len == 0) return false;
    bool visible = false;
    for (size_t i = 0; i < len;) {
        uint8_t c = bytes[i];
        if (c < 0x80) {
            if (c < 0x20 || c == 0x7f) return false;
            if (c != ' ') visible = true;
            i++;
            continue;
        }

        size_t continuation_count;
        uint32_t codepoint;
        if (c >= 0xc2 && c <= 0xdf) {
            continuation_count = 1;
            codepoint = c & 0x1f;
        } else if (c >= 0xe0 && c <= 0xef) {
            continuation_count = 2;
            codepoint = c & 0x0f;
        } else if (c >= 0xf0 && c <= 0xf4) {
            continuation_count = 3;
            codepoint = c & 0x07;
        } else {
            return false;
        }
        if (i + continuation_count >= len) return false;
        for (size_t j = 1; j <= continuation_count; j++) {
            uint8_t next = bytes[i + j];
            if ((next & 0xc0) != 0x80) return false;
            codepoint = (codepoint << 6) | (next & 0x3f);
        }
        if ((continuation_count == 2 && codepoint < 0x800) ||
            (continuation_count == 3 && codepoint < 0x10000) ||
            (codepoint >= 0xd800 && codepoint <= 0xdfff) ||
            codepoint > 0x10ffff) {
            return false;
        }
        visible = true;
        i += continuation_count + 1;
    }
    return visible;
}

device_trust_slot_admission_t device_trust_slot_admission(
    int trusted_slot, int manually_disconnected_slot, int handoff_target_slot)
{
    if (trusted_slot < 0) return DEVICE_TRUST_SLOT_ALLOWED;
    if (handoff_target_slot >= 0 && trusted_slot != handoff_target_slot) {
        return DEVICE_TRUST_SLOT_NOT_SELECTED;
    }
    if (trusted_slot == manually_disconnected_slot &&
        trusted_slot != handoff_target_slot) {
        return DEVICE_TRUST_SLOT_MANUALLY_DISCONNECTED;
    }
    return DEVICE_TRUST_SLOT_ALLOWED;
}

int device_trust_window_first(int selected, int count, int visible_rows)
{
    if (count <= 0 || visible_rows <= 0 || count <= visible_rows) return 0;
    if (selected < 0) selected = 0;
    if (selected >= count) selected = count - 1;
    int first = selected >= visible_rows ? selected - visible_rows + 1 : 0;
    int max_first = count - visible_rows;
    return first < max_first ? first : max_first;
}
