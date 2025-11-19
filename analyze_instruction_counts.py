#!/usr/bin/env python3

"""
Analyze instruction counts from perf stat results
Compares ISPC vs MT implementations across all services
"""

import os
import re
import sys
import glob
import pandas as pd
import matplotlib.pyplot as plt
from pathlib import Path

def parse_perf_output(filepath):
    """Parse perf stat output file to extract performance metrics"""
    metrics = {
        'instructions': 0,
        'cycles': 0,
        'cache_references': 0,
        'cache_misses': 0,
        'ipc': 0.0,
        'time_seconds': 0.0
    }
    
    try:
        with open(filepath, 'r') as f:
            content = f.read()
            
        # Extract instructions
        match = re.search(r'([\d,]+)\s+instructions', content)
        if match:
            metrics['instructions'] = int(match.group(1).replace(',', ''))
        
        # Extract cycles
        match = re.search(r'([\d,]+)\s+cycles', content)
        if match:
            metrics['cycles'] = int(match.group(1).replace(',', ''))
        
        # Extract cache references
        match = re.search(r'([\d,]+)\s+cache-references', content)
        if match:
            metrics['cache_references'] = int(match.group(1).replace(',', ''))
        
        # Extract cache misses
        match = re.search(r'([\d,]+)\s+cache-misses', content)
        if match:
            metrics['cache_misses'] = int(match.group(1).replace(',', ''))
        
        # Extract time
        match = re.search(r'([\d.]+)\s+seconds time elapsed', content)
        if match:
            metrics['time_seconds'] = float(match.group(1))
        
        # Calculate IPC
        if metrics['cycles'] > 0:
            metrics['ipc'] = metrics['instructions'] / metrics['cycles']
            
    except Exception as e:
        print(f"Error parsing {filepath}: {e}")
    
    return metrics

def analyze_results_directory(results_dir):
    """Analyze all perf results in a directory"""
    
    # Find all perf output files
    perf_files = glob.glob(os.path.join(results_dir, '*_perf.txt'))
    
    if not perf_files:
        print(f"No perf files found in {results_dir}")
        return None
    
    data = []
    
    for perf_file in perf_files:
        # Parse filename to extract metadata
        basename = os.path.basename(perf_file)
        # Format: service_operation_mode[threads]_perf.txt
        parts = basename.replace('_perf.txt', '').split('_')
        
        if len(parts) < 3:
            continue
        
        service = parts[0]
        operation = parts[1]
        
        # Determine mode and threads
        if 'ispc' in parts[2]:
            mode = 'ispc'
            threads = None
        elif 'mt' in parts[2]:
            mode = 'mt'
            # Extract thread count (e.g., mt4 -> 4)
            thread_match = re.search(r'mt(\d+)', parts[2])
            threads = int(thread_match.group(1)) if thread_match else None
        else:
            continue
        
        # Parse metrics
        metrics = parse_perf_output(perf_file)
        
        data.append({
            'service': service,
            'operation': operation,
            'mode': mode,
            'threads': threads,
            **metrics
        })
    
    df = pd.DataFrame(data)
    return df

