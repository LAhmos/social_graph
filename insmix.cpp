/*
 * Copyright (C) 2004-2025 Intel Corporation.
 * SPDX-License-Identifier: MIT
 */

/*! @file
 *  This file contains a static and dynamic instruction mix profiler
 */

#include "pin.H"

#include <atomic>
#include <iostream>
#include <iomanip>
#include <fstream>
#include <map>
#include <set>
#include <string>
#include <vector>
#include <unistd.h>

/* ===================================================================== */
/* Commandline Switches */
/* ===================================================================== */

KNOB< std::string > KnobOutputFile(KNOB_MODE_WRITEONCE, "pintool", "o", "insmix.out", "specify file name for insmix profile ");
KNOB< BOOL > KnobPid(KNOB_MODE_WRITEONCE, "pintool", "i", "0", "append pid to output");
KNOB< BOOL > KnobProfilePredicated(KNOB_MODE_WRITEONCE, "pintool", "p", "0",
                                   "enable accurate profiling for predicated instructions");
KNOB< BOOL > KnobProfileRoutines(KNOB_MODE_WRITEONCE, "pintool", "r", "1", "enable per routine profiling");
KNOB< BOOL > KnobProfileStaticOnly(KNOB_MODE_WRITEONCE, "pintool", "s", "0",
                                   "terminate after collection of static profile for main image");
KNOB< BOOL > KnobProfileDynamicOnly(KNOB_MODE_WRITEONCE, "pintool", "d", "1", "Only collect dynamic profile");
KNOB< BOOL > KnobNoSharedLibs(KNOB_MODE_WRITEONCE, "pintool", "no_shared_libs", "0", "do not instrument shared libraries");
KNOB< std::string > KnobFunctionListFile(KNOB_MODE_WRITEONCE, "pintool", "function_list", "",
                                         "specify file containing function names to profile (one per line)");
KNOB< BOOL > KnobInclusiveMode(KNOB_MODE_WRITEONCE, "pintool", "inclusive", "1",
                              "include all subfunctions called by target functions (1=inclusive, 0=exact)");

static std::string longstr(int rtn_no, const char* name)
{
    return std::string("rtn[") + decstr(rtn_no) + std::string(",") + std::string(name) + std::string("]");
}

// Set of function names to profile (empty means profile all functions)
static std::set<std::string> targetFunctions;
static BOOL filterByFunction = false;
static BOOL inclusiveMode = false;

// Global flag: once a target function is called, start tracing everything
static std::atomic<BOOL> tracingEnabled(false);

/* ===================================================================== */

INT32 Usage()
{
    std::cerr << "This pin tool computes a static and dynamic instruction mix profile\n"
                 "\n";

    std::cerr << KNOB_BASE::StringKnobSummary();

    std::cerr << std::endl;

    return -1;
}

/* ===================================================================== */
/* INDEX HELPERS */
/* ===================================================================== */

const UINT32 MAX_INDEX     = 4096;
const UINT32 INDEX_SPECIAL = 3000;
const UINT32 MAX_MEM_SIZE  = 520;

const UINT32 INDEX_TOTAL          = INDEX_SPECIAL + 0;
const UINT32 INDEX_SCALAR         = INDEX_SPECIAL + 1;
const UINT32 INDEX_SIMD           = INDEX_SPECIAL + 2;
const UINT32 INDEX_SPECIAL_END    = INDEX_SPECIAL + 3;

static BOOL IsSIMDInstruction(INS ins)
{
    xed_extension_enum_t ext = static_cast<xed_extension_enum_t>(INS_Extension(ins));
    
    // Check if the instruction belongs to a SIMD extension
    return (ext == XED_EXTENSION_MMX ||
            ext == XED_EXTENSION_SSE ||
            ext == XED_EXTENSION_SSE2 ||
            ext == XED_EXTENSION_SSE3 ||
            ext == XED_EXTENSION_SSSE3 ||
            ext == XED_EXTENSION_SSE4 ||
            ext == XED_EXTENSION_SSE4A ||
            ext == XED_EXTENSION_AVX ||
            ext == XED_EXTENSION_AVX2 ||
            ext == XED_EXTENSION_AVX2GATHER ||
            ext == XED_EXTENSION_AVX512EVEX ||
            ext == XED_EXTENSION_AVX512VEX ||
            ext == XED_EXTENSION_AVXAES ||
            ext == XED_EXTENSION_AVX_IFMA ||
            ext == XED_EXTENSION_AVX_NE_CONVERT ||
            ext == XED_EXTENSION_AVX_VNNI ||
            ext == XED_EXTENSION_AVX_VNNI_INT16 ||
            ext == XED_EXTENSION_AVX_VNNI_INT8 ||
            ext == XED_EXTENSION_FMA ||
            ext == XED_EXTENSION_FMA4 ||
            ext == XED_EXTENSION_F16C ||
            ext == XED_EXTENSION_3DNOW ||
            ext == XED_EXTENSION_XOP ||
            ext == XED_EXTENSION_VAES ||
            ext == XED_EXTENSION_VPCLMULQDQ ||
            ext == XED_EXTENSION_AMX_TILE);
}

