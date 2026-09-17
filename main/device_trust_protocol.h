// Host-testable companion-auth command and text validation model.
#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef enum {
    DEVICE_TRUST_CMD_SET_ALIAS = 0x01,
    DEVICE_TRUST_CMD_OPEN_PAIRING = 0x02,
    DEVICE_TRUST_CMD_FORGET = 0x03,
    DEVICE_TRUST_CMD_FORGET_ALL = 0x04,
    DEVICE_TRUST_CMD_HANDOFF = 0x05,
    DEVICE_TRUST_CMD_YIELD = 0x06,
    DEVICE_TRUST_CMD_REFRESH = 0x07,
    DEVICE_TRUST_CMD_SET_COMPANION_NAME = 0x08,
} device_trust_command_t;

// A companion name is user-visible on Passport. Reject malformed UTF-8,
// control characters and whitespace-only names before they reach NVS/LVGL.
bool device_trust_companion_name_valid(const uint8_t *bytes, size_t len);

typedef enum {
    DEVICE_TRUST_SLOT_ALLOWED = 0,
    DEVICE_TRUST_SLOT_MANUALLY_DISCONNECTED,
    DEVICE_TRUST_SLOT_NOT_SELECTED,
} device_trust_slot_admission_t;

// Model the RAM-only manual-disconnect fence and directed single-link handoff.
device_trust_slot_admission_t device_trust_slot_admission(
    int trusted_slot, int manually_disconnected_slot, int handoff_target_slot);

// First logical row to show in a fixed-size list window while keeping the
// selected row visible.
int device_trust_window_first(int selected, int count, int visible_rows);
