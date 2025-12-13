#!/usr/bin/env python3
"""
Generate CDF (Cumulative Distribution Function) plots for timing statistics.
Compares different configurations (ISPC, MT with different thread counts) for the same batch size N.
Works across all applications in the socialGraph directory.

Usage:
    python3 plot_timing_cdf.py                                    # Search in current directory subdirs
    python3 plot_timing_cdf.py benchmark_results_20251118_164500  # Search in specific results dir
    python3 plot_timing_cdf.py /path/to/results                   # Search in absolute path
"""

import pandas as pd
import numpy as np
import matplotlib.pyplot as plt
import plotly.graph_objects as go
import plotly.express as px
from plotly.subplots import make_subplots
import glob
import os
import re
import sys
from pathlib import Path

# IEEE Conference Paper Compliance Settings
# Set matplotlib backend and parameters for PDF generation
plt.rcParams['pdf.fonttype'] = 42  # Embed fonts as True Type (required for IEEE)
plt.rcParams['ps.fonttype'] = 42
plt.rcParams['font.family'] = 'sans-serif'
plt.rcParams['font.sans-serif'] = ['Times New Roman', 'DejaVu Sans']
IEEE_DPI = 300  # IEEE requires minimum 300 DPI for publication quality
IEEE_FMT = 'pdf'  # Vector format for quality

# Configuration: Baseline configuration for normalization/comparison
# Change this to use a different baseline (e.g., 'ispc', 'mt2_spawn', etc.)
BASELINE_CONFIG = 'mt1_spawn'

# Consistent color scheme across all figures
# Maps configuration names to specific colors
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

def get_config_color(config, color_map=None, fallback_idx=0):
    """
    Get the color for a specific configuration.
    Uses the global color map for known configs, or generates a color for unknown ones.
    
    Args:
        config: Configuration name (e.g., 'ispc', 'mt8_pool')
        color_map: Optional pre-computed color map
        fallback_idx: Index to use for fallback color generation
    
    Returns:
        Color string (hex format)
    """
    if color_map is None:
        color_map = get_config_color_map()
    
    if config in color_map:
        return color_map[config]
    else:
        # Generate a fallback color for unknown configs
        fallback_colors = plt.cm.Set3(np.linspace(0, 1, 12))
        rgba = fallback_colors[fallback_idx % len(fallback_colors)]
        # Convert RGBA array to hex string
        return '#{:02x}{:02x}{:02x}'.format(int(rgba[0]*255), int(rgba[1]*255), int(rgba[2]*255))

def parse_energy_file(filepath):
    """Parse energy summary CSV file and extract configuration info and app name."""
    # Extract configuration from filename
    filename = os.path.basename(filepath)
    
    # Pattern for benchmark results files: <app>_<operation>_<config>_energy_summary.csv
    # E.g., post_create_mt4_pool_energy_summary.csv, uniqueID_compose_ispc_energy_summary.csv
    # Try ISPC pattern first (no mode): <app>_<operation>_ispc_energy_summary.csv
    match = re.search(r'(\w+)_(\w+)_ispc_energy_summary\.csv', filename)
    if match:
        app_name = match.group(1)       # e.g., "post", "user", "uniqueID"
        operation = match.group(2)      # e.g., "create", "lookup", "compose"
        config = 'ispc'
        
        # Read CSV, skipping comment lines
        df = pd.read_csv(filepath, comment='#')
        
        return app_name, operation, config, df
    
    # Try MT pattern with mode: <app>_<operation>_<mtN>_<mode>_energy_summary.csv
    match = re.search(r'(\w+)_(\w+)_(mt\d+)_(pool|spawn)_energy_summary\.csv', filename)
    if match:
        app_name = match.group(1)       # e.g., "post", "user", "uniqueID"
        operation = match.group(2)      # e.g., "create", "lookup", "compose"
        config = match.group(3)         # e.g., "mt4", "mt8"
        mode = match.group(4)           # e.g., "pool", "spawn"
        
        # Combine config and mode for MT configurations
        config = f"{config}_{mode}"
        
        # Read CSV, skipping comment lines
        df = pd.read_csv(filepath, comment='#')
        
        return app_name, operation, config, df
    
    return None, None, None, None

def parse_timing_file(filepath):
    """Parse timing stats CSV file and extract configuration info and app name."""
    # Extract configuration from filename
    filename = os.path.basename(filepath)
    
    # Pattern for benchmark results files: <app>_<operation>_<config>_timing.csv
    # E.g., post_create_mt4_pool_timing.csv, uniqueID_compose_ispc_timing.csv
    # Try ISPC pattern first (no mode): <app>_<operation>_ispc_timing.csv
    match = re.search(r'(\w+)_(\w+)_ispc_timing\.csv', filename)
    if match:
        app_name = match.group(1)       # e.g., "post", "user", "uniqueID"
        operation = match.group(2)      # e.g., "create", "lookup", "compose"
        config = 'ispc'
        
        # Read CSV, skipping comment lines
        df = pd.read_csv(filepath, comment='#')
        
        # Try to infer batch size from number of rows
        batch_size = len(df)
        
        return app_name, operation, config, batch_size, df
    
    # Try MT pattern with mode: <app>_<operation>_<mtN>_<mode>_timing.csv
    match = re.search(r'(\w+)_(\w+)_(mt\d+)_(pool|spawn)_timing\.csv', filename)
    if match:
        app_name = match.group(1)       # e.g., "post", "user", "uniqueID"
        operation = match.group(2)      # e.g., "create", "lookup", "compose"
        config = match.group(3)         # e.g., "mt4", "mt8"
        mode = match.group(4)           # e.g., "pool", "spawn"
        
        # Combine config and mode for MT configurations
        config = f"{config}_{mode}"
        
        # Read CSV, skipping comment lines
        df = pd.read_csv(filepath, comment='#')
        
        # Try to infer batch size from number of rows
        batch_size = len(df)
        
        return app_name, operation, config, batch_size, df
    
    
    # Try different filename patterns for direct timing_stats files
    # Pattern 1: timing_stats_<operation>_<config>_<mode>_N<batch>.csv (e.g., compose_mt8_pool_N2000)
    match = re.search(r'timing_stats_(\w+)_(ispc|mt\d+)(?:_(\w+))?_N(\d+)(?:_fail\d+)?\.csv', filename)
    if match:
        operation = match.group(1)  # Operation (e.g., "compose", "create", "login")
        config = match.group(2)     # Config (e.g., "mt8", "ispc")
        mode = match.group(3)       # Mode (e.g., "pool", "spawn") - optional
        batch_size = int(match.group(4))
        
        # Combine config and mode for MT configurations
        if config.startswith('mt') and mode:
            config = f"{config}_{mode}"
        
        # Extract app name from directory path
        app_name = os.path.basename(os.path.dirname(filepath))
        
        # Read CSV, skipping comment lines
        df = pd.read_csv(filepath, comment='#')
        
        return app_name, operation, config, batch_size, df
    
    # Pattern 1b: timing_stats_<app>_<config>_<mode>_<operation>_N<batch>.csv (e.g., user_mt8_pool_create_N2000)
    match = re.search(r'timing_stats_(\w+)_(ispc|mt\d+)(?:_(\w+))?_(\w+)_N(\d+)(?:_fail\d+)?\.csv', filename)
    if match:
        app_name = match.group(1)   # App name (e.g., "user")
        config = match.group(2)     # Config (e.g., "mt8", "ispc")
        mode = match.group(3)       # Mode (e.g., "pool", "spawn") - optional
        operation = match.group(4)  # Operation (e.g., "create", "login")
        batch_size = int(match.group(5))
        
        # Combine config and mode for MT configurations
        if config.startswith('mt') and mode:
            config = f"{config}_{mode}"
        
        # Read CSV, skipping comment lines
        df = pd.read_csv(filepath, comment='#')
        
        return app_name, operation, config, batch_size, df
    
    # Pattern 2a: timing_stats_<mtN>_<mode>_N<batch>.csv (e.g., mt8_pool_N2000)
    match = re.search(r'timing_stats_(mt\d+)_(pool|spawn)_N(\d+)\.csv', filename)
    if match:
        config = match.group(1)     # e.g., "mt8"
        mode = match.group(2)       # e.g., "pool", "spawn"
        batch_size = int(match.group(3))
        
        # Combine config and mode
        config = f"{config}_{mode}"
        
        # Extract app name from directory path
        app_name = os.path.basename(os.path.dirname(filepath))
        operation = "compose"  # Default operation for services without explicit operation
        
        # Read CSV, skipping comment lines
        df = pd.read_csv(filepath, comment='#')
        
        return app_name, operation, config, batch_size, df
    
    # Pattern 2b: timing_stats_ispc_N<batch>.csv (e.g., ispc_N2000)
    match = re.search(r'timing_stats_ispc_N(\d+)\.csv', filename)
    if match:
        config = 'ispc'
        batch_size = int(match.group(1))
        
        # Extract app name from directory path
        app_name = os.path.basename(os.path.dirname(filepath))
        operation = "compose"  # Default operation for services without explicit operation
        
        # Read CSV, skipping comment lines
        df = pd.read_csv(filepath, comment='#')
        
        return app_name, operation, config, batch_size, df
    
    # Pattern 2c: timing_stats_<config>_N<batch>.csv (old format, e.g., mt8_N1000 without mode)
    match = re.search(r'timing_stats_(\w+)_N(\d+)\.csv', filename)
    if match:
        config = match.group(1)
        batch_size = int(match.group(2))
        
        # Extract app name from directory path
        app_name = os.path.basename(os.path.dirname(filepath))
        operation = "default"  # No operation specified in old format
        
        # Read CSV, skipping comment lines
        df = pd.read_csv(filepath, comment='#')
        
        return app_name, operation, config, batch_size, df
    
    # Pattern 3: timing_stats_<testtype>_<config>_<mode>.csv (userTag format)
    match = re.search(r'timing_stats_(\w+)_(\w+)_(\w+)\.csv', filename)
    if match:
        test_type = match.group(1)
        config = match.group(2)
        mode = match.group(3)
        
        # Combine config and mode for MT configurations
        if config.startswith('mt'):
            config = f"{config}_{mode}"
        
        # Extract app name from directory path
        app_name = os.path.basename(os.path.dirname(filepath))
        operation = test_type  # Use test_type as operation
        
        # Read CSV, skipping comment lines
        df = pd.read_csv(filepath, comment='#')
        
        # Use a dummy batch size since userTag doesn't specify it
        batch_size = len(df)
        
        return app_name, operation, config, batch_size, df
    
    return None, None, None, None, None

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

