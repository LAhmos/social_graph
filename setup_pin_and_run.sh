#!/bin/bash

# Script to download PIN, apply modifications to insmix.cpp, compile it, and run
# This ensures a reproducible setup for instruction counting with SIMD breakdown

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
CYAN='\033[0;36m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  PIN Tool Setup and Execution Script                     ║${NC}"
echo -e "${BLUE}║  Downloads PIN, modifies insmix.cpp, compiles, and runs  ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""

# Configuration
PIN_VERSION="pin-external-4.0-99633-g5ca9893f2-gcc-linux"
PIN_URL="https://software.intel.com/sites/landingpage/pintool/downloads/${PIN_VERSION}.tar.gz"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORK_DIR="$(dirname "${SCRIPT_DIR}")"
PIN_DIR="${WORK_DIR}/${PIN_VERSION}"
INSMIX_DIR="${PIN_DIR}/source/tools/Insmix"
INSMIX_CPP="${INSMIX_DIR}/insmix.cpp"
FUNCTION_LIST="${SCRIPT_DIR}/functions_to_track.txt"

# Step 1: Check if PIN is already downloaded
echo -e "${CYAN}Step 1: Checking for existing PIN installation...${NC}"
if [ -d "${PIN_DIR}" ]; then
    echo -e "${YELLOW}PIN directory already exists at ${PIN_DIR}${NC}"
    echo -e "${YELLOW}Skipping download. To re-download, remove the directory first.${NC}"
else
    echo -e "${GREEN}Downloading PIN from Intel...${NC}"
    cd "${WORK_DIR}"
    
    # Download PIN
    if ! wget -q --show-progress "${PIN_URL}" -O "${PIN_VERSION}.tar.gz"; then
        echo -e "${RED}Error: Failed to download PIN${NC}"
        echo -e "${YELLOW}Note: The URL may have changed. Please check Intel PIN website.${NC}"
        echo -e "${YELLOW}Current URL: ${PIN_URL}${NC}"
        exit 1
    fi
    
    # Extract
    echo -e "${GREEN}Extracting PIN...${NC}"
    tar -xzf "${PIN_VERSION}.tar.gz"
    rm "${PIN_VERSION}.tar.gz"
    
    echo -e "${GREEN}✓ PIN downloaded and extracted${NC}"
fi

# Step 2: Copy modified insmix files from repo to PIN installation
echo ""
echo -e "${CYAN}Step 2: Copying modified insmix files to PIN installation...${NC}"

REPO_INSMIX="${SCRIPT_DIR}/insmix.cpp"
REPO_MAKEFILE="${SCRIPT_DIR}/makefile"
REPO_MAKEFILE_RULES="${SCRIPT_DIR}/makefile.rules"

if [ ! -f "${REPO_INSMIX}" ]; then
    echo -e "${RED}Error: insmix.cpp not found in repo at ${REPO_INSMIX}${NC}"
    echo -e "${YELLOW}Please ensure insmix.cpp is in the social_graph directory${NC}"
    exit 1
fi

# Backup original files if they exist
if [ -f "${INSMIX_CPP}" ]; then
    echo -e "${YELLOW}Backing up original insmix.cpp...${NC}"
    cp "${INSMIX_CPP}" "${INSMIX_CPP}.original.backup"
fi

# Copy modified files from repo to PIN installation
echo -e "${GREEN}Copying insmix.cpp from repo...${NC}"
cp "${REPO_INSMIX}" "${INSMIX_CPP}"

if [ -f "${REPO_MAKEFILE}" ]; then
    echo -e "${GREEN}Copying makefile from repo...${NC}"
    [ -f "${INSMIX_DIR}/makefile" ] && cp "${INSMIX_DIR}/makefile" "${INSMIX_DIR}/makefile.original.backup"
    cp "${REPO_MAKEFILE}" "${INSMIX_DIR}/makefile"
fi

if [ -f "${REPO_MAKEFILE_RULES}" ]; then
    echo -e "${GREEN}Copying makefile.rules from repo...${NC}"
    [ -f "${INSMIX_DIR}/makefile.rules" ] && cp "${INSMIX_DIR}/makefile.rules" "${INSMIX_DIR}/makefile.rules.original.backup"
    cp "${REPO_MAKEFILE_RULES}" "${INSMIX_DIR}/makefile.rules"
fi

echo -e "${GREEN}✓ Modified insmix files copied to PIN installation${NC}"

# Step 3: Compile the insmix tool
echo ""
echo -e "${CYAN}Step 3: Compiling insmix tool...${NC}"

cd "${INSMIX_DIR}"

