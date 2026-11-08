// tests/test_ib_wallpaper.c: Base64 与 CRC32 主机测试(不依赖 ESP-IDF)。
#include "ib_base64.h"
#include "ib_crc32.h"
#include "test_common.h"

#include <string.h>

static void test_crc32(void)
{
    CHECK(ib_crc32("123456789", 9) == 0xCBF43926U);
    CHECK(ib_crc32("", 0) == 0x00000000U);
    // 增量拼接与一次性计算结果一致。
    uint32_t crc = ib_crc32_update(0, "1234", 4);
    crc = ib_crc32_update(crc, "56789", 5);
    CHECK(crc == 0xCBF43926U);
}

static void test_base64(void)
{
    uint8_t out[16];
    CHECK(ib_base64_decode("TWFu", 4, out, sizeof(out)) == 3);
    CHECK(memcmp(out, "Man", 3) == 0);
    CHECK(ib_base64_decode("TWE=", 4, out, sizeof(out)) == 2);
    CHECK(memcmp(out, "Ma", 2) == 0);
    CHECK(ib_base64_decode("TQ==", 4, out, sizeof(out)) == 1);
    CHECK(out[0] == 'M');
    CHECK(ib_base64_decode("TWFu", 3, out, sizeof(out)) == -1);
    CHECK(ib_base64_decode("TW$u", 4, out, sizeof(out)) == -1);
    CHECK(ib_base64_decode("TWFu", 4, out, 2) == -1);
    CHECK(ib_base64_decode("", 0, out, sizeof(out)) == -1);

    // 288 字节是实际分块大小,编码后正好 384 字符。
    char encoded[385];
    static const char alphabet[] = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
    for (int i = 0; i < 384; i++) encoded[i] = alphabet[i % 64];
    encoded[384] = '\0';
    uint8_t chunk[288];
    CHECK(ib_base64_decode(encoded, 384, chunk, sizeof(chunk)) == 288);
}

int main(void)
{
    test_crc32();
    test_base64();
    TEST_DONE("test_ib_wallpaper");
}
