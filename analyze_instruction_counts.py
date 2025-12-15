#!/usr/bin/env python3

"""
Analyze instruction counts from perf stat results
Compares ISPC vs Scalar (MT1) implementations across all services
"""

import os
import re
import sys
import glob
import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
from pathlib import Path

# IEEE Conference Paper Compliance Settings
# Set matplotlib parameters for PDF generation
plt.rcParams['pdf.fonttype'] = 42  # Embed fonts as True Type (required for IEEE)
plt.rcParams['ps.fonttype'] = 42
plt.rcParams['font.family'] = 'sans-serif'
plt.rcParams['font.sans-serif'] = ['Times New Roman', 'DejaVu Sans']
IEEE_DPI = 300  # IEEE requires minimum 300 DPI for publication quality
IEEE_FMT = 'pdf'  # Vector format for quality

def get_display_name(app_name):
    """Map internal app names to display names for figures."""
    display_names = {
        'userTag': 'UserMentionService',
        'user': 'UserService',
        'uniqueID': 'UniqueIdService',
        'text': 'TextService',
        'shortURL': 'UrlShortenService',
        'post': 'PostStorageService'
    }
    return display_names.get(app_name, app_name)

def get_config_color_map():
    """
    Return a consistent color mapping for all configurations.
    This ensures ISPC, MT configurations, etc. always have the same color across all figures.
    """
    return {
        'ispc': '#1f77b4',  # Blue
        'mt1_spawn': '#ff7f0e',  # Orange (baseline)
        'mt1_pool': '#2ca02c',  # Green
        'mt2_spawn': '#d62728',  # Red
        'mt2_pool': '#9467bd',  # Purple
        'mt4_spawn': '#8c564b',  # Brown
        'mt4_pool': '#e377c2',  # Pink
        'mt8_spawn': '#7f7f7f',  # Gray
        'mt8_pool': '#bcbd22',  # Yellow-green
        'mt16_spawn': '#17becf',  # Cyan
        'mt16_pool': '#ff9896',  # Light red
    }

def get_config_color(config, color_map=None):
    """
    Get the color for a specific configuration.
    Uses the global color map for known configs.
    """
    if color_map is None:
        color_map = get_config_color_map()
    
    if config in color_map:
        return color_map[config]
    else:
        # Default fallback
        return '#333333'

def parse_insmix_output(filepath):
    """Parse insmix output file to extract instruction counts with scalar/SIMD breakdown"""
    metrics = {
        'total_instructions': 0,
        'scalar_instructions': 0,
        'simd_instructions': 0,
        'scalar_percent': 0.0,
        'simd_percent': 0.0,
        'time_seconds': 0.0
    }
    
    try:
        with open(filepath, 'r') as f:
            content = f.read()
        
        # Extract total instructions (note: multiple spaces in the format)
        # Use findall and get the LAST match, which is the overall summary
        matches = re.findall(r'3000\s+\*total\s+(\d+)', content)
        if matches:
            metrics['total_instructions'] = int(matches[-1])
        
        # Extract scalar instructions (last match is the summary)
        matches = re.findall(r'3001\s+\*scalar\s+(\d+)', content)
        if matches:
            metrics['scalar_instructions'] = int(matches[-1])
        
        # Extract SIMD instructions (last match is the summary)
        matches = re.findall(r'3002\s+\*simd\s+(\d+)', content)
        if matches:
            metrics['simd_instructions'] = int(matches[-1])
        
        # Calculate percentages
        if metrics['total_instructions'] > 0:
            metrics['scalar_percent'] = (metrics['scalar_instructions'] / metrics['total_instructions']) * 100
            metrics['simd_percent'] = (metrics['simd_instructions'] / metrics['total_instructions']) * 100
            
    except Exception as e:
        print(f"Error parsing {filepath}: {e}")
    
    return metrics

