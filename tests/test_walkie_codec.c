#include "walkie_codec.h"

#include <assert.h>
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>

static void test_round_trip(void)
{
    int16_t input[WALKIE_AUDIO_FRAME_SAMPLES];
    for (int i = 0; i < WALKIE_AUDIO_FRAME_SAMPLES; i++) {
        input[i] = (int16_t)(((i * 997) % 12000) - 6000);
    }

    uint8_t encoded[WALKIE_AUDIO_FRAME_MAX_SIZE];
    size_t encoded_len = walkie_audio_frame_encode(
        0x1234, 7, WALKIE_AUDIO_FLAG_START,
        input, WALKIE_AUDIO_FRAME_SAMPLES, encoded, sizeof(encoded));
    assert(encoded_len == WALKIE_AUDIO_FRAME_MAX_SIZE);

    int16_t output[WALKIE_AUDIO_FRAME_SAMPLES];
    walkie_audio_frame_info_t info;
    size_t samples = 0;
    assert(walkie_audio_frame_decode(encoded, encoded_len, &info,
                                     output, WALKIE_AUDIO_FRAME_SAMPLES, &samples));
    assert(info.stream_id == 0x1234);
    assert(info.sequence == 7);
    assert(info.flags == WALKIE_AUDIO_FLAG_START);
    assert(samples == WALKIE_AUDIO_FRAME_SAMPLES);
    assert(output[0] == input[0]);

    long long total_error = 0;
    for (size_t i = 0; i < samples; i++) {
        total_error += llabs((long long)input[i] - output[i]);
    }
    assert(total_error / (long long)samples < 2500);
}

static void test_end_marker(void)
{
    uint8_t encoded[WALKIE_AUDIO_FRAME_MAX_SIZE];
    size_t len = walkie_audio_frame_encode(
        9, 44, WALKIE_AUDIO_FLAG_END, NULL, 0, encoded, sizeof(encoded));
    assert(len == WALKIE_AUDIO_FRAME_HEADER_SIZE);

    walkie_audio_frame_info_t info;
    size_t samples = 123;
    assert(walkie_audio_frame_decode(encoded, len, &info, NULL, 0, &samples));
    assert(samples == 0);
    assert(info.flags == WALKIE_AUDIO_FLAG_END);
    assert(info.stream_id == 9);
    assert(info.sequence == 44);
}

static void test_rejects_malformed_frames(void)
{
    uint8_t frame[WALKIE_AUDIO_FRAME_MAX_SIZE] = { 0 };
    assert(!walkie_audio_frame_decode(frame, sizeof(frame), NULL, NULL, 0, NULL));

    frame[0] = WALKIE_AUDIO_PROTOCOL_VERSION;
    frame[6] = 160;
    assert(!walkie_audio_frame_decode(frame, WALKIE_AUDIO_FRAME_HEADER_SIZE,
                                      NULL, NULL, 0, NULL));
}

int main(void)
{
    test_round_trip();
    test_end_marker();
    test_rejects_malformed_frames();
    puts("walkie codec: PASS");
    return 0;
}
