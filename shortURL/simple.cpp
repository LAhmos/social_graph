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
#include <algorithm>

// Include the header file that the ispc compiler generates
#include "simple_ispc.h"
// Include the multithreaded version
#include "simple_mt.h"
using namespace ispc;
#include <cstdio>
#include <cstdio>
#include <cstdint>

#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cmath>
#include <sstream>
#include <iomanip>
#include <atomic>
#define MAX_LEN 128

// Better rdtsc WITHOUT serialization (removed CPUID to allow parallel execution)
static inline uint64_t rdtsc_start() {
    unsigned cycles_low, cycles_high;
    asm volatile (
        "RDTSC\n\t"
        "mov %%edx, %0\n\t"
        "mov %%eax, %1\n\t"
        : "=r" (cycles_high), "=r" (cycles_low)
        :: "%rax", "%rdx");
    return ((uint64_t)cycles_high << 32) | cycles_low;
}

static inline uint64_t rdtsc_end() {
    unsigned cycles_low, cycles_high;
    asm volatile(
        "RDTSCP\n\t"
        "mov %%edx, %0\n\t"
        "mov %%eax, %1\n\t"
        : "=r" (cycles_high), "=r" (cycles_low)
        :: "%rax", "%rcx", "%rdx");
    return ((uint64_t)cycles_high << 32) | cycles_low;
}

// Statistical analysis
struct BenchStats {
    double min, max, median, mean, stddev, cv;
    int num_outliers;
    std::vector<int64_t> all_measurements;
};

BenchStats analyze_measurements(std::vector<int64_t> measurements) {
    BenchStats stats;
    stats.all_measurements = measurements;
    
    if (measurements.empty()) {
        return stats;
    }
    
    // Sort for median
    std::sort(measurements.begin(), measurements.end());
    
    stats.min = measurements.front();
    stats.max = measurements.back();
    stats.median = measurements[measurements.size() / 2];
    
    // Calculate mean
    double sum = 0;
    for (auto m : measurements) {
        sum += m;
    }
    stats.mean = sum / measurements.size();
    
    // Calculate standard deviation
    double sq_sum = 0;
    for (auto m : measurements) {
        sq_sum += (m - stats.mean) * (m - stats.mean);
    }
    stats.stddev = std::sqrt(sq_sum / measurements.size());
    
    // Coefficient of variation (%)
    stats.cv = (stats.stddev / stats.mean) * 100.0;
    
    // Count outliers (> 2 stddev from mean)
    stats.num_outliers = 0;
    for (auto m : measurements) {
        if (std::abs(m - stats.mean) > 2 * stats.stddev) {
            stats.num_outliers++;
        }
    }
    
    return stats;
}

