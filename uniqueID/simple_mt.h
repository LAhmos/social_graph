#ifndef SIMPLE_MT_H
#define SIMPLE_MT_H

#include <cstdint>
#include <thread>
#include <vector>
#include <atomic>
#include <chrono>
#include <mutex>
#include <condition_variable>
#include <functional>
#include <cmath>
#include "../ThreadPool.h"

// Same custom epoch as ISPC version
#define CUSTOM_EPOCH 1514764800000

namespace mt {

// RDTSC-based timing (cycle-accurate)
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

// Get current timestamp in nanoseconds (kept for compatibility)
inline int64_t get_clock() {
    auto now = std::chrono::high_resolution_clock::now();
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        now.time_since_epoch()).count();
}

// Get timestamp in CPU cycles (using RDTSC)
inline int64_t get_clock_cycles() {
    return (int64_t)rdtsc_start();
}

// Global thread pool (initialized once)
static ThreadPool* g_thread_pool = nullptr;
static ThreadPool::Mode g_thread_pool_mode = ThreadPool::POOL_MODE;
static int g_num_threads = 0;
static int g_fake_work_iterations = 0;  // Global fake work parameter

// Initialize thread pool (call once before benchmarking)
void InitThreadPool(int num_threads = 0, ThreadPool::Mode mode = ThreadPool::POOL_MODE) {
    if (g_thread_pool) {
        delete g_thread_pool;
    }
    
    if (num_threads <= 0) {
        num_threads = std::thread::hardware_concurrency();
        if (num_threads == 0) num_threads = 8;
    }
    
    g_num_threads = num_threads;
    g_thread_pool_mode = mode;
    g_thread_pool = new ThreadPool(num_threads, mode);
}

// Cleanup thread pool (call at program exit)
void DestroyThreadPool() {
    if (g_thread_pool) {
        delete g_thread_pool;
        g_thread_pool = nullptr;
    }
}

// Set amount of fake work (CPU-bound computation)
void SetFakeWorkIterations(int iterations) {
    g_fake_work_iterations = iterations;
}

// Worker function that processes a range of IDs
void ProcessIdRange(const uint8_t* machine_id, int machine_len, 
                    int start_idx, int end_idx,
                    uint8_t out_buf[][32],
                    int64_t* lane_start_times,
                    int64_t* lane_end_times,
                    int64_t global_start_time) {
    
    for (int i = start_idx; i < end_idx; i++) {
        // Record actual start time (in CPU cycles)
        int64_t actual_start_time = get_clock_cycles();
        lane_start_times[i] = actual_start_time;
        
        //----------------------------------------------------------------------
        // Generate pseudo-timestamp and lane counter (same as ISPC)
        //----------------------------------------------------------------------
        int64_t timestamp = actual_start_time + (int64_t)i;
        int counter = i;
        
        //----------------------------------------------------------------------
        // Convert timestamp -> 10-digit hex (ASCII-based)
        //----------------------------------------------------------------------
        const int timestamp_hex_len = 10;
        uint8_t timestamp_hex[11];
        
        for (int j = 0; j < timestamp_hex_len; ++j) {
            int shift = 4 * (timestamp_hex_len - 1 - j);
            int nib = (timestamp >> shift) & 0xF;
            
            // ASCII conversion
            uint8_t ch;
            if (nib < 10)
                ch = (uint8_t)(48 + nib);        // '0' = 48
            else
                ch = (uint8_t)(97 + (nib - 10)); // 'a' = 97
            
            timestamp_hex[j] = ch;
        }
        timestamp_hex[timestamp_hex_len] = 0;
        
        //----------------------------------------------------------------------
        // Convert counter -> 3-digit hex (ASCII-based)
        //----------------------------------------------------------------------
        const int counter_hex_len = 3;
        uint8_t counter_hex[4];
        
        for (int j = 0; j < counter_hex_len; ++j) {
            int shift = 4 * (counter_hex_len - 1 - j);
            int nib = (counter >> shift) & 0xF;
            
            uint8_t ch;
            if (nib < 10)
                ch = (uint8_t)(48 + nib);        // 48 = '0'
            else
                ch = (uint8_t)(97 + (nib - 10)); // 97 = 'a'
            
            counter_hex[j] = ch;
        }
        counter_hex[counter_hex_len] = 0;
        
        //----------------------------------------------------------------------
        // Build final ID string
        //----------------------------------------------------------------------
        uint8_t* dst = out_buf[i];
        
        // Copy machine_id
        for (int j = 0; j < machine_len; ++j) {
            *dst++ = machine_id[j];
        }
        
        // Append timestamp hex
        for (int j = 0; j < timestamp_hex_len; ++j) {
            *dst++ = timestamp_hex[j];
        }
        
        // Append counter hex
        for (int j = 0; j < counter_hex_len; ++j) {
            *dst++ = counter_hex[j];
        }
        
        *dst = 0;
        
        //----------------------------------------------------------------------
        // FAKE WORK: CPU-bound computation to test memory-bound hypothesis
        //----------------------------------------------------------------------
        volatile double fake_result = 0.0;
        for (int iter = 0; iter < g_fake_work_iterations; iter++) {
            // Compute-intensive operations that won't be optimized away
            fake_result += std::sin(i * 0.1 + iter * 0.01) * std::cos(timestamp * 0.001);
            fake_result *= 1.00001;  // Prevent constant folding
        }
        // Use the result to prevent dead code elimination
        if (fake_result > 1e100) {
            *dst = (uint8_t)fake_result;  // Never actually happens, but prevents optimization
        }
        
        int64_t end_time = get_clock_cycles();
        lane_end_times[i] = end_time;
    }
}

// Main multithreaded batch function (matching ISPC interface)
// Now uses thread pool with direct task assignment (no work-stealing overhead)
void UploadUniqueIdBatch(const uint8_t* machine_id,
                         int machine_len,
                         int N,
                         uint8_t out_buf[][32],
                         int64_t* lane_start_times,
                         int64_t* lane_end_times,
                         int64_t& global_start_time,
                         int num_threads = 0) {
    
    // Initialize thread pool if not already done
    if (!g_thread_pool || (num_threads > 0 && num_threads != g_num_threads)) {
        InitThreadPool(num_threads);
    }
    
    // Capture global start time (in CPU cycles)
    global_start_time = get_clock_cycles();
    
    // Get actual number of workers in the pool
    int actual_workers = g_thread_pool->get_num_workers();
    
    // Calculate work distribution per worker
    int items_per_thread = (N + actual_workers - 1) / actual_workers;
    
    // Execute work using thread pool
    // Each worker gets its ID directly (0, 1, 2, ..., n-1) with no contention
    g_thread_pool->execute([=](int worker_id) {
        int start_idx = worker_id * items_per_thread;
        int end_idx = std::min(start_idx + items_per_thread, N);
        
        if (start_idx < N) {
            ProcessIdRange(machine_id, machine_len,
                          start_idx, end_idx,
                          out_buf,
                          lane_start_times,
                          lane_end_times,
                          global_start_time);
        }
    }, actual_workers);
}

} // namespace mt

#endif // SIMPLE_MT_H
