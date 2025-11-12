# =========================================================
# Simple ISPC + C++ build example
# =========================================================

# --- Configuration ---
CXX      := g++
ISPC     := ispc
TARGET   := simple
TARGET_PTHREAD := simple_pthread
ISPC_SRC := simple.ispc
CPP_SRC  := simple.cpp
CPP_PTHREAD_SRC := simple_pthread.cpp
ISPC_OBJ := simple_ispc.o
ISPC_HDR := simple_ispc.h

CXXFLAGS := -O3
CXXFLAGS_PTHREAD := -O3 -pthread
ISPCFLAGS := --target=avx2-i32x8 -O3 --PIC

# =========================================================
# Build rules
# =========================================================

all: $(TARGET) $(TARGET_PTHREAD)

$(ISPC_OBJ): $(ISPC_SRC)
	$(ISPC) $(ISPC_SRC) $(ISPCFLAGS) -h $(ISPC_HDR) -o $(ISPC_OBJ)

$(TARGET): $(CPP_SRC) $(ISPC_OBJ)
	$(CXX) $(CXXFLAGS) $(CPP_SRC) $(ISPC_OBJ) -o $(TARGET)

$(TARGET_PTHREAD): $(CPP_PTHREAD_SRC)
	$(CXX) $(CXXFLAGS_PTHREAD) $(CPP_PTHREAD_SRC) -o $(TARGET_PTHREAD)

clean:
	rm -f $(TARGET) $(TARGET_PTHREAD) $(ISPC_OBJ) $(ISPC_HDR)

run: $(TARGET)
	./$(TARGET)

run_pthread: $(TARGET_PTHREAD)
	./$(TARGET_PTHREAD)

compare: $(TARGET) $(TARGET_PTHREAD)
	@echo "Running ISPC version..."
	./$(TARGET)
	@echo ""
	@echo "Running pthread version..."
	./$(TARGET_PTHREAD)
	@echo ""
	@echo "Comparison complete. Check timing_stats.csv and timing_stats_pthread.csv"
