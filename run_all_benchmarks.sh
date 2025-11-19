#!/bin/bash

# Comprehensive benchmark script for all socialGraph services
# Runs ISPC and multithreaded (1, 4, 8, 16 threads) versions
# Extracts timing, speedup, and throughput metrics

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Configuration
ITERATIONS=100
RESULTS_DIR="benchmark_results_$(date +%Y%m%d_%H%M%S)"
THREAD_COUNTS=(1 4 8 16)

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  SocialGraph Comprehensive Benchmark Suite                      ║${NC}"
echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║  Iterations: ${ITERATIONS}                                              ║${NC}"
echo -e "${BLUE}║  Thread counts: 1, 4, 8, 16                                      ║${NC}"
echo -e "${BLUE}║  Results dir: ${RESULTS_DIR}                        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Create results directory
mkdir -p "${RESULTS_DIR}"

# Summary file
SUMMARY_FILE="${RESULTS_DIR}/benchmark_summary.csv"
echo "Service,Operation,Mode,Threads,MedianTime_us,Throughput_ops_per_sec,Speedup_vs_MT1" > "${SUMMARY_FILE}"

# Function to extract median time from timing_stats CSV
extract_median_time() {
    local csv_file=$1
    if [[ -f "$csv_file" ]]; then
        # Calculate median from TotalLatency column
        awk -F',' 'NR>1 {print $5}' "$csv_file" | sort -n | awk '{a[NR]=$0} END {print (NR%2==1)?a[(NR+1)/2]:(a[NR/2]+a[NR/2+1])/2}'
    else
        echo "0"
    fi
}

# Function to extract throughput from throughput_stats CSV
extract_throughput() {
    local csv_file=$1
    if [[ -f "$csv_file" ]]; then
        grep "Throughput" "$csv_file" | head -1 | cut -d',' -f3
    else
        echo "0"
    fi
}

# Function to extract median time from benchmark output
extract_median_from_output() {
    local output_file=$1
    if [[ -f "$output_file" ]]; then
        grep "Median:" "$output_file" | head -1 | awk '{print $2}' | tr -d 'µs'
    else
        echo "0"
    fi
}

# Function to run benchmark and save results
run_benchmark() {
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
    
    # Build result file prefix
    local result_prefix="${RESULTS_DIR}/${service}_${operation}_${mode}"
    if [[ "$mode" == "mt" ]]; then
        result_prefix="${result_prefix}${threads}"
    fi
    
    echo -e "${YELLOW}Running: ${service} - ${operation} - ${mode}${threads:+ ($threads threads)}${NC}"
    
    # Change to service directory
    cd "${service_dir}"
    
    # Build command based on service
    local cmd=""
    if [[ "$service" == "text" ]]; then
        # Text service needs CSV file
        cmd="./${executable} test_texts.csv 100 ${mode_str} ${ITERATIONS}"
    elif [[ "$service" == "uniqueID" || "$service" == "shortURL" ]]; then
        # uniqueID and shortURL don't have operation types
        cmd="./${executable} ${mode_str} ${batch_size} ${ITERATIONS}"
    else
        # user, post, userTag have operation types
        cmd="./${executable} ${mode_str} ${operation} ${batch_size} ${ITERATIONS}"
    fi
    
    echo "  Command: ${cmd}"
    
    # Run benchmark and capture output
    local output_file="${result_prefix}_output.txt"
    if eval "${cmd}" > "${output_file}" 2>&1; then
        echo -e "  ${GREEN}✓ Success${NC}"
        
        # Move generated CSV files to results directory
        if [[ "$service" == "user" || "$service" == "post" || "$service" == "userTag" ]]; then
            # These services generate operation-specific CSV files
            mv -f "timing_stats_${operation}_"*.csv "${result_prefix}_timing.csv" 2>/dev/null || true
            mv -f "throughput_stats_${operation}_"*.csv "${result_prefix}_throughput.csv" 2>/dev/null || true
        else
            # Other services
            mv -f timing_stats*.csv "${result_prefix}_timing.csv" 2>/dev/null || true
            mv -f throughput_stats*.csv "${result_prefix}_throughput.csv" 2>/dev/null || true
            mv -f benchmark_stats*.csv "${result_prefix}_benchmark.csv" 2>/dev/null || true
            mv -f raw_measurements*.csv "${result_prefix}_raw.csv" 2>/dev/null || true
        fi
        
        # Extract metrics
        local median_time=$(extract_median_from_output "${output_file}")
        local throughput=$(extract_throughput "${result_prefix}_throughput.csv")
        
        # If not found in throughput file, try to calculate from median time
        if [[ "$throughput" == "0" || -z "$throughput" ]]; then
            if [[ "$median_time" != "0" && -n "$median_time" ]]; then
                throughput=$(echo "scale=2; ${batch_size} / (${median_time} / 1000000)" | bc -l)
            fi
        fi
        
        echo "  Median time: ${median_time} µs"
        echo "  Throughput: ${throughput} ops/sec"
        
        # Store for speedup calculation
        echo "${median_time},${throughput}" > "${result_prefix}_metrics.txt"
        
    else
        echo -e "  ${RED}✗ Failed${NC}"
        echo "0,0" > "${result_prefix}_metrics.txt"
    fi
    
    cd - > /dev/null
    echo ""
}

