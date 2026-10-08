# Reference counting, cycle handling and lifetime analysis: transition audit

Status: compiler lifetime pass, inline scalar ABI and borrowed call arguments implemented, 2026-09-26. The collector
remains unchanged for allocations whose lifetime is not yet proven. Dynamic
sharing and cycle policy are deferred for discussion after this compiler work.

## Required direction

The user requests prompt automatic release while preserving easy-to-write
QLang code. Rust-style ownership/borrow restrictions are explicitly rejected.
Reference counting is acceptable, and cycles must be handled automatically
using root reachability rather than requiring user-written weak references. QLang's own frontend/compiler remains the
implementation authority. Do not replace collection with allocation-only
behavior, exit-time cleanup, or a larger collection threshold.

Numbers and booleans should be represented without a heap allocation per value
or arithmetic operation. This requirement is independent of the ownership
policy for arrays, objects, strings and closures. Immediate values must still
preserve dynamic type checks, exact number behavior and the existing distinction
between uninitialized bindings and initialized null.

## Accepted language constraints and proposed mechanism

User clarification on 2026-09-24:

- Preserve ordinary aliases, mutation, escaping closures and recursive types.
- Do not add Rust-style ownership or borrow-checking restrictions.
- A nonzero reference count is insufficient to retain an unreachable cycle.
- A binding used again later must keep its value alive between uses.

Proposed mechanism: compiler-managed reference counting plus automatic cycle
collection, with conservative compile-time liveness analysis to shorten safe
reference lifetimes. This is a hybrid automatic memory-management design.
Reference counting itself is broadly classified as garbage collection, and
root reachability/cycle detection definitely remains collection work. Do not
claim this removes all GC; it replaces the current conservative heap scanner.
The exact cycle algorithm and its scheduling have not yet been implemented or
benchmarked. Instantaneous cycle reclamation with no graph-maintenance cost is
not promised.

The root set includes live execution state, module/global state and explicitly
registered native references. Heap closures are not automatically roots:
their captures remain live when the closures are reachable from roots.
Counts track concrete strong edges, not source-level occurrences of names.
Changing a binding changes one edge; other aliases may still retain the object.

Ordinary zero-count objects can be released when that count reaches zero.
A possible cycle can be queued when a reference is removed but its count stays
positive. A candidate-subgraph algorithm must account for references from
outside the candidate set and preserve everything reachable from them. Internal
cycle counts alone are not evidence of external reachability. Candidate work
must eventually cover unreachable cycles even if allocations stop, and queued
candidates must not contain dangling pointers. Scheduling, metadata, safe points
and destruction order are outstanding implementation decisions. No full-heap
walk on every reference assignment is proposed.

For subsequent uses, the compiler must analyze control flow, not line gaps.
A value live across a branch, loop backedge, call, returned alias or reachable
closure cannot be released. Start with scope-exit cleanup and correct ownership
of stores/results; release earlier only with proof that the current reference
is dead on every relevant continuation. An overwritten value is distinct from
a later value assigned to the same variable. Dropping a local reference does
not imply freeing its object if another live owner exists. The interpreter's
binding tables must retain references while interpreted code can still use them.

