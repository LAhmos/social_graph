#!/usr/bin/env python3
"""
Analyze benchmark results and generate comparison tables and charts
"""

import csv
import sys
from pathlib import Path
from collections import defaultdict

def load_results(csv_file):
    """Load benchmark results from CSV file"""
    results = defaultdict(lambda: defaultdict(dict))
    
    with open(csv_file, 'r') as f:
        reader = csv.DictReader(f)
        for row in reader:
            service = row['Service']
            operation = row['Operation']
            mode = row['Mode']
            threads = row['Threads']
            mt_mode = row.get('MTMode', 'N/A')
            
            # Build key based on mode
            if mode == 'ispc':
                key = 'ispc_'
            else:
                key = f"{mode}_{threads}_{mt_mode}"
            
            results[service][operation][key] = {
                'median_time': float(row['MedianTime_us']),
                'throughput': float(row['Throughput_ops_per_sec']),
                'speedup': float(row.get('Speedup_vs_MT1_Pool', row.get('Speedup_vs_MT1', 1.0))),
                'mode': mode,
                'threads': threads,
                'mt_mode': mt_mode
            }
    
    return results

def print_comparison_table(results):
    """Print formatted comparison table"""
    print("\n" + "="*100)
    print("BENCHMARK RESULTS COMPARISON")
    print("="*100 + "\n")
    
    for service in sorted(results.keys()):
        print(f"\n{'='*100}")
        print(f"SERVICE: {service.upper()}")
        print(f"{'='*100}")
        
        for operation in sorted(results[service].keys()):
            data = results[service][operation]
            
            print(f"\nOperation: {operation}")
            print(f"{'-'*120}")
            print(f"{'Mode':<15} {'Threads':<10} {'MT Mode':<12} {'Time (µs)':<15} {'Throughput':<20} {'Speedup vs MT1 Pool':<20}")
            print(f"{'-'*120}")
            
            # Order: MT1 pool/spawn, MT4 pool/spawn, MT8, MT16, ISPC
            # Sort keys to ensure consistent ordering
            sorted_keys = sorted(data.keys(), key=lambda x: (
                0 if x.startswith('ispc') else 1,
                0 if 'pool' in x else 1,
                int(x.split('_')[1]) if x.startswith('mt') else 0
            ))
            
            for key in sorted_keys:
                info = data[key]
                mode = info['mode'].upper()
                threads = info['threads'] if info['threads'] else "N/A"
                mt_mode = info['mt_mode'] if info['mt_mode'] != "N/A" else ""
                
                print(f"{mode:<15} {threads:<10} {mt_mode:<12} {info['median_time']:<15.2f} "
                      f"{info['throughput']:<20.2f} {info['speedup']:<20.2f}x")
            print()

def print_speedup_summary(results):
    """Print speedup summary"""
    print("\n" + "="*140)
    print("SPEEDUP SUMMARY (vs MT1 POOL baseline)")
    print("="*140 + "\n")
    
    print(f"{'Service':<15} {'Operation':<15} {'MT4 Pool':<12} {'MT4 Spawn':<12} {'MT16 Pool':<12} {'MT16 Spawn':<12} {'ISPC':<10}")
    print("-"*140)
    
    for service in sorted(results.keys()):
        for operation in sorted(results[service].keys()):
            data = results[service][operation]
            
            mt4_pool = data.get('mt_4_pool', {}).get('speedup', 0)
            mt4_spawn = data.get('mt_4_spawn', {}).get('speedup', 0)
            mt16_pool = data.get('mt_16_pool', {}).get('speedup', 0)
            mt16_spawn = data.get('mt_16_spawn', {}).get('speedup', 0)
            ispc_speedup = data.get('ispc_', {}).get('speedup', 0)
            
            print(f"{service:<15} {operation:<15} {mt4_pool:<12.2f}x {mt4_spawn:<12.2f}x "
                  f"{mt16_pool:<12.2f}x {mt16_spawn:<12.2f}x {ispc_speedup:<10.2f}x")
    print()

