# =========================================================
# Simple ISPC + C++ build example
# =========================================================

# --- Configuration ---
CXX      := g++
ISPC     := ispc
TARGET   := simple
ISPC_SRC := simple.ispc
ISPC_OPT_SRC := simple_optimized.ispc
CPP_SRC  := simple.cpp
ISPC_OBJ := simple_ispc.o
ISPC_OPT_OBJ := simple_optimized_ispc.o
ISPC_HDR := simple_ispc.h
ISPC_OPT_HDR := simple_optimized_ispc.h

CXXFLAGS := -O3 -pthread
ISPCFLAGS := --target=avx2-i32x8 -O3 --PIC

# =========================================================
# Build rules
# =========================================================

all: $(TARGET)

$(ISPC_OBJ): $(ISPC_SRC)
	$(ISPC) $(ISPC_SRC) $(ISPCFLAGS) -h $(ISPC_HDR) -o $(ISPC_OBJ)

$(ISPC_OPT_OBJ): $(ISPC_OPT_SRC)
	$(ISPC) $(ISPC_OPT_SRC) $(ISPCFLAGS) -h $(ISPC_OPT_HDR) -o $(ISPC_OPT_OBJ)

$(TARGET): $(CPP_SRC) $(ISPC_OBJ) $(ISPC_OPT_OBJ)
	$(CXX) $(CXXFLAGS) $(CPP_SRC) $(ISPC_OBJ) $(ISPC_OPT_OBJ) -o $(TARGET)

clean:
	rm -f $(TARGET) $(ISPC_OBJ) $(ISPC_HDR) $(ISPC_OPT_OBJ) $(ISPC_OPT_HDR)

run: $(TARGET)
	./$(TARGET)

run-ispc: $(TARGET)
	./$(TARGET) ispc

run-ispc-opt: $(TARGET)
	./$(TARGET) ispc-opt

run-mt: $(TARGET)
	./$(TARGET) mt

run-mt-8: $(TARGET)
	./$(TARGET) mt 8

run-1k: $(TARGET)
	@echo "=== Testing with 1000 IDs ==="
	@echo "ISPC:"
	@./$(TARGET) ispc 1000 | grep -E "(Batch completed|Throughput)"
	@echo ""
	@echo "Multithreaded (8 threads):"
	@./$(TARGET) mt 8 1000 | grep -E "(Batch completed|Throughput)"

run-2k: $(TARGET)
	@echo "=== Testing with 2000 IDs ==="
	@echo "ISPC:"
	@./$(TARGET) ispc 2000 | grep -E "(Batch completed|Throughput)"
	@echo ""
	@echo "Multithreaded (8 threads):"
	@./$(TARGET) mt 8 2000 | grep -E "(Batch completed|Throughput)"

benchmark: $(TARGET)
	./benchmark.sh

compare-all: $(TARGET)
	@echo "╔═══════════════════════════════════════════════════════════════════╗"
	@echo "║      Quick Comparison: ISPC vs Multithreaded                      ║"
	@echo "╚═══════════════════════════════════════════════════════════════════╝"
	@echo ""
	@echo "N=48 (Small batch):"
	@./$(TARGET) ispc 48 | grep -E "(Batch completed|Throughput)"
	@./$(TARGET) mt 8 48 | grep -E "(Batch completed|Throughput)"
	@echo ""
	@echo "N=1000 (Medium batch):"
	@./$(TARGET) ispc 1000 | grep -E "(Batch completed|Throughput)"
	@./$(TARGET) mt 8 1000 | grep -E "(Batch completed|Throughput)"
	@echo ""
	@echo "N=2000 (Large batch):"
	@./$(TARGET) ispc 2000 | grep -E "(Batch completed|Throughput)"
	@./$(TARGET) mt 8 2000 | grep -E "(Batch completed|Throughput)"

help:
	@echo "Available targets:"
	@echo "  make            - Build the project"
	@echo "  make clean      - Remove build artifacts"
	@echo "  make run        - Run with default (ISPC, N=48)"
	@echo "  make run-ispc   - Run with original ISPC SIMD implementation"
	@echo "  make run-ispc-opt - Run with optimized ISPC SIMD implementation"
	@echo "  make run-mt     - Run with multithreaded (auto threads)"
	@echo "  make run-mt-8   - Run with multithreaded (8 threads)"
	@echo "  make run-1k     - Compare ISPC vs MT with 1000 IDs"
	@echo "  make run-2k     - Compare ISPC vs MT with 2000 IDs"
	@echo "  make compare-all- Quick comparison across all batch sizes"
	@echo "  make benchmark  - Run comprehensive performance comparison"
	@echo "  make help       - Show this help message"
	@echo ""
	@echo "Manual usage:"
	@echo "  ./simple [ispc|ispc-opt|mt] [threads] [batch_size]"
	@echo "  Examples:"
	@echo "    ./simple ispc 1000          # Original ISPC"
	@echo "    ./simple ispc-opt 1000      # Optimized ISPC (3x faster)"
	@echo "    ./simple mt 8 2000          # Multithreading (best)"