def calculate_cdf(data):
    """Calculate CDF for given data."""
    sorted_data = np.sort(data)
    cdf = np.arange(1, len(sorted_data) + 1) / len(sorted_data)
    return sorted_data, cdf

def plot_cdf_for_batch_size_interactive(app_name, operation, batch_size, data_dict, metric='ExecutionTime', output_dir='.'):
    """
    Generate interactive HTML CDF plot for a specific batch size across different configurations.
    
    Args:
        app_name: The application name
        operation: The operation/test type (e.g., "create", "compose", "login")
        batch_size: The batch size (N) to plot
        data_dict: Dictionary mapping config name to DataFrame
        metric: Which metric to plot ('QueueingDelay', 'ExecutionTime', 'TotalLatency')
        output_dir: Directory to save the plot
    """
    # Sort configurations for consistent ordering
    def sort_key(x):
        if x == 'ispc':
            return (0, 0, '')
        elif x.startswith('mt'):
            # Extract thread count and mode (e.g., "mt8_pool" -> 8, "pool")
            parts = x.replace('mt', '').split('_')
            threads = int(parts[0]) if parts[0] else 0
            mode = parts[1] if len(parts) > 1 else ''
            return (1, threads, mode)
        else:
            return (2, 0, x)
    
    configs = sorted(data_dict.keys(), key=sort_key)
    
    # Get consistent color map
    color_map = get_config_color_map()
    
    # Create plotly figure
    fig = go.Figure()
    
    for config in configs:
        df = data_dict[config]
        
        # Get the metric data
        if metric not in df.columns:
            print(f"Warning: Metric '{metric}' not found in {config} data")
            continue
        
        data = df[metric].values
        sorted_data, cdf = calculate_cdf(data)
        
        # Create label
        if config == 'ispc':
            label = 'ISPC SIMD'
        elif config.startswith('mt'):
            # Parse thread count and mode (e.g., "mt8_pool" -> "MT-8 (pool)")
            parts = config.replace('mt', '').split('_')
            threads = parts[0] if parts[0] else '?'
            mode = parts[1] if len(parts) > 1 else ''
            label = f'MT-{threads} ({mode})' if mode else f'MT-{threads}'
        else:
            label = config
        
        # Add trace with consistent color
        fig.add_trace(go.Scatter(
            x=sorted_data,
            y=cdf,
            mode='lines',
            name=label,
            line=dict(width=2.5, color=get_config_color(config, color_map)),
            hovertemplate=f'<b>{label}</b><br>{metric}: %{{x:.0f}} cycles<br>CDF: %{{y:.2%}}<extra></extra>'
        ))
    
    # Add percentile lines
    for percentile in [0.5, 0.9, 0.95, 0.99]:
        fig.add_hline(
            y=percentile,
            line_dash="dot",
            line_color="gray",
            opacity=0.5,
            annotation_text=f'{int(percentile*100)}%',
            annotation_position="left"
        )
    
    # Update layout
    fig.update_layout(
        title=f'{get_display_name(app_name)} ({operation}): CDF of {metric} for N={batch_size}<br>Comparison Across Configurations',
        xaxis_title=f'{metric} (cycles)',
        yaxis_title='CDF',
        hovermode='closest',
        template='plotly_white',
        width=1200,
        height=800,
        font=dict(size=12),
        legend=dict(
            yanchor="bottom",
            y=0.02,
            xanchor="right",
            x=0.98
        )
    )
    
    # Save as interactive HTML
    output_path_html = os.path.join(output_dir, f'{app_name}_{operation}_cdf_{metric.lower()}_N{batch_size}.html')
    fig.write_html(output_path_html)
    print(f"✅ Saved interactive HTML plot: {output_path_html}")

def plot_cdf_for_batch_size(app_name, operation, batch_size, data_dict, metric='ExecutionTime', output_dir='.'):
    """
    Generate CDF plot for a specific batch size across different configurations.
    
    Args:
        app_name: The application name
        operation: The operation/test type (e.g., "create", "compose", "login")
        batch_size: The batch size (N) to plot
        data_dict: Dictionary mapping config name to DataFrame
        metric: Which metric to plot ('QueueingDelay', 'ExecutionTime', 'TotalLatency')
        output_dir: Directory to save the plot
    """
    plt.figure(figsize=(12, 8))
    
    # Sort configurations for consistent ordering
    def sort_key(x):
        if x == 'ispc':
            return (0, 0, '')
        elif x.startswith('mt'):
            # Extract thread count and mode (e.g., "mt8_pool" -> 8, "pool")
            parts = x.replace('mt', '').split('_')
            threads = int(parts[0]) if parts[0] else 0
            mode = parts[1] if len(parts) > 1 else ''
            return (1, threads, mode)
        else:
            return (2, 0, x)
    
    configs = sorted(data_dict.keys(), key=sort_key)
    
    # Get consistent color map
    color_map = get_config_color_map()
    
    for config in configs:
        df = data_dict[config]
        
        # Get the metric data
        if metric not in df.columns:
            print(f"Warning: Metric '{metric}' not found in {config} data")
            continue
        
        data = df[metric].values
        sorted_data, cdf = calculate_cdf(data)
        
        # Create label
        if config == 'ispc':
            label = 'ISPC SIMD'
        elif config.startswith('mt'):
            # Parse thread count and mode (e.g., "mt8_pool" -> "MT-8 (pool)")
            parts = config.replace('mt', '').split('_')
            threads = parts[0] if parts[0] else '?'
            mode = parts[1] if len(parts) > 1 else ''
            label = f'MT-{threads} ({mode})' if mode else f'MT-{threads}'
        else:
            label = config
        
        # Plot CDF with consistent color
        plt.plot(sorted_data, cdf, label=label, linewidth=2.5, 
                color=get_config_color(config, color_map), alpha=0.8)
    
    # Formatting
    plt.xlabel(f'{metric} (cycles)', fontsize=14, fontweight='bold')
    plt.ylabel('CDF', fontsize=14, fontweight='bold')
    plt.grid(True, alpha=0.3, linestyle='--')
    legend = plt.legend(fontsize=11, loc='lower right')
    
    # Make legend text bold
    for text in legend.get_texts():
        text.set_fontweight('bold')
    
    # Make tick labels bold
    ax = plt.gca()
    for label in ax.get_xticklabels():
        label.set_fontweight('bold')
    for label in ax.get_yticklabels():
        label.set_fontweight('bold')
    
    # Add percentile lines
    for percentile in [0.5, 0.9, 0.95, 0.99]:
        plt.axhline(y=percentile, color='gray', linestyle=':', alpha=0.5, linewidth=1)
        plt.text(plt.xlim()[0], percentile, f' {int(percentile*100)}%', 
                va='center', fontsize=9, color='gray')
    
    plt.tight_layout()
    
    # Save plot as PDF for publication quality (IEEE-compliant: 300 DPI, embedded fonts)
    output_path_pdf = os.path.join(output_dir, f'{app_name}_{operation}_cdf_{metric.lower()}_N{batch_size}.pdf')
    plt.savefig(output_path_pdf, format=IEEE_FMT, dpi=IEEE_DPI, bbox_inches='tight')
    print(f"✅ Saved IEEE-compliant PDF plot (300 DPI): {output_path_pdf}")
    
    plt.close()

def plot_all_metrics_subplot(app_name, operation, batch_size, data_dict, output_dir='.'):
    """Generate a single figure with subplots for all three metrics."""
    fig, axes = plt.subplots(1, 3, figsize=(18, 6))
    metrics = ['QueueingDelay', 'ExecutionTime', 'TotalLatency']
    
    # Get consistent color map
    color_map = get_config_color_map()
    
    # Sort configurations
    def sort_key(x):
        if x == 'ispc':
            return (0, 0, '')
        elif x.startswith('mt'):
            parts = x.replace('mt', '').split('_')
            threads = int(parts[0]) if parts[0] else 0
            mode = parts[1] if len(parts) > 1 else ''
            return (1, threads, mode)
        else:
            return (2, 0, x)
    
    configs = sorted(data_dict.keys(), key=sort_key)
    
    for metric_idx, metric in enumerate(metrics):
        ax = axes[metric_idx]
        
        for config in configs:
            df = data_dict[config]
            
            if metric not in df.columns:
                continue
            
            data = df[metric].values
            sorted_data, cdf = calculate_cdf(data)
            
            if config == 'ispc':
                label = 'ISPC SIMD'
            elif config.startswith('mt'):
                parts = config.replace('mt', '').split('_')
                threads = parts[0] if parts[0] else '?'
                mode = parts[1] if len(parts) > 1 else ''
                label = f'MT-{threads} ({mode})' if mode else f'MT-{threads}'
            else:
                label = config
            
            ax.plot(sorted_data, cdf, label=label, linewidth=2.5, 
                   color=get_config_color(config, color_map), alpha=0.8)
        
        ax.set_xlabel(f'{metric} (cycles)', fontsize=12, fontweight='bold')
        ax.set_ylabel('CDF', fontsize=12, fontweight='bold')
        ax.grid(True, alpha=0.3, linestyle='--')
        
        # Add percentile lines
        for percentile in [0.5, 0.9, 0.95, 0.99]:
            ax.axhline(y=percentile, color='gray', linestyle=':', alpha=0.5, linewidth=1)
        
        if metric_idx == 2:  # Only show legend on last subplot
            ax.legend(fontsize=10, loc='lower right')
    
    plt.tight_layout()
    
    # Save as PDF (IEEE-compliant: 300 DPI, embedded fonts)
    output_path_pdf = os.path.join(output_dir, f'{app_name}_{operation}_cdf_all_metrics_N{batch_size}.pdf')
    plt.savefig(output_path_pdf, format=IEEE_FMT, dpi=IEEE_DPI, bbox_inches='tight')
    print(f"✅ Saved combined IEEE-compliant PDF plot (300 DPI): {output_path_pdf}")
    
    plt.close()

