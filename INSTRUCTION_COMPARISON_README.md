# Instruction Count Comparison Tools

This directory contains scripts to compare instruction counts between ISPC and multi-threaded (MT) implementations of the socialGraph kernels.

## Scripts

### 1. `compare_instructions.sh`

Main benchmark script that runs all services with ISPC and MT implementations while collecting instruction counts using `perf stat`.

**Features:**
- Measures instruction counts, cycles, cache references, and cache misses
- Tests ISPC implementation
- Tests MT implementation with 1, 4, 8, and 16 threads
- Uses thread pool mode for MT tests
- Generates detailed CSV and text reports

**Requirements:**
- `perf` tool (install with: `sudo apt-get install linux-tools-generic`)
- Appropriate permissions for perf (see below)

**Usage:**
```bash
./compare_instructions.sh
```

**Setting perf permissions:**
```bash
# Option 1: Temporarily allow user-space perf
sudo sysctl -w kernel.perf_event_paranoid=-1

# Option 2: Run with sudo
sudo ./compare_instructions.sh
```

**Output:**
- Creates a timestamped directory: `instruction_comparison_YYYYMMDD_HHMMSS/`
- `instruction_comparison.csv` - Raw data in CSV format
- `INSTRUCTION_COMPARISON_REPORT.txt` - Human-readable report
- Individual perf and application output files for each test

### 2. `analyze_instruction_counts.py`

Python analysis script that processes the perf results and generates visualizations and detailed comparisons.

**Features:**
- Parses perf stat output files
- Calculates instruction count ratios (MT/ISPC)
- Generates comparison plots
- Computes IPC (Instructions Per Cycle) statistics
- Creates summary reports

**Requirements:**
```bash
pip install pandas matplotlib
```

**Usage:**
```bash
# After running compare_instructions.sh
python3 analyze_instruction_counts.py instruction_comparison_YYYYMMDD_HHMMSS/
```

**Output:**
- `analysis/instruction_analysis.csv` - Processed data
- `analysis/INSTRUCTION_COMPARISON.txt` - Detailed comparison report
- `analysis/instruction_comparison.png` - Instruction count plots
- `analysis/ipc_comparison.png` - IPC comparison plots

## Quick Start

```bash
# Step 1: Run instruction count benchmarks (requires perf)
sudo sysctl -w kernel.perf_event_paranoid=-1  # Enable perf for user
./compare_instructions.sh

# Step 2: Analyze results and generate visualizations
python3 analyze_instruction_counts.py instruction_comparison_YYYYMMDD_HHMMSS/

# Step 3: View results
cat instruction_comparison_YYYYMMDD_HHMMSS/analysis/INSTRUCTION_COMPARISON.txt
```

## Services Tested

The scripts benchmark all socialGraph services:

1. **post** - Create and Lookup operations
2. **user** - Create and Login operations  
3. **userTag** - Insert and Lookup operations
4. **shortURL** - Compose operation
5. **text** - Compose operation
6. **uniqueID** - Compose operation

## Understanding the Results

### Instruction Count Ratio

The scripts calculate the ratio: `MT_instructions / ISPC_instructions`

- **Ratio = 1.0** - Same number of instructions
- **Ratio > 1.0** - MT uses more instructions than ISPC
- **Ratio < 1.0** - MT uses fewer instructions than ISPC (rare)

Example interpretation:
- MT4 ratio = 1.5x means MT with 4 threads executes 50% more instructions than ISPC

### IPC (Instructions Per Cycle)

Higher IPC generally indicates better CPU utilization:
- **ISPC** typically has lower IPC due to SIMD operations taking multiple cycles
- **MT** may have higher IPC per thread but requires multiple threads

### Why MT Might Use More Instructions

1. **Thread synchronization overhead** - Locks, atomics, barriers
2. **Function call overhead** - Each thread calling the kernel function
3. **Thread pool management** - Task queuing and dispatch
4. **Cache coherency** - Additional memory instructions for cache line management
5. **No SIMD** - Scalar operations vs. vectorized ISPC code

## Troubleshooting

### perf: Permission denied

**Solution:**
```bash
# Temporary (until reboot)
sudo sysctl -w kernel.perf_event_paranoid=-1

# Permanent (edit /etc/sysctl.conf)
echo "kernel.perf_event_paranoid = -1" | sudo tee -a /etc/sysctl.conf
sudo sysctl -p
```

### perf not found

**Solution:**
```bash
sudo apt-get install linux-tools-generic
# Or for specific kernel version:
sudo apt-get install linux-tools-$(uname -r)
```

### Python dependencies missing

**Solution:**
```bash
pip install pandas matplotlib numpy
```

## Example Output

```
ISPC Baseline:
  Instructions: 12,345,678
  Cycles:       23,456,789
  IPC:          0.526
  Time:         0.001234 s

Threads    Instructions         Ratio vs ISPC   IPC        Time(s)   
----------------------------------------------------------------------
1              15,234,567          1.234x         0.612      0.001456
4              14,567,890          1.180x         0.598      0.000567
8              14,234,567          1.153x         0.587      0.000345
16             14,123,456          1.144x         0.579      0.000289
```

## Notes

- All tests run with 100 iterations for statistical stability
- Batch sizes are set to 2000 requests for most services
- MT tests use thread pool mode (not spawn mode) for consistency
- Results may vary based on CPU architecture and system load
- Run on an idle system for best reproducibility