def generate_comparison_report(df, output_dir):
    """Generate comparison report and visualizations"""
    
    if df is None or df.empty:
        print("No data to analyze")
        return
    
    os.makedirs(output_dir, exist_ok=True)
    
    # Save raw data
    csv_path = os.path.join(output_dir, 'instruction_analysis.csv')
    df.to_csv(csv_path, index=False)
    print(f"\n✓ Saved raw data to: {csv_path}")
    
    # Generate comparison report
    report_path = os.path.join(output_dir, 'INSTRUCTION_COMPARISON.txt')
    
    with open(report_path, 'w') as f:
        f.write("╔══════════════════════════════════════════════════════════════════╗\n")
        f.write("║     Instruction Count Comparison: ISPC vs MT                     ║\n")
        f.write("╚══════════════════════════════════════════════════════════════════╝\n\n")
        
        # Group by service and operation
        for (service, operation), group in df.groupby(['service', 'operation']):
            f.write(f"\n{'='*70}\n")
            f.write(f"{service.upper()} - {operation}\n")
            f.write(f"{'='*70}\n\n")
            
            # Get ISPC baseline
            ispc_data = group[group['mode'] == 'ispc']
            if ispc_data.empty:
                f.write("  No ISPC data available\n")
                continue
            
            ispc_insts = ispc_data.iloc[0]['instructions']
            ispc_cycles = ispc_data.iloc[0]['cycles']
            ispc_ipc = ispc_data.iloc[0]['ipc']
            
            f.write(f"ISPC Baseline:\n")
            f.write(f"  Instructions: {ispc_insts:,}\n")
            f.write(f"  Cycles:       {ispc_cycles:,}\n")
            f.write(f"  IPC:          {ispc_ipc:.3f}\n")
            f.write(f"  Time:         {ispc_data.iloc[0]['time_seconds']:.6f} s\n\n")
            
            # Compare with MT versions
            mt_data = group[group['mode'] == 'mt'].sort_values('threads')
            
            if not mt_data.empty:
                f.write(f"{'Threads':<10} {'Instructions':<20} {'Ratio vs ISPC':<15} {'IPC':<10} {'Time(s)':<10}\n")
                f.write(f"{'-'*70}\n")
                
                for _, row in mt_data.iterrows():
                    ratio = row['instructions'] / ispc_insts if ispc_insts > 0 else 0
                    f.write(f"{int(row['threads']):<10} {int(row['instructions']):>19,} "
                           f"{ratio:>14.3f}x {row['ipc']:>9.3f} {row['time_seconds']:>9.6f}\n")
            
            f.write("\n")
        
        # Summary statistics
        f.write(f"\n{'='*70}\n")
        f.write(f"SUMMARY STATISTICS\n")
        f.write(f"{'='*70}\n\n")
        
        # Calculate average ratios
        ratios = []
        for (service, operation), group in df.groupby(['service', 'operation']):
            ispc_data = group[group['mode'] == 'ispc']
            if ispc_data.empty:
                continue
            
            ispc_insts = ispc_data.iloc[0]['instructions']
            mt_data = group[group['mode'] == 'mt']
            
            for _, row in mt_data.iterrows():
                if ispc_insts > 0:
                    ratio = row['instructions'] / ispc_insts
                    ratios.append({
                        'service': service,
                        'operation': operation,
                        'threads': int(row['threads']),
                        'ratio': ratio
                    })
        
        if ratios:
            ratios_df = pd.DataFrame(ratios)
            
            f.write("Average Instruction Ratio (MT/ISPC) by Thread Count:\n\n")
            for threads in sorted(ratios_df['threads'].unique()):
                thread_ratios = ratios_df[ratios_df['threads'] == threads]['ratio']
                avg_ratio = thread_ratios.mean()
                f.write(f"  {threads} threads: {avg_ratio:.3f}x (MT uses {(avg_ratio-1)*100:.1f}% more instructions)\n")
    
    print(f"✓ Saved comparison report to: {report_path}")
    
    # Generate visualizations
    generate_plots(df, output_dir)

