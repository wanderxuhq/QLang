# LLVM AOT backend

> **2026-10-31: the repository no longer contains Python.** Every `python3` /
> `*.py` command below is historical. Current build/test commands are the QLang
> drivers listed in [`docs/python-removal.md`](../docs/python-removal.md) §3.

Run commands from the repository root. The current native leaf runtime targets
AArch64 Linux/Android and needs `clang` with `lld`; the build path is QLang +
shell only.

```sh
aot/bootstrap.sh --self --compiler target/selfhost/stage2
S=$(dirname "$(target/tools/stdlib --compiler target/selfhost/stage2 | tail -1)")
target/tools/build aot/tests/t10_control.ql -o /tmp/control --stdlib-object "$S/stdlib.o"
/tmp/control
target/tools/build aot/run_tests.ql -o /tmp/run_tests --stdlib-object "$S/stdlib.o"
/tmp/run_tests "$S"
cargo test --offline
```

The core is the QLang implementation, not the retained Rust interpreter.
The shared pipeline is source -> QLang lexer/parser -> QLang AST -> QLang
interpreter or LLVM emitter. The parser normalizes syntax sugar; the LLVM
backend consumes Function/Parameter/Block nodes without depending on the
original spelling. Rust supplies the initial bootstrap runner. The resulting
native compiler rebuilds itself without Rust: stage 2/3 compiler IR is verified
byte-identical. This compiler milestone does not imply that every language or
standard-library feature has reached native parity.

The compiler is `aot/qlangc.ql`, written in QLang. It reuses the core lexer/parser
and emits textual LLVM IR. The CLI passes user source and `runtime.ql` separately
so internal raw calls are restricted to runtime code; the compiler emits the
runtime first. `runtime.c` provides
allocation, raw memory access, writing, exit, four filesystem syscall
wrappers and a raw entropy syscall (twelve leaf functions). File buffering,
UTF-8 validation, path handling, Math algorithms and language errors remain in
QLang. Canonical paths currently require Linux
`/proc/self/fd`. The generated entry point converts process arguments to QLang
strings and publishes its stack bound to the allocator.

## Current work

- Imports accept literal quoted or unquoted file paths at module top level
  and inside functions/control flow, as statements or expressions such as
  `let namespace = import ...`. Relative paths use the
  importing file's directory; canonical paths identify module instances and active initialization cycles. Files are read
  and parsed at compile time, with no source-file dependency in the executable.
- Each import initializes a fresh module frame, with independent
  execution and closure identity. Module locals are isolated from caller locals.
  Exports merge into the importing scope and also form the returned namespace.
  `export name`, `export { name, alias: value }`, named exports and re-exports
  are supported. Export values are snapshots of bindings (reference values
  still alias); `export let name = value` creates an export entry without
  declaring a module-local binding.
- Initialization errors return as import errors without merging exports or
  overwriting existing caller bindings/annotations. Importing a missing file,
  malformed dependency fails compilation with `CompileError`. Cyclic static
  graphs are accepted; re-entering an active initializer produces `ImportCycle`.
- Error fallback `??` evaluates its right operand only for an Error, preserving
  `null` and `false`. `?` and explicit returns leave the current function.
- All `else if` branches and `if` expressions are compiled. Branch declarations
  are local; each loop iteration with local declarations owns a new frame so
  escaping closures capture the correct variables. Empty frames are omitted.
- String/array truthiness, computed callees and chained calls are supported.
- Bare and parenthesized function parameters (`x -> ...`, `(x) -> ...`) and
  zero-argument forms (`-> ...`, `() -> ...`) share the same AST. Expression
  bodies are normalized to blocks. Invalid parameter lists produce parse
  errors, including non-identifiers, missing separators and missing arrows.
- Calls evaluate the callee and all arguments once, left to right. Function
  metadata controls arity and error-argument rules, including aliases, members
  and computed callees. Non-callable values return `NotCallable`; excess
  arguments return `ArityMismatch`. User functions support partial application;
  the resulting native partial requires the exact remaining argument count.
- Closures compare by identity. Array `add`/`remove` are first-class bound
  methods; ordinary object fields with those names keep their own behavior.
  User recursion has a recoverable 300-call guard, matching the host limit.
  Duplicate parameter names share one slot (last argument wins), preventing
  out-of-bounds frame writes.
- Object keys hash string contents. Empty string keys are distinct from empty
  buckets, including after table growth.
- `let x;` creates only a binding. Reading it produces `Uninitialized` until
  assignment; `null` remains an initialized value of type `Null`. Binding state
  is private frame metadata, with no additional language value. Undeclared
  reads/assignments fail compilation, including direct reads before declaration.
  Closures may capture later declarations in their enclosing scope.
- Variable and parameter annotations are evaluated once in the defining scope.
  Declarations and reassignment check the captured type; parameter checks run
  before the function body, including calls through partial applications. Error
  causes, custom predicates and annotation source text follow host behavior.
- An unhandled final Error is reported to stderr and exits with status 1, as
  does top-level `?` propagation. Executed empty branches clear the preceding
  statement value; a skipped branch without `else` preserves it.
- Field/index assignments evaluate the right side first, then the receiver and
  index once. Failed receivers, indices and setters return an Error from the
  current function/module, or exit with status 1 at top level. No later
  statements or index side effects run after a failed receiver. Error values
  may still be stored as data in valid fields/elements.