# Function to calculate speedup and add to summary
add_to_summary() {
    local service=$1
    local operation=$2
    
    echo -e "${BLUE}Calculating speedups for ${service} - ${operation}${NC}"
    
    # Get MT1 baseline
    local mt1_file="${RESULTS_DIR}/${service}_${operation}_mt1_metrics.txt"
    if [[ ! -f "$mt1_file" ]]; then
        echo -e "  ${RED}Warning: MT1 baseline not found${NC}"
        return
    fi
    
    local mt1_time=$(cut -d',' -f1 "$mt1_file")
    
    # Process each mode
    for mode in ispc mt1 mt4 mt8 mt16; do
        local threads=""
        local mode_name=""
        case $mode in
            ispc)
                mode_name="ispc"
                threads=""
                ;;
            mt1)
                mode_name="mt"
                threads="1"
                ;;
            mt4)
                mode_name="mt"
                threads="4"
                ;;
            mt8)
                mode_name="mt"
                threads="8"
                ;;
            mt16)
                mode_name="mt"
                threads="16"
                ;;
        esac
        
        local metrics_file="${RESULTS_DIR}/${service}_${operation}_${mode}_metrics.txt"
        if [[ -f "$metrics_file" ]]; then
            local median_time=$(cut -d',' -f1 "$metrics_file")
            local throughput=$(cut -d',' -f2 "$metrics_file")
            
            # Calculate speedup vs MT1
            local speedup="1.00"
            if [[ "$median_time" != "0" && -n "$median_time" && "$mt1_time" != "0" ]]; then
                speedup=$(echo "scale=2; ${mt1_time} / ${median_time}" | bc -l)
            fi
            
            echo "${service},${operation},${mode_name},${threads},${median_time},${throughput},${speedup}" >> "${SUMMARY_FILE}"
            echo "  ${mode}: ${speedup}x speedup"
        fi
    done
    echo ""
}

