#!/bin/bash

# Comprehensive benchmark script for all socialGraph services
# Runs ISPC and multithreaded (1, 4, 8, 16 threads) with POOL and SPAWN modes
# Extracts timing, speedup, and throughput metrics

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

# Configuration
ITERATIONS=1000
RESULTS_DIR="benchmark_results_$(date +%Y%m%d_%H%M%S)"
THREAD_COUNTS=(1 4 8 16)
MT_MODES=("pool" "spawn")  # Test both threadpool and spawn modes

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  SocialGraph Comprehensive Benchmark Suite                      ║${NC}"
echo -e "${BLUE}╠══════════════════════════════════════════════════════════════════╣${NC}"
echo -e "${BLUE}║  Iterations: ${ITERATIONS}                                              ║${NC}"
echo -e "${BLUE}║  Thread counts: 1, 4, 8, 16                                      ║${NC}"
echo -e "${BLUE}║  MT modes: pool, spawn                                           ║${NC}"
echo -e "${BLUE}║  Results dir: ${RESULTS_DIR}                        ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Create results directory
mkdir -p "${RESULTS_DIR}"

# Summary file
SUMMARY_FILE="${RESULTS_DIR}/benchmark_summary.csv"
echo "Service,Operation,Mode,Threads,MTMode,MaxLatency_cycles,Throughput_ops_per_sec,Speedup_vs_MT1_Spawn,Throughput_Ratio_vs_MT1_Spawn,Total_Core_Energy_J,Total_Pkg_Energy_J,Total_DRAM_Energy_J,Avg_Pkg_Power_W,Energy_Ratio_vs_MT1_Spawn" > "${SUMMARY_FILE}"

# Function to extract max total latency from timing CSV (largest lane latency)
extract_max_latency_from_timing() {
    local timing_file=$1
    if [[ -f "$timing_file" ]]; then
        # Check the header to determine which column has TotalLatency
        local header=$(head -1 "$timing_file")
        local column_num
        
        # Count commas to determine format
        # Format 1: "Operation,Lane,QueueingDelay,ExecutionTime,TotalLatency" (column 5)
        # Format 2: "Lane,QueueingDelay,ExecutionTime,TotalLatency" (column 4)
        if [[ "$header" == Operation* ]]; then
            column_num=5
        else
            column_num=4
        fi
        
        # Skip header, extract TotalLatency column, find maximum
        tail -n +2 "$timing_file" | cut -d',' -f${column_num} | sort -n | tail -1
    else
        echo "0"
    fi
}

# Function to calculate throughput from max latency and batch size
calculate_throughput() {
    local max_latency_cycles=$1
    local batch_size=$2
    
    # Assuming a typical CPU frequency of 3.0 GHz for cycle-to-time conversion
    # You may need to adjust this based on your actual CPU frequency
    local cpu_freq_ghz=3.0
    
    if [[ "$max_latency_cycles" != "0" && -n "$max_latency_cycles" ]]; then
        # Convert cycles to seconds: cycles / (freq_ghz * 10^9)
        # Then calculate ops/sec: batch_size / time_seconds
        # Simplified: batch_size * freq_ghz * 10^9 / cycles
        local throughput=$(echo "scale=2; ${batch_size} * ${cpu_freq_ghz} * 1000000000 / ${max_latency_cycles}" | bc -l)
        echo "$throughput"
    else
        echo "0"
    fi
}

# Function to extract energy metrics from energy summary CSV
extract_energy_metrics() {
    local energy_summary_file=$1
    
    if [[ -f "$energy_summary_file" ]]; then
        # Energy summary format: Kernel,Samples,AvgPackage_J,StdDevPackage_J,AvgCore_J,StdDevCore_J,
        #                        AvgDRAM_J,StdDevDRAM_J,TotalPackage_J,TotalCore_J,TotalDRAM_J,TotalTime_s,
        #                        AvgTime_s,AvgPower_W,MinPackage_J,MaxPackage_J,CV_Percent
        # Skip header and get the data row
        local data_line=$(tail -n +2 "$energy_summary_file" 2>/dev/null | head -1)
        
        if [[ -n "$data_line" ]]; then
            # Extract: TotalPackage_J (col 9), TotalCore_J (col 10), TotalDRAM_J (col 11), AvgPower_W (col 14)
            local total_pkg_energy=$(echo "$data_line" | cut -d',' -f9)
            local total_core_energy=$(echo "$data_line" | cut -d',' -f10)
            local total_dram_energy=$(echo "$data_line" | cut -d',' -f11)
            local avg_pkg_power=$(echo "$data_line" | cut -d',' -f14)
            
            echo "${total_core_energy},${total_pkg_energy},${total_dram_energy},${avg_pkg_power}"
        else
            echo "0,0,0,0"
        fi
    else
        echo "0,0,0,0"
    fi
}

