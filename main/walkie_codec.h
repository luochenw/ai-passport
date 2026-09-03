#pragma once

#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

// Low-latency walkie-talkie audio frames shared by BLE and the local relay.
//
// Audio is 8 kHz, signed 16-bit mono PCM. Each frame is independently encoded
// with IMA ADPCM so a dropped BLE or WebSocket packet does not corrupt every
// later frame in the same transmission.
#define WALKIE_AUDIO_SAMPLE_RATE       8000
#define WALKIE_AUDIO_FRAME_SAMPLES      160
#define WALKIE_AUDIO_FRAME_MS            20
#define WALKIE_AUDIO_FRAME_HEADER_SIZE   12
#define WALKIE_AUDIO_FRAME_DATA_SIZE     80
#define WALKIE_AUDIO_FRAME_MAX_SIZE      92
#define WALKIE_AUDIO_PROTOCOL_VERSION     1

#define WALKIE_AUDIO_FLAG_START 0x01
#define WALKIE_AUDIO_FLAG_END   0x02

typedef struct {
    uint8_t flags;
    uint16_t stream_id;
    uint16_t sequence;
    uint16_t sample_count;
} walkie_audio_frame_info_t;

// Encodes one independent PCM frame. A zero-sample frame is valid and is used
// for an END marker. Returns the encoded byte count, or 0 for invalid input.
size_t walkie_audio_frame_encode(uint16_t stream_id,
                                 uint16_t sequence,
                                 uint8_t flags,
                                 const int16_t *pcm,
                                 uint16_t sample_count,
                                 uint8_t *out,
                                 size_t out_capacity);

// Validates and decodes one frame. `pcm` may be NULL when the caller only needs
// metadata validation. Returns false for malformed or unsupported input.
bool walkie_audio_frame_decode(const uint8_t *frame,
                               size_t frame_len,
                               walkie_audio_frame_info_t *info,
                               int16_t *pcm,
                               size_t pcm_capacity,
                               size_t *sample_count);
