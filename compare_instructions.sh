#!/bin/bash

# Script to compare instruction counts between ISPC and MT implementations
# Uses perf stat to collect hardware performance counters

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
ITERATIONS=100
RESULTS_DIR="instruction_comparison_$(date +%Y%m%d_%H%M%S)"
THREAD_COUNTS=(1 4 8 16)

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Instruction Count Comparison: ISPC vs MT                        ║${NC}"
echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║  Using perf stat to measure instruction counts                   ║${NC}"
echo -e "${BLUE}║  Iterations: ${ITERATIONS}                                              ║${NC}"
echo -e "${BLUE}║  Thread counts: 1, 4, 8, 16                                      ║${NC}"
echo -e "${BLUE}║  Results dir: ${RESULTS_DIR}                        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if perf is available and find the correct binary
PERF_CMD=""
if command -v perf &> /dev/null && perf --version &> /dev/null; then
    PERF_CMD="perf"
elif [ -f "/usr/lib/linux-tools/6.8.0-87-generic/perf" ]; then
    PERF_CMD="/usr/lib/linux-tools/6.8.0-87-generic/perf"
else
    echo -e "${RED}Error: perf command not found. Please install linux-tools package.${NC}"
    echo "Run: sudo apt-get install linux-tools-generic"
    exit 1
fi

echo "Using perf: ${PERF_CMD}"

# Get absolute path of current directory
BASE_DIR="$(pwd)"

# Create results directory
mkdir -p "${BASE_DIR}/${RESULTS_DIR}"

# Summary file
SUMMARY_FILE="${BASE_DIR}/${RESULTS_DIR}/instruction_comparison.csv"
echo "Service,Operation,Mode,Threads,Instructions,Cycles,IPC,Time_us" > "${SUMMARY_FILE}"

# Function to run benchmark with perf and extract instruction count
run_with_perf() {
    local service=$1
    local operation=$2
    local mode=$3
    local threads=$4
    local batch_size=$5
    
    local service_dir="${service}"
    local executable="simple"
    
    # Build mode string for command
    local mode_str=""
    if [[ "$mode" == "ispc" ]]; then
        mode_str="ispc"
    else
        mode_str="mt ${threads}"
    fi
    
    # Build result file prefix with absolute path
    local result_prefix="${BASE_DIR}/${RESULTS_DIR}/${service}_${operation}_${mode}"
    if [[ "$mode" == "mt" ]]; then
        result_prefix="${result_prefix}${threads}"
    fi
    
    local display_str="${service} - ${operation} - ${mode}"
    if [[ "$mode" == "mt" ]]; then
        display_str="${display_str} (${threads} threads)"
    fi
    echo -e "${YELLOW}Running: ${display_str}${NC}"
    
    # Change to service directory
    cd "${service_dir}"
    
    # Build command based on service
    local cmd=""
    if [[ "$service" == "user" ]]; then
        if [[ "$mode" == "ispc" ]]; then
            cmd="./${executable} ispc ${operation} ${batch_size} 0.0 ${ITERATIONS}"
        else
            cmd="./${executable} mt ${threads} ${operation} pool ${batch_size} 0.0 ${ITERATIONS}"
        fi
    elif [[ "$service" == "post" ]]; then
        if [[ "$mode" == "ispc" ]]; then
            cmd="./${executable} ispc ${operation} ${batch_size} ${ITERATIONS}"
        else
            cmd="./${executable} mt ${threads} ${operation} pool ${batch_size} ${ITERATIONS}"
        fi
    elif [[ "$service" == "userTag" ]]; then
        if [[ "$mode" == "ispc" ]]; then
            cmd="./${executable} ispc ${operation} ${batch_size} ${ITERATIONS}"
        else
            cmd="./${executable} mt ${threads} ${operation} pool ${batch_size} ${ITERATIONS}"
        fi
    elif [[ "$service" == "text" ]]; then
        # Text service needs CSV file
        if [[ "$mode" == "ispc" ]]; then
            cmd="./${executable} test_texts.csv 100 ${ITERATIONS}"
        else
            cmd="./${executable} test_texts.csv 100 mt ${threads} pool ${ITERATIONS}"
        fi
    elif [[ "$service" == "uniqueID" || "$service" == "shortURL" ]]; then
        # uniqueID and shortURL don't have operation types
        if [[ "$mode" == "ispc" ]]; then
            cmd="./${executable} ispc ${batch_size} ${ITERATIONS}"
        else
            cmd="./${executable} mt ${threads} pool ${batch_size} ${ITERATIONS}"
        fi
    fi
    
    echo "  Command: ${cmd}"
    
    # Run with perf stat to collect instruction counts
    local perf_output="${result_prefix}_perf.txt"
    local app_output="${result_prefix}_output.txt"
    
    # Run perf stat with detailed events
    if ${PERF_CMD} stat -e instructions,cycles,cache-references,cache-misses \
        -o "${perf_output}" \
        ${cmd} > "${app_output}" 2>&1; then
        
        echo -e "  ${GREEN}✓ Success${NC}"
        
        # Extract metrics from perf output
        local instructions=$(grep "instructions" "${perf_output}" | grep -v "<not counted>" | head -1 | awk '{print $1}' | tr -d ',')
        local cycles=$(grep "cycles" "${perf_output}" | grep -v "<not counted>" | head -1 | awk '{print $1}' | tr -d ',')
        local time_sec=$(grep "seconds time elapsed" "${perf_output}" | awk '{print $1}')
        
        # Calculate IPC (Instructions Per Cycle)
        local ipc="0"
        if [[ -n "$cycles" && "$cycles" != "0" && -n "$instructions" ]]; then
            ipc=$(echo "scale=4; ${instructions} / ${cycles}" | bc -l)
        fi
        
        # Convert time to microseconds
        local time_us="0"
        if [[ -n "$time_sec" ]]; then
            time_us=$(echo "scale=2; ${time_sec} * 1000000" | bc -l)
        fi
        
        # Also try to get median time from application output
        local app_time=$(grep "Median:" "${app_output}" | head -1 | awk '{print $2}' | tr -d 'µs')
        if [[ -n "$app_time" && "$app_time" != "0" ]]; then
            time_us=$app_time
        fi
        
        echo "  Instructions: ${instructions}"
        echo "  Cycles: ${cycles}"
        echo "  IPC: ${ipc}"
        echo "  Time: ${time_us} µs"
        
        # Add to summary
        local thread_str="${threads}"
        if [[ "$mode" == "ispc" ]]; then
            thread_str="N/A"
        fi
        
        echo "${service},${operation},${mode},${thread_str},${instructions},${cycles},${ipc},${time_us}" >> "${SUMMARY_FILE}"
        
    else
        echo -e "  ${RED}✗ Failed - check ${perf_output} and ${app_output}${NC}"
    fi
    
    cd - > /dev/null
    echo ""
}

