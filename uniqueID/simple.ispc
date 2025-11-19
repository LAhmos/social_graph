#define CUSTOM_EPOCH 1514764800000

// Each lane generates a unique ID string: machine_id + timestamp_hex + counter_hex
export void UploadUniqueIdBatch(uniform uint8 machine_id[],  // e.g., "gpu01"
                                uniform int machine_len,
                                uniform int N,
                                uniform uint8 out_buf[][32],
                                uniform int64 lane_start_times[],  // [N] - output
                                uniform int64 lane_end_times[],    // [N] - output
                                uniform int64 &global_start_time)  // output
{
    // Capture global start - all requests arrive at this time
    global_start_time = clock();
    
    foreach (i = 0 ... N) {
        // Record when this lane actually starts
        int64 actual_start_time = clock();
        
        //----------------------------------------------------------------------
        // Generate pseudo-timestamp and lane counter
        //----------------------------------------------------------------------
        varying int64 timestamp = (int64)clock() + (varying int64)i;
        varying int   counter   = i;
        //print("lane % timestamp % counter %\n", programIndex, timestamp, counter);

        //----------------------------------------------------------------------
        // Convert timestamp -> 10-digit hex (ASCII-based)
        //----------------------------------------------------------------------
        uniform int timestamp_hex_len = 10;
        varying uint8 timestamp_hex[11];

        for (uniform int j = 0; j < timestamp_hex_len; ++j) {
            uniform int shift = 4 * (timestamp_hex_len - 1 - j);
            varying int nib = (timestamp >> shift) & 0xF;
            //print(" shift % \n",shift);
            // ASCII conversion without quotes
            varying uint8 ch;
            if (nib < 10)
                ch = (uint8)(48 + nib);        // '0' = 48
            else
                ch = (uint8)(97 + (nib - 10)); // 'a' = 97
            //print("lane % timestamp nib % ch % % \n", programIndex, nib, ch, ch);
            timestamp_hex[j] = ch;
        }
        timestamp_hex[timestamp_hex_len] = 0;

        //----------------------------------------------------------------------
        // Convert counter -> 3-digit hex (ASCII-based)
        //----------------------------------------------------------------------
        uniform int counter_hex_len = 3;
        varying uint8 counter_hex[4];

        for (uniform int j = 0; j < counter_hex_len; ++j) {
            //print("lane % counter % j %\n", programIndex, counter, j);
            uniform int shift = 4 * (counter_hex_len - 1 - j);
            varying int nib = (counter >> shift) & 0xF;

            varying uint8 ch;
            if (nib < 10)
                ch = (uint8)(48 + nib);        // 48 = '0'
            else
                ch = (uint8)(97 + (nib - 10)); // 97 = 'a'

            counter_hex[j] = ch;
          //  print("lane % counter nib % ch % % \n", programIndex, nib, ch, counter_hex[j]);
        }
        counter_hex[counter_hex_len] = 0;

        //----------------------------------------------------------------------
        // Build final ID string
        //----------------------------------------------------------------------
        uniform int stride = 32; // size of each record

varying uintptr_t dst = (varying uintptr_t)(&out_buf[0]) + (varying uintptr_t)(i * stride);
//print("lane % dst %\n", i, (varying uint8*)dst);
    

        // Copy machine_id
        for (uniform int j = 0; j < machine_len; ++j){
                  varying uint8 h = machine_id[j];
                *((varying uint8*)dst) = h;
                dst += 1;
             //   print("lane % machine_id char % \n", programIndex, h);
        }

        // Append timestamp hex
        for (uniform int j = 0; j < timestamp_hex_len; ++j){
            varying uint8 h = timestamp_hex[j];
            *((varying uint8*)dst) = h;
            dst += 1;
           // print("lane % timestamp char % \n", programIndex, h);

        }

        // Append counter hex
        for (uniform int j = 0; j < counter_hex_len; ++j){
                varying uint8 h = counter_hex[j];
                *((varying uint8*)dst) = h;
                dst += 1;
              //  print("lane % counter char % \n", programIndex, h);
        }

        *((varying uint8*)dst) = 0;
        
        // Record when this lane ends
        int64 end_time = clock();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}
