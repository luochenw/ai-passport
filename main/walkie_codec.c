#include "walkie_codec.h"

#include <string.h>

static const int16_t STEP_TABLE[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31,
    34, 37, 41, 45, 50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143,
    157, 173, 190, 209, 230, 253, 279, 307, 337, 371, 408, 449, 494, 544,
    598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707,
    1878, 2066, 2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871,
    5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487, 12635,
    13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
};

static const int8_t INDEX_TABLE[16] = {
    -1, -1, -1, -1, 2, 4, 6, 8,
    -1, -1, -1, -1, 2, 4, 6, 8,
};

typedef struct {
    int predictor;
    int step_index;
} adpcm_state_t;

static uint16_t read_u16_le(const uint8_t *p)
{
    return (uint16_t)p[0] | ((uint16_t)p[1] << 8);
}

static void write_u16_le(uint8_t *p, uint16_t value)
{
    p[0] = (uint8_t)(value & 0xff);
    p[1] = (uint8_t)(value >> 8);
}

static uint8_t encode_sample(adpcm_state_t *state, int16_t sample)
{
    int step = STEP_TABLE[state->step_index];
    int diff = (int)sample - state->predictor;
    uint8_t code = 0;
    if (diff < 0) {
        code = 8;
        diff = -diff;
    }

    int delta = step >> 3;
    if (diff >= step) {
        code |= 4;
        diff -= step;
        delta += step;
    }
    if (diff >= (step >> 1)) {
        code |= 2;
        diff -= step >> 1;
        delta += step >> 1;
    }
    if (diff >= (step >> 2)) {
        code |= 1;
        delta += step >> 2;
    }

    state->predictor += (code & 8) ? -delta : delta;
    if (state->predictor > 32767) state->predictor = 32767;
    if (state->predictor < -32768) state->predictor = -32768;

    state->step_index += INDEX_TABLE[code];
    if (state->step_index < 0) state->step_index = 0;
    if (state->step_index > 88) state->step_index = 88;
    return code;
}

static int16_t decode_sample(adpcm_state_t *state, uint8_t code)
{
    int step = STEP_TABLE[state->step_index];
    int delta = step >> 3;
    if (code & 4) delta += step;
    if (code & 2) delta += step >> 1;
    if (code & 1) delta += step >> 2;

    state->predictor += (code & 8) ? -delta : delta;
    if (state->predictor > 32767) state->predictor = 32767;
    if (state->predictor < -32768) state->predictor = -32768;

    state->step_index += INDEX_TABLE[code & 0x0f];
    if (state->step_index < 0) state->step_index = 0;
    if (state->step_index > 88) state->step_index = 88;
    return (int16_t)state->predictor;
}

size_t walkie_audio_frame_encode(uint16_t stream_id,
                                 uint16_t sequence,
                                 uint8_t flags,
                                 const int16_t *pcm,
                                 uint16_t sample_count,
                                 uint8_t *out,
                                 size_t out_capacity)
{
    if (!out || sample_count > WALKIE_AUDIO_FRAME_SAMPLES) return 0;
    if (sample_count > 0 && !pcm) return 0;

    size_t payload_len = sample_count > 0 ? (size_t)sample_count / 2 : 0;
    size_t frame_len = WALKIE_AUDIO_FRAME_HEADER_SIZE + payload_len;
    if (out_capacity < frame_len) return 0;

    memset(out, 0, WALKIE_AUDIO_FRAME_HEADER_SIZE);
    out[0] = WALKIE_AUDIO_PROTOCOL_VERSION;
    out[1] = flags;
    write_u16_le(out + 2, stream_id);
    write_u16_le(out + 4, sequence);
    write_u16_le(out + 6, sample_count);

    if (sample_count == 0) return frame_len;

    int16_t predictor = pcm[0];
    write_u16_le(out + 8, (uint16_t)predictor);
    out[10] = 0;

    adpcm_state_t state = {
        .predictor = predictor,
        .step_index = 0,
    };
    size_t dst = WALKIE_AUDIO_FRAME_HEADER_SIZE;
    uint8_t packed = 0;
    bool low_nibble = true;
    for (uint16_t i = 1; i < sample_count; i++) {
        uint8_t code = encode_sample(&state, pcm[i]);
        if (low_nibble) {
            packed = code;
            low_nibble = false;
        } else {
            out[dst++] = packed | (uint8_t)(code << 4);
            low_nibble = true;
        }
    }
    if (!low_nibble) out[dst++] = packed;
    return dst;
}

bool walkie_audio_frame_decode(const uint8_t *frame,
                               size_t frame_len,
                               walkie_audio_frame_info_t *info,
                               int16_t *pcm,
                               size_t pcm_capacity,
                               size_t *sample_count)
{
    if (!frame || frame_len < WALKIE_AUDIO_FRAME_HEADER_SIZE) return false;
    if (frame[0] != WALKIE_AUDIO_PROTOCOL_VERSION) return false;

    uint16_t samples = read_u16_le(frame + 6);
    if (samples > WALKIE_AUDIO_FRAME_SAMPLES) return false;
    size_t payload_len = samples > 0 ? (size_t)samples / 2 : 0;
    if (frame_len != WALKIE_AUDIO_FRAME_HEADER_SIZE + payload_len) return false;
    if (pcm && pcm_capacity < samples) return false;

    if (info) {
        info->flags = frame[1];
        info->stream_id = read_u16_le(frame + 2);
        info->sequence = read_u16_le(frame + 4);
        info->sample_count = samples;
    }
    if (sample_count) *sample_count = samples;
    if (!pcm || samples == 0) return true;

    adpcm_state_t state = {
        .predictor = (int16_t)read_u16_le(frame + 8),
        .step_index = frame[10],
    };
    if (state.step_index > 88) return false;

    pcm[0] = (int16_t)state.predictor;
    size_t src = WALKIE_AUDIO_FRAME_HEADER_SIZE;
    for (uint16_t i = 1; i < samples; i++) {
        uint8_t byte = frame[src + (i - 1) / 2];
        uint8_t code = ((i - 1) & 1) ? (byte >> 4) : (byte & 0x0f);
        pcm[i] = decode_sample(&state, code);
    }
    return true;
}