def print_best_configurations(results):
    """Print best configuration for each service/operation"""
    print("\n" + "="*100)
    print("BEST CONFIGURATIONS (Highest Speedup)")
    print("="*100 + "\n")
    
    print(f"{'Service':<15} {'Operation':<15} {'Best Mode':<15} {'Speedup':<10} {'Throughput (ops/s)':<20}")
    print("-"*100)
    
    for service in sorted(results.keys()):
        for operation in sorted(results[service].keys()):
            data = results[service][operation]
            
            best_key = None
            best_speedup = 0
            
            for key, info in data.items():
                if info['speedup'] > best_speedup:
                    best_speedup = info['speedup']
                    best_key = key
            
            if best_key:
                mode = "MT" if best_key.startswith('mt') else "ISPC"
                threads = best_key.split('_')[1] if best_key.startswith('mt') else "N/A"
                config = f"{mode} ({threads} threads)" if threads != "N/A" else mode
                throughput = data[best_key]['throughput']
                
                print(f"{service:<15} {operation:<15} {config:<15} {best_speedup:<10.2f}x {throughput:<20.2f}")
    print()

def generate_latex_table(results, output_file):
    """Generate LaTeX table for paper inclusion"""
    with open(output_file, 'w') as f:
        f.write("\\begin{table}[htbp]\n")
        f.write("\\centering\n")
        f.write("\\caption{SocialGraph Benchmark Results: Speedup vs MT1 Baseline}\n")
        f.write("\\begin{tabular}{llrrrr}\n")
        f.write("\\hline\n")
        f.write("Service & Operation & MT4 & MT8 & MT16 & ISPC \\\\\n")
        f.write("\\hline\n")
        
        for service in sorted(results.keys()):
            for operation in sorted(results[service].keys()):
                data = results[service][operation]
                
                mt4 = data.get('mt_4', {}).get('speedup', 0)
                mt8 = data.get('mt_8', {}).get('speedup', 0)
                mt16 = data.get('mt_16', {}).get('speedup', 0)
                ispc = data.get('ispc_', {}).get('speedup', 0)
                
                f.write(f"{service} & {operation} & {mt4:.2f}$\\times$ & {mt8:.2f}$\\times$ & "
                       f"{mt16:.2f}$\\times$ & {ispc:.2f}$\\times$ \\\\\n")
        
        f.write("\\hline\n")
        f.write("\\end{tabular}\n")
        f.write("\\end{table}\n")
    
    print(f"LaTeX table written to: {output_file}")

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 analyze_results.py <benchmark_summary.csv>")
        sys.exit(1)
    
    csv_file = sys.argv[1]
    
    if not Path(csv_file).exists():
        print(f"Error: File {csv_file} not found")
        sys.exit(1)
    
    print(f"\nAnalyzing results from: {csv_file}\n")
    
    results = load_results(csv_file)
    
    # Print analysis
    print_comparison_table(results)
    print_speedup_summary(results)
    print_best_configurations(results)
    
    # Generate LaTeX table
    output_dir = Path(csv_file).parent
    latex_file = output_dir / "results_table.tex"
    generate_latex_table(results, latex_file)
    
    # Generate CSV summary
    summary_file = output_dir / "speedup_summary.csv"
    with open(summary_file, 'w', newline='') as f:
        writer = csv.writer(f)
        writer.writerow(['Service', 'Operation', 'MT4_Speedup', 'MT8_Speedup', 'MT16_Speedup', 'ISPC_Speedup'])
        
        for service in sorted(results.keys()):
            for operation in sorted(results[service].keys()):
                data = results[service][operation]
                writer.writerow([
                    service,
                    operation,
                    data.get('mt_4', {}).get('speedup', 0),
                    data.get('mt_8', {}).get('speedup', 0),
                    data.get('mt_16', {}).get('speedup', 0),
                    data.get('ispc_', {}).get('speedup', 0)
                ])
    
    print(f"\nSpeedup summary CSV written to: {summary_file}")
    print("\n" + "="*100)
    print("Analysis complete!")
    print("="*100 + "\n")

if __name__ == "__main__":
    main()
