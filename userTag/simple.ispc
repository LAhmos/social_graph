//===========================================================
// user_notification_memcached : unordered multimap
//===========================================================

#define MAX_ENTRIES   4096
#define MAX_KEY_LEN   32
#define HASH_TABLE_SIZE 8192  // Hash table size (power of 2)

export struct NotificationMap {
    uniform uint8 keys[MAX_ENTRIES][MAX_KEY_LEN];
    uniform int64 values[MAX_ENTRIES];
    uniform int   next_slot;   // how many total entries
    
    // Simplified: Just store first index, traverse linked list for count
    uniform int   hashTable[HASH_TABLE_SIZE];  // first_idx for each hash bucket
    uniform int   nextIndices[MAX_ENTRIES];    // Linked list for same key
};

//--------------------------------------------
// Hash function for keys (DJB2)
//--------------------------------------------
inline varying uint64 hash_key(uint8 *key) {
    varying uint64 h = 5381ul;
    for (uniform int j = 0; j < MAX_KEY_LEN; ++j) {
        varying uint8 b = key[j];
        if (b == 0) break;
        h = ((h << 5) + h) + b;
    }
    return h;
}

//--------------------------------------------
// helper: uniform string equality
//--------------------------------------------
inline bool ustrcmp_eq( uint8 *a, uint8 *b) {
    for (uniform int i = 0; i < MAX_KEY_LEN; i++) {
         uint8 ca = a[i];
         uint8 cb = b[i];
        if (ca != cb) return false;
        if (ca == 0 || cb == 0) break;
    }
    return true;
}

//--------------------------------------------
// Lookup: find first index for given key (hash table based)
//--------------------------------------------
inline int find_first(uniform NotificationMap &map, uint8 *key) {
    // Compute hash of the key
    varying uint64 key_hash = hash_key(key);
    
    // Use hash table for O(1) lookup
    varying int hash_idx = (int)(key_hash & (HASH_TABLE_SIZE - 1));
    
    // Linear probing
    for (uniform int probe = 0; probe < 8; ++probe) {
        varying int candidate_idx = map.hashTable[hash_idx];
        if (candidate_idx == -1) {
            // Empty slot - key not found
            return -1;
        }
        
        // Check if this is the right key
        if (ustrcmp_eq(&map.keys[candidate_idx][0], key)) {
            // Found it
            return candidate_idx;
        }
        
        // Collision - try next slot
        hash_idx = (hash_idx + 1) & (HASH_TABLE_SIZE - 1);
    }
    
    return -1;
}

//--------------------------------------------
// Count: how many entries match the key (traverse linked list)
//--------------------------------------------
inline int count_key(uniform NotificationMap &map, uint8 *key) {
    varying int first_idx = find_first(map, key);
    if (first_idx == -1) {
        return 0;
    }
    
    // Count by traversing the linked list
    varying int count = 0;
    varying int current_idx = first_idx;
    while (current_idx != -1) {
        count++;
        current_idx = map.nextIndices[current_idx];
    }
    
    return count;
}

//--------------------------------------------
// Insert: append new key–value pair (with hash table)
//--------------------------------------------
inline void insert_map(uniform NotificationMap &map,
                    uint8 *key,
                    int64 value)
{
    if (map.next_slot >= MAX_ENTRIES) {
        return;
    }

    // Atomically claim a slot
    varying int inc = 1;
    varying int slot = atomic_add_global(&map.next_slot, inc);
    
    if (slot >= MAX_ENTRIES) {
        return;
    }
    
    // Initialize next pointer to -1
    map.nextIndices[slot] = -1;

    // Copy key
    for (uniform int j = 0; j < MAX_KEY_LEN; j++) {
        uint8 c = key[j];
        map.keys[slot][j] = c;
        if (c == 0) break;
    }

    map.values[slot] = value;
    
    // Update hash table with lock-free algorithm
    varying uint64 key_hash = hash_key(key);
    varying int hash_idx = (int)(key_hash & (HASH_TABLE_SIZE - 1));
    
    // Linear probing to find correct bucket
    for (uniform int probe = 0; probe < 16; ++probe) {
        varying int current_first = map.hashTable[hash_idx];
        
        if (current_first == -1) {
            // Empty bucket - try to claim it
            varying int expected = -1;
            varying int old_val = atomic_compare_exchange_global(&map.hashTable[hash_idx], expected, slot);
            if (old_val == -1) {
                // Successfully claimed this bucket
                break;
            }
            // Someone else claimed it, retry
            continue;
        } else {
            // Bucket occupied - check if it's for the same key
            if (ustrcmp_eq(&map.keys[current_first][0], key)) {
                // Same key - prepend to linked list
                // Set our next pointer to current head
                map.nextIndices[slot] = current_first;
                
                // Try to atomically update the head pointer
                varying int old_head = atomic_compare_exchange_global(&map.hashTable[hash_idx], current_first, slot);
                if (old_head == current_first) {
                    // Successfully prepended
                    break;
                }
                // CAS failed, someone else updated it, retry
                continue;
            }
        }
        
        // Collision with different key - try next bucket
        hash_idx = (hash_idx + 1) & (HASH_TABLE_SIZE - 1);
    }
}

