# Active QLang compiler completion work

## Priority and scope

Prioritize the QLang self-hosted compiler and interpreter, ordinary language
execution, dynamic modules, and useful source diagnostics. The shared QLang AST
is authoritative; syntax sugar must not require separate backend semantics.
Rust is a retained bootstrap/embedding implementation. Do not modify it unless
it blocks QLang work; record independent discrepancies in
[retained-rust-issues.md](retained-rust-issues.md).

The earlier deferral of pow and other nonessential Math/library work was
superseded on 2026-10-07: the user chose to continue the portable-standard-library
requirement, approving a `Number.frexp`/`Number.ldexp` representation mechanism
and a `String.fromCodePoint` mechanism, and moving `JSON.parse` and
`Math.sqrt`/`pow`/`sin`/`cos` into ordinary QLang. Performance optimization and
memory-management replacement remain deferred; do not resume those candidates
merely because artifacts already exist. A library problem takes priority only
when it prevents compiler/self-hosted core or ordinary language execution. Do not
work on undecided Infinity/NaN globals.

Current order:

1. Dynamic-extension bridge: applied after all six integrated gates and the
   selfhost fixed point passed. Preserve its verified language/ABI behavior.
2. Fix failures in functions, closures, statements, scopes, initialization,
   module execution and error propagation. Validate the final source revision.
3. Numeric object-key repair: applied after all six final-version gates passed,
   independently of deferred Math migrations (details below).
4. Continue the portable standard-library requirement after the main language
   path is reliable. Missing public capabilities need concrete user decisions;
   record them instead of inventing backend-specific library implementations.

## Dynamic-extension bridge applied

The21-file bridge implementation/test/documentation patch is now applied to
main. `target/core-extension-integrated/main-application.json` records the
application, backups, gate results and exact candidate hashes. All21 installed
files were independently checked against those hashes after application.

The final driver (session72810) exited0 after all six complete gates passed:

- `semantic-diagnostics`: compiler source attribution and error exits.
- `parse-diagnostics`: compiler/core syntax errors, including chained assignment.
- `extensions`: native/core O0/O2 extension contracts, shared values and identity,
  callbacks, types, source/call frames, definition-site paths and bridge isolation.
- `core-diagnostics`: Error interface preservation, stored/reused Errors,
  recursive/library/module locations, import/assignment failures and isolation.
- `core-full`: all language fixtures,419 type assertions, args, direct bridge,
  function metadata, definition-site imports, error exits and null handling.
- `selfhost`: all compiler fixtures, byte-identical stage2/stage3 LLVM IR and the
  stage2 function execution fixture.

The application verified all195 immutable source hashes, native binary/IR
hashes, fixed-point equality and unchanged main dependencies before writing.
The fixed-point IR SHA256 is
`78e2adce16844a9f0ae4c417e2ac7cce5c1f9dfd84439dc5b2a6e3ad83a1c662`.
No Rust implementation changes were required. The checked source snapshot and
artifacts remain in `target/core-extension-integrated/`; do not rerun its
completed driver or application command.

The later numeric-key repair below has also passed its own final-version
gates and is applied. Its evidence is authoritative for the latest runtime;
the bridge results establish the preceding integration.

## Language behavior to preserve

- A declared but uninitialized binding establishes lexical scope and shadows
  outer bindings. **Reading it is a frontend (compile) error** — not a runtime
  Uninitialized value: the shared parser runs a definite-assignment check (see
  below). Undeclared/private names cannot be used. Do not introduce an undefined
  value. Keep null and Null distinct.
- Builtin names obey ordinary lexical lookup, shadowing and captured assignment.
  Public rebinding must not overwrite private runtime/library bindings.
- Function arity, partial application, annotations and Error-argument policy
  must match across ordinary calls and extension callbacks. Function internals
  remain hidden; existing native function names remain available.
- Imports execute in the expression's scope and resolve paths at the defining
  source file. Skipped imports/exports do not create bindings or erase outer
  annotations. Export tables belong to their defining module and survive escape.
- Static cyclic module graphs are allowed; executed initialization re-entry is
  an ImportCycle. Computed imports use independently compiled shared libraries,
  with ABI checks and fresh module initialization. No runtime source compiler/JIT.
- Cross-extension aliases, cycles and mutable values retain identity. The
  candidate bridge retains identity pairs for its Interpreter lifetime; finer
  reclamation and DSO unloading remain unimplemented, not completed memory work.

See [module-semantics.md](module-semantics.md) for the module contract.

## Confirmed chained-assignment decision

The user chose a syntax error for `a = b = 1`. Previously the shared parser
accepted it, the evaluator silently changed a to null and left b unchanged,
and LLVM reported an unsupported Assign at0:0. The main QLang parser now rejects
it at the second equals sign. Ordinary assignment remains supported.

The frontend fixture has30 invalid and14 valid cases, including member/index
chains, longer chains, function bodies, Unicode/CRLF, and valid nested-function
assignments. Native O0/O2 frontend checks and rebuilt compiler/core parse and
semantic CLI gates pass. Evidence: `target/chained-assignment-fix/change.json`
and the current integration logs. This repair is already in main and does not
require a Rust change.

## Numeric object-key repair applied

The shared parser converts numeric object keys with std.Number.toString. The
legacy fractional formatter truncated values, so literals such as
`{0.3333333333333333: "third"}` acquired the wrong property name. The current
native compiler reproduced all three recorded fractional-key failures before
the fix (`target/numeric-key-main-audit/result.json`).

The applied runtime repair keeps the existing safe-integer path and uses the
existing exact decimal converter for other finite values. It does not special-case
the parser, change the AST, add public features or import unrelated Math work.
The t46 numeric-key and t47 finite-rendering regressions are registered in both
complete native-core and selfhost runners.

