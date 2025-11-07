#define MAX_LEN 128

#define MAX_ENTRIES 1024   // capacity of the "memcached" map



inline uniform int ustrlen(uniform uint8 *s, uniform int maxn) {
    for (uniform int i = 0; i < maxn; ++i)
        if (s[i] == 0) return i;
    return maxn;
}

inline varying  uint64 hash_djb2(varying uintptr_t p) {
    varying uint64 h = 5381ul;
for (uniform int j = 0; j < MAX_LEN - 1; ++j) {
        // load one byte per lane
        varying uint8 b = *((uint8*)p);
        //print("in hash % % \n",p,b);
        // stop if all lanes hit 0
        print("in hash % %\n",b,h);
        if ((b == 0)) break;

        // update hash
        h = ((h << 5) + h) + b;
        
        // advance per-lane pointer
        p += 1;
    }
    return h;
}


//-------------------------------------------------------
// Simple static URL map (shared uniform structure)
//-------------------------------------------------------
struct URLMap {
    uniform uint8 shortURLs[MAX_ENTRIES][MAX_LEN];
    uniform uint8 longURLs [MAX_ENTRIES][MAX_LEN];
    uniform int   count;
};

//-------------------------------------------------------
// uniform strcmp (check equality of two uniform strings)
//-------------------------------------------------------
  bool ustrcmp_eq( uint8 *a,  uint8 *b) {
    for ( int j = 0; j < MAX_LEN; ++j) {
         uint8 ca = a[j];
         uint8 cb = b[j];
        if (ca != cb) return false;
        if (ca == 0 || cb == 0) break;
    }
    return true;
}

//-------------------------------------------------------
// uniform lookup in URLMap (linear search)
//-------------------------------------------------------
  int find_url(uniform URLMap &map,  uint8 *longURL) {
        for ( int i = 0; i < map.count; ++i)
            if (ustrcmp_eq(&map.longURLs[i][0], longURL))
                return i;
    return -1;
}

 void insert_into_map(uniform URLMap &map,
                            uint8 *longURL,
                            uint8 *shortURL) {
    if (map.count >= MAX_ENTRIES) return;
    print("adding %",map.count);
    varying int32 x =1;
    varying int slot = atomic_add_global(&map.count, x);
    print("adding %",slot);
    for (int j = 0; j < MAX_LEN; ++j) {
        map.longURLs [slot][j] = longURL[j];
        map.shortURLs[slot][j] = shortURL[j];
        if (longURL[j] == 0 && shortURL[j] == 0) break;
    }
 }
export void concat_batch(uniform URLMap &map,
                        uniform uint8 HOSTNAME[],
                         uniform uint8 tokens_buf[],   // all tokens flattened
                         uniform int   offsets[],      // per-lane token offset
                         uniform int   N,
                         uniform uint8 out_buf[],      // output: N * MAX_LEN
                         uniform int64 lane_start_times[],  // [N] - output
                         uniform int64 lane_end_times[],    // [N] - output
                         uniform int64 &global_start_time)  // output
{
    // Capture global start - all requests arrive at this time
    global_start_time = clock();
    
    uniform int host_len = ustrlen(HOSTNAME, MAX_LEN);
    if (host_len >= MAX_LEN) host_len = MAX_LEN - 1;
    uniform uint8 alphabet[62] = {
        97,98,99,100,101,102,103,104,105,106,107,108,109,110,111,112,113,114,115,116,117,118,119,120,121,122, // a–z
        65,66,67,68,69,70,71,72,73,74,75,76,77,78,79,80,81,82,83,84,85,86,87,88,89,90,                         // A–Z
        48,49,50,51,52,53,54,55,56,57                                                                          // 0–9
    };
    print("map %", &map);


    foreach (i = 0 ... N) {
        // Record when this lane actually starts
        int64 actual_start_time = clock();
        // per-lane start of its token
        // varying int off = offsets[i];
        // print("off %", off);
        varying uintptr_t longURL = (varying uintptr_t)(tokens_buf + i * MAX_LEN);
        varying uintptr_t dstp = (varying uintptr_t)(out_buf + i * MAX_LEN);
        print("longURL % % \n", (varying uint8*)longURL, *((varying uint8*)longURL));

        //---------------------------------------------------
        // 1️⃣ Lookup in map
        //---------------------------------------------------
        int found = find_url(map, ( uint8*)longURL);
        print ("found %",found);
        if (found >= 0) {
            // Reuse existing short URL

            for (int j = 0; j < MAX_LEN; ++j) {
                varying uint8 h = map.shortURLs[found][j];
                *((varying uint8*)dstp) = h;
                dstp += 1;
                if (h == 0) break;
            }
            
            // Record timing even for cache hits
            int64 end_time = clock();
            lane_start_times[i] = actual_start_time;
            lane_end_times[i] = end_time;
            continue;
        }




        // per-lane destination base
        

        //-------------------------------------------------------
        // copy HOSTNAME (uniform → varying)
        //-------------------------------------------------------
        for (uniform int j = 0; j < host_len && j < MAX_LEN - 1; ++j) {
            varying uint8 h = HOSTNAME[j];
            *((varying uint8*)dstp) = h;
            dstp += 1;
        }
        print("before longURL % % \n", (varying uint8*)longURL, *((varying uint8*)longURL));
        varying uint64 id = hash_djb2(longURL);
        print("lane hash %\n", id);
        
        varying uintptr_t dst_tokp = dstp;  // overwrite in place
        varying bool zero = (id == 0ull);
        if ((zero)) {
            *((varying uint8*)dst_tokp) = alphabet[0];
            dst_tokp += 1;
        }

        for (uniform int j = 0; j < MAX_LEN - 1; ++j) {
            varying bool active = (id > 0ull);
            if (!(active)) break;

            varying uint64 q = id / 62ull;
            varying uint64 r = id - q * 62ull;
            *((varying uint8*)dst_tokp) = alphabet[r];
            print(" id % q % r % [r] % \n",id,q,r,alphabet[r]); ;
            dst_tokp += 1;
            id = q;
        }

        // terminate encoded token
        *((varying uint8*)dst_tokp) = 0;

        //-------------------------------------------------------
        // append token (varying → varying, per-lane)
        //-------------------------------------------------------
        // for ( int j = 0; j < MAX_LEN - host_len - 1; ++j) {
        //     // read from each lane’s own token pointer + j
        //     varying uint8 b = *((uint8*)longURL);
        //     print("b --- % ",b);
        //     *((varying uint8*)dstp) = b;
        //     dstp += 1;
        //     longURL+=1;
        //     print("delta=%\n", (int)((intptr_t)(varying uint8*)(longURL + j) - (intptr_t)longURL));
        //     if ((b == 0)) break;   // uniform exit when all lanes hit NUL
        // }

        //-------------------------------------------------------
        // terminate safely
        //-------------------------------------------------------
        *((varying uint8*)( (varying uintptr_t)(out_buf + i * MAX_LEN) + (MAX_LEN - 1) )) = 0;
        longURL = (varying uintptr_t)(tokens_buf + i * MAX_LEN);
        dstp = (varying uintptr_t)(out_buf + i * MAX_LEN);
        insert_into_map(map, ( uint8*)longURL, ( uint8*)dstp);
        
        // Record when this lane ends
        int64 end_time = clock();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}

