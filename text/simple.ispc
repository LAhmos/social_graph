#define MAX_TEXT_LEN   256
#define MAX_MENTIONS   16
#define MAX_URLS       16
#define MAX_URL_LEN    128

//--------------------------------------------------
// Data structures
//--------------------------------------------------
export struct TextResult {
    uniform int    num_mentions;
    uniform int    num_urls;
    uniform uint8  updated_text[MAX_TEXT_LEN];
    uniform uint8  mentions[MAX_MENTIONS][64];
    uniform uint8  urls[MAX_URLS][MAX_URL_LEN];
    uniform uint8  shortened_urls[MAX_URLS][MAX_URL_LEN];
};

//--------------------------------------------------
// Helper functions
//--------------------------------------------------

// Base62 encode for URL shortening
static void idToShortURL(uniform int64 n, uniform uint8 out_buf[]) {
    // Base62 mapping: a-z (97-122), A-Z (65-90), 0-9 (48-57)
    uniform uint8 temp[64];
    uniform int len = 0;
    
    if (n == 0) {
        out_buf[0] = 97; // 'a'
        out_buf[1] = 0;
        return;
    }
    
    while (n > 0 && len < 63) {
        uniform int64 remainder = n % 62;
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
    for (uniform int i = 0; i < len; i++) {
        out_buf[i] = temp[len - 1 - i];
    }
    out_buf[len] = 0;
}

// Hash URL
static uniform int64 hashURL(const uniform uint8 url[], uniform int len) {
    uniform int64 hash = 5381;
    for (uniform int i = 0; i < len; i++) {
        hash = ((hash << 5) + hash) + url[i];
    }
    return hash & 0x7FFFFFFFFFFFFFFF;
}

// String length helper
static uniform int strlen_ispc(const uniform uint8 str[]) {
    uniform int len = 0;
    while (str[len] != 0 && len < MAX_URL_LEN) {
        len++;
    }
    return len;
}

// Memory copy helper
static void memcpy_ispc(uniform uint8 dest[], const uniform uint8 src[], uniform int n) {
    for (uniform int i = 0; i < n; i++) {
        dest[i] = src[i];
    }
}

// Process single text - now implemented in ISPC
static void process_single_text(
    const uniform uint8 text[],
    uniform int text_len,
    uniform uint8 mentions[][64],
    uniform int * uniform num_mentions,
    uniform uint8 urls[][128],
    uniform int * uniform num_urls,
    uniform uint8 shortened_urls[][128],
    uniform uint8 updated_text[]
)
{
    *num_mentions = 0;
    *num_urls = 0;
    
    // Extract user mentions (@username)
    for (uniform int idx = 0; idx < text_len && *num_mentions < MAX_MENTIONS; idx++) {
        if (text[idx] == 64) { // '@'
            uniform int start = idx + 1;
            uniform int end = start;
            
            // Find end of mention (space, comma, or end of text)
            while (end < text_len && text[end] != 32 && text[end] != 44 && 
                   text[end] != 0 && text[end] != 10 && text[end] != 13) {
                end++;
            }
            
            uniform int mention_len = end - start;
            if (mention_len > 0 && mention_len < 63) {
                memcpy_ispc(mentions[*num_mentions], &text[start], mention_len);
                mentions[*num_mentions][mention_len] = 0;
                (*num_mentions)++;
            }
            idx = end - 1; // -1 because loop will increment
        }
    }
    
    // Extract URLs
    for (uniform int idx = 0; idx < text_len && *num_urls < MAX_URLS; idx++) {
        // Check for "http://" (104='h', 116='t', 112='p', 58=':', 47='/')
        uniform bool is_http = (idx + 7 <= text_len &&
                       text[idx] == 104 && text[idx+1] == 116 && text[idx+2] == 116 &&
                       text[idx+3] == 112 && text[idx+4] == 58 && 
                       text[idx+5] == 47 && text[idx+6] == 47);
        // Check for "https://" (115='s')
        uniform bool is_https = (idx + 8 <= text_len &&
                        text[idx] == 104 && text[idx+1] == 116 && text[idx+2] == 116 &&
                        text[idx+3] == 112 && text[idx+4] == 115 && text[idx+5] == 58 &&
                        text[idx+6] == 47 && text[idx+7] == 47);
        
        if (is_http || is_https) {
            uniform int start = idx;
            uniform int end = start;
            
            // Find end of URL (space=32, comma=44, newline=10, carriage return=13)
            while (end < text_len && text[end] != 32 && text[end] != 44 && 
                   text[end] != 0 && text[end] != 10 && text[end] != 13) {
                end++;
            }
            
            uniform int url_len = end - start;
            if (url_len > 0 && url_len < MAX_URL_LEN - 1) {
                // Store original URL
                memcpy_ispc(urls[*num_urls], &text[start], url_len);
                urls[*num_urls][url_len] = 0;
                
                // Generate shortened URL
                uniform int64 url_hash = hashURL(&text[start], url_len);
                
                // Build shortened URL: "http://short-url/"
                uniform uint8 hostname[18];
                hostname[0] = 104; hostname[1] = 116; hostname[2] = 116; hostname[3] = 112; // http
                hostname[4] = 58; hostname[5] = 47; hostname[6] = 47; // ://
                hostname[7] = 115; hostname[8] = 104; hostname[9] = 111; hostname[10] = 114; // shor
                hostname[11] = 116; hostname[12] = 45; hostname[13] = 117; hostname[14] = 114; // t-ur
                hostname[15] = 108; hostname[16] = 47; hostname[17] = 0; // l/\0
                uniform int hostname_len = 17;
                
                memcpy_ispc(shortened_urls[*num_urls], hostname, hostname_len);
                
                uniform uint8 short_id[64];
                idToShortURL(url_hash, short_id);
                
                uniform int short_id_len = strlen_ispc(short_id);
                memcpy_ispc(&shortened_urls[*num_urls][hostname_len], short_id, short_id_len);
                shortened_urls[*num_urls][hostname_len + short_id_len] = 0;
                
                (*num_urls)++;
            }
            idx = end - 1; // -1 because loop will increment
        }
    }
    
    // Build updated text with shortened URLs
    if (*num_urls > 0) {
        uniform int out_idx = 0;
        uniform int text_idx = 0;
        uniform int url_count = 0;
        
        while (text_idx < text_len && out_idx < MAX_TEXT_LEN - 1) {
            // Check for "http://"
            uniform bool is_http = (text_idx + 7 <= text_len &&
                           text[text_idx] == 104 && text[text_idx+1] == 116 && 
                           text[text_idx+2] == 116 && text[text_idx+3] == 112 && 
                           text[text_idx+4] == 58 && text[text_idx+5] == 47 && 
                           text[text_idx+6] == 47);
            // Check for "https://"
            uniform bool is_https = (text_idx + 8 <= text_len &&
                            text[text_idx] == 104 && text[text_idx+1] == 116 && 
                            text[text_idx+2] == 116 && text[text_idx+3] == 112 && 
                            text[text_idx+4] == 115 && text[text_idx+5] == 58 &&
                            text[text_idx+6] == 47 && text[text_idx+7] == 47);
            
            if ((is_http || is_https) && url_count < *num_urls) {
                // Skip original URL
                uniform int url_end = text_idx;
                while (url_end < text_len && text[url_end] != 32 && 
                       text[url_end] != 44 && text[url_end] != 0 && 
                       text[url_end] != 10 && text[url_end] != 13) {
                    url_end++;
                }
                
                // Insert shortened URL
                uniform int short_len = strlen_ispc(shortened_urls[url_count]);
                if (out_idx + short_len < MAX_TEXT_LEN - 1) {
                    memcpy_ispc(&updated_text[out_idx], shortened_urls[url_count], short_len);
                    out_idx += short_len;
                }
                
                text_idx = url_end;
                url_count++;
            } else {
                updated_text[out_idx++] = text[text_idx++];
            }
        }
        updated_text[out_idx] = 0;
    } else {
        // No URLs, copy original text
        uniform int copy_len = (text_len < MAX_TEXT_LEN - 1) ? text_len : (MAX_TEXT_LEN - 1);
        memcpy_ispc(updated_text, text, copy_len);
        updated_text[copy_len] = 0;
    }
}

//--------------------------------------------------
// Vectorized helper: process multiple texts in parallel (SIMD across texts)
//--------------------------------------------------
static void process_texts_vectorized(
    uniform const uint8 texts[],
    varying int text_indices,           // Which text each lane processes
    uniform TextResult results[],
    varying int text_lens,
    varying int64 &start_time,
    varying int64 &end_time
)
{
    // Each SIMD lane processes a different text
    start_time = clock();
    
    // Calculate base offset for each lane's text
    varying int base_offset = text_indices * MAX_TEXT_LEN;
    
    // Initialize result counts to 0 for each lane
    varying int num_mentions = 0;
    varying int num_urls = 0;
    
    // Extract user mentions (@username) - vectorized across texts
    for (uniform int idx = 0; idx < MAX_TEXT_LEN; idx++) {
        // Each lane reads from its own text
        varying uint8 current_char = texts[base_offset + idx];
        varying bool found_at = (current_char == 64) && (idx < text_lens) && (num_mentions < MAX_MENTIONS);
        
        if (any(found_at)) {
            // Handle mention extraction per lane that found '@'
            foreach_active(lane) {
                uniform int lane_idx = extract(text_indices, lane);
                uniform int lane_offset = extract(base_offset, lane);
                uniform int lane_text_len = extract(text_lens, lane);
                uniform int lane_mentions = extract(num_mentions, lane);
                
                if (extract(found_at, lane)) {
                    uniform int start = idx + 1;
                    uniform int end = start;
                    
                    // Find end of mention
                    while (end < lane_text_len && texts[lane_offset + end] != 32 && 
                           texts[lane_offset + end] != 44 && texts[lane_offset + end] != 0 && 
                           texts[lane_offset + end] != 10 && texts[lane_offset + end] != 13) {
                        end++;
                    }
                    
                    uniform int mention_len = end - start;
                    if (mention_len > 0 && mention_len < 63 && lane_mentions < MAX_MENTIONS) {
                        memcpy_ispc(results[lane_idx].mentions[lane_mentions], 
                                   &texts[lane_offset + start], mention_len);
                        results[lane_idx].mentions[lane_mentions][mention_len] = 0;
                        
                        // Update varying counter
                        num_mentions = insert(num_mentions, lane, lane_mentions + 1);
                    }
                }
            }
        }
    }
    
    // Store mention counts
    foreach_active(lane) {
        uniform int lane_idx = extract(text_indices, lane);
        results[lane_idx].num_mentions = extract(num_mentions, lane);
    }
    
    // Extract URLs - vectorized across texts
    for (uniform int idx = 0; idx < MAX_TEXT_LEN - 8; idx++) {
        varying int check_offset = base_offset + idx;
        
        // Check for "http://" or "https://" in parallel across lanes
        varying bool is_http = (idx + 7 <= text_lens) &&
                       (texts[check_offset] == 104) && (texts[check_offset+1] == 116) && 
                       (texts[check_offset+2] == 116) && (texts[check_offset+3] == 112) &&
                       (texts[check_offset+4] == 58) && (texts[check_offset+5] == 47) && 
                       (texts[check_offset+6] == 47);
        
        varying bool is_https = (idx + 8 <= text_lens) &&
                        (texts[check_offset] == 104) && (texts[check_offset+1] == 116) && 
                        (texts[check_offset+2] == 116) && (texts[check_offset+3] == 112) &&
                        (texts[check_offset+4] == 115) && (texts[check_offset+5] == 58) &&
                        (texts[check_offset+6] == 47) && (texts[check_offset+7] == 47);
        
        varying bool found_url = (is_http || is_https) && (num_urls < MAX_URLS);
        
        if (any(found_url)) {
            // Handle URL extraction per lane that found URL
            foreach_active(lane) {
                uniform int lane_idx = extract(text_indices, lane);
                uniform int lane_offset = extract(base_offset, lane);
                uniform int lane_text_len = extract(text_lens, lane);
                uniform int lane_urls = extract(num_urls, lane);
                
                if (extract(found_url, lane) && lane_urls < MAX_URLS) {
                    uniform int start = idx;
                    uniform int end = start;
                    
                    // Find end of URL
                    while (end < lane_text_len && texts[lane_offset + end] != 32 && 
                           texts[lane_offset + end] != 44 && texts[lane_offset + end] != 0 && 
                           texts[lane_offset + end] != 10 && texts[lane_offset + end] != 13) {
                        end++;
                    }
                    
                    uniform int url_len = end - start;
                    if (url_len > 0 && url_len < MAX_URL_LEN - 1) {
                        // Store original URL
                        memcpy_ispc(results[lane_idx].urls[lane_urls], 
                                   &texts[lane_offset + start], url_len);
                        results[lane_idx].urls[lane_urls][url_len] = 0;
                        
                        // Generate shortened URL
                        uniform int64 url_hash = hashURL(&texts[lane_offset + start], url_len);
                        
                        // Build shortened URL: "http://short-url/"
                        uniform uint8 hostname[18];
                        hostname[0] = 104; hostname[1] = 116; hostname[2] = 116; hostname[3] = 112;
                        hostname[4] = 58; hostname[5] = 47; hostname[6] = 47;
                        hostname[7] = 115; hostname[8] = 104; hostname[9] = 111; hostname[10] = 114;
                        hostname[11] = 116; hostname[12] = 45; hostname[13] = 117; hostname[14] = 114;
                        hostname[15] = 108; hostname[16] = 47; hostname[17] = 0;
                        uniform int hostname_len = 17;
                        
                        memcpy_ispc(results[lane_idx].shortened_urls[lane_urls], hostname, hostname_len);
                        
                        uniform uint8 short_id[64];
                        idToShortURL(url_hash, short_id);
                        
                        uniform int short_id_len = strlen_ispc(short_id);
                        memcpy_ispc(&results[lane_idx].shortened_urls[lane_urls][hostname_len], 
                                   short_id, short_id_len);
                        results[lane_idx].shortened_urls[lane_urls][hostname_len + short_id_len] = 0;
                        
                        // Update varying counter
                        num_urls = insert(num_urls, lane, lane_urls + 1);
                    }
                }
            }
        }
    }
    
    // Store URL counts and build updated text
    foreach_active(lane) {
        uniform int lane_idx = extract(text_indices, lane);
        uniform int lane_urls = extract(num_urls, lane);
        results[lane_idx].num_urls = lane_urls;
        
        // Build updated text with shortened URLs
        uniform int lane_offset = extract(base_offset, lane);
        uniform int lane_text_len = extract(text_lens, lane);
        
        if (lane_urls > 0) {
            uniform int out_idx = 0;
            uniform int text_idx = 0;
            uniform int url_count = 0;
            
            while (text_idx < lane_text_len && out_idx < MAX_TEXT_LEN - 1) {
                uniform bool is_http = (text_idx + 7 <= lane_text_len &&
                               texts[lane_offset + text_idx] == 104 && 
                               texts[lane_offset + text_idx+1] == 116 && 
                               texts[lane_offset + text_idx+2] == 116 && 
                               texts[lane_offset + text_idx+3] == 112 && 
                               texts[lane_offset + text_idx+4] == 58 && 
                               texts[lane_offset + text_idx+5] == 47 && 
                               texts[lane_offset + text_idx+6] == 47);
                
                uniform bool is_https = (text_idx + 8 <= lane_text_len &&
                                texts[lane_offset + text_idx] == 104 && 
                                texts[lane_offset + text_idx+1] == 116 && 
                                texts[lane_offset + text_idx+2] == 116 && 
                                texts[lane_offset + text_idx+3] == 112 && 
                                texts[lane_offset + text_idx+4] == 115 && 
                                texts[lane_offset + text_idx+5] == 58 &&
                                texts[lane_offset + text_idx+6] == 47 && 
                                texts[lane_offset + text_idx+7] == 47);
                
                if ((is_http || is_https) && url_count < lane_urls) {
                    // Skip original URL
                    uniform int url_end = text_idx;
                    while (url_end < lane_text_len && 
                           texts[lane_offset + url_end] != 32 && 
                           texts[lane_offset + url_end] != 44 && 
                           texts[lane_offset + url_end] != 0 && 
                           texts[lane_offset + url_end] != 10 && 
                           texts[lane_offset + url_end] != 13) {
                        url_end++;
                    }
                    
                    // Insert shortened URL
                    uniform int short_len = strlen_ispc(results[lane_idx].shortened_urls[url_count]);
                    if (out_idx + short_len < MAX_TEXT_LEN - 1) {
                        memcpy_ispc(&results[lane_idx].updated_text[out_idx], 
                                   results[lane_idx].shortened_urls[url_count], short_len);
                        out_idx += short_len;
                    }
                    
                    text_idx = url_end;
                    url_count++;
                } else {
                    results[lane_idx].updated_text[out_idx++] = texts[lane_offset + text_idx++];
                }
            }
            results[lane_idx].updated_text[out_idx] = 0;
        } else {
            // No URLs, copy original text
            uniform int copy_len = (lane_text_len < MAX_TEXT_LEN - 1) ? lane_text_len : (MAX_TEXT_LEN - 1);
            memcpy_ispc(results[lane_idx].updated_text, &texts[lane_offset], copy_len);
            results[lane_idx].updated_text[copy_len] = 0;
        }
    }
    
    end_time = clock();
}

//--------------------------------------------------
// Batch kernel: process multiple texts in parallel using VECTORIZATION
//--------------------------------------------------
export void processText_batch(
    uniform const uint8 texts[],        // [N * MAX_TEXT_LEN]
    uniform int N,
    uniform TextResult results[],       // [N]
    uniform int64 lane_start_times[],   // [N] - output
    uniform int64 lane_end_times[],     // [N] - output
    uniform int64 &global_start_time)   // output
{
    // Capture global start time
    global_start_time = clock();
    
    // Process texts in parallel using foreach - processes programCount texts at once
    // This is TRUE VECTORIZATION: each SIMD lane processes a different text simultaneously
    foreach (i = 0 ... N) {
        // Calculate text length for each lane
        varying int text_len = 0;
        varying int offset = i * MAX_TEXT_LEN;
        
        for (uniform int j = 0; j < MAX_TEXT_LEN; j++) {
            if (texts[offset + j] == 0) {
                text_len = j;
                break;
            }
        }
        if (text_len == 0) text_len = MAX_TEXT_LEN;
        
        varying int64 start_time, end_time;
        
        // Process this batch of texts in SIMD
        process_texts_vectorized(texts, i, results, text_len, start_time, end_time);
        
        // Store timing results
        lane_start_times[i] = start_time;
        lane_end_times[i] = end_time;
    }
}