Targeted native O0/O2 checks pass all38 finite output lines and the three key
lookups; the corrected native interpreter passes them too. The final revision
then passed all six complete gates: semantic diagnostics, parse diagnostics,
runtime diagnostics, native extensions, native core and selfhost. The core gate
includes419 type assertions, direct bridge/metadata, definition-site imports,
error exits and null/handled-error checks. All compiler fixtures, exact stage2/3
LLVM IR equality and the stage2 function execution test pass.

`target/numeric-key-integrated/main-application.json` records the applied8-file
patch, backups and evidence. All8 main files match the verified candidate bytes.
The final fixed-point IR SHA256 is
`fe7e0e39de0dd4cc6bc61da6c43f01d6fd4cf72f67b8c6e27a8fd28a81a8bfc6`.
All199 frozen source hashes and compiler/core artifact hashes were checked before
application. The guard also checks the exact README publication already applied
by the predecessor; that documentation reconciliation changes no tested inputs.

The final remaining-gate driver (session12376) exited0. The original driver
(session3011) exited1 because of its earlier, independently verified scheduling
assertion; its actual selfhost child passed with exit0. The recovery record
preserves that distinction and verifies all six real gate results before merging.
No failing test was treated as a pass. Both drivers are finished; do not restart.

This remains a narrow compiler-relevant repair. Number parsing and predicates
are now ordinary QLang functions in the default library, but Number.toString and
complete number-formatting portability still depend on privileged numeric
representation helpers. Number/JSON portability is not complete. Extended Math
work remains deferred.

## Portable standard library remains incomplete

All library algorithms must be ordinary QLang shared by both execution paths;
LLVM implements language mechanisms. QLang source packaging is also in QLang.
Python test/link/data-generation tooling is not a language implementation.

String, Array, base Math, Number, Object and the whole JSON module (stringify and
parse) are installed through the shared QLang loader. Number exposes ordinary
QLang `parseFloat`, `isNaN` and `isFinite`; Object exposes ordinary QLang
`values`, `merge`, `hasOwn`, `get` and `field`. String includes the validated
Unicode casing/whitespace data; Array algorithms use existing language
indexing/removal. Math includes PI, E, abs, trunc, floor, ceil, round, and now
sqrt, pow, sin and cos, rebuilt on the frexp/ldexp mechanisms. `JSON.parse` is
ordinary QLang with `String.fromCodePoint` decoding `\uXXXX`/surrogate pairs; the
runtime's former `__jp_*`/`__json_parse` were removed. Object key enumeration
still uses the existing native `std.Object.keys` reflection operation, so Object
algorithms are migrated but full Object portability is not complete.

Number.toString and complete number-formatting portability, Object key
reflection, filesystem, entropy-backed Math.random and the variadic
Math.max/Math.min still need migration/audit. `Number.toString` is
runtime-internal (`__str`, diagnostics, object-key coercion) and its
exact-shortest-digit path uses the raw big-integer layer; `Math.random` depends
on the entropy syscall; and `Math.max/min` must stay runtime code — moving their
comparison into the library was attempted and rejected by the call-buffer
contract, which pins that a variadic max/min call performs no per-call heap work
(allocations grew 6664 → 12664 for +1000 calls once the body was a library call),
and their Error-argument message names the function, which only the dispatcher
produces. Do not count moving privileged runtime algorithms into a new file as
portability.
Unicode codepoint conversion (`String.fromCodePoint`) and exact binary64
representation (`Number.frexp`/`Number.ldexp`) are now provided as approved
mechanisms. Still missing: OS effects, structured Error construction,
variable-arity calls, intentional Error arguments and portable Object key
enumeration, plus a negative-zero sign oracle inside the library (the runtime
`Number.toString` text is the only current one). Some algorithms can use existing
arithmetic; an old raw-memory dependency alone does not justify a new primitive.

The detailed audit is [stdlib-capability-gaps.md](stdlib-capability-gaps.md).
Report missing QLang capabilities to the user and obtain design confirmation
before adding public primitives. Keep deferred numeric candidates isolated.

## Applied core repair: partial-function member parity

The call-policy audit exposed an existing core-language discrepancy. A partially
applied user function has the native-style name `<curried>` in direct LLVM
execution, but the QLang AST interpreter rejects the same `.name` read. The
current native O0/O2 probe passes; the unchanged native interpreter differs only
on the two name reads, with calls and arity results equal. Evidence is
`target/partial-function-members-audit/baseline.json` (driver session83560 exit0).

The applied 3-file repair adds the missing interpreter member branch and
extends t45 from 11 to 19 checks, including zero-bound partials, aliases, arity and
hidden storage. All five gates passed: native t45 at O0/O2, the corrected core
probe, complete core, runtime diagnostics and native extensions. The guarded
application verified all 199 frozen inputs, unchanged main dependencies and
artifact hashes. Evidence: target/partial-function-members-audit/main-application.json.

Compiler/runtime sources and their entire static import closure are unchanged
from the verified numeric-key revision. `compiler-reuse.json` records each hash
and the existing fixed point; that compiler evidence is reused while the changed
t45 fixture is executed separately. This is an interpreter repair, not a new
calling convention or default-library migration.

## Confirmed library call policy

The user confirmed that migrated standard-library functions follow ordinary
QLang function rules, including partial application. For example,
std.Number.parseFloat()("2.5") may return 2.5 after migration instead of reporting
ArityMismatch on the first call. Do not add exact-arity compatibility wrappers
or backend library-name exceptions. The original behavior probe and this decision
are recorded in target/number-call-policy-audit/result.json.

The Number parsing/predicate migration is applied in main. The installed
`stdlib/number.ql` imports the ordinary QLang decimal parser and String module,
and exports `parseFloat`, `isNaN` and `isFinite`; it adds no extended Math
algorithms. `target/number-portable-current/main-application.json` records all
203 frozen inputs, nine changed files, and the eight passing gates. The native
and core checks include the independent 49-value IEEE-754 oracle. Selfhost
passed with byte-identical stage2/stage3 IR and the stage2 function execution
fixture (`stage2-functions`). The separate `Number.toString` and complete
number-formatting portability work remains unfinished. Deferred Math,
optimization, memory replacement and numeric-global work remain out of scope.

