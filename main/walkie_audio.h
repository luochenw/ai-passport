#pragma once

#include <stdbool.h>

// Registers the walkie-talkie GATT service and its BLE observers. Must be
// called before ble_hub_init().
void walkie_audio_register(void);

// Creates the bounded playback queue and audio worker. Call after
// bsp_audio_init() and before BLE can accept a connection.
void walkie_audio_init(void);

typedef void (*walkie_audio_activity_fn)(bool receiving);
void walkie_audio_set_activity_hook(walkie_audio_activity_fn fn);

bool walkie_audio_is_transmitting(void);
bool walkie_audio_is_receiving(void);
