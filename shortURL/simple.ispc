#define MAX_LEN 128

#define MAX_ENTRIES 1024*10   // capacity of the "memcached" map
#define HASH_TABLE_SIZE 16384  // Hash table size (power of 2 for fast modulo)



inline uniform int ustrlen(uniform uint8 *s, uniform int maxn) {
    for (uniform int i = 0; i < maxn; ++i)
        if (s[i] == 0) return i;
    return maxn;
}

// Helper to get length of first string in SOA layout
// For HOSTNAME in SOA format [MAX_LEN][N], check the first entry
inline uniform int ustrlen_soa_first(uniform uint8 *s, uniform int stride, uniform int maxn) {
    for (uniform int i = 0; i < maxn; ++i)
        if (s[i * stride] == 0) return i;  // check s[0], s[stride], s[2*stride], etc.
    return maxn;
}

// Original version for AoS (contiguous) strings
inline varying uint64 hash_djb2(varying uintptr_t p) {
    varying uint64 h = 5381ul;
    for (uniform int j = 0; j < MAX_LEN - 1; ++j) {
        // load one byte per lane
        varying uint8 b = *((uint8*)p);
        //print("in hash % % \n",p,b);
        // stop if all lanes hit 0
        // print("in hash % %\n",b,h);
        if ((b == 0)) break;

        // update hash
        h = ((h << 5) + h) + b;
        
        // advance per-lane pointer
        p += 1;
    }
    return h;
}

// SOA-aware version: reads from SOA layout [MAX_LEN][N]
inline varying uint64 hash_djb2_soa(uniform uint8 soa_buf[], varying int lane_id, uniform int N) {
    varying uint64 h = 5381ul;
    for (uniform int j = 0; j < MAX_LEN - 1; ++j) {
        // SOA access: char_pos * N + lane_id
        varying uint8 b = soa_buf[j * N + lane_id];
        // print("in hash % %\n", b, h);
        if ((b == 0)) break;

        // update hash
        h = ((h << 5) + h) + b;
    }
    return h;
}


//-------------------------------------------------------
// Simple static URL map (shared uniform structure)
// Using SOA layout for better vectorization + Hash Table
//-------------------------------------------------------
struct URLMap {
    uniform uint8 shortURLs[MAX_LEN][MAX_ENTRIES];  // SOA: [character_position][entry_index]
    uniform uint8 longURLs [MAX_LEN][MAX_ENTRIES];  // SOA: [character_position][entry_index]
    uniform int   count;
    
    // Hash table for O(1) lookup: maps hash -> entry_index (-1 means empty)
    uniform int   hashTable[HASH_TABLE_SIZE];
    uniform uint64 hashValues[MAX_ENTRIES];  // Store hash for each entry to handle collisions
};

//-------------------------------------------------------
// SOA-aware strcmp (check equality between SOA entry and linear string)
//-------------------------------------------------------
bool ustrcmp_eq_soa(uniform URLMap &map, int entry_idx, uint8 *b) {
    for (int j = 0; j < MAX_LEN; ++j) {
        uint8 ca = map.longURLs[j][entry_idx];  // SOA access: [position][entry]
        uint8 cb = b[j];
        if (ca != cb) return false;
        if (ca == 0 || cb == 0) break;
    }
    return true;
}

//-------------------------------------------------------
// SOA-aware strcmp (check equality between two SOA buffers)
//-------------------------------------------------------
bool ustrcmp_eq_soa_soa(uniform URLMap &map, int entry_idx, uniform uint8 soa_buf[], varying int lane_id, uniform int N) {
    for (int j = 0; j < MAX_LEN; ++j) {
        uint8 ca = map.longURLs[j][entry_idx];       // SOA map access
        uint8 cb = soa_buf[j * N + lane_id];         // SOA buffer access
        if (ca != cb) return false;
        if (ca == 0 || cb == 0) break;
    }
    return true;
}

//-------------------------------------------------------
// uniform lookup in URLMap (linear search) - SOA version with AoS string
//-------------------------------------------------------
int find_url(uniform URLMap &map, uint8 *longURL) {
    for (int i = 0; i < map.count; ++i)
        if (ustrcmp_eq_soa(map, i, longURL))
            return i;
    return -1;
}