def print_statistics(app_name, operation, batch_size, data_dict, metric='ExecutionTime'):
    """Print statistical summary for each configuration."""
    print(f"\n{'='*80}")
    print(f"{get_display_name(app_name)} ({operation}): STATISTICS FOR N={batch_size} - {metric}")
    print(f"{'='*80}")
    print(f"{'Config':<15} {'Min':>10} {'Median':>10} {'Mean':>10} {'95th%':>10} {'99th%':>10} {'Max':>10}")
    print(f"{'-'*80}")
    
    def sort_key(x):
        if x == 'ispc':
            return (0, 0, '')
        elif x.startswith('mt'):
            parts = x.replace('mt', '').split('_')
            threads = int(parts[0]) if parts[0] else 0
            mode = parts[1] if len(parts) > 1 else ''
            return (1, threads, mode)
        else:
            return (2, 0, x)
    
    configs = sorted(data_dict.keys(), key=sort_key)
    
    for config in configs:
        df = data_dict[config]
        if metric not in df.columns:
            continue
        
        data = df[metric].values
        
        stats = {
            'min': np.min(data),
            'median': np.median(data),
            'mean': np.mean(data),
            'p95': np.percentile(data, 95),
            'p99': np.percentile(data, 99),
            'max': np.max(data)
        }
        
        # Create label
        if config == 'ispc':
            label = 'ISPC'
        elif config.startswith('mt'):
            parts = config.replace('mt', '').split('_')
            threads = parts[0] if parts[0] else '?'
            mode = parts[1] if len(parts) > 1 else ''
            label = f'MT-{threads}({mode})' if mode else f'MT-{threads}'
        else:
            label = config
        
        print(f"{label:<15} {stats['min']:>10.0f} {stats['median']:>10.0f} "
              f"{stats['mean']:>10.0f} {stats['p95']:>10.0f} "
              f"{stats['p99']:>10.0f} {stats['max']:>10.0f}")
    
    print(f"{'='*80}\n")

def plot_speedup_grouped_by_app(app_data, batch_size, metric='TotalLatency', output_dir='.'):
    """
    Generate a grouped bar chart showing speedup for each app operation.
    Each app+operation has a group of bars, with the baseline (mt1_spawn) at 1.0x.
    
    Args:
        app_data: Nested dict of app_name -> operation -> batch_size -> config -> df
        batch_size: The batch size to plot speedup for
        metric: The metric to compute speedup on ('ExecutionTime', 'TotalLatency', etc.)
        output_dir: Directory to save the plot
    """
    
    def sort_key(x):
        # Sort mt1_spawn first (baseline), then others
        if x == 'mt1_spawn':
            return (-1, 0, '')
        elif x == 'ispc':
            return (0, 0, '')
        elif x.startswith('mt'):
            parts = x.replace('mt', '').split('_')
            threads = int(parts[0]) if parts[0] else 0
            mode = parts[1] if len(parts) > 1 else ''
            return (1, threads, mode)
        else:
            return (2, 0, x)
    
    # Collect speedup data for each app+operation combination
    speedup_data = {}  # (app_name, operation) -> {config: speedup_value}
    baseline_times = {}  # (app_name, operation) -> baseline_mean_time
    
    for app_name in sorted(app_data.keys()):
        operation_data = app_data[app_name]
        
        # Process all operations with data for this batch size
        for operation in sorted(operation_data.keys()):
            if batch_size in operation_data[operation]:
                data_dict = operation_data[operation][batch_size]
                
                # Look for baseline configuration
                if BASELINE_CONFIG not in data_dict:
                    print(f"⚠️  Warning: Baseline '{BASELINE_CONFIG}' not found for {app_name}/{operation}, skipping")
                    continue
                
                baseline_df = data_dict[BASELINE_CONFIG]
                
                if metric not in baseline_df.columns:
                    continue
                
                baseline_mean = np.mean(baseline_df[metric].values)
                baseline_times[(app_name, operation)] = baseline_mean
                
                # Get all configurations for this app+operation and sort them
                configs = sorted(data_dict.keys(), key=sort_key)
                
                # Calculate speedup for each config
                app_op_speedups = {}
                for config in configs:
                    df = data_dict[config]
                    if metric not in df.columns:
                        continue
                    
                    config_mean = np.mean(df[metric].values)
                    speedup = baseline_mean / config_mean  # Higher is better
                    app_op_speedups[config] = speedup
                
                speedup_data[(app_name, operation)] = app_op_speedups
    
    if not speedup_data:
        print(f"⚠️  No speedup data to plot for N={batch_size}")
        return
    
    # Prepare data for plotting
    app_ops = sorted(speedup_data.keys())  # List of (app_name, operation) tuples
    
    # Get all unique configs across all app+operations
    all_configs = set()
    for app_op_speedups in speedup_data.values():
        all_configs.update(app_op_speedups.keys())
    configs = sorted(all_configs, key=sort_key)
    
    # Create bar chart - make it wider to accommodate more groups
    fig, ax = plt.subplots(figsize=(max(16, len(app_ops) * 1.5), 8))
    
    # Bar width and positions
    bar_width = 0.15
    num_configs = len(configs)
    
    # Get consistent color map
    color_map = get_config_color_map()
    
    # X positions for each app+operation group with spacing between them
    # Use spacing factor to add gaps between groups
    spacing_factor = 2.5  # Increase this for more spacing
    x_pos = np.arange(len(app_ops)) * spacing_factor
    
    # Plot bars for each configuration (skip baseline)
    configs_to_plot = [c for c in configs if c != BASELINE_CONFIG]
    num_configs_to_plot = len(configs_to_plot)
    
    for config_idx, config in enumerate(configs_to_plot):
        speedups = []
        for app_op in app_ops:
            if config in speedup_data[app_op]:
                speedups.append(speedup_data[app_op][config])
            else:
                speedups.append(0)  # No data for this config
        
        # Create label
        if config == 'ispc':
            label = 'ISPC SIMD'
        elif config.startswith('mt'):
            parts = config.replace('mt', '').split('_')
            threads = parts[0] if parts[0] else '?'
            mode = parts[1] if len(parts) > 1 else ''
            label = f'MT-{threads} ({mode})' if mode else f'MT-{threads}'
        else:
            label = config
        
        # Position offset for this configuration
        offset = (config_idx - num_configs_to_plot/2 + 0.5) * bar_width
        
        ax.bar(x_pos + offset, speedups, bar_width, 
               label=label, color=get_config_color(config, color_map), alpha=0.8)
    
    # Add horizontal line at 1.0x (baseline)
    ax.axhline(y=1.0, color='red', linestyle='--', linewidth=2, alpha=0.7, label='Baseline (1.0x)')
    
    # Formatting
    ax.set_xlabel('Application / Operation', fontsize=14, fontweight='bold')
    ax.set_ylabel('Speedup', fontsize=14, fontweight='bold')
    ax.set_xticks(x_pos)
    # Create labels like "PostStorageService/create", "UserService/lookup", etc.
    x_labels = [f'{get_display_name(app)}/{op}' for app, op in app_ops]
    ax.set_xticklabels(x_labels, fontsize=11, rotation=45, ha='right')
    ax.legend(fontsize=10, loc='upper left', ncol=2)
    ax.grid(True, alpha=0.3, linestyle='--', axis='y')
    
    # Set y-axis to start at 0
    ax.set_ylim(bottom=0)
    
    plt.tight_layout()
    
    # Save plot (IEEE-compliant: 300 DPI, embedded fonts)
    output_path_pdf = os.path.join(output_dir, f'speedup_grouped_by_app_{metric.lower()}_N{batch_size}.pdf')
    plt.savefig(output_path_pdf, format=IEEE_FMT, dpi=IEEE_DPI, bbox_inches='tight')
    print(f"✅ Saved IEEE-compliant speedup plot (300 DPI): {output_path_pdf}")
    
    plt.close()
    
    # Also create interactive HTML version
    fig_interactive = go.Figure()
    
    # Plot bars for each configuration (skip baseline)
    for config_idx, config in enumerate(configs_to_plot):
        speedups = []
        hover_texts = []
        for app_op in app_ops:
            app, operation = app_op
            if config in speedup_data[app_op]:
                speedup = speedup_data[app_op][config]
                speedups.append(speedup)
                hover_texts.append(f'{get_display_name(app)}/{operation}<br>Config: {config}<br>Speedup: {speedup:.3f}x')
            else:
                speedups.append(0)
                hover_texts.append(f'{get_display_name(app)}/{operation}<br>No data')
        
        # Create label
        if config == 'ispc':
            label = 'ISPC SIMD'
        elif config.startswith('mt'):
            parts = config.replace('mt', '').split('_')
            threads = parts[0] if parts[0] else '?'
            mode = parts[1] if len(parts) > 1 else ''
            label = f'MT-{threads} ({mode})' if mode else f'MT-{threads}'
        else:
            label = config
        
        # Position offset for this configuration
        offset = (config_idx - num_configs_to_plot/2 + 0.5) * bar_width
        x_positions = x_pos + offset
        
        fig_interactive.add_trace(go.Bar(
            x=x_positions,
            y=speedups,
            name=label,
            width=bar_width,
            text=[f'{s:.2f}x' if s > 0 else '' for s in speedups],
            textposition='outside',
            hovertext=hover_texts,
            hoverinfo='text'
        ))
    
    # Add baseline line
    fig_interactive.add_hline(
        y=1.0,
        line_dash="dash",
        line_color="red",
        line_width=2,
        opacity=0.7,
        annotation_text="Baseline (1.0x)",
        annotation_position="top left"
    )
    
    # Update layout
    x_labels = [f'{get_display_name(app)}/{op}' for app, op in app_ops]
    fig_interactive.update_layout(
        title=f'Speedup Comparison Across Applications and Operations for N={batch_size}<br>{metric} (Higher is Better)',
        xaxis=dict(
            title='Application / Operation',
            tickmode='array',
            tickvals=x_pos,
            ticktext=x_labels,
            tickangle=45
        ),
        yaxis=dict(
            title='Speedup',
            rangemode='tozero'
        ),
        barmode='group',
        hovermode='closest',
        template='plotly_white',
        width=max(1600, len(app_ops) * 150),
        height=800,
        font=dict(size=11),
        legend=dict(
            yanchor="top",
            y=0.98,
            xanchor="left",
            x=0.01
        ),
        showlegend=True
    )
    
    # Save interactive HTML version
    output_path_html = os.path.join(output_dir, f'speedup_grouped_by_app_{metric.lower()}_N{batch_size}.html')
    fig_interactive.write_html(output_path_html)
    print(f"✅ Saved interactive speedup plot: {output_path_html}")
    
    # Print speedup statistics
    print(f"\n{'='*80}")
    print(f"SPEEDUP STATISTICS FOR N={batch_size} - {metric}")
    print(f"{'='*80}")
    print(f"{'App/Operation':<25} {'Config':<20} {'Speedup':>10}")
    print(f"{'-'*80}")
    
    for app_op in app_ops:
        app, operation = app_op
        app_op_speedups = speedup_data[app_op]
        for config in sorted(app_op_speedups.keys(), key=sort_key):
            speedup = app_op_speedups[config]
            
            if config == 'ispc':
                label = 'ISPC'
            elif config.startswith('mt'):
                parts = config.replace('mt', '').split('_')
                threads = parts[0] if parts[0] else '?'
                mode = parts[1] if len(parts) > 1 else ''
                label = f'MT-{threads}({mode})' if mode else f'MT-{threads}'
            else:
                label = config
            
            app_op_label = f'{get_display_name(app)}/{operation}'
            print(f"{app_op_label:<25} {label:<20} {speedup:>10.3f}x")
        print(f"{'-'*55}")
    
    print(f"{'='*80}\n")