# Function to run benchmark and save results
run_benchmark() {
    local service=$1
    local operation=$2
    local mode=$3
    local threads=$4
    local mt_mode=$5
    local batch_size=$6
    
    local service_dir="${service}"
    local executable="simple"
    
    # Build mode string for command
    local mode_str=""
    if [[ "$mode" == "ispc" ]]; then
        mode_str="ispc"
        mt_mode="N/A"  # Not applicable for ISPC
    else
        mode_str="mt ${threads}"
    fi
    
    # Build result file prefix with absolute path
    local result_prefix="$(pwd)/${RESULTS_DIR}/${service}_${operation}_${mode}"
    if [[ "$mode" == "mt" ]]; then
        result_prefix="${result_prefix}${threads}_${mt_mode}"
    fi
    
    local display_str="${service} - ${operation} - ${mode}"
    if [[ "$mode" == "mt" ]]; then
        display_str="${display_str} (${threads} threads, ${mt_mode})"
    fi
    echo -e "${YELLOW}Running: ${display_str}${NC}"
    
    # Change to service directory
    cd "${service_dir}"
    
    # Build command based on service - now with mt_mode for MT tests
    local cmd=""
    if [[ "$service" == "user" ]]; then
        if [[ "$mode" == "ispc" ]]; then
            cmd="./${executable} ispc ${operation} ${batch_size} 0.0 ${ITERATIONS}"
        else
            cmd="./${executable} mt ${threads} ${operation} ${mt_mode} ${batch_size} 0.0 ${ITERATIONS}"
        fi
    elif [[ "$service" == "post" ]]; then
        if [[ "$mode" == "ispc" ]]; then
            cmd="./${executable} ispc ${operation} ${batch_size} ${ITERATIONS}"
        else
            cmd="./${executable} mt ${threads} ${operation} ${mt_mode} ${batch_size} ${ITERATIONS}"
        fi
    elif [[ "$service" == "userTag" ]]; then
        if [[ "$mode" == "ispc" ]]; then
            cmd="./${executable} ispc ${operation} ${batch_size} ${ITERATIONS}"
        else
            cmd="./${executable} mt ${threads} ${operation} ${mt_mode} ${batch_size} ${ITERATIONS}"
        fi
    elif [[ "$service" == "text" ]]; then
        # Text service needs CSV file with different argument order
        if [[ "$mode" == "ispc" ]]; then
            cmd="./${executable} /home/aalawneh/energy/socialGraph/text/test.txt ${batch_size}  ${ITERATIONS}"
        else
            cmd="./${executable} /home/aalawneh/energy/socialGraph/text/test.txt ${batch_size}  mt ${threads} ${mt_mode} ${ITERATIONS}"
        fi
    elif [[ "$service" == "uniqueID" || "$service" == "shortURL" ]]; then
        # uniqueID and shortURL don't have operation types
        if [[ "$mode" == "ispc" ]]; then
            cmd="./${executable} ispc ${batch_size} ${ITERATIONS}"
        else
            cmd="./${executable} mt ${threads} ${mt_mode} ${batch_size} ${ITERATIONS}"
        fi
    fi
    
    echo "  Command: ${cmd}"
    
    # Run benchmark and capture output
    local output_file="${result_prefix}_output.txt"
    if eval "${cmd}" > "${output_file}" 2>&1; then
        echo -e "  ${GREEN}✓ Success${NC}"
        
        # Copy generated CSV files to results directory (keep originals for CDF plotting)
        # Build specific filename patterns based on service
        if [[ "$service" == "user" ]]; then
            # user service pattern: timing_stats_user_{mode}_{operation}_N{batch}_fail0.csv
            local csv_pattern="user_${mode}"
            if [[ "$mode" == "mt" ]]; then
                csv_pattern="user_mt${threads}_${mt_mode}"
            fi
            cp -f timing_stats_${csv_pattern}_${operation}_N${batch_size}_fail*.csv "${result_prefix}_timing.csv" 2>/dev/null || true
            cp -f throughput_stats_${csv_pattern}_${operation}_N${batch_size}_fail*.csv "${result_prefix}_throughput.csv" 2>/dev/null || true
            cp -f benchmark_stats_${csv_pattern}_${operation}_N${batch_size}_fail*.csv "${result_prefix}_benchmark.csv" 2>/dev/null || true
            cp -f raw_measurements_${csv_pattern}_${operation}_N${batch_size}_fail*.csv "${result_prefix}_raw.csv" 2>/dev/null || true
            cp -f energy_measurements_${csv_pattern}_${operation}_N${batch_size}_fail*.csv "${result_prefix}_energy.csv" 2>/dev/null || true
            cp -f energy_summary_${csv_pattern}_${operation}_N${batch_size}_fail*.csv "${result_prefix}_energy_summary.csv" 2>/dev/null || true
        elif [[ "$service" == "post" ]]; then
            # post pattern: timing_stats_{operation}_{mode}_N{batch}.csv
            local csv_pattern="${operation}_${mode}"
            if [[ "$mode" == "mt" ]]; then
                csv_pattern="${operation}_mt${threads}_${mt_mode}"
            fi
            cp -f timing_stats_${csv_pattern}_N${batch_size}.csv "${result_prefix}_timing.csv" 2>/dev/null || true
            cp -f throughput_stats_${csv_pattern}_N${batch_size}.csv "${result_prefix}_throughput.csv" 2>/dev/null || true
            cp -f benchmark_stats_${csv_pattern}_N${batch_size}.csv "${result_prefix}_benchmark.csv" 2>/dev/null || true
            cp -f raw_measurements_${csv_pattern}_N${batch_size}.csv "${result_prefix}_raw.csv" 2>/dev/null || true
            cp -f energy_measurements_${csv_pattern}_N${batch_size}.csv "${result_prefix}_energy.csv" 2>/dev/null || true
            cp -f energy_summary_${csv_pattern}_N${batch_size}.csv "${result_prefix}_energy_summary.csv" 2>/dev/null || true
        elif [[ "$service" == "userTag" ]]; then
            # userTag pattern: timing_stats_{operation}_{mode}.csv
            # energy files now use same pattern as other services: energy_*_{operation}_mt{threads}_{mt_mode}_[b/q]{batch_size}.csv
            local csv_pattern="${operation}_${mode}"
            
            if [[ "$mode" == "mt" ]]; then
                csv_pattern="${operation}_mt${threads}_${mt_mode}"
            fi
            
            # Determine the batch/query size prefix (b for insert, q for lookup)
            local size_prefix="b"
            if [[ "$operation" == "lookup" ]]; then
                size_prefix="q"
            fi
            
            cp -f timing_stats_${csv_pattern}.csv "${result_prefix}_timing.csv" 2>/dev/null || true
            cp -f throughput_stats_${csv_pattern}.csv "${result_prefix}_throughput.csv" 2>/dev/null || true
            cp -f benchmark_stats_${csv_pattern}.csv "${result_prefix}_benchmark.csv" 2>/dev/null || true
            cp -f raw_measurements_${csv_pattern}.csv "${result_prefix}_raw.csv" 2>/dev/null || true
            cp -f energy_measurements_${csv_pattern}_${size_prefix}${batch_size}.csv "${result_prefix}_energy.csv" 2>/dev/null || true
            cp -f energy_summary_${csv_pattern}_${size_prefix}${batch_size}.csv "${result_prefix}_energy_summary.csv" 2>/dev/null || true
        elif [[ "$service" == "text" ]]; then
            # text service pattern: timing_stats_compose_{mode}_N{batch}.csv
            local csv_pattern="compose_${mode}"
            if [[ "$mode" == "mt" ]]; then
                csv_pattern="compose_mt${threads}_${mt_mode}"
            fi
            cp -f timing_stats_${csv_pattern}_N${batch_size}.csv "${result_prefix}_timing.csv" 2>/dev/null || true
            cp -f throughput_stats_${csv_pattern}_N${batch_size}.csv "${result_prefix}_throughput.csv" 2>/dev/null || true
            cp -f benchmark_stats_${csv_pattern}_N${batch_size}.csv "${result_prefix}_benchmark.csv" 2>/dev/null || true
            cp -f raw_measurements_${csv_pattern}_N${batch_size}.csv "${result_prefix}_raw.csv" 2>/dev/null || true
            cp -f energy_measurements_${csv_pattern}_N${batch_size}.csv "${result_prefix}_energy.csv" 2>/dev/null || true
            cp -f energy_summary_${csv_pattern}_N${batch_size}.csv "${result_prefix}_energy_summary.csv" 2>/dev/null || true
        elif [[ "$service" == "uniqueID" || "$service" == "shortURL" ]]; then
            # uniqueID and shortURL pattern: timing_stats_{mode}_N{batch}.csv
            local csv_pattern="${mode}"
            if [[ "$mode" == "mt" ]]; then
                csv_pattern="mt${threads}_${mt_mode}"
            fi
            cp -f timing_stats_${csv_pattern}_N${batch_size}.csv "${result_prefix}_timing.csv" 2>/dev/null || true
            cp -f throughput_stats_${csv_pattern}_N${batch_size}.csv "${result_prefix}_throughput.csv" 2>/dev/null || true
            cp -f benchmark_stats_${csv_pattern}_N${batch_size}.csv "${result_prefix}_benchmark.csv" 2>/dev/null || true
            cp -f raw_measurements_${csv_pattern}_N${batch_size}.csv "${result_prefix}_raw.csv" 2>/dev/null || true
            cp -f energy_measurements_${csv_pattern}_N${batch_size}.csv "${result_prefix}_energy.csv" 2>/dev/null || true
            cp -f energy_summary_${csv_pattern}_N${batch_size}.csv "${result_prefix}_energy_summary.csv" 2>/dev/null || true
        else
            # Generic fallback: use wildcard (may need refinement)
            cp -f timing_stats*.csv "${result_prefix}_timing.csv" 2>/dev/null || true
            cp -f throughput_stats*.csv "${result_prefix}_throughput.csv" 2>/dev/null || true
            cp -f benchmark_stats*.csv "${result_prefix}_benchmark.csv" 2>/dev/null || true
            cp -f raw_measurements*.csv "${result_prefix}_raw.csv" 2>/dev/null || true
            cp -f energy_measurements*.csv "${result_prefix}_energy.csv" 2>/dev/null || true
            cp -f energy_summary*.csv "${result_prefix}_energy_summary.csv" 2>/dev/null || true
        fi
        
        # Extract metrics from timing CSV file (max total latency across all lanes)
        local max_latency_cycles=$(extract_max_latency_from_timing "${result_prefix}_timing.csv")
        local throughput=$(calculate_throughput "${max_latency_cycles}" "${batch_size}")
        
        # Extract energy metrics from energy summary CSV
        local energy_metrics=$(extract_energy_metrics "${result_prefix}_energy_summary.csv")
        local total_core_energy=$(echo "$energy_metrics" | cut -d',' -f1)
        local total_pkg_energy=$(echo "$energy_metrics" | cut -d',' -f2)
        local total_dram_energy=$(echo "$energy_metrics" | cut -d',' -f3)
        local avg_pkg_power=$(echo "$energy_metrics" | cut -d',' -f4)
        
        echo "  Max lane latency: ${max_latency_cycles} cycles"
        echo "  Throughput: ${throughput} ops/sec"
        echo "  Total Core Energy: ${total_core_energy} J, Avg Power: ${avg_pkg_power} W"
        
        # Store for speedup calculation (using cycles instead of microseconds)
        echo "${max_latency_cycles},${throughput},${total_core_energy},${total_pkg_energy},${total_dram_energy},${avg_pkg_power}" > "${result_prefix}_metrics.txt"
        
    else
        echo -e "  ${RED}✗ Failed - check ${output_file}${NC}"
        echo "0,0,0,0,0,0" > "${result_prefix}_metrics.txt"
    fi
    
    cd - > /dev/null
    echo ""
}

