# Standard library / language capability boundary

User requirement: all standard-library algorithms are QLang. LLVM implements
language features; it must not own a second standard library. Rust discrepancies
remain deferred unless they prevent QLang work. This audit is incomplete and
must be extended as each existing runtime family is migrated.

## Confirmed boundaries from current code

| Capability | Current source | Required follow-up |
| --- | --- | --- |
| Unicode scalar ↔ numeric code point | `aot/runtime.ql` String.codePointAt and its approved inverse String.fromCodePoint (UTF-8 decode/encode leaves) | Implemented as backend-independent String representation mechanisms. The portable String and JSON modules use them through ordinary calls; no native stdlib algorithm is delegated to. |
| Exact binary64 representation | Number.frexp (mantissa in [1,2) + power-of-two exponent) and Number.ldexp (m·2^e) are the approved representation mechanisms; Math.sqrt/pow/sin/cos are ordinary QLang in `stdlib/math.ql` built on them | Negative-zero *sign* is not observable through frexp/ldexp, and division by zero is an error, so the runtime's Number.toString text is the only in-library oracle for `-0`. Ordinary arithmetic alone still loses that information; do not silently call libm/Rust. |
| Files, canonical paths, process I/O, OS entropy | C syscall leaves and QLang buffering/validation in `aot/runtime.ql` | External effects require a host capability boundary. Keep algorithms and error handling in QLang; primitive host operations need an explicit language/embedding contract before relocating these libraries. |
| Load native shared libraries and resolve symbols | `ql_extension_open` in `aot/runtime.c` uses the platform loader; module policy is in QLang | This is the dynamic-import language mechanism, not a standard-library algorithm. QLang cannot implement the OS loader boundary with its current portable operations. Libraries are pinned; unloading remains unimplemented. The native AST interpreter uses a private QLang value bridge, without adding portable OS-loader primitives or standard-library algorithms. |
| Create structured Errors with kind/message/cause | `std.Error.raise` is currently runtime-provided | Make the error-construction language primitive explicit. Portable String currently uses this existing primitive to create Errors, not a host string algorithm. |
| Variable-arity QLang functions | The shared Parameter AST has fixed parameters; Math.min/max are runtime dispatch mode 6 (variadic native) carrying a diagnostic name, and Math.random is a runtime entropy mechanism | Moving the max/min comparison into the library was attempted and rejected: `aot/run_call_tests.py` pins that a variadic max/min call performs **no per-call heap work** (delegating to a library function grew allocations 6664 → 12664 for +1000 calls, because a library call allocates a frame), and the Error-argument message names the function, which the dispatcher — never the body — produces. A general rest-parameter/argument-list mechanism would still be needed to express *other* variadic APIs in QLang. |
| Native exact arity versus ordinary QLang partial calls | Native `std.Number.parseFloat()` returns ArityMismatch; an ordinary one-parameter QLang function returns a partial when called without arguments | Confirmed by the user: migrated libraries use ordinary QLang function rules, including partial application. No exact-arity compatibility wrapper or backend library-name exception is needed. |
| Functions intentionally accepting Error arguments | Ordinary QLang calls reject Error arguments before the body; native diagnostics/type predicates use private exemptions | Error.toString, isError and other diagnostic/type functions cannot preserve that API as ordinary functions without an explicit language-level mechanism. Do not add library-name exceptions in LLVM. |
| Object enumeration and algorithms | `std.Object.values`, `merge`, `hasOwn`, `get` and `field` are ordinary QLang in `stdlib/object.ql`; they use the existing `std.Object.keys` host reflection operation | The algorithms are migrated and default-installed. Fully portable key enumeration still needs a language-level reflection contract. Do not build a second hash table in LLVM for the library. |
| Automatic standard-library loading | Per-module std namespaces currently clone backend tables | Shared QLang source loading and default String/Array/base Math/Number/Object/JSON.stringify installation are implemented. Complete the remaining library migrations through the same path; loader regression and selfhost gates remain required. |

These are missing *portable interfaces*, not claims that Unicode algorithms need
C or that floating-point math must use a system library. Unicode casing and
whitespace algorithms already run in ordinary QLang using generated constant
data, without codepoint conversion or raw byte access.

## Current migration state

The default manifest (`stdlib/manifest.json`) installs String, Array, base Math,
Number, Object and JSON.stringify through the shared QLang source loader.
`stdlib/build_bundle.ql`
packages those sources in QLang; Python scripts provide tests and static Unicode
data.

- `stdlib/string.ql`: casing, whitespace and other migrated String algorithms
  use ordinary QLang and Unicode constant data. The transitional codePointAt
  operation still needs the representation boundary listed above.
- `stdlib/array.ql`: algorithms use ordinary indexing, indexed append, equality,
  interpolation and the existing bound array.remove operation. Shrinking an
  aliased array requires that mutation mechanism; the library does not inspect
  raw array storage or call old std.Array algorithms.