- The core interpreter applies the same assignment rules. Arrays reject
  nonnumeric, fractional, nonfinite and out-of-range indices; negative indices
  and appending at `length` remain supported. Objects reject keys other than
  strings/numbers before hash-table access. Canonical built-in type members
  `check`, `raise`, `of` and `make` are protected on both execution paths;
  user-defined type predicates and free fields remain writable.
- Unsupported AST nodes and unresolved names produce `CompileError` rather
  than a successful wrong binary.
- `std.JSON.stringify` is ordinary QLang in `stdlib/json.ql`, including container
  traversal and escaping. `std.JSON.parse` remains runtime-provided, with nested
  containers, escapes, surrogate pairs, duplicate keys, input errors and depth
  limits. Decimal parsing rounds once to binary64; stringify retains the existing
  exact Number.toString formatter. Key enumeration, parsing and complete numeric
  formatting portability remain unfinished; see the capability-gap document.
- String interpolation works in double quotes, single quotes and backticks.
  Each expression is evaluated and rendered once, from left to right; `?`
  propagates before later parts run. Nested strings/templates, brace-containing
  strings/comments, object expressions, function calls and `if` expressions
  retain ordinary expression parsing. Arrays/objects render recursively and
  user/native functions retain their textual representations.
- Unterminated strings/interpolations, mismatched interpolation delimiters,
  empty interpolations and trailing expression tokens are rejected. Quoted
  object keys remain literal keys. Ordinary string escapes include hexadecimal,
  Unicode scalars, NUL and line continuation; backticks permit literal newlines.
- LLVM string literals are encoded from Unicode scalars to actual UTF-8 bytes,
  including NUL, two-byte characters and emoji. String length, indexing, `at`
  and the documented curried `codePointAt` use Unicode scalar indices. Empty
  separators in `String.split` terminate and preserve whole Unicode scalars.
- The allocator conservatively traces raw pointers in the stack, saved registers
  and live allocation blocks. It reclaims unreachable blocks without moving live
  values, including blocks reachable through interior pointers. Slabs are reused;
  reserved pages stay mapped until exit. This is a single-threaded allocator
  with a 4 GiB arena bound. Embedders must publish a stack bound to enable GC.
- Native arrays store capacity separately from length and grow geometrically.
  Both method appends and `array[array.length]` writes use the same path.
- Trusted runtime word reads/writes lower to LLVM loads/stores, avoiding the
  temporary allocations of byte-by-byte numeric decomposition.
- Imported module code is emitted once per canonical path. Each import still
  executes a fresh factory with fresh variables, namespace tables and closures.
- LLVM numeric constants use exact JSON number conversion, independently of
  display formatting. Decimal parsing uses the same correctly rounded path.
- Native programs receive `args` without the executable name. Native
  `std.fs.readFileText` and `std.fs.canonicalPath` report `IOError`/`TypeMismatch`;
  text reading validates UTF-8 and preserves embedded NUL bytes. NUL in a path
  is rejected before invoking the OS.

`t10_control.ql`, `t10_objects.ql`, `t11_json.ql`, `t12_calls.ql`,
`t13_bindings.ql`, `t14_interpolation.ql`, `t15_modules.ql` and `t16_functions.ql`
compare the core interpreter (BOOT) with NATIVE. Where present, `.expected`
fixtures also assert the language contract independently of either engine.
Rust interpreter comparisons are optional: set `QLANG_CHECK_RUST=1` for both
`run_v1_tests.sh` and `run_module_tests.py`. Rust remains the bootstrap runner
even when its direct-interpreter compatibility checks are disabled.
`bootstrapped/tests/function_ast.ql` checks the shared AST contract directly.
The runner checks exit statuses, enforces timeouts, isolates artifacts, and checks
that unsupported features fail compilation. Older `t8_*` / some `t9_*` files
use internal runtime helpers and are not all suitable for direct HOST execution.

## Remaining M3 work

M3 is **not complete**. In particular:

- Multi-key object JSON serialization order is not a byte-parity guarantee:
  host maps and native hash buckets may traverse fields differently. Compare
  parsed contents when object key order is not part of the intended contract.
- Literal imports and exports now work inside functions and control flow;
  their extended native gates are in progress. Lazy cycles are implemented
  and under validation. Computed `import (path)` loads a separately compiled native
  extension and returns a namespace; all 28 standalone contracts pass at O0/O2.
  The native QLang AST interpreter also loads these extensions through its
  private value bridge, preserving callbacks, aliases and canonical types.
  Literal dependencies are embedded at compile time, with definition-site paths. See [module semantics](../docs/module-semantics.md).
- Standard-library namespace tables are now isolated per file in both BOOT and
  NATIVE. Canonical type objects retain shared identity; free-field mutations
  on those type objects are still a separate isolation boundary.
- Default Array and String algorithms now come from the shared QLang library, including
  Unicode 15.1 casing and whitespace. Codepoint access still needs a portable
  primitive boundary; other standard-library families remain to migrate.
- Finite numeric rendering in printing, interpolation and `std.Number.toString`
  preserves exact safe integers and otherwise uses the existing shortest
  round-trip QLang decimal converter. This also fixes numeric object keys parsed
  by the native compiler. Portable representation access remains a separate
  [library capability gap](../docs/stdlib-capability-gaps.md).
- Interpolation does not include host source positions in rendered error
  diagnostics. Object field traversal order is not guaranteed to match the host.
- Standard-library argument type validation, several missing built-ins and
  standard-library edge cases still differ from the host.