//-------------------------------------------------------
// uniform lookup in URLMap (hash table based) - SOA version with SOA input
//-------------------------------------------------------
int find_url_soa(uniform URLMap &map, uniform uint8 soa_buf[], varying int lane_id, uniform int N) {
    // Compute hash of the input URL
    varying uint64 url_hash = hash_djb2_soa(soa_buf, lane_id, N);
    
    // Use hash table for O(1) lookup
    varying int hash_idx = (int)(url_hash & (HASH_TABLE_SIZE - 1));  // Fast modulo for power of 2
    varying int entry_idx = map.hashTable[hash_idx];
    
    // Linear probing for collision resolution
    for (uniform int probe = 0; probe < 8; ++probe) {  // Max 8 probes
        if (entry_idx == -1) {
            // Empty slot, not found
            return -1;
        }
        
        // Check if hash matches and then verify the actual string
        if (map.hashValues[entry_idx] == url_hash) {
            if (ustrcmp_eq_soa_soa(map, entry_idx, soa_buf, lane_id, N)) {
                return entry_idx;  // Found!
            }
        }
        
        // Collision, try next slot (linear probing)
        hash_idx = (hash_idx + 1) & (HASH_TABLE_SIZE - 1);
        entry_idx = map.hashTable[hash_idx];
    }
    
    return -1;  // Not found after max probes
}

void insert_into_map(uniform URLMap &map,
                     uint8 *longURL,
                     uint8 *shortURL) {
    if (map.count >= MAX_ENTRIES) return;
    // print("adding %",map.count);
    varying int32 x = 1;
    varying int slot = atomic_add_global(&map.count, x);
    // print("adding %",slot);
    // SOA layout: store each character position across entries
    for (int j = 0; j < MAX_LEN; ++j) {
        map.longURLs [j][slot] = longURL[j];   // SOA: [position][entry]
        map.shortURLs[j][slot] = shortURL[j];  // SOA: [position][entry]
        if (longURL[j] == 0 && shortURL[j] == 0) break;
    }
}

// SOA-aware version: reads longURL from SOA buffer, shortURL from AoS buffer
void insert_into_map_soa(uniform URLMap &map,
                         uniform uint8 longURL_soa[],
                         varying int lane_id,
                         uniform int N,
                         uint8 *shortURL) {
    if (map.count >= MAX_ENTRIES) return;
    // print("adding %", map.count);
    varying int32 x = 1;
    varying int slot = atomic_add_global(&map.count, x);
    // print("adding %", slot);
    // SOA layout: store each character position across entries
    for (int j = 0; j < MAX_LEN; ++j) {
        map.longURLs [j][slot] = longURL_soa[j * N + lane_id];  // Read from SOA input
        map.shortURLs[j][slot] = shortURL[j];                   // Read from AoS output
        if (longURL_soa[j * N + lane_id] == 0 && shortURL[j] == 0) break;
    }
}