int main(int argc, char* argv[]) {
    // Parse command-line arguments
    bool use_ispc = true;  // Default to ISPC
    int num_threads = 0;    // 0 means auto-detect for multithreaded
    int N = 4;  // Default batch size
    std::string mt_mode = "pool";  // Default MT mode: "pool" or "spawn"
    int warmup_iters = 5;   // Warm-up iterations
    int bench_iters = 50;   // Benchmark iterations
    
    if (argc > 1) {
        std::string mode_str = argv[1];
        if (mode_str == "mt" || mode_str == "multithreaded") {
            use_ispc = false;
            if (argc > 2) {
                num_threads = std::atoi(argv[2]);
            }
            if (argc > 3) {
                mt_mode = argv[3];
            }
            if (argc > 4) {
                N = std::atoi(argv[4]);
            }
            if (argc > 5) {
                bench_iters = std::atoi(argv[5]);
            }
        } else if (mode_str == "ispc") {
            use_ispc = true;
            if (argc > 2) {
                N = std::atoi(argv[2]);
            }
            if (argc > 3) {
                bench_iters = std::atoi(argv[3]);
            }
        } else {
            std::cerr << "Usage: " << argv[0] << " [ispc|mt] [num_threads] [mt_mode] [batch_size] [iterations]\n";
            std::cerr << "  ispc:         Use ISPC SIMD\n";
            std::cerr << "  mt:           Use multithreaded implementation\n";
            std::cerr << "  num_threads:  Number of threads (only for mt mode, default=auto)\n";
            std::cerr << "  mt_mode:      'pool' or 'spawn' (only for mt mode, default='pool')\n";
            std::cerr << "  batch_size:   Number of URLs to process (default=4)\n";
            std::cerr << "  iterations:   Benchmark iterations (default=50)\n";
            std::cerr << "\nExamples:\n";
            std::cerr << "  " << argv[0] << " ispc 100             # ISPC with 100 URLs, 50 iterations\n";
            std::cerr << "  " << argv[0] << " ispc 100 100         # ISPC with 100 URLs, 100 iterations\n";
            std::cerr << "  " << argv[0] << " mt 8 pool 100        # MT pool, 8 threads, 100 URLs\n";
            std::cerr << "  " << argv[0] << " mt 8 spawn 100 100   # MT spawn, 8 threads, 100 URLs, 100 iterations\n";
            return 1;
        }
    }
    
    // Validate mt_mode
    if (mt_mode != "pool" && mt_mode != "spawn") {
        std::cerr << "Error: mt_mode must be 'pool' or 'spawn'\n";
        return 1;
    }
    
    std::string mode_name = use_ispc ? "ISPC SIMD" : ("Multithreaded (" + mt_mode + ")");
    int padding = 66 - 9 - mode_name.length();
    
    std::cout << "\n╔══════════════════════════════════════════════════════════════════╗\n";
    std::cout << "║  BENCHMARK CONFIGURATION - SHORT URL SERVICE                     ║\n";
    std::cout << "╠══════════════════════════════════════════════════════════════════╣\n";
    std::cout << "║  Mode: " << mode_name << std::string(padding, ' ') << "║\n";
    std::cout << "║  Batch Size: " << N << std::string(52 - std::to_string(N).length(), ' ') << "║\n";
    if (!use_ispc && num_threads > 0) {
        std::cout << "║  Threads: " << num_threads << std::string(55 - std::to_string(num_threads).length(), ' ') << "║\n";
    } else if (!use_ispc) {
        std::cout << "║  Threads: Auto-detect                                          ║\n";
    }
    std::cout << "║  Warmup Iterations: " << warmup_iters << std::string(45 - std::to_string(warmup_iters).length(), ' ') << "║\n";
    std::cout << "║  Benchmark Iterations: " << bench_iters << std::string(42 - std::to_string(bench_iters).length(), ' ') << "║\n";
    std::cout << "╚══════════════════════════════════════════════════════════════════╝\n\n";
    
    // Initialize thread pool for multithreaded mode (BEFORE any timing)
    ThreadPool::Mode pool_mode = (mt_mode == "spawn") ? ThreadPool::SPAWN_MODE : ThreadPool::POOL_MODE;
    if (!use_ispc) {
        std::cout << "🔧 Initializing thread pool with " << (num_threads > 0 ? num_threads : std::thread::hardware_concurrency()) << " threads (" << mt_mode << " mode)...\n";
        mt::InitThreadPool(num_threads, pool_mode);
        std::cout << "✅ Thread pool ready\n\n";
    }

    // Initialize persistent map
    URLMap ispc_map{};
    // Initialize hash table with -1 (empty)
    for (int i = 0; i < 16384; i++) {
        ispc_map.hashTable[i] = -1;
    }
    mt::URLMap mt_map{};
    // Initialize MT hash table with -1 (empty)
    for (int i = 0; i < 16384; i++) {
        mt_map.hashTable[i].store(-1, std::memory_order_relaxed);
    }
    const char* hostname_str = "https://sho.rt/";
    
    // Prepare tokens (generate based on N)
    std::vector<std::string> token_strings;
    std::vector<char*> tokens;
    
    // Reserve space to prevent reallocation (which would invalidate .c_str() pointers)
    token_strings.reserve(N);
    tokens.reserve(N);
    
    // Generate diverse tokens
    for (int i = 0; i < N; i++) {
        std::string token = "url_" + std::to_string(i) + "_" + std::to_string(rand() % 1000);
        token_strings.push_back(token);
        tokens.push_back(const_cast<char*>(token_strings[i].c_str()));
    }

    size_t buf_size = static_cast<size_t>(N) * MAX_LEN;
    size_t hostname_len = strlen(hostname_str);
    
    // ========================================================================
    // PREPARE DATA FOR ISPC (SOA layout)
    // ========================================================================
    // HOSTNAME as uniform array [MAX_LEN] - same for all requests
    uint8_t* HOSTNAME_ISPC = new uint8_t[MAX_LEN]();
    strncpy((char*)HOSTNAME_ISPC, hostname_str, MAX_LEN - 1);
    
    // tokens_buf in SOA layout [MAX_LEN][N]
    uint8_t* tokens_buf_SOA = new uint8_t[buf_size]();
    for (int i = 0; i < N; ++i) {
        size_t token_len = strlen(tokens[i]);
        for (int j = 0; j < MAX_LEN; j++) {
            if (j < token_len) {
                tokens_buf_SOA[j * N + i] = tokens[i][j];  // SOA: [char_pos][request_id]
            } else {
                tokens_buf_SOA[j * N + i] = 0;  // null terminator
            }
        }
    }
    
    // out_buf in SOA layout [MAX_LEN][N]
    uint8_t* out_buf_SOA = new uint8_t[buf_size]();
    
    // ========================================================================
    // PREPARE DATA FOR MT (AoS layout)
    // ========================================================================
    // HOSTNAME in AoS layout (simple string)
    uint8_t* HOSTNAME_AOS = new uint8_t[MAX_LEN]();
    strncpy((char*)HOSTNAME_AOS, hostname_str, MAX_LEN - 1);
    
    // tokens_buf in AoS layout [N][MAX_LEN]
    uint8_t* tokens_buf_AOS = new uint8_t[buf_size]();
    for (int i = 0; i < N; ++i) {
        strncpy((char*)(tokens_buf_AOS + i * MAX_LEN), tokens[i], MAX_LEN - 1);
    }
    
    // out_buf in AoS layout [N][MAX_LEN]
    uint8_t* out_buf_AOS = new uint8_t[buf_size]();
    
    // offsets (kept for compatibility, though not used in SOA)
    int* offsets = new int[N];
    for (int i = 0; i < N; ++i) {
        offsets[i] = i * MAX_LEN;
    }

    // Timing arrays for current iteration
    std::vector<int64_t> lane_start_times(N);
    std::vector<int64_t> lane_end_times(N);
    int64_t global_start_time = 0;
    
    // Accumulators for averaging timing across iterations
    std::vector<double> avg_queue_delay(N, 0.0);
    std::vector<double> avg_exec_time(N, 0.0);
    std::vector<double> avg_total_latency(N, 0.0);
    
    // ========================================================================
    // WARM-UP PHASE
    // ========================================================================
    std::cout << "🔥 Warming up: " << warmup_iters << " iterations...\n";
    for (int w = 0; w < warmup_iters; w++) {
        // Reset maps each iteration to avoid accumulation
        if (use_ispc) {
            ispc_map.count = 0;
            // Reset hash table
            for (int i = 0; i < 16384; i++) {
                ispc_map.hashTable[i] = -1;
            }
            memset(out_buf_SOA, 0, buf_size);
            ispc::concat_batch(ispc_map, HOSTNAME_ISPC, tokens_buf_SOA, offsets, N, out_buf_SOA,
                             lane_start_times.data(), lane_end_times.data(), global_start_time);
        } else {
            mt_map.count.store(0, std::memory_order_relaxed);
            memset(out_buf_AOS, 0, buf_size);
            mt::concat_batch(mt_map, HOSTNAME_AOS, tokens_buf_AOS, offsets, N, out_buf_AOS,
                           lane_start_times.data(), lane_end_times.data(), global_start_time, num_threads);
        }
    }
    std::cout << "✅ Warm-up complete\n\n";

    // ========================================================================
    // BENCHMARK PHASE
    // ========================================================================
    std::cout << "📊 Benchmarking: " << bench_iters << " iterations...\n";
    std::vector<int64_t> cycle_measurements;
    std::vector<int64_t> time_measurements_ns;
    
    // Reset maps before benchmark to get clean final state
    if (use_ispc) {
        ispc_map.count = 0;
        // Reset hash table
        for (int i = 0; i < 16384; i++) {
            ispc_map.hashTable[i] = -1;
        }
    } else {
        mt_map.count.store(0, std::memory_order_relaxed);
    }
    
    for (int iter = 0; iter < bench_iters; iter++) {
        // Cycle measurement with serialization
        uint64_t cycles_start = rdtsc_start();
        
        // Wall-clock time measurement
        auto start = std::chrono::high_resolution_clock::now();
        
        // Call the appropriate implementation based on mode
        if (use_ispc) {
            // memset(out_buf_SOA, 0, buf_size);
            ispc::concat_batch(ispc_map, HOSTNAME_ISPC, tokens_buf_SOA, offsets, N, out_buf_SOA,
                             lane_start_times.data(), lane_end_times.data(), global_start_time);
        } else {
            // memset(out_buf_AOS, 0, buf_size);
            mt::concat_batch(mt_map, HOSTNAME_AOS, tokens_buf_AOS, offsets, N, out_buf_AOS,
                           lane_start_times.data(), lane_end_times.data(), global_start_time, num_threads);
        }
        
        auto end = std::chrono::high_resolution_clock::now();
        uint64_t cycles_end = rdtsc_end();
        
        // Store measurements
        int64_t total_cycles = cycles_end - cycles_start;
        auto duration_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(end - start);
        
        cycle_measurements.push_back(total_cycles);
        time_measurements_ns.push_back(duration_ns.count());
        
        // Accumulate relative timing metrics for this iteration
        for (int i = 0; i < N; i++) {
            int64_t queue_delay = lane_start_times[i] - global_start_time;
            int64_t exec_time = lane_end_times[i] - lane_start_times[i];
            int64_t total_latency = lane_end_times[i] - global_start_time;
            
            avg_queue_delay[i] += queue_delay;
            avg_exec_time[i] += exec_time;
            avg_total_latency[i] += total_latency;
        }
        
        // Progress indicator for long runs
        if (bench_iters >= 20 && (iter + 1) % (bench_iters / 10) == 0) {
            std::cout << "  Progress: " << (iter + 1) << "/" << bench_iters << "\n";
        }
    }
    
    // Calculate averages
    for (int i = 0; i < N; i++) {
        avg_queue_delay[i] /= bench_iters;
        avg_exec_time[i] /= bench_iters;
        avg_total_latency[i] /= bench_iters;
    }
    
    std::cout << "✅ Benchmarking complete\n\n";
    
    // ========================================================================
    // STATISTICAL ANALYSIS
    // ========================================================================
    BenchStats cycle_stats = analyze_measurements(cycle_measurements);
    BenchStats time_stats = analyze_measurements(time_measurements_ns);
    
    // Estimate CPU frequency from median measurements
    double median_wall_time_sec = time_stats.median / 1e9;
    double estimated_freq_ghz = (cycle_stats.median / median_wall_time_sec) / 1e9;
    
    std::cout << "\n╔══════════════════════════════════════════════════════════════════╗\n";
    std::cout << "║  BENCHMARK RESULTS (STATISTICAL ANALYSIS)                        ║\n";
    std::cout << "╚══════════════════════════════════════════════════════════════════╝\n\n";
    
    std::cout << "CYCLE MEASUREMENTS:\n";
    std::cout << "  Min:      " << std::setw(12) << (int64_t)cycle_stats.min << " cycles\n";
    std::cout << "  Median:   " << std::setw(12) << (int64_t)cycle_stats.median << " cycles  ⭐ (most reliable)\n";
    std::cout << "  Mean:     " << std::setw(12) << (int64_t)cycle_stats.mean << " cycles\n";
    std::cout << "  Max:      " << std::setw(12) << (int64_t)cycle_stats.max << " cycles\n";
    std::cout << "  Stddev:   " << std::setw(12) << (int64_t)cycle_stats.stddev << " cycles\n";
    std::cout << "  CV:       " << std::setw(12) << std::fixed << std::setprecision(2) 
              << cycle_stats.cv << " %\n";
    std::cout << "  Outliers: " << std::setw(12) << cycle_stats.num_outliers 
              << " / " << bench_iters << "\n\n";
    
    std::cout << "WALL-CLOCK TIME:\n";
    std::cout << "  Min:      " << std::setw(12) << std::fixed << std::setprecision(2)
              << time_stats.min / 1000.0 << " µs\n";
    std::cout << "  Median:   " << std::setw(12) << std::fixed << std::setprecision(2)
              << time_stats.median / 1000.0 << " µs  ⭐\n";
    std::cout << "  Mean:     " << std::setw(12) << std::fixed << std::setprecision(2)
              << time_stats.mean / 1000.0 << " µs\n";
    std::cout << "  Max:      " << std::setw(12) << std::fixed << std::setprecision(2)
              << time_stats.max / 1000.0 << " µs\n";
    std::cout << "  Stddev:   " << std::setw(12) << std::fixed << std::setprecision(2)
              << time_stats.stddev / 1000.0 << " µs\n";
    std::cout << "  CV:       " << std::setw(12) << std::fixed << std::setprecision(2) 
              << time_stats.cv << " %\n";
    std::cout << "  Outliers: " << std::setw(12) << time_stats.num_outliers 
              << " / " << bench_iters << "\n\n";
    
    std::cout << "PERFORMANCE METRICS (based on median):\n";
    std::cout << "  Estimated CPU freq:   " << std::fixed << std::setprecision(3) 
              << estimated_freq_ghz << " GHz\n";
    std::cout << "  Throughput:           " << std::fixed << std::setprecision(2)
              << (N * 1e9 / time_stats.median) << " URLs/sec\n";
    std::cout << "  Cycles per URL:       " << (int64_t)(cycle_stats.median / N) << " cycles\n";
    std::cout << "  Time per URL:         " << std::fixed << std::setprecision(2)
              << (time_stats.median / (double)N) << " ns\n\n";
    
    // Benchmark quality assessment
    std::cout << "BENCHMARK QUALITY:\n";
    double overall_cv = (cycle_stats.cv + time_stats.cv) / 2.0;
    if (overall_cv < 3.0) {
        std::cout << "  ✅ EXCELLENT (CV < 3%) - Very stable measurements\n";
    } else if (overall_cv < 5.0) {
        std::cout << "  ✅ GOOD (CV < 5%) - Stable measurements\n";
    } else if (overall_cv < 10.0) {
        std::cout << "  ⚠️  MODERATE (CV 5-10%) - Some noise present\n";
        std::cout << "  💡 Tip: Try setting CPU governor to 'performance'\n";
    } else {
        std::cout << "  ❌ NOISY (CV > 10%) - High variation detected!\n";
        std::cout << "  💡 Tips:\n";
        std::cout << "     - Set CPU governor: sudo cpupower frequency-set --governor performance\n";
        std::cout << "     - Close background applications\n";
    }
    std::cout << "\n";

    // Print sample results
    printf("\n=== Sample Generated URLs (first 10 and last 10) ===\n");
    int print_limit = std::min(10, N);
    char temp_url[MAX_LEN];
    
    if (use_ispc) {
        // Reconstruct from SOA format
        for (int i = 0; i < print_limit; ++i) {
            int j;
            for (j = 0; j < MAX_LEN; ++j) {
                temp_url[j] = out_buf_SOA[j * N + i];  // SOA: char_pos * N + request_id
                if (temp_url[j] == 0) break;
            }
            temp_url[j] = 0;
            printf("Lane %d → %s\n", i, temp_url);
        }
        
        if (N > 20) {
            printf("...\n");
            for (int i = N - print_limit; i < N; ++i) {
                int j;
                for (j = 0; j < MAX_LEN; ++j) {
                    temp_url[j] = out_buf_SOA[j * N + i];
                    if (temp_url[j] == 0) break;
                }
                temp_url[j] = 0;
                printf("Lane %d → %s\n", i, temp_url);
            }
        } else if (N > 10) {
            for (int i = print_limit; i < N; ++i) {
                int j;
                for (j = 0; j < MAX_LEN; ++j) {
                    temp_url[j] = out_buf_SOA[j * N + i];
                    if (temp_url[j] == 0) break;
                }
                temp_url[j] = 0;
                printf("Lane %d → %s\n", i, temp_url);
            }
        }
    } else {
        // MT version uses AoS - direct string access
        for (int i = 0; i < print_limit; ++i)
            printf("Lane %d → %s\n", i, &out_buf_AOS[i * MAX_LEN]);
        
        if (N > 20) {
            printf("...\n");
            for (int i = N - print_limit; i < N; ++i)
                printf("Lane %d → %s\n", i, &out_buf_AOS[i * MAX_LEN]);
        } else if (N > 10) {
            for (int i = print_limit; i < N; ++i)
                printf("Lane %d → %s\n", i, &out_buf_AOS[i * MAX_LEN]);
        }
    }

    if (use_ispc) {
        printf("\nMap after processing (count=%d):\n", ispc_map.count);
        // Reconstruct strings from SOA layout for display
        char temp_long[MAX_LEN], temp_short[MAX_LEN];
        for (int i = 0; i < std::min(10, ispc_map.count); ++i) {
            // Extract from SOA: [char_pos][entry_idx]
            int j;
            for (j = 0; j < MAX_LEN; ++j) {
                temp_long[j] = ispc_map.longURLs[j][i];
                if (temp_long[j] == 0) break;
            }
            temp_long[j] = 0;
            
            for (j = 0; j < MAX_LEN; ++j) {
                temp_short[j] = ispc_map.shortURLs[j][i];
                if (temp_short[j] == 0) break;
            }
            temp_short[j] = 0;
            
            printf("[%02d] %s → %s\n", i, temp_long, temp_short);
        }
    } else {
        int mt_count = mt_map.count.load(std::memory_order_acquire);
        printf("\nMap after processing (count=%d):\n", mt_count);
        for (int i = 0; i < std::min(10, mt_count); ++i)
            printf("[%02d] %s → %s\n", i, mt_map.longURLs[i], mt_map.shortURLs[i]);
    }


    // ------------------------------------------------------------------
    // DUMP TIMING DATA TO CSV
    // ------------------------------------------------------------------
    std::string technique = use_ispc ? "ispc" : ("mt" + std::to_string(num_threads > 0 ? num_threads : 8) + "_" + mt_mode);
    std::string timing_filename = "timing_stats_" + technique + "_N" + std::to_string(N) + ".csv";
    
    FILE* csv_file = fopen(timing_filename.c_str(), "w");
    if (csv_file) {
        // Write header with statistical info
 
        fprintf(csv_file, "Lane,QueueingDelay,ExecutionTime,TotalLatency\n");
        
        // Write averaged per-lane timing data
        for (int i = 0; i < N; i++) {
            fprintf(csv_file, "%d,%.1f,%.1f,%.1f\n", 
                    i, avg_queue_delay[i], avg_exec_time[i], avg_total_latency[i]);
        }
        
        fclose(csv_file);
        std::cout << "✅ Per-lane timing data exported to '" << timing_filename << "'\n";
    } else {
        std::cerr << "❌ Failed to create timing CSV file\n";
    }
    
    // ------------------------------------------------------------------
    // DUMP STATISTICAL BENCHMARK RESULTS TO CSV
    // ------------------------------------------------------------------
    std::string stats_filename = "benchmark_stats_" + technique + "_N" + std::to_string(N) + ".csv";
    
    FILE* stats_file = fopen(stats_filename.c_str(), "w");
    if (stats_file) {
        // Write benchmark configuration and results
        fprintf(stats_file, "Metric,Value,Unit\n");
        fprintf(stats_file, "Technique,%s,\n", technique.c_str());
        fprintf(stats_file, "BatchSize,%d,URLs\n", N);
        fprintf(stats_file, "WarmupIterations,%d,\n", warmup_iters);
        fprintf(stats_file, "BenchmarkIterations,%d,\n", bench_iters);
        fprintf(stats_file, "\n");
        
        // Cycle statistics
        fprintf(stats_file, "CyclesMin,%ld,cycles\n", (int64_t)cycle_stats.min);
        fprintf(stats_file, "CyclesMedian,%ld,cycles\n", (int64_t)cycle_stats.median);
        fprintf(stats_file, "CyclesMean,%.2f,cycles\n", cycle_stats.mean);
        fprintf(stats_file, "CyclesMax,%ld,cycles\n", (int64_t)cycle_stats.max);
        fprintf(stats_file, "CyclesStddev,%.2f,cycles\n", cycle_stats.stddev);
        fprintf(stats_file, "CyclesCV,%.2f,percent\n", cycle_stats.cv);
        fprintf(stats_file, "CyclesOutliers,%d,count\n", cycle_stats.num_outliers);
        fprintf(stats_file, "\n");
        
        // Time statistics
        fprintf(stats_file, "TimeMinUs,%.2f,microseconds\n", time_stats.min / 1000.0);
        fprintf(stats_file, "TimeMedianUs,%.2f,microseconds\n", time_stats.median / 1000.0);
        fprintf(stats_file, "TimeMeanUs,%.2f,microseconds\n", time_stats.mean / 1000.0);
        fprintf(stats_file, "TimeMaxUs,%.2f,microseconds\n", time_stats.max / 1000.0);
        fprintf(stats_file, "TimeStddevUs,%.2f,microseconds\n", time_stats.stddev / 1000.0);
        fprintf(stats_file, "TimeCV,%.2f,percent\n", time_stats.cv);
        fprintf(stats_file, "TimeOutliers,%d,count\n", time_stats.num_outliers);
        fprintf(stats_file, "\n");
        
        // Performance metrics (based on median)
        fprintf(stats_file, "EstimatedCpuFreqGHz,%.3f,GHz\n", estimated_freq_ghz);
        fprintf(stats_file, "ThroughputURLsPerSec,%.2f,URLs/sec\n", (N * 1e9 / time_stats.median));
        fprintf(stats_file, "CyclesPerURL,%ld,cycles\n", (int64_t)(cycle_stats.median / N));
        fprintf(stats_file, "TimePerURLNs,%.2f,nanoseconds\n", (time_stats.median / (double)N));
        
        fclose(stats_file);
        std::cout << "✅ Statistical results exported to '" << stats_filename << "'\n";
    } else {
        std::cerr << "❌ Failed to create stats CSV file\n";
    }
    
    // ------------------------------------------------------------------
    // DUMP ALL RAW MEASUREMENTS TO CSV
    // ------------------------------------------------------------------
    std::string raw_filename = "raw_measurements_" + technique + "_N" + std::to_string(N) + ".csv";
    
    FILE* raw_file = fopen(raw_filename.c_str(), "w");
    if (raw_file) {
        fprintf(raw_file, "Iteration,Cycles,TimeNs,TimeMicroseconds\n");
        for (int i = 0; i < bench_iters; i++) {
            fprintf(raw_file, "%d,%ld,%ld,%.2f\n", 
                    i + 1, 
                    cycle_measurements[i], 
                    time_measurements_ns[i],
                    time_measurements_ns[i] / 1000.0);
        }
        fclose(raw_file);
        std::cout << "✅ Raw measurements exported to '" << raw_filename << "'\n";
    } else {
        std::cerr << "❌ Failed to create raw measurements CSV file\n";
    }
    
    // ------------------------------------------------------------------
    // DUMP THROUGHPUT STATS TO CSV
    // ------------------------------------------------------------------
    std::string throughput_filename = "throughput_stats_" + technique + "_N" + std::to_string(N) + ".csv";
    
    FILE* throughput_file = fopen(throughput_filename.c_str(), "w");
    if (throughput_file) {
        double throughput = (N * 1e9 / time_stats.median);
        
        // Write header
        fprintf(throughput_file, "Metric,Value,Unit\n");
        
        // Write throughput metrics (median-based)
        fprintf(throughput_file, "BatchSize,%d,URLs\n", N);
        fprintf(throughput_file, "MedianTimeUs,%.2f,microseconds\n", time_stats.median / 1000.0);
        fprintf(throughput_file, "Throughput,%.2f,URLs/sec\n", throughput);
        fprintf(throughput_file, "AvgLatencyPerURL,%.2f,nanoseconds\n", (time_stats.median / N));
        
        fclose(throughput_file);
        std::cout << "✅ Throughput stats exported to '" << throughput_filename << "'\n";
    } else {
        std::cerr << "❌ Failed to create throughput CSV file\n";
    }
    
    std::cout << "\n";
    
    // Cleanup
    if (!use_ispc) {
        std::cout << "🔧 Destroying thread pool...\n";
        mt::DestroyThreadPool();
        std::cout << "✅ Cleanup complete\n";
    }
    
    // Cleanup
    delete[] HOSTNAME_ISPC;
    delete[] tokens_buf_SOA;
    delete[] out_buf_SOA;
    delete[] HOSTNAME_AOS;
    delete[] tokens_buf_AOS;
    delete[] out_buf_AOS;
    delete[] offsets;
    
    return 0;
}