#define MAX_TEXT_LEN   256
#define MAX_MENTIONS   16
#define MAX_URLS       16
#define MAX_URL_LEN    128

//--------------------------------------------------
// Data structures - FULLY INTERLEAVED for contiguous SIMD access!
//--------------------------------------------------
export struct TextResult {
    uniform int*    num_mentions;           // [N] - array of mention counts
    uniform int*    num_urls;               // [N] - array of URL counts
    uniform uint8*  updated_text;           // [MAX_TEXT_LEN * N] - INTERLEAVED: char j of text i at j*N+i
    uniform uint8*  mentions;               // [MAX_MENTIONS * 64 * N] - INTERLEAVED
    uniform uint8*  urls;                   // [MAX_URLS * MAX_URL_LEN * N] - INTERLEAVED
    uniform uint8*  shortened_urls;         // [MAX_URLS * MAX_URL_LEN * N] - INTERLEAVED
};

//--------------------------------------------------
// Helper functions
//--------------------------------------------------

// Hash URL - VECTORIZED VERSION with FULLY INTERLEAVED layout
// Each SIMD lane hashes a different URL in parallel
static varying int64 hashURL_vectorized(
    uniform const uint8 texts[],
    uniform int N,
    varying int text_id,
    varying int start,
    varying int len
) {
    varying int64 hash = 5381;
    for (varying int i = 0; i < len; i++) {
        varying int char_offset = (start + i) * N + text_id;
        varying uint8 byte_val = texts[char_offset];
        hash = ((hash << 5) + hash) + byte_val;
    }
    return hash & 0x7FFFFFFFFFFFFFFF;
}

