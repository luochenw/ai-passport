#pragma once

#include <stdint.h>

// Convert between the compact user-visible trusted-list ordinal and the fixed
// NVS slot. Kept IDF-independent so holes caused by forgetting a peer are easy
// to unit-test on the host.
int device_trust_slot_from_ordinal(uint8_t used_mask, int ordinal);
int device_trust_ordinal_from_slot(uint8_t used_mask, int slot);
