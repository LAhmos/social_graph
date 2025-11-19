//----------------------------------------------------------------------
// Generate unique ID based on timestamp + lane counter
//----------------------------------------------------------------------
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
    // //print("lane % timestamp % counter %\n", programIndex, timestamp, counter);

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
        // //print("lane %, timestamp nib %  \n", programIndex,timestamp_hex[j]);
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
        // //print("lane % machine_id char % % \n", programIndex,h ,out_buf[j]);
    }

    // Append timestamp hex
    for (uniform int j = 0; j < timestamp_hex_len; ++j) {
        varying uint8 h = timestamp_hex[j];
        varying int offset = machine_len + j;
        out_buf[offset] = h;
        
        // *((varying uint8*)dst) = h;
        // dst += 1;
        // //print("lane % timestamp char % % \n", programIndex, h,out_buf[offset]);
    }

    // Append counter hex
    for (uniform int j = 0; j < counter_hex_len; ++j) {
        varying uint8 h = counter_hex[j];
        varying int offset = machine_len + timestamp_hex_len + j;
        out_buf[offset] = h;
        // *((varying uint8*)dst) = h;
        // dst += 1;
        // //print("lane % counter char % \n", programIndex, out_buf[offset]);
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
// //print("lane % generated id string %\n", i, (varying uint8*)id_ptr);
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
    // //print("lane % final id numeric %\n", programIndex, id_value);

id_value = id_value & 0x7FFFFFFFFFFFFFFF;
return id_value;

    // Debug (optional)

}

#define MAX_USERS   1024
#define MAX_FIELD   32
#define HASH_TABLE_SIZE 2048  // Hash table size (power of 2 for fast modulo)

export struct User {
    uint8 first_name[MAX_FIELD];
    uint8 last_name[MAX_FIELD];
    uint8 username[MAX_FIELD];
    uint8 date_birth[MAX_FIELD];
    uint8 password_hashed[65];  // 64 hex chars + '\0'
    int64 user_id;             // numeric unique ID per lane
};

// Structure of Arrays (SoA) layout for better SIMD performance + Hash Table
export struct UserMap {
    uniform uint8 usernames[MAX_USERS][MAX_FIELD];      // keys
    uniform uint8 first_names[MAX_USERS][MAX_FIELD];    // first names
    uniform uint8 last_names[MAX_USERS][MAX_FIELD];     // last names
    uniform uint8 dates_birth[MAX_USERS][MAX_FIELD];    // dates of birth
    uniform uint8 passwords_hashed[MAX_USERS][65];      // password hashes
    uniform int64 user_ids[MAX_USERS];                  // user IDs
    uniform int   count;                                // number of entries
    
    // Hash table for O(1) lookup: maps hash -> entry_index (-1 means empty)
    uniform int   hashTable[HASH_TABLE_SIZE];
    uniform uint64 hashValues[MAX_USERS];  // Store hash for each entry to handle collisions
};

//------------------------------------
// Hash function for usernames (DJB2)
//------------------------------------
inline varying uint64 hash_username(uint8 *username) {
    varying uint64 h = 5381ul;
    for (uniform int j = 0; j < MAX_FIELD; ++j) {
        varying uint8 b = username[j];
        if (b == 0) break;
        h = ((h << 5) + h) + b;
    }
    return h;
}

//------------------------------------
// Hash function for usernames in SoA format
//------------------------------------
inline varying uint64 hash_username_soa(uniform const uint8 username_soa[], uniform int N, varying int current_user_idx) {
    varying uint64 h = 5381ul;
    for (uniform int j = 0; j < MAX_FIELD; ++j) {
        varying uint8 b = username_soa[j * N + current_user_idx];
        if (b == 0) break;
        h = ((h << 5) + h) + b;
    }
    return h;
}