- `stdlib/math.ql`: PI, E, abs, trunc, floor, ceil, round, and now sqrt, pow,
  sin and cos are ordinary QLang, installed in main. The transcendental
  algorithms were moved out of `aot/runtime.ql` and are rebuilt on the
  Number.frexp/Number.ldexp representation mechanisms; the runtime keeps only
  the variadic max/min dispatch and the entropy-backed random. The numeric
  suite passes on LLVM O0/O2 with max ULP {sqrt 1, sin 2, cos 2, pow 0}, and the
  selfhost and interpreter gates pass.
- `stdlib/number.ql`: ordinary QLang `parseFloat`, `isNaN` and `isFinite` are
  installed and import the QLang Decimal and String modules. The applied
  candidate passed all eight gates, including the 49-value native/core oracle,
  stage2/stage3 fixed point and stage2 function execution check. It does not
  provide Number.toString; complete Number formatting portability remains open.
- `stdlib/object.ql`: `values`, `merge`, `hasOwn`, `get` and `field` are ordinary
  QLang algorithms installed by default. The application passed all eight
  Object gates, including stage2/stage3 fixed point and stage2 function
  execution. `Object.keys` remains the existing native reflection operation,
  so this does not complete Object portability.
- `stdlib/json.ql` supplies default `JSON.stringify` and `JSON.parse`; both are
  ordinary QLang. `json_quote.ql` provides ordinary-QLang string escaping and the
  parser decodes `\uXXXX`/surrogate pairs through String.fromCodePoint. Object
  key order is not an API guarantee and is not asserted by the tests. The
  runtime's former `__jp_*`/`__json_parse` were removed, so no JSON algorithm
  remains in `aot/runtime.ql`. Stringify still reads Number.isFinite and the
  runtime Number.toString text; Object.keys remains native reflection.
- Remaining runtime std surface is mechanisms only: Object.keys (reflection),
  Number.toString (runtime-internal: `__str`, diagnostics, object keys),
  Math.max/min (variadic dispatch) and Math.random (entropy), String.codePointAt/
  fromCodePoint, Number.frexp/ldexp, String/Number/Error/Fs primitives.
  Number.toString formatting portability and complete Object reflection remain
  open; privileged QLang in `aot/runtime.ql` is not a complete portable-library
  implementation merely because its source language is QLang.

The native interpreter extension bridge is a language interoperability
mechanism. It does not migrate these libraries. It retains identity pairs for
its Interpreter lifetime and pins shared libraries; finer reclamation and
unloading remain unimplemented. See [module-semantics.md](module-semantics.md).

## Work order and deferred candidates

The user prioritizes the self-hosted compiler, ordinary language execution,
modules and useful source diagnostics. Pow, nonessential Math migration,
performance optimization and memory replacement are deferred. Do not resume
those experiments just because their artifacts exist. Current integration
status is maintained in [compiler-next-steps.md](compiler-next-steps.md).

Isolated sqrt/sin/cos and pow candidates exist under target/. Their
explicit-import or targeted passes do not establish default installation or
full compiler integration. Number parsing/predicates have since been integrated
and applied; Number formatting remains incomplete. Earlier progress paragraphs
described some of these jobs as active; those descriptions were historical and
must not be used to restart them. The previous audit text is
preserved in `target/core-extension-integrated/stdlib-capability-gaps-before-cleanup.md`.

Two findings remain useful for later work without approving any new feature:

- Existing arithmetic can replace some private binary64 normalization and
  construction helpers. A raw-memory implementation dependency alone does not
  prove a new public primitive is necessary. Preserve rounding and signed-zero
  behavior when evaluating an alternative.
- Portable library closures capture a private base namespace. A library that
  needs another migrated library must use the shared module import mechanism,
  rather than assume that later changes to the public std namespace will update
  its captured dependencies.

The numeric object-key defect is tracked separately in the compiler roadmap.
Its narrow runtime formatting repair does not complete Number formatting or
JSON portability, or authorize publication of broader Math candidates.

## Reviewed follow-up split

Luna's source inventory was reviewed during the current Number integration.
Existing APIs and missing portable capabilities must be distinguished:

- `std.Error.raise(kind, message, cause)` already constructs structured Errors
  and is usable by ordinary QLang libraries. Its classification as a language
  primitive/host boundary remains to be made explicit; it is not an absent API.
- Object algorithms are now ordinary QLang and default-installed: values,
  merge, hasOwn, get and field use existing `std.Object.keys`. Key enumeration
  itself remains native reflection, so complete Object portability still needs
  an agreed language contract for that operation. The hasOwn implementation
  enumerates keys rather than treating a stored Error as absence; ordinary
  member/index operations construct and mutate objects.
- JSON.stringify traversal and escaping are now ordinary QLang. They retain
  existing Object key enumeration and exact Number formatting dependencies.
  JSON.parse remains in the runtime; its grammar can use current QLang, while
  decoding non-ASCII `\uXXXX` escapes needs scalar construction. A portable
  inverse of codePointAt is currently absent. Stringify preserves ordinary
  Unicode input and escapes controls using a QLang table, so it does not need
  that inverse operation.
- Filesystem readFileText/canonicalPath already exist. Computation can implement
  buffering and validation, but actual reads/path resolution require a host
  operation. Agree that boundary before moving the implementation; there is no
  need to invent an additional public filesystem API to begin the discussion.

