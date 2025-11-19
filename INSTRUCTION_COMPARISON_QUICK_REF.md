# Instruction Count Comparison - Quick Reference

## Files Created

```
socialGraph/
├── compare_instructions.sh              ⭐ Main benchmark script
├── analyze_instruction_counts.py        📊 Analysis & visualization
├── instruction_comparison_example.sh    🚀 Quick test example
├── INSTRUCTION_COMPARISON_README.md     📖 Full documentation
└── INSTRUCTION_COMPARISON_SUMMARY.txt   📋 This summary
```

## Usage Examples

### Example 1: Quick Test (POST service only)
```bash
# Takes ~2-3 minutes
./instruction_comparison_example.sh
```

### Example 2: Full Benchmark (all services)
```bash
# Takes ~30-45 minutes
# Step 1: Enable perf
sudo sysctl -w kernel.perf_event_paranoid=-1

# Step 2: Run benchmarks
./compare_instructions.sh

# Step 3: Analyze results
python3 analyze_instruction_counts.py instruction_comparison_20251117_220000/
```

### Example 3: Single Service
```bash
# Run just one service manually
cd post
perf stat -e instructions,cycles ./simple ispc create 2000 100
perf stat -e instructions,cycles ./simple mt 4 create pool 2000 100
```

## What Each Script Does

### 1. `compare_instructions.sh`
- Runs all 6 services (post, user, userTag, shortURL, text, uniqueID)
- Tests ISPC implementation
- Tests MT with 1, 4, 8, 16 threads
- Uses `perf stat` to measure instructions, cycles, cache metrics
- Generates CSV and text reports

**Output:**
```
instruction_comparison_20251117_220000/
├── instruction_comparison.csv
├── INSTRUCTION_COMPARISON_REPORT.txt
├── post_create_ispc_perf.txt
├── post_create_ispc_output.txt
├── post_create_mt1_perf.txt
├── post_create_mt1_output.txt
└── ... (more files)
```

### 2. `analyze_instruction_counts.py`
- Parses all perf output files
- Calculates instruction ratios (MT/ISPC)
- Generates comparison plots
- Creates detailed reports

**Output:**
```
analysis/
├── instruction_analysis.csv
├── INSTRUCTION_COMPARISON.txt
├── instruction_comparison.png
└── ipc_comparison.png
```

### 3. `instruction_comparison_example.sh`
- Quick demonstration using POST service
- Fewer iterations (20 vs 100)
- Shows basic comparison workflow

## Interpreting Results

### Instruction Ratio
```
Service: post - create
ISPC:        12,345,678 instructions
MT-1:        15,234,567 instructions → 1.23x (23% more than ISPC)
MT-4:        14,567,890 instructions → 1.18x (18% more than ISPC)
MT-8:        14,234,567 instructions → 1.15x (15% more than ISPC)
```

**Key Insight:** MT implementations typically use 10-40% more instructions than ISPC due to threading overhead.

### IPC (Instructions Per Cycle)
- **Higher IPC** = Better CPU utilization
- ISPC often has lower IPC (SIMD operations take multiple cycles)
- MT may have higher IPC per thread but needs multiple threads

## Common Issues & Solutions

| Issue | Solution |
|-------|----------|
| `perf: Permission denied` | `sudo sysctl -w kernel.perf_event_paranoid=-1` |
| `perf: command not found` | `sudo apt-get install linux-tools-generic` |
| Python import errors | `pip install pandas matplotlib` |
| No benchmark data | Run `make` in each service directory |

## Key Metrics Collected

| Metric | Description | Usage |
|--------|-------------|-------|
| **Instructions** | Total CPU instructions executed | Primary comparison metric |
| **Cycles** | CPU cycles consumed | Measure of time |
| **IPC** | Instructions per cycle | Efficiency metric |
| **Cache References** | Memory cache accesses | Memory behavior |
| **Cache Misses** | Cache misses | Memory efficiency |

## Services & Operations Tested

| Service | Operations | Batch Size |
|---------|-----------|------------|
| post | create, lookup | 2000 |
| user | create, login | 2000 |
| userTag | insert, lookup | 2000 |
| shortURL | compose | 2000 |
| text | compose | 2000 |
| uniqueID | compose | 2000 |

## Performance Overhead Breakdown

MT implementations use more instructions due to:

1. **Thread Synchronization** (~5-15%)
   - Locks, atomics, barriers
   - Memory fence instructions

2. **Function Call Overhead** (~2-8%)
   - Each thread calls kernel function
   - Stack setup/teardown

3. **Thread Pool Management** (~3-10%)
   - Task queuing
   - Thread wake-up

4. **Cache Coherency** (~5-20%)
   - Cache line invalidation
   - Inter-thread communication

5. **No SIMD** (~10-30%)
   - Scalar vs vectorized operations
   - More instructions for same work

**Total typical overhead: 10-40% more instructions**

## Visualization Examples

The analysis script generates two types of plots:

### 1. Instruction Count Comparison
Shows instruction count for ISPC (baseline) vs MT (1, 4, 8, 16 threads) for each service/operation.

### 2. IPC Comparison
Bar chart comparing Instructions Per Cycle across all implementations.

## Next Steps

1. ✅ Run quick example to verify setup
2. ✅ Run full benchmark suite
3. ✅ Analyze results with Python script
4. ✅ Review generated plots and reports
5. ✅ Use data for optimization decisions

## Links to Documentation

- **Full Documentation:** `INSTRUCTION_COMPARISON_README.md`
- **Quick Summary:** `INSTRUCTION_COMPARISON_SUMMARY.txt`
- **This Guide:** `INSTRUCTION_COMPARISON_QUICK_REF.md`

---
**Created:** November 17, 2025  
**Purpose:** Compare instruction efficiency of ISPC vs MT implementations