def plot_throughput_grouped_by_app(app_data, batch_size, metric='TotalLatency', output_dir='.'):
    """
    Generate a grouped bar chart showing throughput for each app operation.
    Throughput is calculated as operations per second based on the mean latency.
    
    Args:
        app_data: Nested dict of app_name -> operation -> batch_size -> config -> df
        batch_size: The batch size to plot throughput for
        metric: The metric to compute throughput on ('ExecutionTime', 'TotalLatency', etc.)
        output_dir: Directory to save the plot
    """
    
    def sort_key(x):
        # Sort mt1_spawn first, then others
        if x == 'mt1_spawn':
            return (-1, 0, '')
        elif x == 'ispc':
            return (0, 0, '')
        elif x.startswith('mt'):
            parts = x.replace('mt', '').split('_')
            threads = int(parts[0]) if parts[0] else 0
            mode = parts[1] if len(parts) > 1 else ''
            return (1, threads, mode)
        else:
            return (2, 0, x)
    
    # Collect throughput data for each app+operation combination
    throughput_data = {}  # (app_name, operation) -> {config: throughput_value}
    
    for app_name in sorted(app_data.keys()):
        operation_data = app_data[app_name]
        
        # Process all operations with data for this batch size
        for operation in sorted(operation_data.keys()):
            if batch_size in operation_data[operation]:
                data_dict = operation_data[operation][batch_size]
                
                # Get all configurations for this app+operation and sort them
                configs = sorted(data_dict.keys(), key=sort_key)
                
                # Calculate throughput for each config
                app_op_throughputs = {}
                baseline_throughput = None
                
                # First pass: calculate absolute throughput and find baseline
                absolute_throughputs = {}
                for config in configs:
                    df = data_dict[config]
                    if metric not in df.columns:
                        continue
                    
                    # Mean latency in cycles
                    config_mean = np.mean(df[metric].values)
                    
                    # Throughput = operations per cycle
                    # For better readability, multiply by a constant (e.g., 1e6 for ops per million cycles)
                    throughput = 1e6 / config_mean  # ops per million cycles
                    absolute_throughputs[config] = throughput
                    
                    if config == BASELINE_CONFIG:
                        baseline_throughput = throughput
                
                # Second pass: normalize by baseline
                if baseline_throughput is not None and baseline_throughput > 0:
                    for config, throughput in absolute_throughputs.items():
                        app_op_throughputs[config] = throughput / baseline_throughput
                else:
                    # If no baseline, use absolute values
                    app_op_throughputs = absolute_throughputs
                
                if app_op_throughputs:
                    throughput_data[(app_name, operation)] = app_op_throughputs
    
    if not throughput_data:
        print(f"⚠️  No throughput data to plot for N={batch_size}")
        return
    
    # Prepare data for plotting
    app_ops = sorted(throughput_data.keys())  # List of (app_name, operation) tuples
    
    # Get all unique configs across all app+operations
    all_configs = set()
    for app_op_throughputs in throughput_data.values():
        all_configs.update(app_op_throughputs.keys())
    configs = sorted(all_configs, key=sort_key)
    
    # Create bar chart - make it wider to accommodate more groups
    fig, ax = plt.subplots(figsize=(max(16, len(app_ops) * 1.5), 4.5))
    
    # Bar width and positions
    bar_width = 0.30
    num_configs = len(configs)
    
    # Get consistent color map
    color_map = get_config_color_map()
    
    # X positions for each app+operation group with spacing between them
    spacing_factor = 2.3  # Increase spacing to prevent label overlap
    x_pos = np.arange(len(app_ops)) * spacing_factor
    
    # Plot bars for each configuration (skip baseline)
    configs_to_plot = [c for c in configs if c != BASELINE_CONFIG]
    num_configs_to_plot = len(configs_to_plot)
    
    Y_MAX = 8 # Maximum y-axis value
    
    for config_idx, config in enumerate(configs_to_plot):
        throughputs = []
        for app_op in app_ops:
            if config in throughput_data[app_op]:
                throughputs.append(throughput_data[app_op][config])
            else:
                throughputs.append(0)  # No data for this config
        
        # Create label
        if config == 'ispc':
            label = 'ISPC SIMD'
        elif config.startswith('mt'):
            parts = config.replace('mt', '').split('_')
            threads = parts[0] if parts[0] else '?'
            mode = parts[1] if len(parts) > 1 else ''
            label = f'MT-{threads} ({mode})' if mode else f'MT-{threads}'
        else:
            label = config
        
        # Position offset for this configuration
        offset = (config_idx - num_configs_to_plot/2 + 0.5) * bar_width
        
        # Cap display values at Y_MAX for bars
        display_throughputs = [min(t, Y_MAX) if t > 0 else 0 for t in throughputs]
        
        bars = ax.bar(x_pos + offset, display_throughputs, bar_width, 
                      label=label, color=get_config_color(config, color_map), alpha=0.8,
                      edgecolor='black', linewidth=0.8)
        
        # Add text labels on top for values exceeding Y_MAX
        for i, (actual_val, display_val) in enumerate(zip(throughputs, display_throughputs)):
            if actual_val > Y_MAX:
                ax.text(x_pos[i] + offset, Y_MAX, f'{actual_val:.1f}',
                       ha='center', va='bottom', fontsize=8, fontweight='bold',
                       rotation=0)
    
    # Add baseline reference line at 1.0
    ax.axhline(y=1.0, color='red', linestyle='--', linewidth=2, alpha=0.7, label='Baseline (1.0x)')
    
    # Formatting
    ax.set_xlabel('Application / Operation', fontsize=14, fontweight='bold')
    ax.set_ylabel('Normalized Throughput', fontsize=14, fontweight='bold')
    ax.set_xticks(x_pos)
    # Create labels with app name and operation on different lines
    x_labels = [f'{get_display_name(app)}\n{op}' for app, op in app_ops]
    ax.set_xticklabels(x_labels, fontsize=11, rotation=0, ha='center', fontweight='bold')
    legend = ax.legend(fontsize=10, loc='upper left', ncol=2)
    
    # Make tick labels bold
    for label in ax.get_yticklabels():
        label.set_fontweight('bold')
    
    # Make legend text bold
    for text in legend.get_texts():
        text.set_fontweight('bold')
    
    ax.grid(True, alpha=0.3, linestyle='--', axis='y')
    
    # Set y-axis range from 0 to Y_MAX
    ax.set_ylim(bottom=0, top=Y_MAX)
    
    plt.tight_layout()
    
    # Save plot (IEEE-compliant: 300 DPI, embedded fonts)
    output_path_pdf = os.path.join(output_dir, f'throughput_grouped_by_app_{metric.lower()}_N{batch_size}.pdf')
    plt.savefig(output_path_pdf, format=IEEE_FMT, dpi=IEEE_DPI, bbox_inches='tight')
    print(f"✅ Saved IEEE-compliant throughput plot (300 DPI): {output_path_pdf}")
    
    plt.close()
    
    # Also create interactive HTML version
    fig_interactive = go.Figure()
    
    # Plot bars for each configuration (skip baseline)
    for config_idx, config in enumerate(configs_to_plot):
        throughputs = []
        hover_texts = []
        text_labels = []
        for app_op in app_ops:
            app, operation = app_op
            if config in throughput_data[app_op]:
                throughput = throughput_data[app_op][config]
                throughputs.append(throughput)
                hover_texts.append(f'{get_display_name(app)}/{operation}<br>Config: {config}<br>Normalized Throughput: {throughput:.2f}x')
                # Show text label only if exceeds Y_MAX
                if throughput > Y_MAX:
                    text_labels.append(f'{throughput:.1f}')
                else:
                    text_labels.append('')
            else:
                throughputs.append(0)
                hover_texts.append(f'{get_display_name(app)}/{operation}<br>No data')
                text_labels.append('')
        
        # Create label
        if config == 'ispc':
            label = 'ISPC SIMD'
        elif config.startswith('mt'):
            parts = config.replace('mt', '').split('_')
            threads = parts[0] if parts[0] else '?'
            mode = parts[1] if len(parts) > 1 else ''
            label = f'MT-{threads} ({mode})' if mode else f'MT-{threads}'
        else:
            label = config
        
        # Position offset for this configuration
        offset = (config_idx - num_configs_to_plot/2 + 0.5) * bar_width
        x_positions = x_pos + offset
        
        # Cap display values at Y_MAX
        display_throughputs = [min(t, Y_MAX) if t > 0 else 0 for t in throughputs]
        
        fig_interactive.add_trace(go.Bar(
            x=x_positions,
            y=display_throughputs,
            name=label,
            width=bar_width,
            text=text_labels,
            textposition='outside',
            hovertext=hover_texts,
            hoverinfo='text'
        ))
    
    # Add baseline reference line at 1.0
    fig_interactive.add_hline(y=1.0, line_dash="dash", line_color="red", line_width=2, 
                              annotation_text="Baseline (1.0x)", annotation_position="right")
    
    # Update layout
    x_labels = [f'{get_display_name(app)}/{op}' for app, op in app_ops]
    fig_interactive.update_layout(
        title=f'Throughput Comparison Across Applications and Operations for N={batch_size}<br>{metric} (Higher is Better)',
        xaxis=dict(
            title='Application / Operation',
            tickmode='array',
            tickvals=x_pos,
            ticktext=x_labels,
            tickangle=45
        ),
        yaxis=dict(
            title='Normalized Throughput',
            range=[0, Y_MAX]
        ),
        barmode='group',
        hovermode='closest',
        template='plotly_white',
        width=max(1600, len(app_ops) * 150),
        height=800,
        font=dict(size=11),
        legend=dict(
            yanchor="top",
            y=0.98,
            xanchor="left",
            x=0.01
        ),
        showlegend=True
    )
    
    # Save interactive HTML version
    output_path_html = os.path.join(output_dir, f'throughput_grouped_by_app_{metric.lower()}_N{batch_size}.html')
    fig_interactive.write_html(output_path_html)
    print(f"✅ Saved interactive throughput plot: {output_path_html}")
    
    # Print throughput statistics
    print(f"\n{'='*80}")
    print(f"THROUGHPUT STATISTICS FOR N={batch_size} - {metric}")
    print(f"{'='*80}")
    print(f"{'App/Operation':<25} {'Config':<20} {'Norm. Throughput':>18}")
    print(f"{'-'*80}")
    
    for app_op in app_ops:
        app, operation = app_op
        app_op_throughputs = throughput_data[app_op]
        for config in sorted(app_op_throughputs.keys(), key=sort_key):
            throughput = app_op_throughputs[config]
            
            if config == 'ispc':
                label = 'ISPC'
            elif config.startswith('mt'):
                parts = config.replace('mt', '').split('_')
                threads = parts[0] if parts[0] else '?'
                mode = parts[1] if len(parts) > 1 else ''
                label = f'MT-{threads}({mode})' if mode else f'MT-{threads}'
            else:
                label = config
            
            app_op_label = f'{get_display_name(app)}/{operation}'
            print(f"{app_op_label:<25} {label:<20} {throughput:>18.2f}x")
        print(f"{'-'*55}")
    
    print(f"{'='*80}\n")