static UINT32 IndexStringLength(BBL bbl, BOOL memory_acess_profile)
{
    UINT32 count = 0;

    for (INS ins = BBL_InsHead(bbl); INS_Valid(ins); ins = INS_Next(ins))
    {
        // Count opcode + scalar/SIMD classification
        count += 2;
    }

    return count;
}

/* ===================================================================== */
static UINT16* INS_GenerateIndexString(INS ins, UINT16* stats, BOOL memory_acess_profile)
{
    const UINT32 offset = 0;

    *stats++ = offset + INS_Opcode(ins);
    
    // Add scalar or SIMD classification
    if (IsSIMDInstruction(ins))
        *stats++ = INDEX_SIMD;
    else
        *stats++ = INDEX_SCALAR;

    return stats;
}

/* ===================================================================== */

static std::string IndexToOpcodeString(UINT32 index)
{
    if (INDEX_SPECIAL <= index && index < INDEX_SPECIAL_END)
    {
        if (index == INDEX_TOTAL)
            return "*total";
        else if (index == INDEX_SCALAR)
            return "*scalar";
        else if (index == INDEX_SIMD)
            return "*simd";
        else
        {
            ASSERTX(0);
            return "";
        }
    }
    else
    {
        return OPCODE_StringShort(index);
    }
}

/* ===================================================================== */

/* ===================================================================== */

typedef std::atomic<UINT64> COUNTER;

/* zero initialized */

class STATS
{
  public:
    COUNTER unpredicated[MAX_INDEX];
    COUNTER predicated[MAX_INDEX];
    COUNTER predicated_true[MAX_INDEX];

    VOID Clear()
    {
        for (UINT32 i = 0; i < MAX_INDEX; i++)
        {
            unpredicated[i].store(0, std::memory_order_relaxed);
            predicated[i].store(0, std::memory_order_relaxed);
            predicated_true[i].store(0, std::memory_order_relaxed);
        }
    }
};

STATS GlobalStatsStatic;
STATS GlobalStatsDynamic;

class RTN_TABLE_ENTRY
{
  public:
    ADDRINT _address;
    const char* _name;

    RTN_TABLE_ENTRY(ADDRINT address, const char* name) : _address(address), _name(name) {}
};

std::map< UINT32, RTN_TABLE_ENTRY* > rtn_table;

class BBLSTATS
{
  public:
    COUNTER _counter;
    const UINT16* const _stats;
    const ADDRINT _addr;
    const UINT32 _rtn_num;
    const UINT32 _size;
    const UINT32 _numins;

  public:
    BBLSTATS(UINT16* stats, ADDRINT addr, UINT32 rtn_num, UINT32 size, UINT32 numins)
        : _counter(0), _stats(stats), _addr(addr), _rtn_num(rtn_num), _size(size), _numins(numins) {};
};

static BOOL CompareLess(const BBLSTATS* const& s1, const BBLSTATS* const& s2)
{
    return ((rtn_table[s1->_rtn_num]->_address) < (rtn_table[s2->_rtn_num]->_address));
}

static std::vector< const BBLSTATS* > statsList;

/* ===================================================================== */

static VOID ThreadStart(THREADID threadId, CONTEXT* ctx, INT32 flags, VOID* v)
{
    // Nothing to initialize
}

static VOID ThreadFini(THREADID threadId, const CONTEXT* ctx, INT32 code, VOID* v)
{
    // Nothing to clean up
}

/* ===================================================================== */
// Function entry callback - enable tracing when target function is called
static VOID OnFunctionEntry()
{
    tracingEnabled.store(true, std::memory_order_relaxed);
}