inline  int strlen( uint8 *s) {
    uint32 i = 0;
    while(s[i] != 0) i++;
    return i;
}
export void userMention_flat_batch(
    uniform NotificationMap &map,
    uniform  uint8 usernames_flat[], // flat buffer
    uniform  int start_idx[],        // starting username index per post
    uniform  int num_per_post[],     // number of usernames per post
    uniform int64 postIDs[],              // post IDs per lane
    uniform int N,
    uniform int64 lane_start_times[],  // [N] - output
    uniform int64 lane_end_times[],    // [N] - output
    uniform int64 &global_start_time)  // output
{
    // Capture global start - all requests arrive at this time
    global_start_time = clock();
    
    // ":user_id" in ASCII
    uniform uint8 suffix[8] = {58,117,115,101,114,95,105,100};

    foreach (i = 0 ... N) {
        // Record when this lane actually starts
        int64 actual_start_time = clock();
         int64 post = postIDs[i];
         int start = start_idx[i];
         int count = num_per_post[i];

        for (int u = 0; u < count; u++) {
            uint8 *uname = &usernames_flat[(start + u) * MAX_KEY_LEN];
            // uint32 len = strlen(uname);
            // print("Processing username % (len %)\n", uname, len);
            // uint8 key_buf[MAX_KEY_LEN];
            // for (uniform int j = 0; j < len; j++){
            //     key_buf[j] = uname[j];
            //     print("key_buf[%] = %\n", j, key_buf[j]);
            // }

            // append suffix in the last 8 bytes
            // for ( int j = len; j < len+8; j++){
            //     key_buf[j] = suffix[j];
            //     print("key_buf[%] = %\n", j, key_buf[j]);
            // }
            insert_map(map, (uint8 * )&uname[0], post);
        }

        
            // print("Post % processed % usernames\n", post, count);
        
        // Record when this lane ends
        int64 end_time = clock();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}


export void getMentionNotifications_batch(
    uniform const NotificationMap &map,
    uniform  uint8 usernames[],  // [N * MAX_KEY_LEN]
    uniform int N,
    uniform int64 out_posts[],        // [N * max_posts]
    uniform int max_posts,
    uniform int out_counts[],         // [N]
    uniform int64 lane_start_times[],  // [N] - output
    uniform int64 lane_end_times[],    // [N] - output
    uniform int64 &global_start_time)  // output
{
    // Capture global start - all requests arrive at this time
    global_start_time = clock();
    
    foreach (i = 0 ... N) {
        // Record when this lane actually starts
        int64 actual_start_time = clock();
         const uint8 *uname = &usernames[i * MAX_KEY_LEN];
         int base = i * max_posts;
         int found = 0;

        // Use hash table for O(1) lookup
        varying uint64 key_hash = hash_key((uint8*)uname);
        varying int hash_idx = (int)(key_hash & (HASH_TABLE_SIZE - 1));
        varying int first_idx = -1;
        
        // Linear probing to find the key
        for (uniform int probe = 0; probe < 16; ++probe) {
            varying int candidate_idx = map.hashTable[hash_idx];
            if (candidate_idx == -1) {
                // Empty slot - key not found
                break;
            }
            
            // Check if this is the right key
            if (ustrcmp_eq(&map.keys[candidate_idx][0], uname)) {
                // Found it
                first_idx = candidate_idx;
                break;
            }
            
            // Collision - try next slot
            hash_idx = (hash_idx + 1) & (HASH_TABLE_SIZE - 1);
        }
        
        // Follow the linked list of entries for this key
        if (first_idx != -1) {
            varying int current_idx = first_idx;
            while (current_idx != -1 && found < max_posts) {
                out_posts[base + found] = map.values[current_idx];
                found++;
                
                // Move to next entry in linked list
                current_idx = map.nextIndices[current_idx];
            }
        }

        out_counts[i] = found;

        // print("Lane % (username %) found % posts\n",
        //       i, uname, found);
        
        // Record when this lane ends
        int64 end_time = clock();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}