- Before the shared-library migration, `demo/type_gymnastics.ql` passed 419/419
  in the core interpreter on both the Rust bootstrap and native runtimes.
  The latest Array/String loader revision is undergoing that full gate again. Direct AOT compilation of that demo still
  rejects its deliberately undeclared `undefined` name read. The native
  interpreter can evaluate that read as an error; no `undefined` value is added.

The host's postfix `?` previously evaluated its operand twice. This is fixed and
covered by `tests/error_propagation.rs`. JSON crash/validation regressions are in
`tests/json.rs`. The boot interpreter now gives branches/iterations child scopes
and treats empty arrays as false, matching the host. JSON native calls now
recursively unwrap/wrap containers at the boot boundary, preserving ordinary
user fields named `type` and `value`. HOST, BOOT and NATIVE reject excessively
deep/cyclic JSON serialization rather than exhausting the call stack.

The boot call bridge now handles zero arguments, exact partial arity, the first
error argument as the cause, and bound array methods. Type predicates may mutate
their captured environment during annotated reassignment: the host now releases
its environment borrow before invoking user code, avoiding a `RefCell` panic.
This is covered in `tests/type_system.rs`. The boot environment also clears
stale initialization/annotation state on redeclaration, respects unannotated
shadows, and evaluates declaration annotations before initializers. Its statement
runner preserves the last expression across declarations, assignments, loops
and untaken branches, matching the host and native backend.

## Native bootstrap checks

```sh
QLANG=./target/release/qlang python3 aot/run_platform_tests.py
QLANG=./target/release/qlang python3 aot/run_gc_tests.py
# Build a stage-1 native compiler, then compile function and frontend contracts:
QLANG=./target/release/qlang python3 aot/run_selfhost_tests.py
# Also require stage 2/3 to emit byte-identical compiler IR:
QLANG=./target/release/qlang python3 aot/run_selfhost_tests.py --self --output-dir target/selfhost
```

A native compiler accepts `qlangc --emit-llvm source.ql aot/runtime.ql` and emits
LLVM IR on stdout. `python3 aot/native_link.py output.ll -o output` links
the result and checks its static strings before publishing the executable.
Python only drives Clang and inspects ELF bytes; parsing, AST compilation and
language semantics remain in QLang. The Rust bootstrap CLI's source-text
invocation remains supported. The selfhost runner can reuse a binary with
`--compiler /path/qlangc`.

Verified on 2026-09-23: stage 1 compiles the function, numeric-literal and frontend
contracts; the native frontend passes all 18 AST checks. Stage 1 builds stage 2,
and stage 2 emits byte-identical stage-3 compiler IR. Stage 2 also compiles and
runs the function contract. These checks run with the native compiler and Clang.
The resulting executable is `target/selfhost/stage2` when using the command above.

The full AOT regression passed 22 program comparisons, 13 compile rejections
and 8 native exit-status cases. The separately verified `t19_literals.ql` has
been added to the default program list, bringing it to 23.

Four native compiler rejection cases cover undeclared names, missing modules,
invalid parameters and incomplete runtime sources; failures emit no IR.
Platform contracts and descriptor cleanup pass. GC tests at `-O0` and `-O2`
preserve closures, cycles, large buffers, interior pointers and aliases across
array growth. The existing module suite and 30 JSON numeric boundary/random
cases also pass. `t19_literals.ql` separately verifies 16 exact-number results.

The interpreter now owns private standard-library namespace tables per module;
user mutation cannot rewrite its internal formatting or file APIs. String
conversion renders wrapped arrays/objects at the QLang boundary. LLVM constants
use exact numeric conversion, fixing the previous truncation of `3.14159` to `3`.

## Native core interpreter

The native compiler can also compile `bootstrapped/run_file.ql`, including the
QLang interpreter and its frontend, into a standalone executable:

```sh
python3 aot/run_interpreter_tests.py --compiler target/selfhost/stage2 --output-dir target/native-interpreter
target/native-interpreter/interpreter aot/tests/t16_functions.ql
```

This gate invokes the native compiler and Clang, with no Rust runner. Fixed
contracts exercise functions, annotations, module namespace isolation, numeric
literals, JSON and errors; the type-system demo passes all 419 assertions.
It also checks dynamic imports inside interpreted
functions, paths relative to their defining modules, and failing process exit
statuses for unhandled errors. Dependencies of the interpreter itself are
compiled into the binary; files imported by interpreted programs are loaded
when those programs execute. The CLI currently accepts a source-file path and
prints the existing interpreter progress messages.

Native functions expose their diagnostic `.name` metadata to the interpreter's
call bridge; ordinary QLang closures do not. Error fields support both dotted
and computed string access. `Error.raise(message)` and
`Error.raise(message, cause)` construct error values, including through aliases,
without partial application. The entry script unwraps unhandled interpreter
errors into the runtime error channel, yielding exit status 1. This is distinct
from `runSource`, whose API continues to return an interpreter result record.
The core interpreter also rejects assignment to undeclared/out-of-scope names
and propagates errors when writing through an uninitialized receiver. Assignment
checks binding presence independently of the value stored in that binding.

Verified on 2026-09-23: all native interpreter contracts and twelve failing-exit
cases pass. A supplementary run of 23 existing programs produced identical
output on the native and Rust-hosted instances of the core interpreter.
`t20_native_bridge.ql` also passes both BOOT and direct AOT execution; it is now
part of the default AOT program list (24 programs).

## Assignment regression checks

After building a compiler from the current sources, run:

