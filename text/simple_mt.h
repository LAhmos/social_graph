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

#define MAX_TEXT_LEN   256
#define MAX_MENTIONS   16
#define MAX_URLS       16
#define MAX_URL_LEN    128

namespace mt {

//--------------------------------------------------
// Data structures (same as ISPC)
//--------------------------------------------------
struct TextResult {
    int    num_mentions;
    int    num_urls;
    uint8_t  updated_text[MAX_TEXT_LEN];
    uint8_t  mentions[MAX_MENTIONS][64];
    uint8_t  urls[MAX_URLS][MAX_URL_LEN];
    uint8_t  shortened_urls[MAX_URLS][MAX_URL_LEN];
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

// Base62 encode for URL shortening
static void idToShortURL(int64_t n, uint8_t* out_buf) {
    uint8_t temp[64];
    int len = 0;
    
    if (n == 0) {
        out_buf[0] = 97; // 'a'
        out_buf[1] = 0;
        return;
    }
    
    while (n > 0 && len < 63) {
        int64_t remainder = n % 62;
        if (remainder < 26) {
            temp[len++] = 97 + remainder; // 'a' to 'z'
        } else if (remainder < 52) {
            temp[len++] = 65 + (remainder - 26); // 'A' to 'Z'
        } else {
            temp[len++] = 48 + (remainder - 52); // '0' to '9'
        }
        n = n / 62;
    }
    
    // Reverse
    for (int i = 0; i < len; i++) {
        out_buf[i] = temp[len - 1 - i];
    }
    out_buf[len] = 0;
}

// Hash URL
static int64_t hashURL(const uint8_t* url, int len) {
    int64_t hash = 5381;
    for (int i = 0; i < len; i++) {
        hash = ((hash << 5) + hash) + url[i];
    }
    return hash & 0x7FFFFFFFFFFFFFFF;
}

// String length helper
static int strlen_mt(const uint8_t* str) {
    int len = 0;
    while (str[len] != 0 && len < MAX_URL_LEN) {
        len++;
    }
    return len;
}

// Memory copy helper
static void memcpy_mt(uint8_t* dest, const uint8_t* src, int n) {
    for (int i = 0; i < n; i++) {
        dest[i] = src[i];
    }
}

//--------------------------------------------------
// Process single text - INLINED VERSION (matches ISPC structure)
//--------------------------------------------------

//--------------------------------------------------
// Worker function for batch processing - FULLY INLINED (matches ISPC)
//--------------------------------------------------
void ProcessTextRange(const uint8_t* texts,
                      int start_idx,
                      int end_idx,
                      TextResult* results,
                      int64_t* lane_start_times,
                      int64_t* lane_end_times,
                      int64_t global_start_time) {
    
    for (int i = start_idx; i < end_idx; i++) {
        // ===== INLINED PROCESSING - NO FUNCTION CALL (matches ISPC structure) =====
        
        // Start timing
        int64_t start_time = get_clock_cycles();
        
        // Calculate text length
        int text_len = 0;
        int offset = i * MAX_TEXT_LEN;
        
        for (int j = 0; j < MAX_TEXT_LEN; j++) {
            if (texts[offset + j] == 0) {
                text_len = j;
                break;
            }
        }
        if (text_len == 0) text_len = MAX_TEXT_LEN;
        
        int base_offset = i * MAX_TEXT_LEN;
        
        // Initialize result counts
        int num_mentions = 0;
        int num_urls = 0;
        
        // ===== MENTION EXTRACTION =====
        for (int idx = 0; idx < MAX_TEXT_LEN; idx++) {
            uint8_t current_char = texts[base_offset + idx];
            bool found_at = (current_char == 64) && (idx < text_len) && (num_mentions < MAX_MENTIONS);
            
            if (found_at) {
                int mention_start = idx + 1;
                int mention_end = mention_start;
                
                // Find end of mention
                for (int scan = mention_start; scan < text_len && scan < mention_start + 63; scan++) {
                    uint8_t c = texts[base_offset + scan];
                    bool is_delimiter = (c == 32 || c == 44 || c == 0 || c == 10 || c == 13);
                    
                    if (!is_delimiter && mention_end == scan) {
                        mention_end = scan + 1;
                    }
                }
                
                int mention_len = mention_end - mention_start;
                bool valid_mention = found_at && (mention_len > 0) && (mention_len < 63);
                
                if (valid_mention) {
                    // Copy mention
                    for (int k = 0; k < mention_len; k++) {
                        results[i].mentions[num_mentions][k] = texts[base_offset + mention_start + k];
                    }
                    results[i].mentions[num_mentions][mention_len] = 0;
                    num_mentions++;
                }
            }
        }
        
        results[i].num_mentions = num_mentions;
        
        // ===== URL EXTRACTION AND HASHING =====
        for (int idx = 0; idx < MAX_TEXT_LEN - 8; idx++) {
            int check_offset = base_offset + idx;
            
            // Check for "http://" or "https://"
            bool is_http = (idx + 7 <= text_len) &&
                           (texts[check_offset] == 104) && (texts[check_offset+1] == 116) && 
                           (texts[check_offset+2] == 116) && (texts[check_offset+3] == 112) &&
                           (texts[check_offset+4] == 58) && (texts[check_offset+5] == 47) && 
                           (texts[check_offset+6] == 47);
            
            bool is_https = (idx + 8 <= text_len) &&
                            (texts[check_offset] == 104) && (texts[check_offset+1] == 116) && 
                            (texts[check_offset+2] == 116) && (texts[check_offset+3] == 112) &&
                            (texts[check_offset+4] == 115) && (texts[check_offset+5] == 58) &&
                            (texts[check_offset+6] == 47) && (texts[check_offset+7] == 47);
            
            bool found_url = (is_http || is_https) && (num_urls < MAX_URLS);
            
            if (found_url) {
                int url_start = idx;
                int url_end = url_start;
                
                // Find end of URL
                for (int scan = url_start; scan < text_len && scan < url_start + MAX_URL_LEN; scan++) {
                    uint8_t c = texts[base_offset + scan];
                    bool is_delimiter = (c == 32 || c == 44 || c == 0 || c == 10 || c == 13);
                    
                    if (!is_delimiter && url_end == scan) {
                        url_end = scan + 1;
                    }
                }
                
                int url_len = url_end - url_start;
                bool valid_url = found_url && (url_len > 0) && (url_len < MAX_URL_LEN - 1);
                
                if (valid_url) {
                    // Hash URL
                    int64_t url_hash = hashURL(&texts[base_offset + url_start], url_len);
                    
                    // Generate Base62 encoded ID
                    uint8_t short_id[64];
                    idToShortURL(url_hash, short_id);
                    
                    // Store original URL
                    for (int k = 0; k < url_len; k++) {
                        results[i].urls[num_urls][k] = texts[base_offset + url_start + k];
                    }
                    results[i].urls[num_urls][url_len] = 0;
                    
                    // Build shortened URL
                    uint8_t hostname[17];
                    hostname[0] = 104; hostname[1] = 116; hostname[2] = 116; hostname[3] = 112;
                    hostname[4] = 58; hostname[5] = 47; hostname[6] = 47;
                    hostname[7] = 115; hostname[8] = 104; hostname[9] = 111; hostname[10] = 114;
                    hostname[11] = 116; hostname[12] = 45; hostname[13] = 117; hostname[14] = 114;
                    hostname[15] = 108; hostname[16] = 47;
                    
                    for (int h = 0; h < 17; h++) {
                        results[i].shortened_urls[num_urls][h] = hostname[h];
                    }
                    
                    // Find short_id length
                    int short_id_len = 0;
                    for (int k = 0; k < 63; k++) {
                        if (short_id[k] == 0) {
                            short_id_len = k;
                            break;
                        }
                    }
                    if (short_id_len == 0) short_id_len = 63;
                    
                    // Copy short_id
                    for (int k = 0; k < short_id_len; k++) {
                        results[i].shortened_urls[num_urls][17 + k] = short_id[k];
                    }
                    results[i].shortened_urls[num_urls][17 + short_id_len] = 0;
                    
                    num_urls++;
                }
            }
        }
        
        results[i].num_urls = num_urls;
        
        // ===== BUILD UPDATED TEXT =====
        if (num_urls > 0) {
            int out_idx = 0;
            int text_idx = 0;
            int url_count = 0;
            
            while (text_idx < text_len && out_idx < MAX_TEXT_LEN - 1) {
                bool is_http = (text_idx + 7 <= text_len &&
                               texts[base_offset + text_idx] == 104 && 
                               texts[base_offset + text_idx+1] == 116 && 
                               texts[base_offset + text_idx+2] == 116 && 
                               texts[base_offset + text_idx+3] == 112 && 
                               texts[base_offset + text_idx+4] == 58 && 
                               texts[base_offset + text_idx+5] == 47 && 
                               texts[base_offset + text_idx+6] == 47);
                
                bool is_https = (text_idx + 8 <= text_len &&
                                texts[base_offset + text_idx] == 104 && 
                                texts[base_offset + text_idx+1] == 116 && 
                                texts[base_offset + text_idx+2] == 116 && 
                                texts[base_offset + text_idx+3] == 112 && 
                                texts[base_offset + text_idx+4] == 115 && 
                                texts[base_offset + text_idx+5] == 58 &&
                                texts[base_offset + text_idx+6] == 47 && 
                                texts[base_offset + text_idx+7] == 47);
                
                if ((is_http || is_https) && url_count < num_urls) {
                    // Skip original URL
                    int url_end = text_idx;
                    while (url_end < text_len && 
                           texts[base_offset + url_end] != 32 && 
                           texts[base_offset + url_end] != 44 && 
                           texts[base_offset + url_end] != 0 && 
                           texts[base_offset + url_end] != 10 && 
                           texts[base_offset + url_end] != 13) {
                        url_end++;
                    }
                    
                    // Copy shortened URL
                    int short_len = 0;
                    for (int sl = 0; sl < MAX_URL_LEN; sl++) {
                        if (results[i].shortened_urls[url_count][sl] == 0) {
                            short_len = sl;
                            break;
                        }
                    }
                    if (short_len == 0) short_len = MAX_URL_LEN;
                    
                    if (out_idx + short_len < MAX_TEXT_LEN - 1) {
                        for (int cp = 0; cp < short_len; cp++) {
                            results[i].updated_text[out_idx + cp] = results[i].shortened_urls[url_count][cp];
                        }
                        out_idx += short_len;
                    }
                    
                    text_idx = url_end;
                    url_count++;
                } else {
                    results[i].updated_text[out_idx] = texts[base_offset + text_idx];
                    out_idx++;
                    text_idx++;
                }
            }
            results[i].updated_text[out_idx] = 0;
        } else {
            // No URLs, copy original text
            int copy_len = (text_len < MAX_TEXT_LEN - 1) ? text_len : (MAX_TEXT_LEN - 1);
            for (int cp = 0; cp < copy_len; cp++) {
                results[i].updated_text[cp] = texts[base_offset + cp];
            }
            results[i].updated_text[copy_len] = 0;
        }
        
        // End timing
        int64_t end_time = get_clock_cycles();
        
        // Store timing results
        lane_start_times[i] = start_time;
        lane_end_times[i] = end_time;
    }
}

//--------------------------------------------------
// Multithreaded processText_batch
//--------------------------------------------------
void processText_batch(const uint8_t* texts,
                       int N,
                       TextResult* results,
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
    g_thread_pool->execute([=](int worker_id) {
        int start_idx = worker_id * items_per_thread;
        int end_idx = std::min(start_idx + items_per_thread, N);
        
        if (start_idx < N) {
            ProcessTextRange(texts, start_idx, end_idx,
                           results, lane_start_times, lane_end_times,
                           global_start_time);
        }
    }, actual_workers);
}

} // namespace mt

#endif // SIMPLE_MT_H
