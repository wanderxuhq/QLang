# Source diagnostics

## Current worktree status

The approved output-only implementation is now applied to the local worktree.
Unhandled errors carry original source positions and call/import/cause paths;
existing Error.line/col receive coordinates, while Error.file/Error.trace remain
unavailable and Error.toString retains its previous representation. The private
interpreter source context is omitted from interpreted user `std`. Compiler and
interpreter CLI adapters suppress their implementation frames.

Targeted native O0/O2 output and context tests, native AST core diagnostic/args
checks, all four native compiler semantic-source cases and the matching native
extension matrix pass. The full native-core gate has now passed on the frozen
diagnostic revision (core-full.log, session83511 exit0; all175 input hashes
rechecked). It includes419 type assertions, native bridges, definition-site
imports and error/null contracts. The compiler selfhost/fixed-point gate remains
active. Later Math/library and native-member repairs require their own gates;
this result does not establish completion of the current combined worktree. The private
Error layout is included in the native extension ABI descriptor. Old binaries
are rejected before initialization and require rebuilding for the new runtime.

Regression entry points are `aot/run_runtime_diagnostic_tests.py` (native
`--compiler` or core `--interpreter`), `aot/run_source_context_tests.py`
(`--compiler`), and `aot/run_semantic_diagnostic_tests.py` (`--compiler`). The
runtime runner can also check a previous-layout DSO with `--old-extension`.
The reviewed application manifest and preserved previous file bytes live under
`target/output-diagnostics-fixed/`; no Rust or C implementation was changed by
this diagnostic patch. The chronology below records earlier implementation and
validation stages, including candidates that were never applied unchanged.

The rebuilt native compiler's complete diagnostic-specific suite now passes
(`target/output-diagnostics-fixed/compiler.log`, session27951 exit0): usage and
four semantic source cases,18 direct and7 module contracts at O0/O2, nine
unhandled-report modes per level, and rejection of older-layout extensions.
This is additional to the retained-host compiler path and native AST-core
diagnostic suites; the broader selfhost/core gates remain pending.

The matching native-extension matrix also completed successfully
(`target/output-diagnostics-fixed/extensions.log`, session17122 exit0): all four
O0/O2 host/module combinations pass28 contracts with source files removed.
Full selfhost/core gates remain pending. The supplemental unhandled DSO report
check also passed (`extension-reports.log`, session40154 exit0): all four O0/O2
host/module combinations retain the correct origin for exported Errors and
initialization failures after source removal; failed initialization also keeps
the host import frame. It reuses the matrix's already verified extension binaries.

The bridge fixture also passes from its applied repository path
(`main-bridge.log`, session38339 exit0): checked native compilation, eight basic
contracts and five unhandled modes cover native/partial calls, callback re-entry,
scope restoration and no leak. This validates the adjusted imports used by the
permanent regression runner, beyond the earlier isolated fixture placement.

## Confirmed scope and later roadmap

The user selected **diagnostic output first** (2026-09-27): improve unhandled
error reports with original source positions and useful call/import/cause paths,
while preserving the current public Error interface. New Error.file/Error.trace
fields are deferred; Error-as-value and Error.toString behavior are not changed
by this stage. Internal source bookkeeping must not become a new public control
API implicitly.