```sh
python3 aot/run_assignment_tests.py --compiler target/selfhost/stage2
# Also run the contracts through a previously built native core interpreter:
python3 aot/run_assignment_tests.py --compiler target/selfhost/stage2 --interpreter target/native-interpreter/interpreter
```

`t21_assignments.ql` fixes the expected output for 42 checks, covering failed
writes at function boundaries, protected members, evaluation order, aliases,
error values stored as data, successful nested writes and loop exits. The
runner also checks 17 failing top-level programs and module export isolation
after a failed write. The fixture is included in the default AOT and native
interpreter suites (the AOT program list now contains 25 programs).

Verified on 2026-09-23: the 42 fixed outputs, 17 top-level failures and module
export-isolation case pass on LLVM. The native core interpreter also passes the
42 outputs and 17 top-level failures. The updated compiler again emits identical
stage-2/stage-3 IR. A complete native-interpreter rebuild passes all 419 type
assertions and existing exit checks. Native regressions for control flow,
objects, JSON, calls, bindings, interpolation, modules and GC also pass.
The current verified compiler/interpreter are retained at
`target/assignment-check/self/stage2` and
`target/assignment-check/core/interpreter`; their verification logs are beside
the binaries.

## Checked native linking

One interpreter link produced an executable with missing static-string buffer
relocations (1,181 dynamic relocations instead of 1,991), causing a crash before
startup. A retained valid object contains all 809 string-buffer relocations.
Further links using fixed object files independently reproduced an LLD process
abort; the successful outputs were byte-identical. Twelve consecutive links
with `--threads=1` also produced that identical executable. This establishes
external linker instability in the local toolchain, but does not establish the
internal cause of the original malformed link or prove a threading defect.

`native_link.py` now uses single-threaded LLD and validates each QLang static
string against its input IR: object tag, byte length, buffer relocation and
exact buffer bytes. It reads the loader's dynamic table rather than relying on
section relocation counts. Only a successfully linked and validated temporary
file replaces the requested executable, so failures preserve an existing
working binary. No automatic retries are used.

The self-host, native-interpreter, assignment and GC runners use this helper.
The retained Rust `--compile` CLI also requests single-threaded LLD, but does
not invoke the Python ELF checker. Direct Clang invocations bypass the checker.

```sh
python3 aot/native_link.py output.ll -o output
# Check an existing executable without linking or running it:
python3 aot/native_link.py output.ll -o output --check-only
python3 aot/run_link_tests.py
# Optional local regression against the retained incident artifact:
python3 aot/run_link_tests.py --historical-dir target/assignment-check
```

The checker supports the current backend's unstripped AArch64 ELF64 output
with ordinary RELA relocations; run it before stripping symbols. It checks the
static-string ABI, not every property of an executable. Regression coverage
includes real links at `-O0`/`-O2`, UTF-8, embedded NUL, empty strings, damaged
ELF headers and string contents, missing loader relocations, and preservation
of the previous executable on both reported and silent link failure. The
retained malformed interpreter is rejected while its valid counterpart passes
all 809 string checks.

Verified on 2026-09-23 through this helper: the rebuilt native compiler passes
1,144 string checks and the interpreter passes 809. The rebuilt interpreter
passes all five fixed-output fixtures, 419 type assertions, dynamic imports,
12 error-exit cases and initialized-null handling. Direct native bridge and
function-metadata contracts also pass. These executables and logs are under
`target/link-check/`. The retained Rust CLI builds successfully and its
compiled assignment fixture matches all 42 expected outputs.


## Core-first validation (2026-09-23)

- QLang frontend contracts: 11 valid AST cases and 7 invalid parameter cases passed.
- The core frontend also parsed its lexer, parser, interpreter, standard library
  and LLVM compiler sources successfully. This checks source parsing, not full
  native self-compilation.
- `t16_functions.ql`: BOOT and NATIVE matched all 13 fixed expected output lines.
- All 8 native exit-status cases passed, including uninitialized reads and
  initialized `null` bindings.
- Existing call, binding, interpolation and module AOT regressions passed
  against the core interpreter.
- Core module suite: standalone execution, initialization errors, definition-site
  paths and all 11 compile-rejection cases passed.
- The existing HOST/BOOT and Node compatibility suite passed again, with native
  differential cases disabled for this run.
- Optional Rust compatibility for `t16_functions.ql` currently fails because the
  retained Rust parser rejects the core's `-> 9` zero-argument spelling. This
  does not change the core syntax or invalidate its BOOT/NATIVE contract.

## Earlier validation (2026-09-23, before core-first gates)

- `cargo test --offline`: 46 integration tests and 14 doc tests passed.
- AOT runner: 20 HOST/BOOT/NATIVE comparisons, 13 compile-rejection checks and
  8 HOST/NATIVE exit-status cases passed.
- `difftest.py`: 291 HOST/BOOT cases and 102 Node reference cases passed again.
  The previous full native differential gate passed 101 cases; this round
  reruns the AOT programs above, including the new module regression.
- Module suite: standalone execution after deleting all inputs, initialization
  error exit status, HOST/BOOT definition-site imports, and 11 rejection cases
  (including canonical cycles and private-name isolation) passed.
- HOST and BOOT type gymnastics: byte-identical, 419/419 assertions passed.
- LLVM verifier accepted the control-flow and JSON/Unicode regression modules;
  the `-O2` native executables produced the same output as HOST. The new call
  and binding regressions also passed verification and HOST comparison at `-O2`.
  Interpolation and module regressions also passed both checks.
