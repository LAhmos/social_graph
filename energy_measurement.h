/*
  Energy Measurement Header
  Copyright (c) 2025
  
  A reusable header for measuring energy consumption using Intel RAPL.
  Supports per-kernel measurements with averaging across multiple iterations.
*/

#ifndef ENERGY_MEASUREMENT_H
#define ENERGY_MEASUREMENT_H

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/time.h>
#include <iostream>
#include <vector>
#include <string>
#include <algorithm>
#include <cmath>
#include <iomanip>

// RAPL energy file paths
#define RAPL_PKG_PATH  "/sys/class/powercap/intel-rapl:0/energy_uj"
#define RAPL_CORE_PATH "/sys/class/powercap/intel-rapl:0:0/energy_uj"
#define RAPL_DRAM_PATH "/sys/class/powercap/intel-rapl:0:1/energy_uj"

// Energy measurement structure
struct EnergyMeasurement {
    long long pkg_uj;   // Package energy in microjoules
    long long core_uj;  // Core energy in microjoules
    long long dram_uj;  // DRAM energy in microjoules
    double time_sec;    // Execution time in seconds
};

// Statistics structure for accumulated measurements
struct EnergyStats {
    std::string kernel_name;
    std::vector<double> pkg_j;   // Package energy in joules
    std::vector<double> core_j;  // Core energy in joules
    std::vector<double> dram_j;  // DRAM energy in joules
    std::vector<double> time_s;  // Time in seconds
    std::vector<double> power_w; // Power in watts
    
    // Computed statistics
    double avg_pkg_j;
    double avg_core_j;
    double avg_dram_j;
    double avg_time_s;
    double avg_power_w;
    double stddev_pkg_j;
    double stddev_core_j;
    double stddev_dram_j;
    double min_pkg_j;
    double max_pkg_j;
    
    EnergyStats(const std::string& name) : kernel_name(name),
        avg_pkg_j(0), avg_core_j(0), avg_dram_j(0), avg_time_s(0), avg_power_w(0),
        stddev_pkg_j(0), stddev_core_j(0), stddev_dram_j(0),
        min_pkg_j(1e9), max_pkg_j(0) {}
};

class EnergyMonitor {
private:
    bool rapl_available;
    
    // Helper function to read RAPL energy counter
    static long long read_rapl_energy(const char* path) {
        FILE* f = fopen(path, "r");
        if (!f) {
            return -1;  // File not available
        }
        long long val;
        int ret = fscanf(f, "%lld", &val);
        fclose(f);
        if (ret != 1) return -1;
        return val;
    }
    
    // Helper to get current time
    static double get_time_sec() {
        struct timeval tv;
        gettimeofday(&tv, NULL);
        return tv.tv_sec + tv.tv_usec / 1e6;
    }
    
    // Handle RAPL counter wraparound
    static long long handle_wraparound(long long start, long long end) {
        // RAPL counters are typically 32-bit and wraparound
        const long long MAX_ENERGY_UJ = 262143328850ULL;  // Typical max value
        if (end < start) {
            return (MAX_ENERGY_UJ - start) + end;
        }
        return end - start;
    }

public:
    EnergyMonitor() {
        // Check if RAPL is available
        rapl_available = (read_rapl_energy(RAPL_PKG_PATH) >= 0);
        if (!rapl_available) {
            fprintf(stderr, "⚠️  Warning: RAPL energy counters not available. "
                           "Energy measurements will be disabled.\n");
            fprintf(stderr, "   Run with sudo or check permissions for /sys/class/powercap/\n");
        }
    }
    
    bool is_available() const { return rapl_available; }
    
    // Start energy measurement
    EnergyMeasurement start() {
        EnergyMeasurement m = {0, 0, 0, 0.0};
        if (!rapl_available) return m;
        
        m.pkg_uj = read_rapl_energy(RAPL_PKG_PATH);
        m.core_uj = read_rapl_energy(RAPL_CORE_PATH);
        m.dram_uj = read_rapl_energy(RAPL_DRAM_PATH);
        m.time_sec = get_time_sec();
        return m;
    }
    