# Function to calculate speedup and add to summary
add_to_summary() {
    local service=$1
    local operation=$2
    
    echo -e "${CYAN}Calculating speedups for ${service} - ${operation}${NC}"
    
    # Get MT1 SPAWN baseline (this is our baseline for all comparisons)
    local mt1_spawn_file="${RESULTS_DIR}/${service}_${operation}_mt1_spawn_metrics.txt"
    if [[ ! -f "$mt1_spawn_file" ]]; then
        echo -e "  ${RED}Warning: MT1 SPAWN baseline not found${NC}"
        return
    fi
    
    local mt1_spawn_cycles=$(cut -d',' -f1 "$mt1_spawn_file")
    local mt1_spawn_throughput=$(cut -d',' -f2 "$mt1_spawn_file")
    local mt1_spawn_total_core_energy=$(cut -d',' -f3 "$mt1_spawn_file")
    local mt1_spawn_total_pkg_energy=$(cut -d',' -f4 "$mt1_spawn_file")
    local mt1_spawn_total_dram_energy=$(cut -d',' -f5 "$mt1_spawn_file")
    local mt1_spawn_avg_pkg_power=$(cut -d',' -f6 "$mt1_spawn_file")
    echo "  MT1 SPAWN baseline: ${mt1_spawn_cycles} cycles, ${mt1_spawn_throughput} ops/sec, ${mt1_spawn_total_core_energy} J (total core)"
    
    # Process ISPC
    local ispc_file="${RESULTS_DIR}/${service}_${operation}_ispc_metrics.txt"
    if [[ -f "$ispc_file" ]]; then
        local max_latency_cycles=$(cut -d',' -f1 "$ispc_file")
        local throughput=$(cut -d',' -f2 "$ispc_file")
        local total_core_energy=$(cut -d',' -f3 "$ispc_file")
        local total_pkg_energy=$(cut -d',' -f4 "$ispc_file")
        local total_dram_energy=$(cut -d',' -f5 "$ispc_file")
        local avg_pkg_power=$(cut -d',' -f6 "$ispc_file")
        
        # Calculate speedup vs MT1 SPAWN (lower cycles = faster = higher speedup)
        local speedup="1.00"
        if [[ "$max_latency_cycles" != "0" && -n "$max_latency_cycles" && "$mt1_spawn_cycles" != "0" ]]; then
            speedup=$(echo "scale=2; ${mt1_spawn_cycles} / ${max_latency_cycles}" | bc -l)
        fi
        
        # Calculate throughput ratio vs MT1 SPAWN (higher throughput = better)
        local throughput_ratio="1.00"
        if [[ "$throughput" != "0" && -n "$throughput" && "$mt1_spawn_throughput" != "0" ]]; then
            throughput_ratio=$(echo "scale=2; ${throughput} / ${mt1_spawn_throughput}" | bc -l)
        fi
        
        # Calculate energy ratio vs MT1 SPAWN (lower total core energy = better = ratio < 1.00)
        local energy_ratio="1.00"
        if [[ "$total_core_energy" != "0" && -n "$total_core_energy" && "$mt1_spawn_total_core_energy" != "0" ]]; then
            energy_ratio=$(echo "scale=2; ${total_core_energy} / ${mt1_spawn_total_core_energy}" | bc -l)
        fi
        
        echo "${service},${operation},ispc,,N/A,${max_latency_cycles},${throughput},${speedup},${throughput_ratio},${total_core_energy},${total_pkg_energy},${total_dram_energy},${avg_pkg_power},${energy_ratio}" >> "${SUMMARY_FILE}"
        echo "  ISPC: ${max_latency_cycles} cycles, ${throughput} ops/sec, ${speedup}x speedup, ${throughput_ratio}x throughput, ${total_core_energy}J total (${energy_ratio}x energy)"
    fi
    
    # Process each MT mode
    for mt_mode in "${MT_MODES[@]}"; do
        for threads in "${THREAD_COUNTS[@]}"; do
            local metrics_file="${RESULTS_DIR}/${service}_${operation}_mt${threads}_${mt_mode}_metrics.txt"
            if [[ -f "$metrics_file" ]]; then
                local max_latency_cycles=$(cut -d',' -f1 "$metrics_file")
                local throughput=$(cut -d',' -f2 "$metrics_file")
                local total_core_energy=$(cut -d',' -f3 "$metrics_file")
                local total_pkg_energy=$(cut -d',' -f4 "$metrics_file")
                local total_dram_energy=$(cut -d',' -f5 "$metrics_file")
                local avg_pkg_power=$(cut -d',' -f6 "$metrics_file")
                
                # Calculate speedup vs MT1 SPAWN (lower cycles = faster = higher speedup)
                local speedup="1.00"
                if [[ "$max_latency_cycles" != "0" && -n "$max_latency_cycles" && "$mt1_spawn_cycles" != "0" ]]; then
                    speedup=$(echo "scale=2; ${mt1_spawn_cycles} / ${max_latency_cycles}" | bc -l)
                fi
                
                # Calculate throughput ratio vs MT1 SPAWN (higher throughput = better)
                local throughput_ratio="1.00"
                if [[ "$throughput" != "0" && -n "$throughput" && "$mt1_spawn_throughput" != "0" ]]; then
                    throughput_ratio=$(echo "scale=2; ${throughput} / ${mt1_spawn_throughput}" | bc -l)
                fi
                
                # Calculate energy ratio vs MT1 SPAWN (lower total core energy = better = ratio < 1.00)
                local energy_ratio="1.00"
                if [[ "$total_core_energy" != "0" && -n "$total_core_energy" && "$mt1_spawn_total_core_energy" != "0" ]]; then
                    energy_ratio=$(echo "scale=2; ${total_core_energy} / ${mt1_spawn_total_core_energy}" | bc -l)
                fi
                
                echo "${service},${operation},mt,${threads},${mt_mode},${max_latency_cycles},${throughput},${speedup},${throughput_ratio},${total_core_energy},${total_pkg_energy},${total_dram_energy},${avg_pkg_power},${energy_ratio}" >> "${SUMMARY_FILE}"
                echo "  MT${threads} (${mt_mode}): ${max_latency_cycles} cycles, ${throughput} ops/sec, ${speedup}x speedup, ${throughput_ratio}x throughput, ${total_core_energy}J total (${energy_ratio}x energy)"
            fi
        done
    done
    
    echo ""
}

