// tests/test_common.h: 主机测试用的极简断言。
#pragma once

#include <stdio.h>
#include <string.h>

static int s_failures;

#define CHECK(cond)                                                                   \
    do {                                                                              \
        if (!(cond)) {                                                                \
            fprintf(stderr, "%s:%d: CHECK failed: %s\n", __FILE__, __LINE__, #cond);  \
            s_failures++;                                                             \
        }                                                                             \
    } while (0)

#define CHECK_STR(actual, expected)                                                   \
    do {                                                                              \
        const char *a_ = (actual);                                                    \
        const char *e_ = (expected);                                                  \
        if (strcmp(a_, e_) != 0) {                                                    \
            fprintf(stderr, "%s:%d: expected \"%s\", got \"%s\"\n", __FILE__, __LINE__, e_, a_); \
            s_failures++;                                                             \
        }                                                                             \
    } while (0)

#define TEST_DONE(name)                                                               \
    do {                                                                              \
        if (s_failures) {                                                             \
            fprintf(stderr, "%s: %d failure(s)\n", name, s_failures);                 \
            return 1;                                                                 \
        }                                                                             \
        printf("%s: PASS\n", name);                                                   \
        return 0;                                                                     \
    } while (0)