# ============================================================================
# POST SERVICE
# ============================================================================
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  POST SERVICE${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"

POST_BATCH_CREATE=1000
POST_BATCH_LOOKUP=100

# Create operation
for threads in "${THREAD_COUNTS[@]}"; do
    run_benchmark "post" "create" "mt" "$threads" "$POST_BATCH_CREATE"
done
run_benchmark "post" "create" "ispc" "" "$POST_BATCH_CREATE"
add_to_summary "post" "create"

# Lookup operation
for threads in "${THREAD_COUNTS[@]}"; do
    run_benchmark "post" "lookup" "mt" "$threads" "$POST_BATCH_LOOKUP"
done
run_benchmark "post" "lookup" "ispc" "" "$POST_BATCH_LOOKUP"
add_to_summary "post" "lookup"

# ============================================================================
# USER SERVICE
# ============================================================================
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  USER SERVICE${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"

USER_BATCH_CREATE=1000
USER_BATCH_LOGIN=1000

# Create operation
for threads in "${THREAD_COUNTS[@]}"; do
    run_benchmark "user" "create" "mt" "$threads" "$USER_BATCH_CREATE"
done
run_benchmark "user" "create" "ispc" "" "$USER_BATCH_CREATE"
add_to_summary "user" "create"

# Login operation
for threads in "${THREAD_COUNTS[@]}"; do
    run_benchmark "user" "login" "mt" "$threads" "$USER_BATCH_LOGIN"
done
run_benchmark "user" "login" "ispc" "" "$USER_BATCH_LOGIN"
add_to_summary "user" "login"

# ============================================================================
# USERTAG SERVICE
# ============================================================================
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  USERTAG SERVICE${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"

USERTAG_BATCH_INSERT=4
USERTAG_BATCH_LOOKUP=4

# Insert operation
for threads in "${THREAD_COUNTS[@]}"; do
    run_benchmark "userTag" "insert" "mt" "$threads" "$USERTAG_BATCH_INSERT"
done
run_benchmark "userTag" "insert" "ispc" "" "$USERTAG_BATCH_INSERT"
add_to_summary "userTag" "insert"

# Lookup operation
for threads in "${THREAD_COUNTS[@]}"; do
    run_benchmark "userTag" "lookup" "mt" "$threads" "$USERTAG_BATCH_LOOKUP"
done
run_benchmark "userTag" "lookup" "ispc" "" "$USERTAG_BATCH_LOOKUP"
add_to_summary "userTag" "lookup"

# ============================================================================
# TEXT SERVICE
# ============================================================================
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  TEXT SERVICE${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"

TEXT_BATCH=100

# Text service (single operation)
for threads in "${THREAD_COUNTS[@]}"; do
    run_benchmark "text" "process" "mt" "$threads" "$TEXT_BATCH"
done
run_benchmark "text" "process" "ispc" "" "$TEXT_BATCH"
add_to_summary "text" "process"

# ============================================================================
# SHORTURL SERVICE
# ============================================================================
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  SHORTURL SERVICE${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"

SHORTURL_BATCH=1000

# ShortURL service (single operation)
for threads in "${THREAD_COUNTS[@]}"; do
    run_benchmark "shortURL" "shorten" "mt" "$threads" "$SHORTURL_BATCH"
done
run_benchmark "shortURL" "shorten" "ispc" "" "$SHORTURL_BATCH"
add_to_summary "shortURL" "shorten"

# ============================================================================
# UNIQUEID SERVICE
# ============================================================================
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  UNIQUEID SERVICE${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"

UNIQUEID_BATCH=1000

# UniqueID service (single operation)
for threads in "${THREAD_COUNTS[@]}"; do
    run_benchmark "uniqueID" "generate" "mt" "$threads" "$UNIQUEID_BATCH"
done
run_benchmark "uniqueID" "generate" "ispc" "" "$UNIQUEID_BATCH"
add_to_summary "uniqueID" "generate"

# ============================================================================
# GENERATE SUMMARY REPORT
# ============================================================================
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"
echo -e "${GREEN}  GENERATING SUMMARY REPORT${NC}"
echo -e "${GREEN}═══════════════════════════════════════════════════════════════════${NC}"

REPORT_FILE="${RESULTS_DIR}/BENCHMARK_REPORT.txt"

{
    echo "╔══════════════════════════════════════════════════════════════════╗"
    echo "║  SocialGraph Benchmark Results Summary                          ║"
    echo "║  $(date)                                    ║"
    echo "╚══════════════════════════════════════════════════════════════════╝"
    echo ""
    echo "Configuration:"
    echo "  Iterations: ${ITERATIONS}"
    echo "  Thread counts: ${THREAD_COUNTS[*]}"
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    
    # Process each service
    while IFS=, read -r service operation mode threads median_time throughput speedup; do
        if [[ "$service" == "Service" ]]; then
            continue  # Skip header
        fi
        
        if [[ -z "$threads" ]]; then
            threads="N/A"
        fi
        
        printf "%-12s %-10s %-6s %-8s %12s µs  %15s ops/s  %6sx\n" \
            "$service" "$operation" "$mode" "$threads" "$median_time" "$throughput" "$speedup"
    done < "${SUMMARY_FILE}"
    
    echo ""
    echo "════════════════════════════════════════════════════════════════════"
    echo ""
    echo "Best Speedups (vs MT1):"
    echo ""
    
    # Find best speedup for each service/operation
    tail -n +2 "${SUMMARY_FILE}" | awk -F',' '
    {
        key = $1 "," $2
        if ($7 > max[key]) {
            max[key] = $7
            line[key] = $0
        }
    }
    END {
        for (k in max) {
            split(line[k], a, ",")
            printf "  %-12s %-10s: %5.2fx (%s %s threads)\n", a[1], a[2], a[7], a[3], a[4]
        }
    }' | sort
    
    echo ""
    echo "Files generated in: ${RESULTS_DIR}/"
    echo "  - benchmark_summary.csv: Comprehensive results"
    echo "  - *_output.txt: Raw benchmark output"
    echo "  - *_timing.csv: Detailed timing data"
    echo "  - *_throughput.csv: Throughput statistics"
    
} > "${REPORT_FILE}"

# Display report
cat "${REPORT_FILE}"

echo ""
echo -e "${GREEN}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${GREEN}║  Benchmark Complete!                                             ║${NC}"
echo -e "${GREEN}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${GREEN}║  Results saved to: ${RESULTS_DIR}/${NC}"
echo -e "${GREEN}║  Summary: ${RESULTS_DIR}/benchmark_summary.csv${NC}"
echo -e "${GREEN}║  Report:  ${RESULTS_DIR}/BENCHMARK_REPORT.txt${NC}"
echo -e "${GREEN}╚══════════════════════════════════════════════════════════════════╝${NC}"
