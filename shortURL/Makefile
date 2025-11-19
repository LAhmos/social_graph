# =========================================================
# Simple ISPC + C++ + Multithreaded build
# =========================================================

# --- Configuration ---
CXX      := g++
ISPC     := ispc
TARGET   := simple
ISPC_SRC := simple.ispc
CPP_SRC  := simple.cpp
ISPC_OBJ := simple_ispc.o
ISPC_HDR := simple_ispc.h

CXXFLAGS := -O3 -std=c++11 -pthread
ISPCFLAGS := --target=avx2-i32x8 -O3 --PIC

# =========================================================
# Build rules
# =========================================================

all: $(TARGET)

$(ISPC_OBJ): $(ISPC_SRC)
	$(ISPC) $(ISPC_SRC) $(ISPCFLAGS) -h $(ISPC_HDR) -o $(ISPC_OBJ)

$(TARGET): $(CPP_SRC) $(ISPC_OBJ) simple_mt.h ../ThreadPool.h
	$(CXX) $(CXXFLAGS) $(CPP_SRC) $(ISPC_OBJ) -o $(TARGET)

clean:
	rm -f $(TARGET) $(ISPC_OBJ) $(ISPC_HDR) *.csv

run: $(TARGET)
	./$(TARGET)

run-ispc: $(TARGET)
	./$(TARGET) ispc

run-mt: $(TARGET)
	./$(TARGET) mt

benchmark-ispc: $(TARGET)
	./$(TARGET) ispc 100 100

benchmark-mt: $(TARGET)
	./$(TARGET) mt 8 100 100

.PHONY: all clean run run-ispc run-mt benchmark-ispc benchmark-mt