## Reviewed JSON string helper candidate

Luna supplied an ordinary QLang internal string-quoting helper. Astra reviewed
its escape behavior, required a correction to failure propagation and executed
its independent fixture. All 37 assertions pass on direct LLVM O0/O2 and the
current native QLang interpreter. Evidence and frozen source are in
`target/json-quote-reviewed/`; the driver exited successfully.

This helper is not installed in std.JSON and is not a complete JSON migration.
It uses existing String indexing/concatenation and Error construction, with no
raw storage operations or host JSON algorithm. Full JSON remains dependent on
object reflection, numeric formatting and Unicode escape construction decisions.

## Object algorithms and value-access repairs applied

`stdlib/object.ql` now provides ordinary QLang `values`, `merge`, `hasOwn`,
`get` and `field` functions through the default standard-library loader. The
algorithms use existing `std.Object.keys`; that key enumerator remains native
reflection, so this is an Object algorithm migration rather than complete
Object portability. No new public reflection primitive was added. The applied
record is `target/object-portable-preparation/main-application.json`: 20 changed
files across 212 frozen inputs, with all eight gates passed. Those include the
native/core targeted fixtures, full interpreter suite, diagnostics, extensions
and selfhost stage2/stage3 plus stage2 function checks.

Several real failures during integration are retained as historical evidence.
The first core candidate returned null for `Number["check"]`; the generic raw
Object/Type index repair fixed that language path. Raw host type predicates,
normalization of scalar and Array values crossing the interpreter boundary, and
MemberAccess/IndexAccess error behavior also needed correction. An early
raw-type core attempt ended with exit -15 after a separate String access
observation exposed a nonterminating trim loop; that interrupted result remains
in its candidate records and is superseded by the final passing gates. The
follow-up 12-case observation and t51 strict fixture document the old internal
field leaks and error fallbacks. These fixes are now applied with Object and
covered by the final Object core/native tests; the historic failure records are
not passing evidence.

The final Object application registers t49 raw-index (17 assertions), t50 raw
type checks (31 assertions) and t51 value-access errors (46 assertions). All
three targeted fixtures passed on native O0/O2 and the checked core. The eight
application gates passed, including stage2/stage3 fixed point, stage2 function
execution, full interpreter, semantic/parse/runtime diagnostics and extension
bridge. Evidence is in `target/object-portable-preparation/`, especially
`main-application.json` and `results.json`. The remaining Object portability gap
is the native `std.Object.keys` reflection boundary; replacing that boundary
with a portable language contract needs design review.

## Return flow inside expressions

The AST coverage audit found that the shared parser emits the same If node in
statement and expression positions, but core evaluation discarded its Return
flow in expression position. A completed run with the checked normalization
core confirms the problem in nine contexts: initializer, array element, call
argument, arithmetic operand, unary operand, loop condition, assignment member
receiver, assignment index receiver and assignment index expression. Each
incorrectly executes later side effects; a nested-function return control works.
The process exited 0 with empty stderr. Actual output is preserved in
`target/if-expression-return-audit/core.stdout` and `core.run.json`. The native
O0 comparison has now completed with exit 0, empty stderr and exact expected
output: all nine expression cases return immediately with no later side effects,
and the nested-call control continues normally. The engine disagreement is
therefore confirmed by execution, not just source inspection.

The repair in `target/if-expression-return-fix/` carries Return completion
separately from ordinary values and Errors, then restores statement flow at the
enclosing boundary. It covers annotations, assignment receivers/indices and
unary propagation. Return carriers use a private identity token, so an Error
kind named Return or a similarly shaped user object cannot forge one.

The fix is applied. The original ten-line expression observation passed native
O0 and the corrected core; the 31-check boundary fixture passed native O0/O2
and the corrected core. All three full gates passed: interpreter core, runtime diagnostics and extension bridge, each
with exit 0 and its exact success marker. The final application records seven
changed files over the Object base; the combined main snapshot has 216 inputs.
Evidence is in `target/if-expression-return-fix/`, especially
`verify-full.results.json` and `main-application.json`. Compiler source/AST/runtime
were unchanged; selfhost evidence is inherited from the verified Object
application. This repairs function-local Return flow. The separate function-scope
rule is now implemented by the shared parser, as described below.

## Function-only return implemented

The user-approved rule is enforced by `bootstrapped/parser.ql`: `return` is valid
only inside a lexical function body. Script and module top-level returns are
syntax errors, including those in untaken branches. Interpolations inherit the
surrounding function context; parameter annotations remain in the definition's
outer context. A nested function restores that context when parsing its body
finishes. Module source is checked before compiler-generated factories wrap it.

The focused verification in `target/function-return-scope/` rebuilds both native
QLang tools from the previously verified QLang compiler. The frontend pack passes
at LLVM O0/O2, including 37 new return-scope assertions, existing function AST and
source diagnostics, and corrected function-local Return source spans. Existing
`t16`, `t52` and `t53` behavior also agrees with the new native QLang interpreter.
CLI checks reject script returns, imported module returns (directly and from a
function), and `--emit-module` returns with the keyword's original source position
and no execution of the malformed source's statements. The new checks are
registered in the selfhost and compiler/core diagnostic runners.

Actual exits, output and source hashes are recorded in `verify.result.json`,
`persistent-runners.run.json` and `main-application.json` in that directory. This
is focused verification; the full suite and self-compilation fixed point were
not repeated in this round. The retained Rust parser discrepancy is documented
in `docs/retained-rust-issues.md`; no Rust code was changed.

## JSON.stringify default integration applied