Detailed source evidence and bounded tasks remain in
`target/luna-library-inventory/report.md` and `next-tasks.md`. Those were static
reviews, not newly executed library tests. Core semantics, boundary proposals
and final integration stay with Astra; Luna handles isolated implementations,
regression fixtures and inventories under the confirmed language rules.

## Decisions required before new public capabilities

For each remaining library, first identify the smallest missing operation using
current QLang semantics. Record a concrete example that cannot be implemented
while preserving the existing API, then ask the user about the language-level
contract. In particular, variable arity, intentionally accepted Error arguments,
portable Object key enumeration, Unicode scalar conversion and OS effects must
not be hidden behind library-name special cases in LLVM. Do not silently change
an existing variadic API to an Array argument or treat a stored Error as a
missing object property.

## Confirmed Number call policy

The user approved ordinary QLang function rules for migrated standard-library
functions, including partial application. The native/core comparison remains in
target/number-call-policy-audit/result.json; its decision field now records the
approval. The separate partial-function name discrepancy has been repaired and
passed all five affected-path gates (see the compiler roadmap).

Number parsing and predicates are now installed as ordinary QLang functions.
The application record is `target/number-portable-current/main-application.json`:
203 frozen inputs, nine changed files, and eight passing gates. The selfhost gate
verified stage2/stage3 fixed-point equality and the stage2 function execution
fixture. The installed exports are `Number.parseFloat`, `Number.isNaN` and
`Number.isFinite`; no Number formatting method was added. `Number.toString` and
complete formatting portability remain unfinished: it is runtime-internal (used
by `__str`, diagnostics and object keys), and its exact-shortest-digit path needs
the raw big-integer layer. The previously deferred Math scope (sqrt/pow/sin/cos)
has since been migrated to `stdlib/math.ql` on the frexp/ldexp mechanisms; only
the variadic max/min dispatch and entropy random remain runtime natives.

## Unicode escape decoding: implemented

Status: implemented. `String.fromCodePoint(n)` was approved and added as a
backend-independent String representation mechanism (the inverse of
`String.codePointAt`): it constructs a one-scalar String for integral code points
0..1114111, rejecting surrogates 55296..57343 and non-integral/out-of-range
inputs with RangeError. It lowers through ordinary member lookup and call, with
no JSON or standard-library-name dispatch.

`stdlib/json.ql` now implements `JSON.parse` in ordinary QLang: grammar, escape
scanning, surrogate-pair combination (halves are combined before the constructor
is called, so an unpaired surrogate is rejected) and the existing malformed-JSON
error text. The runtime's `__jp_*` / `__utf8_put` decoder was removed. Inputs
such as `"\u4e2d"` → `"中"` and `"\uD83D\uDE00"` → `"😀"` are covered by t11 and
by a 68-input host/native differential. A separate character type, byte-array
API, or general encoding framework was not required.

## Open issue: a new library binding referenced from the export object crashes (2026-10-10)

While adding `std.Result(T)` the native path started segfaulting at startup. Bisected
with a minimal module (`let Result = 42;`), using `println(std.Math.sqrt(4))` as the
probe and always rebuilding the compiler from the modified bundle:

| variant | content | result |
|---|---|---|
| V3 | new module added, binding **not** referenced by the export object | works |
| V4 | new export entry, but pointing at an **existing** binding (`Math2: MathLibrary`) | works |
| V5 | new module, its new binding referenced from the export object | segfault |
| V7 | same as V5, module placed first in the bundle instead of last | segfault |

So it is specifically "the export object references a binding that only the newly
added module defines", independent of position: the runtime's own `__fresh_std` /
`__install_library` are dynamic and not at fault. The most likely cause is that the
new binding does not get a slot in the library frame, so the export object reads an
unallocated slot. Next step: compare the emitted IR of a *working* export (e.g.
`MathLibrary`) with the failing one and check the slot allocation for the added
module's binding.

Relevant when this is picked up: this is the blocker for design step B (`std.Result`)
in docs/result-type-proposal.md.

### Root cause (found with AddressSanitizer)

Compiling the failing program with `-fsanitize=address` points straight at the fault:

```
#2 ql_mem_get_ptr (aot/runtime.c:200)
#3 ql_fn14  <- #4 ql_fn15  <- #5 ql_fn126  <- main
```

An object/table operation is applied to something that is not an object. The library
namespace machinery assumes **every exported member is a module object**: in
`__install_library`, each member is fetched and then `__obj_keys(module)` is called on
it; `__fresh_std` similarly probes each member with `readU64(value, 0)`. Exporting a
*type constructor* (a function) or a *scalar* therefore dereferences a non-pointer.

Two consequences:

1. `Result(T)` must not be a library-namespace export. It belongs where `Array` and
   `Object` live: a runtime-provided *type constructor* (that is how `Array(Number)`
   already works), with the check predicate supplied the same way.
2. The runtime has a latent robustness defect worth fixing independently: the library
   plumbing should reject or skip a non-object member instead of crashing.

