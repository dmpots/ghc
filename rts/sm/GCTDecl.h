/* -----------------------------------------------------------------------------
 *
 * (c) The GHC Team 1998-2009
 *
 * Documentation on the architecture of the Garbage Collector can be
 * found in the online commentary:
 * 
 *   http://hackage.haskell.org/trac/ghc/wiki/Commentary/Rts/Storage/GC
 *
 * ---------------------------------------------------------------------------*/

#ifndef SM_GCTDECL_H
#define SM_GCTDECL_H

#include "BeginPrivate.h"

/* -----------------------------------------------------------------------------
   The gct variable is thread-local and points to the current thread's
   gc_thread structure.  It is heavily accessed, so we try to put gct
   into a global register variable if possible; if we don't have a
   register then use gcc's __thread extension to create a thread-local
   variable.
   -------------------------------------------------------------------------- */
#if defined(THREADED_RTS)

#define GLOBAL_REG_DECL(type,name,reg) register type name REG(reg);

#define SET_GCT(to) gct = (to)



#if (defined(i386_HOST_ARCH) && defined(linux_HOST_OS))
// Using __thread is better than stealing a register on x86/Linux, because
// we have too few registers available.  In my tests it was worth
// about 5% in GC performance, but of course that might change as gcc
// improves. -- SDM 2009/04/03
//
// For MacOSX, we can use an llvm-based C compiler which will pass gct
// as a parameter to the GC functions

extern __thread gc_thread* gct;
#define DECLARE_GCT __thread gc_thread* gct;

#elif defined(llvm_CC_FLAVOR)
// LLVM does not support the __thread extension and will generate
// incorrect code for global register variables. If we are compiling
// with a C compiler that uses an LLVM back end (clang or llvm-gcc) then we
// pass the gct variable as a parameter to all the functions that need it
#define PASS_GCT_AS_PARAM 1

#elif defined(sparc_HOST_ARCH)
// On SPARC we can't pin gct to a register. Names like %l1 are just offsets
//	into the register window, which change on each function call.
//	
//	There are eight global (non-window) registers, but they're used for other purposes.
//	%g0     -- always zero
//	%g1     -- volatile over function calls, used by the linker
//	%g2-%g3 -- used as scratch regs by the C compiler (caller saves)
//	%g4	-- volatile over function calls, used by the linker
//	%g5-%g7	-- reserved by the OS

extern __thread gc_thread* gct;
#define DECLARE_GCT __thread gc_thread* gct;


#elif defined(REG_Base) && !defined(i386_HOST_ARCH)
// on i386, REG_Base is %ebx which is also used for PIC, so we don't
// want to steal it

GLOBAL_REG_DECL(gc_thread*, gct, REG_Base)
#define DECLARE_GCT /* nothing */


#elif defined(REG_R1)

GLOBAL_REG_DECL(gc_thread*, gct, REG_R1)
#define DECLARE_GCT /* nothing */


#elif defined(__GNUC__)

extern __thread gc_thread* gct;
#define DECLARE_GCT __thread gc_thread* gct;

#else

#error Cannot find a way to declare the thread-local gct

#endif

#else  // not the threaded RTS

extern StgWord8 the_gc_thread[];

#define gct ((gc_thread*)&the_gc_thread)
#define SET_GCT(to) /*nothing*/
#define DECLARE_GCT /*nothing*/

#endif // THREADED_RTS

// Definitions for passing the GCT variable as a parameter to the GC functions
#if defined(PASS_GCT_AS_PARAM)
#define DECLARE_GCT /* nothing */
#undef gct

// for function declarations
#define DECLARE_GCT_PARAM(...) gc_thread *gct, __VA_ARGS__
#define DECLARE_GCT_ONLY_PARAM gc_thread *gct
// for function calls
#define GCT_PARAM(...) gct, __VA_ARGS__
#define GCT_ONLY_PARAM gct
#else
// for function declarations
#define DECLARE_GCT_PARAM(...) __VA_ARGS__
#define DECLARE_GCT_ONLY_PARAM void
// for function calls
#define GCT_PARAM(...) __VA_ARGS__
#define GCT_ONLY_PARAM /* nothing */
#endif

#include "EndPrivate.h"

#endif // SM_GCTDECL_H
