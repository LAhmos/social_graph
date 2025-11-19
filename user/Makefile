# =========================================================
# Simple ISPC + C++ build example
# =========================================================

# --- Configuration ---
CXX      := g++
ISPC     := ispc
TARGET   := simple
ISPC_SRC := simple.ispc
CPP_SRC  := simple.cpp
ISPC_OBJ := simple_ispc.o
ISPC_HDR := simple_ispc.h
MT_HDR   := simple_mt.h

CXXFLAGS := -O3 -std=c++11 -pthread
ISPCFLAGS := --target=avx2-i32x8 -O3 --PIC

# =========================================================
# Build rules
# =========================================================

all: $(TARGET)

$(ISPC_OBJ): $(ISPC_SRC)
	$(ISPC) $(ISPC_SRC) $(ISPCFLAGS) -h $(ISPC_HDR) -o $(ISPC_OBJ)

$(TARGET): $(CPP_SRC) $(ISPC_OBJ) $(MT_HDR)
	$(CXX) $(CXXFLAGS) $(CPP_SRC) $(ISPC_OBJ) -o $(TARGET)

clean:
	rm -f $(TARGET) $(ISPC_OBJ) $(ISPC_HDR) *.csv

run: $(TARGET)
	./$(TARGET)

run_ispc: $(TARGET)
	./$(TARGET) ispc

run_mt: $(TARGET)
	./$(TARGET) mt

run_mt8: $(TARGET)
	./$(TARGET) mt 8

# Benchmark targets
bench_ispc: $(TARGET)
	./$(TARGET) ispc 100

bench_mt: $(TARGET)
	./$(TARGET) mt 8 100