def generate_plots(df, output_dir):
    """Generate comparison plots"""
    
    if df is None or df.empty:
        return
    
    # Plot 1: Instruction count comparison
    fig, axes = plt.subplots(2, 3, figsize=(18, 12))
    fig.suptitle('Instruction Count Comparison: ISPC vs MT', fontsize=16, fontweight='bold')
    
    services_ops = df.groupby(['service', 'operation']).size().index.tolist()[:6]
    
    for idx, (service, operation) in enumerate(services_ops):
        row = idx // 3
        col = idx % 3
        ax = axes[row, col]
        
        group = df[(df['service'] == service) & (df['operation'] == operation)]
        
        # Get ISPC baseline
        ispc_data = group[group['mode'] == 'ispc']
        mt_data = group[group['mode'] == 'mt'].sort_values('threads')
        
        if not ispc_data.empty and not mt_data.empty:
            ispc_insts = ispc_data.iloc[0]['instructions']
            
            # Plot
            threads = mt_data['threads'].tolist()
            instructions = mt_data['instructions'].tolist()
            
            ax.axhline(y=ispc_insts, color='green', linestyle='--', linewidth=2, label='ISPC')
            ax.plot(threads, instructions, 'bo-', linewidth=2, markersize=8, label='MT')
            
            ax.set_xlabel('Thread Count', fontsize=10)
            ax.set_ylabel('Instructions', fontsize=10)
            ax.set_title(f'{service} - {operation}', fontsize=11, fontweight='bold')
            ax.legend()
            ax.grid(True, alpha=0.3)
            ax.ticklabel_format(style='scientific', axis='y', scilimits=(0,0))
    
    plt.tight_layout()
    plot_path = os.path.join(output_dir, 'instruction_comparison.png')
    plt.savefig(plot_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"✓ Saved instruction comparison plot to: {plot_path}")
    
    # Plot 2: IPC comparison
    fig, ax = plt.subplots(figsize=(14, 8))
    
    # Prepare data for grouped bar chart
    services_ops = df.groupby(['service', 'operation']).size().index.tolist()
    
    x = range(len(services_ops))
    width = 0.15
    
    for i, mode_threads in enumerate(['ispc', 'mt1', 'mt4', 'mt8', 'mt16']):
        ipcs = []
        for service, operation in services_ops:
            group = df[(df['service'] == service) & (df['operation'] == operation)]
            
            if mode_threads == 'ispc':
                data = group[group['mode'] == 'ispc']
            else:
                threads = int(mode_threads[2:])
                data = group[(group['mode'] == 'mt') & (group['threads'] == threads)]
            
            if not data.empty:
                ipcs.append(data.iloc[0]['ipc'])
            else:
                ipcs.append(0)
        
        offset = (i - 2) * width
        ax.bar([p + offset for p in x], ipcs, width, label=mode_threads.upper())
    
    ax.set_xlabel('Service - Operation', fontsize=12)
    ax.set_ylabel('Instructions Per Cycle (IPC)', fontsize=12)
    ax.set_title('IPC Comparison Across Services', fontsize=14, fontweight='bold')
    ax.set_xticks(x)
    ax.set_xticklabels([f"{s}-{o}" for s, o in services_ops], rotation=45, ha='right')
    ax.legend()
    ax.grid(True, alpha=0.3, axis='y')
    
    plt.tight_layout()
    ipc_plot_path = os.path.join(output_dir, 'ipc_comparison.png')
    plt.savefig(ipc_plot_path, dpi=150, bbox_inches='tight')
    plt.close()
    print(f"✓ Saved IPC comparison plot to: {ipc_plot_path}")

def main():
    if len(sys.argv) < 2:
        print("Usage: python3 analyze_instruction_counts.py <results_directory>")
        print("\nExample:")
        print("  python3 analyze_instruction_counts.py instruction_comparison_20251117_220000")
        sys.exit(1)
    
    results_dir = sys.argv[1]
    
    if not os.path.isdir(results_dir):
        print(f"Error: Directory '{results_dir}' not found")
        sys.exit(1)
    
    print(f"\n{'='*70}")
    print(f"Analyzing Instruction Counts from: {results_dir}")
    print(f"{'='*70}\n")
    
    # Parse all perf results
    df = analyze_results_directory(results_dir)
    
    if df is None or df.empty:
        print("No data found to analyze")
        sys.exit(1)
    
    print(f"Found {len(df)} benchmark results")
    print(f"Services: {df['service'].unique().tolist()}")
    print(f"Operations: {df['operation'].unique().tolist()}")
    
    # Generate report
    output_dir = os.path.join(results_dir, 'analysis')
    generate_comparison_report(df, output_dir)
    
    print(f"\n{'='*70}")
    print(f"Analysis complete! Results saved to: {output_dir}")
    print(f"{'='*70}\n")

if __name__ == '__main__':
    main()
