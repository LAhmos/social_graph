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
THREAD_COUNTS=(1 4 8 16)

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Instruction Count Comparison: ISPC vs MT                        ║${NC}"
echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║  Using Intel Pin with insmix for scalar/SIMD breakdown           ║${NC}"
echo -e "${BLUE}║  Iterations: ${ITERATIONS}                                              ║${NC}"
echo -e "${BLUE}║  Thread counts: 1, 4, 8, 16                                      ║${NC}"
echo -e "${BLUE}║  Results dir: ${RESULTS_DIR}                        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Check if Pin and insmix are available
PIN_ROOT="/home/aalawneh/energy/pin-external-4.0-99633-g5ca9893f2-gcc-linux"
PIN_CMD="${PIN_ROOT}/pin"
INSMIX_TOOL="${PIN_ROOT}/source/tools/Insmix/obj-intel64/insmix.so"

if [ ! -f "${PIN_CMD}" ]; then
    echo -e "${RED}Error: Pin not found at ${PIN_CMD}${NC}"
    exit 1
fi

if [ ! -f "${INSMIX_TOOL}" ]; then
    echo -e "${RED}Error: insmix tool not found at ${INSMIX_TOOL}${NC}"
    echo "Building insmix tool..."
    cd "${PIN_ROOT}/source/tools/Insmix"
    make
    cd - > /dev/null
fi

echo "Using Pin: ${PIN_CMD}"
echo "Using insmix: ${INSMIX_TOOL}"

# Get absolute path of current directory
BASE_DIR="$(pwd)"

# Create results directory
mkdir -p "${BASE_DIR}/${RESULTS_DIR}"

# Summary file
SUMMARY_FILE="${BASE_DIR}/${RESULTS_DIR}/instruction_comparison.csv"
echo "Service,Operation,Mode,Threads,Total_Instructions,Scalar_Instructions,SIMD_Instructions,Scalar_Percent,SIMD_Percent,Time_us" > "${SUMMARY_FILE}"

