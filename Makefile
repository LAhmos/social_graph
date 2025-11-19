# =============================
# Main Makefile for Social Graph Applications
# =============================

CXX       := g++
CXXFLAGS  := -std=c++17 -O3 -march=native -pthread -Wall
LDFLAGS   := -pthread

# ThreadPool test

# Subdirectories containing apps
APPS := post shortURL text uniqueID user userTag

# =============================
# Main targets
# =============================

all: $(TEST_TARGET) apps

# Build the threadpool test
$(TEST_TARGET): $(TEST_SRC) ThreadPool.h
	$(CXX) $(CXXFLAGS) $(TEST_SRC) $(LDFLAGS) -o $(TEST_TARGET)

# Build all apps in subdirectories
apps:
	@echo "Building all applications..."
	@for dir in $(APPS); do \
		echo "Building in $$dir..."; \
		$(MAKE) -C $$dir all || exit 1; \
	done

# =============================
# Individual app targets
# =============================

post:
	$(MAKE) -C post all

shortURL:
	$(MAKE) -C shortURL all

text:
	$(MAKE) -C text all

uniqueID:
	$(MAKE) -C uniqueID all

user:
	$(MAKE) -C user all

userTag:
	$(MAKE) -C userTag all

# =============================
# Run targets
# =============================

# Run with default thread counts (1, 2, 4, 8, 16)
run: $(TEST_TARGET)
	./$(TEST_TARGET)

# Run with custom thread counts
# Usage: make run-custom THREADS="1 2 4 6 8 12 16 24 32"
run-custom: $(TEST_TARGET)
	./$(TEST_TARGET) $(THREADS)

# Run quick test with fewer thread counts
run-quick: $(TEST_TARGET)
	./$(TEST_TARGET) 1 2 4 8

# =============================
# Clean targets
# =============================

clean: clean-apps
	rm -f $(TEST_TARGET)

clean-apps:
	@echo "Cleaning all applications..."
	@for dir in $(APPS); do \
		echo "Cleaning in $$dir..."; \
		$(MAKE) -C $$dir clean || true; \
	done

.PHONY: all apps post shortURL text uniqueID user userTag run run-custom run-quick clean clean-apps
