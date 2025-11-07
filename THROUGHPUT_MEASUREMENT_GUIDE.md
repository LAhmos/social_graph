# Throughput and Per-Lane Latency Measurement Guide

This guide explains how to add throughput and per-lane latency measurements to ISPC kernels across the socialGraph project.

## What Was Added to `post/` Directory

The `post/simple.cpp` and `post/simple.ispc` now include:

1. **Global start time tracking** - All requests are assumed to arrive at the same time
2. **Per-lane timing** - Each lane records when it actually starts and ends execution
3. **Queueing delay measurement** - Time each lane waits before execution
4. **Execution time measurement** - Actual work done by each lane
5. **Cache warming analysis** - Shows cold start vs warm cache performance

## How to Apply to Other Directories

### 1. Modify ISPC Kernel Functions

Add these parameters to each batch kernel:

```ispc
export void your_kernel_batch(
    // ... existing parameters ...
    uniform int64 lane_start_times[],  // [N] - output (actual execution start)
    uniform int64 lane_end_times[],    // [N] - output  
    uniform int64 &global_start_time)  // output - when all requests arrived
{
    // Capture global start (all requests arrive at this time)
    global_start_time = clock();
    
    foreach (i = 0 ... N) {
        // Record when this lane actually starts
        int64 actual_start_time = clock();
        
        // ... your kernel work here ...
        
        // Record when this lane ends
        int64 end_time = clock();
        lane_start_times[i] = actual_start_time;
        lane_end_times[i] = end_time;
    }
}
```

### 2. Modify C++ Calling Code

Add timing arrays and global start variable:

```cpp
std::vector<int64_t> lane_start(N, 0);
std::vector<int64_t> lane_end(N, 0);
int64_t global_start = 0;

auto start_time = std::chrono::high_resolution_clock::now();

ispc::your_kernel_batch(
    // ... existing parameters ...
    lane_start.data(),
    lane_end.data(),
    global_start);

auto end_time = std::chrono::high_resolution_clock::now();
```

### 3. Add Analysis Code

```cpp
// Calculate throughput
auto duration_ns = std::chrono::duration_cast<std::chrono::nanoseconds>(end_time - start_time);
double throughput = (N * 1000000000.0) / duration_ns.count();

std::cout << "Throughput: " << throughput << " ops/sec\n";

// Analyze per-lane timing
std::cout << "\n--- Per-Lane Analysis ---\n";
for (int group = 0; group < N / 8; group++) {
    int64_t group_queue_delay = lane_start[group * 8] - global_start;
    int64_t group_exec_sum = 0;
    for (int i = 0; i < 8; i++) {
        group_exec_sum += (lane_end[group * 8 + i] - lane_start[group * 8 + i]);
    }
    double group_exec_avg = group_exec_sum / 8.0;
    
    std::cout << "Group " << group 
              << " - Queue: " << group_queue_delay 
              << " cycles, Exec: " << group_exec_avg << " cycles\n";
}

// Show cache warming effects
std::cout << "\nCache warming effect:\n";
int64_t first_group_exec = lane_end[0] - lane_start[0];
int64_t last_group_exec = lane_end[N-8] - lane_start[N-8];
std::cout << "First group: " << first_group_exec << " cycles (cold)\n";
std::cout << "Last group: " << last_group_exec << " cycles (warm)\n";
std::cout << "Speedup: " << (double)first_group_exec / last_group_exec << "x\n";
```

## Directories to Update

### 1. `/socialGraph/user/` - User registration and login
**Kernels to update:**
- `newUser_batch()` - User registration
- `login_batch()` - User authentication

**Key measurements:**
- Registration throughput (users/sec)
- Login throughput (logins/sec)
- Password hashing latency per lane
- Queueing delays for authentication

### 2. `/socialGraph/uniqueID/` - Unique ID generation
**Kernels to update:**
- ID generation batch kernel

**Key measurements:**
- ID generation throughput (IDs/sec)
- Per-lane ID generation latency
- Timestamp generation overhead

### 3. `/socialGraph/shortURL/` - URL shortening
**Kernels to update:**
- URL composition/shortening kernel

**Key measurements:**
- URL shortening throughput (URLs/sec)
- Per-lane URL processing latency

### 4. `/socialGraph/userTag/` - User tagging operations
**Kernels to update:**
- Tag creation/lookup kernels

**Key measurements:**
- Tagging throughput (tags/sec)
- Tag lookup latency per lane

## Key Metrics to Track

For each kernel, measure:

1. **Overall Throughput**: Operations per second for the entire batch
2. **Queueing Delay**: Time each lane waits before starting execution
3. **Execution Time**: Actual work done by each lane
4. **Total Latency**: Queueing + Execution (what users experience)
5. **Cache Warming Effect**: First SIMD group vs subsequent groups
6. **Variation**: Min, max, average, and standard deviation

## Important Findings from `post/` Analysis

1. **5-6x cold start penalty**: First SIMD group is 5-6x slower than warmed groups
2. **Queueing dominates variation**: With uniform workloads, 70-80% of latency variation comes from queueing
3. **Stabilization after 2-3 groups**: Cache effects stabilize quickly
4. **SIMD synchronization**: All lanes in a group start together but later groups have massive queueing delays

## Example Output Format

```
=== Kernel Performance ===
Operations: 64
Execution time: 33 μs
Throughput: 1,896,240 ops/sec
Average latency: 527 ns/op

Summary by SIMD group:
  Group 0: Queue=80 cycles, Exec=53,898 cycles (cold start)
  Group 1: Queue=54,016 cycles, Exec=12,596 cycles (4.28x faster)
  Group 2: Queue=66,632 cycles, Exec=9,972 cycles (5.40x faster)
  ...
  Group 7: Queue=114,582 cycles, Exec=9,294 cycles (5.80x faster)

Cache warming effect: 5.8x speedup after warmup
Queueing contributes 77% of latency variation
```

## Reference Implementation

See `/socialGraph/post/simple.cpp` and `/socialGraph/post/simple.ispc` for the complete implementation.

## Benefits

1. **Performance insights**: Understand true kernel performance vs cold start penalties
2. **Queueing analysis**: See how SIMD batching creates head-of-line blocking
3. **Optimization opportunities**: Identify cache effects and workload imbalances
4. **Realistic latency estimates**: Include queueing delays that users actually experience
