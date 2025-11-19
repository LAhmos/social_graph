/*
  Copyright (c) 2010-2023, Intel Corporation

  SPDX-License-Identifier: BSD-3-Clause
*/

#include <stdio.h>
#include <stdlib.h>
#include<iostream>
#include<algorithm>
#include<string>
#include<vector>
#include <chrono>
#include <mutex>
#include <sstream>
#include <iomanip>
#include <atomic>
#include <arpa/inet.h>
#include <net/if.h>
#include <sys/ioctl.h>
#include <sys/socket.h>
#include <signal.h>
#include <unistd.h>
#include <stdlib.h>
#include <stdio.h>
#include <string.h>
using namespace std;

// Include the header file that the ispc compiler generates
#include "simple_ispc.h"
#include "simple_optimized_ispc.h"
// Include the multithreaded version
#include "simple_mt.h"
#include <cstdio>
#include <cstdio>
#include <cstdint>

#include <cstdio>
#include <cstring>
#include <cstdint>
#include <cmath>
#define MAX_LEN 128

#include <stdio.h>
#include <string.h>
#include <pthread.h>
#include <sched.h>

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

// Pin thread to specific CPU core
void pin_to_core(int core_id) {
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(core_id, &cpuset);
    pthread_t current_thread = pthread_self();
    if (pthread_setaffinity_np(current_thread, sizeof(cpu_set_t), &cpuset) != 0) {
        std::cerr << "Warning: Failed to pin thread to core " << core_id << "\n";
    } else {
        std::cout << "✅ Thread pinned to CPU core " << core_id << "\n";
    }
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
u_int16_t HashMacAddressPid(const std::string &mac)
{
  u_int16_t hash = 0;
  std::string mac_pid = mac + std::to_string(getpid());
  for ( unsigned int i = 0; i < mac_pid.size(); i++ ) {
    hash += ( mac[i] << (( i & 1 ) * 8 ));
  }
  return hash;
}

int GetMachineId (std::string *mac_hash) {
  std::string mac;
  int sock = socket(AF_INET, SOCK_DGRAM, IPPROTO_IP );
  if ( sock < 0 ) {
    cout << "Unable to obtain MAC address" <<endl;
    return -1;
  }

  struct ifconf conf{};
  char ifconfbuf[ 128 * sizeof(struct ifreq)  ];
  memset( ifconfbuf, 0, sizeof( ifconfbuf ));
  conf.ifc_buf = ifconfbuf;
  conf.ifc_len = sizeof( ifconfbuf );
  if ( ioctl( sock, SIOCGIFCONF, &conf ))
  {
    cout << "Unable to obtain MAC address";
    return -1;
  }

  struct ifreq* ifr;
  for (
      ifr = conf.ifc_req;
      reinterpret_cast<char *>(ifr) <
          reinterpret_cast<char *>(conf.ifc_req) + conf.ifc_len;
      ifr++) {
    if ( ifr->ifr_addr.sa_data == (ifr+1)->ifr_addr.sa_data ) {
      continue;  // duplicate, skip it
    }

    if ( ioctl( sock, SIOCGIFFLAGS, ifr )) {
      continue;  // failed to get flags, skip it
    }
    if ( ioctl( sock, SIOCGIFHWADDR, ifr ) == 0 ) {
      mac = std::string(ifr->ifr_addr.sa_data);
      if (!mac.empty()) {
        break;
      }
    }
  }
  close(sock);

  std::stringstream stream;
  stream << std::hex << HashMacAddressPid(mac);
  *mac_hash = stream.str();

  if (mac_hash->size() > 3) {
    mac_hash->erase(0, mac_hash->size() - 3);
  } else if (mac_hash->size() < 3) {
    *mac_hash = std::string(3 - mac_hash->size(), '0') + *mac_hash;
  }
  return 0;
}
int main(int argc, char* argv[]) {
    // Parse command-line arguments
    bool use_ispc = true;  // Default to ISPC
    bool use_optimized_ispc = true;  // Always use optimized ISPC version by default
    int num_threads = 0;    // 0 means auto-detect for multithreaded
    std::string mt_mode = "pool";  // Default MT mode: "pool" or "spawn"
    int N = 48;  // Default batch size
    int warmup_iters = 5;   // Warm-up iterations
    int bench_iters = 50;   // Benchmark iterations
    int pin_core = 0;       // CPU core to pin to
    int fake_work_iters = 0; // Fake work iterations (for testing memory-bound hypothesis)
    
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
            if (argc > 6) {
                fake_work_iters = std::atoi(argv[6]);
            }
        } else if (mode_str == "ispc" || mode_str == "ispc-opt" || mode_str == "ispc-optimized") {
            use_ispc = true;
            use_optimized_ispc = true;  // Always use optimized ISPC (SoA + register optimization)
            if (argc > 2) {
                N = std::atoi(argv[2]);
            }
            if (argc > 3) {
                bench_iters = std::atoi(argv[3]);
            }
        } else if (mode_str == "ispc-old") {
            use_ispc = true;
            use_optimized_ispc = false;  // Original ISPC (only via explicit ispc-old flag)
            if (argc > 2) {
                N = std::atoi(argv[2]);
            }
            if (argc > 3) {
                bench_iters = std::atoi(argv[3]);
            }
        } else {
            std::cerr << "Usage: " << argv[0] << " [ispc|mt] [num_threads] [mt_mode] [batch_size] [iterations] [fake_work]\n";
            std::cerr << "  ispc:         Use ISPC SIMD (optimized SoA + register optimization) [DEFAULT]\n";
            std::cerr << "  ispc-old:     Use ISPC SIMD (original AoS layout, for comparison only)\n";
            std::cerr << "  mt:           Use multithreaded implementation\n";
            std::cerr << "  num_threads:  Number of threads (only for mt mode, default=auto)\n";
            std::cerr << "  mt_mode:      'pool' or 'spawn' (only for mt mode, default='pool')\n";
            std::cerr << "  batch_size:   Number of IDs to generate (default=48)\n";
            std::cerr << "  iterations:   Benchmark iterations (default=50)\n";
            std::cerr << "  fake_work:    Fake work iterations for mt mode (default=0, tests memory-bound)\n";
            std::cerr << "\nExamples:\n";
            std::cerr << "  " << argv[0] << " ispc 1000             # Optimized ISPC with 1000 IDs, 50 iterations\n";
            std::cerr << "  " << argv[0] << " ispc 1000 100         # Optimized ISPC with 1000 IDs, 100 iterations\n";
            std::cerr << "  " << argv[0] << " ispc-old 1000         # Original ISPC (for comparison)\n";
            std::cerr << "  " << argv[0] << " mt 8 pool 1000        # MT pool, 8 threads, 1000 IDs\n";
            std::cerr << "  " << argv[0] << " mt 8 spawn 1000 100   # MT spawn, 8 threads, 1000 IDs, 100 iterations\n";
            std::cerr << "  " << argv[0] << " mt 8 1000 100 1000 # Same with 1000 fake work iterations (CPU-bound test)\n";
            return 1;
        }
    }
    
    // Validate mt_mode
    if (mt_mode != "pool" && mt_mode != "spawn") {
        std::cerr << "Error: mt_mode must be 'pool' or 'spawn'\n";
        return 1;
    }
    
    std::string mode_name = use_ispc ? (use_optimized_ispc ? "ISPC SIMD (Optimized)" : "ISPC SIMD (Original)") : ("Multithreaded (" + mt_mode + ")");
    int padding = 66 - 9 - mode_name.length();
    
    std::cout << "\n╔══════════════════════════════════════════════════════════════════╗\n";
    std::cout << "║  BENCHMARK CONFIGURATION                                         ║\n";
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
    std::cout << "║  CPU Core Pinning: " << pin_core << std::string(46 - std::to_string(pin_core).length(), ' ') << "║\n";
    if (!use_ispc && fake_work_iters > 0) {
        std::cout << "║  Fake Work Iterations: " << fake_work_iters << std::string(42 - std::to_string(fake_work_iters).length(), ' ') << "║\n";
    }
    std::cout << "╚══════════════════════════════════════════════════════════════════╝\n\n";
    
    // Pin to CPU core (DISABLED for multithreaded benchmarks - causes all threads to compete for same core!)
    if (use_ispc) {
        pin_to_core(pin_core);
    } else {
        std::cout << "ℹ️  CPU pinning disabled for multithreaded mode (would cause contention)\n\n";
    }
    
    // Initialize thread pool for multithreaded mode (BEFORE any timing)
    ThreadPool::Mode pool_mode = (mt_mode == "spawn") ? ThreadPool::SPAWN_MODE : ThreadPool::POOL_MODE;
    if (!use_ispc) {
        std::cout << "🔧 Initializing thread pool with " << (num_threads > 0 ? num_threads : std::thread::hardware_concurrency()) << " threads (" << mt_mode << " mode)...\n";
        mt::InitThreadPool(num_threads, pool_mode);
        mt::SetFakeWorkIterations(fake_work_iters);
        if (fake_work_iters > 0) {
            std::cout << "⚙️  Fake work enabled: " << fake_work_iters << " iterations per ID (testing CPU-bound behavior)\n";
        }
        std::cout << "✅ Thread pool ready\n\n";
    }

    string machine_id;
    if (GetMachineId(&machine_id) != 0) {
	exit(EXIT_FAILURE);
    }
    cout<<"machine_id: "<<machine_id<<endl;
    const char* machine_id_cstr = machine_id.c_str();
    int machine_len = strlen(machine_id_cstr);

    // Dynamically allocate arrays based on N and mode
    uint8_t (*ids)[32] = new uint8_t[N][32];
    uint8_t* ids_transposed = nullptr;  // For optimized ISPC (SoA layout)
    
    if (use_optimized_ispc) {
        ids_transposed = new uint8_t[32 * N];  // Flat transposed buffer
        std::cout << "Allocated transposed buffer for optimized ISPC: " << static_cast<void*>(ids_transposed) << "\n";
    } else {
        std::cout << "Base address of ids: " << static_cast<void*>(ids) << "\n";
        
        if (N <= 48) {
            std::cout << "\n";
            for (int i = 0; i < N; i++) {
                std::cout << "Row " << i << " address: "
                          << static_cast<void*>(ids[i]) << '\n';
            }
        } else {
            std::cout << "(Skipping address printout for large N)\n";
        }
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
        if (use_ispc && use_optimized_ispc) {
            ispc::UploadUniqueIdBatch_Optimized((uint8_t*)machine_id_cstr, machine_len, N, ids_transposed,
                                                lane_start_times.data(),
                                                lane_end_times.data(),
                                                global_start_time);
        } else if (use_ispc) {
            ispc::UploadUniqueIdBatch((uint8_t*)machine_id_cstr, machine_len, N, ids,
                                      lane_start_times.data(),
                                      lane_end_times.data(),
                                      global_start_time);
        } else {
            mt::UploadUniqueIdBatch((uint8_t*)machine_id_cstr, machine_len, N, ids,
                                    lane_start_times.data(),
                                    lane_end_times.data(),
                                    global_start_time,
                                    num_threads);
        }
    }
    std::cout << "✅ Warm-up complete\n\n";

    // ========================================================================
    // BENCHMARK PHASE
    // ========================================================================
    std::cout << "📊 Benchmarking: " << bench_iters << " iterations...\n";
    std::vector<int64_t> cycle_measurements;
    std::vector<int64_t> time_measurements_ns;
    
    for (int iter = 0; iter < bench_iters; iter++) {
        // Cycle measurement with serialization
        uint64_t cycles_start = rdtsc_start();
        
        // Wall-clock time measurement
        auto start = std::chrono::high_resolution_clock::now();
        
        // Call the appropriate implementation based on mode
        if (use_ispc && use_optimized_ispc) {
            ispc::UploadUniqueIdBatch_Optimized((uint8_t*)machine_id_cstr, machine_len, N, ids_transposed,
                                                lane_start_times.data(),
                                                lane_end_times.data(),
                                                global_start_time);
        } else if (use_ispc) {
            ispc::UploadUniqueIdBatch((uint8_t*)machine_id_cstr, machine_len, N, ids,
                                      lane_start_times.data(),
                                      lane_end_times.data(),
                                      global_start_time);
        } else {
            mt::UploadUniqueIdBatch((uint8_t*)machine_id_cstr, machine_len, N, ids,
                                    lane_start_times.data(),
                                    lane_end_times.data(),
                                    global_start_time,
                                    num_threads);
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
              << (N * 1e9 / time_stats.median) << " IDs/sec\n";
    std::cout << "  Cycles per ID:        " << (int64_t)(cycle_stats.median / N) << " cycles\n";
    std::cout << "  Time per ID:          " << std::fixed << std::setprecision(2)
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
        std::cout << "     - Use taskset to pin to isolated core\n";
    }
    std::cout << "\n";

    // Print first 10 and last 10 IDs for large N
    int print_limit = std::min(10, N);
    for (int i = 0; i < print_limit; i++)
        printf("Lane %d → %s\n", i, ids[i]);
    
    if (N > 20) {
        printf("...\n");
        for (int i = N - print_limit; i < N; i++)
            printf("Lane %d → %s\n", i, ids[i]);
    } else if (N > 10) {
        for (int i = print_limit; i < N; i++)
            printf("Lane %d → %s\n", i, ids[i]);
    }
    
    // ------------------------------------------------------------------
    // DUMP TIMING DATA TO CSV (from last iteration)
    // ------------------------------------------------------------------
    // Create unique filename based on technique and batch size
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
        fprintf(stats_file, "BatchSize,%d,IDs\n", N);
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
        fprintf(stats_file, "ThroughputIDsPerSec,%.2f,IDs/sec\n", (N * 1e9 / time_stats.median));
        fprintf(stats_file, "CyclesPerID,%ld,cycles\n", (int64_t)(cycle_stats.median / N));
        fprintf(stats_file, "TimePerIDNs,%.2f,nanoseconds\n", (time_stats.median / (double)N));
        
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
    // DUMP THROUGHPUT STATS TO CSV (keeping old format for compatibility)
    // ------------------------------------------------------------------
    std::string throughput_filename = "throughput_stats_" + technique + "_N" + std::to_string(N) + ".csv";
    
    FILE* throughput_file = fopen(throughput_filename.c_str(), "w");
    if (throughput_file) {
        double throughput = (N * 1e9 / time_stats.median);
        
        // Write header
        fprintf(throughput_file, "Metric,Value,Unit\n");
        
        // Write throughput metrics (median-based)
        fprintf(throughput_file, "BatchSize,%d,IDs\n", N);
        fprintf(throughput_file, "MedianTimeUs,%.2f,microseconds\n", time_stats.median / 1000.0);
        fprintf(throughput_file, "Throughput,%.2f,IDs/sec\n", throughput);
        fprintf(throughput_file, "AvgLatencyPerID,%.2f,nanoseconds\n", (time_stats.median / N));
        
        // Calculate per-group statistics
        const int SIMD_WIDTH = 8;
        int num_groups = (N + SIMD_WIDTH - 1) / SIMD_WIDTH;
        
        fprintf(throughput_file, "\nGroup,AvgQueueDelay,AvgExecTime,AvgTotalLatency,Unit\n");
        for (int group = 0; group < num_groups; group++) {
            double total_queue = 0;
            double total_exec = 0;
            double total_latency = 0;
            int lanes_in_group = std::min(SIMD_WIDTH, N - group * SIMD_WIDTH);
            
            for (int lane = 0; lane < lanes_in_group; lane++) {
                int idx = group * SIMD_WIDTH + lane;
                total_queue += avg_queue_delay[idx];
                total_exec += avg_exec_time[idx];
                total_latency += avg_total_latency[idx];
            }
            
            fprintf(throughput_file, "%d,%.1f,%.1f,%.1f,cycles\n", 
                    group,
                    total_queue / lanes_in_group,
                    total_exec / lanes_in_group,
                    total_latency / lanes_in_group);
        }
        
        // Cache warming analysis (using averaged values)
        if (num_groups >= 2) {
            double group0_avg = 0, group1_avg = 0;
            for (int i = 0; i < SIMD_WIDTH && i < N; i++) {
                group0_avg += avg_exec_time[i];
            }
            group0_avg /= std::min(SIMD_WIDTH, N);
            
            if (N > SIMD_WIDTH) {
                int lanes_in_group1 = std::min(SIMD_WIDTH, N - SIMD_WIDTH);
                for (int i = 0; i < lanes_in_group1; i++) {
                    group1_avg += avg_exec_time[SIMD_WIDTH + i];
                }
                group1_avg /= lanes_in_group1;
                
                double speedup = group0_avg / group1_avg;
                fprintf(throughput_file, "\nMetric,Value,Unit\n");
                fprintf(throughput_file, "ColdCacheExecution,%.1f,cycles\n", group0_avg);
                fprintf(throughput_file, "WarmCacheExecution,%.1f,cycles\n", group1_avg);
                fprintf(throughput_file, "CacheWarmupSpeedup,%.2f,x\n", speedup);
            }
        }
        
        fclose(throughput_file);
        std::cout << "✅ Throughput stats exported to '" << throughput_filename << "'\n";
    } else {
        std::cerr << "❌ Failed to create throughput CSV file\n";
    }
    
    std::cout << "\n";
    
    // ------------------------------------------------------------------
    // TIMING ANALYSIS
    // ------------------------------------------------------------------
    std::cout << "\n╔══════════════════════════════════════════════════════════════════╗\n";
    std::cout << "║       TIMING ANALYSIS - UploadUniqueIdBatch (N=" << N << ")            ║\n";
    std::cout << "╚══════════════════════════════════════════════════════════════════╝\n\n";
    
    // Calculate statistics per SIMD group (8 lanes per group)
    const int SIMD_WIDTH = 8;
    int num_groups = (N + SIMD_WIDTH - 1) / SIMD_WIDTH;
    
    std::cout << "Per-SIMD-Group Statistics (8 lanes per group):\n";
    std::cout << "Group | Avg Queue Delay | Avg Exec Time | Avg Total Latency\n";
    std::cout << "------+-----------------+---------------+------------------\n";
    
    for (int group = 0; group < num_groups; group++) {
        int64_t total_queue = 0;
        int64_t total_exec = 0;
        int64_t total_latency = 0;
        int lanes_in_group = std::min(SIMD_WIDTH, N - group * SIMD_WIDTH);
        
        for (int lane = 0; lane < lanes_in_group; lane++) {
            int idx = group * SIMD_WIDTH + lane;
            int64_t queue_delay = lane_start_times[idx] - global_start_time;
            int64_t exec_time = lane_end_times[idx] - lane_start_times[idx];
            int64_t latency = lane_end_times[idx] - global_start_time;
            
            total_queue += queue_delay;
            total_exec += exec_time;
            total_latency += latency;
        }
        
        std::cout << std::setw(5) << group << " | "
                  << std::setw(15) << (total_queue / lanes_in_group) << " | "
                  << std::setw(13) << (total_exec / lanes_in_group) << " | "
                  << std::setw(16) << (total_latency / lanes_in_group) << "\n";
    }
    
    // Detailed per-lane timing (showing first 16 lanes as sample)
    std::cout << "\nDetailed Per-Lane Timing (first 16 lanes, cycles):\n";
    std::cout << "Lane | Queueing Delay | Execution Time | Total Latency\n";
    std::cout << "-----+----------------+----------------+--------------\n";
    
    for (int i = 0; i < std::min(16, N); i++) {
        int64_t queue_delay = lane_start_times[i] - global_start_time;
        int64_t exec_time = lane_end_times[i] - lane_start_times[i];
        int64_t total_latency = lane_end_times[i] - global_start_time;
        
        std::cout << std::setw(4) << i << " | "
                  << std::setw(14) << queue_delay << " | "
                  << std::setw(14) << exec_time << " | "
                  << std::setw(12) << total_latency << "\n";
    }
    
    // Cache warming analysis
    if (num_groups >= 2) {
        int64_t group0_avg = 0, group1_avg = 0;
        for (int i = 0; i < SIMD_WIDTH && i < N; i++) {
            group0_avg += (lane_end_times[i] - lane_start_times[i]);
        }
        group0_avg /= std::min(SIMD_WIDTH, N);
        
        if (N > SIMD_WIDTH) {
            int lanes_in_group1 = std::min(SIMD_WIDTH, N - SIMD_WIDTH);
            for (int i = 0; i < lanes_in_group1; i++) {
                group1_avg += (lane_end_times[SIMD_WIDTH + i] - lane_start_times[SIMD_WIDTH + i]);
            }
            group1_avg /= lanes_in_group1;
            
            std::cout << "\n🔥 Cache Warming Analysis:\n";
            std::cout << "   Group 0 avg execution: " << group0_avg << " cycles (cold cache)\n";
            std::cout << "   Group 1 avg execution: " << group1_avg << " cycles (warm cache)\n";
            double speedup = (double)group0_avg / group1_avg;
            std::cout << "   Speedup after warmup: " << std::fixed << std::setprecision(2) 
                      << speedup << "x\n";
        }
    }
    
    // Cleanup
    if (!use_ispc) {
        std::cout << "\n🔧 Destroying thread pool...\n";
        mt::DestroyThreadPool();
        std::cout << "✅ Cleanup complete\n";
    }
    
    delete[] ids;
    if (ids_transposed) {
        delete[] ids_transposed;
    }
    
    return 0;
}