# ============================================
# MAIN BENCHMARK EXECUTION
# ============================================

# Batch sizes for each service/operation (all set to 2000 requests)
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
echo -e "${GREEN}  Starting Benchmark Suite${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""

# ============================================
# POST SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  POST SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# Post - Create
run_benchmark "post" "create" "ispc" "" "N/A" ${POST_BATCH_CREATE}
for threads in "${THREAD_COUNTS[@]}"; do
    for mt_mode in "${MT_MODES[@]}"; do
        run_benchmark "post" "create" "mt" ${threads} ${mt_mode} ${POST_BATCH_CREATE}
    done
done
add_to_summary "post" "create"

# Post - Lookup
run_benchmark "post" "lookup" "ispc" "" "N/A" ${POST_BATCH_LOOKUP}
for threads in "${THREAD_COUNTS[@]}"; do
    for mt_mode in "${MT_MODES[@]}"; do
        run_benchmark "post" "lookup" "mt" ${threads} ${mt_mode} ${POST_BATCH_LOOKUP}
    done
done
add_to_summary "post" "lookup"

# ============================================
# USER SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  USER SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# User - Create
run_benchmark "user" "create" "ispc" "" "N/A" ${USER_BATCH_CREATE}
for threads in "${THREAD_COUNTS[@]}"; do
    for mt_mode in "${MT_MODES[@]}"; do
        run_benchmark "user" "create" "mt" ${threads} ${mt_mode} ${USER_BATCH_CREATE}
    done