    // End energy measurement and return delta
    EnergyMeasurement end(const EnergyMeasurement& start_m) {
        EnergyMeasurement end_m = {0, 0, 0, 0.0};
        if (!rapl_available) return end_m;
        
        end_m.pkg_uj = read_rapl_energy(RAPL_PKG_PATH);
        end_m.core_uj = read_rapl_energy(RAPL_CORE_PATH);
        end_m.dram_uj = read_rapl_energy(RAPL_DRAM_PATH);
        end_m.time_sec = get_time_sec();
        
        // Calculate deltas with wraparound handling
        EnergyMeasurement delta;
        delta.pkg_uj = handle_wraparound(start_m.pkg_uj, end_m.pkg_uj);
        delta.core_uj = handle_wraparound(start_m.core_uj, end_m.core_uj);
        delta.dram_uj = handle_wraparound(start_m.dram_uj, end_m.dram_uj);
        delta.time_sec = end_m.time_sec - start_m.time_sec;
        
        return delta;
    }
    
    // Add measurement to statistics
    static void add_measurement(EnergyStats& stats, const EnergyMeasurement& m) {
        double pkg_j = m.pkg_uj / 1e6;
        double core_j = m.core_uj / 1e6;
        double dram_j = m.dram_uj / 1e6;
        double time_s = m.time_sec;
        double power_w = (time_s > 0) ? (pkg_j / time_s) : 0.0;
        
        stats.pkg_j.push_back(pkg_j);
        stats.core_j.push_back(core_j);
        stats.dram_j.push_back(dram_j);
        stats.time_s.push_back(time_s);
        stats.power_w.push_back(power_w);
    }
    
    // Compute statistics
    static void compute_stats(EnergyStats& stats) {
        if (stats.pkg_j.empty()) return;
        
        size_t n = stats.pkg_j.size();
        
        // Compute averages
        stats.avg_pkg_j = 0;
        stats.avg_core_j = 0;
        stats.avg_dram_j = 0;
        stats.avg_time_s = 0;
        stats.avg_power_w = 0;
        
        for (size_t i = 0; i < n; i++) {
            stats.avg_pkg_j += stats.pkg_j[i];
            stats.avg_core_j += stats.core_j[i];
            stats.avg_dram_j += stats.dram_j[i];
            stats.avg_time_s += stats.time_s[i];
            stats.avg_power_w += stats.power_w[i];
        }
        
        stats.avg_pkg_j /= n;
        stats.avg_core_j /= n;
        stats.avg_dram_j /= n;
        stats.avg_time_s /= n;
        stats.avg_power_w /= n;
        
        // Compute standard deviations
        double var_pkg = 0, var_core = 0, var_dram = 0;
        for (size_t i = 0; i < n; i++) {
            var_pkg += (stats.pkg_j[i] - stats.avg_pkg_j) * (stats.pkg_j[i] - stats.avg_pkg_j);
            var_core += (stats.core_j[i] - stats.avg_core_j) * (stats.core_j[i] - stats.avg_core_j);
            var_dram += (stats.dram_j[i] - stats.avg_dram_j) * (stats.dram_j[i] - stats.avg_dram_j);
        }
        
        stats.stddev_pkg_j = std::sqrt(var_pkg / n);
        stats.stddev_core_j = std::sqrt(var_core / n);
        stats.stddev_dram_j = std::sqrt(var_dram / n);
        
        // Compute min/max
        stats.min_pkg_j = *std::min_element(stats.pkg_j.begin(), stats.pkg_j.end());
        stats.max_pkg_j = *std::max_element(stats.pkg_j.begin(), stats.pkg_j.end());
    }
    
