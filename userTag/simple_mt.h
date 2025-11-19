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
#include <cstring>
#include "../ThreadPool.h"

#define MAX_ENTRIES   4096
#define MAX_KEY_LEN   32

namespace mt {

//--------------------------------------------------
// Data structures (same as ISPC)
//--------------------------------------------------
#define HASH_TABLE_SIZE_MT 8192

struct NotificationMap {
    uint8_t keys[MAX_ENTRIES][MAX_KEY_LEN];
    int64_t values[MAX_ENTRIES];
    std::atomic<int> next_slot{0};   // Atomic for thread-safe insertions
    
    // Hash table: stores [head_index, tail_index] for each username
    std::atomic<int> hashTable[HASH_TABLE_SIZE_MT][2];
    
    // Linked list: nextIndices[i] points to next notification for same user (-1 = end)
    std::atomic<int> nextIndices[MAX_ENTRIES];
    
    // Store hash values for collision detection
    uint64_t hashValues[MAX_ENTRIES];
};

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

// Global thread pool
static ThreadPool* g_thread_pool = nullptr;
static ThreadPool::Mode g_thread_pool_mode = ThreadPool::POOL_MODE;
static int g_num_threads = 0;

// Initialize thread pool
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

// Cleanup thread pool
void DestroyThreadPool() {
    if (g_thread_pool) {
        delete g_thread_pool;
        g_thread_pool = nullptr;
    }
}

//--------------------------------------------------
// Helper functions (same algorithms as ISPC)
//--------------------------------------------------

// String equality check
inline bool ustrcmp_eq(const uint8_t* a, const uint8_t* b) {
    for (int i = 0; i < MAX_KEY_LEN; i++) {
        uint8_t ca = a[i];
        uint8_t cb = b[i];
        if (ca != cb) return false;
        if (ca == 0 || cb == 0) break;
    }
    return true;
}

// DJB2 hash function for username
inline uint64_t hash_username(const uint8_t* username) {
    uint64_t h = 5381ul;
    for (int j = 0; j < MAX_KEY_LEN; ++j) {
        uint8_t b = username[j];
        if (b == 0) break;
        h = ((h << 5) + h) + b;
    }
    return h;
}

//--------------------------------------------------
// Insert: append new key–value pair (thread-safe with hash table)
//--------------------------------------------------
inline void insert_map(NotificationMap& map,
                      const uint8_t* key,
                      int64_t value) {
    // Atomic increment to get slot
    int slot = map.next_slot.fetch_add(1);
    
    if (slot >= MAX_ENTRIES) {
        return; // Map full
    }
    
    // Initialize next pointer to -1 (end of list)
    map.nextIndices[slot].store(-1, std::memory_order_relaxed);
    
    // Compute hash for this username
    uint64_t username_hash = hash_username(key);
    map.hashValues[slot] = username_hash;
    
    // Copy key
    for (int j = 0; j < MAX_KEY_LEN; j++) {
        uint8_t c = key[j];
        map.keys[slot][j] = c;
        if (c == 0) break;
    }
    
    map.values[slot] = value;
    
    // Insert into hash table with linked list
    int hash_idx = (int)(username_hash & (HASH_TABLE_SIZE_MT - 1));
    
    // Try to update the tail pointer
    int old_tail = map.hashTable[hash_idx][1].load(std::memory_order_relaxed);
    
    while (true) {
        if (old_tail == -1) {
            // List is empty, try to set both head and tail
            int expected = -1;
            if (map.hashTable[hash_idx][0].compare_exchange_weak(expected, slot, std::memory_order_release)) {
                map.hashTable[hash_idx][1].store(slot, std::memory_order_release);
                break;
            }
            // Retry
            old_tail = map.hashTable[hash_idx][1].load(std::memory_order_relaxed);
        } else {
            // List exists, append to tail
            if (map.hashTable[hash_idx][1].compare_exchange_weak(old_tail, slot, std::memory_order_release)) {
                // Update the old tail's next pointer
                map.nextIndices[old_tail].store(slot, std::memory_order_release);
                break;
            }
            // CAS failed, old_tail was updated by CAS, retry with new value
        }
    }
}

//--------------------------------------------------
// Worker function for userMention insertion
//--------------------------------------------------
void ProcessUserMentionRange(NotificationMap& map,
                             const uint8_t* usernames_flat,
                             const int* start_idx,
                             const int* num_per_post,
                             const int64_t* postIDs,
                             int begin_idx,
                             int end_idx,
                             int64_t* lane_start_times,
                             int64_t* lane_end_times,
                             int64_t global_start_time) {
    
    for (int i = begin_idx; i < end_idx; i++) {
        // Record actual start time
        int64_t actual_start_time = get_clock_cycles();
        
        int64_t post = postIDs[i];
        int start = start_idx[i];
        int count = num_per_post[i];
        
        // Insert all usernames for this post
        for (int u = 0; u < count; u++) {
            const uint8_t* uname = &usernames_flat[(start + u) * MAX_KEY_LEN];
            insert_map(map, uname, post);
        }
        
        int64_t end_time = get_clock_cycles();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}

//--------------------------------------------------
// Multithreaded userMention_flat_batch
//--------------------------------------------------
void userMention_flat_batch(NotificationMap& map,
                            const uint8_t* usernames_flat,
                            const int* start_idx,
                            const int* num_per_post,
                            const int64_t* postIDs,
                            int N,
                            int64_t* lane_start_times,
                            int64_t* lane_end_times,
                            int64_t& global_start_time,
                            int num_threads = 0) {
    
    // Initialize thread pool if not already done
    if (!g_thread_pool || (num_threads > 0 && num_threads != g_num_threads)) {
        InitThreadPool(num_threads);
    }
    
    // Capture global start time
    global_start_time = get_clock_cycles();
    
    // Get actual number of workers
    int actual_workers = g_thread_pool->get_num_workers();
    
    // Calculate work distribution
    int items_per_thread = (N + actual_workers - 1) / actual_workers;
    
    // Execute work using thread pool
    g_thread_pool->execute([&](int worker_id) {
        int begin_idx = worker_id * items_per_thread;
        int end_idx = std::min(begin_idx + items_per_thread, N);
        
        if (begin_idx < N) {
            ProcessUserMentionRange(map, usernames_flat,
                                   start_idx, num_per_post, postIDs,
                                   begin_idx, end_idx,
                                   lane_start_times, lane_end_times,
                                   global_start_time);
        }
    }, actual_workers);
}

//--------------------------------------------------
// Worker function for getMentionNotifications lookup (with hash table)
//--------------------------------------------------
void ProcessGetNotificationsRange(const NotificationMap& map,
                                  const uint8_t* usernames,
                                  int begin_idx,
                                  int end_idx,
                                  int64_t* out_posts,
                                  int max_posts,
                                  int* out_counts,
                                  int64_t* lane_start_times,
                                  int64_t* lane_end_times,
                                  int64_t global_start_time) {
    
    for (int i = begin_idx; i < end_idx; i++) {
        // Record actual start time
        int64_t actual_start_time = get_clock_cycles();
        
        const uint8_t* uname = &usernames[i * MAX_KEY_LEN];
        int base = i * max_posts;
        int found = 0;
        
        // Use hash table to find notifications for this user
        uint64_t username_hash = hash_username(uname);
        int hash_idx = (int)(username_hash & (HASH_TABLE_SIZE_MT - 1));
        int head = map.hashTable[hash_idx][0].load(std::memory_order_acquire);
        
        // Traverse linked list of notifications for this user
        int current = head;
        while (current != -1 && found < max_posts) {
            // Verify hash matches to handle collisions
            if (map.hashValues[current] == username_hash && 
                ustrcmp_eq(&map.keys[current][0], uname)) {
                out_posts[base + found] = map.values[current];
                found++;
            }
            
            // Follow the linked list
            current = map.nextIndices[current].load(std::memory_order_acquire);
        }
        
        out_counts[i] = found;
        
        int64_t end_time = get_clock_cycles();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}

//--------------------------------------------------
// Multithreaded getMentionNotifications_batch
//--------------------------------------------------
void getMentionNotifications_batch(const NotificationMap& map,
                                   const uint8_t* usernames,
                                   int N,
                                   int64_t* out_posts,
                                   int max_posts,
                                   int* out_counts,
                                   int64_t* lane_start_times,
                                   int64_t* lane_end_times,
                                   int64_t& global_start_time,
                                   int num_threads = 0) {
    
    // Initialize thread pool if not already done
    if (!g_thread_pool || (num_threads > 0 && num_threads != g_num_threads)) {
        InitThreadPool(num_threads);
    }
    
    // Capture global start time
    global_start_time = get_clock_cycles();
    
    // Get actual number of workers
    int actual_workers = g_thread_pool->get_num_workers();
    
    // Calculate work distribution
    int items_per_thread = (N + actual_workers - 1) / actual_workers;
    
    // Execute work using thread pool
    g_thread_pool->execute([&](int worker_id) {
        int begin_idx = worker_id * items_per_thread;
        int end_idx = std::min(begin_idx + items_per_thread, N);
        
        if (begin_idx < N) {
            ProcessGetNotificationsRange(map, usernames,
                                        begin_idx, end_idx,
                                        out_posts, max_posts, out_counts,
                                        lane_start_times, lane_end_times,
                                        global_start_time);
        }
    }, actual_workers);
}

} // namespace mt

#endif // SIMPLE_MT_H