Terminology and algorithm precedent: CPython documents reference counting plus
cyclic collection and how candidate-internal references are separated from
external references in its [collector design](https://github.com/python/cpython/blob/main/InternalDocs/garbage_collector.md).
This is a reference for the principle, not a decision to copy Python's collector.

## Evidence motivating the transition (before the compiler passes)

- `src/value.rs`: numbers and booleans are inline enum payloads. Arrays and
  objects use `Rc<RefCell<...>>`; functions and errors also use `Rc`.
- `src/environment.rs`: scopes use `Rc<RefCell<Environment>>`.
- `src/value.rs`: a function retains its defining environment. This retained
  Rust implementation does not give QLang source programs a borrow checker,
  and `Rc` alone cannot reclaim a strong environment/function cycle.
- `aot/qlangc.ql`, `emitFrame`: every scope frame is heap allocated and retains
  its parent through a pointer.
- `aot/qlangc.ql`, `emitClosure`: each closure retains the entire defining frame.
  Storing that closure into the same frame forms an ownership cycle if both
  edges are naively converted into strong references. This happens even when
  the function never reads itself. Capture analysis must distinguish actual
  free variables from merely sharing a defining scope.
- `emitBindingStore` currently only stores pointers. Reassignment does not
  release a previous owner; function returns and other control-flow exits
  contain no deterministic cleanup.
- `aot/tests/t18_gc.ql` explicitly tests object self-reference, aliases and
  escaping closures. Removing those tests would conceal a semantic change.
- `demo/type_gymnastics.ql`: `List`, `Tree`, `Mu` and mutually recursive
  `EBox`/`OBox` types link a mutable box to a predicate closure that refers back
  to the box. These cycles are part of the current test program, not merely
  allocator-internal bookkeeping.

## Implementation sequence

1. Define a non-allocating scalar value representation and a heap-object ABI.
   Keep declaration/initialization state separate from language values.
2. Compute closure free variables and escape information in the QLang compiler.
   Capture only required values or shared mutable cells, preserving aliases.
   Do not introduce source-level borrowing requirements.
3. Give every generated operation an ownership contract: borrowed arguments,
   owned results, stores/replacements, captured values and container elements.
4. Insert cleanup on normal scope exits, reassignment and early exits, including
   return, error propagation, break/continue and module initialization failure.
   Returned/captured objects must survive their originating scope.
5. Implement automatic handling of closure recursion and user object cycles.
   The interpreter's dynamic execution and native ABI must follow the same
   language rules; direct AOT checks alone do not cover interpreted programs.
6. Add release counters and bounded-memory stress checks. Existing output tests
   alone cannot detect leaks, double release or premature destruction. Exercise
   aliases, overwrite-with-self, escaping closures, annotations, module exports,
   error causes and permitted recursive structures.
7. Retire the current conservative collector only after those contracts and
   automatic cycle handling work across the runtime,
   compiler and native core interpreter. Verify the self-compilation fixed point
   and rerun the full type gymnastics without removing recursive structures
   or reducing coverage to conceal lifetime defects.

## First compiler lifetime pass (superseded scalar storage described below)

The implementation is in QLang (`aot/lifetime.ql` and `aot/qlangc.ql`), using
the shared QLang AST. It does not add a borrow checker or alter alias semantics.

- Immutable numeric literals and Boolean values use static constants. Numeric
  comparisons and logical negation select the shared Boolean constants.
- Raw invocation argument buffers are borrowed by the callee ABI: parameters
  copy the values, and the buffer address is never exposed to QLang. They now
  use entry-block stack slots with start/end markers around the call. Arrays
  passed as actual language values still follow their existing heap semantics.
- A conservative AST walk detects potential frame capture. A frame with no
  nested function/import can use stack storage; possible capture retains the
  existing heap path. Function frames end at the common epilogue, covering
  ordinary returns and error propagation. Block frames end at normal block
  exit; an early function exit automatically ends their stack storage too.
- Newly computed numeric results consumed by arithmetic, comparisons,
  conditions or selected raw numeric operands use temporary stack slots.
  User calls, container stores, returned values and short-circuit/coalescing
  results conservatively keep their ordinary escape behavior. Arithmetic
  runtime fallback helpers may retain Error causes, but not temporary Number
  operands; this is part of the trusted runtime ABI proof.
- Every stack allocation is emitted in the function entry block. Slots are
  reused across loop iterations, and recursive calls get separate activations.
  Temporary scalar slots currently live for the activation; lexical frames
  and invocation buffers also receive explicit LLVM lifetime markers.

This pass eliminates proven unnecessary heap allocations; it does not yet
perform general last-use destruction of arbitrary shared heap objects or
implement reference counting/cycle collection. A binding used later, an alias,
or an escaping closure must continue working. The conservative fallback is
intentional until those cases are addressed separately.

The lifetime fixture checks subsequent uses, overwritten aliases, returned
scalars/containers, mutable captured variables, per-iteration closure captures,
early returns, error causes, short-circuit/fallback results and negative zero.
A 100,000-iteration native variant runs with a 1 MiB stack at both `-O0` and
`-O2`; the ordinary fixture uses 1,000 iterations for interpreter regressions.
The first-pass allocation gate allowed up to 1,100 allocations per additional
1,000 iterations and observed exactly 1,000. The inline ABI below removes those
escaping counter boxes too; the current gate requires zero growth.

The fixture also exposed an existing core interpreter bug: unary negation
used `0 - value`, which changes `-0` into `+0`. It now uses unary negation,
preserving the sign consistently with native execution.

## Performance baseline

The diagnostic run retained under `target/perf-check/` used the existing
optimized interpreter object plus a temporary instrumented C allocator. It
passed 419/419 assertions and observed 806,545,717 allocations, including
748,592,488 allocations of 16 bytes, requesting 17,396,358,840 bytes cumulatively.
GC accounted for about 71% of CPU samples and allocation itself about 21%.
These are diagnostic measurements, not an uninstrumented benchmark guarantee.
Raising the temporary minimum collection threshold from 8 MiB to 64 MiB reduced
collections from 2,278 to 284 and wall time from 27.0 to 12.2 seconds while the
allocation count remained unchanged. That experiment is evidence for reducing
allocation, not the requested replacement for GC.


## Measured first-pass result (2026-09-24)

Three alternating runs per executable on the same machine, with no compilation
or profiling instrumentation in the timed processes, passed 419/419 assertions
on every run. Wall-time medians were 24.481 seconds before and
2.626 seconds after (9.32x). Corresponding process-CPU
medians were 23.723 and 2.468 seconds. This is a local
measurement of the native QLang interpreter, not direct AOT of the test file.

Separate instrumented runs counted 806,545,717 versus 94,840,123 allocations, a
88.24% reduction. Cumulative requested bytes fell from
17,396,358,840 to 1,676,744,552; these figures are not peak heap usage. Collections
fell from 2,278 to 211 with the original collector and 8 MiB minimum threshold
unchanged. Detailed runs are in `target/lifetime-check/timing.json`; allocation
counts are in `target/lifetime-check/profile.log` and the original baseline in
`target/perf-check/profile.log`.

Verified native compiler: `target/lifetime-check/final-self/stage2`.
Verified core interpreter: `target/lifetime-check/final-core/interpreter`.
Stage-2/stage-3 compiler IR is byte-identical. The final native core gate passes
six fixed-output fixtures, all 419 type assertions, dynamic imports, function
metadata, 12 error exits and initialized-null checks. The lifetime suite passes
at `-O0`/`-O2`, including the constrained-stack stress and allocation-growth gate.

## Inline scalar and call ABI (2026-09-24)

`aot/qlangc.ql` now emits `%ql_value = type { i64, i64 }`. Numbers carry their
full IEEE-754 binary64 payload, Booleans carry 0/1, and null has its own kind.
Copying, computing, returning and storing these values requires no scalar heap
box, including values that escape a function. There is no pointer truncation
or NaN payload encoding. Heap/raw references use kind 0 and a full-width
pointer payload; the heap header retains the existing language tag. The
all-zero internal binding state is distinct from Number zero, false and null.
It is never exposed as an additional language value.

Functions return values directly and receive a borrowed array of 16-byte
values. Container elements, annotations and bindings use the same ABI:

| Storage | Layout |
| --- | --- |
| Frame | parent/count header: 16 bytes; each value/type/text binding: 48 bytes |
| Array | existing 32-byte header; each element: 16 bytes |
| Object | existing 32-byte header; each key/value bucket: 32 bytes |
| Closure | 72 bytes; code/env raw pointers; name at 40, annotations at 56 |
| Error | 88 bytes; kind/message/line/col/cause values at 8/24/40/56/72 |
| String | 48-byte header `{tag, buf, len, scalar-count, last-index+1, last-pos}`; separate byte buffer |

`aot/value_abi.ql` supplies the small allocation-free LLVM access helpers.
Trusted `ql_value_get`, `ql_value_store` and `ql_number_bits` intrinsics lower
to LLVM instructions, not new native C functions. JSON number conversion
continues to run in QLang, with exact bit construction and byte inspection of
inline numbers. The eleven C leaf functions and collector are unchanged.

This ABI trades wider container slots for removal of individual scalar
allocations and indirections. At that milestone, dynamic user calls still built language argument arrays.
The borrowed-call pass below removes ordinary temporary wrapper allocations;
strings, objects, closures and escaping environments still allocate.
General ownership cleanup and automatic cycle handling remain separate work.

The scalar counter-loop regression observes 521 total allocations for both
1,000 and 2,000 iterations (startup, call/container setup and printing included).
`t23_inline_values.ql` adds fixed-output checks for mixed container growth,
shared aliases, scalar snapshots, captured values, error fields, negative zero,
subnormal/maximum finite numbers and initialized-null versus uninitialized
bindings. The native core gate includes it as its seventh fixed fixture.

### Measured inline-ABI result

Three alternating uninstrumented runs per executable, with compilation excluded,
passed 419/419 assertions each. The previous lifetime-pass interpreter measured
2.176 seconds median wall time in this comparison, and the inline-value
interpreter measured 1.140 seconds (1.91x faster). The previous
2.626-second measurement was taken in a separate session; use this paired
comparison for the incremental speedup. Median process CPU was 2.121 versus
1.101 seconds. This runs the LLVM-compiled QLang core interpreter on the test
source, not direct AOT compilation of the type-gymnastics file.

Separate allocator instrumentation counted 94,840,123 -> 6,289,689
allocations (93.37% fewer). Cumulative requested bytes
fell from 1,676,744,552 to 418,043,312, and collections from 211 to 71. The
remaining 1,019,461 requests of 16 bytes include real small buffers; size alone
does not identify scalar boxes. The scalar constructors and operations no
longer allocate. The collector and its thresholds were not modified.

The diagnostic profile used the initial inline-ABI interpreter object. The
final rebuild removes unused emitter parameters and register names, and uses
a readable multiline form of the same helper IR. Final artifacts:

- Compiler: `target/value-check/final-self/stage2` (stage 2/3 IR identical).
- Interpreter: `target/value-check/final-core/interpreter`.
- Paired timings: `target/value-check/timing.json`.
- Allocation counts/profile: `target/value-check/profile.log`.

Validation logs under `target/value-check/` cover final self-compilation, seven
fixed core fixtures and all 419 type assertions, native/core semantic
comparisons, assignment contracts and failure exits, 30 JSON numeric boundary
cases, and lifetime/collection stress at both `-O0` and `-O2`.

## Borrowed call arguments (2026-09-26)

Ordinary generated calls now build their argument Array descriptor and inline
elements together in a fixed entry-block stack slot. The QLang dispatcher
`__call_borrowed` borrows this read-only list for one call, with LLVM lifetime
markers before initialization and after dispatch. Parameters copy individual
values into the callee's own bindings. A function can return a parameter, store
it, or capture it without retaining the caller's temporary descriptor. Shared
objects retain their identity; scalar values remain snapshots.

The escape boundary is partial application. `__partial` first copies the list
into an owned Array, then captures that copy. Repeated calls at a reused stack
site therefore produce independent partials. This is a shallow slot copy:
object/array arguments still refer to the same objects. Completing a partial
currently still creates a combined argument Array; this dynamically-sized
concatenation has not been converted to stack storage.

The mode-4 partial thunk, mode-5 Error constructor and mode-6 Math extrema
consume the borrowed list synchronously. Their one-argument invocation wrapper uses a raw stack
buffer. Literal argument lists used for dynamic annotation predicates also
borrow stack storage. Ordinary Array literals and arrays explicitly passed
as values keep their heap semantics. Evaluation order, arity checks, Error
argument policy, annotations and recursion-depth checks remain in the QLang
dispatcher. No function or error check is bypassed by this optimization.

The dedicated dispatcher name is a runtime contract: new emitters reject an
older runtime without `__call_borrowed`, rather than silently allowing it to
capture stack storage. A private `__call` alias permits bootstrapping with
older emitters whose argument lists were heap allocated.

`aot/run_call_tests.py` checks the following at both `-O0` and `-O2`:

- Fixed outputs for partial snapshots, shared aliases, escaped closures,
  computed callees, native/user call policies, annotations and Error causes.
- Retained values surviving 20,000 iterations of allocation churn.
- Equal allocation counts for 1,000/2,000 annotated calls through an array of
  function aliases, including dynamic predicate dispatch and variadic Math calls.
- 100,000 calls under a 1 MiB stack limit, with all LLVM allocas in entry blocks.
- Rejection of an incompatible runtime before any IR is emitted.

General reference counting, shared-object destruction and automatic cycle
handling remain separate work. This pass removes temporary call allocations;
it leaves the existing allocator and collector unchanged.

### Measured borrowed-call result

The annotated call loop makes 525 total allocations for either 1,000 or 2,000
iterations at both optimization levels; the increase per additional call is
zero. This count includes startup, persistent fixture state and printing.

Three alternating runs per executable, with compilation and profiling excluded,
passed 419/419 assertions each. This session's inline-value baseline measured
1.768 seconds median wall time; borrowed calls measured 1.671 seconds,
a 5.50% reduction. Median process CPU was
1.639 -> 1.537 seconds. The earlier 1.140-second
inline-value result came from a separate session; compare the paired runs
for this change's incremental effect. These timings execute the type-gymnastics
source with the LLVM-built core interpreter.

Separate instrumentation counted 6,289,689 -> 2,931,016 allocations
(53.40% fewer), and 418,043,312 -> 345,854,488 cumulative requested
bytes. Collections fell from 71 to 61 with unchanged allocator thresholds.
Allocation-count reduction is larger than the reduction in bytes or execution
time: many eliminated requests were small argument buffers, while object
lookup, string hashing/comparison and the existing collector remain active.
These byte counts are cumulative requests, not peak memory.

Verified compiler: `target/call-check/final-self/stage2`; stage 2/3 IR matches.
Verified interpreter: `target/call-check/final-core/interpreter`. Logs for
self-compilation, eight fixed interpreter fixtures, 419 type assertions,
call-buffer contracts, semantic comparisons and collection stress are under
`target/call-check/`. Paired timings are in `timing.json`, and allocation
instrumentation in `profile.log`.

## Native loader address-space fix

Dynamic extensions require the platform loader. The raw allocator no longer
moves the process break, because libc/libdl can also allocate there. It reserves
an independent anonymous address range with PROT_NONE, enabling pages only as
allocations grow, while keeping the same slabs, root scanning,
thresholds and reuse rules. This is a correctness fix for coexistence with the
loader, not completion of deterministic reclamation or a new ownership model.
The O0/O2 allocator root/interior-pointer checks pass after the change.