    // Print statistics
    static void print_stats(const EnergyStats& stats) {
        std::cout << "\n╔══════════════════════════════════════════════════════════════════╗\n";
        std::cout << "║  ENERGY STATISTICS - " << stats.kernel_name 
                  << std::string(42 - stats.kernel_name.length(), ' ') << "║\n";
        std::cout << "╠══════════════════════════════════════════════════════════════════╣\n";
        std::cout << "║  Samples: " << stats.pkg_j.size() 
                  << std::string(56 - std::to_string(stats.pkg_j.size()).length(), ' ') << "║\n";
        std::cout << "╚══════════════════════════════════════════════════════════════════╝\n\n";
        
        std::cout << std::fixed << std::setprecision(6);
        std::cout << "ENERGY CONSUMPTION:\n";
        std::cout << "  Package:  " << std::setw(12) << stats.avg_pkg_j << " ± " 
                  << std::setw(10) << stats.stddev_pkg_j << " J  "
                  << "(min: " << stats.min_pkg_j << " J, max: " << stats.max_pkg_j << " J)\n";
        std::cout << "  Core:     " << std::setw(12) << stats.avg_core_j << " ± " 
                  << std::setw(10) << stats.stddev_core_j << " J\n";
        std::cout << "  DRAM:     " << std::setw(12) << stats.avg_dram_j << " ± " 
                  << std::setw(10) << stats.stddev_dram_j << " J\n\n";
        
        std::cout << "POWER:\n";
        std::cout << "  Average:  " << std::setw(12) << stats.avg_power_w << " W\n";
        std::cout << "  Duration: " << std::setw(12) << stats.avg_time_s << " s\n\n";
        
        // Calculate coefficient of variation
        double cv_pkg = (stats.avg_pkg_j > 0) ? (stats.stddev_pkg_j / stats.avg_pkg_j * 100.0) : 0.0;
        std::cout << "MEASUREMENT QUALITY:\n";
        std::cout << "  CV (Package): " << std::fixed << std::setprecision(2) << cv_pkg << " %";
        if (cv_pkg < 2.0) {
            std::cout << "  ✅ EXCELLENT\n";
        } else if (cv_pkg < 5.0) {
            std::cout << "  ✅ GOOD\n";
        } else if (cv_pkg < 10.0) {
            std::cout << "  ⚠️  MODERATE\n";
        } else {
            std::cout << "  ❌ NOISY\n";
        }
        std::cout << "\n";
    }
    
    // Export to CSV
    static void export_csv(const std::vector<EnergyStats>& all_stats, const std::string& filename) {
        FILE* f = fopen(filename.c_str(), "w");
        if (!f) {
            fprintf(stderr, "❌ Failed to create CSV file: %s\n", filename.c_str());
            return;
        }
        
        // Write header
        fprintf(f, "Kernel,Iteration,PackageEnergy_J,CoreEnergy_J,DRAMEnergy_J,Time_s,Power_W\n");
        
        // Write data
        for (const auto& stats : all_stats) {
            for (size_t i = 0; i < stats.pkg_j.size(); i++) {
                fprintf(f, "%s,%zu,%.6f,%.6f,%.6f,%.6f,%.6f\n",
                        stats.kernel_name.c_str(), i,
                        stats.pkg_j[i], stats.core_j[i], stats.dram_j[i],
                        stats.time_s[i], stats.power_w[i]);
            }
        }
        
        fclose(f);
        std::cout << "✅ Energy data exported to '" << filename << "'\n";
    }
    
    // Export summary statistics to CSV
    static void export_summary_csv(const std::vector<EnergyStats>& all_stats, const std::string& filename) {
        FILE* f = fopen(filename.c_str(), "w");
        if (!f) {
            fprintf(stderr, "❌ Failed to create CSV file: %s\n", filename.c_str());
            return;
        }
        
        // Write header
        fprintf(f, "Kernel,Samples,AvgPackage_J,StdDevPackage_J,AvgCore_J,StdDevCore_J,"
                   "AvgDRAM_J,StdDevDRAM_J,AvgTime_s,AvgPower_W,MinPackage_J,MaxPackage_J,CV_Percent\n");
        
        // Write data
        for (const auto& stats : all_stats) {
            double cv = (stats.avg_pkg_j > 0) ? (stats.stddev_pkg_j / stats.avg_pkg_j * 100.0) : 0.0;
            fprintf(f, "%s,%zu,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.6f,%.2f\n",
                    stats.kernel_name.c_str(), stats.pkg_j.size(),
                    stats.avg_pkg_j, stats.stddev_pkg_j,
                    stats.avg_core_j, stats.stddev_core_j,
                    stats.avg_dram_j, stats.stddev_dram_j,
                    stats.avg_time_s, stats.avg_power_w,
                    stats.min_pkg_j, stats.max_pkg_j, cv);
        }
        
        fclose(f);
        std::cout << "✅ Energy summary exported to '" << filename << "'\n";
    }
};

#endif // ENERGY_MEASUREMENT_H