// Fully SOA-aware version: reads both longURL and shortURL from SOA buffers
void insert_into_map_soa_soa(uniform URLMap &map,
                             uniform uint8 longURL_soa[],
                             uniform uint8 shortURL_soa[],
                             varying int lane_id,
                             uniform int N) {
    if (map.count >= MAX_ENTRIES) return;
    // print("adding %", map.count);
    varying int32 x = 1;
    varying int slot = atomic_add_global(&map.count, x);
    // print("adding %", slot);
    
    // Compute hash for this URL
    varying uint64 url_hash = hash_djb2_soa(longURL_soa, lane_id, N);
    
    // Store hash value for collision detection
    map.hashValues[slot] = url_hash;
    
    // Insert into hash table with linear probing
    varying int hash_idx = (int)(url_hash & (HASH_TABLE_SIZE - 1));
    for (uniform int probe = 0; probe < 8; ++probe) {  // Max 8 probes
        varying int expected = -1;
        varying int current = map.hashTable[hash_idx];
        if (current == -1) {
            // Try to claim this slot atomically
            varying int old_val = atomic_compare_exchange_global(&map.hashTable[hash_idx], expected, slot);
            if (old_val == -1) {
                // Successfully inserted
                break;
            }
        }
        // Collision, try next slot
        hash_idx = (hash_idx + 1) & (HASH_TABLE_SIZE - 1);
    }
    
    // SOA layout: store each character position across entries
    for (int j = 0; j < MAX_LEN; ++j) {
        map.longURLs [j][slot] = longURL_soa[j * N + lane_id];   // Read from SOA longURL
        map.shortURLs[j][slot] = shortURL_soa[j * N + lane_id];  // Read from SOA shortURL
        if (longURL_soa[j * N + lane_id] == 0 && shortURL_soa[j * N + lane_id] == 0) break;
    }
}
export void concat_batch(uniform URLMap &map,
                        uniform uint8 HOSTNAME[],           // [MAX_LEN] - common hostname for all requests
                        uniform uint8 tokens_buf[],         // SOA: [MAX_LEN][N] - all 1st chars, then all 2nd chars, etc.
                        uniform int   offsets[],            // per-lane token offset (may be unused with SOA)
                        uniform int   N,
                        uniform uint8 out_buf[],            // SOA: [MAX_LEN][N] - all 1st chars, then all 2nd chars, etc.
                        uniform int64 lane_start_times[],   // [N] - output
                        uniform int64 lane_end_times[],     // [N] - output
                        uniform int64 &global_start_time)   // output
{
    // Capture global start - all requests arrive at this time
    global_start_time = clock();
    
    // HOSTNAME is uniform: [MAX_LEN] - same for all lanes
    uniform int host_len = ustrlen(HOSTNAME, MAX_LEN);
    if (host_len >= MAX_LEN) host_len = MAX_LEN - 1;
    uniform uint8 alphabet[62] = {
        97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,117,118,119,120,121,122, // a–z
        65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,                         // A–Z
        48,49,50,51,52,53,54,55,56,57                                                                          // 0–9
    };
    // print("map %", &map);

    foreach (i = 0 ... N) {
        // Record when this lane actually starts
        int64 actual_start_time = clock();
        
        // Track current position in output for this lane
        varying int out_pos = 0;

        //---------------------------------------------------
        // 1️⃣ Lookup in map using SOA-aware comparison
        //---------------------------------------------------
        int found = find_url_soa(map, tokens_buf, i, N);
        // print ("found %",found);
        if (found >= 0) {
            // Reuse existing short URL - write directly from map (SOA) to out_buf (SOA)
            for (uniform int j = 0; j < MAX_LEN; ++j) {
                varying uint8 h = map.shortURLs[j][found];  // SOA map access
                out_buf[j * N + i] = h;                     // SOA output write
                if (h == 0) break;
            }
            // print("Cache hit for lane %: reusing short URL %\n", i, &map.shortURLs[0][found]);
            
            // Record timing even for cache hits
            int64 end_time = clock();
            lane_start_times[i] = actual_start_time;
            lane_end_times[i] = end_time;
            continue;
        }
        // print("Cache miss for lane %: generating new short URL\n", i);

        //-------------------------------------------------------
        // Copy HOSTNAME directly to SOA output
        // HOSTNAME is uniform: [MAX_LEN] - same for all lanes
        // out_buf is SOA: [MAX_LEN][N]
        //-------------------------------------------------------
        for (uniform int j = 0; j < host_len && j < MAX_LEN - 1; ++j) {
            varying uint8 h = HOSTNAME[j];             // Uniform read: all lanes read same value
            out_buf[out_pos * N + i] = h;              // SOA write: char_pos * N + lane_id
            out_pos += 1;
        }
        
        // Hash directly from SOA tokens_buf
        varying uint64 id = hash_djb2_soa(tokens_buf, i, N);
        // print("lane hash %\n", id);
        
        // Handle zero hash case
        varying bool zero = (id == 0ull);
        if ((zero)) {
            out_buf[out_pos * N + i] = alphabet[0];
            out_pos += 1;
        }

        // Encode the hash into base62, writing directly to SOA output
        for (uniform int j = 0; j < MAX_LEN - 1; ++j) {
            varying bool active = (id > 0ull);
            if (!(active)) break;

            varying uint64 q = id / 62ull;
            varying uint64 r = id - q * 62ull;
            out_buf[out_pos * N + i] = alphabet[r];    // SOA write
            // print(" id % q % r % [r] % \n",id,q,r,alphabet[r]);
            out_pos += 1;
            id = q;
        }

        // Null terminate
        out_buf[out_pos * N + i] = 0;
        
        // Ensure null termination at the end position too
        out_buf[(MAX_LEN - 1) * N + i] = 0;
        
        // Insert into map: both from SOA buffers (tokens_buf and out_buf)
        insert_into_map_soa_soa(map, tokens_buf, out_buf, i, N);
        
        // Record when this lane ends
        int64 end_time = clock();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}

