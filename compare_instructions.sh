#!/bin/bash

# Script to compare instruction counts between ISPC and MT implementations
# Uses Intel Pin with modified insmix tool to get scalar/SIMD breakdown

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
THREAD_COUNTS=(1)
FUNCTION_LIST="/home/aalawneh/energy/functions_to_track.txt"
PROFILER="${1:-both}"  # Options: pin, perf, both (default: both)

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Instruction Count Comparison: ISPC vs MT (1 thread)            ║${NC}"
echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║  Profiler: ${PROFILER}                                                    ║${NC}"
echo -e "${BLUE}║  - Pin: Scalar/SIMD breakdown with function filtering            ║${NC}"
echo -e "${BLUE}║  - Perf: Hardware counters (instructions, cycles, IPC)           ║${NC}"
echo -e "${BLUE}║  Iterations: ${ITERATIONS}                                              ║${NC}"
echo -e "${BLUE}║  Thread count: 1                                                 ║${NC}"
echo -e "${BLUE}║  Results dir: ${RESULTS_DIR}                        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check profiler availability
USE_PIN=false
USE_PERF=false

if [[ "$PROFILER" == "pin" || "$PROFILER" == "both" ]]; then
    PIN_ROOT="/home/aalawneh/energy/pin-external-4.0-99633-g5ca9893f2-gcc-linux"
    PIN_CMD="${PIN_ROOT}/pin"
    INSMIX_TOOL="${PIN_ROOT}/source/tools/Insmix/obj-intel64/insmix.so"
    
    if [ ! -f "${PIN_CMD}" ]; then
        echo -e "${YELLOW}Warning: Pin not found at ${PIN_CMD}${NC}"
        if [[ "$PROFILER" == "pin" ]]; then
            exit 1
        fi
    elif [ ! -f "${INSMIX_TOOL}" ]; then
        echo -e "${YELLOW}Warning: insmix tool not found, building...${NC}"
        cd "${PIN_ROOT}/source/tools/Insmix"
        make
        cd - > /dev/null
        if [ -f "${INSMIX_TOOL}" ]; then
            USE_PIN=true
        fi
    else
        USE_PIN=true
    fi
    
    if [[ "$USE_PIN" == true ]]; then
        if [ ! -f "${FUNCTION_LIST}" ]; then
            echo -e "${RED}Error: Function list not found at ${FUNCTION_LIST}${NC}"
            exit 1
        fi
        echo "✓ Using Pin: ${PIN_CMD}"
        echo "✓ Using insmix: ${INSMIX_TOOL}"
        echo "✓ Using function list: ${FUNCTION_LIST}"
    fi
fi

if [[ "$PROFILER" == "perf" || "$PROFILER" == "both" ]]; then
    if command -v perf &> /dev/null; then
        # Test if we can run perf
        if perf stat -e instructions echo "test" &> /dev/null 2>&1; then
            USE_PERF=true
            echo "✓ Using perf for hardware counters"
        else
            echo -e "${YELLOW}Warning: perf found but cannot access hardware counters (try: sudo or adjust paranoid level)${NC}"
            if [[ "$PROFILER" == "perf" ]]; then
                echo "  Fix: sudo sysctl kernel.perf_event_paranoid=-1"
                exit 1
            fi
        fi
    else
        echo -e "${YELLOW}Warning: perf not found${NC}"
        if [[ "$PROFILER" == "perf" ]]; then
            exit 1
        fi
    fi
fi

if [[ "$USE_PIN" == false && "$USE_PERF" == false ]]; then
    echo -e "${RED}Error: No profilers available${NC}"
    exit 1
fi

# Get absolute path of current directory
BASE_DIR="$(pwd)"

# Create results directory
mkdir -p "${BASE_DIR}/${RESULTS_DIR}"

# Summary files
SUMMARY_FILE="${BASE_DIR}/${RESULTS_DIR}/instruction_comparison.csv"
if [[ "$USE_PIN" == true && "$USE_PERF" == true ]]; then
    echo "Service,Operation,Mode,Threads,Pin_Total_Insts,Pin_Scalar_Insts,Pin_SIMD_Insts,Pin_SIMD_Pct,Perf_Instructions,Perf_Cycles,Perf_IPC,Inst_Diff,Inst_Diff_Pct,Time_us" > "${SUMMARY_FILE}"
