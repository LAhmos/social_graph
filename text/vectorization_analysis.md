# Vectorization Analysis for process_single_text

## Summary
**The `process_single_text` function is NOT being vectorized.** It's compiled as purely scalar code with only minimal vector instruction usage for data movement.

## Evidence

### 1. Assembly Analysis
Generated assembly file: `simple_ispc.s` (57KB, 1933 lines total)

Function `process_single_text` spans lines 24-1274 (1,251 lines of assembly)

**Vector Instructions Found:** Only 6 instances of YMM/XMM register usage:
```assembly
vpcmpeqd    %ymm1, %ymm1, %ymm1      # Create mask
vtestps     %ymm1, %ymm0             # Test condition
vmovaps     .LCPI0_0(%rip), %xmm0    # Load constant "http://short-url"
vmovups     %xmm0, (%rcx,%r15)       # Store 16 bytes
vmovaps     .LCPI0_0(%rip), %xmm0    # Load constant again
vmovups     %xmm0, (%rcx,%r15)       # Store 16 bytes
```

These vector instructions are NOT used for computational loops but only for:
- **Condition testing** (vtestps)
- **Moving 16-byte string constants** (the "http://short-url" prefix)

### 2. Loop Structure Analysis

All loops in `process_single_text` use **scalar operations**:
- `cmpb` - Compare single bytes
- `movzbl` - Move single bytes with zero extension
- `incl/incq` - Increment counters one at a time
- Scalar conditional branches (`je`, `jne`, `jg`, `jge`)

Example from mention extraction loop:
```assembly
.LBB0_4:                                # =>This Loop Header: Depth=1
    cmpl    $15, %r14d                  # Scalar comparison
    jg      .LBB0_14
    movslq  %eax, %rcx
    cmpb    $64, (%r12,%rcx)           # Scalar byte compare for '@'
    jne     .LBB0_3
```

### 3. Why Is It Not Vectorized?

The function is declared as `static void process_single_text(...)` with **all `uniform` parameters**:
```ispc
static void process_single_text(
    const uniform uint8 text[],           // uniform
    uniform int text_len,                 // uniform
    uniform uint8 mentions[][64],         // uniform
    uniform int * uniform num_mentions,   // uniform pointer
    ...
)
```

#### Key Issues:

1. **All uniform data**: When all data is `uniform`, ISPC treats the function as scalar code operating on single values, not SIMD lanes.

2. **Sequential string parsing**: The logic involves:
   - Character-by-character scanning
   - Variable-length patterns (mentions, URLs)
   - Conditional branching based on individual characters
   - Data-dependent control flow

3. **No SIMD parallelism**: The function processes ONE text at a time, not multiple texts in parallel across SIMD lanes.

## How the Code Actually Executes

In `processText_batch`:
```assembly
.LBB1_3:                                # Loop processing N texts
    rdtsc                                # Get timestamp
    # ... setup arguments ...
    callq   process_single_text___...   # SCALAR call
    rdtsc                                # Get timestamp
    incq    %rbp                         # Move to next text
    cmpq    %r12, %rbp
    je      .LBB1_37
```

Each text is processed **sequentially** in a scalar loop, not in parallel using SIMD.

## Recommendations for Vectorization

To achieve actual SIMD vectorization, you would need to:

### Option 1: Vectorize Within Text Processing
Process 8 characters at once within a single text:
```ispc
// Use varying instead of uniform
foreach (i = 0 ... text_len) {
    varying uint8 c = text[i];  // Load 8 chars at once
    varying bool is_at = (c == '@');
    // ... SIMD operations on 8 characters ...
}
```

**Challenge**: String parsing with variable-length patterns is inherently difficult to vectorize.

### Option 2: Process Multiple Texts in Parallel
Change the function signature to process 8 texts simultaneously:
```ispc
export void processText_batch(
    uniform const uint8 texts[],
    uniform int N,
    uniform TextResult results[]
)
{
    foreach (i = 0 ... N) {
        // Now 'i' is varying - processes 8 texts per iteration
        varying int offset = i * MAX_TEXT_LEN;
        // Process texts[offset] for 8 different values of i
    }
}
```

### Option 3: Accept Current Design
If the text processing logic is too complex for effective vectorization:
- Keep current implementation
- The compiler will generate efficient scalar code
- Focus optimization efforts elsewhere (I/O, memory access patterns)

## Conclusion

**Current State**: `process_single_text` is compiled as **scalar code**, not vectorized SIMD code.

**Performance**: The function processes texts one at a time using scalar instructions, with ISPC providing mainly:
- Good compiler optimizations
- Clean C interop
- Timing instrumentation

**To Get Vectorization**: The algorithm and data structures would need significant redesign to expose SIMD parallelism (processing multiple characters or multiple texts simultaneously across SIMD lanes).
