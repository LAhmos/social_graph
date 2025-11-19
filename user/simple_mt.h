#ifndef USER_SIMPLE_MT_H
#define USER_SIMPLE_MT_H

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

// Same custom epoch as ISPC version
#define CUSTOM_EPOCH 1514764800000
#define MAX_USERS 1024
#define MAX_FIELD 32

namespace mt {

// User struct matching ISPC version
struct User {
    uint8_t first_name[MAX_FIELD];
    uint8_t last_name[MAX_FIELD];
    uint8_t username[MAX_FIELD];
    uint8_t date_birth[MAX_FIELD];
    uint8_t password_hashed[65];  // 64 hex chars + '\0'
    int64_t user_id;              // numeric unique ID
};

// UserMap struct matching ISPC version with hash table
#define HASH_TABLE_SIZE_MT 2048

struct UserMap {
    uint8_t usernames[MAX_USERS][MAX_FIELD];  // keys
    User users[MAX_USERS];                     // values
    std::atomic<int> count{0};                 // number of entries (atomic for thread safety)
    
    // Hash table for O(1) lookup
    std::atomic<int> hashTable[HASH_TABLE_SIZE_MT];  // maps hash -> entry_index (-1 means empty)
    uint64_t hashValues[MAX_USERS];                  // Store hash for each entry to handle collisions
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
inline int64_t get_timestamp_ns() {
    auto now = std::chrono::high_resolution_clock::now();
    return std::chrono::duration_cast<std::chrono::nanoseconds>(
        now.time_since_epoch()).count();
}

// Get timestamp in CPU cycles (using RDTSC)
inline int64_t get_timestamp_cycles() {
    return (int64_t)rdtsc_start();
}

// Global thread pool
static ThreadPool* g_thread_pool = nullptr;
static int g_num_threads = 0;
static ThreadPool::Mode g_thread_pool_mode = ThreadPool::POOL_MODE;

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

// Generate unique ID (same algorithm as ISPC version)
inline int64_t generate_unique_id(const uint8_t* machine_id, int machine_len, int i) {
    uint8_t out_buf[32];
    
    // Generate pseudo-timestamp and lane counter
    int64_t timestamp = get_timestamp_ns() + (int64_t)i;
    int counter = i;
    
    // Convert timestamp -> 10-digit hex (ASCII-based)
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
    
    // Convert counter -> 3-digit hex (ASCII-based)
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
    
    // Build final ID string in buffer
    uint8_t* dst = out_buf;
    
    for (int j = 0; j < machine_len; ++j) {
        *dst++ = machine_id[j];
    }
    
    for (int j = 0; j < timestamp_hex_len; ++j) {
        *dst++ = timestamp_hex[j];
    }
    
    for (int j = 0; j < counter_hex_len; ++j) {
        *dst++ = counter_hex[j];
    }
    
    *dst = 0;
    
    // Convert hex string to int64
    int id_len = machine_len + timestamp_hex_len + counter_hex_len;
    uint64_t id_value = 0;
    
    for (int j = 0; j < id_len; j++) {
        uint8_t c = out_buf[j];
        
        int64_t v;
        if (c >= 48 && c <= 57)           // 0-9
            v = (int64_t)(c - 48);
        else if (c >= 97 && c <= 102)     // a-f
            v = (int64_t)(c - 97 + 10);
        else if (c >= 65 && c <= 70)      // A-F
            v = (int64_t)(c - 65 + 10);
        else
            break;
        
        id_value = (id_value << 4) | v;
    }
    
    // Apply mask
    id_value = id_value & 0x7FFFFFFFFFFFFFFF;
    return id_value;
}

// Hash function (FNV-1a based, matching ISPC version)
inline void hash256_hex_placeholder(const uint8_t* s, uint8_t* out64) {
    uint64_t h = 1469598103934665603ULL;
    uint64_t p = 1099511628211ULL;
    
    int len = 0;
    while (s[len] != 0) len++;
    
    for (int i = 0; i < len; ++i) {
        h ^= (uint64_t)s[i];
        h *= p;
    }
    
    // Expand to 64 hex chars
    uint64_t x = h;
    for (int j = 0; j < 64; ++j) {
        if ((j & 7) == 0 && j) x = x * 6364136223846793005ULL + 1ULL;
        int shift = (j & 7) * 8;
        int nib = (int)((x >> shift) & 0xF);
        out64[j] = (uint8_t)(nib < 10 ? (48 + nib) : (97 + (nib - 10)));
    }
    out64[64] = 0;
}

// Hash function for usernames (DJB2)
inline uint64_t hash_username(const uint8_t* username) {
    uint64_t h = 5381ul;
    for (int j = 0; j < MAX_FIELD; ++j) {
        uint8_t b = username[j];
        if (b == 0) break;
        h = ((h << 5) + h) + b;
    }
    return h;
}

// String comparison
inline bool strcmp_eq(const uint8_t* a, const uint8_t* b, uint32_t len) {
    for (uint32_t j = 0; j < len; ++j) {
        uint8_t ca = a[j];
        uint8_t cb = b[j];
        if (ca != cb) return false;
        if (ca == 0 || cb == 0) break;
    }
    return true;
}

// Find user by username (hash table based)
inline int find_user(UserMap& map, const uint8_t* username) {
    // Compute hash of the username
    uint64_t username_hash = hash_username(username);
    
    // Use hash table for O(1) lookup
    int hash_idx = (int)(username_hash & (HASH_TABLE_SIZE_MT - 1));  // Fast modulo
    
    // Linear probing
    for (int probe = 0; probe < 8; ++probe) {
        int entry_idx = map.hashTable[hash_idx].load(std::memory_order_acquire);
        
        if (entry_idx == -1) {
            // Empty slot, not found
            return -1;
        }
        
        // Check if hash matches and then verify the actual string
        if (map.hashValues[entry_idx] == username_hash) {
            if (strcmp_eq(&map.usernames[entry_idx][0], username, MAX_FIELD)) {
                return entry_idx;  // Found!
            }
        }
        
        // Collision, try next slot
        hash_idx = (hash_idx + 1) & (HASH_TABLE_SIZE_MT - 1);
    }
    
    return -1;  // Not found after max probes
}

// Mutex for map insertion (to prevent race conditions)
static std::mutex g_map_insert_mutex;

// Insert into user map (with duplicate check inside lock to prevent TOCTOU)
// Atomically check for duplicate and insert if not exists
// Returns true if inserted, false if duplicate or capacity exceeded
inline bool insert_into_user_map_if_not_exists(UserMap& map, const uint8_t* username, const User& user) {
    // Use mutex to make check-and-insert atomic
    std::lock_guard<std::mutex> lock(g_map_insert_mutex);
    
    // Check for duplicate using hash table
    int existing = find_user(map, username);
    if (existing != -1) {
        return false;  // Username already exists (duplicate)
    }
    
    // Not a duplicate - reserve the next slot
    int slot = map.count.load(std::memory_order_relaxed);
    
    // Check if we exceeded capacity
    if (slot >= MAX_USERS) {
        return false;
    }
    
    // Compute hash for this username
    uint64_t username_hash = hash_username(username);
    
    // Store hash value for collision detection
    map.hashValues[slot] = username_hash;
    
    // Write data FIRST before making it visible via hash table
    // This ensures other threads doing lookups will see complete data
    
    // Copy username key
    for (int j = 0; j < MAX_FIELD; ++j) {
        uint8_t c = username[j];
        map.usernames[slot][j] = c;
        if (c == 0) break;
    }
    
    // Copy user struct
    map.users[slot] = user;
    
    // NOW increment count (this makes the slot visible to count-based iterations)
    map.count.fetch_add(1, std::memory_order_release);
    
    // Insert into hash table with linear probing
    // This is done LAST to ensure data is written before hash table points to it
    int hash_idx = (int)(username_hash & (HASH_TABLE_SIZE_MT - 1));
    for (int probe = 0; probe < 8; ++probe) {
        int expected = -1;
        int current = map.hashTable[hash_idx].load(std::memory_order_relaxed);
        if (current == -1) {
            // Try to claim this slot
            if (map.hashTable[hash_idx].compare_exchange_strong(expected, slot, std::memory_order_release)) {
                // Successfully inserted
                break;
            }
        }
        // Collision, try next slot
        hash_idx = (hash_idx + 1) & (HASH_TABLE_SIZE_MT - 1);
    }
    
    return true;
}

// Simple insert without duplicate checking (for cases where duplicate check already done)
inline bool insert_into_user_map(UserMap& map, const uint8_t* username, const User& user) {
    // Atomically reserve a slot (like ISPC's atomic_add_global)
    int slot = map.count.fetch_add(1, std::memory_order_relaxed);
    
    // Check if we exceeded capacity
    if (slot >= MAX_USERS) {
        // Rollback the increment
        map.count.fetch_sub(1, std::memory_order_relaxed);
        return false;
    }
    
    // Copy username key
    for (int j = 0; j < MAX_FIELD; ++j) {
        uint8_t c = username[j];
        map.usernames[slot][j] = c;
        if (c == 0) break;
    }
    
    // Copy user struct
    map.users[slot] = user;
    
    return true;
}

// Worker function for newUser_batch
void ProcessNewUserRange(const uint8_t* machine_id, int machine_len,
                         int start_idx, int end_idx,
                         const uint8_t* first_names,
                         const uint8_t* last_names,
                         const uint8_t* usernames,
                         const uint8_t* passwords,
                         const uint8_t* dates_birth,
                         User* users,
                         UserMap& map,
                         int64_t* lane_start_times,
                         int64_t* lane_end_times,
                         int64_t global_start_time) {
    
    constexpr int stride = 32;
    
    for (int i = start_idx; i < end_idx; i++) {
        // Capture start time as absolute timestamp (will be converted to relative in main)
        int64_t actual_start_time = get_timestamp_cycles();
        
        // Generate unique ID
        int64_t uid = generate_unique_id(machine_id, machine_len, i);
        users[i].user_id = uid;
        
        // Hash password
        const uint8_t* pass = &passwords[i * stride];
        hash256_hex_placeholder(pass, &users[i].password_hashed[0]);
        
        // Copy other fields
        const uint8_t* fn_ptr = &first_names[i * stride];
        const uint8_t* ln_ptr = &last_names[i * stride];
        const uint8_t* un_ptr = &usernames[i * stride];
        const uint8_t* db_ptr = &dates_birth[i * stride];
        
        // Copy all fields to local user struct first
        User local_user = users[i];  // Copy struct including user_id and password_hash
        std::memcpy(&local_user.first_name[0], fn_ptr, MAX_FIELD);
        std::memcpy(&local_user.last_name[0], ln_ptr, MAX_FIELD);
        std::memcpy(&local_user.username[0], un_ptr, MAX_FIELD);
        std::memcpy(&local_user.date_birth[0], db_ptr, MAX_FIELD);
        
        // Copy back to output array
        users[i] = local_user;
        
        // Atomically check for duplicate and insert (like ISPC does)
        insert_into_user_map_if_not_exists(map, &local_user.username[0], local_user);
        
        // Capture end time as absolute timestamp (will be converted to relative in main)
        int64_t end_time = get_timestamp_cycles();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}

// Main multithreaded newUser_batch function
void newUser_batch(int N,
                   const uint8_t* machine_id,
                   int machine_len,
                   const uint8_t* first_names,
                   const uint8_t* last_names,
                   const uint8_t* usernames,
                   const uint8_t* passwords,
                   const uint8_t* dates_birth,
                   User* users,
                   UserMap& map,
                   int64_t* lane_start_times,
                   int64_t* lane_end_times,
                   int64_t& global_start_time,
                   int num_threads = 0) {
    
    // Initialize thread pool if needed
    if (!g_thread_pool || (num_threads > 0 && num_threads != g_num_threads)) {
        InitThreadPool(num_threads);
    }
    
    // Capture global start
    global_start_time = get_timestamp_cycles();
    
    int actual_workers = g_thread_pool->get_num_workers();
    int items_per_thread = (N + actual_workers - 1) / actual_workers;
    
    // Execute work
    g_thread_pool->execute([&](int worker_id) {
        int start_idx = worker_id * items_per_thread;
        int end_idx = std::min(start_idx + items_per_thread, N);
        
        if (start_idx < N) {
            ProcessNewUserRange(machine_id, machine_len,
                              start_idx, end_idx,
                              first_names, last_names, usernames,
                              passwords, dates_birth,
                              users, map,
                              lane_start_times, lane_end_times,
                              global_start_time);
        }
    }, actual_workers);
}

// Worker function for login_batch
void ProcessLoginRange(UserMap& map,
                       int start_idx, int end_idx,
                       const uint8_t* usernames,
                       const uint8_t* passwords,
                       int* login_results,
                       int64_t* lane_start_times,
                       int64_t* lane_end_times,
                       int64_t global_start_time) {
    
    constexpr int stride = 32;
    
    for (int i = start_idx; i < end_idx; i++) {
        // Capture start time as absolute timestamp (will be converted to relative in main)
        int64_t actual_start_time = get_timestamp_cycles();
        
        const uint8_t* uname = &usernames[i * stride];
        const uint8_t* pass = &passwords[i * stride];
        
        // Lookup username
        int idx = find_user(map, uname);
        if (idx == -1) {
            login_results[i] = 0;
            int64_t end_time = get_timestamp_cycles();
            lane_start_times[i] = actual_start_time;
            lane_end_times[i] = end_time;
            continue;
        }
        
        // Hash entered password
        uint8_t entered_hash[65];
        hash256_hex_placeholder(pass, entered_hash);
        
        // Compare hashes
        const uint8_t* stored_hash = &map.users[idx].password_hashed[0];
        bool match = strcmp_eq(entered_hash, stored_hash, 64);
        
        login_results[i] = match ? 1 : 0;
        
        int64_t end_time = get_timestamp_cycles();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}

// Main multithreaded login_batch function
void login_batch(UserMap& map,
                 const uint8_t* usernames,
                 const uint8_t* passwords,
                 int N,
                 int* login_results,
                 int64_t* lane_start_times,
                 int64_t* lane_end_times,
                 int64_t& global_start_time,
                 int num_threads = 0) {
    
    // Initialize thread pool if needed
    if (!g_thread_pool || (num_threads > 0 && num_threads != g_num_threads)) {
        InitThreadPool(num_threads);
    }
    
    // Capture global start
    global_start_time = get_timestamp_cycles();
    
    int actual_workers = g_thread_pool->get_num_workers();
    int items_per_thread = (N + actual_workers - 1) / actual_workers;
    
    // Execute work
    g_thread_pool->execute([=, &map, &global_start_time](int worker_id) {
        int start_idx = worker_id * items_per_thread;
        int end_idx = std::min(start_idx + items_per_thread, N);
        
        if (start_idx < N) {
            ProcessLoginRange(map, start_idx, end_idx,
                            usernames, passwords,
                            login_results,
                            lane_start_times, lane_end_times,
                            global_start_time);
        }
    }, actual_workers);
}

} // namespace mt

#endif // USER_SIMPLE_MT_H