def plot_all_apps_cdf_subplots(app_data, batch_size, metric='TotalLatency', output_dir='.'):
    """
    Generate a single figure with subplots for all app/operation combinations.
    Each subplot shows the CDF for one app/operation at the specified batch size.
    
    Args:
        app_data: Nested dict of app_name -> operation -> batch_size -> config -> df
        batch_size: The batch size to plot
        metric: Which metric to plot ('QueueingDelay', 'ExecutionTime', 'TotalLatency')
        output_dir: Directory to save the plot
    """
    
    def sort_key(x):
        if x == 'ispc':
            return (0, 0, '')
        elif x.startswith('mt'):
            parts = x.replace('mt', '').split('_')
            threads = int(parts[0]) if parts[0] else 0
            mode = parts[1] if len(parts) > 1 else ''
            return (1, threads, mode)
        else:
            return (2, 0, x)
    
    # Collect all app/operation combinations that have data for this batch size
    app_ops = []
    for app_name in sorted(app_data.keys()):
        for operation in sorted(app_data[app_name].keys()):
            if batch_size in app_data[app_name][operation]:
                app_ops.append((app_name, operation))
    
    if not app_ops:
        print(f"⚠️  No data to plot for N={batch_size}")
        return
    
    # Calculate grid dimensions (try to make it roughly square)
    n_plots = len(app_ops)
    n_cols = int(np.ceil(np.sqrt(n_plots)))
    n_rows = int(np.ceil(n_plots / n_cols))
    
    # Create figure with subplots
    fig, axes = plt.subplots(n_rows, n_cols, figsize=(6 * n_cols, 5 * n_rows))
    
    # Flatten axes array for easier iteration
    if n_plots == 1:
        axes = [axes]
    else:
        axes = axes.flatten() if n_rows > 1 or n_cols > 1 else [axes]
    
    # Generate colors for configurations
    # First, collect all unique configurations across all apps
    all_configs = set()
    for app_name, operation in app_ops:
        data_dict = app_data[app_name][operation][batch_size]
        all_configs.update(data_dict.keys())
    
    configs = sorted(all_configs, key=sort_key)
    # Use consistent color map across all figures
    color_map = get_config_color_map()
    
    # Plot each app/operation in its own subplot
    # Track if we've added labels (only need once for shared legend)
    labels_added = False
    legend_handles = []
    legend_labels = []
    
    for idx, (app_name, operation) in enumerate(app_ops):
        ax = axes[idx]
        data_dict = app_data[app_name][operation][batch_size]
        
        # Get configurations for this app/operation
        app_configs = sorted(data_dict.keys(), key=sort_key)
        
        for config in app_configs:
            df = data_dict[config]
            
            if metric not in df.columns:
                continue
            
            data = df[metric].values
            sorted_data, cdf = calculate_cdf(data)
            
            # Create label
            if config == 'ispc':
                label = 'ISPC'
            elif config.startswith('mt'):
                parts = config.replace('mt', '').split('_')
                threads = parts[0] if parts[0] else '?'
                mode = parts[1] if len(parts) > 1 else ''
                label = f'MT-{threads}({mode})' if mode else f'MT-{threads}'
            else:
                label = config
            
            # Plot CDF with consistent colors across subplots (no label on individual plots)
            line, = ax.plot(sorted_data, cdf, linewidth=2,
                           color=color_map[config], alpha=0.8)
            
            # Collect handles and labels from first subplot for shared legend
            if not labels_added and idx == 0:
                legend_handles.append(line)
                legend_labels.append(label)
        
        # Mark that we've collected labels
        if idx == 0:
            labels_added = True
        
        # Formatting for this subplot
        ax.set_xlabel(f'{metric} (cycles)', fontsize=10, fontweight='bold')
        ax.set_ylabel('CDF', fontsize=10, fontweight='bold')
        ax.set_title(f'{get_display_name(app_name)} ({operation})', fontsize=10, fontweight='bold')
        ax.grid(True, alpha=0.3, linestyle='--')
        
        # Add percentile lines
        for percentile in [0.5, 0.9, 0.95, 0.99]:
            ax.axhline(y=percentile, color='gray', linestyle=':', alpha=0.3, linewidth=1)
    
    # Hide any unused subplots
    for idx in range(len(app_ops), len(axes)):
        axes[idx].set_visible(False)
    
    # Add a single shared horizontal legend below all subplots
    fig.legend(legend_handles, legend_labels, loc='lower center', fontsize=14, 
               ncol=len(legend_labels), frameon=True, bbox_to_anchor=(0.5, -0.02),
               prop={'weight': 'bold'})
    
    plt.tight_layout(rect=[0, 0.05, 1, 0.99])
    
    # Save as PDF (IEEE-compliant: 300 DPI, embedded fonts)
    output_path_pdf = os.path.join(output_dir, f'all_apps_cdf_{metric.lower()}_N{batch_size}.pdf')
    plt.savefig(output_path_pdf, format=IEEE_FMT, dpi=IEEE_DPI, bbox_inches='tight')
    print(f"✅ Saved combined CDF plot with {len(app_ops)} subplots (300 DPI): {output_path_pdf}")
    
    plt.close()
    
    # Also create interactive HTML version using plotly subplots
    from plotly.subplots import make_subplots
    
    fig_interactive = make_subplots(
        rows=n_rows, cols=n_cols,
        subplot_titles=[f'{get_display_name(app)}/{op}' for app, op in app_ops],
        vertical_spacing=0.12 / n_rows if n_rows > 1 else 0.1,
        horizontal_spacing=0.10 / n_cols if n_cols > 1 else 0.1
    )
    
    # Add traces for each app/operation
    for idx, (app_name, operation) in enumerate(app_ops):
        row = idx // n_cols + 1
        col = idx % n_cols + 1
        
        data_dict = app_data[app_name][operation][batch_size]
        app_configs = sorted(data_dict.keys(), key=sort_key)
        
        for config in app_configs:
            df = data_dict[config]
            
            if metric not in df.columns:
                continue
            
            data = df[metric].values
            sorted_data, cdf = calculate_cdf(data)
            
            # Create label
            if config == 'ispc':
                label = 'ISPC'
            elif config.startswith('mt'):
                parts = config.replace('mt', '').split('_')
                threads = parts[0] if parts[0] else '?'
                mode = parts[1] if len(parts) > 1 else ''
                label = f'MT-{threads}({mode})' if mode else f'MT-{threads}'
            else:
                label = config
            
            # Only show legend for first subplot to avoid clutter
            show_legend = (idx == 0)
            
            fig_interactive.add_trace(
                go.Scatter(
                    x=sorted_data,
                    y=cdf,
                    mode='lines',
                    name=label,
                    line=dict(width=2),
                    legendgroup=config,  # Group by config for unified legend
                    showlegend=show_legend,
                    hovertemplate=f'<b>{label}</b><br>{metric}: %{{x:.0f}} cycles<br>CDF: %{{y:.2%}}<extra></extra>'
                ),
                row=row, col=col
            )
        
        # Add percentile lines
        for percentile in [0.5, 0.9, 0.95, 0.99]:
            fig_interactive.add_hline(
                y=percentile,
                line_dash="dot",
                line_color="gray",
                opacity=0.3,
                row=row, col=col
            )
    
    # Update layout
    fig_interactive.update_xaxes(title_text=f'{metric} (cycles)', row=n_rows)
    fig_interactive.update_yaxes(title_text='CDF')
    
    fig_interactive.update_layout(
        title_text=f'CDF Comparison Across All Applications and Operations for N={batch_size}<br>{metric}',
        height=400 * n_rows,
        width=500 * n_cols,
        hovermode='closest',
        template='plotly_white',
        font=dict(size=10),
        showlegend=True,
        legend=dict(
            yanchor="top",
            y=0.99,
            xanchor="left",
            x=1.01
        )
    )
    
    # Save interactive HTML version
    output_path_html = os.path.join(output_dir, f'all_apps_cdf_{metric.lower()}_N{batch_size}.html')
    fig_interactive.write_html(output_path_html)
    print(f"✅ Saved interactive combined CDF plot: {output_path_html}")