`stdlib/json.ql` and `stdlib/json_quote.ql` now supply ordinary-QLang
`std.JSON.stringify` through the shared source loader. Traversal and escaping
have been removed from the privileged runtime, and the interpreter no longer
has a stringify-specific argument-conversion branch. JSON.parse is preserved
by merging library fields into the existing namespace. Existing Object.keys
reflection and Number.toString formatting remain dependencies; complete JSON
portability is still unfinished.

The applied ten-file change is recorded in
`target/json-stringify-integration/main-application.json`. The QLang bundle
builder and its check passed. One combined affected program covers existing
JSON behavior, functions, the native value bridge, finite-number rendering,
48 new default-stringify checks and 33 call-policy checks. All 171 output lines
match on the rebuilt QLang core and LLVM O0/O2. Stage2 compiled that program,
including the function fixture; stage2/stage3 self-compilation produced identical
LLVM IR. The rebuilt core also passed 419/419 type assertions. Both core and
native unhandled-depth diagnostics identify stdlib/json.ql and the user call.

Verification reused checked bootstrap artifacts and combined related fixtures
to avoid separate runtime compilation for each test. The original command
results and streams are in `verify.result.json` and the adjacent run records.
This was a focused integration run; earlier complete extension/core suites were
not rerun or counted as new passes. All 220 frozen source inputs were checked
before application. No Rust implementation was changed.

## Feature design requires user confirmation

Obtain confirmation before adding syntax, language semantics or public
capabilities. An old roadmap is not blanket approval. Fixes against established
behavior may proceed; fixes that change the rules must be discussed first.

## Error diagnostics roadmap — user decision 2026-09-27

1. **Current scope: diagnostic output only.** Unhandled failures identify
   original file/line/column and useful call/import/cause paths. Preserve the
   existing public Error interface and Error-as-value behavior; no public
   Error.file/Error.trace fields. Error.toString remains unchanged. Source-aware
   unhandled reporting is a separate internal path. Packaged library locations
   refer back to original stdlib sources, including Unicode/newline coordinates.
2. **Later: program-readable source and call-chain information.** The user wants
   this on the roadmap after stage1. Field names, frame shape/order, origin versus
   propagation, reused Errors and Error-argument handling need a concrete design
   and confirmation. Experimental earlier field names are not an accepted API.

The output-only implementation is applied. The bridge revision has passed
semantic, parse and runtime diagnostics plus complete core/selfhost gates.
The later numeric-key repair also passed all six final integration gates. Earlier public-field experiments must not be
published unchanged. See [source-diagnostics.md](source-diagnostics.md).

## Definite assignment: uninitialized reads are a compile error (2026-10-09)

The user chose to change the semantics: a binding must be initialized before it
is read, and violating that is a frontend error rather than a runtime Uninitialized
value. Implemented in the shared parser (`bootstrapped/parser.ql`), so the
self-hosted compiler, the boot interpreter and the native interpreter all get it.

Rules: `let x;` declares an uninitialized binding; assignment initializes it;
`if`/`else` joins are conjunctive over the live paths (a one-sided branch does not
initialize); a loop body's assignments never become definite; `return` ends
reachability. Reads of a not-definitely-initialized binding produce
`reading uninitialized variable: NAME` with the original source coordinate.

Sound escape hatch: names that appear anywhere inside a nested function are exempt
(an over-approximation of captures). Those reads are deferred — a closure may read
an outer binding after the assignment — so the emitter keeps its runtime check for
them. The corpus relies on this: runtime.ql and qlangc.ql have forward references
inside function bodies.

Effect: with same-body reads guaranteed, the emitter no longer emits the null
check, the `ql_empty` check or their cold diagnostic paths for them
(`aot/qlangc.ql`, depth 0 and non-optional scope). One `x = x + 1` dropped from 301
to 174 IR lines, emitted IR shrank ~34 % (1000 statements 33.9 → 24.5 MB, 3000
statements 62.2 → 40.9 MB), and the compiler's static string declarations went
2699 → 2086. Verified by self-hosting with the native compiler only
(`stage1 --emit-llvm aot/qlangc.ql aot/runtime.ql`, 41 s) with byte-identical
stage2/stage3 IR, and the native compiler rejects `let x; x;`.

Workflow note (user direction): build and test with the QLang-compiled native
compiler, not the Rust host. `stage1 --emit-llvm aot/qlangc.ql aot/runtime.ql` is
~41 s, where the Rust boot path took ~13 min, and it exercises the shipping path.

Fixtures that deliberately exercised the old runtime semantics were reworked
(t13/t15/t20/t21/t22/t23/t33/t34/t38); their coverage moves to the frontend
diagnostic fixture. `tests/uninitialized.rs` runs the retained Rust host, which
still reports the runtime value — a recorded discrepancy in
[retained-rust-issues.md](retained-rust-issues.md).

Extensions (same day):

- The same pass tracks a statically known local function's arity (refreshed on
  reassignment, merged conservatively across branches), so a call to it with
  **more** arguments than it declares is a frontend error
  (`Arity mismatch: expected N arguments, got M`). Fewer arguments stay legal
  (partial application), member/unknown callees keep the runtime check, and
  variadic runtime natives such as `Math.max` are unaffected. t12's excess-argument
  case moved to the diagnostic fixture (36 invalid now).
- Emitter: a binding declared without a type annotation stores zero type/text, so
  the `__check_binding` diamond on reassignment always takes its plain branch.
  `emitLetStmt` records annotated bindings in `curScope.annotated` and
  `emitStoreByName` emits a plain store for the rest. One `x = x + 1` went from
  174 to 108 IR lines and 1000 statements from 24.5 to 21.0 MB.
