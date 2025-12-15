# Modified Insmix PIN Tool

This directory contains the modified `insmix.cpp` PIN tool that adds support for:
- Function filtering via `-function_list` parameter
- Inclusive mode for tracking subfunctions  
- SIMD vs scalar instruction classification
- Special counters for total, scalar, and SIMD instruction counts

## Files

- `insmix.cpp` - Modified PIN tool source code
- `makefile` - PIN tool makefile
- `makefile.rules` - Build rules for the tool

## Building

These files need to be compiled within the Intel PIN installation directory. To build:

1. **Copy files to PIN installation:**
   ```bash
   PIN_ROOT=/home/aalawneh/energy/pin-external-4.0-99633-g5ca9893f2-gcc-linux
   cp insmix.cpp $PIN_ROOT/source/tools/Insmix/
   cp makefile $PIN_ROOT/source/tools/Insmix/
   cp makefile.rules $PIN_ROOT/source/tools/Insmix/
   ```

2. **Build the tool:**
   ```bash
   cd $PIN_ROOT/source/tools/Insmix
   make
   ```

3. **The compiled tool will be at:**
   ```
   $PIN_ROOT/source/tools/Insmix/obj-intel64/insmix.so
   ```

## Usage

```bash
PIN_ROOT=/home/aalawneh/energy/pin-external-4.0-99633-g5ca9893f2-gcc-linux
$PIN_ROOT/pin -t $PIN_ROOT/source/tools/Insmix/obj-intel64/insmix.so \
    -o output.txt \
    -function_list functions_to_track.txt \
    -inclusive 1 \
    -- ./your_application [args]
```

## Parameters

- `-o <file>` - Output file name (default: insmix.out)
- `-function_list <file>` - File containing function names to profile (one per line)
- `-inclusive 1/0` - Include subfunctions called by target functions (1=yes, 0=no)
- `-r 1/0` - Enable per-routine profiling (default: 1)
- `-no_shared_libs` - Do not instrument shared libraries

## Output Format

The tool outputs instruction mix statistics with special counters:
- `3000 *total` - Total instruction count
- `3001 *scalar` - Scalar instruction count  
- `3002 *simd` - SIMD instruction count (SSE, AVX, AVX2, AVX-512, etc.)

## Note

This is a modified version of Intel PIN's insmix tool. The original tool is part of the Intel PIN distribution and is subject to Intel's license.