- JSON numeric differential: 30 boundary/seeded-random cases matched HOST,
  including subnormals, largest finite values and exact rounding midpoints.
- Leaf allocator checked for alignment, preserved data across chunk growth and
  rejection of an overflowing allocation; seven leaf functions remain.

The differential runner defaults to one native compilation at a time. Set
`QLANG_TEST_JOBS` to opt into parallel compilation; each case has its own source
and executable, compile/run timeouts, and an exactly-one-result check. Native
scratch directories are cleaned up on completion.

Host interpolation now reuses ordinary tokenization, retaining nested braces,
quotes and comments. Its parser requires exactly one expression per part; the
lexer rejects unfinished backticks and preserves outer string spans. These
regressions are covered by `tests/interpolation.rs`.

Host module fixes are covered by `tests/modules.rs`: imports no longer discard
initialization errors, function imports retain definition paths/source positions,
canonical cycles fail without recursive loading, and file-read failures are Error
values rather than strings masquerading as source. The boot interpreter now
loads user modules through `bootstrapped/modules.ql`; the compiler uses the same
path and parser helpers. No native C leaf functions were added.


## Compiler-proven lifetimes (2026-09-24)

`aot/lifetime.ql` analyzes the QLang AST for possible lexical-frame capture.
Frames proven local use stack storage; captured frames remain on the heap.
Raw invocation buffers also use stack storage. Scalar values use the inline
ABI described below, including returned and stored numeric results. All stack slots are allocated at function entry,
so loops reuse bounded storage. Frame and call-buffer lifetime markers identify
safe storage-reuse points. This preserves existing aliases, escaping closures and error exits.

This is a conservative compiler optimization, not a completed replacement for
the current collector. General shared-object destruction and automatic cycle
handling remain separate work. See the [lifetime design and boundaries](../docs/memory-management-transition.md).

```sh
python3 aot/run_lifetime_tests.py --compiler target/selfhost/stage2
```

`t22_lifetimes.ql` is included in the default AOT list and the
native interpreter gate. The dedicated runner additionally checks 100,000 loop
iterations under a 1 MiB stack at `-O0` and `-O2`, entry-block-only stack
allocation, and zero additional scalar-loop allocations using an instrumented allocator.
It covers later uses, aliases, escaped results, per-iteration closures, error
causes and negative zero. The core interpreter's unary negation was corrected
to preserve negative zero instead of implementing it as subtraction from zero.

Verified native compiler: `target/lifetime-check/final-self/stage2`; interpreter:
`target/lifetime-check/final-core/interpreter`. Stage-2/stage-3 compiler IR matches.
The final native core gate passes all six fixtures and 419 type assertions.
Three alternating timings per interpreter give medians of 24.48s before
and 2.63s after (9.3x). Separate allocation instrumentation shows
806,545,717 -> 94,840,123 allocations (88.2% fewer), with no collector tuning.
Timings and counts are retained under `target/lifetime-check/`.

## Inline values and native calling convention (2026-09-24)

Numbers, Booleans and null are now passed and stored by value as two 64-bit
fields, including return values, bindings, array elements and object fields.
Numbers preserve all binary64 bits; heap references preserve the full pointer.
Uninitialized bindings remain internal state, distinct from zero, false and
initialized null. This changes the generated ABI: rebuild LLVM artifacts
together with the matching QLang runtime. No QLang source syntax changes.

