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
#include <cstring>
#include "../ThreadPool.h"

#define MAX_LEN 128
#define MAX_ENTRIES 1024

namespace mt {

#define HASH_TABLE_SIZE_MT 16384

// URL Map structure (matching ISPC layout with hash table)
struct URLMap {
    uint8_t shortURLs[MAX_ENTRIES][MAX_LEN];
    uint8_t longURLs[MAX_ENTRIES][MAX_LEN];
    std::atomic<int> count;  // Atomic counter (matching ISPC atomic_add_global)
    
    // Hash table for O(1) lookup
    std::atomic<int> hashTable[HASH_TABLE_SIZE_MT];
    
    // Store hash values for collision detection
    uint64_t hashValues[MAX_ENTRIES];
};

// Global thread pool (initialized once)
static ThreadPool* g_thread_pool = nullptr;
static ThreadPool::Mode g_thread_pool_mode = ThreadPool::POOL_MODE;
static int g_num_threads = 0;

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

// Helper: string length (matching ISPC ustrlen)
inline int ustrlen(const uint8_t* s, int maxn) {
    for (int i = 0; i < maxn; ++i)
        if (s[i] == 0) return i;
    return maxn;
}

// Helper: hash function (matching ISPC hash_djb2)
inline uint64_t hash_djb2(const uint8_t* p) {
    uint64_t h = 5381ul;
    for (int j = 0; j < MAX_LEN - 1; ++j) {
        uint8_t b = p[j];
        if (b == 0) break;
        h = ((h << 5) + h) + b;
    }
    return h;
}

// Helper: string comparison (matching ISPC ustrcmp_eq)
inline bool ustrcmp_eq(const uint8_t* a, const uint8_t* b) {
    for (int j = 0; j < MAX_LEN; ++j) {
        uint8_t ca = a[j];
        uint8_t cb = b[j];
        if (ca != cb) return false;
        if (ca == 0 || cb == 0) break;
    }
    return true;
}

// Helper: find URL in map (using hash table for O(1) lookup)
inline int find_url(URLMap& map, const uint8_t* longURL) {
    // Compute hash for this URL
    uint64_t url_hash = hash_djb2(longURL);
    
    // Linear probing with max 8 probes
    int hash_idx = (int)(url_hash & (HASH_TABLE_SIZE_MT - 1));
    for (int probe = 0; probe < 8; ++probe) {
        int slot = map.hashTable[hash_idx].load(std::memory_order_acquire);
        if (slot == -1) {
            // Empty slot, URL not found
            return -1;
        }
        // Check if hash matches and URL matches
        if (map.hashValues[slot] == url_hash && 
            ustrcmp_eq(&map.longURLs[slot][0], longURL)) {
            return slot;
        }
        // Collision, try next slot
        hash_idx = (hash_idx + 1) & (HASH_TABLE_SIZE_MT - 1);
    }
    return -1;
}

// Helper: insert into map (lock-free with atomic and hash table)
inline void insert_into_map(URLMap& map, const uint8_t* longURL, const uint8_t* shortURL) {
    // Atomically reserve a slot (equivalent to ISPC's atomic_add_global)
    int slot = map.count.fetch_add(1, std::memory_order_relaxed);
    
    if (slot >= MAX_ENTRIES) return;
    
    // Compute hash for this URL
    uint64_t url_hash = hash_djb2(longURL);
    
    // Store hash value for collision detection
    map.hashValues[slot] = url_hash;
    
    // Write to the reserved slot (no contention, each thread has unique slot)
    for (int j = 0; j < MAX_LEN; ++j) {
        map.longURLs[slot][j] = longURL[j];
        map.shortURLs[slot][j] = shortURL[j];
        if (longURL[j] == 0 && shortURL[j] == 0) break;
    }
    
    // Insert into hash table with linear probing
    int hash_idx = (int)(url_hash & (HASH_TABLE_SIZE_MT - 1));
    for (int probe = 0; probe < 8; ++probe) {
        int expected = -1;
        if (map.hashTable[hash_idx].compare_exchange_strong(expected, slot, std::memory_order_release)) {
            // Successfully inserted
            break;
        }
        // Collision, try next slot
        hash_idx = (hash_idx + 1) & (HASH_TABLE_SIZE_MT - 1);
    }
}

// Worker function that processes a range of URLs
void ProcessUrlRange(URLMap& map,
                     const uint8_t* HOSTNAME,
                     int host_len,
                     const uint8_t* tokens_buf,
                     int start_idx,
                     int end_idx,
                     uint8_t* out_buf,
                     int64_t* lane_start_times,
                     int64_t* lane_end_times,
                     int64_t global_start_time) {
    
    // Alphabet for base-62 encoding
    const uint8_t alphabet[62] = {
        97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,117,118,119,120,121,122, // a-z
        65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,                         // A-Z
        48,49,50,51,52,53,54,55,56,57                                                                          // 0-9
    };
    
    for (int i = start_idx; i < end_idx; i++) {
        // Record actual start time (in CPU cycles)
        int64_t actual_start_time = get_clock_cycles();
        lane_start_times[i] = actual_start_time;
        
        // AoS layout: tokens are sequential in memory [URL0][URL1][URL2]...
        const uint8_t* longURL = tokens_buf + i * MAX_LEN;
        uint8_t* dstp = out_buf + i * MAX_LEN;
        
        //----------------------------------------------------------------------
        // 1️⃣ Lookup in map (lock-free read with atomic)
        //----------------------------------------------------------------------
        int found = find_url(map, longURL);
        
        if (found >= 0) {
            // Reuse existing short URL
            for (int j = 0; j < MAX_LEN; ++j) {
                uint8_t h = map.shortURLs[found][j];
                dstp[j] = h;
                if (h == 0) break;
            }
            
            int64_t end_time = get_clock_cycles();
            lane_end_times[i] = end_time;
            continue;
        }
        
        //----------------------------------------------------------------------
        // 2️⃣ Copy HOSTNAME
        //----------------------------------------------------------------------
        for (int j = 0; j < host_len && j < MAX_LEN - 1; ++j) {
            dstp[j] = HOSTNAME[j];
        }
        
        //----------------------------------------------------------------------
        // 3️⃣ Generate hash and convert to base-62
        //----------------------------------------------------------------------
        uint64_t id = hash_djb2(longURL);
        
        uint8_t* dst_tokp = dstp + host_len;
        
        if (id == 0) {
            *dst_tokp++ = alphabet[0];
        } else {
            // Convert to base-62 (same as ISPC version)
            for (int j = 0; j < MAX_LEN - 1 && id > 0; ++j) {
                uint64_t q = id / 62ull;
                uint64_t r = id - q * 62ull;
                *dst_tokp++ = alphabet[r];
                id = q;
            }
        }
        
        // Terminate encoded token
        *dst_tokp = 0;
        
        //----------------------------------------------------------------------
        // 4️⃣ Terminate safely
        //----------------------------------------------------------------------
        out_buf[i * MAX_LEN + (MAX_LEN - 1)] = 0;
        
        //----------------------------------------------------------------------
        // 5️⃣ Insert into map (thread-safe)
        //----------------------------------------------------------------------
        insert_into_map(map, longURL, dstp);
        
        int64_t end_time = get_clock_cycles();
        lane_end_times[i] = end_time;
    }
}

// Main multithreaded batch function (matching ISPC interface)
void concat_batch(URLMap& map,
                  const uint8_t* HOSTNAME,
                  const uint8_t* tokens_buf,
                  const int* offsets,  // Not used in MT version (assumed sequential layout)
                  int N,
                  uint8_t* out_buf,
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
    
    // Calculate hostname length
    int host_len = ustrlen(HOSTNAME, MAX_LEN);
    if (host_len >= MAX_LEN) host_len = MAX_LEN - 1;
    
    // Get actual number of workers in the pool
    int actual_workers = g_thread_pool->get_num_workers();
    
    // Calculate work distribution per worker
    int items_per_thread = (N + actual_workers - 1) / actual_workers;
    
    // Execute work using thread pool
    g_thread_pool->execute([&](int worker_id) {
        int start_idx = worker_id * items_per_thread;
        int end_idx = std::min(start_idx + items_per_thread, N);
        
        if (start_idx < N) {
            ProcessUrlRange(map, HOSTNAME, host_len,
                          tokens_buf,
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
