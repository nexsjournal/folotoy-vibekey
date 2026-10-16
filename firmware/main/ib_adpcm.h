// main/ib_adpcm.h: IMA ADPCM(4 bit)编码,用于麦克风上行。
// 纯 C,不依赖 ESP-IDF,由 tests/test_ib_adpcm.c 在主机上测试。
//
// 块格式(164 字节,自包含,丢一块不影响后面):
//   [0..1] int16 LE  本块第一个样本编码前的预测值
//   [2]    uint8     步长索引 0..88
//   [3]    uint8     保留,恒为 0
//   [4..163] 320 个 4 bit 码,每字节低半字节在前(先样本 2n,后样本 2n+1)
// 16 kHz 单声道下一块 = 20 ms。
#pragma once

#include <stddef.h>
#include <stdint.h>

#define IB_ADPCM_BLOCK_SAMPLES 320
#define IB_ADPCM_BLOCK_BYTES   164

typedef struct {
    int16_t predictor;
    uint8_t index;
} ib_adpcm_state_t;

void ib_adpcm_init(ib_adpcm_state_t *st);
uint8_t ib_adpcm_encode_sample(ib_adpcm_state_t *st, int16_t sample);
int16_t ib_adpcm_decode_sample(ib_adpcm_state_t *st, uint8_t nibble);
// 编码恰好 IB_ADPCM_BLOCK_SAMPLES 个样本:先用当前状态写块头,再编码;状态跨块延续。
void ib_adpcm_encode_block(ib_adpcm_state_t *st, const int16_t *pcm, uint8_t out[IB_ADPCM_BLOCK_BYTES]);
// 解码一块(状态从块头恢复)。设备上不用,供测试与参考实现。
void ib_adpcm_decode_block(const uint8_t in[IB_ADPCM_BLOCK_BYTES], int16_t *pcm);