def plot_normalized_energy_grouped_by_app(energy_data, metric='TotalPackage_J', output_dir='.'):
    """
    Generate a grouped bar chart showing normalized energy for each app operation.
    Each app+operation has a group of bars, with the baseline (mt1_spawn) at 1.0x.
    
    Args:
        energy_data: Nested dict of app_name -> operation -> config -> df
        metric: The energy metric to plot ('TotalPackage_J', 'TotalCore_J', 'TotalDRAM_J', 'AvgPackage_J')
        output_dir: Directory to save the plot
    """
    
    def sort_key(x):
        # Sort mt1_spawn first (baseline), then others
        if x == 'mt1_spawn':
            return (-1, 0, '')
        elif x == 'ispc':
            return (0, 0, '')
        elif x.startswith('mt'):
            parts = x.replace('mt', '').split('_')
            threads = int(parts[0]) if parts[0] else 0
            mode = parts[1] if len(parts) > 1 else ''
            return (1, threads, mode)
        else:
            return (2, 0, x)
    
    # Collect normalized energy data for each app+operation combination
    normalized_energy_data = {}  # (app_name, operation) -> {config: normalized_value}
    baseline_energies = {}  # (app_name, operation) -> baseline_energy
    
    for app_name in sorted(energy_data.keys()):
        operation_data = energy_data[app_name]
        
        # Process all operations
        for operation in sorted(operation_data.keys()):
            config_data = operation_data[operation]
            
            # Look for baseline configuration
            if BASELINE_CONFIG not in config_data:
                print(f"⚠️  Warning: Baseline '{BASELINE_CONFIG}' not found for {app_name}/{operation}, skipping")
                continue
            
            baseline_df = config_data[BASELINE_CONFIG]
            
            if metric not in baseline_df.columns:
                print(f"⚠️  Warning: Metric '{metric}' not found in baseline for {app_name}/{operation}")
                continue
            
            # Get baseline energy (use first row since energy summary has one row per config)
            baseline_energy = baseline_df[metric].iloc[0] if len(baseline_df) > 0 else 0
            if baseline_energy == 0:
                print(f"⚠️  Warning: Baseline energy is 0 for {app_name}/{operation}, skipping")
                continue
                
            baseline_energies[(app_name, operation)] = baseline_energy
            
            # Get all configurations for this app+operation and sort them
            configs = sorted(config_data.keys(), key=sort_key)
            
            # Calculate normalized energy for each config
            app_op_normalized = {}
            for config in configs:
                df = config_data[config]
                if metric not in df.columns:
                    continue
                
                config_energy = df[metric].iloc[0] if len(df) > 0 else 0
                # Normalized energy: higher means more energy consumed (worse)
                normalized = config_energy / baseline_energy
                app_op_normalized[config] = normalized
            
            normalized_energy_data[(app_name, operation)] = app_op_normalized
    
    if not normalized_energy_data:
        print(f"⚠️  No normalized energy data to plot")
        return
    
    # Prepare data for plotting
    app_ops = sorted(normalized_energy_data.keys())  # List of (app_name, operation) tuples
    
    # Get all unique configs across all app+operations
    all_configs = set()
    for app_op_normalized in normalized_energy_data.values():
        all_configs.update(app_op_normalized.keys())
    configs = sorted(all_configs, key=sort_key)
    
    # Create bar chart - make it wider to accommodate more groups
    fig, ax = plt.subplots(figsize=(max(16, len(app_ops) * 1.5), 4.5))
    
    # Bar width and positions
    bar_width = 0.30
    num_configs = len(configs)
    
    # Get consistent color map
    color_map = get_config_color_map()
    
    # X positions for each app+operation group with spacing between them
    spacing_factor = 2.3  # Increase spacing to prevent label overlap
    x_pos = np.arange(len(app_ops)) * spacing_factor
    
    # Plot bars for each configuration (skip baseline)
    configs_to_plot = [c for c in configs if c != BASELINE_CONFIG]
    num_configs_to_plot = len(configs_to_plot)
    
    for config_idx, config in enumerate(configs_to_plot):
        normalized_values = []
        for app_op in app_ops:
            if config in normalized_energy_data[app_op]:
                normalized_values.append(normalized_energy_data[app_op][config])
            else:
                normalized_values.append(0)  # No data for this config
        
        # Create label
        if config == 'ispc':
            label = 'ISPC SIMD'
        elif config.startswith('mt'):
            parts = config.replace('mt', '').split('_')
            threads = parts[0] if parts[0] else '?'
            mode = parts[1] if len(parts) > 1 else ''
            label = f'MT-{threads} ({mode})' if mode else f'MT-{threads}'
        else:
            label = config
        
        # Position offset for this configuration
        offset = (config_idx - num_configs_to_plot/2 + 0.5) * bar_width
        
        ax.bar(x_pos + offset, normalized_values, bar_width, 
               label=label, color=get_config_color(config, color_map), alpha=0.8,
               edgecolor='black', linewidth=0.8)
    
    # Add horizontal line at 1.0x (baseline)
    ax.axhline(y=1.0, color='red', linestyle='--', linewidth=2, alpha=0.7, label='Baseline (1.0x)')
    
    # Formatting
    ax.set_xlabel('Application / Operation', fontsize=14, fontweight='bold')
    ax.set_ylabel('Normalized Energy', fontsize=14, fontweight='bold')
    ax.set_xticks(x_pos)
    # Create labels with app name and operation on different lines
    x_labels = [f'{get_display_name(app)}\n{op}' for app, op in app_ops]
    ax.set_xticklabels(x_labels, fontsize=11, rotation=0, ha='center', fontweight='bold')
    legend = ax.legend(fontsize=10, loc='upper left', ncol=2)
    
    # Make tick labels bold
    for label in ax.get_yticklabels():
        label.set_fontweight('bold')
    
    # Make legend text bold
    for text in legend.get_texts():
        text.set_fontweight('bold')
    
    ax.grid(True, alpha=0.3, linestyle='--', axis='y')
    
    # Set y-axis to start at 0
    ax.set_ylim(bottom=0)
    
    plt.tight_layout()
    
    # Save plot (IEEE-compliant: 300 DPI, embedded fonts)
    output_path_pdf = os.path.join(output_dir, f'normalized_energy_grouped_by_app_{metric.lower()}.pdf')
    plt.savefig(output_path_pdf, format=IEEE_FMT, dpi=IEEE_DPI, bbox_inches='tight')
    print(f"✅ Saved IEEE-compliant normalized energy plot (300 DPI): {output_path_pdf}")
    
    plt.close()
    
    # Also create interactive HTML version
    fig_interactive = go.Figure()
    
    # Plot bars for each configuration (skip baseline)
    for config_idx, config in enumerate(configs_to_plot):
        normalized_values = []
        hover_texts = []
        for app_op in app_ops:
            app, operation = app_op
            if config in normalized_energy_data[app_op]:
                normalized = normalized_energy_data[app_op][config]
                normalized_values.append(normalized)
                hover_texts.append(f'{get_display_name(app)}/{operation}<br>Config: {config}<br>Normalized Energy: {normalized:.3f}x')
            else:
                normalized_values.append(0)
                hover_texts.append(f'{get_display_name(app)}/{operation}<br>No data')
        
        # Create label
        if config == 'ispc':
            label = 'ISPC SIMD'
        elif config.startswith('mt'):
            parts = config.replace('mt', '').split('_')
            threads = parts[0] if parts[0] else '?'
            mode = parts[1] if len(parts) > 1 else ''
            label = f'MT-{threads} ({mode})' if mode else f'MT-{threads}'
        else:
            label = config
        
        # Position offset for this configuration
        offset = (config_idx - num_configs_to_plot/2 + 0.5) * bar_width
        x_positions = x_pos + offset
        
        fig_interactive.add_trace(go.Bar(
            x=x_positions,
            y=normalized_values,
            name=label,
            width=bar_width,
            text=[f'{n:.2f}x' if n > 0 else '' for n in normalized_values],
            textposition='outside',
            hovertext=hover_texts,
            hoverinfo='text'
        ))
    
    # Add baseline line
    fig_interactive.add_hline(
        y=1.0,
        line_dash="dash",
        line_color="red",
        line_width=2,
        opacity=0.7,
        annotation_text="Baseline (1.0x)",
        annotation_position="top left"
    )
    
    # Update layout
    x_labels = [f'{get_display_name(app)}/{op}' for app, op in app_ops]
    fig_interactive.update_layout(
        title=f'Normalized Energy Comparison Across Applications and Operations<br>{metric} (Lower is Better)',
        xaxis=dict(
            title='Application / Operation',
            tickmode='array',
            tickvals=x_pos,
            ticktext=x_labels,
            tickangle=45
        ),
        yaxis=dict(
            title='Normalized Energy',
            rangemode='tozero'
        ),
        barmode='group',
        hovermode='closest',
        template='plotly_white',
        width=max(1600, len(app_ops) * 150),
        height=800,
        font=dict(size=11),
        legend=dict(
            yanchor="top",
            y=0.98,
            xanchor="left",
            x=0.01
        ),
        showlegend=True
    )
    
    # Save interactive HTML version
    output_path_html = os.path.join(output_dir, f'normalized_energy_grouped_by_app_{metric.lower()}.html')
    fig_interactive.write_html(output_path_html)
    print(f"✅ Saved interactive normalized energy plot: {output_path_html}")
    
    # Print normalized energy statistics
    print(f"\n{'='*80}")
    print(f"NORMALIZED ENERGY STATISTICS - {metric}")
    print(f"{'='*80}")
    print(f"{'App/Operation':<25} {'Config':<20} {'Normalized':>12} {'Absolute (J)':>15}")
    print(f"{'-'*80}")
    
    for app_op in app_ops:
        app, operation = app_op
        app_op_normalized = normalized_energy_data[app_op]
        baseline_energy = baseline_energies[app_op]
        
        for config in sorted(app_op_normalized.keys(), key=sort_key):
            normalized = app_op_normalized[config]
            absolute_energy = normalized * baseline_energy
            
            if config == 'ispc':
                label = 'ISPC'
            elif config.startswith('mt'):
                parts = config.replace('mt', '').split('_')
                threads = parts[0] if parts[0] else '?'
                mode = parts[1] if len(parts) > 1 else ''
                label = f'MT-{threads}({mode})' if mode else f'MT-{threads}'
            else:
                label = config
            
            app_op_label = f'{get_display_name(app)}/{operation}'
            print(f"{app_op_label:<25} {label:<20} {normalized:>12.3f}x {absolute_energy:>15.6f}")
        print(f"{'-'*55}")
    
    print(f"{'='*80}\n")

