// Passport companion authentication and connection ownership.
#pragma once

#include "host/ble_gap.h"
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

#define DEVICE_TRUST_MAX_COMPANIONS 8
#define DEVICE_TRUST_ID_MAX         64
#define DEVICE_TRUST_NAME_MAX       48
#define DEVICE_TRUST_ALIAS_MAX      32

typedef enum {
    DEVICE_TRUST_IDLE = 0,
    DEVICE_TRUST_CONNECTED,
    DEVICE_TRUST_PAIRING,
    DEVICE_TRUST_AWAITING_CONFIRMATION,
    DEVICE_TRUST_AUTHORIZED,
    DEVICE_TRUST_DENIED,
} device_trust_state_t;

typedef struct {
    device_trust_state_t state;
    uint32_t revision;
    uint32_t numeric_code;
    int pairing_seconds;
    bool pairing_discovery_active;
    bool authorized;
    bool confirmation_pending;
    bool confirmation_retrust;
    uint8_t platform;
    char companion_id[DEVICE_TRUST_ID_MAX + 1];
    char companion_name[DEVICE_TRUST_NAME_MAX + 1];
    char app_version[25];
    char alias[DEVICE_TRUST_ALIAS_MAX + 1];
} device_trust_snapshot_t;

// Register before ble_hub_init(). init() requires NVS to be ready.
void device_trust_init(void);
void device_trust_register(void);
void device_trust_configure_host(void);

// ble_hub forwards GAP events here before notifying feature observers.
int device_trust_gap_event(struct ble_gap_event *event);

bool device_trust_is_authorized(void);
bool device_trust_is_authorized_conn(uint16_t conn_handle);
bool device_trust_authorized_link(uint16_t *conn_handle, uint32_t *generation);
bool device_trust_authorized_link_matches(uint16_t conn_handle, uint32_t generation);

void device_trust_tick(void);
void device_trust_snapshot(device_trust_snapshot_t *out);
void device_trust_confirm_pairing(bool accept);

int device_trust_count(void);
bool device_trust_companion(int index, char *id, size_t id_size,
                            char *name, size_t name_size, uint8_t *platform);

bool device_trust_open_pairing_window(void);
// Ask the authorized companion to stop reconnecting, then asynchronously
// terminate GAP. Trust metadata and the NimBLE bond remain intact; selecting a
// trusted companion or opening pairing clears the RAM-only disconnect fence.
bool device_trust_disconnect_current(void);
bool device_trust_set_alias(const char *alias);
bool device_trust_forget(int index);
bool device_trust_forget_all(void);
bool device_trust_handoff(int index);