# Function to run benchmark with Pin insmix and extract instruction breakdown
run_with_pin() {
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
    local insmix_output="${result_prefix}_insmix.out"
    local bblcnt_output="${result_prefix}_bblcnt.out"
    local app_output="${result_prefix}_output.txt"
    
    # Run with Pin insmix tool
    local start_time=$(date +%s%N)
    if ${PIN_CMD} -t ${INSMIX_TOOL} -o "${insmix_output}" -o2 "${bblcnt_output}" -- ${cmd} > "${app_output}" 2>&1; then
        local end_time=$(date +%s%N)
        local elapsed_us=$(( ($end_time - $start_time) / 1000 ))
        
        echo -e "  ${GREEN}✓ Success${NC}"
        
        # Extract scalar and SIMD instruction counts from insmix output
        local total_insts=$(tail -20 "${insmix_output}" | grep '^\s*3000 \*total' | awk '{print $3}')
        local scalar_insts=$(tail -20 "${insmix_output}" | grep '^\s*4046 \*scalar' | awk '{print $3}')
        local simd_insts=$(tail -20 "${insmix_output}" | grep '^\s*4047 \*simd' | awk '{print $3}')
        
        # Calculate percentages
        local scalar_pct="0.00"
        local simd_pct="0.00"
        if [[ -n "$total_insts" && "$total_insts" != "0" ]]; then
            if [[ -n "$scalar_insts" ]]; then
                scalar_pct=$(echo "scale=2; (${scalar_insts} / ${total_insts}) * 100" | bc -l)
            fi
            if [[ -n "$simd_insts" ]]; then
                simd_pct=$(echo "scale=2; (${simd_insts} / ${total_insts}) * 100" | bc -l)
            fi
        fi
        
        # Try to get median time from application output
        local app_time=$(grep "Median:" "${app_output}" | head -1 | awk '{print $2}' | tr -d 'µs')
        if [[ -n "$app_time" && "$app_time" != "0" ]]; then
            elapsed_us=$app_time
        fi
        
        echo "  Total Instructions:  ${total_insts}"
        echo "  Scalar Instructions: ${scalar_insts} (${scalar_pct}%)"
        echo "  SIMD Instructions:   ${simd_insts} (${simd_pct}%)"
        echo "  Time: ${elapsed_us} µs"
        
        # Add to summary
        local thread_str="${threads}"
        if [[ "$mode" == "ispc" ]]; then
            thread_str="N/A"
        fi
        
        echo "${service},${operation},${mode},${thread_str},${total_insts},${scalar_insts},${simd_insts},${scalar_pct},${simd_pct},${elapsed_us}" >> "${SUMMARY_FILE}"
        
    else
        echo -e "  ${RED}✗ Failed - check ${insmix_output} and ${app_output}${NC}"
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
run_with_pin "post" "create" "ispc" "" ${POST_BATCH_CREATE}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_pin "post" "create" "mt" ${threads} ${POST_BATCH_CREATE}
done
generate_comparison_report "post" "create"

# Post - Lookup
run_with_pin "post" "lookup" "ispc" "" ${POST_BATCH_LOOKUP}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_pin "post" "lookup" "mt" ${threads} ${POST_BATCH_LOOKUP}
done
generate_comparison_report "post" "lookup"

# ============================================
# USER SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  USER SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# User - Create
run_with_pin "user" "create" "ispc" "" ${USER_BATCH_CREATE}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_pin "user" "create" "mt" ${threads} ${USER_BATCH_CREATE}
done
generate_comparison_report "user" "create"

# User - Login
run_with_pin "user" "login" "ispc" "" ${USER_BATCH_LOGIN}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_pin "user" "login" "mt" ${threads} ${USER_BATCH_LOGIN}
done
generate_comparison_report "user" "login"

# ============================================
# USERTAG SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  USERTAG SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# UserTag - Insert
run_with_pin "userTag" "insert" "ispc" "" ${USERTAG_BATCH_INSERT}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_pin "userTag" "insert" "mt" ${threads} ${USERTAG_BATCH_INSERT}
done
generate_comparison_report "userTag" "insert"

# UserTag - Lookup
run_with_pin "userTag" "lookup" "ispc" "" ${USERTAG_BATCH_LOOKUP}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_pin "userTag" "lookup" "mt" ${threads} ${USERTAG_BATCH_LOOKUP}
done
generate_comparison_report "userTag" "lookup"

# ============================================
# SHORTURL SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  SHORTURL SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_with_pin "shortURL" "compose" "ispc" "" ${SHORTURL_BATCH}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_pin "shortURL" "compose" "mt" ${threads} ${SHORTURL_BATCH}
done
generate_comparison_report "shortURL" "compose"

# ============================================
# TEXT SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  TEXT SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_with_pin "text" "compose" "ispc" "" ${TEXT_BATCH}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_pin "text" "compose" "mt" ${threads} ${TEXT_BATCH}
done
generate_comparison_report "text" "compose"

# ============================================
# UNIQUEID SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  UNIQUEID SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_with_pin "uniqueID" "compose" "ispc" "" ${UNIQUEID_BATCH}
for threads in "${THREAD_COUNTS[@]}"; do
    run_with_pin "uniqueID" "compose" "mt" ${threads} ${UNIQUEID_BATCH}
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
║   Instruction Count Comparison: ISPC vs MT (Scalar/SIMD)        ║
╚══════════════════════════════════════════════════════════════════╝

Generated: $(date)
Iterations per test: ${ITERATIONS}
Thread counts tested: ${THREAD_COUNTS[@]}

All measurements collected using Intel Pin with modified insmix tool.
Provides detailed scalar vs SIMD instruction breakdown.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

INSTRUCTION COUNT COMPARISON BY SERVICE:

EOF

# Process and format results
echo "" >> "${REPORT_FILE}"
echo "Service            Operation    Mode   Threads  Total_Insts     Scalar_Insts    SIMD_Insts   SIMD%    Time(µs)" >> "${REPORT_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "${REPORT_FILE}"

while IFS=',' read -r service operation mode threads total_insts scalar_insts simd_insts scalar_pct simd_pct time_us; do
    if [[ "$service" == "Service" ]]; then continue; fi
    
    printf "%-18s %-12s %-6s %-8s %15s %15s %14s %8s %12s\n" \
        "$service" "$operation" "$mode" "$threads" "$total_insts" "$scalar_insts" "$simd_insts" "$simd_pct" "$time_us" >> "${REPORT_FILE}"
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
echo -e "${YELLOW}NOTE: This script uses Intel Pin for instrumentation.${NC}"
echo -e "${YELLOW}Pin will slow down execution significantly (10-100x).${NC}"
echo -e "${YELLOW}Results show scalar vs SIMD instruction breakdown.${NC}"
echo ""