def analyze_results_directory(results_dir):
    """Analyze all insmix results in a directory"""
    
    # Find all insmix output files
    insmix_files = glob.glob(os.path.join(results_dir, '*_insmix.out'))
    
    if not insmix_files:
        print(f"No insmix files found in {results_dir}")
        return None
    
    data = []
    
    for insmix_file in insmix_files:
        # Parse filename to extract metadata
        basename = os.path.basename(insmix_file)
        # Format: service_operation_mode[threads]_insmix.out
        parts = basename.replace('_insmix.out', '').split('_')
        
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
        metrics = parse_insmix_output(insmix_file)
        
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
        f.write("║     Instruction Count Comparison: ISPC vs Scalar                 ║\n")
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
            
            ispc_total = ispc_data.iloc[0]['total_instructions']
            ispc_scalar = ispc_data.iloc[0]['scalar_instructions']
            ispc_simd = ispc_data.iloc[0]['simd_instructions']
            ispc_simd_pct = ispc_data.iloc[0]['simd_percent']
            
            f.write(f"ISPC Baseline:\n")
            f.write(f"  Total Instructions: {ispc_total:,}\n")
            f.write(f"  Scalar:             {ispc_scalar:,} ({100-ispc_simd_pct:.1f}%)\n")
            f.write(f"  SIMD:               {ispc_simd:,} ({ispc_simd_pct:.1f}%)\n\n")
            
            # Compare with Scalar (MT1) version
            scalar_data = group[(group['mode'] == 'mt') & (group['threads'] == 1)]
            
            if not scalar_data.empty:
                f.write(f"Scalar (MT1):\n")
                row = scalar_data.iloc[0]
                ratio = row['total_instructions'] / ispc_total if ispc_total > 0 else 0
                f.write(f"  Total Instructions: {int(row['total_instructions']):,}\n")
                f.write(f"  Scalar:             {int(row['scalar_instructions']):,} ({row['scalar_percent']:.1f}%)\n")
                f.write(f"  SIMD:               {int(row['simd_instructions']):,} ({row['simd_percent']:.1f}%)\n")
                f.write(f"  Ratio:              {ratio:.3f}x vs ISPC\n")
            
            f.write("\n")
        
        # Summary statistics
        f.write(f"\n{'='*70}\n")
        f.write(f"SUMMARY STATISTICS\n")
        f.write(f"{'='*70}\n\n")
        
        # Calculate average ratios for scalar vs ISPC
        ratios = []
        for (service, operation), group in df.groupby(['service', 'operation']):
            ispc_data = group[group['mode'] == 'ispc']
            if ispc_data.empty:
                continue
            
            ispc_insts = ispc_data.iloc[0]['total_instructions']
            ispc_simd_pct = ispc_data.iloc[0]['simd_percent']
            scalar_data = group[(group['mode'] == 'mt') & (group['threads'] == 1)]
            
            if not scalar_data.empty:
                row = scalar_data.iloc[0]
                if ispc_insts > 0:
                    ratio = row['total_instructions'] / ispc_insts
                    ratios.append({
                        'service': service,
                        'operation': operation,
                        'ratio': ratio,
                        'ispc_simd_pct': ispc_simd_pct,
                        'mt_simd_pct': row['simd_percent']
                    })
        
        if ratios:
            ratios_df = pd.DataFrame(ratios)
            avg_ratio = ratios_df['ratio'].mean()
            avg_ispc_simd = ratios_df['ispc_simd_pct'].mean()
            avg_mt_simd = ratios_df['mt_simd_pct'].mean()
            
            f.write("Average Instruction Ratio (Scalar/ISPC):\n\n")
            f.write(f"  Overall: {avg_ratio:.3f}x (Scalar uses {(avg_ratio-1)*100:.1f}% more instructions)\n")
            f.write(f"  Avg ISPC SIMD%: {avg_ispc_simd:.1f}%\n")
            f.write(f"  Avg MT1 SIMD%:  {avg_mt_simd:.1f}%\n")
            f.write(f"\nPer-benchmark ratios:\n")
            for _, row in ratios_df.iterrows():
                f.write(f"  {row['service']}-{row['operation']}: {row['ratio']:.3f}x (ISPC SIMD: {row['ispc_simd_pct']:.1f}%, MT1 SIMD: {row['mt_simd_pct']:.1f}%)\n")
    
    print(f"✓ Saved comparison report to: {report_path}")
    
    # Generate visualizations
    generate_plots(df, output_dir)