def generate_index_html(output_dir, app_data, batch_sizes):
    """
    Generate an index.html file with links to all interactive plots.
    
    Args:
        output_dir: Directory where plots are saved
        app_data: Nested dict of app_name -> operation -> batch_size -> config -> df
        batch_sizes: List of batch sizes that have plots
    """
    
    # Organize data by batch size
    batch_size_info = {}
    for batch_size in batch_sizes:
        batch_size_info[batch_size] = {}
        for app_name in sorted(app_data.keys()):
            for operation in sorted(app_data[app_name].keys()):
                if batch_size in app_data[app_name][operation]:
                    if app_name not in batch_size_info[batch_size]:
                        batch_size_info[batch_size][app_name] = []
                    batch_size_info[batch_size][app_name].append(operation)
    
    # Application icons mapping
    app_icons = {
        'post': '📝',
        'user': '👤',
        'userTag': '🏷️',
        'shortURL': '🔗',
        'text': '📄',
        'uniqueID': '🆔'
    }
    
    # Operation icons mapping
    op_icons = {
        'create': '➕',
        'lookup': '🔍',
        'login': '🔐',
        'insert': '📥',
        'compose': '🔧'
    }
    
    html_content = f"""<!DOCTYPE html>
<html lang="en">
<head>
    <meta charset="UTF-8">
    <meta name="viewport" content="width=device-width, initial-scale=1.0">
    <title>Interactive Performance Plots - socialGraph Benchmark Results</title>
    <style>
        body {{
            font-family: 'Segoe UI', Tahoma, Geneva, Verdana, sans-serif;
            max-width: 1400px;
            margin: 0 auto;
            padding: 20px;
            background-color: #f5f5f5;
        }}
        h1 {{
            color: #2c3e50;
            border-bottom: 3px solid #3498db;
            padding-bottom: 10px;
        }}
        h2 {{
            color: #34495e;
            margin-top: 40px;
            border-left: 4px solid #3498db;
            padding-left: 10px;
        }}
        h3 {{
            color: #34495e;
            margin-top: 25px;
            font-size: 1.3em;
        }}
        .batch-section {{
            background: white;
            padding: 20px;
            margin: 20px 0;
            border-radius: 8px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
        }}
        .batch-header {{
            background: linear-gradient(135deg, #667eea 0%, #764ba2 100%);
            color: white;
            padding: 15px 20px;
            border-radius: 8px;
            margin-bottom: 20px;
            font-size: 1.2em;
            font-weight: bold;
        }}
        .plot-grid {{
            display: grid;
            grid-template-columns: repeat(auto-fill, minmax(280px, 1fr));
            gap: 15px;
            margin: 20px 0;
        }}
        .plot-card {{
            background: white;
            border: 1px solid #e0e0e0;
            border-radius: 8px;
            padding: 15px;
            box-shadow: 0 2px 4px rgba(0,0,0,0.1);
            transition: transform 0.2s, box-shadow 0.2s;
        }}
        .plot-card:hover {{
            transform: translateY(-5px);
            box-shadow: 0 4px 8px rgba(0,0,0,0.2);
        }}
        .plot-card a {{
            text-decoration: none;
            color: #2c3e50;
            font-weight: 600;
            display: block;
        }}
        .plot-card .description {{
            color: #7f8c8d;
            font-size: 0.85em;
            margin-top: 8px;
        }}
        .speedup-card {{
            background: linear-gradient(135deg, #11998e 0%, #38ef7d 100%);
            color: white;
            border: none;
            grid-column: span 2;
        }}
        .speedup-card a {{
            color: white;
        }}
        .speedup-card .description {{
            color: #f0f0f0;
        }}
        .icon {{
            font-size: 1.8em;
            margin-bottom: 8px;
        }}
        .app-group {{
            margin-bottom: 30px;
        }}
        .app-title {{
            color: #2c3e50;
            font-size: 1.1em;
            font-weight: bold;
            margin-bottom: 10px;
            padding-bottom: 5px;
            border-bottom: 2px solid #ecf0f1;
        }}
        .summary {{
            background: #e8f4f8;
            padding: 15px;
            border-radius: 8px;
            margin: 20px 0;
            border-left: 4px solid #3498db;
        }}
        .summary strong {{
            color: #2c3e50;
        }}
        footer {{
            margin-top: 50px;
            padding-top: 20px;
            border-top: 1px solid #ddd;
            text-align: center;
            color: #7f8c8d;
        }}
    </style>
</head>
<body>
    <h1>🚀 Interactive Performance Plots</h1>
    <div class="summary">
        <strong>Benchmark Results:</strong> {len(batch_sizes)} batch size(s) | 
        <strong>Applications:</strong> {len(app_data)} apps | 
        <strong>Metric:</strong> TotalLatency | 
        <strong>Baseline:</strong> MT-1 (spawn)
    </div>
"""
    
    # Generate sections for each batch size
    for batch_size in sorted(batch_sizes, reverse=True):
        html_content += f"""
    <div class="batch-section">
        <div class="batch-header">
            📊 Batch Size: N={batch_size}
        </div>
        
        <h3>📊 Combined CDF Plots (All Apps/Operations)</h3>
        <div class="plot-grid">
            <div class="plot-card speedup-card">
                <div class="icon">📊</div>
                <a href="all_apps_cdf_totallatency_N{batch_size}.html" target="_blank">
                    All Apps CDF - Total Latency
                </a>
                <div class="description">
                    Interactive subplots showing CDF of Total Latency for all applications and operations in one view
                </div>
            </div>
            <div class="plot-card speedup-card">
                <div class="icon">⚡</div>
                <a href="all_apps_cdf_executiontime_N{batch_size}.html" target="_blank">
                    All Apps CDF - Execution Time
                </a>
                <div class="description">
                    Interactive subplots showing CDF of Execution Time for all applications and operations in one view
                </div>
            </div>
            <div class="plot-card speedup-card">
                <div class="icon">⏱️</div>
                <a href="all_apps_cdf_queueingdelay_N{batch_size}.html" target="_blank">
                    All Apps CDF - Queueing Delay
                </a>
                <div class="description">
                    Interactive subplots showing CDF of Queueing Delay for all applications and operations in one view
                </div>
            </div>
        </div>
        
        <h3>⚡ Speedup, Throughput & Energy Comparison</h3>
        <div class="plot-grid">
            <div class="plot-card speedup-card">
                <div class="icon">📈</div>
                <a href="speedup_grouped_by_app_totallatency_N{batch_size}.html" target="_blank">
                    Speedup by Application & Operation
                </a>
                <div class="description">
                    Interactive bar chart comparing speedup across all applications and operations relative to MT-1 (spawn) baseline
                </div>
            </div>
            <div class="plot-card speedup-card">
                <div class="icon">⚡</div>
                <a href="throughput_grouped_by_app_totallatency_N{batch_size}.html" target="_blank">
                    Throughput by Application & Operation
                </a>
                <div class="description">
                    Interactive bar chart showing throughput (ops per million cycles) across all applications and operations
                </div>
            </div>
        </div>
        
        <h3>🔋 Energy Efficiency Comparison</h3>
        <div class="plot-grid">
            <div class="plot-card speedup-card">
                <div class="icon">🔋</div>
                <a href="normalized_energy_grouped_by_app_totalcore_j.html" target="_blank">
                    Normalized Energy by Application & Operation
                </a>
                <div class="description">
                    Interactive bar chart comparing normalized core energy consumption across all applications and operations relative to MT-1 (spawn) baseline (Lower is Better)
                </div>
            </div>
        </div>

        <h3>📉 CDF Plots by Application</h3>
"""
        
        # Group by application
        for app_name in sorted(batch_size_info[batch_size].keys()):
            operations = batch_size_info[batch_size][app_name]
            app_icon = app_icons.get(app_name, '📊')
            display_name = get_display_name(app_name)
            
            html_content += f"""
        <div class="app-group">
            <div class="app-title">{app_icon} {display_name}</div>
            <div class="plot-grid">
"""
            
            for operation in sorted(operations):
                op_icon = op_icons.get(operation, '⚙️')
                filename = f"{app_name}_{operation}_cdf_totallatency_N{batch_size}.html"
                
                html_content += f"""                <div class="plot-card">
                    <div class="icon">{op_icon}</div>
                    <a href="{filename}" target="_blank">{display_name} {operation.title()}</a>
                    <div class="description">CDF of TotalLatency for {display_name} {operation} operations (N={batch_size})</div>
                </div>
"""
            
            html_content += """            </div>
        </div>
"""
        
        html_content += """    </div>
"""
    
    html_content += """
    <footer>
        <p>Generated on November 18, 2025 | All plots are interactive - hover, zoom, and pan to explore the data</p>
        <p>💡 <strong>Tip:</strong> Click on legend items to show/hide configurations | Use the toolbar to download plots as PNG</p>
    </footer>
</body>
</html>
"""
    
    # Write index.html
    index_path = os.path.join(output_dir, 'index.html')
    with open(index_path, 'w') as f:
        f.write(html_content)
    
    print(f"✅ Generated index.html with {len(batch_sizes)} batch size(s) and {sum(len(ops) for ops in batch_size_info[batch_sizes[0]].values())} plot(s)")

