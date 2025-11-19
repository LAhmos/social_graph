#define CUSTOM_EPOCH 1514764800000

// OPTIMIZED: Structure-of-Arrays (SoA) layout for SIMD-friendly access
// Instead of storing each ID as a row, we store all IDs in columnar format
export void UploadUniqueIdBatch_Optimized(uniform uint8 machine_id[],
                                           uniform int machine_len,
                                           uniform int N,
                                           uniform uint8 out_buf_transposed[],  // Now flat array [32][N]
                                           uniform int64 lane_start_times[],
                                           uniform int64 lane_end_times[],
                                           uniform int64 &global_start_time)
{
    global_start_time = clock();
    
    // Process in groups of programCount (8 for avx2-i32x8)
    uniform int num_full_groups = N / programCount;
    uniform int remainder = N % programCount;
    
    // Capture single timestamp for all IDs (like original)
    uniform int64 base_timestamp = clock();
    
    for (uniform int group = 0; group < num_full_groups; group++) {
        uniform int base_idx = group * programCount;
        
        // Each lane processes one ID in this group
        varying int i = base_idx + programIndex;
        
        int64 actual_start_time = base_timestamp;
        
        //----------------------------------------------------------------------
        // Generate timestamp and counter (same logic as original)
        //----------------------------------------------------------------------
        varying int64 timestamp = base_timestamp + (varying int64)i;
        varying int counter = i;
        
        //----------------------------------------------------------------------
        // Build final ID string in TRANSPOSED layout - WRITE DIRECTLY!
        // KEY OPTIMIZATION: No intermediate arrays, write straight to output
        // This eliminates 15 vector registers (11 + 4 from hex arrays)
        //----------------------------------------------------------------------
        uniform int byte_offset = 0;
        
        // Copy machine_id (all lanes write same bytes, but to different positions)
        for (uniform int j = 0; j < machine_len; ++j) {
            varying uint8 ch = machine_id[j];
            uniform uint8* row_ptr = &out_buf_transposed[byte_offset * N];
            row_ptr[programIndex] = ch;  // CONTIGUOUS WRITE!
            byte_offset++;
        }
        
        // Convert timestamp -> 10-digit hex and write directly
        uniform int timestamp_hex_len = 10;
        for (uniform int j = 0; j < timestamp_hex_len; ++j) {
            uniform int shift = 4 * (timestamp_hex_len - 1 - j);
            varying int nib = (timestamp >> shift) & 0xF;
            // Compute ASCII character directly
            varying uint8 ch = (nib < 10) ? (uint8)(48 + nib) : (uint8)(97 + (nib - 10));
            // Write immediately - no intermediate storage!
            uniform uint8* row_ptr = &out_buf_transposed[byte_offset * N];
            row_ptr[programIndex] = ch;
            byte_offset++;
        }
        
        // Convert counter -> 3-digit hex and write directly
        uniform int counter_hex_len = 3;
        for (uniform int j = 0; j < counter_hex_len; ++j) {
            uniform int shift = 4 * (counter_hex_len - 1 - j);
            varying int nib = (counter >> shift) & 0xF;
            // Compute and write in one step
            varying uint8 ch = (nib < 10) ? (uint8)(48 + nib) : (uint8)(97 + (nib - 10));
            uniform uint8* row_ptr = &out_buf_transposed[byte_offset * N];
            row_ptr[programIndex] = ch;
            byte_offset++;
        }
        
        // Null terminator
        uniform uint8* row_ptr = &out_buf_transposed[byte_offset * N];
        row_ptr[programIndex] = 0;
        
        int64 end_time = clock();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
    
    // Handle remainder with masking (if N is not multiple of 8)
    if (remainder > 0) {
        uniform int base_idx = num_full_groups * programCount;
        varying int i = base_idx + programIndex;
        
        // Only process if within bounds
        if (programIndex < remainder) {
            int64 actual_start_time = base_timestamp;
            
            varying int64 timestamp = base_timestamp + (varying int64)i;
            varying int counter = i;
            
            // Write directly without intermediate arrays
            uniform int byte_offset = 0;
            
            // Machine ID
            for (uniform int j = 0; j < machine_len; ++j) {
                if (programIndex < remainder) {
                    varying uint8 ch = machine_id[j];
                    out_buf_transposed[byte_offset * N + i] = ch;
                }
                byte_offset++;
            }
            
            // Timestamp hex - compute and write directly
            uniform int timestamp_hex_len = 10;
            for (uniform int j = 0; j < timestamp_hex_len; ++j) {
                if (programIndex < remainder) {
                    uniform int shift = 4 * (timestamp_hex_len - 1 - j);
                    varying int nib = (timestamp >> shift) & 0xF;
                    varying uint8 ch = (nib < 10) ? (uint8)(48 + nib) : (uint8)(97 + (nib - 10));
                    out_buf_transposed[byte_offset * N + i] = ch;
                }
                byte_offset++;
            }
            
            // Counter hex - compute and write directly
            uniform int counter_hex_len = 3;
            for (uniform int j = 0; j < counter_hex_len; ++j) {
                if (programIndex < remainder) {
                    uniform int shift = 4 * (counter_hex_len - 1 - j);
                    varying int nib = (counter >> shift) & 0xF;
                    varying uint8 ch = (nib < 10) ? (uint8)(48 + nib) : (uint8)(97 + (nib - 10));
                    out_buf_transposed[byte_offset * N + i] = ch;
                }
                byte_offset++;
            }
            
            if (programIndex < remainder) {
                out_buf_transposed[byte_offset * N + i] = 0;
            }
            
            int64 end_time = clock();
            lane_start_times[i] = actual_start_time;
            lane_end_times[i] = end_time;
        }
    }
}

// ALTERNATIVE: Hybrid approach - batch writes to temporary aligned buffer, then copy
export void UploadUniqueIdBatch_Hybrid(uniform uint8 machine_id[],
                                        uniform int machine_len,
                                        uniform int N,
                                        uniform uint8 out_buf[][32],
                                        uniform int64 lane_start_times[],
                                        uniform int64 lane_end_times[],
                                        uniform int64 &global_start_time)
{
    global_start_time = clock();
    
    foreach (i = 0 ... N) {
        int64 actual_start_time = clock();
        
        //----------------------------------------------------------------------
        // Generate timestamp and counter
        //----------------------------------------------------------------------
        varying int64 timestamp = (int64)clock() + (varying int64)i;
        varying int counter = i;
        
        //----------------------------------------------------------------------
        // Build ID in LOCAL BUFFER first (avoids scatter until the end)
        //----------------------------------------------------------------------
        varying uint8 local_id[32];  // Stack-allocated per lane
        varying int pos = 0;
        
        // Copy machine_id
        for (uniform int j = 0; j < machine_len; ++j) {
            local_id[pos++] = machine_id[j];
        }
        
        // Convert and append timestamp
        uniform int timestamp_hex_len = 10;
        for (uniform int j = 0; j < timestamp_hex_len; ++j) {
            uniform int shift = 4 * (timestamp_hex_len - 1 - j);
            varying int nib = (timestamp >> shift) & 0xF;
            varying uint8 ch = (nib < 10) ? (uint8)(48 + nib) : (uint8)(97 + (nib - 10));
            local_id[pos++] = ch;
        }
        
        // Convert and append counter
        uniform int counter_hex_len = 3;
        for (uniform int j = 0; j < counter_hex_len; ++j) {
            uniform int shift = 4 * (counter_hex_len - 1 - j);
            varying int nib = (counter >> shift) & 0xF;
            varying uint8 ch = (nib < 10) ? (uint8)(48 + nib) : (uint8)(97 + (nib - 10));
            local_id[pos++] = ch;
        }
        local_id[pos] = 0;
        
        //----------------------------------------------------------------------
        // OPTIMIZED COPY: Use fully unrolled copy to minimize scatter overhead
        // Copy entire 32-byte local buffer to output
        //----------------------------------------------------------------------
        // Each lane writes to its own row in out_buf
        // This is still scatter, but minimized to 32 operations instead of scattered byte-by-byte
        
        // Fully unroll the copy (let compiler optimize)
        out_buf[i][0] = local_id[0];
        out_buf[i][1] = local_id[1];
        out_buf[i][2] = local_id[2];
        out_buf[i][3] = local_id[3];
        out_buf[i][4] = local_id[4];
        out_buf[i][5] = local_id[5];
        out_buf[i][6] = local_id[6];
        out_buf[i][7] = local_id[7];
        out_buf[i][8] = local_id[8];
        out_buf[i][9] = local_id[9];
        out_buf[i][10] = local_id[10];
        out_buf[i][11] = local_id[11];
        out_buf[i][12] = local_id[12];
        out_buf[i][13] = local_id[13];
        out_buf[i][14] = local_id[14];
        out_buf[i][15] = local_id[15];
        out_buf[i][16] = local_id[16];
        out_buf[i][17] = local_id[17];
        out_buf[i][18] = local_id[18];
        out_buf[i][19] = local_id[19];
        out_buf[i][20] = local_id[20];
        out_buf[i][21] = local_id[21];
        out_buf[i][22] = local_id[22];
        out_buf[i][23] = local_id[23];
        out_buf[i][24] = local_id[24];
        out_buf[i][25] = local_id[25];
        out_buf[i][26] = local_id[26];
        out_buf[i][27] = local_id[27];
        out_buf[i][28] = local_id[28];
        out_buf[i][29] = local_id[29];
        out_buf[i][30] = local_id[30];
        out_buf[i][31] = local_id[31];
        
        int64 end_time = clock();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}
