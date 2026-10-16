// main/ib_adpcm.c: 标准 IMA ADPCM(与 WAV 格式 0x11 同一量化算法)。
#include "ib_adpcm.h"

static const int8_t INDEX_ADJUST[16] = { -1, -1, -1, -1, 2, 4, 6, 8, -1, -1, -1, -1, 2, 4, 6, 8 };

static const int16_t STEP_SIZES[89] = {
    7, 8, 9, 10, 11, 12, 13, 14, 16, 17, 19, 21, 23, 25, 28, 31, 34, 37, 41, 45,
    50, 55, 60, 66, 73, 80, 88, 97, 107, 118, 130, 143, 157, 173, 190, 209, 230, 253, 279, 307,
    337, 371, 408, 449, 494, 544, 598, 658, 724, 796, 876, 963, 1060, 1166, 1282, 1411, 1552, 1707, 1878, 2066,
    2272, 2499, 2749, 3024, 3327, 3660, 4026, 4428, 4871, 5358, 5894, 6484, 7132, 7845, 8630, 9493, 10442, 11487,
    12635, 13899, 15289, 16818, 18500, 20350, 22385, 24623, 27086, 29794, 32767,
};

static int16_t sat16(int32_t v)
{
    if (v > 32767) return 32767;
    if (v < -32768) return -32768;
    return (int16_t)v;
}

static uint8_t sat_index(int v)
{
    if (v < 0) return 0;
    if (v > 88) return 88;
    return (uint8_t)v;
}

void ib_adpcm_init(ib_adpcm_state_t *st)
{
    st->predictor = 0;
    st->index = 0;
}

uint8_t ib_adpcm_encode_sample(ib_adpcm_state_t *st, int16_t sample)
{
    int32_t step = STEP_SIZES[st->index];
    int32_t diff = (int32_t)sample - st->predictor;
    uint8_t code = 0;
    if (diff < 0) {
        code = 8;
        diff = -diff;
    }
    int32_t delta = step >> 3;
    if (diff >= step) {
        code |= 4;
        diff -= step;
        delta += step;
    }
    step >>= 1;
    if (diff >= step) {
        code |= 2;
        diff -= step;
        delta += step;
    }
    step >>= 1;
    if (diff >= step) {
        code |= 1;
        delta += step;
    }
    st->predictor = sat16((code & 8) ? (int32_t)st->predictor - delta : (int32_t)st->predictor + delta);
    st->index = sat_index((int)st->index + INDEX_ADJUST[code]);
    return code;
}

int16_t ib_adpcm_decode_sample(ib_adpcm_state_t *st, uint8_t nibble)
{
    nibble &= 0x0F;
    int32_t step = STEP_SIZES[st->index];
    int32_t delta = step >> 3;
    if (nibble & 4) delta += step;
    if (nibble & 2) delta += step >> 1;
    if (nibble & 1) delta += step >> 2;
    st->predictor = sat16((nibble & 8) ? (int32_t)st->predictor - delta : (int32_t)st->predictor + delta);
    st->index = sat_index((int)st->index + INDEX_ADJUST[nibble]);
    return st->predictor;
}

void ib_adpcm_encode_block(ib_adpcm_state_t *st, const int16_t *pcm, uint8_t out[IB_ADPCM_BLOCK_BYTES])
{
    uint16_t pred = (uint16_t)st->predictor;
    out[0] = (uint8_t)(pred & 0xFF);
    out[1] = (uint8_t)(pred >> 8);
    out[2] = st->index;
    out[3] = 0;
    for (int i = 0; i < IB_ADPCM_BLOCK_SAMPLES; i += 2) {
        uint8_t lo = ib_adpcm_encode_sample(st, pcm[i]);
        uint8_t hi = ib_adpcm_encode_sample(st, pcm[i + 1]);
        out[4 + i / 2] = (uint8_t)(lo | (hi << 4));
    }
}

void ib_adpcm_decode_block(const uint8_t in[IB_ADPCM_BLOCK_BYTES], int16_t *pcm)
{
    ib_adpcm_state_t st = {
        .predictor = (int16_t)((uint16_t)in[0] | ((uint16_t)in[1] << 8)),
        .index = sat_index(in[2]),
    };
    for (int i = 0; i < IB_ADPCM_BLOCK_SAMPLES; i += 2) {
        uint8_t b = in[4 + i / 2];
        pcm[i] = ib_adpcm_decode_sample(&st, b & 0x0F);
        pcm[i + 1] = ib_adpcm_decode_sample(&st, b >> 4);
    }
}