done
add_to_summary "user" "create"

# User - Login
run_benchmark "user" "login" "ispc" "" "N/A" ${USER_BATCH_LOGIN}
for threads in "${THREAD_COUNTS[@]}"; do
    for mt_mode in "${MT_MODES[@]}"; do
        run_benchmark "user" "login" "mt" ${threads} ${mt_mode} ${USER_BATCH_LOGIN}
    done
done
add_to_summary "user" "login"

# ============================================
# USERTAG SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  USERTAG SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

# UserTag - Insert
run_benchmark "userTag" "insert" "ispc" "" "N/A" ${USERTAG_BATCH_INSERT}
for threads in "${THREAD_COUNTS[@]}"; do
    for mt_mode in "${MT_MODES[@]}"; do
        run_benchmark "userTag" "insert" "mt" ${threads} ${mt_mode} ${USERTAG_BATCH_INSERT}
    done
done
add_to_summary "userTag" "insert"

# UserTag - Lookup
run_benchmark "userTag" "lookup" "ispc" "" "N/A" ${USERTAG_BATCH_LOOKUP}
for threads in "${THREAD_COUNTS[@]}"; do
    for mt_mode in "${MT_MODES[@]}"; do
        run_benchmark "userTag" "lookup" "mt" ${threads} ${mt_mode} ${USERTAG_BATCH_LOOKUP}
    done
