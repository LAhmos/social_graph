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

#define MAX_ENTRIES   4096
#define MAX_POST_LEN  128
#define MAX_RESULTS   16

namespace mt {

//--------------------------------------------------
// Data structures (same as ISPC)
//--------------------------------------------------
struct Post {
    int    user_id;
    int64_t  post_id;
    uint8_t  post_string[MAX_POST_LEN];
};

#define HASH_TABLE_SIZE_MT 8192

struct PostMap {
    int   user_ids[MAX_ENTRIES];
    Post  posts[MAX_ENTRIES];
    std::atomic<int> next_slot{0};
    
    // Hash table: stores [head_index, tail_index] for each user
    std::atomic<int> hashTable[HASH_TABLE_SIZE_MT][2];
    
    // Linked list: nextIndices[i] points to next post by same user (-1 = end)
    std::atomic<int> nextIndices[MAX_ENTRIES];
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

// Get current timestamp in nanoseconds using chrono (kept for compatibility)
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
// Generate unique ID (same algorithm as ISPC)
//--------------------------------------------------
int64_t generate_unique_id(const uint8_t* machine_id, int machine_len, int i) {
    uint8_t out_buf[32];
    
    //----------------------------------------------------------------------
    // Generate pseudo-timestamp and counter
    //----------------------------------------------------------------------
    int64_t timestamp = get_clock() + (int64_t)i;
    int counter = i;
    
    //----------------------------------------------------------------------
    // Convert timestamp -> 10-digit hex (ASCII-based)
    //----------------------------------------------------------------------
    const int timestamp_hex_len = 10;
    uint8_t timestamp_hex[11];
    
    for (int j = 0; j < timestamp_hex_len; ++j) {
        int shift = 4 * (timestamp_hex_len - 1 - j);
        int nib = (timestamp >> shift) & 0xF;
        uint8_t ch;
        if (nib < 10)
            ch = (uint8_t)(48 + nib);
        else
            ch = (uint8_t)(97 + (nib - 10));
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
            ch = (uint8_t)(48 + nib);
        else
            ch = (uint8_t)(97 + (nib - 10));
        counter_hex[j] = ch;
    }
    counter_hex[counter_hex_len] = 0;
    
    //----------------------------------------------------------------------
    // Build final ID string
    //----------------------------------------------------------------------
    // Copy machine_id
    for (int j = 0; j < machine_len; ++j) {
        out_buf[j] = machine_id[j];
    }
    
    // Append timestamp hex
    for (int j = 0; j < timestamp_hex_len; ++j) {
        out_buf[machine_len + j] = timestamp_hex[j];
    }
    
    // Append counter hex
    for (int j = 0; j < counter_hex_len; ++j) {
        out_buf[machine_len + timestamp_hex_len + j] = counter_hex[j];
    }
    
    int offset = machine_len + timestamp_hex_len + counter_hex_len;
    out_buf[offset] = 0;
    
    //----------------------------------------------------------------------
    // Convert generated hex string to int64 (same as ISPC)
    //----------------------------------------------------------------------
    int id_len = machine_len + timestamp_hex_len + counter_hex_len;
    uint64_t id_value = 0;
    
    for (int j = 0; j < id_len; j++) {
        uint8_t c = out_buf[j];
        
        int64_t v;
        if (c >= 48 && c <= 57)             // 0–9
            v = (int64_t)(c - 48);
        else if (c >= 97 && c <= 102)       // a–f
            v = (int64_t)(c - 97 + 10);
        else if (c >= 65 && c <= 70)        // A–F
            v = (int64_t)(c - 65 + 10);
        else
            break;
        
        id_value = (id_value << 4) | v;
    }
    
    // Apply mask
    id_value = id_value & 0x7FFFFFFFFFFFFFFF;
    return id_value;
}

//--------------------------------------------------
// Insert post into PostMap (with hash table and linked list)
//--------------------------------------------------
inline void insert_post(PostMap& map,
                       int user_id,
                       const uint8_t* post_text,
                       int64_t post_id) {
    // Atomic increment to get slot
    int slot = map.next_slot.fetch_add(1);
    
    if (slot >= MAX_ENTRIES) return;
    
    // Initialize next pointer to -1 (end of list)
    map.nextIndices[slot].store(-1, std::memory_order_relaxed);
    
    // Fill entry
    map.user_ids[slot] = user_id;
    map.posts[slot].user_id = user_id;
    map.posts[slot].post_id = post_id;
    
    // Copy post text (truncate if needed)
    for (int j = 0; j < MAX_POST_LEN; j++) {
        map.posts[slot].post_string[j] = post_text[j];
        if (post_text[j] == 0) break;
    }
    
    // Insert into hash table with linked list
    int hash_idx = user_id & (HASH_TABLE_SIZE_MT - 1);
    
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
// Worker function for newPost batch processing
//--------------------------------------------------
void ProcessNewPostRange(PostMap& map,
                        const uint8_t* machine_id,
                        int machine_len,
                        const int* user_ids,
                        const uint8_t* post_texts,
                        int64_t* post_ids,
                        int start_idx,
                        int end_idx,
                        int64_t* lane_start_times,
                        int64_t* lane_end_times,
                        int64_t global_start_time) {
    
    for (int i = start_idx; i < end_idx; i++) {
        // Record actual start time (in CPU cycles)
        int64_t actual_start_time = get_clock_cycles();
        
        int user_id = user_ids[i];
        const uint8_t* post_txt = &post_texts[i * MAX_POST_LEN];
        int64_t post_id = generate_unique_id(machine_id, machine_len, i);
        
        // Store the generated post_id
        post_ids[i] = post_id;
        
        insert_post(map, user_id, post_txt, post_id);
        
        int64_t end_time = get_clock_cycles();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}

//--------------------------------------------------
// Multithreaded newPost_batch
//--------------------------------------------------
void newPost_batch(PostMap& map,
                   const uint8_t* machine_id,
                   int machine_len,
                   const int* user_ids,
                   const uint8_t* post_texts,
                   int64_t* post_ids,
                   int N,
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
    
    // Get actual number of workers
    int actual_workers = g_thread_pool->get_num_workers();
    
    // Calculate work distribution
    int items_per_thread = (N + actual_workers - 1) / actual_workers;
    
    // Execute work using thread pool
    g_thread_pool->execute([&](int worker_id) {
        int start_idx = worker_id * items_per_thread;
        int end_idx = std::min(start_idx + items_per_thread, N);
        
        if (start_idx < N) {
            ProcessNewPostRange(map, machine_id, machine_len,
                              user_ids, post_texts, post_ids,
                              start_idx, end_idx,
                              lane_start_times, lane_end_times,
                              global_start_time);
        }
    }, actual_workers);
}

//--------------------------------------------------
// Worker function for getPostByUser batch processing (with hash table)
//--------------------------------------------------
void ProcessGetPostRange(const PostMap& map,
                        const int* query_user_ids,
                        int start_idx,
                        int end_idx,
                        uint8_t* out_posts,
                        int* out_counts,
                        int64_t* lane_start_times,
                        int64_t* lane_end_times,
                        int64_t global_start_time) {
    
    for (int i = start_idx; i < end_idx; i++) {
        // Record actual start time (in CPU cycles)
        int64_t actual_start_time = get_clock_cycles();
        
        int query_id = query_user_ids[i];
        int found = 0;
        
        // Each request writes to its region in out_posts
        uint8_t* dst = &out_posts[i * MAX_RESULTS * MAX_POST_LEN];
        
        // Use hash table to find posts by this user
        int hash_idx = query_id & (HASH_TABLE_SIZE_MT - 1);
        int head = map.hashTable[hash_idx][0].load(std::memory_order_acquire);
        
        // Traverse linked list of posts by this user
        int current = head;
        while (current != -1 && found < MAX_RESULTS) {
            if (map.user_ids[current] == query_id) {
                // Copy post text
                const uint8_t* src = &map.posts[current].post_string[0];
                uint8_t* dst_post = &dst[found * MAX_POST_LEN];
                
                for (int k = 0; k < MAX_POST_LEN; k++) {
                    dst_post[k] = src[k];
                    if (src[k] == 0) break;
                }
                
                found++;
            }
            
            // Follow the linked list
            current = map.nextIndices[current].load(std::memory_order_acquire);
        }
        
        int64_t end_time = get_clock_cycles();
        out_counts[i] = found;
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}

//--------------------------------------------------
// Multithreaded getPostByUser_batch
//--------------------------------------------------
void getPostByUser_batch(const PostMap& map,
                        const int* query_user_ids,
                        int N,
                        uint8_t* out_posts,
                        int* out_counts,
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
    
    // Get actual number of workers
    int actual_workers = g_thread_pool->get_num_workers();
    
    // Calculate work distribution
    int items_per_thread = (N + actual_workers - 1) / actual_workers;
    
    // Execute work using thread pool
    g_thread_pool->execute([&](int worker_id) {
        int start_idx = worker_id * items_per_thread;
        int end_idx = std::min(start_idx + items_per_thread, N);
        
        if (start_idx < N) {
            ProcessGetPostRange(map, query_user_ids,
                              start_idx, end_idx,
                              out_posts, out_counts,
                              lane_start_times, lane_end_times,
                              global_start_time);
        }
    }, actual_workers);
}

} // namespace mt

#endif // SIMPLE_MT_H
