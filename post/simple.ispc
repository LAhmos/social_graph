#define MAX_ENTRIES   4096
#define MAX_POST_LEN  128
#define MAX_RESULTS   16   // max posts returned per user

//--------------------------------------------------
// Data structures
//--------------------------------------------------
export struct Post {
    uniform int    user_id;
    uniform int64  post_id;
    uniform uint8  post_string[MAX_POST_LEN];
};

export struct PostMap {
    uniform int   user_ids[MAX_ENTRIES];
    uniform Post  posts[MAX_ENTRIES];
    uniform int   next_slot;
};

//--------------------------------------------------
// Insert post into PostMap (like multimap)
//--------------------------------------------------
inline void insert_post(uniform PostMap &map,
                         int user_id,
                         uint8 *post_text,
                         int64 post_id)
{
    if (map.next_slot >= MAX_ENTRIES) return;

    varying int inc = 1;
    varying int slot = atomic_add_global(&map.next_slot, inc);

    // Fill entry
    map.user_ids[slot] = user_id;
    map.posts[slot].user_id = user_id;
    map.posts[slot].post_id = post_id;

    // Copy post text (truncate if needed)
    for (uniform int j = 0; j < MAX_POST_LEN; j++) {
        map.posts[slot].post_string[j] = post_text[j];
        if (post_text[j] == 0) break;
    }

    if (programIndex == 0)
        print("Inserted post % for user %\n", post_id, user_id);
}
inline int64 generate_unique_id(
    uniform  uint8 machine_id[],
    uniform int machine_len,
    varying int i)
{
    varying uint8  out_buf[32];

    //----------------------------------------------------------------------
    // Generate pseudo-timestamp and lane counter
    //----------------------------------------------------------------------
    varying int64 timestamp = (int64)clock() + (varying int64)i;
    varying int   counter   = i;
    // print("lane % timestamp % counter %\n", programIndex, timestamp, counter);

    //----------------------------------------------------------------------
    // Convert timestamp -> 10-digit hex (ASCII-based)
    //----------------------------------------------------------------------
    uniform int timestamp_hex_len = 10;
    varying uint8 timestamp_hex[11];

    for (uniform int j = 0; j < timestamp_hex_len; ++j) {
        uniform int shift = 4 * (timestamp_hex_len - 1 - j);
        varying int nib = (timestamp >> shift) & 0xF;
        varying uint8 ch;
        if (nib < 10)
            ch = (uint8)(48 + nib);        // '0' = 48
        else
            ch = (uint8)(97 + (nib - 10)); // 'a' = 97
        timestamp_hex[j] = ch;
        // print("lane %, timestamp nib %  \n", programIndex,timestamp_hex[j]);
    }
    timestamp_hex[timestamp_hex_len] = 0;

    //----------------------------------------------------------------------
    // Convert counter -> 3-digit hex (ASCII-based)
    //----------------------------------------------------------------------
    uniform int counter_hex_len = 3;
    varying uint8 counter_hex[4];

    for (uniform int j = 0; j < counter_hex_len; ++j) {
        uniform int shift = 4 * (counter_hex_len - 1 - j);
        varying int nib = (counter >> shift) & 0xF;

        varying uint8 ch;
        if (nib < 10)
            ch = (uint8)(48 + nib);        // 48 = '0'
        else
            ch = (uint8)(97 + (nib - 10)); // 97 = 'a'

        counter_hex[j] = ch;
    }
    counter_hex[counter_hex_len] = 0;

    //----------------------------------------------------------------------
    // Build final ID string
    //----------------------------------------------------------------------
    // Copy machine_id
    for (uniform int j = 0; j < machine_len; ++j) {
        varying uint8 h = machine_id[j];
        out_buf[j] = h;
        // *((varying uint8*)dst) = h;
        // dst += 1;
        // print("lane % machine_id char % % \n", programIndex,h ,out_buf[j]);
    }

    // Append timestamp hex
    for (uniform int j = 0; j < timestamp_hex_len; ++j) {
        varying uint8 h = timestamp_hex[j];
        varying int offset = machine_len + j;
        out_buf[offset] = h;
        
        // *((varying uint8*)dst) = h;
        // dst += 1;
        // print("lane % timestamp char % % \n", programIndex, h,out_buf[offset]);
    }

    // Append counter hex
    for (uniform int j = 0; j < counter_hex_len; ++j) {
        varying uint8 h = counter_hex[j];
        varying int offset = machine_len + timestamp_hex_len + j;
        out_buf[offset] = h;
        // *((varying uint8*)dst) = h;
        // dst += 1;
        // print("lane % counter char % \n", programIndex, out_buf[offset]);
    }
    varying int offset = machine_len + timestamp_hex_len + counter_hex_len;
    out_buf[offset] = 0;
//----------------------------------------------------------------------
 // Convert generated hex string to int64 and mask like C++ stoul(...,16)
 // result = stoul(hex_str, nullptr, 16) & 0x7FFFFFFFFFFFFFFF
//----------------------------------------------------------------------
uniform int id_len = machine_len + timestamp_hex_len + counter_hex_len;
varying uint64 id_value = 0;

// Pointer to this lane's ID string
// varying uintptr_t id_ptr = (varying uintptr_t)(&out_buf[0]);
// Parse hex characters
// print("lane % generated id string %\n", i, (varying uint8*)id_ptr);
for ( int j = 0; j < id_len; j++) {
    varying uint8 c = out_buf[j];
    
    varying int64 v;

    if (c >= 48 && c <= 57)             // 0–9
        v = (int64)(c - 48);
    else if (c >= 97 && c <= 102)       // a–f
        v = (int64)(c - 97 + 10);
    else if (c >= 65 && c <= 70)        // A–F
        v = (int64)(c - 65 + 10);
    else
        break;

    id_value = (id_value << 4) | v;
}

// Apply mask 0x7FFFFFFFFFFFFFFF
    // print("lane % final id numeric %\n", programIndex, id_value);

id_value = id_value & 0x7FFFFFFFFFFFFFFF;
return id_value;

    // Debug (optional)

}