//------------------------------------
// uniform strcmp (for usernames) - AoS version
//------------------------------------
inline bool ustrcmp_eq(  uint8 *a,   uint8 *b) {
    for (uniform int j = 0; j < MAX_FIELD; ++j) {
         uint8 ca = a[j];
         uint8 cb = b[j];
        if (ca != cb) return false;
        if (ca == 0 || cb == 0) break;
    }
    return true;
}

//------------------------------------
// SoA strcmp: compare username stored in SoA format with map entry
// Input: username_soa[char_idx * N + user_idx] = character char_idx of user user_idx
//        current_user_idx = which user this lane is processing
//------------------------------------
inline bool ustrcmp_eq_soa(uniform const uint8 username_soa[], uniform int N, varying int current_user_idx, uniform const uint8 *map_username) {
    for (uniform int j = 0; j < MAX_FIELD; ++j) {
        // Each lane reads character j of its assigned user: username_soa[j * N + current_user_idx]
        varying uint8 ca = username_soa[j * N + current_user_idx];
        varying uint8 cb = map_username[j];
        if (ca != cb) return false;
        if (ca == 0 || cb == 0) break;
    }
    return true;
}

inline bool strcmp_eq(  uint8 *a,   uint8 *b,uint32 len)  {
    for (uniform int j = 0; j < len; ++j) {
         uint8 ca = a[j];
         uint8 cb = b[j];
        //  //print("lane % comparing char % % \n", programIndex, ca , cb );
        if (ca != cb) return false;
        if (ca == 0 || cb == 0) break;
    }
    return true;
}

//------------------------------------
// Lookup: find index of username with efficiency tracking (AoS version)
//------------------------------------
inline int find_user(uniform UserMap &map, uint8 *username, varying int &iterations_done) {
    iterations_done = 0;
    for (uniform int i = 0; i < map.count; ++i) {
        iterations_done++;
        if (ustrcmp_eq(&map.usernames[i][0], username))
            return i;
    }
    return -1;
}

//------------------------------------
// Lookup: find index of username with SoA input (hash table based)
//------------------------------------
inline int find_user_soa(uniform UserMap &map, uniform const uint8 username_soa[], uniform int N, varying int current_user_idx, varying int &iterations_done) {
    iterations_done = 0;
    
    // Compute hash of the input username
    varying uint64 username_hash = hash_username_soa(username_soa, N, current_user_idx);
    
    // Use hash table for O(1) lookup
    varying int hash_idx = (int)(username_hash & (HASH_TABLE_SIZE - 1));  // Fast modulo for power of 2
    varying int entry_idx = map.hashTable[hash_idx];
    
    // Linear probing for collision resolution
    for (uniform int probe = 0; probe < 8; ++probe) {  // Max 8 probes
        iterations_done++;
        
        if (entry_idx == -1) {
            // Empty slot, not found
            return -1;
        }
        
        // Check if hash matches and then verify the actual string
        if (map.hashValues[entry_idx] == username_hash) {
            if (ustrcmp_eq_soa(username_soa, N, current_user_idx, &map.usernames[entry_idx][0]))
                return entry_idx;  // Found!
        }
        
        // Collision, try next slot (linear probing)
        hash_idx = (hash_idx + 1) & (HASH_TABLE_SIZE - 1);
        entry_idx = map.hashTable[hash_idx];
    }
    
    return -1;  // Not found after max probes
}