//--------------------------------------------------
// Batch kernel: process multiple texts in parallel using VECTORIZATION
// FULLY INLINED - no function call overhead
// INTERLEAVED LAYOUT for contiguous SIMD access!
//--------------------------------------------------
export void processText_batch(
    uniform const uint8 texts[],        // [N * MAX_TEXT_LEN] - INTERLEAVED layout!
    uniform int N,
    uniform TextResult &results,        // SoA structure with pointers to arrays
    uniform int64 lane_start_times[],   // [N] - output
    uniform int64 lane_end_times[],     // [N] - output
    uniform int64 &global_start_time)   // output
{
    // Capture global start time
    global_start_time = clock();
    
    // Process texts in parallel using foreach - processes programCount texts at once
    // With INTERLEAVED layout: char position j for all lanes is at j*programCount + lane_id
    // This enables TRUE vectorization with contiguous memory access!
    foreach (i = 0 ... N) {
        // ===== INLINED PROCESSING - NO FUNCTION CALL =====
        
        // Start timing for this lane
        varying int64 start_time = clock();
        
        // Each lane processes a different text (i)
        // In FULLY INTERLEAVED layout across ALL N texts:
        // Character j of text i is at: j * N + i
        // This allows 8 consecutive texts to read char j with ONE vector load!
        
        // Calculate text length for each lane
        varying int text_len = 0;
        
        for (uniform int j = 0; j < MAX_TEXT_LEN; j++) {
            // FULLY CONTIGUOUS! Text i's char j is at j*N + i
            varying int interleaved_offset = j * N + i;
            if (texts[interleaved_offset] == 0) {
                text_len = j;
                break;
            }
        }
        if (text_len == 0) text_len = MAX_TEXT_LEN;
        
        // Initialize result counts to 0 for each lane - VECTORIZED
        varying int num_mentions = 0;
        varying int num_urls = 0;
        
        // ===== VECTORIZED MENTION EXTRACTION =====
        // Scan through text in parallel across all lanes
        for (uniform int idx = 0; idx < MAX_TEXT_LEN; idx++) {
            // FULLY CONTIGUOUS! Char idx of text i is at idx*N + i
            varying int char_offset = idx * N + i;
            varying uint8 current_char = texts[char_offset];
            varying bool found_at = (current_char == 64) && (idx < text_len) && (num_mentions < MAX_MENTIONS);
            
            if (any(found_at)) {
                // Find mention boundaries in parallel across lanes
                varying int mention_start = idx + 1;
                varying int mention_end = mention_start;
                
                // Vectorized search for end of mention
                for (varying int scan = mention_start; scan < text_len && scan < mention_start + 63; scan++) {
                    varying int scan_offset = scan * N + i;
                    varying uint8 c = texts[scan_offset];
                    varying bool is_delimiter = (c == 32 || c == 44 || c == 0 || c == 10 || c == 13);
                    
                    // Update mention_end only if we haven't found delimiter yet
                    if (!is_delimiter && mention_end == scan) {
                        mention_end = scan + 1;
                    }
                }
                
                // Calculate mention length for each lane
                varying int mention_len = mention_end - mention_start;
                varying bool valid_mention = found_at && (mention_len > 0) && (mention_len < 63);
                
                // Store mentions directly to output - INTERLEAVED!
                if (any(valid_mention)) {
                    // Mention byte k of mention j for text i is at: (j*64 + k) * N + i
                    varying int mention_base = num_mentions * 64 * N;
                    
                    // Direct vectorized copy to output - CONTIGUOUS writes!
                    for (varying int k = 0; k < mention_len; k++) {
                        varying int src_offset = (mention_start + k) * N + i;
                        varying int dest_offset = mention_base + k * N + i;
                        results.mentions[dest_offset] = texts[src_offset];
                    }
                    results.mentions[mention_base + mention_len * N + i] = 0;
                    
                    // Increment counter for lanes that found valid mention
                    if (valid_mention) {
                        num_mentions = num_mentions + 1;
                    }
                }
            }
        }
        
        // Store mention count directly - vectorized write to SoA
        results.num_mentions[i] = num_mentions;
        
        // ===== VECTORIZED URL EXTRACTION AND HASHING =====
        for (uniform int idx = 0; idx < MAX_TEXT_LEN - 8; idx++) {
            // FULLY CONTIGUOUS ACCESS for URL detection
            varying int check_offset = idx * N + i;
            
            // Check for "http://" or "https://" in parallel across lanes
            varying bool is_http = (idx + 7 <= text_len) &&
                           (texts[check_offset] == 104) && 
                           (texts[check_offset + N] == 116) && 
                           (texts[check_offset + 2 * N] == 116) && 
                           (texts[check_offset + 3 * N] == 112) &&
                           (texts[check_offset + 4 * N] == 58) && 
                           (texts[check_offset + 5 * N] == 47) && 
                           (texts[check_offset + 6 * N] == 47);
            
            varying bool is_https = (idx + 8 <= text_len) &&
                            (texts[check_offset] == 104) && 
                            (texts[check_offset + N] == 116) && 
                            (texts[check_offset + 2 * N] == 116) && 
                            (texts[check_offset + 3 * N] == 112) &&
                            (texts[check_offset + 4 * N] == 115) && 
                            (texts[check_offset + 5 * N] == 58) &&
                            (texts[check_offset + 6 * N] == 47) && 
                            (texts[check_offset + 7 * N] == 47);
            
            varying bool found_url = (is_http || is_https) && (num_urls < MAX_URLS);
            
            if (any(found_url)) {
                // Find URL boundaries in parallel
                varying int url_start = idx;
                varying int url_end = url_start;
                
                // Vectorized search for end of URL
                for (varying int scan = url_start; scan < text_len && scan < url_start + MAX_URL_LEN; scan++) {
                    varying int scan_offset = scan * N + i;
                    varying uint8 c = texts[scan_offset];
                    varying bool is_delimiter = (c == 32 || c == 44 || c == 0 || c == 10 || c == 13);
                    
                    if (!is_delimiter && url_end == scan) {
                        url_end = scan + 1;
                    }
                }
                
                varying int url_len = url_end - url_start;
                varying bool valid_url = found_url && (url_len > 0) && (url_len < MAX_URL_LEN - 1);
                
                if (any(valid_url)) {
                    // VECTORIZED hash computation - all lanes hash in parallel
                    varying int64 url_hash = hashURL_vectorized(texts, N, i, url_start, url_len);
                    
                    // Local buffer for Base62 encoding (small, per-lane)
                    varying uint8 short_id[64];
                    
                    // VECTORIZED Base62 encoding directly to local buffer
                    varying int64 n = url_hash;
                    varying int len = 0;
                    varying uint8 temp[64];
                    
                    if (n == 0) {
                        short_id[0] = 97; // 'a'
                        short_id[1] = 0;
                        len = 1;
                    } else {
                        // Each lane computes its own Base62 encoding
                        while (n > 0 && len < 63) {
                            varying int64 remainder = n % 62;
                            varying uint8 encoded_char;
                            
                            if (remainder < 26) {
                                encoded_char = 97 + remainder; // 'a' to 'z'
                            } else if (remainder < 52) {
                                encoded_char = 65 + (remainder - 26); // 'A' to 'Z'
                            } else {
                                encoded_char = 48 + (remainder - 52); // '0' to '9'
                            }
                            
                            temp[len] = encoded_char;
                            len++;
                            n = n / 62;
                        }
                        
                        // Reverse and write to short_id buffer
                        for (varying int idx = 0; idx < len; idx++) {
                            short_id[idx] = temp[len - 1 - idx];
                        }
                        short_id[len] = 0;
                    }
                    
                    // Store URLs directly to output - INTERLEAVED!
                    if (any(valid_url)) {
                        // Copy original URL directly to output
                        // Byte k of URL j for text i is at: (j*MAX_URL_LEN + k) * N + i
                        varying int url_base = num_urls * MAX_URL_LEN * N;
                        
                        for (varying int k = 0; k < url_len; k++) {
                            varying int src_offset = (url_start + k) * N + i;
                            varying int dest_offset = url_base + k * N + i;
                            results.urls[dest_offset] = texts[src_offset];
                        }
                        results.urls[url_base + url_len * N + i] = 0;
                        
                        // Build shortened URL directly to output - INTERLEAVED!
                        varying int short_base = num_urls * MAX_URL_LEN * N;
                        
                        // Copy hostname prefix "http://short-url/" directly - INTERLEAVED
                        uniform uint8 hostname[17];
                        hostname[0] = 104; hostname[1] = 116; hostname[2] = 116; hostname[3] = 112;
                        hostname[4] = 58; hostname[5] = 47; hostname[6] = 47;
                        hostname[7] = 115; hostname[8] = 104; hostname[9] = 111; hostname[10] = 114;
                        hostname[11] = 116; hostname[12] = 45; hostname[13] = 117; hostname[14] = 114;
                        hostname[15] = 108; hostname[16] = 47;
                        
                        for (uniform int h = 0; h < 17; h++) {
                            results.shortened_urls[short_base + h * N + i] = hostname[h];
                        }
                        
                        // Copy Base62 encoded ID directly to output - INTERLEAVED
                        for (varying int k = 0; k < len; k++) {
                            results.shortened_urls[short_base + (17 + k) * N + i] = short_id[k];
                        }
                        results.shortened_urls[short_base + (17 + len) * N + i] = 0;
                        
                        // Increment URL counter for valid URLs
                        if (valid_url) {
                            num_urls = num_urls + 1;
                        }
                    }
                }
            }
        }
        
        // Store URL count directly - vectorized write to SoA
        results.num_urls[i] = num_urls;
        
        // Build updated text - FULLY VECTORIZED (reads directly from output arrays)
        if (num_urls > 0) {
            varying int out_idx = 0;
            varying int text_idx = 0;
            varying int url_count = 0;
            
            while (text_idx < text_len && out_idx < MAX_TEXT_LEN - 1) {
                varying int check_offset = text_idx * N + i;
                
                varying bool is_http = (text_idx + 7 <= text_len &&
                               texts[check_offset] == 104 && 
                               texts[check_offset + N] == 116 && 
                               texts[check_offset + 2 * N] == 116 && 
                               texts[check_offset + 3 * N] == 112 && 
                               texts[check_offset + 4 * N] == 58 && 
                               texts[check_offset + 5 * N] == 47 && 
                               texts[check_offset + 6 * N] == 47);
                
                varying bool is_https = (text_idx + 8 <= text_len &&
                                texts[check_offset] == 104 && 
                                texts[check_offset + N] == 116 && 
                                texts[check_offset + 2 * N] == 116 && 
                                texts[check_offset + 3 * N] == 112 && 
                                texts[check_offset + 4 * N] == 115 && 
                                texts[check_offset + 5 * N] == 58 &&
                                texts[check_offset + 6 * N] == 47 && 
                                texts[check_offset + 7 * N] == 47);
                
                if ((is_http || is_https) && url_count < num_urls) {
                    // Skip original URL - vectorized
                    varying int url_end = text_idx;
                    while (url_end < text_len) {
                        varying int end_offset = url_end * N + i;
                        varying uint8 c = texts[end_offset];
                        if (c == 32 || c == 44 || c == 0 || c == 10 || c == 13) {
                            break;
                        }
                        url_end++;
                    }
                    
                    // Copy shortened URL - INTERLEAVED layout
                    varying int short_len = 0;
                    varying int short_url_base = url_count * MAX_URL_LEN * N;
                    for (uniform int sl = 0; sl < MAX_URL_LEN; sl++) {
                        if (results.shortened_urls[short_url_base + sl * N + i] == 0) {
                            short_len = sl;
                            break;
                        }
                    }
                    if (short_len == 0) short_len = MAX_URL_LEN;
                    
                    if (out_idx + short_len < MAX_TEXT_LEN - 1) {
                        for (varying int cp = 0; cp < short_len; cp++) {
                            varying int src_offset = short_url_base + cp * N + i;
                            varying int dest_offset = (out_idx + cp) * N + i;
                            results.updated_text[dest_offset] = results.shortened_urls[src_offset];
                        }
                        out_idx += short_len;
                    }
                    
                    text_idx = url_end;
                    url_count++;
                } else {
                    varying int src_offset = text_idx * N + i;
                    varying int dest_offset = out_idx * N + i;
                    results.updated_text[dest_offset] = texts[src_offset];
                    out_idx++;
                    text_idx++;
                }
            }
            results.updated_text[out_idx * N + i] = 0;
        } else {
            // No URLs, copy original text - INTERLEAVED!
            varying int copy_len = (text_len < MAX_TEXT_LEN - 1) ? text_len : (MAX_TEXT_LEN - 1);
            for (varying int cp = 0; cp < copy_len; cp++) {
                varying int src_offset = cp * N + i;
                varying int dest_offset = cp * N + i;
                results.updated_text[dest_offset] = texts[src_offset];
            }
            results.updated_text[copy_len * N + i] = 0;
        }
        
        // End timing for this lane
        varying int64 end_time = clock();
        
        // Store timing results
        lane_start_times[i] = start_time;
        lane_end_times[i] = end_time;
    }
}