//--------------------------------------------------
// Batch kernel: each lane posts one message
//--------------------------------------------------
export void newPost_batch(uniform PostMap &map,
                            uniform  uint8 machine_id[],
                            uniform int machine_len,
                          uniform const int user_ids[],
                          uniform const uint8 post_texts[], // [N * MAX_POST_LEN]
                          uniform int64 post_ids[],          // [N]
                          uniform int N,
                          uniform int64 lane_start_times[],  // [N] - output (actual execution start)
                          uniform int64 lane_end_times[],    // [N] - output
                          uniform int64 &global_start_time)  // output - when all requests arrived
{
    // Capture the global start time - all requests arrive at this time
    global_start_time = clock();
    
    foreach (i = 0 ... N) {
            // Record when this lane actually starts (includes queueing delay)
            int64 actual_start_time = clock();
            
            int user_id = user_ids[i];
            uint8 *post_txt = &post_texts[i * MAX_POST_LEN];
            int64 post_id = generate_unique_id(machine_id, machine_len,i); // can come from UploadUniqueId()

        insert_post(map, user_id, post_txt, post_id);
        
        int64 end_time = clock();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}

export void getPostByUser_batch(uniform const PostMap &map,
                                uniform  int query_user_ids[],
                                uniform int N,
                                uniform uint8 out_posts[],  // [N * MAX_RESULTS * MAX_POST_LEN]
                                uniform int out_counts[],   // [N]
                                uniform int64 lane_start_times[],  // [N] - output (actual execution start)
                                uniform int64 lane_end_times[],    // [N] - output
                                uniform int64 &global_start_time)  // output - when all requests arrived
{
    // Capture the global start time - all requests arrive at this time
    global_start_time = clock();
    
    foreach (i = 0 ... N) {
         // Record when this lane actually starts (includes queueing delay)
         int64 actual_start_time = clock();
         
         int query_id = query_user_ids[i];
         int found = 0;

        // Each lane will write its results to its region in out_posts
        uniform uint8 *dst = &out_posts[i * MAX_RESULTS * MAX_POST_LEN];

        for (uniform int j = 0; j < map.next_slot; j++) {
            if (map.user_ids[j] == query_id) {
                // copy post text to this lane's result region
                uniform uint8 *src = &map.posts[j].post_string[0];
                uniform uint8 *dst_post = &dst[found * MAX_POST_LEN];

                for (uniform int k = 0; k < MAX_POST_LEN; k++) {
                    dst_post[k] = src[k];
                    if (src[k] == 0) break;
                }

                found++;
                if (found >= MAX_RESULTS) break;
            }
        }

        int64 end_time = clock();
        out_counts[i] = found;
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}