inline void insert_into_user_map(uniform UserMap &map,
                                  uint8 *username,
                                  User user) {
    if (map.count >= MAX_USERS) return;

    // increment atomically (parallel-safe)
    varying int inc = 1;
    varying int slot = atomic_add_global(&map.count, inc);
    // only one lane inserts for that slot
    //print("Inserted at slot %\n", slot);

    // Compute hash for this username
    varying uint64 username_hash = hash_username(username);
    
    // Store hash value for collision detection
    map.hashValues[slot] = username_hash;
    
    // Insert into hash table with linear probing
    varying int hash_idx = (int)(username_hash & (HASH_TABLE_SIZE - 1));
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

    // copy username key
    for (uniform int j = 0; j < MAX_FIELD; ++j) {
        uint8 c = username[j];
        map.usernames[slot][j] = c;
        if (c == 0) break;
    }

    // copy User fields into SoA arrays
    for (uniform int j = 0; j < MAX_FIELD; ++j) {
        map.first_names[slot][j] = user.first_name[j];
        if (user.first_name[j] == 0) break;
    }
    for (uniform int j = 0; j < MAX_FIELD; ++j) {
        map.last_names[slot][j] = user.last_name[j];
        if (user.last_name[j] == 0) break;
    }
    for (uniform int j = 0; j < MAX_FIELD; ++j) {
        map.dates_birth[slot][j] = user.date_birth[j];
        if (user.date_birth[j] == 0) break;
    }
    for (uniform int j = 0; j < 65; ++j) {
        map.passwords_hashed[slot][j] = user.password_hashed[j];
        if (user.password_hashed[j] == 0) break;
    }
    map.user_ids[slot] = user.user_id;
}


inline  int strlen( uint8 *s) {
    uint32 i = 0;
    while(s[i] != 0) i++;
    return i;
}
inline void hash256_hex_placeholder( uint8* s,  uint8* out64) {
    //print("lane % hashing string %\n", programIndex, out64);
     uint64 h = 1469598103934665603ULL; // FNV-1a basis
     uint64 p = 1099511628211ULL;       // FNV-1a prime
     int len = strlen(s);
    for (int i = 0; i < len; ++i) {
        h ^= (uint64)((uint8)s[i]);
        h *= p;
    }
    // expand to 64 hex chars
    uint64 x = h;
    for (uniform int j = 0; j < 64; ++j) {
        if ((j & 7) == 0 && j) x = x * 6364136223846793005ULL + 1ULL;
        int shift = (j & 7) * 8;
        int nib = (int)((x >> shift) & 0xF);
        out64[j] = (uint8)(nib < 10 ? (48 + nib) : (97 + (nib - 10)));
    }
    out64[64] = 0;
}


inline void strcpy( uint8* dst,  uint8* src) {
     int i = 0;
     uint8 c;
    //print("lane % starting strcpy\n", src);

    // Copy until we reach '\0' per lane
    do {
        c = src[i];
        dst[i] = c;
        // //print("lane % copying char %   % \n", programIndex, c , &dst[i] );
        // //print("lane % copying char %   % \n", programIndex, c , &src[i]);
        i += 1;
    } while (c != 0);

    // Optional: print first few chars for debugging
    // if (programIndex == 0)
    //     //print("lane % copied string\n", programIndex);
}