/* ===================================================================== */
VOID PIN_FAST_ANALYSIS_CALL docount(COUNTER* counter)
{
    counter->fetch_add(1, std::memory_order_relaxed);
}

// Conditional counting for inclusive mode
VOID PIN_FAST_ANALYSIS_CALL docount_if_tracing(COUNTER* counter)
{
    if (tracingEnabled.load(std::memory_order_relaxed))
    {
        counter->fetch_add(1, std::memory_order_relaxed);
    }
}

/* ===================================================================== */
VOID Trace(TRACE trace, VOID* v)
{
    if (KnobNoSharedLibs.Value() && IMG_Type(SEC_Img(RTN_Sec(TRACE_Rtn(trace)))) == IMG_TYPE_SHAREDLIB) return;

    // If function filtering is enabled and inclusive mode is on,
    // instrument everything and check at runtime if tracing is enabled
    if (filterByFunction && !inclusiveMode)
    {
        // Exact mode: only instrument target functions
        RTN rtn = TRACE_Rtn(trace);
        if (RTN_Valid(rtn))
        {
            std::string rtnName = RTN_Name(rtn);
            if (targetFunctions.find(rtnName) == targetFunctions.end())
            {
                return;
            }
        }
    }
    
    RTN rtn = TRACE_Rtn(trace);
    ADDRINT rtn_address;
    const char* rtn_name;
    UINT32 rtn_num;
    if (!RTN_Valid(rtn))
    {
        //std::cerr << "Cannot find valid RTN for trace at address" << TRACE_Address(trace);
        rtn_address = 0;
        rtn_name    = "UNKNOWN";
        rtn_num     = 0;
    }
    else
    {
        rtn_num     = RTN_Id(rtn);
        rtn_address = RTN_Address(rtn);
        rtn_name    = RTN_Name(rtn).c_str();
    }
    std::map< UINT32, RTN_TABLE_ENTRY* >::const_iterator it = rtn_table.find(rtn_num);
    if (it == rtn_table.end())
    {
        char* str = new char[strlen(rtn_name) + 1];
        strcpy(str, rtn_name);
        RTN_TABLE_ENTRY* rtn_table_entry = new RTN_TABLE_ENTRY(rtn_address, str);
        rtn_table[rtn_num]               = rtn_table_entry;
    }
    const BOOL accurate_handling_of_predicates = KnobProfilePredicated.Value();

    for (BBL bbl = TRACE_BblHead(trace); BBL_Valid(bbl); bbl = BBL_Next(bbl))
    {
        // Summarize the stats for the bbl in a 0 terminated list
        // This is done at instrumentation time
        const UINT32 n = IndexStringLength(bbl, 1);

        UINT16* const stats     = new UINT16[n + 1];
        UINT16* const stats_end = stats + (n + 1);
        UINT16* curr            = stats;

        UINT32 numins = 0;
        UINT32 size   = 0;

        for (INS ins = BBL_InsHead(bbl); INS_Valid(ins); ins = INS_Next(ins))
        {
            numins += 1;
            size += INS_Size(ins);

            // Count the number of times a predicated instruction is actually executed
            // this is expensive and hence disabled by default
            if (INS_IsPredicated(ins) && accurate_handling_of_predicates)
            {
                INS_InsertPredicatedCall(ins, IPOINT_BEFORE, AFUNPTR(docount), IARG_FAST_ANALYSIS_CALL, IARG_PTR,
                                         &(GlobalStatsDynamic.predicated_true[INS_Opcode(ins)]), IARG_END);
            }

            curr = INS_GenerateIndexString(ins, curr, 1);
        }

        // std::string terminator
        *curr++ = 0;

        ASSERTX(curr == stats_end);

        // Insert instrumentation to count the number of times the bbl is executed
        BBLSTATS* bblstats = new BBLSTATS(stats, INS_Address(BBL_InsHead(bbl)), rtn_num, size, numins);
        
        // In inclusive mode, only count if tracing is enabled
        if (filterByFunction && inclusiveMode)
        {
            INS_InsertCall(BBL_InsHead(bbl), IPOINT_BEFORE, MAKE_AFUNPTR(docount_if_tracing), IARG_FAST_ANALYSIS_CALL, IARG_PTR,
                           &(bblstats->_counter), IARG_END);
        }
        else
        {
            INS_InsertCall(BBL_InsHead(bbl), IPOINT_BEFORE, MAKE_AFUNPTR(docount), IARG_FAST_ANALYSIS_CALL, IARG_PTR,
                           &(bblstats->_counter), IARG_END);
        }

        // Remember the counter and stats so we can compute a summary at the end
        statsList.push_back(bblstats);
    }
}

