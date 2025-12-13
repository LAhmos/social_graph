#!/bin/bash

# Setup script for socialGraph benchmark environment
# This script downloads ISPC, sets up PATH, and installs Python dependencies

set -e  # Exit on error

# Color codes for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  SocialGraph Environment Setup                                  ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
cd "$SCRIPT_DIR"

# ============================================
# 1. Download and setup ISPC
# ============================================
echo -e "${YELLOW}[1/3] Setting up ISPC compiler...${NC}"

ISPC_VERSION="v1.28.2"
ISPC_DIR="ispc-${ISPC_VERSION}-linux"
ISPC_TARBALL="ispc-${ISPC_VERSION}-linux.tar.gz"
ISPC_URL="https://github.com/ispc/ispc/releases/download/${ISPC_VERSION}/${ISPC_TARBALL}"

if [ -d "$ISPC_DIR" ]; then
    echo -e "${GREEN}✓ ISPC already exists at ${ISPC_DIR}${NC}"
else
    echo "  Downloading ISPC ${ISPC_VERSION}..."
    if command -v wget &> /dev/null; then
        wget -q --show-progress "$ISPC_URL"
    elif command -v curl &> /dev/null; then
        curl -L -o "$ISPC_TARBALL" "$ISPC_URL"
    else
        echo -e "${RED}✗ Error: wget or curl required to download ISPC${NC}"
        exit 1
    fi
    
    echo "  Extracting ISPC..."
    tar -xzf "$ISPC_TARBALL"
    rm "$ISPC_TARBALL"
    echo -e "${GREEN}✓ ISPC downloaded and extracted${NC}"
fi

# Add ISPC to PATH
ISPC_BIN="$SCRIPT_DIR/$ISPC_DIR/bin"
if [[ ":$PATH:" != *":$ISPC_BIN:"* ]]; then
    export PATH="$ISPC_BIN:$PATH"
    echo -e "${GREEN}✓ ISPC added to PATH${NC}"
fi

# Verify ISPC installation
if command -v ispc &> /dev/null; then
    ISPC_VERSION_OUTPUT=$(ispc --version 2>&1 | head -1)
    echo -e "${GREEN}✓ ISPC is ready: ${ISPC_VERSION_OUTPUT}${NC}"
else
    echo -e "${RED}✗ Error: ISPC not found in PATH${NC}"
    exit 1
fi

# ============================================
# 2. Install Python dependencies
# ============================================
echo ""
echo -e "${YELLOW}[2/3] Installing Python dependencies...${NC}"

# Check if Python 3 is available
if ! command -v python3 &> /dev/null; then
    echo -e "${RED}✗ Error: Python 3 is required but not installed${NC}"
    exit 1
fi

PYTHON_VERSION=$(python3 --version)
echo "  Found: $PYTHON_VERSION"

# Create requirements.txt with necessary packages
cat > requirements.txt << 'EOF'
# Data processing and analysis
pandas>=1.3.0
numpy>=1.21.0

# Plotting and visualization
matplotlib>=3.4.0
plotly>=5.0.0

# Optional: For better interactive plots
kaleido>=0.2.1
EOF

# Create virtual environment
VENV_DIR="venv"
if [ -d "$VENV_DIR" ]; then
    echo -e "${GREEN}✓ Virtual environment already exists${NC}"
else
    echo "  Creating virtual environment..."
    python3 -m venv "$VENV_DIR"
    echo -e "${GREEN}✓ Virtual environment created${NC}"
fi

# Install packages in virtual environment
echo "  Installing Python packages in virtual environment..."
"$VENV_DIR/bin/pip" install -q --upgrade pip
"$VENV_DIR/bin/pip" install -q -r requirements.txt
echo -e "${GREEN}✓ Python dependencies installed${NC}"

# ============================================
# 3. Verify build tools
# ============================================
echo ""
echo -e "${YELLOW}[3/3] Verifying build tools...${NC}"

# Check for g++
if command -v g++ &> /dev/null; then
    GCC_VERSION=$(g++ --version | head -1)
    echo -e "${GREEN}✓ g++ found: ${GCC_VERSION}${NC}"
else
    echo -e "${RED}✗ Error: g++ not found${NC}"
    echo "  On Ubuntu/Debian: sudo apt-get install build-essential"
    exit 1
fi

# Check for make
if command -v make &> /dev/null; then
    MAKE_VERSION=$(make --version | head -1)
    echo -e "${GREEN}✓ make found: ${MAKE_VERSION}${NC}"
else
    echo -e "${RED}✗ Error: make not found${NC}"
    exit 1
fi

# ============================================
# 4. Create shell configuration
# ============================================
echo ""
echo -e "${YELLOW}Setting up shell configuration...${NC}"

# Create a source file for the environment
cat > env_setup.sh << 'EOF'
#!/bin/bash
# Source this file to setup the socialGraph environment
# Usage: source env_setup.sh

# Get the directory where this script is located
SCRIPT_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"

# Add ISPC to PATH
export PATH="$SCRIPT_DIR/ispc-v1.28.2-linux/bin:$PATH"

# Activate Python virtual environment
source "$SCRIPT_DIR/venv/bin/activate"

echo "SocialGraph environment activated"
echo "ISPC: $(which ispc)"
echo "Python: $(which python)"
EOF

chmod +x env_setup.sh

echo -e "${GREEN}✓ Created env_setup.sh${NC}"
echo ""

# ============================================
# Summary
# ============================================
echo -e "${BLUE}╔══════════════════════════════════════════════════════════════════╗${NC}"
echo -e "${BLUE}║  Setup Complete!                                                 ║${NC}"
echo -e "${BLUE}╚══════════════════════════════════════════════════════════════════╝${NC}"
echo ""
echo "Next steps:"
echo "  1. To activate the environment in your current shell:"
echo -e "     ${GREEN}source env_setup.sh${NC}"
echo ""
echo "  2. To make it permanent, add these lines to your ~/.bashrc:"
echo -e "     ${GREEN}export PATH=\"$ISPC_BIN:\$PATH\"${NC}"
echo -e "     ${GREEN}source \"$SCRIPT_DIR/venv/bin/activate\"${NC}"
echo ""
echo "  3. Build and run benchmarks:"
echo "     cd user && make && ./simple ispc create 100"
echo "     cd post && make && ./simple ispc create 100"
echo "     cd userTag && make && ./simple ispc insert 50"
echo ""
echo "  4. Run comprehensive benchmarks:"
echo "     ./run_all_benchmarks_with_modes.sh"
echo ""