export void login_batch(
    uniform UserMap &map,
    uniform const uint8 usernames[],
    uniform const uint8 passwords[],
    uniform int N,
    uniform int login_results[],
    uniform int64 lane_start_times[],  // [N] - output
    uniform int64 lane_end_times[],    // [N] - output
    uniform int64 &global_start_time,  // output
    uniform int lane_iterations[])     // [N] - output: iterations each lane did in find_user
{
    // Capture global start - all requests arrive at this time
    global_start_time = clock();
    
    // Allocate hash buffer ONCE outside the foreach loop
    // Number of bytes in each hash
    uniform int HASH_LEN = 65;
    uniform int total_bytes = programCount * HASH_LEN;
    
    // allocate runtime buffer ONCE for all iterations
    uint8* all_hashes = (uint8*)alloca(total_bytes);
    
    foreach (i = 0 ... N) {
        // Record when this lane actually starts
        int64 actual_start_time = clock();
        
        uniform int stride = 32;
        uint8* uname = &usernames[i * stride];
        uint8* pass  = &passwords[i * stride];

        // 1️⃣ Lookup username with efficiency tracking
        int iterations = 0;
        int idx = find_user(map, uname, iterations);
        lane_iterations[i] = iterations;
        //print("lane % looking up username %\n", idx, uname);
        if (idx == -1) {
            
            //print("ERROR: username not found → %\n", uname);
            login_results[i] = 0;
            
            // Record timing even for failed attempts
            int64 end_time = clock();
            lane_start_times[i] = actual_start_time;
            lane_end_times[i] = end_time;
            continue;
        }
        //print("Username % found at index %\n", uname, idx);
        // 2️⃣ Hash entered password
        // Each lane gets its own slice of the pre-allocated buffer
        varying uintptr_t lane_ptr =
            (varying uintptr_t)all_hashes +
            (varying uintptr_t)(programIndex * HASH_LEN);
        varying uint8* entered_hash = (varying uint8*)lane_ptr;

// debug print
//print("lane % entered_hash_ptr %\n", programIndex, entered_hash);

// call uniform hash function per lane
hash256_hex_placeholder(
    (uniform const uint8*)pass,
    (uniform uint8*)&all_hashes[programIndex * HASH_LEN]);


        // for (int j = 0; j < 64; ++j) {
        //      //print("lane % entered hash char % \n", programIndex, entered_hash[j] );
        // }
        // entered_hash[64] = 0;

        // 3️⃣ Compare hashes (using SoA layout)
        uint8* stored_hash = &map.passwords_hashed[idx][0];
        //print("lane % stored hash %\n", programIndex, stored_hash);
        bool match = strcmp_eq((uniform uint8*)&all_hashes[programIndex * HASH_LEN], stored_hash,64);

        if (match) {
            //print("Login successful for %\n", uname);
            login_results[i] = 1;
        } else {
            
                //print("ERROR: password is not correct for %\n", uname);
            login_results[i] = 0;
        }
        
        // Record when this lane ends
        int64 end_time = clock();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}

//=============================================================================
// SoA-optimized login_batch: Input buffers are in SoA layout
// Layout: username_soa[char_idx * N + user_idx] = character char_idx of user user_idx
// This allows consecutive address access across lanes for the same character position
//=============================================================================
export void login_batch_soa(
    uniform UserMap &map,
    uniform const uint8 usernames_soa[],  // SoA: [char0_user0, char0_user1, ..., char1_user0, char1_user1, ...]
    uniform const uint8 passwords_soa[],  // SoA: same layout
    uniform int N,
    uniform int login_results[],
    uniform int64 lane_start_times[],
    uniform int64 lane_end_times[],
    uniform int64 &global_start_time,
    uniform int lane_iterations[])
{
    global_start_time = clock();
    
    // Allocate hash buffer ONCE
    uniform int HASH_LEN = 65;
    uniform int total_bytes = programCount * HASH_LEN;
    uint8* all_hashes = (uint8*)alloca(total_bytes);
    
    // Allocate temporary buffer for password per lane (since hash function expects contiguous string)
    uint8* temp_passwords = (uint8*)alloca(programCount * MAX_FIELD);
    
    foreach (i = 0 ... N) {
        int64 actual_start_time = clock();
        
        // Each foreach iteration processes programCount users (8 for AVX2)
        // Lane programIndex in this iteration processes user at index i
        // All lanes in same iteration form a batch and access consecutive addresses
        
        // 1️⃣ Lookup username using SoA-optimized find
        // In SoA layout: usernames_soa[char_idx * N + user_idx]
        // For user i, character j is at: usernames_soa[j * N + i]
        int iterations = 0;
        int idx = find_user_soa(map, &usernames_soa[0], N, i, iterations);
        lane_iterations[i] = iterations;
        
        if (idx == -1) {
            login_results[i] = 0;
            int64 end_time = clock();
            lane_start_times[i] = actual_start_time;
            lane_end_times[i] = end_time;
            continue;
        }
        
        // 2️⃣ Extract password from SoA into contiguous buffer for hashing
        // Copy characters from SoA layout: passwords_soa[j*N + i] -> temp_passwords[programIndex*MAX_FIELD + j]
        for (uniform int j = 0; j < MAX_FIELD; ++j) {
            varying uint8 c = passwords_soa[j * N + i];
            temp_passwords[programIndex * MAX_FIELD + j] = c;
            if (c == 0) break;
        }
        
        // Hash the password
        hash256_hex_placeholder(
            &temp_passwords[programIndex * MAX_FIELD],
            (uniform uint8*)&all_hashes[programIndex * HASH_LEN]);
        
        // 3️⃣ Compare hashes
        uint8* stored_hash = &map.passwords_hashed[idx][0];
        bool match = strcmp_eq((uniform uint8*)&all_hashes[programIndex * HASH_LEN], stored_hash, 64);
        
        login_results[i] = match ? 1 : 0;
        
        int64 end_time = clock();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}

export void newUser_batch(
    uniform int N,
    uniform  uint8 machine_id[],
    uniform int machine_len,
    uniform uint8 first_names[],
    uniform uint8 last_names[],
    uniform uint8 usernames[],
    uniform uint8 passwords[],
    uniform uint8 dates_birth[],
    uniform User users[],
    uniform UserMap &map,
    uniform int64 lane_start_times[],  // [N] - output
    uniform int64 lane_end_times[],    // [N] - output
    uniform int64 &global_start_time)  // output
{
    // Capture global start - all requests arrive at this time
    global_start_time = clock();
    
    foreach (i = 0 ... N) {
        // Record when this lane actually starts
        int64 actual_start_time = clock();
        
        varying int64 uid = generate_unique_id(machine_id, machine_len,i);
        users[i].user_id = uid;
        uniform int stride = 32;
        varying uintptr_t ps = (varying uintptr_t)(passwords) + (varying uintptr_t)(i * stride);
        hash256_hex_placeholder(( uint8*)ps, (uint8*)&users[i].password_hashed[0]);
        // Copy other fields (first name, last name, username, date of birth)
     // Compute lane-local pointers to the flat buffers
        varying uintptr_t fns = (varying uintptr_t)(first_names) + (varying uintptr_t)(i * stride);
        varying uintptr_t lns = (varying uintptr_t)(last_names)  + (varying uintptr_t)(i * stride);
        varying uintptr_t uns = (varying uintptr_t)(usernames)   + (varying uintptr_t)(i * stride);
        varying uintptr_t dbs = (varying uintptr_t)(dates_birth) + (varying uintptr_t)(i * stride);

        // Cast back to varying uint8* for copying
         uint8* fn_ptr = ( uint8*)fns;
         uint8* ln_ptr = ( uint8*)lns;
         uint8* un_ptr = ( uint8*)uns;
         uint8* db_ptr = ( uint8*)dbs;

        // Copy into struct fields (each lane writes its own record)
        strcpy(( uint8*)&users[i].first_name[0], fn_ptr);
        strcpy(( uint8*)&users[i].last_name[0],  ln_ptr);
        strcpy(( uint8*)&users[i].username[0],   un_ptr);
        strcpy(( uint8*)&users[i].date_birth[0], db_ptr);

        // Check if username exists
    int dummy_iterations = 0;
    int idx = find_user(map, ( uint8*) &users[i].username[0], dummy_iterations);
    if (idx == -1) {
        insert_into_user_map(map, ( uint8*)&users[i].username[0], users[i]);
    } else {
            //print("ERROR: username % already exists\n", users[i].username[0]);
    }

        // Record when this lane ends
        int64 end_time = clock();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;

        // Store ID result (e.g., truncate to 32-bit or keep full 64-bit)
        //user_ids_out[i] = (uniform int)extract(uid, 0);

        // Optional print
        // //print("lane % generated uid %\n", programIndex, uid);
    }
}

//=============================================================================
// SoA-optimized newUser_batch: Input buffers are in SoA layout
// Layout: first_names_soa[char_idx * N + user_idx] = character char_idx of user user_idx
// This allows consecutive address access across lanes for the same character position
//=============================================================================
export void newUser_batch_soa(
    uniform int N,
    uniform uint8 machine_id[],
    uniform int machine_len,
    uniform const uint8 first_names_soa[],   // SoA: [char0_user0, char0_user1, ..., char1_user0, char1_user1, ...]
    uniform const uint8 last_names_soa[],    // SoA: same layout
    uniform const uint8 usernames_soa[],     // SoA: same layout
    uniform const uint8 passwords_soa[],     // SoA: same layout
    uniform const uint8 dates_birth_soa[],   // SoA: same layout
    uniform User users[],
    uniform UserMap &map,
    uniform int64 lane_start_times[],
    uniform int64 lane_end_times[],
    uniform int64 &global_start_time)
{
    global_start_time = clock();
    
    // Allocate hash buffer ONCE
    uniform int HASH_LEN = 65;
    uniform int total_bytes = programCount * HASH_LEN;
    uint8* all_hashes = (uint8*)alloca(total_bytes);
    
    // Allocate temporary buffers for extracting SoA data into contiguous strings
    uint8* temp_first_names = (uint8*)alloca(programCount * MAX_FIELD);
    uint8* temp_last_names = (uint8*)alloca(programCount * MAX_FIELD);
    uint8* temp_usernames = (uint8*)alloca(programCount * MAX_FIELD);
    uint8* temp_passwords = (uint8*)alloca(programCount * MAX_FIELD);
    uint8* temp_dates_birth = (uint8*)alloca(programCount * MAX_FIELD);
    
    foreach (i = 0 ... N) {
        int64 actual_start_time = clock();
        
        // Generate unique ID
        varying int64 uid = generate_unique_id(machine_id, machine_len, i);
        users[i].user_id = uid;
        
        // Extract data from SoA layout into temporary contiguous buffers
        // For user i, character j is at: field_soa[j * N + i]
        
        // Extract first name
        for (uniform int j = 0; j < MAX_FIELD; ++j) {
            varying uint8 c = first_names_soa[j * N + i];
            temp_first_names[programIndex * MAX_FIELD + j] = c;
            users[i].first_name[j] = c;
            if (c == 0) break;
        }
        
        // Extract last name
        for (uniform int j = 0; j < MAX_FIELD; ++j) {
            varying uint8 c = last_names_soa[j * N + i];
            temp_last_names[programIndex * MAX_FIELD + j] = c;
            users[i].last_name[j] = c;
            if (c == 0) break;
        }
        
        // Extract username
        for (uniform int j = 0; j < MAX_FIELD; ++j) {
            varying uint8 c = usernames_soa[j * N + i];
            temp_usernames[programIndex * MAX_FIELD + j] = c;
            users[i].username[j] = c;
            if (c == 0) break;
        }
        
        // Extract date of birth
        for (uniform int j = 0; j < MAX_FIELD; ++j) {
            varying uint8 c = dates_birth_soa[j * N + i];
            temp_dates_birth[programIndex * MAX_FIELD + j] = c;
            users[i].date_birth[j] = c;
            if (c == 0) break;
        }
        
        // Extract password and hash it
        for (uniform int j = 0; j < MAX_FIELD; ++j) {
            varying uint8 c = passwords_soa[j * N + i];
            temp_passwords[programIndex * MAX_FIELD + j] = c;
            if (c == 0) break;
        }
        
        // Hash the password
        hash256_hex_placeholder(
            &temp_passwords[programIndex * MAX_FIELD],
            (uniform uint8*)&all_hashes[programIndex * HASH_LEN]);
        
        // Copy hashed password to user struct
        for (uniform int j = 0; j < 65; ++j) {
            users[i].password_hashed[j] = all_hashes[programIndex * HASH_LEN + j];
        }
        
        // Check if username exists using SoA-optimized find
        int dummy_iterations = 0;
        int idx = find_user_soa(map, &usernames_soa[0], N, i, dummy_iterations);
        
        if (idx == -1) {
            // Username doesn't exist, insert new user
            insert_into_user_map(map, (uint8*)&users[i].username[0], users[i]);
        } else {
            //print("ERROR: username already exists\n");
        }
        
        // Record when this lane ends
        int64 end_time = clock();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}