done
add_to_summary "userTag" "lookup"

# ============================================
# SHORTURL SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  SHORTURL SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_benchmark "shortURL" "compose" "ispc" "" "N/A" ${SHORTURL_BATCH}
for threads in "${THREAD_COUNTS[@]}"; do
    for mt_mode in "${MT_MODES[@]}"; do
        run_benchmark "shortURL" "compose" "mt" ${threads} ${mt_mode} ${SHORTURL_BATCH}
    done
done
add_to_summary "shortURL" "compose"

# ============================================
# TEXT SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  TEXT SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_benchmark "text" "compose" "ispc" "" "N/A" ${TEXT_BATCH}
for threads in "${THREAD_COUNTS[@]}"; do
    for mt_mode in "${MT_MODES[@]}"; do
        run_benchmark "text" "compose" "mt" ${threads} ${mt_mode} ${TEXT_BATCH}
    done
done
add_to_summary "text" "compose"

# ============================================
# UNIQUEID SERVICE
# ============================================
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"
echo -e "${BLUE}  UNIQUEID SERVICE${NC}"
echo -e "${BLUE}━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━${NC}"

run_benchmark "uniqueID" "compose" "ispc" "" "N/A" ${UNIQUEID_BATCH}
for threads in "${THREAD_COUNTS[@]}"; do
    for mt_mode in "${MT_MODES[@]}"; do
        run_benchmark "uniqueID" "compose" "mt" ${threads} ${mt_mode} ${UNIQUEID_BATCH}
    done