The representation helpers are in `value_abi.ql`; the language runtime remains
QLang. No C leaf functions were added. Container slots are wider, while
scalar heap boxes and the associated allocation work disappear. Shared heap objects still allocate; ordinary call argument borrowing is
described below. These changes do not yet replace the existing collector. See the [ABI layout and validation](../docs/memory-management-transition.md#inline-scalar-and-call-abi-2026-09-24).

`t23_inline_values.ql` joins the default AOT list (27 programs), the native
compiler fixture gate and the native core gate. The lifetime runner requires
the same allocation count for 1,000 and 2,000 scalar-loop iterations. The
numeric and collection regressions can also use a native compiler directly:

```sh
python3 aot/run_json_numeric_tests.py --compiler target/selfhost/stage2
python3 aot/run_gc_tests.py --compiler target/selfhost/stage2
```

Verified compiler: `target/value-check/final-self/stage2`; verified interpreter:
`target/value-check/final-core/interpreter`. Stage 2/3 LLVM IR is identical;
all seven core fixtures and 419 type assertions pass. Paired timings of the
previous and current interpreters are 2.18s -> 1.14s median
(1.91x), with compilation excluded. Separate instrumentation reports
94,840,123 -> 6,289,689 allocations. Results are retained under
`target/value-check/`; the [transition audit](../docs/memory-management-transition.md)
records layout, measurement details and the remaining ownership work.

## Borrowed call argument lists (2026-09-26)

The QLang compiler now uses fixed stack storage for ordinary call argument
lists, including computed callees and dynamic annotation predicates. The
QLang dispatcher retains all arity, Error-argument, annotation and recursion
checks. Partial application copies the bound list before capturing it, while
preserving the identity of reference arguments. Completing a partial still
allocates its combined argument array. Actual language Array values retain
their ordinary heap behavior.

The new `__call_borrowed` runtime entry is required: mixing a new emitter with
an older runtime is rejected. LLVM lifetime markers bound the borrow; slots
live in function entry blocks and are reused across loops. The runtime's
collector is unchanged.

```sh
python3 aot/run_call_tests.py --compiler target/selfhost/stage2
```

`t24_call_buffers.ql` is included in the default AOT list (28 programs), native
compiler tests and the native interpreter gate (eight fixed fixtures). The
dedicated runner checks retained partials and allocation churn at `-O0`/`-O2`,
zero per-call allocation growth for annotated calls, and 100,000 calls within
a 1 MiB stack. See the [borrowing contract](../docs/memory-management-transition.md#borrowed-call-arguments-2026-09-26).

Verified compiler: `target/call-check/final-self/stage2`; interpreter:
`target/call-check/final-core/interpreter`. The compiler fixed point, eight
core fixtures and 419 type assertions pass. The annotated-call allocation
counts are 525/525 for 1,000/2,000 iterations at both optimization levels.
On the full type-gymnastics run, separate instrumentation counted
6,289,689 -> 2,931,016 allocations (53.4% fewer). This session's
paired median times were 1.77s -> 1.67s (5.5% less
time). Measurements and validation logs are under `target/call-check/`.


## Numeric correctness (2026-09-26)

Unary negation checks the operand type and evaluates it once. Floating remainder
handles the entire finite binary64 range in QLang; numeric bitwise conversion
truncates and saturates instead of allowing out-of-range LLVM conversion poison.
`Number.parseFloat` consumes a complete trimmed decimal string, supports signed
zero, exponents and special values, and returns NaN for malformed input.

Math algorithms remain entirely in QLang: normalized square root, integral
powers and high-precision intermediate log/exp for general powers, and a
1216-bit range reducer for sine/cosine. `Math.random` constructs a 53-bit result
from raw OS entropy, with short-read, interruption and failure handling in QLang.
No system math library is linked. See [numeric semantics and limits](../docs/numeric-semantics.md).

```sh
python3 aot/run_numeric_tests.py --compiler target/selfhost/stage2
python3 aot/generate_math_constants.py
```

`t25_numeric.ql` adds 83 fixed checks to the native compiler and core interpreter
gates and brings the default AOT list to 29 programs. The dedicated numeric
runner verifies 792 deterministic boundary/random cases at both `-O0` and `-O2`,
checks the absence of external math symbols, and injects entropy failures.
The generator independently reproduces the checked-in trigonometric constant;
it is a development utility, not part of program execution.

Verified compiler: `target/numeric-check/self/stage2`; interpreter:
`target/numeric-check/core/interpreter`. Stage 2/3 LLVM IR is identical. All nine
core fixtures, 419 type assertions, numeric checks, 30 JSON numeric cases,
call-buffer contracts and existing allocator stress checks pass. Validation logs
are retained under `target/numeric-check/`. This is a correctness milestone;
no new performance measurements or collector changes are included.


## Variadic Math extrema (2026-09-26)

`Math.min/max` now consume the full argument list in QLang, including zero,
one and more than four arguments. Native function policy 6 passes a borrowed
read-only argument array after ordinary Error-argument validation. The reducer
never retains it. The interpreter handles these reductions through the original
function value, so aliases and imported members work while user replacements
continue to use ordinary function dispatch.

Empty calls return the appropriate infinity. NaN propagates, later invalid
types still produce errors, and mixed signed zeros select +0 for max / -0 for
min. The retained Rust implementation follows the same explicit contracts.
See [numeric semantics](../docs/numeric-semantics.md) for details.

`t26_extrema.ql` adds 51 fixed checks to the numeric, selfhost and native core
suites. The default AOT list now contains 30 programs and the native core gate
has ten fixed fixtures. The call-buffer stress test also exercises variadic
computed callees repeatedly under a 1 MiB stack at `-O0` and `-O2`.

```sh
python3 aot/run_numeric_tests.py --compiler target/selfhost/stage2
python3 aot/run_call_tests.py --compiler target/selfhost/stage2
cargo test --offline --test math_extrema
```

Verified compiler: `target/extrema-check/self/stage2`; native core interpreter:
`target/extrema-check/core/interpreter`. Stage 2/3 emit byte-identical LLVM IR.
All ten interpreter fixtures and 419 type assertions pass. The 51 extrema
contracts pass on direct AOT at both optimization levels, the native core,
the Rust-hosted core and the retained Rust interpreter. Numeric and call-buffer
suites pass; logs are retained under `target/extrema-check/`.


## Native argument-list bridge (2026-09-26)

The self-hosted interpreter now forwards native argument lists through the
internal `std.__callNative(function, arguments)` bootstrap ABI. The QLang runtime
validates the list and delegates to its existing call dispatcher; the retained
Rust bootstrap does the same through its call context. No C leaf or LLVM emitter
change is needed. This is an implementation API, not new spread syntax or a
public function-application feature for interpreted user functions.

The previous bridge expanded only zero through four arguments and accidentally
passed larger lists as one Array. That could make `JSON.stringify(1,2,3,4,5,6)`
serialize the list or make `println` print it, instead of rejecting the arity.
The old native interpreter also crashed on `Object.keys(1,2,3,4,5,6)` after
mistaking the arguments for one Array; the rebuilt interpreter reports
`ArityMismatch` and exits normally when that error is handled.
All native calls now retain positional arguments and the target's arity and
Error policy. The temporary extrema-specific folding branch is removed.

User functions still use the AST interpreter; its type-library QLang helpers
retain their wrapper-aware unary path. JSON wrapping/unwrapping and interpreter
String rendering retain their existing boundaries. User namespace mutations
cannot replace the interpreter's private call bridge.

`t27_native_calls.ql` adds 32 fixed checks for native arities, aliases, returned
curried natives, bound methods, Error causes, ordered effects, explicit `?`
propagation and namespace isolation. The call runner executes it at `-O0` and
`-O2`; it is also included in the selfhost and native interpreter gates and as
a Rust integration test. The default AOT list has 31 programs; the native core
gate has eleven fixed fixtures.

```sh
python3 aot/run_call_tests.py --compiler target/selfhost/stage2
python3 aot/run_interpreter_tests.py --compiler target/selfhost/stage2
cargo test --offline --test native_calls
```

Verified compiler: `target/native-call-check/self/stage2`; core interpreter:
`target/native-call-check/core/interpreter`. Stage 2/3 compiler IR is identical.
All eleven native core fixtures, 419 type assertions, call-buffer checks and the
full offline Rust test suite pass. The new contract also passes on the
Rust-hosted core. Logs and the before/after crash reproduction are retained in
`target/native-call-check/`.


## Object validation and stored values (2026-09-26)

Object APIs now reject invalid receiver/key types before accessing raw table
memory. Curried APIs validate each stage. Presence probing no longer infers
absence from an Error-valued result: `hasOwn` reports stored Error fields as
present and `get` preserves their values. Strict `field` access reports a missing
field with its name. The self-hosted interpreter preserves retrieved wrappers,
function identity and mutable aliases, while rejecting its internal function
records as Object receivers.

See [Object contracts](../docs/object-semantics.md). `t28_objects.ql` adds 98 checks
to the selfhost and core gates. The default AOT list contains 32 programs and
the native core gate has twelve fixed fixtures. A dedicated runner verifies
both successful contracts and eight unhandled invalid-input cases at `-O0` and
`-O2`:

```sh
python3 aot/run_object_tests.py --compiler target/selfhost/stage2
cargo test --offline --test object_stdlib
```

Verified compiler: `target/object-check/self/stage2`; core interpreter:
`target/object-check/core/interpreter`. Stage 2/3 compiler IR is byte-identical.
All twelve core fixtures and 419 type assertions pass. The Object suite passes
at both optimization levels, including eight failing-exit cases; the same 98
contracts pass in the Rust-hosted core and retained Rust interpreter. Existing
allocator stress tests also pass. Logs are retained under `target/object-check/`.


## Array validation, identity and stored values (2026-09-26)

Array APIs now validate receivers before raw storage access. Curried operations
validate both stages where appropriate. `get` probes invalid indices with null,
`at` reports index/type errors, and `remove` keeps its invalid-index no-op
contract. Indices must be finite integers, with negative indices supported.

`reverse` and `concat` preserve stored Error elements. Retrieved functions remain
callable, and inserted/retrieved aggregates retain shared identity through the
self-hosted interpreter. Search uses scalar equality and aggregate/function
identity, skips Error elements and terminates for cyclic aggregates. `join` and
`toString` render nested values using the existing interpolation formatter.

See [Array contracts](../docs/array-semantics.md). `t29_arrays.ql` adds 174 checks
to the selfhost and native core gates. The default AOT list contains 33 programs;
the core gate contains thirteen fixed fixtures. The dedicated runner also
checks eight unhandled invalid-input cases at both optimization levels:

```sh
python3 aot/run_array_tests.py --compiler target/array-check/self/stage2
python3 aot/run_interpreter_tests.py --compiler target/array-check/self/stage2
```

This work changes only QLang implementations and supporting tests/docs. Existing
Rust changes from earlier milestones remain; additional Rust discrepancies are
[recorded separately](../docs/retained-rust-issues.md). The Rust-hosted QLang core
uses QLang adapters to avoid the retained host's index truncation and recursive
aggregate search behavior. Direct Rust compatibility is deferred.

The 174 contracts pass on direct LLVM output at `-O0`/`-O2`, the native QLang
core and the Rust-hosted QLang core. All thirteen native core fixtures and 419
type assertions pass, as do the existing native-call and call-buffer suites.
The eight unhandled Array errors exit with status 1 at both optimization levels.
The rebuilt core is `target/array-check/core/interpreter`; logs are retained
under `target/array-check/`.
The rebuilt compiler is `target/array-check/self/stage2`. Its stage 2/3 LLVM IR
is byte-identical, and the complete requested selfhost gate passes.


## Portable standard-library migration (2026-09-26, in progress)

The standard library must be ordinary QLang shared across execution engines.
LLVM owns language mechanisms, not a second collection of library algorithms.
String algorithms live in `stdlib/string.ql`, with generated Unicode data in
`stdlib/unicode_data.ql`; Array algorithms live in `stdlib/array.ql`. Both supply
the default namespace through the shared source loader. Their old backend
implementations have been removed. Base Math, Number parsing/predicates, Object
algorithms and JSON.stringify are also installed through that loader. JSON.parse,
Number formatting, key reflection, filesystem and remaining Math still need
migration or an agreed language/host boundary.
The [library guide](../stdlib/README.md) describes their contracts and tests.
The independent Unicode runner covers 2,927 scalars with nonidentity mappings,
contextual sigma strings and Unicode whitespace.

[Missing portable capabilities](../docs/stdlib-capability-gaps.md) include
variadic function parameters, intentionally accepting Error arguments, numeric
codepoint conversion, binary64 representation and external-effect primitives.
The current code must not hide those gaps behind new backend-only library
implementations. Shared loading is implemented; migration of the remaining
library families is still required. Dynamic extensions and output-only source
diagnostics have since passed their integrated gates; their remaining limits
and current evidence are maintained in the compiler roadmap.


## Default shared QLang library loading

`stdlib/build_bundle.ql` now packages the library source in QLang. Python is used
only for Unicode data generation and tests, not source bundling or runtime
execution. Both the compiler and interpreter consume `bootstrapped/library.ql`.
The compiler emits library AST through ordinary user-function code generation;
the core evaluates ordinary function records in a private bootstrap scope.
Public std namespace tables remain separate per module.

String, Array, base Math, Number parsing/predicates, Object algorithms and
JSON.stringify receive ordinary QLang members through the shared manifest.
Their migrated backend algorithms and corresponding interpreter adapters have
been removed. This does not mean every member of each namespace is portable.
Unicode string length/indexing and bound Array add/remove remain language
mechanisms; `codePointAt` is the documented transitional primitive. Migrated
functions use ordinary QLang partial application without native name/arity rules.

`t29_arrays` tests 176 contracts, `t30_strings` tests 193, and
`t31_library_loading` tests 18 installation/isolation cases. Array and loading
checks pass at O0/O2 and through the native core; String's complete Unicode
suite passed before Array installation. `t32_value_access` adds 37 direct
language checks for invalid numeric indices and private function records, passed
at O0/O2 and through the native core. The source bundle is generated in QLang.
String-loader selfhost completed with byte-identical stage 2/3 IR
(`target/library-scan-check/self.log`). Later Number/Object revisions passed
full core/selfhost integration. JSON.stringify passed focused integration,
including 419 type assertions and stage2/stage3 equality; its shared-library
migration does not complete the remaining runtime families. See the current
[compiler roadmap](../docs/compiler-next-steps.md) for applied revisions and
verification scope; these older logs are historical evidence, not live jobs.

## Parse diagnostics (2026-09-27)

The shared QLang frontend now reports `file:line:col` for lexical and parse
failures, preserving Unicode scalar columns, CRLF/lone CR and nested
interpolation coordinates. Missing delimiters/declaration names/member names,
invalid assignment targets and unterminated block comments are rejected.
Parser errors are collected consistently and cannot silently execute as null.
The core rejects malformed root input before initializing its execution scope.

The 24-invalid/10-valid frontend fixture and existing function AST contract pass.
Compiler/core CLI tests pass for root and imported sources and core function
imports (`target/diagnostics-check/cli.log`). Subsequent integrated parse,
semantic and runtime diagnostic gates passed on the applied extension revision.
See [diagnostic contracts](../docs/source-diagnostics.md) and the current roadmap
for that evidence and the deferred program-readable Error information.

## Nested literal modules and lazy initialization

The LLVM loader now walks the shared AST to find nested literal imports. Their
execution remains at the original expression, with local bindings and fresh
module instances. Function and conditional exports target the defining module;
skipped exports preserve the importer's previous bindings and annotations.
The QLang core's imported/partial functions now preserve export-table ownership.

The 22-contract fixture passed the core and LLVM O0/O2; the dedicated source-
removal runner also passed. Subsequent integrated core/selfhost gates covered
scoped modules. Computed paths use the native-extension mechanism below.

Lazy cyclic graphs now compile. Runtime initialization flags detect active
re-entry and are cleared on normal/error exits. Nine targeted contracts pass
QLang core and LLVM O0/O2. Integrated core/selfhost and extension gates passed
on the applied bridge revision (`target/core-extension-integrated/`). Library
unloading and finer bridge-value reclamation remain unimplemented.

## Independently compiled native extensions

```sh
qlangc --emit-llvm app.ql aot/runtime.ql > app.ll
python3 aot/native_link.py app.ll -o app
qlangc --emit-module plugin.ql aot/runtime.ql > plugin.ll
python3 aot/native_link.py plugin.ll --shared -o plugin.so
./app /absolute/path/plugin.so
```

Use the checked linker above for extension hosts; the retained Rust `--compile`
convenience driver does not export their required runtime symbols.

In `app.ql`, use `let plugin = import (args[0]);` and `plugin.exportName`.
The extension uses normal QLang exports. The host may be built before the
extension exists. Use matching compiler/runtime ABI versions and the checked
linker for both artifacts. See [module semantics](../docs/module-semantics.md)
for scope, relative paths, initialization, ABI and host limits. The native
QLang interpreter runs the same source entry with
`native-interpreter app.ql /absolute/path/plugin.so`. Rebuild extensions with
the matching compiler/runtime; the ABI now includes interpreter callback support.

The dedicated suite builds the host first, builds independent extensions, removes
all QLang fixture sources, then checks O0/O2 host/extension combinations:

```sh
TEST_TIMEOUT=1800 python3 aot/run_extension_tests.py --compiler /path/to/qlangc
python3 aot/run_extension_bridge_tests.py --compiler /path/to/qlangc \
  --interpreter /path/to/native-interpreter
```

The second suite checks the same loader contracts through the QLang AST core,
plus cross-boundary callbacks, shared mutable values, custom type predicates,
Error-argument policy and exact user-source diagnostics. Extension source files
are removed before execution; the interpreter still receives its entry script.

The loader requires the system dynamic-loading API (`libdl`); QLang cannot
express that OS boundary directly. No standard-library algorithms were moved
into the backend. The allocator reserves a separate anonymous memory region so
libc and the loader can safely own the process break; collection rules are
unchanged by this address-space fix.
