# QLang modules and lexical scope

Imports execute in their expression's lexical scope. Literal imports inside
functions, conditions, loop bodies, initializers, and other expressions use the
same AST as top-level imports. Literal paths resolve relative to the source
file that defines the expression, not the process directory or function caller.
Each executed import initializes a fresh module and fresh closures. An untaken
branch or an uncalled function does not initialize its imports.

Only exports actually produced during initialization are merged into the
importing scope. A skipped conditional export does not overwrite an existing
binding or its annotation. An import does not declare names absent from its
result. Name lookup and assignment fall back to the next outer lexical binding
when an optional import did not define the name. An explicit uninitialized
local declaration still hides an outer binding and produces Uninitialized on
read. An exported Error is a present value; it is not a missing export.

Export statements write to the defining module's export table. This includes
exports inside blocks, loops, functions, escaped closures, and partial
applications. The returned namespace refers to that table and can observe later
exports. Names previously merged into an importing scope remain snapshots;
later exports do not retroactively introduce or overwrite those bindings.

LLVM frames retain declaration presence separately from initialized value
state. This is internal scope metadata, not a new language value. Hidden module
export bindings are captured through the normal environment chain. The QLang
interpreter's function records likewise preserve the defining export table.

## Current limits

The LLVM graph loader still discovers all literal dependencies at compile time
and embeds them in the executable. Cyclic static graphs are accepted. A
per-module initialization guard reports ImportCycle only when execution
re-enters an active module. Guards are cleared on ordinary and propagated
initialization errors. Lazy imports after initialization therefore remain valid.

Missing dependencies still fail compilation even when an import would not
execute. The user selected runtime loading of separately compiled QLang extensions.
Runtime compilation/interpretation of newly supplied `.ql` source is out of scope.
Both LLVM-generated programs and the native QLang AST interpreter support this
extension contract. Hosts without the internal bridge and library unloading
remain outside that support, as detailed below.

## Evidence

`t35_scoped_modules.ql` covers 22 lexical module contracts, including skipped
initialization, conditional exports, closure/module identity, imported Error
values, declaration state, and function export ownership. It passes through the
QLang core on the bootstrap host and LLVM O0/O2 compiled by the QLang compiler
on that host. Subsequent integrated native core and selfhost gates passed on
the applied extension-bridge revision, including scoped/lazy module fixtures
and exact stage2/stage3 equality (`target/core-extension-integrated/`). Current
library-specific revisions and their validation scope are in the compiler roadmap.
`run_scoped_module_tests.py` additionally removes all fixture source files before
executing both LLVM builds and checks that block/function import names do not
leak into an outer scope.

`t36_lazy_modules.ql` adds nine contracts for lazy cyclic graphs, inactive
self imports, active cycles and cleanup after failed initialization. All nine
pass in the QLang core on the bootstrap host and LLVM O0/O2. The dedicated
`run_lazy_module_tests.py` also checks source removal and active/inactive root
cycles. Its native-compiler execution has passed, including the native core
and source-deleted LLVM O0/O2 runs. The later integrated core/selfhost gates
also passed on the applied extension-bridge revision.

## Native extensions

`let module = import (pathExpression);` evaluates the path once at runtime and
returns the exported namespace or an Error. Access exports through `module.name`.
A computed import does not introduce unknown bare names into its lexical scope;
ordinary literal imports retain their existing merging behavior. Both forms use
the shared Import AST, with `pathExpression` distinguishing the dynamic form.
Computed paths load native shared libraries, never newly supplied QLang source.
Relative paths use the defining source file's directory; deployment may instead
supply absolute paths. The source file itself need not exist at execution time.

Compile a module with `qlangc --emit-module module.ql aot/runtime.ql`, then use
`native_link.py --shared` to link its IR. Compile hosts with `--emit-llvm` and
link through `native_link.py` to export the runtime leaves needed by extensions.
Host compilation does not read, resolve or require the future extension file.

An extension embeds its literal QLang dependencies but shares the host's allocator,
standard-library closures and canonical type objects. It copies the base runtime
binding frame and retains host closures; per-module loading flags are local.
The ABI descriptor includes a representation version and the ordered runtime
slot names, checked before invoking the entry. This is the initial AArch64 ABI,
not a promise of compatibility across arbitrary future compiler versions.
QLang owns validation, relative-path resolution, fresh initialization, cycle
checks and Error construction. C supplies only `dlopen`/symbol lookup and keeps
one handle pinned per loaded library. Unloading is not implemented: escaped
closures and static strings can outlive their original namespace.

Repeated imports initialize fresh module state. Active re-entry returns
ImportCycle; both ordinary and propagated initialization errors clear the guard.
Libraries with incompatible ABI metadata return ImportABI; invalid shared
libraries and missing entries return ImportError. Filesystem failures retain
IOError. Extension functions use the ordinary call, annotation and partial
application mechanisms, without a second value representation.

The native QLang AST interpreter uses an internal QLang value bridge for these
modules. It preserves function and canonical-type identity, aliases and cycles,
and synchronizes shared objects/arrays at calls and callback re-entry. Callback
arity, annotations, partial application and Error-argument rules remain those of
the normal evaluator. Extensions see the interpreted script's process arguments.
The internal bridge is absent from interpreted user `std`.

Identity pairs are currently retained for the lifetime of the Interpreter
instance. Per-value reclamation across this bridge is not implemented; the
memory-management redesign remains deferred. This retention is separate from
pinning native libraries to keep escaped code and static strings valid.

A hosting runtime without the bridge returns NativeExtensionUnavailable. The
retained Rust implementation is unchanged. Relative paths still resolve at the
import expression's defining source, including escaped closures. The ABI includes
`interpreter-callback=1`; rebuild extensions with the matching compiler/runtime.
The bridge does not add runtime source compilation or library unloading.

`t37_extensions.ql` passes all 28 contracts for each O0/O2 host/extension
combination, using the QLang compiler on the retained bootstrap host. Hosts
were built before the extension files existed; all QLang fixture sources were
removed before execution from a different working directory. Coverage includes
embedded static dependencies, closures, partials, annotations, canonical types,
callbacks, object/array aliases, fresh state, late exports, cycles, ABI/file/entry
failures and allocation pressure. The corrected native QLang compilers then
emitted ordinary and dynamic-cycle extensions and passed the same four O0/O2
combinations with sources removed. The cycle compiler was itself rebuilt by
its native predecessor. This targeted proof is not a new full compiler
fixed-point or AST interpreter parity gate. ABI construction preallocates slot
storage before reordering keys, independent of object traversal order.
Checked-linker corruption/atomic-publication tests and O0/O2 allocator
root/interior-pointer tests also pass with the loader changes.

After default QLang `JSON.stringify` integration, a separate bridge check passed
28 assertions with the plugin source removed after compilation. It covers JSON
containers/Unicode, Error and function values, wrapper-like objects, partial calls,
root-Error causes and cycle depth behavior across the extension boundary. The
checked QLang compiler built the host and an O2 plugin; the native host passed at
O0/O2 and the checked native core passed. Evidence is in
`target/json-extension-check/verify.result.json`. This focused result does not
replace or expand the existing full extension/selfhost gate claims.

The dedicated lazy graph suite has now completed on the native QLang compiler:
nine contracts pass in the native core and LLVM O0/O2 with sources removed;
active and inactive root cycles also pass O0/O2. Its terminal log is
`target/extensions-check/lazy-native-fixed.log`.