def main():
    """Main function to generate CDF plots for all apps."""
    # Get search directory from command line or use current directory
    if len(sys.argv) > 1:
        search_dir = sys.argv[1]
        if not os.path.isabs(search_dir):
            # Convert relative path to absolute
            search_dir = os.path.abspath(search_dir)
    else:
        # Default: script directory (socialGraph root)
        search_dir = os.path.dirname(os.path.abspath(__file__))
    
    print(f"🔍 Searching for timing files in: {search_dir}")
    
    # Find all timing stats files in the search directory
    # Try both patterns: timing_stats_*.csv and *_timing.csv
    # Search both in the directory itself and subdirectories
    pattern1_direct = os.path.join(search_dir, 'timing_stats_*.csv')
    pattern1_recursive = os.path.join(search_dir, '**/timing_stats_*.csv')
    pattern2_direct = os.path.join(search_dir, '*_timing.csv')
    pattern2_recursive = os.path.join(search_dir, '**/*_timing.csv')
    
    files = (glob.glob(pattern1_direct) + 
             glob.glob(pattern1_recursive, recursive=True) +
             glob.glob(pattern2_direct) +
             glob.glob(pattern2_recursive, recursive=True))
    files = list(set(files))  # Remove duplicates
    
    if not files:
        print(f"❌ No timing stats files found in: {search_dir}")
        print(f"   Searched for: timing_stats_*.csv and *_timing.csv")
        return
    
    print(f"📁 Found {len(files)} timing stats files")
    
    # Find all energy summary files
    energy_pattern_direct = os.path.join(search_dir, '*_energy_summary.csv')
    energy_pattern_recursive = os.path.join(search_dir, '**/*_energy_summary.csv')
    
    energy_files = (glob.glob(energy_pattern_direct) + 
                    glob.glob(energy_pattern_recursive, recursive=True))
    energy_files = list(set(energy_files))  # Remove duplicates
    
    print(f"🔋 Found {len(energy_files)} energy summary files")
    
    # Group files by app, operation, and batch size
    app_data = {}  # app_name -> operation -> batch_size -> config -> df
    
    # Filter configurations: drop mt4_pool and all spawn variants
    FILTER_CONFIGS = {'mt4_pool','mt1_pool' , 'mt4_spawn', 'mt8_pool', 'mt16_pool'}
    
    for filepath in files:
        app_name, operation, config, batch_size, df = parse_timing_file(filepath)
        
        if app_name is None:
            print(f"⚠️  Skipping file (couldn't parse): {os.path.basename(filepath)}")
            continue
        
        # Filter out unwanted configurations
        if config in FILTER_CONFIGS:
            print(f"  🚫 Filtered out {app_name}/{operation}/{config} for N={batch_size}")
            continue
        
        if app_name not in app_data:
            app_data[app_name] = {}
        
        if operation not in app_data[app_name]:
            app_data[app_name][operation] = {}
        
        if batch_size not in app_data[app_name][operation]:
            app_data[app_name][operation][batch_size] = {}
        
        app_data[app_name][operation][batch_size][config] = df
        print(f"  ✅ Loaded {app_name}/{operation}/{config} for N={batch_size} ({len(df)} data points)")
    
    # Group energy files by app, operation, and config
    energy_data = {}  # app_name -> operation -> config -> df
    
    for filepath in energy_files:
        app_name, operation, config, df = parse_energy_file(filepath)
        
        if app_name is None:
            print(f"⚠️  Skipping energy file (couldn't parse): {os.path.basename(filepath)}")
            continue
        
        # Filter out unwanted configurations (same as timing data)
        if config in FILTER_CONFIGS:
            print(f"  🚫 Filtered out energy {app_name}/{operation}/{config}")
            continue
        
        if app_name not in energy_data:
            energy_data[app_name] = {}
        
        if operation not in energy_data[app_name]:
            energy_data[app_name][operation] = {}
        
        energy_data[app_name][operation][config] = df
        print(f"  🔋 Loaded energy {app_name}/{operation}/{config}")
    
    # Create output directory for plots in the search directory
    output_dir = os.path.join(search_dir, 'cdf_plots')
    os.makedirs(output_dir, exist_ok=True)
    print(f"\n📊 Generating CDF plots in: {output_dir}\n")
    
    # Collect all unique batch sizes across all apps for speedup plots
    all_batch_sizes = set()
    
    # Generate plots for each app, operation, and batch size
    for app_name in sorted(app_data.keys()):
        print(f"\n{'#'*80}")
        print(f"# PROCESSING APP: {app_name.upper()}")
        print(f"{'#'*80}")
        
        operation_data = app_data[app_name]
        
        for operation in sorted(operation_data.keys()):
            print(f"\n{'='*80}")
            print(f"# PROCESSING OPERATION: {operation.upper()}")
            print(f"{'='*80}")
            
            batch_size_data = operation_data[operation]
            
            for batch_size in sorted(batch_size_data.keys()):
                all_batch_sizes.add(batch_size)
                data_dict = batch_size_data[batch_size]
                print(f"\n{'-'*80}")
                print(f"{app_name}/{operation}: Processing N={batch_size} ({len(data_dict)} configurations)")
                print(f"{'-'*80}")
                
                # Plot both PDF and interactive HTML for TotalLatency
                plot_cdf_for_batch_size(app_name, operation, batch_size, data_dict, 'TotalLatency', output_dir)
                plot_cdf_for_batch_size_interactive(app_name, operation, batch_size, data_dict, 'TotalLatency', output_dir)
                
                # Print statistics for TotalLatency
                print_statistics(app_name, operation, batch_size, data_dict, 'TotalLatency')
    
    # Generate speedup plots grouped by app for each batch size
    print(f"\n{'#'*80}")
    print(f"# GENERATING SPEEDUP PLOTS")
    print(f"{'#'*80}")
    
    for batch_size in sorted(all_batch_sizes):
        print(f"\n{'-'*80}")
        print(f"Generating speedup plot for N={batch_size}")
        print(f"{'-'*80}")
        plot_speedup_grouped_by_app(app_data, batch_size, 'TotalLatency', output_dir)
    
    # Generate throughput plots grouped by app for each batch size
    print(f"\n{'#'*80}")
    print(f"# GENERATING THROUGHPUT PLOTS")
    print(f"{'#'*80}")
    
    for batch_size in sorted(all_batch_sizes):
        print(f"\n{'-'*80}")
        print(f"Generating throughput plot for N={batch_size}")
        print(f"{'-'*80}")
        plot_throughput_grouped_by_app(app_data, batch_size, 'TotalLatency', output_dir)
    
    # Generate combined CDF plots with all apps as subplots for each batch size
    print(f"\n{'#'*80}")
    print(f"# GENERATING COMBINED CDF PLOTS (ALL APPS AS SUBPLOTS)")
    print(f"{'#'*80}")
    
    for batch_size in sorted(all_batch_sizes):
        print(f"\n{'-'*80}")
        print(f"Generating combined CDF plot for N={batch_size}")
        print(f"{'-'*80}")
        plot_all_apps_cdf_subplots(app_data, batch_size, 'TotalLatency', output_dir)
        plot_all_apps_cdf_subplots(app_data, batch_size, 'ExecutionTime', output_dir)
        plot_all_apps_cdf_subplots(app_data, batch_size, 'QueueingDelay', output_dir)
    
    # Generate normalized energy plots if energy data is available
    if energy_data:
        print(f"\n{'#'*80}")
        print(f"# GENERATING NORMALIZED ENERGY PLOTS")
        print(f"{'#'*80}")
        print(f"\n{'-'*80}")
        print(f"Generating normalized energy plot")
        print(f"{'-'*80}")
        plot_normalized_energy_grouped_by_app(energy_data, 'TotalCore_J', output_dir)
    else:
        print(f"\n⚠️  No energy data found, skipping energy plots")
    
    # Generate dynamic index.html
    generate_index_html(output_dir, app_data, sorted(all_batch_sizes))
    
    print(f"\n{'='*80}")
    print(f"✅ All CDF, speedup, throughput, and energy plots generated successfully!")
    print(f"📁 Plots saved in: {output_dir}")
    print(f"📊 Apps processed: {', '.join(sorted(app_data.keys()))}")
    print(f"🌐 Open index.html in your browser to view all interactive plots")
    print(f"{'='*80}")

if __name__ == '__main__':
    main()
