//===========================================================
// user_notification_memcached : unordered multimap
//===========================================================

#define MAX_ENTRIES   1024
#define MAX_KEY_LEN   32

export struct NotificationMap {
    uniform uint8 keys[MAX_ENTRIES][MAX_KEY_LEN];
    uniform int64 values[MAX_ENTRIES];
    uniform int   next_slot;   // how many total entries
};

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
// Lookup: find first index for given key
//--------------------------------------------
inline int find_first(uniform NotificationMap &map, uint8 *key) {
    for (uniform int i = 0; i < map.next_slot; i++) {
        if (ustrcmp_eq(&map.keys[i][0], key))
            return i;
    }
    return -1;
}

//--------------------------------------------
// Count: how many entries match the key
//--------------------------------------------
inline int count_key(uniform NotificationMap &map, uint8 *key) {
    uniform int count = 0;
    for (uniform int i = 0; i < map.next_slot; i++) {
        if (ustrcmp_eq(&map.keys[i][0], key))
            count++;
    }
    return count;
}

//--------------------------------------------
// Insert: append new key–value pair
//--------------------------------------------
inline void insert_map(uniform NotificationMap &map,
                    uint8 *key,
                    int64 value)
{
    if (map.next_slot >= MAX_ENTRIES) {
        print("⚠️  Notification map full, cannot insert more\n");
        return;
    }

    // atomic increment to handle parallel inserts
    varying int inc = 1;
    varying int slot = atomic_add_global(&map.next_slot, inc);

    // Copy key
    for (uniform int j = 0; j < MAX_KEY_LEN; j++) {
        uint8 c = key[j];
        map.keys[slot][j] = c;
        if (c == 0) break;
    }

    map.values[slot] = value;

    
    print("Inserted notification key % → value % at slot %\n",
              key, value, slot);
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
    uniform int N)
{
    // ":user_id" in ASCII
    uniform uint8 suffix[8] = {58,117,115,101,114,95,105,100};

    foreach (i = 0 ... N) {
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

        
            print("Post % processed % usernames\n", post, count);
    }
}


export void getMentionNotifications_batch(
    uniform const NotificationMap &map,
    uniform  uint8 usernames[],  // [N * MAX_KEY_LEN]
    uniform int N,
    uniform int64 out_posts[],        // [N * max_posts]
    uniform int max_posts,
    uniform int out_counts[])         // [N]
{
    foreach (i = 0 ... N) {
         const uint8 *uname = &usernames[i * MAX_KEY_LEN];
         int base = i * max_posts;
         int found = 0;

        for (uniform int j = 0; j < map.next_slot; j++) {
            if (ustrcmp_eq(&map.keys[j][0], uname)) {
                out_posts[base + found] = map.values[j];
                found++;
                if (found >= max_posts)
                    break;
            }
        }

        out_counts[i] = found;

        print("Lane % (username %) found % posts\n",
              i, uname, found);
    }
}