#!/bin/bash

# Quick example script showing how to use the instruction comparison tools

set -e

echo "╔══════════════════════════════════════════════════════════════════╗"
echo "║  Instruction Count Comparison - Quick Example                   ║"
echo "╚══════════════════════════════════════════════════════════════════╝"
echo ""

echo "This script will run a quick example on just the POST service"
echo "to demonstrate the instruction comparison tools."
echo ""
echo "Press Enter to continue or Ctrl+C to cancel..."
read

# Check for perf and find the correct binary
PERF_CMD=""
if command -v perf &> /dev/null && perf --version &> /dev/null; then
    PERF_CMD="perf"
elif [ -f "/usr/lib/linux-tools/6.8.0-87-generic/perf" ]; then
    PERF_CMD="/usr/lib/linux-tools/6.8.0-87-generic/perf"
else
    echo "❌ Error: perf command not found"
    echo "Install it with: sudo apt-get install linux-tools-generic"
    exit 1
fi

echo "Using perf: ${PERF_CMD}"

# Check permissions
echo "Checking perf permissions..."
if ! ${PERF_CMD} stat -e instructions echo "test" &> /dev/null; then
    echo "⚠️  perf needs additional permissions"
    echo "Run: sudo sysctl -w kernel.perf_event_paranoid=-1"
    echo ""
    echo "Continue anyway? (y/n)"
    read answer
    if [ "$answer" != "y" ]; then
        exit 1
    fi
fi

# Create quick test directory
RESULTS_DIR="instruction_example_$(date +%Y%m%d_%H%M%S)"
mkdir -p "${RESULTS_DIR}"

echo ""
echo "═══════════════════════════════════════════"
echo "  Running POST Service Example"
echo "═══════════════════════════════════════════"
echo ""

# Function to run one test
run_test() {
    local mode=$1
    local threads=$2
    local batch=2000
    local iters=20  # Fewer iterations for quick test
    
    cd post
    
    if [ "$mode" == "ispc" ]; then
        echo "Testing ISPC..."
        cmd="./simple ispc create ${batch} ${iters}"
        output_file="../${RESULTS_DIR}/post_create_ispc"
    else
        echo "Testing MT with ${threads} threads..."
        cmd="./simple mt ${threads} create pool ${batch} ${iters}"
        output_file="../${RESULTS_DIR}/post_create_mt${threads}"
    fi
    
    echo "  Running: ${cmd}"
    
    # Run with perf
    ${PERF_CMD} stat -e instructions,cycles,cache-references,cache-misses \
        -o "${output_file}_perf.txt" \
        ${cmd} > "${output_file}_output.txt" 2>&1
    
    # Extract instructions
    insts=$(grep "instructions" "${output_file}_perf.txt" | awk '{print $1}' | tr -d ',')
    cycles=$(grep "cycles" "${output_file}_perf.txt" | awk '{print $1}' | tr -d ',')
    
    echo "  ✓ Instructions: ${insts}"
    echo "  ✓ Cycles: ${cycles}"
    
    if [ -n "$cycles" ] && [ "$cycles" != "0" ]; then
        ipc=$(echo "scale=3; ${insts} / ${cycles}" | bc -l)
        echo "  ✓ IPC: ${ipc}"
    fi
    
    echo ""
    
    cd ..
}

# Run tests
run_test "ispc" ""
run_test "mt" "1"
run_test "mt" "4"
run_test "mt" "8"

echo "═══════════════════════════════════════════"
echo "  Generating Comparison"
echo "═══════════════════════════════════════════"
echo ""

# Create simple comparison
ispc_insts=$(grep "instructions" "${RESULTS_DIR}/post_create_ispc_perf.txt" | awk '{print $1}' | tr -d ',')

echo "POST CREATE - Instruction Count Comparison:"
echo "─────────────────────────────────────────────"
printf "%-15s %20s %15s\n" "Implementation" "Instructions" "vs ISPC"
echo "─────────────────────────────────────────────"

printf "%-15s %20s %15s\n" "ISPC" "$ispc_insts" "1.00x"

for threads in 1 4 8; do
    mt_insts=$(grep "instructions" "${RESULTS_DIR}/post_create_mt${threads}_perf.txt" | awk '{print $1}' | tr -d ',')
    if [ -n "$mt_insts" ] && [ "$ispc_insts" != "0" ]; then
        ratio=$(echo "scale=2; ${mt_insts} / ${ispc_insts}" | bc -l)
        printf "%-15s %20s %15s\n" "MT-${threads} threads" "$mt_insts" "${ratio}x"
    fi
done

echo "─────────────────────────────────────────────"
echo ""
echo "✅ Example complete!"
echo ""
echo "Results saved to: ${RESULTS_DIR}/"
echo ""
echo "To run the full benchmark on all services:"
echo "  ./compare_instructions.sh"
echo ""
echo "To analyze with visualizations:"
echo "  python3 analyze_instruction_counts.py ${RESULTS_DIR}/"
echo ""