**Later:** expose source and call-chain information to QLang programs. This is a
requested roadmap item, not approval of the experimental field names or record
layout. Present the concrete interface and semantic tradeoffs for confirmation
before implementing that feature. See the [active roadmap](compiler-next-steps.md#error-diagnostics-roadmap--user-decision-2026-09-27).

The QLang lexer records line and column coordinates on tokens. Lines and columns
are one-based; columns count Unicode scalars (a tab counts as one scalar).
LF and lone CR start a new line, and CRLF counts as one newline. Token spans
remain zero-based, half-open scalar offsets into the original source.
Interpolation tokens keep their original source offsets and coordinates.

`Parser.setSourcePath(path)` identifies the file; anonymous source uses
`<source>`. `program.diagnostics` and `parser.getDiagnostics()` expose records
with `message`, `file`, `line`, `col` and `span`. The existing `program.errors`
string list remains available, formatted as `file:line:col: message`.
Imported source is labelled with its resolved path, not the importing file.

Missing required delimiters, invalid declarations/assignment targets, missing
member names and unfinished block comments are parse errors. The core rejects a
malformed root program before creating its execution environment. Imported
parse failures follow the existing Error propagation rules. Failed compilation
must exit nonzero and produce no LLVM IR.

`bootstrapped/tests/diagnostics.ql` covers 24 malformed and 10 valid programs,
including Unicode, CRLF, lone CR and interpolation. It passes on direct native
LLVM output and the retained bootstrap executing the QLang frontend.
`aot/run_diagnostic_tests.py` additionally checks compiler/core CLI failures,
imported files and definition-site imports in the core. All its CLI checks pass
(`target/diagnostics-check/cli.log`), including nonzero exits, no emitted IR on
compile failure and no execution of the malformed program.

This is the parse-diagnostic layer. Valid AST nodes still need source metadata
for semantic compilation errors and runtime errors. Runtime Error `line`/`col`
fields, call-site/definition-site attribution and source-aware cause formatting
are not implemented by formatting the parser's messages. Those remain required
by the active compiler workstream.


## Semantic AST positions and compile failures

The shared parser now attaches `location` metadata to semantic nodes, including
identifiers, expressions, blocks, parameters and statements. It records the
source file, one-based Unicode-scalar line/column endpoints and half-open scalar
offsets. Grouping retains the underlying identifier's precise token location;
normalization contracts compare semantic structure independently of locations.
Object shorthand, interpolation expressions and assignment targets retain their
original positions. Metadata does not change the AST kind or language values.

The LLVM compiler now uses those positions for undeclared reads/assignments,
top-level return diagnostics and literal import resolution failures. Imported
module errors refer to the defining file. Synthetic compiler/runtime bindings
without source metadata keep their existing diagnostic rather than inventing a
user position. Runtime Error source attribution is still outstanding.

The new `bootstrapped/tests/ast_locations.ql` contains 24 fixed span contracts
and eight empty/trivia parsing contracts. This also fixes whitespace-only files
and newline-only empty blocks being rejected after whitespace reached EOF or a
closing brace. All location, normalized-function AST and existing malformed
syntax contracts pass through the QLang parser on the retained host. Native
fixture/compiler builds and exact CLI diagnostic checks are in progress under
`target/semantic-diagnostics-check/`.

The native AST location fixture now passes O0/O2 (24 spans, eight trivia cases),
and the updated compiler has been rebuilt by the preceding native QLang compiler
and checked linked (2241 static strings). Exact semantic CLI diagnostics passed
all four cases through the QLang compiler on the retained host and through the
rebuilt native QLang compiler (`semantic-native.log`: ALL CHECKS PASS, process
completed). These include original Unicode columns, assignment targets, imported
file attribution and import-site failures, with nonzero exits and no emitted IR.
Current full fixed-point/core gates and runtime error locations remain outstanding.

## Bundled standard-library origins

The QLang source packager now records each module's original line starts and
source length in Unicode scalars, alongside its generated line range. It keeps
LF, CRLF and lone CR endings. Import/export replacement lines and an inserted
final newline no longer make generated scalar offsets appear to be original
file offsets.

`bootstrapped/source_origins.ql` remaps the parsed library's semantic locations
and structured/textual parse diagnostics before either engine consumes them.
Ranges spanning generated wrappers or multiple modules remain virtual. Remapping
does not alter semantic AST fields or annotation text, and shared diagnostic
objects are remapped once. The mapping is embedded; deployed executables do not
need the library source files for this step.

`bootstrapped/tests/source_origins.ql` checks original spans across newline styles,
Unicode, annotations, interpolation, wrapper ranges, parse diagnostics and the
production library loader. `aot/run_bundle_tests.py` independently checks native
QLang packaging of empty files, mixed newlines, Unicode separators, interpolation,
EOF without newline and stale-bundle rejection. Both the original-source fixture
(O0/O2) and the packager contracts pass using native QLang artifacts. The native
packager also verifies the repository bundle with --check. Terminal evidence is
in `target/source-origins-check/`; runtime Error attribution remains unfinished
in the main implementation.

Runtime provenance is now being validated in isolated candidates, not in the main
runtime/compiler. The first native candidate passes18 direct and7 module contracts
at O0/O2, old-layout extension rejection and source-aware unhandled call/import/
assignment reports, through both compiler build paths. Its Error layout/ABI change
was not published after automatic review rejected the initial direct main edit.

The second candidate adds scoped source contexts for the QLang AST evaluator,
including errors stored by declarations/assignments and host callback boundaries.
Twelve context contracts pass O0/O2; the checked native interpreter and embedding
probe are under validation in `target/runtime-core-diagnostics-check/`. This is
not yet interpreter/native parity or a current full-gate pass. The retained Rust
host lacks the new private capability and retains its previous error metadata;
existing function/module semantics still pass on that host running the QLang core.

The isolated experiments described above predate the user's staged decision.
Their public file/trace projections are not part of stage1 and cannot be merged
unchanged. Verification of an output-only revision remains required.

The output-only revision under `target/output-diagnostics-check/` now passes its
first native O0/O2 fixture via the retained-host QLang compiler:18 checks retain
the old Error interface and reject file/trace projections, plus unhandled
cached/reused/recursive/cause/library-source reports and old-ABI rejection.
Module cases, native-compiler CLI boundaries and native-core execution remain
under validation; this revision is still isolated from the main implementation.

The output-only retained-host compiler path is now fully verified:
`target/output-diagnostics-check/bootstrap.log` reports ALL CHECKS PASS
(session29879 exit0). Both18 direct and7 module checks pass O0/O2, together with
nine unhandled-report modes at each level and old-ABI rejection. Native compiler,
AST core, callback-boundary and full current gates remain outstanding.

The output-only native/interpreter boundary suite has now passed completely
(`target/output-diagnostics-check/boundary.log`, session62462 exit0): eight
basic checks plus five unhandled-report modes cover native and partial functions,
callback re-entry, restoration of an enclosing source context and no context leak.
A separate native compiler CLI test caught implementation frames leaking into
user diagnostics. Its repair is isolated under `target/output-diagnostics-fixed/`
and still under validation; main publication has not occurred.

The output-only native AST core suite has completed successfully
(`target/output-diagnostics-check/interpreter.log`, session24703 exit0):18 direct
and7 module checks, all nine unhandled-report modes, and absence of the internal
diagnostic hook from interpreted user `std`. The compiler CLI boundary repair
also passes a checked bootstrap-path build and exact usage-error output
(`target/output-diagnostics-fixed/bootstrap-cli.log`, session59917 exit0).
The fixed native compiler's semantic cases, O0/O2 output fixtures, current full
core/selfhost gates and native extension ABI matrix are still running.

Publication must preserve the newer main `aot/run_interpreter_tests.py` args gate
and `bootstrapped/README.md` argument documentation: the frozen diagnostic tree
predates those two changes. Its historical t40 and native-source-bridge fixtures
still contain deferred public metadata assertions and must be replaced with the
separately validated output-based versions, not copied wholesale.

The output-based context replacement now passes at both O0 and O2
(`target/output-diagnostics-fixed/context.log`, session13069 exit0):12 existing
field checks and11 exact stderr modes per level. Reusing a cached Error at the
same coordinates in a distinct invocation is covered, as are native partial
calls, scope restoration and unknown/synthetic source points. Portable regression
entry points are being prepared in the review overlay; full current-source gates
and main publication remain outstanding.

The supplemental args regression also passes on the output-only native core
(`target/output-diagnostics-fixed/arguments.log`, session62203 exit0), covering
empty arguments, scalar values and lexical/module sharing. This closes the
missing args invocation in the frozen test driver without modifying running
build inputs or replacing the newer main regression entry point.
