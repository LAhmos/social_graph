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
using namespace ispc;
#include <cstdio>
#include <cstdio>
#include <cstdint>

#include <cstdio>
#include <cstring>
#include <cstdint>
#define MAX_LEN 128

#include <stdio.h>
#include <string.h>
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
int main() {

    string machine_id;
    if (GetMachineId(&machine_id) != 0) {
	exit(EXIT_FAILURE);
    }
    cout<<"machine_id: "<<machine_id<<endl;
    const char* machine_id_cstr = machine_id.c_str();
    int machine_len = strlen(machine_id_cstr);

    const int N = 48;
    uint8_t ids[N][32];
    std::cout << "Base address of ids: " << static_cast<void*>(ids) << "\n\n";

    for (int i = 0; i < N; i++) {
        std::cout << "Row " << i << " address: "
                  << static_cast<void*>(ids[i]) << '\n';
    }

    // Timing arrays
    std::vector<int64_t> lane_start_times(N);
    std::vector<int64_t> lane_end_times(N);
    int64_t global_start_time = 0;

    auto start = std::chrono::high_resolution_clock::now();
    ispc::UploadUniqueIdBatch((uint8_t*)machine_id_cstr, machine_len, N, ids,
                              lane_start_times.data(),
                              lane_end_times.data(),
                              global_start_time);
    auto end = std::chrono::high_resolution_clock::now();
    
    auto duration = std::chrono::duration_cast<std::chrono::microseconds>(end - start);
    std::cout << "\nBatch completed in " << duration.count() << " µs\n";
    std::cout << "Throughput: " << (N * 1000000.0 / duration.count()) << " IDs/sec\n\n";

    for (int i = 0; i < N; i++)
        printf("Lane %d → %s\n", i, ids[i]);
    
    // ------------------------------------------------------------------
    // DUMP TIMING DATA TO CSV
    // ------------------------------------------------------------------
    FILE* csv_file = fopen("timing_stats.csv", "w");
    if (csv_file) {
        // Write header
        fprintf(csv_file, "Lane,QueueingDelay,ExecutionTime,TotalLatency\n");
        
        // Write per-lane timing data
        for (int i = 0; i < N; i++) {
            int64_t queue_delay = lane_start_times[i] - global_start_time;
            int64_t exec_time = lane_end_times[i] - lane_start_times[i];
            int64_t total_latency = lane_end_times[i] - global_start_time;
            
            fprintf(csv_file, "%d,%ld,%ld,%ld\n", i, queue_delay, exec_time, total_latency);
        }
        
        fclose(csv_file);
        std::cout << "\n✅ Timing data exported to 'timing_stats.csv'\n";
    } else {
        std::cerr << "\n❌ Failed to create CSV file\n";
    }
    
    // ------------------------------------------------------------------
    // DUMP THROUGHPUT STATS TO CSV
    // ------------------------------------------------------------------
    FILE* throughput_file = fopen("throughput_stats.csv", "w");
    if (throughput_file) {
        double throughput = (N * 1000000.0 / duration.count());
        
        // Write header
        fprintf(throughput_file, "Metric,Value,Unit\n");
        
        // Write throughput metrics
        fprintf(throughput_file, "BatchSize,%d,IDs\n", N);
        fprintf(throughput_file, "TotalTime,%ld,microseconds\n", duration.count());
        fprintf(throughput_file, "Throughput,%.2f,IDs/sec\n", throughput);
        fprintf(throughput_file, "AvgLatencyPerID,%.2f,nanoseconds\n", (duration.count() * 1000.0 / N));
        
        // Calculate per-group statistics
        const int SIMD_WIDTH = 8;
        int num_groups = (N + SIMD_WIDTH - 1) / SIMD_WIDTH;
        
        fprintf(throughput_file, "\nGroup,AvgQueueDelay,AvgExecTime,AvgTotalLatency,Unit\n");
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
            
            fprintf(throughput_file, "%d,%ld,%ld,%ld,cycles\n", 
                    group,
                    total_queue / lanes_in_group,
                    total_exec / lanes_in_group,
                    total_latency / lanes_in_group);
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
                
                double speedup = (double)group0_avg / group1_avg;
                fprintf(throughput_file, "\nMetric,Value,Unit\n");
                fprintf(throughput_file, "ColdCacheExecution,%ld,cycles\n", group0_avg);
                fprintf(throughput_file, "WarmCacheExecution,%ld,cycles\n", group1_avg);
                fprintf(throughput_file, "CacheWarmupSpeedup,%.2f,x\n", speedup);
            }
        }
        
        fclose(throughput_file);
        std::cout << "✅ Throughput stats exported to 'throughput_stats.csv'\n";
    } else {
        std::cerr << "❌ Failed to create throughput CSV file\n";
    }
    
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
    
    return 0;
}