/* ===================================================================== */
static VOID DumpStats(std::ofstream& out, STATS& stats, BOOL predicated_true, BOOL print_zeros, const std::string& title)
{
    out << "#\n"
           "# "
        << title
        << "\n"
           "#\n"
           "#     opcode       count-unpredicated    count-predicated";

    if (predicated_true) out << "    count-predicated-true";

    out << "\n#\n";

    for (UINT32 i = 0; i < INDEX_SPECIAL; i++)
    {
        stats.unpredicated[INDEX_TOTAL].fetch_add(stats.unpredicated[i].load(std::memory_order_relaxed), std::memory_order_relaxed);
        stats.predicated[INDEX_TOTAL].fetch_add(stats.predicated[i].load(std::memory_order_relaxed), std::memory_order_relaxed);
        stats.predicated_true[INDEX_TOTAL].fetch_add(stats.predicated_true[i].load(std::memory_order_relaxed), std::memory_order_relaxed);
    }

    for (UINT32 i = 0; i < MAX_INDEX; i++)
    {
        UINT64 unpred_val = stats.unpredicated[i].load(std::memory_order_relaxed);
        UINT64 pred_val = stats.predicated[i].load(std::memory_order_relaxed);
        
        if (!print_zeros && unpred_val == 0 && pred_val == 0) continue;

        out << std::setw(4) << i << " " << ljstr(IndexToOpcodeString(i), 20) << " " << std::setw(16) << unpred_val << " "
            << std::setw(16) << pred_val;
        if (predicated_true) out << " " << std::setw(16) << stats.predicated_true[i].load(std::memory_order_relaxed);
        out << std::endl;
    }
}

/* ===================================================================== */

VOID PrintDynamicCounts(std::ofstream& out)
{
    // Print tracing status in inclusive mode
    if (inclusiveMode && filterByFunction)
    {
        out << "#" << std::endl;
        out << "# Inclusive Mode: Tracing " << (tracingEnabled.load(std::memory_order_relaxed) ? "was enabled" : "was never enabled") << std::endl;
        out << "#" << std::endl;
    }
    
    sort(statsList.begin(), statsList.end(), CompareLess);
    statsList.push_back(0); // add terminator marker

    STATS DynamicRtn;
    UINT32 rtn_num = 0;

    for (std::vector< const BBLSTATS* >::iterator bi = statsList.begin(); bi != statsList.end(); bi++)
    {
        const BBLSTATS* b = (*bi);

        if (b == 0 || rtn_num != b->_rtn_num)
        {
            if (rtn_num > 0 && KnobProfileRoutines)
            {
                DumpStats(out, DynamicRtn, false, 0,
                          "$rtn-counts " + longstr(rtn_num, rtn_table[rtn_num]->_name) + " at " +
                              hexstr(rtn_table[rtn_num]->_address));
                out << "#" << std::endl;
            }

            if (b != 0)
            {
                rtn_num = b->_rtn_num;
                DynamicRtn.Clear();
            }
            else
            {
                break;
            }
        }

        for (const UINT16* stats = b->_stats; *stats; stats++)
        {
            ASSERT(*stats < MAX_INDEX, "bad index " + decstr(*stats) + " at " + hexstr(b->_addr) + "\n");
            UINT64 count = b->_counter.load(std::memory_order_relaxed);
            DynamicRtn.unpredicated[*stats].fetch_add(count, std::memory_order_relaxed);
            GlobalStatsDynamic.unpredicated[*stats].fetch_add(count, std::memory_order_relaxed);
        }
    }

    DumpStats(out, GlobalStatsDynamic, KnobProfilePredicated, 0, "$dynamic-counts");

    out << "# $eof" << std::endl;
}

/* ===================================================================== */

VOID PrintOutput()
{
    std::string filename;
    std::ofstream out;

    // dump insmix profile

    filename = KnobOutputFile.Value();

    if (KnobPid)
    {
        filename += "." + decstr(getpid());
    }
    out.open(filename.c_str());

    out << "INSMIX        1.0         0\n";

    DumpStats(out, GlobalStatsStatic, false, 0, "$static-counts");

    out << std::endl;

    PrintDynamicCounts(out);

    out.close();
}

/* ===================================================================== */