- Constant failures the frontend can prove are errors as well: division or modulo
  by a literal zero (`division by zero`) and an integer literal index outside an
  array literal (`index out of range: N`, positive or negative). The right operand
  of `&&`/`||` is exempt everywhere, since it may never be evaluated —
  `false && 1 / 0` stays legal and is pinned as a valid case. Two further
  candidates were deliberately *not* added: member access on a scalar literal
  (string literals do have members — `"ab".length` is true — so those tables
  belong to the runtime, not a frontend mirror) and a literal initializer that
  contradicts its annotation (the annotation is an arbitrary expression evaluated
  at run time; judging it statically needs a type-value notion the frontend does
  not have). Fixtures that used `1 / 0` to *obtain* a runtime error value now
  divide by a variable zero, preserving their source-position assertions
  (t38, t40, native_source_bridge, t6, v1_shortcircuit).

## Statements end at `;` (2026-10-09)

Settled after working through a line-start/line-end continuation scheme: **a
statement ends only at `;`** (or at the `}` of a block-like statement). A newline
never ends one, so parsing is greedy and every source has exactly one parse — there
is no continuation ambiguity left to resolve. The earlier experiment for that
ambiguity (rejecting no-effect expression statements, and a statement whose first
token can both continue the previous line and start a statement, i.e. `-`, `+`,
`(`, `[`) was reverted as unnecessary complexity.

- Every value-producing statement needs `;`: declarations, assignments, `return`,
  `export`, and any expression statement — **except a block's tail statement,
  where it may be omitted (like Rust) or written; both mean the same thing.**
  Operationally the rule is: a missing `;` is an error unless the next significant
  token is `}` or end of input. A missing one is reported at the offending token
  (`expected ';' after declaration` / `after statement` / `after return` /
  `after export`).
- `if`, `while` and bare blocks end at their `}`; a following `;` is an empty
  statement, which is why `if c { … };` stays valid.
- A standalone expression statement is legal (`xxx;`, `xxx.yyy[zzz];`, `[1, 2];`),
  which is what allows a chain to continue over the following lines. Before this
  rule, `let a = 1 let b = 2;` and `{ x y }` were silently accepted (statements
  without a separator), which is exactly the hole it closes.
- The corpus is already `;`-terminated, so the rule costs no source changes.
  Still kept from the same session: definite assignment, the static arity check,
  literal division by zero, and literal array-index bounds.

## Line endings: keep core.autocrlf off (2026-10-09)

This checkout had `core.autocrlf=true`, so a `git checkout` rewrote the sources to
CRLF. The library bundle embeds the module *characters* — its newlines are escaped
inside the generated string literal — so a CRLF working tree makes
`stdlib/build_bundle.ql --check` report a stale bundle even though the committed
bundle is correct, and it silently changes the source text the compiler parses
(positions and embedded literals). Fix: `git config core.autocrlf false`, then
re-materialize the working files from the index (`git checkout-index -f -a`, or
copy every `git ls-files` entry from `git cat-file blob :<path>`), after which
`--check` verifies. Fixtures may still use CRLF deliberately — the packager tests
cover mixed newlines — only the sources that feed the bundle need LF.

## Compiler emission scaling: measurements and one fix (2026-10-08)

The user un-deferred compiler scalability work. Clean measurements (native
`stage1`, nothing else running): a trivial program emits 20.0 MB in 14.4 s;
adding 1000/2000/3000 `x = x + 1` statements costs 45.1/127.7/252.1 s for
34.6/49.2/63.8 MB — 0.72 s/MB at the baseline rising to ~5.7 s/MB. The growth
tracks accumulated *emitted bytes*, not statement count: a 4000-statement
unique-binding program emits almost no IR and stays linear (~1.8 ms/statement).

