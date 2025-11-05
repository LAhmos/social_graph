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

CXXFLAGS := -O3
ISPCFLAGS := --target=avx2-i32x8 -O3 --PIC

# =========================================================
# Build rules
# =========================================================

all: $(TARGET)

$(ISPC_OBJ): $(ISPC_SRC)
	$(ISPC) $(ISPC_SRC) $(ISPCFLAGS) -h $(ISPC_HDR) -o $(ISPC_OBJ)

$(TARGET): $(CPP_SRC) $(ISPC_OBJ)
	$(CXX) $(CXXFLAGS) $(CPP_SRC) $(ISPC_OBJ) -o $(TARGET)

clean:
	rm -f $(TARGET) $(ISPC_OBJ) $(ISPC_HDR)

run: $(TARGET)
	./$(TARGET)
