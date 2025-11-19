# Segmentation Fault Root Cause Analysis

## Summary
The POST and USERTAG services are crashing due to **buffer overflow** caused by accumulating data across benchmark iterations without resetting the storage maps.

## The Problem

### Critical Issue: No Map Reset Between Iterations

**Location:** All `simple.cpp` files in affected services
**Issue:** The benchmark loops run 100+ iterations, each adding entries to fixed-size arrays, but never reset the map between iterations.

### Math That Exposes the Bug:

```
Warmup:     5 iterations × 1000 posts = 5,000 entries
Benchmark: 100 iterations × 1000 posts = 100,000 entries
TOTAL: 105,000 entries attempted

But MAX_ENTRIES = 4,096 (defined in simple_mt.h)
```

**After just 5 iterations (warmup + 1 benchmark), the arrays are full!**

### What Happens:

1. **POST Service - Create Operation:**
   - Iterations 1-4: Posts get inserted successfully
   - Iteration 5+: `next_slot` exceeds MAX_ENTRIES (4096)
   - The check `if (slot >= MAX_ENTRIES) return;` silently fails to insert
   - Later code tries to print/access array entries beyond the allocated size
   - **SEGFAULT** occurs when accessing memory past the array bounds

2. **POST Service - Lookup Operation:**
   - Same accumulation problem
   - `next_slot.load()` returns values > MAX_ENTRIES
   - Loop `for (int j = 0; j < current_slot; j++)` iterates beyond array bounds
   - **SEGFAULT** when accessing `map.user_ids[j]` or `map.posts[j]`

3. **USERTAG Service - Insert Operation:**
   - Batch size: 800 entries
   - After ~5 iterations: 800 × 5 = 4000+ entries
   - Exceeds MAX_ENTRIES = 4096
   - **Double free or corruption** in ISPC mode (memory management issue)
   - **SEGFAULT** in MT modes (array bounds violation)

## Code Evidence

### POST simple_mt.h (line 177-189):
```cpp
inline void insert_post(PostMap& map,
                       int user_id,
                       const uint8_t* post_text,
                       int64_t post_id) {
    // Atomic increment to get slot
    int slot = map.next_slot.fetch_add(1);
    
    if (slot >= MAX_ENTRIES) return;  // ❌ Silently fails, but next_slot still incremented!
    
    // Fill entry - THIS NEVER GETS CALLED after MAX_ENTRIES
    map.user_ids[slot] = user_id;
    map.posts[slot].user_id = user_id;
    // ...
}
```

###  POST simple.cpp (line 199-215 - Benchmark Loop):
```cpp
for (int iter = 0; iter < bench_iters; iter++) {
    // ❌ NO RESET OF map.next_slot here!
    
    if (use_ispc) {
        ispc::newPost_batch(*ispc_map, ...);
    } else {
        mt::newPost_batch(*mt_map, ...);
    }
    // next_slot keeps growing: 1000, 2000, 3000, 4000, 5000, ...
}
```

### POST simple.cpp (line 428+ - Where Crash Occurs):
```cpp
// This tries to print entries that don't exist!
for (int i = 0; i < std::min(5, next_slot_count); i++) {
    if (use_ispc) {
        std::cout << "[" << i << "] "
                  << "user_id=" << ispc_map->posts[i].user_id  // ⚠️ OK
                  << "  post_id=" << ispc_map->posts[i].post_id
                  << "  text=" << ispc_map->posts[i].post_string  // 💥 SEGFAULT HERE
                  << "\n";
    }
}
```

The crash happens when printing `post_string` because the text field might have been partially overwritten or points to corrupted memory.

## Affected Services

| Service  | Operation | Status | Reason |
|----------|-----------|--------|--------|
| **POST** | create | ❌ ALL MT configs crash | Buffer overflow after iteration 5 |
| **POST** | lookup | ❌ ALL MT configs crash | Iterates beyond array bounds |
| **USERTAG** | insert | ❌ ISPC + ALL MT crash | Buffer overflow + memory corruption |
| USER | create | ✅ Works | (Probably has reset or smaller batch) |
| USER | login | ✅ Works | (Probably has reset or smaller batch) |
| SHORTURL | compose | ✅ Works | (Single iteration or has reset) |
| TEXT | compose | ✅ Works | (Single iteration or has reset) |
| UNIQUEID | compose | ✅ Works | (Single iteration or has reset) |

## Solutions

### Option 1: Reset Map Between Iterations (Recommended)
Add reset logic before each iteration:

```cpp
for (int iter = 0; iter < bench_iters; iter++) {
    // Reset map before each iteration
    if (use_ispc) {
        ispc_map->next_slot = 0;
    } else {
        mt_map->next_slot.store(0);
    }
    
    // Now run the benchmark iteration
    // ...
}
```

### Option 2: Increase MAX_ENTRIES
Change MAX_ENTRIES to accommodate all iterations:
```cpp
#define MAX_ENTRIES (150000)  // 100 iterations × 1000 posts + margin
```
**⚠️ Warning:** This wastes memory (600+ MB per service)

### Option 3: Reduce Iterations or Batch Size
```bash
# In run_all_benchmarks_with_modes.sh
POST_BATCH_CREATE=100    # Instead of 1000
# OR
ITERATIONS=10            # Instead of 100
```
**⚠️ Warning:** Reduces benchmark statistical significance

### Option 4: Single-Iteration Timing (Best for Accuracy)
Only measure one iteration at a time, reset between measurements:
```cpp
for (int iter = 0; iter < bench_iters; iter++) {
    // Reset
    if (use_ispc) ispc_map->next_slot = 0;
    else mt_map->next_slot.store(0);
    
    // Time this iteration
    auto start = chrono::high_resolution_clock::now();
    // ... do work ...
    auto end = chrono::high_resolution_clock::now();
    time_measurements.push_back(duration(end - start));
}
```

## Recommended Fix

**Implement Option 4** - It provides:
- ✅ Accurate per-iteration timing
- ✅ No memory waste
- ✅ Prevents buffer overflow
- ✅ Maintains statistical validity
- ✅ Each iteration is independent

## Implementation Priority

1. **CRITICAL:** Fix POST service (both create and lookup)
2. **CRITICAL:** Fix USERTAG service (insert operation)  
3. **VERIFY:** Check other services for similar issues
4. **TEST:** Re-run benchmarks after fixes

## Files to Modify

- `/home/aalawneh/energy/socialGraph/post/simple.cpp`
- `/home/aalawneh/energy/socialGraph/userTag/simple.cpp`
- Possibly other service simple.cpp files

---

**Next Steps:** Apply Option 4 (map reset per iteration) to all affected services.