Ruled out by direct measurement: array append (1.2 M elements, linear), string
concat + store (2.4 M live strings, linear), `println` (~3 µs/line), and GC
frequency (raising the collection threshold 16× gained only ~20 % at n=1000 and
OOM'd at n=2000). Peak RSS is 208 MB for the trivial program and 574 MB at
n=1000 — the heap grows ~500 B per emitted line, roughly 10× the retained IR
bytes — so the remaining per-line cost growth is consistent with memory/GC
pressure from holding the whole IR in memory: the main body, every function block
and every string declaration are buffered until the final flush.

Fixed: `escapeBytes` in `aot/qlangc.ql` built the escaped literal with
`text = text + …` per byte — O(len²) per literal — and now uses an O(n log n)
pairwise concatenation with a small-input fast path. Emitted IR is unchanged, the
selfhost gate passes 47/47, and literal-heavy compiles improve ~11 % (a
3000×1000-char-literal program 39.6 → 35.1 s; the interpreter's `run_file.ql`
~40.6 → 35.9 s).

Next step (structural, not attempted): let main's body stream instead of
buffering, by pre-sizing main's frame from the already-computed binding set so its
stack allocas are known before the body is emitted. That removes the large live
set the current design forces; it needs its own before/after measurement and the
full gates. This sandbox has no `perf`/`gdb`, so finer profiling would need either
a temporary clock leaf or a profiler-enabled machine.

Phase breakdown obtained by temporarily instrumenting `qlangc.ql` with
`/proc/self/stat` CPU-time stamps (`/proc/uptime` is frozen in this sandbox),
CPU seconds:

| phase | n=0 | n=1000 | n=2000 | n=3000 |
| --- | --- | --- | --- | --- |
| frontend (lex+parse user+library+runtime) | 4.17 | 5.36 | 6.77 | 8.12 |
| emit runtime | 1.54 | 1.53 | 1.56 | 1.54 |
| emit library | 3.44 | 3.44 | 3.43 | 3.42 |
| **emit user program** | **0.00** | **20.34** | **76.23** | **167.72** |
| flush | 1.00 | 1.79 | 2.42 | 3.42 |
| total | 10.2 | 32.5 | 90.4 | 184.3 |

So the fixed costs are modest and honest — the entire runtime+library emission is
~5 s and the frontend 4–8 s — while **emitting the user program is ~90 % of the
time and is quadratic** (per statement 20 → 38 → 56 ms, per emitted line ~65 →
180 µs). The flush is cheap (1–3.4 s for up to 1.36 M lines), so I/O is not the
problem. Two levers remain: emit fewer IR lines per operation (a plain
`x = x + 1` currently emits ~311 lines — less output means less emitter work, less
memory and smaller binaries), and stop retaining the whole IR in memory. The
instrumentation was reverted after measurement; the only compiler change kept is
the `escapeBytes` fix above.

Dissection of the ~311 lines added by one `x = x + 1` (`stage1`, diffing the IR of
`let x = 1; println(x);` against the same program plus the assignment): 126
`getelementptr`, 84 `load`, ~100 `store`, 29 `call`, 29 basic blocks, 18
`extractvalue`, 17 `alloca`, 16 `inttoptr`, 13 `icmp`, 9 `phi`. The hot code is
tiny — the `+` is inlined as `ql_tag` checks plus `fadd` — so the mass is:

- **Cold error paths emitted inline at every site.** Each identifier *read* emits
  an "Uninitialized" check plus its error-construction/propagation block; each
  write emits an absent-binding (`UndefinedVariable`) path and a
  `__check_binding` annotation diamond; every call is followed by an inline
  propagate block. Each is ~40–80 lines, most of it a diagnostic block that never
  executes on the normal path.
- **One hoisted `alloca` per call site** (17 for this one statement) from the
  entry-block stack-slot mechanism, so a 3000-statement module hoists tens of
  thousands of allocas.

Root cause found and fixed (branch `emission-scaling`): `String.join` built its
result with `out = out + …` per element — O(n²) — and `stackEntry()` joins the
per-call-site stack-slot list, which grows with every statement. Two fixes:

- `String.join` in `stdlib/string.ql` now uses a pairwise reduction (O(n log n));
  this is the root-cause fix and protects every join caller.
- Call-argument buffers are pooled per size (`argSlot` in `aot/qlangc.ql`) instead
  of one `alloca` per call site, so main's entry block holds a handful of allocas
  rather than tens of thousands. This is safe because the invocation ABI only
  borrows the buffer (partial application copies), every argument is evaluated
  before the stores, and each use is bracketed by `lifetime.start/end`.

Emission times (native `stage1`, nothing else running):

| case | before | after |
| --- | --- | --- |
| trivial `println(1)` | 14.4 s | **10.1 s** |
| +1000 `x = x + 1` | 43.5 s | **13.6 s** (3.2×) |
| +2000 | 127.7 s | **17.2 s** (7.4×) |
| +3000 | 252.1 s | **34.8 s** (7.2×) |
| interpreter `run_file.ql` | 35.9 s | **30.0 s** |
| t16 fixture | 12.1 s | **9.5 s** |

Pooling alone accounted for ~2.4× (it shrank the list being joined). Validated:
selfhost gate 47/47 including the stage2/stage3 IR fixed point, interpreter 52/52,
numeric suite, call-buffer allocations still flat `[633, 633]`, lifetime suite,
extension and extension-bridge suites, portable String suite, `cargo test`.

Remaining: the per-statement IR mass is still the cold error/diagnostic paths
emitted inline at every read, write and call (~40–80 lines each, never executed on
the normal path). Sharing them — one helper per error *shape* (kind + message)
parameterized by the source location — should take `x = x + 1` from ~311 lines to
roughly 40 and cut both emission time and artifact size further; it needs the
exact error kind/message/location preserved plus the full gates. Also known
quadratic: `JSON.stringify` in `stdlib/json.ql` builds its output with `output =
output + …` per token, so large values pay O(output²). Neither is attempted yet.

## Extension suites need a dlopen-permitted TMPDIR (2026-10-08)

`aot/run_extension_tests.py` and `aot/run_extension_bridge_tests.py` build host
binaries and DSOs inside a temp directory and then `dlopen` them. In this sandbox
the dynamic-linker namespace permits only `/data` (plus system paths), so with the
default `TMPDIR` (`/tmp`) every plugin fails to load and the suites report
extension failures ("library ... is not accessible for the namespace"). Running
them as `TMPDIR=/data/qltmp python3 ...` makes both pass — `ALL CHECKS PASS` for
the extension suite and `Native core extension suite: ALL CHECKS PASS` for the
bridge suite. This is an environment restriction, not a product defect; the same
failures appeared with the pre-change compiler and are not related to any
migration.

## Retired compiler fixtures audited (2026-10-08)

36 `aot/tests/*.ql` fixtures are referenced by no runner (the early t4–t8 / v1 /
m0 series plus t9–t14). None has a `.expected` golden, so they were never part of
the golden comparison runner; their coverage now lives in the stdlib test scripts
and the t16+ fixtures. Re-running the current-numbering ones (t9–t14) gives nine
byte-identical host/native; the three that differ are fully explained and are not
regressions (they reproduce identically with `stage1c`/`stage1e`):

- `t9_error.ql` calls the private `__err`/`__isError` names the compiler no longer
  exposes to source; the fixture is obsolete.
- `t12_calls.ql` lines 72/74 — `Function.check(std.String.length())` and
  `Function.check(std.String.includes("abc")())` — differ because the retained
  Rust host keeps exact-arity natives (host `false`, ArityMismatch) while the
  migrated library follows ordinary-function rules and returns a partial (native
  `true`). This is exactly the approved call policy above.
- `t14_interpolation.ql` line 18 interpolates a function value: the host prints
  `<native fn String.length>`, the native prints `native <function>`.

No fixture was deleted or registered; creating `.expected` goldens for them would
be a deliberate new-baseline decision, not a fix.

## Module unhandled-initialization exit status verified (2026-10-08)

`aot/run_module_tests.py` asserted exit status 0 for an unhandled module
initialization error on the boot path, which contradicted the documented
contract in `bootstrapped/run_file.ql`: an unhandled error is unwrapped at the
process boundary so the runtime reports it and returns a failing exit status.
The boot path now asserts the same status 1 and the same `DivisionByZero`
diagnostic as the native path. The whole suite passes ("Module suite: ALL PASS",
11 checks) against the current compiler and release host; the earlier failure
was a stale test expectation, not a runtime defect. No runtime or compiler source
changed for this.

## Cold-path outlining: done on branch `cold-paths-and-lazy-std` (2026-10-09)

The per-reader located-error path (`__err_at` with the source coordinates) is now
emitted **once per module** as a private function `@__cold_located_error` with an
ordinary ABI (values in registers, no frame buffer) instead of inline at every
reader. Measured:

- one read: 60 -> 37 IR lines; `x = x + 1`: 111 -> 66
- a whole module (empty program, i.e. the runtime and the standard library):
  339,948 -> 257,043 lines, 15.84 MB -> 12.10 MB (-24 %)

Validated: selfhost gate 47/47 (including the stage2/stage3 fixed point), native
interpreter 53/53, and the runtime-diagnostic and source-context suites — the two
that pin error coordinates and traces, so the outlining is behaviour-preserving.

Two constraints this toolchain imposes, both found the hard way:

- **A forward `declare` for a function defined in the same module is rejected**
  ("invalid redefinition", reproducible with plain `i32`). This is why runtime calls
  are all indirect through closure boxes. The helper therefore cannot be declared up
  front: it is generated at the end of compilation (where the module bindings exist)
  and **spliced into the output stream right after the prelude**, ahead of every use.
- **The helper must index the runtime frame directly.** A runtime name's lookup depth
  is the compile-time distance from `curScope` to `runtimeScope`, so the helper sets
  its scope to `runtimeScope` (depth 0 against its argument) and each call site
  passes the runtime frame obtained by walking `curEnv`'s parent chain once per level.

Next on this branch: (c) direct calls to runtime functions (which needs the function
definitions emitted *before* `main`, since this clang forbids forward declarations),
and then on-demand `std`. Note that link-time garbage collection cannot help with the
standard library: the std namespace object built at startup references every member,
so `opt -passes=globaldce` removes 0 of 278 functions. On-demand std has to be a
*compiler* decision (emit only referenced members, transitively closed, falling back
to everything for dynamic access).

### (c) Selective direct runtime calls: done

A runtime function whose body has already been emitted is now called directly
(`call %ql_value @ql_fnN(...)`): the code address is known, so the box's
code-pointer load and the indirect branch disappear. Frame and closure still come
from the box and arguments still go through the pooled buffer, so the ABI is
unchanged. Safety rests on two facts: this toolchain requires the definition to
precede a direct call, and runtime bindings are private and never reassigned —
checked, of the runtime's 173 top-level bindings only 4 mutable state names are
ever assigned, and none of them is a function.

To make that legal the module layout is now prelude → cold helper → function
bodies → main (globals last; they are unordered). Closure boxes keep the order
irrelevant for every indirect call.

Measured: 4850 direct calls against 411 indirect in a whole module; the module
drops from 257,043 to 247,343 lines (12.10 MB to 11.68 MB); a read from 37 to 35
lines and `x = x + 1` from 66 to 64. The compiler itself is 3-5 % faster
(q1000 15.43 -> 14.99 s, p3000 21.48 -> 20.36 s).

## Emission roadmap (2026-10-10)

Measured composition of one `x = x + 1` at HEAD (about 62 IR lines per statement;
the located-error helper's own body is a further one-off ~30 lines per module):

| part | lines | why |
|---|---|---|
| read `x` | ~15 | frame load of the binding, the "is this value an Error?" test (ql_tag/icmp/br), its cold branch and phi, frame pointer load |
| `+` dispatch | ~30 | the "are both operands Numbers?" test, the inline numeric fast path (extractvalue/bitcast/fadd/insertvalue), and the general path (frame-slot lookup of the operator, argument buffer, direct call to the runtime's `__op_add`) |
| write `x = ...` | ~10 | another Error test with its cold branch and phi, the binding store, and the statement-value bookkeeping store |
| diagnostic file-name string | 2 | interned once per module |

Levers, in rough order of value:

1. **On-demand standard library** — 68 % of the emitted module is the library
   (247,351 lines with it, 79,684 without, for a program that uses none of it).
   Compiler-side reachability over the library's top-level bindings and the object
   literals that expose them, with a fallback to emitting everything whenever the
   program's use of `std` is not statically enumerable (module object escaping into
   a variable, dynamic keys, unknown member names — note `std.Number.toString` and
   friends come from the *runtime*, not the library, so they are not "unknown").
   Must be validated against the `std.*` fixtures; a wrong decision fails at run
   time, not at compile time.
2. **Fold `@ql_tag` on constants and on same-scope bindings** — the read and write
   Error tests cost ~3 lines each at every site; on a value the compiler knows can
   never be an Error (a literal, or a binding whose only assignments are literals)
   the test and its cold branch are dead.
3. **Common up the runtime box loads** — each operator/call site re-loads the
   callee's frame pointer and closure from the same module frame (5-8 lines per
   site); a per-function CSE or hoisting out of loops would remove most of it.
4. **Drop the statement-value bookkeeping when unobserved** — every statement
   stores a fresh value into the statement slot; a whole block's worth is dead when
   nothing reads the block's value.
5. **Merge the numeric test with the dispatch** — the inline "both Numbers?" test
   duplicates the check the runtime's `__op_add` performs anyway; calling the
   runtime path unconditionally would shrink sites at some run-time cost.

### Per-construct emission cost (measured 2026-10-10)

Base program declares `x`, `y`, `f = (a) -> a`, `g = (a, b) -> a + b`,
`o = {p: 1}`, `a = [1, 2]` and reads `y` once (so the located-error helper's
one-off body, about 22-30 lines per module, is already present and cancels out).

| construct | lines | | construct | lines |
|---|---|---|---|---|
| `write x = 1;` | 2 | | `call f(1);` | 58 |
| `while false { 1; }` | 7 | | `y + 1;` / `y == 1;` | 60 / 60 |
| `read y;` | 13 | | `x = y + 1;` | 62 |
| `x = y;` | 15 | | `y < 1;` | 62 |
| `let z = y;` | 21 | | `if y == 1 { 1; }` | 68 |
| `!y;` | 29 | | `println(y);` | 71 |
| `[y, 1];` | 29 | | `y / 2;` | 82 |
| `y ?? 1;` | 31 | | `g(y, y);` | 86 |
| `y.p;` / `a[0];` | 40 / 40 | | `y % 2;` | 99 |
| `{p: y};` | 43 | | `f(1)(2);` | 103 |
| `y?;` | 44 | | `y == 1 && y == 2;` | 161 |
| `-y;` | 53 | | | |

Conclusions this changes:

- A plain read is **13** lines, not 35: the earlier figure included the once-per
  module cold helper. Writes are already nearly free (2).
- **Operators dominate**: 47-99 lines each, and `/` and `%` are worse than `+`
  because they skip the "both operands are Number literals" fast path and always
  take the tag test plus the general dispatch. `&&`/`||` pay that twice plus the
  short-circuit machinery (161 for one `&&` of two comparisons).
- **Calls are next**: `f(1)` 58, `println(y)` 71, `g(y, y)` 86, `f(1)(2)` 103.
  `println` is a builtin, so it still goes through the box path; a known-builtin
  direct call would help everywhere (fixtures and the compiler itself use it
  heavily).
- Unary minus (53) is the same shape as a binary operator and just as expensive.

Priorities follow from this: (1) on-demand std (68 % of the module), (2) the
operator path — fold the tag test when types are known and share the dispatch
machinery, (3) direct calls for builtins, (4) the general cold-path and
bookkeeping cleanups listed above.

### The operator path: where its ~47 lines go, and the ideas

| piece | lines |
|---|---|
| "are both operands Numbers?" test | 5 (`ql_tag` x2, `icmp` x2, `and`) |
| inline numeric fast path | 9 (extractvalue x2, bitcast x2, `fadd`, bitcast, insertvalue x2) |
| general path: fetch the operator's frame/closure | 9 |
| general path: argument buffer and call | 7 |
| branches and phi merge | ~5 |

`aot/value_abi.ql` is a hand-written block of `alwaysinline` IR leaves (`ql_tag`,
`ql_empty`, `ql_word`, `ql_truthy`) that the compiler emits whole, so moving a hot
fragment into a leaf needs no ABI or linker change.

1. **Hoist the frame/closure fetch to function scope (largest).** Those 9 lines are
   identical at every call site in a function, because a runtime function's box is a
   singleton and runtime bindings are never reassigned (the same invariant the
   direct-call change rests on). Load once in the entry block, then reference the
   register: ~8 lines saved per site. The module has ~4,850 direct calls, so this is
   worth roughly 35k lines, ~14 % of the module. The loads must go in the entry
   block, not at first use, or a use after a loop would not be dominated.
2. **A `ql_both_number(a, b)` leaf** replaces the type test: 5 lines -> 2.
3. **Leaves for the numeric fast path** (`ql_num_add` and friends, `alwaysinline`):
   9 lines -> 1. `-O2` inlines them back, so run-time is unchanged and only IR volume
   shrinks (an `-O0` build would pay a call).
4. **Give `/` and `%` a fast path.** They skip the both-literals fast path today, so
   they cost 82 and 99 lines. With `ql_num_div` / `ql_num_mod` leaves (zero check
   included) they drop to the `+` shape: 50-60 lines saved each. Biggest single win
   in this family.
5. **Fold the read/write Error test** (3 lines plus branch and phi) when the value
   cannot be an Error: a literal, or a same-scope binding whose assignments are all
   literals.
6. **`&&` at 161 lines** is two operators plus the short-circuit machinery; once
   operators shrink it falls to roughly 90.
7. **Long term: type inference with unboxed locals.** If a binding or parameter is
   provably a Number (or String), keep it unboxed and every tag test, fast path and
   pack/unpack disappears: an operator becomes ~2 lines and a read ~2. This is the
   structural answer to "why does one assignment need so many instructions"; the
   price is a real inference pass.

Do not outline the general (non-numeric) path: it is not cold — string concatenation
goes through it — so hoisting it out of line would slow string-heavy code.

### The real cost is not the check, it is not knowing the type (measured)

Same statement, differing only in whether the compiler knows the operand types:

| statement | lines |
|---|---|
| `z = 1 + 2;` (literals: the compiler emits the numeric path alone) | **21** |
| `z = y + 1;` (dynamic) | **62** |
| `z = y + y;` (both dynamic) | **75** |
| `z = s + s;` (strings, general path) | **75** |
| `y;` / `z = 1;` | 13 / 2 |

So two thirds of a statement's cost is the price of *not knowing types at compile
time*, and it is not spent on the 5-line test: it is spent on having to emit **both**
the specialised numeric path (9 lines) and the general dispatch path (16) plus the
branches that merge them. The test is cheap; the fact that its outcome is unknown is
what costs 40 lines.

This reorders the roadmap. The mechanical ideas (leaves, hoisting the frame fetch,
a fast path for `/` and `%`) recover only the mechanism overhead, about 15-20 lines
per operator; they cannot remove the duplicate paths. Only knowing the types can, and
the measured target is 62 -> ~20 for a statement whose operands are proven Numbers.

Narrow first step: **intra-function type inference**, restricted to bindings whose
initial value is a literal of one type and which are never assigned another (and are
only combined with that type). It is the same forward flow analysis the
definite-assignment pass already performs, needs no interprocedural work, and falls
back to today's dynamic emission whenever it cannot prove a type. Parameters and
return values (every call site agreeing on a type) are a later step.