elif [[ "$USE_PIN" == true ]]; then
    echo "Service,Operation,Mode,Threads,Total_Instructions,Scalar_Instructions,SIMD_Instructions,Scalar_Percent,SIMD_Percent,Time_us" > "${SUMMARY_FILE}"
else
    echo "Service,Operation,Mode,Threads,Instructions,Cycles,IPC,Instructions_Per_Batch,Time_us" > "${SUMMARY_FILE}"
fi

# Function to run benchmark with profiler(s) and extract instruction counts
run_with_profiler() {
    local service=$1
    local operation=$2
    local mode=$3
    local threads=$4
    local batch_size=$5
    
    local service_dir="${service}"
    local executable="simple"
    
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
    
    # Build command based on service - matching run_all_benchmarks_with_modes.sh exactly
    local cmd=""
    local full_path_exe="${BASE_DIR}/${service_dir}/${executable}"
    
    if [[ "$service" == "user" ]]; then
        if [[ "$mode" == "ispc" ]]; then
            cmd="${full_path_exe} ispc ${operation} ${batch_size} 0.0 ${ITERATIONS}"
        else
            cmd="${full_path_exe} mt ${threads} ${operation} spawn ${batch_size} 0.0 ${ITERATIONS}"
        fi
    elif [[ "$service" == "post" ]]; then
        if [[ "$mode" == "ispc" ]]; then
            cmd="${full_path_exe} ispc ${operation} ${batch_size} ${ITERATIONS}"
        else
            cmd="${full_path_exe} mt ${threads} ${operation} spawn ${batch_size} ${ITERATIONS}"
        fi
    elif [[ "$service" == "userTag" ]]; then
        if [[ "$mode" == "ispc" ]]; then
            cmd="${full_path_exe} ispc ${operation} ${batch_size} ${ITERATIONS}"
        else
            cmd="${full_path_exe} mt ${threads} ${operation} spawn ${batch_size} ${ITERATIONS}"
        fi
    elif [[ "$service" == "text" ]]; then
        # Text service needs text file with different argument order
        if [[ "$mode" == "ispc" ]]; then
            cmd="${full_path_exe} /home/aalawneh/energy/socialGraph/text/test.txt ${batch_size} ${ITERATIONS}"
        else
            cmd="${full_path_exe} /home/aalawneh/energy/socialGraph/text/test.txt ${batch_size} mt ${threads} spawn ${ITERATIONS}"
        fi
    elif [[ "$service" == "uniqueID" || "$service" == "shortURL" ]]; then
        # uniqueID and shortURL don't have operation types
        if [[ "$mode" == "ispc" ]]; then
            cmd="${full_path_exe} ispc ${batch_size} ${ITERATIONS}"
        else
            cmd="${full_path_exe} mt ${threads} spawn ${batch_size} ${ITERATIONS}"
        fi
    fi
    
    echo "  Command: ${cmd}"
    
    # Output files
    local app_output="${result_prefix}_output.txt"
    local perf_output="${result_prefix}_perf.txt"
    local insmix_output="${result_prefix}_insmix.out"
    
    # Variables to collect
    local pin_total="N/A"
    local pin_scalar="N/A"
    local pin_simd="N/A"
    local pin_simd_pct="N/A"
    local perf_insts="N/A"
    local perf_cycles="N/A"
    local perf_ipc="N/A"
    local inst_diff="N/A"
    local inst_diff_pct="N/A"
    local elapsed_us="0"
    
    # Run with perf if enabled
    if [[ "$USE_PERF" == true ]]; then
        echo "  [Perf] Collecting hardware counters..."
        local start_time=$(date +%s%N)
        
        # Run with perf stat to get instructions, cycles
        if perf stat -e instructions,cycles -o "${perf_output}" ${cmd} > "${app_output}" 2>&1; then
            local end_time=$(date +%s%N)
            elapsed_us=$(( ($end_time - $start_time) / 1000 ))
            
            # Extract metrics from perf output (sum all values for hybrid CPUs)
            perf_insts=$(grep "instructions" "${perf_output}" | awk '{gsub(/,/, "", $1); if ($1 ~ /^[0-9]+$/) sum += $1} END {print sum}')
            perf_cycles=$(grep "cycles" "${perf_output}" | awk '{gsub(/,/, "", $1); if ($1 ~ /^[0-9]+$/) sum += $1} END {print sum}')
            
            if [[ -n "$perf_cycles" && "$perf_cycles" != "0" && -n "$perf_insts" ]]; then
                perf_ipc=$(echo "scale=3; ${perf_insts} / ${perf_cycles}" | bc -l)
            else
                perf_ipc="0"
            fi
            
            echo -e "  ${GREEN}✓ Perf Success${NC}"
            echo "  Perf Instructions: ${perf_insts}"
            echo "  Perf Cycles:       ${perf_cycles}"
            echo "  Perf IPC:          ${perf_ipc}"
        else
            echo -e "  ${RED}✗ Perf Failed${NC}"
        fi
    fi
    
    # Run with Pin if enabled
    if [[ "$USE_PIN" == true ]]; then
        echo "  [Pin] Collecting scalar/SIMD breakdown..."
        local start_time=$(date +%s%N)
        
        # If we already ran with perf, use that output; otherwise run again
        if [[ "$USE_PERF" == false ]]; then
            if ${PIN_CMD} -t ${INSMIX_TOOL} -o "${insmix_output}" -function_list "${FUNCTION_LIST}" -inclusive 1 -- ${cmd} > "${app_output}" 2>&1; then
                local end_time=$(date +%s%N)
                elapsed_us=$(( ($end_time - $start_time) / 1000 ))
            else
                echo -e "  ${RED}✗ Pin Failed${NC}"
                cd - > /dev/null
                echo ""
                return
            fi
        else
            # Run Pin with the same command
            if ! ${PIN_CMD} -t ${INSMIX_TOOL} -o "${insmix_output}" -function_list "${FUNCTION_LIST}" -inclusive 1 -- ${cmd} > /dev/null 2>&1; then
                echo -e "  ${YELLOW}⚠ Pin Failed (perf results still available)${NC}"
                cd - > /dev/null
                echo ""
                return
            fi
        fi
        
        # Extract scalar and SIMD instruction counts from insmix output
        pin_total=$(tail -20 "${insmix_output}" | grep '^\s*3000 \*total' | awk '{print $3}')
        pin_scalar=$(tail -20 "${insmix_output}" | grep '^\s*3001 \*scalar' | awk '{print $3}')
        pin_simd=$(tail -20 "${insmix_output}" | grep '^\s*3002 \*simd' | awk '{print $3}')
        
        # Calculate SIMD percentage
        if [[ -n "$pin_total" && "$pin_total" != "0" && -n "$pin_simd" ]]; then
            pin_simd_pct=$(echo "scale=2; (${pin_simd} / ${pin_total}) * 100" | bc -l)
        else
            pin_simd_pct="0.00"
        fi
        
        echo -e "  ${GREEN}✓ Pin Success${NC}"
        echo "  Pin Total:    ${pin_total}"
        echo "  Pin Scalar:   ${pin_scalar}"
        echo "  Pin SIMD:     ${pin_simd} (${pin_simd_pct}%)"
    fi
    
    # Compare Pin vs Perf if both are available
    if [[ "$USE_PIN" == true && "$USE_PERF" == true ]]; then
        if [[ "$pin_total" != "N/A" && "$perf_insts" != "N/A" && "$perf_insts" != "0" ]]; then
            inst_diff=$((pin_total - perf_insts))
            inst_diff_pct=$(echo "scale=2; (${inst_diff} / ${perf_insts}) * 100" | bc -l)
            echo "  Difference:   ${inst_diff} (${inst_diff_pct}% vs perf)"
        fi
    fi
    
    # Try to get median time from application output
    local app_time=$(grep "Median:" "${app_output}" | head -1 | awk '{print $2}' | tr -d 'µs')
    if [[ -n "$app_time" && "$app_time" != "0" ]]; then
        elapsed_us=$app_time
    fi
    
    echo "  Time: ${elapsed_us} µs"
    
    # Add to summary based on which profilers are enabled
    local thread_str="${threads}"
    if [[ "$mode" == "ispc" ]]; then
        thread_str="N/A"
    fi
    
    if [[ "$USE_PIN" == true && "$USE_PERF" == true ]]; then
        echo "${service},${operation},${mode},${thread_str},${pin_total},${pin_scalar},${pin_simd},${pin_simd_pct},${perf_insts},${perf_cycles},${perf_ipc},${inst_diff},${inst_diff_pct},${elapsed_us}" >> "${SUMMARY_FILE}"
    elif [[ "$USE_PIN" == true ]]; then
        # Calculate scalar percentage
        local pin_scalar_pct="0.00"
        if [[ -n "$pin_total" && "$pin_total" != "0" && -n "$pin_scalar" ]]; then
            pin_scalar_pct=$(echo "scale=2; (${pin_scalar} / ${pin_total}) * 100" | bc -l)
        fi
        echo "${service},${operation},${mode},${thread_str},${pin_total},${pin_scalar},${pin_simd},${pin_scalar_pct},${pin_simd_pct},${elapsed_us}" >> "${SUMMARY_FILE}"
    else
        # Perf only
        local insts_per_batch="0"
        if [[ "$perf_insts" != "N/A" && "$batch_size" != "0" ]]; then
            insts_per_batch=$(echo "scale=2; ${perf_insts} / ${batch_size}" | bc -l)
        fi
        echo "${service},${operation},${mode},${thread_str},${perf_insts},${perf_cycles},${perf_ipc},${insts_per_batch},${elapsed_us}" >> "${SUMMARY_FILE}"
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
    local ispc_line=$(grep "^${service},${operation},ispc," "${SUMMARY_FILE}")
    
    if [[ -z "$ispc_line" ]]; then
        echo -e "  ${RED}Warning: No ISPC data found${NC}"
        return
    fi
    
    local ispc_total=$(echo "$ispc_line" | cut -d',' -f5)
    local ispc_scalar=$(echo "$ispc_line" | cut -d',' -f6)
    local ispc_simd=$(echo "$ispc_line" | cut -d',' -f7)
    local ispc_simd_pct=$(echo "$ispc_line" | cut -d',' -f9)
    
    echo "  ISPC: ${ispc_total} total (${ispc_scalar} scalar, ${ispc_simd} SIMD = ${ispc_simd_pct}%)"
    
    # Compare with each MT configuration
    for threads in "${THREAD_COUNTS[@]}"; do
        local mt_line=$(grep "^${service},${operation},mt,${threads}," "${SUMMARY_FILE}")
        
        if [[ -n "$mt_line" ]]; then
            local mt_total=$(echo "$mt_line" | cut -d',' -f5)
            local mt_scalar=$(echo "$mt_line" | cut -d',' -f6)
            local mt_simd=$(echo "$mt_line" | cut -d',' -f7)
            local mt_simd_pct=$(echo "$mt_line" | cut -d',' -f9)
            
            if [[ -n "$mt_total" && "$mt_total" != "0" && "$ispc_total" != "0" ]]; then
                local ratio=$(echo "scale=2; ${mt_total} / ${ispc_total}" | bc -l)
                echo "  MT${threads}: ${mt_total} total (${mt_scalar} scalar, ${mt_simd} SIMD = ${mt_simd_pct}%) - ${ratio}x vs ISPC"
            fi
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
run_with_profiler "post" "create" "ispc" "" ${POST_BATCH_CREATE}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_profiler "post" "create" "mt" ${threads} ${POST_BATCH_CREATE}
done
generate_comparison_report "post" "create"

# Post - Lookup
run_with_profiler "post" "lookup" "ispc" "" ${POST_BATCH_LOOKUP}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_profiler "post" "lookup" "mt" ${threads} ${POST_BATCH_LOOKUP}
done
generate_comparison_report "post" "lookup"

# ============================================
# USER SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  USER SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# User - Create
run_with_profiler "user" "create" "ispc" "" ${USER_BATCH_CREATE}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_profiler "user" "create" "mt" ${threads} ${USER_BATCH_CREATE}
done
generate_comparison_report "user" "create"

# User - Login
run_with_profiler "user" "login" "ispc" "" ${USER_BATCH_LOGIN}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_profiler "user" "login" "mt" ${threads} ${USER_BATCH_LOGIN}
done
generate_comparison_report "user" "login"

# ============================================
# USERTAG SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  USERTAG SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# UserTag - Insert
run_with_profiler "userTag" "insert" "ispc" "" ${USERTAG_BATCH_INSERT}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_profiler "userTag" "insert" "mt" ${threads} ${USERTAG_BATCH_INSERT}
done
generate_comparison_report "userTag" "insert"

# UserTag - Lookup
run_with_profiler "userTag" "lookup" "ispc" "" ${USERTAG_BATCH_LOOKUP}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_profiler "userTag" "lookup" "mt" ${threads} ${USERTAG_BATCH_LOOKUP}
done
generate_comparison_report "userTag" "lookup"

# ============================================
# SHORTURL SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  SHORTURL SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_with_profiler "shortURL" "compose" "ispc" "" ${SHORTURL_BATCH}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_profiler "shortURL" "compose" "mt" ${threads} ${SHORTURL_BATCH}
done
generate_comparison_report "shortURL" "compose"

# ============================================
# TEXT SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  TEXT SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_with_profiler "text" "compose" "ispc" "" ${TEXT_BATCH}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_profiler "text" "compose" "mt" ${threads} ${TEXT_BATCH}
done
generate_comparison_report "text" "compose"

# ============================================
# UNIQUEID SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  UNIQUEID SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_with_profiler "uniqueID" "compose" "ispc" "" ${UNIQUEID_BATCH}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_profiler "uniqueID" "compose" "mt" ${threads} ${UNIQUEID_BATCH}
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

# Create report header based on profiler type
cat > "${REPORT_FILE}" << EOF
╔══════════════════════════════════════════════════════════════════╗
║   Instruction Count Comparison: ISPC vs MT                      ║
╚══════════════════════════════════════════════════════════════════╝

Generated: $(date)
Iterations per test: ${ITERATIONS}
Thread counts tested: ${THREAD_COUNTS[@]}
Profiler(s): ${PROFILER}

EOF

if [[ "$USE_PIN" == true ]]; then
    echo "Pin: Intel Pin with insmix tool for scalar/SIMD instruction breakdown" >> "${REPORT_FILE}"
    echo "     Function filtering enabled (inclusive mode)" >> "${REPORT_FILE}"
fi

if [[ "$USE_PERF" == true ]]; then
    echo "Perf: Linux perf tool with hardware performance counters" >> "${REPORT_FILE}"
    echo "      Measurements: instructions, cycles, IPC" >> "${REPORT_FILE}"
fi

cat >> "${REPORT_FILE}" << EOF

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

INSTRUCTION COUNT COMPARISON BY SERVICE:

EOF

# Process and format results based on profiler type
echo "" >> "${REPORT_FILE}"

if [[ "$USE_PIN" == true && "$USE_PERF" == true ]]; then
    # Both profilers - show comparison
    echo "Service        Operation  Mode  Threads  Pin_Total    Pin_SIMD%  Perf_Insts   Perf_IPC  Diff%     Time(µs)" >> "${REPORT_FILE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "${REPORT_FILE}"
    
    while IFS=',' read -r service operation mode threads pin_total pin_scalar pin_simd pin_simd_pct perf_insts perf_cycles perf_ipc inst_diff inst_diff_pct time_us; do
        if [[ "$service" == "Service" ]]; then continue; fi
        
        printf "%-14s %-10s %-5s %-8s %12s %10s %12s %9s %9s %10s\n" \
            "$service" "$operation" "$mode" "$threads" "$pin_total" "$pin_simd_pct" "$perf_insts" "$perf_ipc" "$inst_diff_pct" "$time_us" >> "${REPORT_FILE}"
    done < "${SUMMARY_FILE}"
    
elif [[ "$USE_PIN" == true ]]; then
    # Pin only
    echo "Service            Operation    Mode   Threads  Total_Insts     Scalar_Insts    SIMD_Insts   SIMD%    Time(µs)" >> "${REPORT_FILE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "${REPORT_FILE}"
    
    while IFS=',' read -r service operation mode threads total_insts scalar_insts simd_insts scalar_pct simd_pct time_us; do
        if [[ "$service" == "Service" ]]; then continue; fi
        
        printf "%-18s %-12s %-6s %-8s %15s %15s %14s %8s %12s\n" \
            "$service" "$operation" "$mode" "$threads" "$total_insts" "$scalar_insts" "$simd_insts" "$simd_pct" "$time_us" >> "${REPORT_FILE}"
    done < "${SUMMARY_FILE}"
    
else
    # Perf only
    echo "Service            Operation    Mode   Threads  Instructions    Cycles          IPC      Inst/Batch  Time(µs)" >> "${REPORT_FILE}"
    echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "${REPORT_FILE}"
    
    while IFS=',' read -r service operation mode threads instructions cycles ipc inst_per_batch time_us; do
        if [[ "$service" == "Service" ]]; then continue; fi
        
        printf "%-18s %-12s %-6s %-8s %15s %15s %8s %11s %12s\n" \
            "$service" "$operation" "$mode" "$threads" "$instructions" "$cycles" "$ipc" "$inst_per_batch" "$time_us" >> "${REPORT_FILE}"
    done < "${SUMMARY_FILE}"
fi

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
        
        ispc_total=$(echo "$ispc_line" | cut -d',' -f5)
        ispc_scalar=$(echo "$ispc_line" | cut -d',' -f6)
        ispc_simd=$(echo "$ispc_line" | cut -d',' -f7)
        ispc_simd_pct=$(echo "$ispc_line" | cut -d',' -f9)
        
        echo "${service_dir} - ${operation}:" >> "${REPORT_FILE}"
        echo "  ISPC: Total=${ispc_total}, Scalar=${ispc_scalar}, SIMD=${ispc_simd} (${ispc_simd_pct}%)" >> "${REPORT_FILE}"
        
        for threads in "${THREAD_COUNTS[@]}"; do
            mt_line=$(grep "^${service_dir},${operation},mt,${threads}," "${SUMMARY_FILE}" 2>/dev/null || echo "")
            if [[ -n "$mt_line" ]]; then
                mt_total=$(echo "$mt_line" | cut -d',' -f5)
                mt_scalar=$(echo "$mt_line" | cut -d',' -f6)
                mt_simd=$(echo "$mt_line" | cut -d',' -f7)
                mt_simd_pct=$(echo "$mt_line" | cut -d',' -f9)
                
                if [[ -n "$mt_total" && "$mt_total" != "0" && "$ispc_total" != "0" ]]; then
                    ratio=$(echo "scale=3; ${mt_total} / ${ispc_total}" | bc -l)
                    echo "  MT${threads}: Total=${mt_total}, Scalar=${mt_scalar}, SIMD=${mt_simd} (${mt_simd_pct}%) - ${ratio}x vs ISPC" >> "${REPORT_FILE}"
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

if [[ "$USE_PIN" == true ]]; then
    echo -e "${YELLOW}NOTE: Pin instrumentation slows down execution significantly (10-100x).${NC}"
    echo -e "${YELLOW}      Pin results include scalar vs SIMD instruction breakdown.${NC}"
fi

if [[ "$USE_PERF" == true ]]; then
    echo -e "${YELLOW}NOTE: Perf uses hardware performance counters (minimal overhead).${NC}"
    echo -e "${YELLOW}      Perf results include total instructions, cycles, and IPC.${NC}"
fi

if [[ "$USE_PIN" == true && "$USE_PERF" == true ]]; then
    echo -e "${CYAN}TIP:  Compare Pin vs Perf instruction counts to verify measurements.${NC}"
    echo -e "${CYAN}      Small differences expected due to Pin's instrumentation overhead.${NC}"
fi

echo ""
echo -e "${BLUE}Usage examples:${NC}"
echo -e "  ${0} pin       # Use Pin only (scalar/SIMD breakdown)"
echo -e "  ${0} perf      # Use perf only (fast, hardware counters)"
echo -e "  ${0} both      # Use both profilers (default, recommended)"
echo ""