VOID Fini(int, VOID* v) { PrintOutput(); }

/* ===================================================================== */

VOID Detach(VOID* v) { PrintOutput(); }

/* ===================================================================== */

VOID Routine(RTN rtn, VOID* v)
{
    if (!inclusiveMode || !filterByFunction) return;
    
    std::string rtnName = RTN_Name(rtn);
    
    // Only instrument target functions to enable tracing
    if (targetFunctions.find(rtnName) != targetFunctions.end())
    {
        RTN_Open(rtn);
        
        // Insert call at function entry to enable tracing
        RTN_InsertCall(rtn, IPOINT_BEFORE, (AFUNPTR)OnFunctionEntry, IARG_END);
        
        RTN_Close(rtn);
    }
}

VOID Image(IMG img, VOID* v)
{
    for (SEC sec = IMG_SecHead(img); SEC_Valid(sec); sec = SEC_Next(sec))
    {
        for (RTN rtn = SEC_RtnHead(sec); RTN_Valid(rtn); rtn = RTN_Next(rtn))
        {
            // Prepare for processing of RTN, an  RTN is not broken up into BBLs,
            // it is merely a sequence of INSs
            RTN_Open(rtn);

            for (INS ins = RTN_InsHead(rtn); INS_Valid(ins); ins = INS_Next(ins))
            {
                UINT16 array[128];
                UINT16* end = INS_GenerateIndexString(ins, array, 1);

                if (INS_IsPredicated(ins))
                {
                    for (UINT16* start = array; start < end; start++)
                        GlobalStatsStatic.predicated[*start].fetch_add(1, std::memory_order_relaxed);
                }
                else
                {
                    for (UINT16* start = array; start < end; start++)
                        GlobalStatsStatic.unpredicated[*start].fetch_add(1, std::memory_order_relaxed);
                }
            }

            // to preserve space, release data associated with RTN after we have processed it
            RTN_Close(rtn);
        }
    }

    if (KnobProfileStaticOnly.Value())
    {
        Fini(0, 0);
        exit(0);
    }
}

/* ===================================================================== */

int main(int argc, CHAR* argv[])
{
    PIN_InitSymbols();

    if (PIN_Init(argc, argv))
    {
        return Usage();
    }

    // Load function list if specified
    if (!KnobFunctionListFile.Value().empty())
    {
        filterByFunction = true;
        std::ifstream funcFile(KnobFunctionListFile.Value().c_str());
        if (!funcFile.is_open())
        {
            std::cerr << "Error: Cannot open function list file: " << KnobFunctionListFile.Value() << std::endl;
            return 1;
        }
        
        std::string line;
        while (std::getline(funcFile, line))
        {
            // Trim whitespace
            size_t start = line.find_first_not_of(" \t\r\n");
            size_t end = line.find_last_not_of(" \t\r\n");
            if (start != std::string::npos && end != std::string::npos)
            {
                std::string funcName = line.substr(start, end - start + 1);
                if (!funcName.empty() && funcName[0] != '#') // Skip empty lines and comments
                {
                    targetFunctions.insert(funcName);
                    std::cout << "Tracking function: " << funcName << std::endl;
                }
            }
        }
        funcFile.close();
        
        if (targetFunctions.empty())
        {
            std::cerr << "Warning: Function list file is empty or contains no valid function names" << std::endl;
            filterByFunction = false;
        }
        else
        {
            std::cout << "Loaded " << targetFunctions.size() << " functions to profile" << std::endl;
        }
    }

    // Initialize inclusive mode
    inclusiveMode = KnobInclusiveMode.Value();
    if (inclusiveMode && filterByFunction)
    {
        std::cout << "Inclusive mode enabled: will start tracing when any target function is called\n";
        
        // Add RTN instrumentation to detect target function calls
        RTN_AddInstrumentFunction(Routine, 0);
    }

    PIN_AddThreadStartFunction(ThreadStart, nullptr);
    PIN_AddThreadFiniFunction(ThreadFini, nullptr);

    TRACE_AddInstrumentFunction(Trace, 0);

    PIN_AddFiniFunction(Fini, 0);
    PIN_AddDetachFunction(Detach, 0);

    if (!KnobProfileDynamicOnly.Value()) IMG_AddInstrumentFunction(Image, 0);

    // Never returns

    PIN_StartProgram();

    return 0;
}

/* ===================================================================== */
/* eof */
/* ===================================================================== */
