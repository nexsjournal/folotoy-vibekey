#include "ib_base64.h"

static int b64_value(char ch)
{
    if (ch >= 'A' && ch <= 'Z') return ch - 'A';
    if (ch >= 'a' && ch <= 'z') return ch - 'a' + 26;
    if (ch >= '0' && ch <= '9') return ch - '0' + 52;
    if (ch == '+') return 62;
    if (ch == '/') return 63;
    return -1;
}

int ib_base64_decode(const char *in, size_t len, uint8_t *out, size_t cap)
{
    if (!in || !out || len == 0 || len % 4 != 0) return -1;

    uint32_t acc = 0;
    int bits = 0;
    size_t n = 0;
    bool padding = false;
    for (size_t i = 0; i < len; i++) {
        char ch = in[i];
        if (ch == '=') {
            padding = true;
            continue;
        }
        if (padding) return -1;
        int v = b64_value(ch);
        if (v < 0) return -1;
        acc = (acc << 6) | (uint32_t)v;
        bits += 6;
        if (bits >= 8) {
            bits -= 8;
            if (n >= cap) return -1;
            out[n++] = (uint8_t)((acc >> bits) & 0xFF);
        }
    }
    return (int)n;
}
