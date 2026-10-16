// tests/test_ib_adpcm.c: ib_adpcm 主机测试(编码→解码误差、块头、跨块状态)。
#include "ib_adpcm.h"
#include "test_common.h"

#include <math.h>
#include <stdlib.h>

#ifndef M_PI
#define M_PI 3.14159265358979323846
#endif

int main(void)
{
    enum { BLOCKS = 10, N = IB_ADPCM_BLOCK_SAMPLES * BLOCKS };
    static int16_t pcm[N];
    static int16_t dec[N];
    static uint8_t blk[BLOCKS][IB_ADPCM_BLOCK_BYTES];

    // 440 Hz + 1500 Hz 混合正弦,16 kHz。
    for (int i = 0; i < N; i++) {
        double t = (double)i / 16000.0;
        pcm[i] = (int16_t)(9000.0 * sin(2 * M_PI * 440 * t) + 4000.0 * sin(2 * M_PI * 1500 * t));
    }

    ib_adpcm_state_t st;
    ib_adpcm_init(&st);
    for (int b = 0; b < BLOCKS; b++) {
        ib_adpcm_state_t before = st;
        ib_adpcm_encode_block(&st, pcm + b * IB_ADPCM_BLOCK_SAMPLES, blk[b]);
        int16_t pred = (int16_t)(blk[b][0] | (blk[b][1] << 8));
        CHECK(pred == before.predictor);
        CHECK(blk[b][2] == before.index);
        CHECK(blk[b][3] == 0);
    }
    // 每块独立解码(乱序也可以)。
    for (int b = BLOCKS - 1; b >= 0; b--) ib_adpcm_decode_block(blk[b], dec + b * IB_ADPCM_BLOCK_SAMPLES);

    // 首块从 index 0 起步需要几十个样本收敛,之后信噪比应 > 20 dB。
    double sig = 0, err = 0;
    for (int i = 200; i < N; i++) {
        sig += (double)pcm[i] * pcm[i];
        double e = (double)pcm[i] - dec[i];
        err += e * e;
    }
    double snr = 10.0 * log10(sig / err);
    CHECK(snr > 20.0);

    // 编码器与解码器逐样本状态一致。
    ib_adpcm_state_t enc, de;
    ib_adpcm_init(&enc);
    ib_adpcm_init(&de);
    for (int i = 0; i < 2000; i++) {
        int16_t s = (int16_t)((rand() % 65536) - 32768);
        uint8_t code = ib_adpcm_encode_sample(&enc, s);
        CHECK(code < 16);
        int16_t out = ib_adpcm_decode_sample(&de, code);
        CHECK(out == enc.predictor && de.index == enc.index);
    }

    // 低半字节在前:编码 [大正, 大负] 的第一个码在低 4 位。
    ib_adpcm_init(&st);
    int16_t two[IB_ADPCM_BLOCK_SAMPLES] = { 0 };
    two[0] = 30000;
    two[1] = -30000;
    uint8_t one[IB_ADPCM_BLOCK_BYTES];
    ib_adpcm_encode_block(&st, two, one);
    CHECK((one[4] & 0x08) == 0);          // 第 0 个样本为正
    CHECK((one[4] & 0x80) != 0);          // 第 1 个样本为负

    printf("snr=%.1f dB\n", snr);
    TEST_DONE("test_ib_adpcm");
}
