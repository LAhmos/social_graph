/*
  Copyright (c) 2010-2023, Intel Corporation

  SPDX-License-Identifier: BSD-3-Clause
*/

#include <stdio.h>
#include <stdlib.h>

// Include the header file that the ispc compiler generates
#include "simple_ispc.h"
using namespace ispc;
#include <cstdio>
#include <cstdio>
#include <cstdint>

#include <cstdio>
#include <cstring>
#include <cstdint>
#define MAX_LEN 128

int main() {

    // Initialize persistent map
    URLMap map{};
    uint8_t HOSTNAME[] = "https://sho.rt/";

    // Prepare tokens
    char *tokens[] = {"aadasdas", "bbb", "ccc", "ddd"};
    const int N = 4;

    // Pack tokens into flat buffer
    uint8_t tokens_buf[N * MAX_LEN] = {0};
    int offsets[N];
    for (int i = 0; i < N; ++i) {
        offsets[i] = i * MAX_LEN;
        strcpy((char*)&tokens_buf[i * MAX_LEN], tokens[i]);
    }

    // Output buffer
    uint8_t out_buf[N * MAX_LEN] = {0};

    // ---------- First round ----------
    printf("\n=== Round 1: first call ===\n");
    ispc::concat_batch(map, HOSTNAME, tokens_buf, offsets, N, out_buf);

    for (int i = 0; i < N; ++i)
        printf("Lane %d → %s\n", i, &out_buf[i * MAX_LEN]);

    printf("\nMap after first round (count=%d):\n", map.count);
    for (int i = 0; i < map.count; ++i)
        printf("[%02d] %s → %s\n", i, map.longURLs[i], map.shortURLs[i]);


    // ---------- Second round ----------
    printf("\n=== Round 2: reuse map, add new tokens ===\n");
    // Replace a few tokens: reuse some, add new
    char *tokens2[] = {"aadasdas", "bbb", "newurl", "ddd"};
    for (int i = 0; i < N; ++i)
        strcpy((char*)&tokens_buf[i * MAX_LEN], tokens2[i]);
    memset(out_buf, 0, sizeof(out_buf));

    ispc::concat_batch(map, HOSTNAME, tokens_buf, offsets, N, out_buf);

    for (int i = 0; i < N; ++i)
        printf("Lane %d → %s\n", i, &out_buf[i * MAX_LEN]);

    printf("\nMap after second round (count=%d):\n", map.count);
    for (int i = 0; i < map.count; ++i)
        printf("[%02d] %s → %s\n", i, map.longURLs[i], map.shortURLs[i]);

    return 0;
}