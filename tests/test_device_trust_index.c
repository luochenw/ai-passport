#include "device_trust_index.h"
#include <assert.h>

int main(void)
{
    // Slots 0, 2 and 6 are occupied. Public list indices must stay compact.
    const uint8_t holes = (1u << 0) | (1u << 2) | (1u << 6);
    assert(device_trust_slot_from_ordinal(holes, 0) == 0);
    assert(device_trust_slot_from_ordinal(holes, 1) == 2);
    assert(device_trust_slot_from_ordinal(holes, 2) == 6);
    assert(device_trust_slot_from_ordinal(holes, 3) == -1);
    assert(device_trust_ordinal_from_slot(holes, 0) == 0);
    assert(device_trust_ordinal_from_slot(holes, 2) == 1);
    assert(device_trust_ordinal_from_slot(holes, 6) == 2);
    assert(device_trust_ordinal_from_slot(holes, 1) == -1);
    assert(device_trust_ordinal_from_slot(holes, -1) == -1);
    return 0;
}