done
add_to_summary "uniqueID" "compose"

# ============================================
# GENERATE SUMMARY REPORT
# ============================================
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Generating Summary Report${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""

REPORT_FILE="${RESULTS_DIR}/BENCHMARK_REPORT.txt"

cat > "${REPORT_FILE}" << EOF
╔══════════════════════════════════════════════════════════════════╗
║        SocialGraph Benchmark Results Summary                     ║
╚══════════════════════════════════════════════════════════════════╝

Generated: $(date)
Iterations per test: ${ITERATIONS}
Thread counts tested: ${THREAD_COUNTS[@]}
MT modes tested: ${MT_MODES[@]}

All speedups, throughput ratios, and energy ratios calculated relative to MT1 (SPAWN mode) baseline.

━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

PERFORMANCE RESULTS BY SERVICE:

EOF

# Read and format summary
while IFS=',' read -r service operation mode threads mt_mode max_latency throughput speedup throughput_ratio pkg_energy core_energy dram_energy pkg_power energy_ratio; do
    if [[ "$service" == "Service" ]]; then continue; fi
    
    printf "%-12s %-10s %-6s %-8s %-8s %15s cycles %15s ops/s %8s %10s\n" \
        "$service" "$operation" "$mode" "$threads" "$mt_mode" "$max_latency" "$throughput" "${speedup}x" "${throughput_ratio}x" >> "${REPORT_FILE}"
done < "${SUMMARY_FILE}"

echo "" >> "${REPORT_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "${REPORT_FILE}"
echo "" >> "${REPORT_FILE}"
echo "ENERGY RESULTS BY SERVICE:" >> "${REPORT_FILE}"
echo "" >> "${REPORT_FILE}"

# Read and format energy summary
while IFS=',' read -r service operation mode threads mt_mode max_latency throughput speedup throughput_ratio total_core_energy total_pkg_energy total_dram_energy avg_pkg_power energy_ratio; do
    if [[ "$service" == "Service" ]]; then continue; fi
    
    printf "%-12s %-10s %-6s %-8s %-8s %10s J %10s J %10s J %10s W %10s\n" \
        "$service" "$operation" "$mode" "$threads" "$mt_mode" "$total_core_energy" "$total_pkg_energy" "$total_dram_energy" "$avg_pkg_power" "${energy_ratio}x" >> "${REPORT_FILE}"
done < "${SUMMARY_FILE}"

echo "" >> "${REPORT_FILE}"
echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━" >> "${REPORT_FILE}"
echo "" >> "${REPORT_FILE}"
echo "CSV Summary: ${SUMMARY_FILE}" >> "${REPORT_FILE}"
echo "All result files in: ${RESULTS_DIR}/" >> "${REPORT_FILE}"
echo "" >> "${REPORT_FILE}"

cat "${REPORT_FILE}"

echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  Benchmark Complete!${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}"
echo ""
echo -e "Summary: ${CYAN}${SUMMARY_FILE}${NC}"
echo -e "Report:  ${CYAN}${REPORT_FILE}${NC}"
echo -e "Results: ${CYAN}${RESULTS_DIR}/${NC}"
echo ""