def generate_plots(df, output_dir):
    """Generate comparison plots with stacked bars showing scalar/SIMD breakdown"""
    
    if df is None or df.empty:
        return
    
    # Plot 1: Instruction count comparison with stacked bars (scalar + SIMD)
    fig, ax = plt.subplots(figsize=(max(16, len(df.groupby(['service', 'operation']).size()) * 1.5), 5.5))
    
    # Prepare data for grouped stacked bar chart
    services_ops = df.groupby(['service', 'operation']).size().index.tolist()
    
    # Adjust spacing for better label visibility
    spacing_factor = 1.8
    x = np.arange(len(services_ops)) * spacing_factor
    width = 0.40
    
    # Data arrays for stacked bars
    # Normalize to MT-1 baseline (MT-1 total = 1.0 for each benchmark)
    # Bar height = total instructions normalized to MT-1
    # Each bar divided by scalar/SIMD percentages
    mt1_scalar_vals = []
    mt1_simd_vals = []
    ispc_scalar_vals = []
    ispc_simd_vals = []
    
    for service, operation in services_ops:
        group = df[(df['service'] == service) & (df['operation'] == operation)]
        
        ispc_data = group[group['mode'] == 'ispc']
        mt1_data = group[(group['mode'] == 'mt') & (group['threads'] == 1)]
        
        if not ispc_data.empty and not mt1_data.empty:
            # MT1 baseline - normalize to 1.0, divide by percentages
            mt1_total = mt1_data.iloc[0]['total_instructions']
            mt1_scalar_pct = mt1_data.iloc[0]['scalar_percent']
            mt1_simd_pct = mt1_data.iloc[0]['simd_percent']
            
            # MT-1 bar always sums to 1.0
            mt1_scalar_vals.append(mt1_scalar_pct / 100)
            mt1_simd_vals.append(mt1_simd_pct / 100)
            
            # ISPC data - normalize to MT-1 total, divide by percentages
            ispc_total = ispc_data.iloc[0]['total_instructions']
            ispc_scalar_pct = ispc_data.iloc[0]['scalar_percent']
            ispc_simd_pct = ispc_data.iloc[0]['simd_percent']
            
            # ISPC bar height = ratio to MT-1, divided by percentages
            ispc_ratio = ispc_total / mt1_total if mt1_total > 0 else 0
            ispc_scalar_vals.append(ispc_ratio * (ispc_scalar_pct / 100))
            ispc_simd_vals.append(ispc_ratio * (ispc_simd_pct / 100))
        else:
            mt1_scalar_vals.append(0)
            mt1_simd_vals.append(0)
            ispc_scalar_vals.append(0)
            ispc_simd_vals.append(0)
    
    # Get consistent color map
    color_map = get_config_color_map()
    mt1_color = get_config_color('mt1_spawn', color_map)
    ispc_color = get_config_color('ispc', color_map)
    
    # Define colors for scalar and SIMD portions within each bar
    # Using shades: darker for scalar, lighter for SIMD
    scalar_color = '#5DA5DA'  # Blue
    simd_color = '#FAA43A'     # Orange
    
    # Create stacked bars with borders
    # MT1 bars (left) - bar height = total scaled, divided by percentage into scalar/SIMD
    p1 = ax.bar(x - width/2, mt1_scalar_vals, width, label='MT-1 Scalar', color=scalar_color, alpha=0.9,
                edgecolor='black', linewidth=0.8)
    p2 = ax.bar(x - width/2, mt1_simd_vals, width, bottom=mt1_scalar_vals, label='MT-1 SIMD', color=simd_color, alpha=0.9,
                edgecolor='black', linewidth=0.8)
    
    # ISPC bars (right) - bar height = ratio to MT-1, divided by percentage into scalar/SIMD
    p3 = ax.bar(x + width/2, ispc_scalar_vals, width, label='ISPC Scalar', color=scalar_color, alpha=0.6, hatch='//',
                edgecolor='black', linewidth=0.8)
    p4 = ax.bar(x + width/2, ispc_simd_vals, width, bottom=ispc_scalar_vals, label='ISPC SIMD', color=simd_color, alpha=0.6, hatch='//',
                edgecolor='black', linewidth=0.8)
    
    # Add horizontal line at y=1.0 for MT-1 baseline reference
    ax.axhline(y=1.0, color='red', linestyle='--', linewidth=2, alpha=0.7, label='MT-1 Baseline')
    
    ax.set_xlabel('Application / Operation', fontsize=16, fontweight='bold')
    ax.set_ylabel('Normalized Instruction Count', fontsize=16, fontweight='bold')
    ax.set_xticks(x)
    ax.set_xticklabels([f"{get_display_name(s)}\n{o}" for s, o in services_ops], rotation=0, ha='center', fontsize=13, fontweight='bold')
    legend = ax.legend(loc='upper left', fontsize=13, ncol=2)
    
    # Make tick labels bold
    for label in ax.get_yticklabels():
        label.set_fontweight('bold')
        label.set_fontsize(13)
    
    # Make legend text bold
    for text in legend.get_texts():
        text.set_fontweight('bold')
    
    ax.grid(True, alpha=0.3, linestyle='--', axis='y')
    ax.set_ylim(bottom=0)
    
    plt.tight_layout()
    plot_path = os.path.join(output_dir, 'instruction_comparison_stacked.pdf')
    plt.savefig(plot_path, format=IEEE_FMT, dpi=IEEE_DPI, bbox_inches='tight')
    plt.close()
    print(f"✓ Saved IEEE-compliant stacked instruction comparison plot (300 DPI) to: {plot_path}")
    
    # Plot 2: Scaled instruction count comparison (without stacking)
    fig, ax = plt.subplots(figsize=(max(16, len(services_ops) * 1.5), 5.5))
    
    # Prepare data for total instruction comparison (normalized to MT-1)
    mt1_totals = []
    ispc_totals = []
    
    for service, operation in services_ops:
        group = df[(df['service'] == service) & (df['operation'] == operation)]
        
        ispc_data = group[group['mode'] == 'ispc']
        mt1_data = group[(group['mode'] == 'mt') & (group['threads'] == 1)]
        
        if not ispc_data.empty and not mt1_data.empty:
            mt1_total = mt1_data.iloc[0]['total_instructions']
            ispc_total = ispc_data.iloc[0]['total_instructions']
            
            # MT-1 normalized to 1.0
            mt1_totals.append(1.0)
            # ISPC relative to MT-1
            ispc_totals.append(ispc_total / mt1_total if mt1_total > 0 else 0)
        else:
            mt1_totals.append(0)
            ispc_totals.append(0)
    
    # Get consistent colors from color map
    color_map = get_config_color_map()
    mt1_color = get_config_color('mt1_spawn', color_map)
    ispc_color = get_config_color('ispc', color_map)
    
    # Create grouped bar chart with borders
    p1 = ax.bar(x - width/2, mt1_totals, width, label='MT-1 (spawn)', color=mt1_color, alpha=0.8,
                edgecolor='black', linewidth=0.8)
    p2 = ax.bar(x + width/2, ispc_totals, width, label='ISPC', color=ispc_color, alpha=0.8,
                edgecolor='black', linewidth=0.8)
    
    # Add horizontal line at y=1.0 for MT-1 baseline reference
    ax.axhline(y=1.0, color='red', linestyle='--', linewidth=2, alpha=0.7, label='MT-1 Baseline')
    
    ax.set_xlabel('Application / Operation', fontsize=16, fontweight='bold')
    ax.set_ylabel('Total Instructions (Normalized to MT-1 = 1.0)', fontsize=16, fontweight='bold')
    ax.set_xticks(x)
    ax.set_xticklabels([f"{get_display_name(s)}\n{o}" for s, o in services_ops], rotation=0, ha='center', fontsize=13, fontweight='bold')
    legend = ax.legend(fontsize=13, loc='upper left')
    
    # Make tick labels bold
    for label in ax.get_yticklabels():
        label.set_fontweight('bold')
        label.set_fontsize(13)
    
    # Make legend text bold
    for text in legend.get_texts():
        text.set_fontweight('bold')
    
    ax.grid(True, alpha=0.3, linestyle='--', axis='y')
    ax.set_ylim(bottom=0)
    
    plt.tight_layout()
    total_plot_path = os.path.join(output_dir, 'instruction_comparison_total.pdf')
    plt.savefig(total_plot_path, format=IEEE_FMT, dpi=IEEE_DPI, bbox_inches='tight')
    plt.close()
    print(f"✓ Saved IEEE-compliant total instruction comparison plot (300 DPI) to: {total_plot_path}")
    
    # Plot 3: SIMD percentage comparison
    fig, ax = plt.subplots(figsize=(max(16, len(services_ops) * 1.5), 5.5))
    
    # Prepare data for SIMD percentage comparison
    mt1_simd_pcts = []
    ispc_simd_pcts = []
    
    for service, operation in services_ops:
        group = df[(df['service'] == service) & (df['operation'] == operation)]
        
        ispc_data = group[group['mode'] == 'ispc']
        mt1_data = group[(group['mode'] == 'mt') & (group['threads'] == 1)]
        
        if not ispc_data.empty and not mt1_data.empty:
            mt1_simd_pcts.append(mt1_data.iloc[0]['simd_percent'])
            ispc_simd_pcts.append(ispc_data.iloc[0]['simd_percent'])
        else:
            mt1_simd_pcts.append(0)
            ispc_simd_pcts.append(0)
    
    # Get consistent colors from color map
    color_map = get_config_color_map()
    mt1_color = get_config_color('mt1_spawn', color_map)
    ispc_color = get_config_color('ispc', color_map)
    
    # Create grouped bar chart with borders
    p1 = ax.bar(x - width/2, mt1_simd_pcts, width, label='MT-1 (spawn)', color=mt1_color, alpha=0.8,
                edgecolor='black', linewidth=0.8)
    p2 = ax.bar(x + width/2, ispc_simd_pcts, width, label='ISPC SIMD', color=ispc_color, alpha=0.8,
                edgecolor='black', linewidth=0.8)
    
    ax.set_xlabel('Application / Operation', fontsize=16, fontweight='bold')
    ax.set_ylabel('SIMD Instructions (%)', fontsize=16, fontweight='bold')
    ax.set_xticks(x)
    ax.set_xticklabels([f"{get_display_name(s)}\n{o}" for s, o in services_ops], rotation=0, ha='center', fontsize=13, fontweight='bold')
    legend = ax.legend(fontsize=13, loc='upper left')
    
    # Make tick labels bold
    for label in ax.get_yticklabels():
        label.set_fontweight('bold')
        label.set_fontsize(13)
    
    # Make legend text bold
    for text in legend.get_texts():
        text.set_fontweight('bold')
    
    ax.grid(True, alpha=0.3, linestyle='--', axis='y')
    ax.set_ylim(bottom=0, top=100)
    
    plt.tight_layout()
    simd_pct_plot_path = os.path.join(output_dir, 'simd_percentage_comparison.pdf')
    plt.savefig(simd_pct_plot_path, format=IEEE_FMT, dpi=IEEE_DPI, bbox_inches='tight')
    plt.close()
    print(f"✓ Saved IEEE-compliant SIMD percentage comparison plot (300 DPI) to: {simd_pct_plot_path}")

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
