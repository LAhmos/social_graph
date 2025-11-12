# =========================================================
# Text Processing - ISPC + C++ build
# =========================================================

# --- Configuration ---
CXX      := g++
ISPC     := ../../ispc-v1.28.2-linux/bin/ispc
TARGET   := text
ISPC_TARGET := simple
ISPC_SRC := simple.ispc
CPP_SRC  := simple.cpp
ISPC_OBJ := simple_ispc.o
ISPC_HDR := simple_ispc.h

CXXFLAGS := -O3 -std=c++17
ISPCFLAGS := --target=avx2-i32x8 -O3 --pic

# =========================================================
# Build rules
# =========================================================

all: $(TARGET) $(ISPC_TARGET)

# Original text target (without ISPC)
$(TARGET): text.cpp
	$(CXX) -fopenmp -g -std=c++17 -o $@ $^

# ISPC-based target
$(ISPC_OBJ): $(ISPC_SRC)
	$(ISPC) $(ISPC_SRC) $(ISPCFLAGS) -h $(ISPC_HDR) -o $(ISPC_OBJ)

$(ISPC_TARGET): $(CPP_SRC) $(ISPC_OBJ) text_kernel.cpp
	$(CXX) $(CXXFLAGS) $(CPP_SRC) text_kernel.cpp $(ISPC_OBJ) -o $(ISPC_TARGET)

run: $(TARGET)
	./$(TARGET) usatoday_facebook_statuses.csv 10

run-ispc: $(ISPC_TARGET)
	./$(ISPC_TARGET) usatoday_facebook_statuses.csv 128

clean: 
	rm -f $(TARGET) $(ISPC_TARGET) $(ISPC_OBJ) $(ISPC_HDR) *.o