# Function to compare and generate report
generate_comparison_report() {
    local service=$1
    local operation=$2
    
    echo -e "${CYAN}Generating comparison for ${service} - ${operation}${NC}"
    
    # Get ISPC baseline
    local ispc_insts=$(grep "^${service},${operation},ispc," "${SUMMARY_FILE}" | cut -d',' -f5)
    
    if [[ -z "$ispc_insts" || "$ispc_insts" == "0" ]]; then
        echo -e "  ${RED}Warning: No ISPC data found${NC}"
        return
    fi
    
    echo "  ISPC instructions: ${ispc_insts}"
    
    # Compare with each MT configuration
    for threads in "${THREAD_COUNTS[@]}"; do
        local mt_insts=$(grep "^${service},${operation},mt,${threads}," "${SUMMARY_FILE}" | cut -d',' -f5)
        
        if [[ -n "$mt_insts" && "$mt_insts" != "0" ]]; then
            local ratio=$(echo "scale=2; ${mt_insts} / ${ispc_insts}" | bc -l)
            echo "  MT${threads} instructions: ${mt_insts} (${ratio}x vs ISPC)"
        fi
    done
    
    echo ""
}

# ============================================
# MAIN BENCHMARK EXECUTION
# ============================================

# Batch sizes for each service/operation
USER_BATCH_CREATE=2000
USER_BATCH_LOGIN=2000
POST_BATCH_CREATE=2000
POST_BATCH_LOOKUP=2000
USERTAG_BATCH_INSERT=2000
USERTAG_BATCH_LOOKUP=2000
SHORTURL_BATCH=2000
TEXT_BATCH=2000
UNIQUEID_BATCH=2000

echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Starting Instruction Count Benchmark${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""

# ============================================
# POST SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  POST SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Post - Create
run_with_perf "post" "create" "ispc" "" ${POST_BATCH_CREATE}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_perf "post" "create" "mt" ${threads} ${POST_BATCH_CREATE}
done
generate_comparison_report "post" "create"

# Post - Lookup
run_with_perf "post" "lookup" "ispc" "" ${POST_BATCH_LOOKUP}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_perf "post" "lookup" "mt" ${threads} ${POST_BATCH_LOOKUP}
done
generate_comparison_report "post" "lookup"

# ============================================
# USER SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  USER SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# User - Create
run_with_perf "user" "create" "ispc" "" ${USER_BATCH_CREATE}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_perf "user" "create" "mt" ${threads} ${USER_BATCH_CREATE}
done
generate_comparison_report "user" "create"

# User - Login
run_with_perf "user" "login" "ispc" "" ${USER_BATCH_LOGIN}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_perf "user" "login" "mt" ${threads} ${USER_BATCH_LOGIN}
done
generate_comparison_report "user" "login"

# ============================================
# USERTAG SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  USERTAG SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# UserTag - Insert
run_with_perf "userTag" "insert" "ispc" "" ${USERTAG_BATCH_INSERT}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_perf "userTag" "insert" "mt" ${threads} ${USERTAG_BATCH_INSERT}
done
generate_comparison_report "userTag" "insert"

# UserTag - Lookup
run_with_perf "userTag" "lookup" "ispc" "" ${USERTAG_BATCH_LOOKUP}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_perf "userTag" "lookup" "mt" ${threads} ${USERTAG_BATCH_LOOKUP}
done
generate_comparison_report "userTag" "lookup"

# ============================================
# SHORTURL SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  SHORTURL SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_with_perf "shortURL" "compose" "ispc" "" ${SHORTURL_BATCH}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_perf "shortURL" "compose" "mt" ${threads} ${SHORTURL_BATCH}
done
generate_comparison_report "shortURL" "compose"

# ============================================
# TEXT SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  TEXT SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_with_perf "text" "compose" "ispc" "" ${TEXT_BATCH}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_perf "text" "compose" "mt" ${threads} ${TEXT_BATCH}
done
generate_comparison_report "text" "compose"

# ============================================
# UNIQUEID SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  UNIQUEID SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_with_perf "uniqueID" "compose" "ispc" "" ${UNIQUEID_BATCH}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_perf "uniqueID" "compose" "mt" ${threads} ${UNIQUEID_BATCH}
done
generate_comparison_report "uniqueID" "compose"

# ============================================
# GENERATE SUMMARY REPORT
# ============================================
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Generating Summary Report${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""

REPORT_FILE="${BASE_DIR}/${RESULTS_DIR}/INSTRUCTION_COMPARISON_REPORT.txt"

cat > "${REPORT_FILE}" << EOF
╔══════════════════════════════════════════════════════════════════╗
║     Instruction Count Comparison: ISPC vs MT                     ║
╚══════════════════════════════════════════════════════════════════╝

Generated: $(date)
Iterations per test: ${ITERATIONS}
Thread counts tested: ${THREAD_COUNTS[@]}

All measurements collected using perf stat hardware performance counters.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

INSTRUCTION COUNT COMPARISON BY SERVICE:

EOF

# Process and format results
echo "" >> "${REPORT_FILE}"
echo "Service            Operation    Mode   Threads  Instructions        Cycles          IPC     Time(µs)" >> "${REPORT_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "${REPORT_FILE}"

while IFS=',' read -r service operation mode threads instructions cycles ipc time_us; do
    if [[ "$service" == "Service" ]]; then continue; fi
    
    printf "%-18s %-12s %-6s %-8s %15s %15s %8s %12s\n" \
        "$service" "$operation" "$mode" "$threads" "$instructions" "$cycles" "$ipc" "$time_us" >> "${REPORT_FILE}"
done < "${SUMMARY_FILE}"

echo "" >> "${REPORT_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "${REPORT_FILE}"
echo "" >> "${REPORT_FILE}"
echo "ISPC vs MT INSTRUCTION RATIO SUMMARY:" >> "${REPORT_FILE}"
echo "" >> "${REPORT_FILE}"

# Calculate ratios for each service/operation
for service_dir in post user userTag shortURL text uniqueID; do
    for operation in create login lookup insert compose; do
        # Get ISPC count
        ispc_line=$(grep "^${service_dir},${operation},ispc," "${SUMMARY_FILE}" 2>/dev/null || echo "")
        if [[ -z "$ispc_line" ]]; then
            continue
        fi
        
        ispc_insts=$(echo "$ispc_line" | cut -d',' -f5)
        
        echo "${service_dir} - ${operation}:" >> "${REPORT_FILE}"
        echo "  ISPC baseline: ${ispc_insts} instructions" >> "${REPORT_FILE}"
        
        for threads in "${THREAD_COUNTS[@]}"; do
            mt_line=$(grep "^${service_dir},${operation},mt,${threads}," "${SUMMARY_FILE}" 2>/dev/null || echo "")
            if [[ -n "$mt_line" ]]; then
                mt_insts=$(echo "$mt_line" | cut -d',' -f5)
                if [[ -n "$mt_insts" && "$mt_insts" != "0" && "$ispc_insts" != "0" ]]; then
                    ratio=$(echo "scale=3; ${mt_insts} / ${ispc_insts}" | bc -l)
                    echo "  MT${threads}: ${mt_insts} instructions (${ratio}x ISPC)" >> "${REPORT_FILE}"
                fi
            fi
        done
        echo "" >> "${REPORT_FILE}"
    done
done

echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "${REPORT_FILE}"
echo "" >> "${REPORT_FILE}"
echo "CSV Data: ${SUMMARY_FILE}" >> "${REPORT_FILE}"
echo "All result files in: ${RESULTS_DIR}/" >> "${REPORT_FILE}"
echo "" >> "${REPORT_FILE}"

cat "${REPORT_FILE}"

echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Instruction Count Comparison Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "Summary CSV: ${CYAN}${SUMMARY_FILE}${NC}"
echo -e "Report:      ${CYAN}${REPORT_FILE}${NC}"
echo -e "Results:     ${CYAN}${BASE_DIR}/${RESULTS_DIR}/${NC}"
echo ""
echo -e "${YELLOW}NOTE: This script requires 'perf' tool and appropriate permissions.${NC}"
echo -e "${YELLOW}If you see permission errors, you may need to:${NC}"
echo -e "${YELLOW}  1. Run: sudo sysctl -w kernel.perf_event_paranoid=-1${NC}"
echo -e "${YELLOW}  2. Or run this script with sudo${NC}"
echo ""
