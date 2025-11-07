# =========================================================
# Simple ISPC + C++ build example
# =========================================================

# --- Configuration ---
CXX      := g++
ISPC     := ispc
TARGET   := simple
TARGET_MT := benchmark_multithread
ISPC_SRC := simple.ispc
CPP_SRC  := simple.cpp
CPP_MT_SRC := benchmark_multithread.cpp
ISPC_OBJ := simple_ispc.o
ISPC_HDR := simple_ispc.h

CXXFLAGS := -O3 -pthread
ISPCFLAGS := --target=avx2-i32x8 -O3 --PIC

# =========================================================
# Build rules
# =========================================================

all: $(TARGET) $(TARGET_MT)

$(ISPC_OBJ): $(ISPC_SRC)
	$(ISPC) $(ISPC_SRC) $(ISPCFLAGS) -h $(ISPC_HDR) -o $(ISPC_OBJ)

$(TARGET): $(CPP_SRC) $(ISPC_OBJ)
	$(CXX) $(CXXFLAGS) $(CPP_SRC) $(ISPC_OBJ) -o $(TARGET)

$(TARGET_MT): $(CPP_MT_SRC)
	$(CXX) $(CXXFLAGS) $(CPP_MT_SRC) -o $(TARGET_MT)

clean:
	rm -f $(TARGET) $(TARGET_MT) $(ISPC_OBJ) $(ISPC_HDR)

run: $(TARGET)
	./$(TARGET)

run-mt: $(TARGET_MT)
	./$(TARGET_MT)

compare: $(TARGET) $(TARGET_MT)
	@echo "=== Running ISPC version ==="
	./$(TARGET)
	@echo ""
	@echo "=== Running Multithreaded version ==="
	./$(TARGET_MT)

test: $(TARGET) $(TARGET_MT)
	./quick_test.sh

detailed: $(TARGET) $(TARGET_MT)
	./detailed_comparison.sh

.PHONY: help
help:
	@echo "╔══════════════════════════════════════════════════════════════════╗"
	@echo "║        ISPC vs Multithreaded Performance Comparison              ║"
	@echo "╚══════════════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "Available targets:"
	@echo "  make all          - Build both ISPC and multithreaded versions"
	@echo "  make simple       - Build ISPC version only"
	@echo "  make $(TARGET_MT) - Build multithreaded version only"
	@echo "  make clean        - Remove all build artifacts"
	@echo ""
	@echo "Running:"
	@echo "  make run          - Run ISPC version (N=48)"
	@echo "  make run-mt       - Run multithreaded version (default config)"
	@echo "  make compare      - Run both versions back-to-back"
	@echo "  make test         - Quick performance test"
	@echo "  make detailed     - Detailed performance analysis"
	@echo ""
	@echo "Manual execution:"
	@echo "  ./simple                        - ISPC version"
	@echo "  ./benchmark_multithread [N] [T] - Multithreaded (N IDs, T threads)"
	@echo ""
	@echo "Examples:"
	@echo "  ./benchmark_multithread 768 8   - 768 IDs with 8 threads"
	@echo "  ./benchmark_multithread 1000 16 - 1000 IDs with 16 threads"
	@echo ""
	@echo "Documentation:"
	@echo "  README_COMPARISON.md - Full comparison documentation"
	@echo "  SUMMARY.md          - Quick reference guide"
