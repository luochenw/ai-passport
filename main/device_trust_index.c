#include "device_trust_index.h"

int device_trust_slot_from_ordinal(uint8_t used_mask, int ordinal)
{
    if (ordinal < 0) return -1;
    int seen = 0;
    for (int slot = 0; slot < 8; slot++) {
        if (!(used_mask & (1u << slot))) continue;
        if (seen++ == ordinal) return slot;
    }
    return -1;
}

int device_trust_ordinal_from_slot(uint8_t used_mask, int slot)
{
    if (slot < 0 || slot >= 8 || !(used_mask & (1u << slot))) return -1;
    int ordinal = 0;
    for (int i = 0; i < slot; i++) {
        if (used_mask & (1u << i)) ordinal++;
    }
    return ordinal;
}
