/*
  Copyright (c) 2010-2023, Intel Corporation

  SPDX-License-Identifier: BSD-3-Clause
*/

#include <stdio.h>
#include <stdlib.h>
#include <chrono>
#include <vector>
#include <iostream>
#include <iomanip>

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
    
    // Timing arrays for first call
    std::vector<int64_t> lane_start_1(N);
    std::vector<int64_t> lane_end_1(N);
    int64_t global_start_1 = 0;
    
    auto start_1 = std::chrono::high_resolution_clock::now();
    ispc::concat_batch(map, HOSTNAME, tokens_buf, offsets, N, out_buf,
                       lane_start_1.data(), lane_end_1.data(), global_start_1);
    auto end_1 = std::chrono::high_resolution_clock::now();
    
    auto duration_1 = std::chrono::duration_cast<std::chrono::microseconds>(end_1 - start_1);
    printf("Batch completed in %ld µs\n", duration_1.count());

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

    // Timing arrays for second call
    std::vector<int64_t> lane_start_2(N);
    std::vector<int64_t> lane_end_2(N);
    int64_t global_start_2 = 0;
    
    auto start_2 = std::chrono::high_resolution_clock::now();
    ispc::concat_batch(map, HOSTNAME, tokens_buf, offsets, N, out_buf,
                       lane_start_2.data(), lane_end_2.data(), global_start_2);
    auto end_2 = std::chrono::high_resolution_clock::now();
    
    auto duration_2 = std::chrono::duration_cast<std::chrono::microseconds>(end_2 - start_2);
    printf("Batch completed in %ld µs\n", duration_2.count());

    for (int i = 0; i < N; ++i)
        printf("Lane %d → %s\n", i, &out_buf[i * MAX_LEN]);

    printf("\nMap after second round (count=%d):\n", map.count);
    for (int i = 0; i < map.count; ++i)
        printf("[%02d] %s → %s\n", i, map.longURLs[i], map.shortURLs[i]);

    // ------------------------------------------------------------------
    // TIMING ANALYSIS - First concat_batch
    // ------------------------------------------------------------------
    std::cout << "\n╔══════════════════════════════════════════════════════════════════╗\n";
    std::cout << "║       TIMING ANALYSIS - First concat_batch (N=" << N << ")              ║\n";
    std::cout << "╚══════════════════════════════════════════════════════════════════╝\n\n";
    
    std::cout << "Per-Lane Timing (cycles):\n";
    std::cout << "Lane | URL          | Queue Delay | Exec Time  | Total Latency\n";
    std::cout << "-----+--------------+-------------+------------+--------------\n";
    
    for (int i = 0; i < N; i++) {
        int64_t queue_delay = lane_start_1[i] - global_start_1;
        int64_t exec_time = lane_end_1[i] - lane_start_1[i];
        int64_t total_latency = lane_end_1[i] - global_start_1;
        
        std::cout << std::setw(4) << i << " | "
                  << std::setw(12) << &tokens_buf[i * MAX_LEN] << " | "
                  << std::setw(11) << queue_delay << " | "
                  << std::setw(10) << exec_time << " | "
                  << std::setw(12) << total_latency << "\n";
    }
    
    // ------------------------------------------------------------------
    // TIMING ANALYSIS - Second concat_batch
    // ------------------------------------------------------------------
    std::cout << "\n╔══════════════════════════════════════════════════════════════════╗\n";
    std::cout << "║       TIMING ANALYSIS - Second concat_batch (N=" << N << ")             ║\n";
    std::cout << "╚══════════════════════════════════════════════════════════════════╝\n\n";
    
    std::cout << "Per-Lane Timing (cycles):\n";
    std::cout << "Lane | URL          | Queue Delay | Exec Time  | Total Latency | Cache Hit?\n";
    std::cout << "-----+--------------+-------------+------------+---------------+-----------\n";
    
    for (int i = 0; i < N; i++) {
        int64_t queue_delay = lane_start_2[i] - global_start_2;
        int64_t exec_time = lane_end_2[i] - lane_start_2[i];
        int64_t total_latency = lane_end_2[i] - global_start_2;
        
        // Determine if it's a cache hit (comparing with round 1)
        bool is_cached = (strcmp(tokens2[i], "aadasdas") == 0 || 
                         strcmp(tokens2[i], "bbb") == 0 || 
                         strcmp(tokens2[i], "ddd") == 0);
        
        std::cout << std::setw(4) << i << " | "
                  << std::setw(12) << tokens2[i] << " | "
                  << std::setw(11) << queue_delay << " | "
                  << std::setw(10) << exec_time << " | "
                  << std::setw(13) << total_latency << " | "
                  << (is_cached ? "✅ HIT " : "❌ MISS") << "\n";
    }
    
    // Cache hit analysis
    int64_t cached_avg = 0, uncached_avg = 0;
    int cached_count = 0, uncached_count = 0;
    
    for (int i = 0; i < N; i++) {
        bool is_cached = (strcmp(tokens2[i], "aadasdas") == 0 || 
                         strcmp(tokens2[i], "bbb") == 0 || 
                         strcmp(tokens2[i], "ddd") == 0);
        int64_t exec_time = lane_end_2[i] - lane_start_2[i];
        
        if (is_cached) {
            cached_avg += exec_time;
            cached_count++;
        } else {
            uncached_avg += exec_time;
            uncached_count++;
        }
    }
    
    if (cached_count > 0 && uncached_count > 0) {
        cached_avg /= cached_count;
        uncached_avg /= uncached_count;
        
        std::cout << "\n🔥 Cache Hit Performance:\n";
        std::cout << "   Cache HIT avg execution: " << cached_avg << " cycles\n";
        std::cout << "   Cache MISS avg execution: " << uncached_avg << " cycles\n";
        double speedup = (double)uncached_avg / cached_avg;
        std::cout << "   Speedup with cache: " << std::fixed << std::setprecision(2) 
                  << speedup << "x\n";
    }

    return 0;
}