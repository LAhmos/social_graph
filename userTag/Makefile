# =========================================================
# Simple ISPC + C++ build example
# =========================================================

# --- Configuration ---
CXX      := g++
ISPC     := ispc
TARGET   := simple
TARGET_MT := simple_mt
ISPC_SRC := simple.ispc
CPP_SRC  := simple.cpp
ISPC_OBJ := simple_ispc.o
ISPC_HDR := simple_ispc.h

CXXFLAGS := -O3 -pthread
ISPCFLAGS := --target=avx2-i32x8 -O3 --PIC

# =========================================================
# Build rules
# =========================================================

all: $(TARGET)

$(ISPC_OBJ): $(ISPC_SRC)
	$(ISPC) $(ISPC_SRC) $(ISPCFLAGS) -h $(ISPC_HDR) -o $(ISPC_OBJ)

$(TARGET): $(CPP_SRC) $(ISPC_OBJ)
	$(CXX) $(CXXFLAGS) $(CPP_SRC) $(ISPC_OBJ) -o $(TARGET)

# Build multithreaded version (includes both ISPC and MT support)
simple_mt: $(CPP_SRC) $(ISPC_OBJ) simple_mt.h ../ThreadPool.h
	$(CXX) $(CXXFLAGS) $(CPP_SRC) $(ISPC_OBJ) -o $(TARGET_MT)

clean:
	rm -f $(TARGET) $(TARGET_MT) $(ISPC_OBJ) $(ISPC_HDR) *.csv

run: $(TARGET)
	./$(TARGET)

run-ispc: $(TARGET)
	./$(TARGET)

run-mt: simple_mt
	./$(TARGET_MT)

.PHONY: all clean run run-ispc run-mt simple_mt