# Check if already compiled
INSMIX_SO="${INSMIX_DIR}/obj-intel64/insmix.so"
if [ -f "${INSMIX_SO}" ]; then
    echo -e "${YELLOW}insmix.so already exists. Recompiling...${NC}"
    make clean
fi

echo -e "${GREEN}Building insmix...${NC}"
if make; then
    echo -e "${GREEN}✓ insmix compiled successfully${NC}"
    echo -e "${GREEN}  Location: ${INSMIX_SO}${NC}"
else
    echo -e "${RED}Error: Compilation failed${NC}"
    echo -e "${YELLOW}Please check the build errors above${NC}"
    exit 1
fi

# Step 4: Verify function list file exists
echo ""
echo -e "${CYAN}Step 4: Verifying function list file...${NC}"

if [ ! -f "${FUNCTION_LIST}" ]; then
    echo -e "${YELLOW}Function list not found. Creating default list...${NC}"
    cat > "${FUNCTION_LIST}" << 'EOF'
# Functions to track for instruction counting
# Add one function name per line
main
process
compute
filter
scan
EOF
    echo -e "${GREEN}✓ Created default function list at ${FUNCTION_LIST}${NC}"
    echo -e "${YELLOW}  You may want to edit this file to add specific functions${NC}"
else
    echo -e "${GREEN}✓ Function list exists at ${FUNCTION_LIST}${NC}"
    echo -e "${CYAN}  Functions to track:${NC}"
    cat "${FUNCTION_LIST}" | grep -v '^#' | grep -v '^$' | head -10
fi

# Step 5: Run a test
echo ""
echo -e "${CYAN}Step 5: Running test...${NC}"

PIN_CMD="${PIN_DIR}/pin"
TEST_APP="/bin/ls"  # Simple test application

if [ ! -f "${PIN_CMD}" ]; then
    echo -e "${RED}Error: PIN executable not found at ${PIN_CMD}${NC}"
    exit 1
fi

echo -e "${GREEN}Running test with PIN and insmix...${NC}"
echo -e "${CYAN}Command: ${PIN_CMD} -t ${INSMIX_SO} -o test_insmix.out -function_list ${FUNCTION_LIST} -inclusive 1 -- ${TEST_APP}${NC}"

cd "${WORK_DIR}"
if ${PIN_CMD} -t ${INSMIX_SO} -o test_insmix.out -function_list "${FUNCTION_LIST}" -inclusive 1 -- ${TEST_APP} > /dev/null 2>&1; then
    echo -e "${GREEN}✓ Test run successful${NC}"
    
    if [ -f "test_insmix.out" ]; then
        echo -e "${GREEN}✓ Output file created${NC}"
        echo -e "${CYAN}Sample output (last 20 lines):${NC}"
        tail -20 test_insmix.out
        
        # Check for SIMD breakdown
        if grep -q '\*scalar' test_insmix.out && grep -q '\*simd' test_insmix.out; then
            echo -e "${GREEN}✓ SIMD breakdown found in output${NC}"
        else
            echo -e "${YELLOW}⚠ SIMD breakdown markers not found (expected for test app)${NC}"
        fi
    fi
else
    echo -e "${RED}Error: Test run failed${NC}"
    echo -e "${YELLOW}This may be normal if /bin/ls doesn't contain the tracked functions${NC}"
fi

# Cleanup test output
rm -f test_insmix.out

echo ""
echo -e "${BLUE}╔═══════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Setup Complete!                                          ║${NC}"
echo -e "${BLUE}╚═══════════════════════════════════════════════════════════╝${NC}"
echo ""
echo -e "${GREEN}PIN Tool Information:${NC}"
echo -e "  PIN directory:    ${CYAN}${PIN_DIR}${NC}"
echo -e "  PIN executable:   ${CYAN}${PIN_CMD}${NC}"
echo -e "  Insmix tool:      ${CYAN}${INSMIX_SO}${NC}"
echo -e "  Function list:    ${CYAN}${FUNCTION_LIST}${NC}"
echo ""
echo -e "${GREEN}Usage Example:${NC}"
echo -e "  ${CYAN}${PIN_CMD} -t ${INSMIX_SO} \\${NC}"
echo -e "    ${CYAN}-o output.txt \\${NC}"
echo -e "    ${CYAN}-function_list ${FUNCTION_LIST} \\${NC}"
echo -e "    ${CYAN}-inclusive 1 \\${NC}"
echo -e "    ${CYAN}-- ./your_application [args]${NC}"
echo ""
echo -e "${GREEN}To use in your existing script:${NC}"
echo -e "  ${CYAN}export PIN_ROOT=${PIN_DIR}${NC}"
echo -e "  ${CYAN}./compare_instructions.sh${NC}"
echo ""
