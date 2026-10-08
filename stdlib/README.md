# QLang standard library

Library algorithms belong in ordinary QLang modules, shared by interpreted and
compiled execution. They must not use LLVM intrinsics, raw memory access, Rust
algorithms or system-library algorithms. Unicode tables are static data; their
Python generator is a development utility, not a language runtime dependency.

`string.ql` exports `StringLibrary` for explicit use and supplies the default
`std.String` through the shared loader. It covers length, concat, rendering,
trim, default Unicode case mapping, includes, startsWith, endsWith, replace,
split, repeat, join and at. Unicode 15.1.0 data is pinned; casing includes
expansion and contextual final sigma. The algorithms use ordinary QLang
indexing, objects, arrays, type predicates, interpolation and Error creation.

`build_bundle.ql` packages the manifest's QLang source as QLang string literals;
`bootstrapped/library.ql` parses that same bundle for both execution paths.
The compiler emits its ordinary AST without runtime privileges. The interpreter
executes its ordinary function records in a private bootstrap environment.
Public namespace tables stay isolated per user module. A compiled program does
not read the library source files at runtime or invoke Python.

The old String algorithms have been removed from `aot/runtime.ql`. The remaining
codepoint entry is a transitional primitive awaiting a portable language API.
Array also uses the shared loader; its backend library algorithms and interpreter
adapters have been removed. `math.ql` now supplies PI, E, abs, trunc, floor, ceil
and round through the same shared loader. Its185 default-library checks and the
existing numeric fixture pass LLVM O0/O2 and the newly compiled QLang interpreter.
Private trunc/round helpers still support the unmigrated pow algorithm. Remaining
Math operations and other runtime library families still need migration; see
[capability gaps](../docs/stdlib-capability-gaps.md).

```ql
import ./stdlib/string.ql;
println(StringLibrary.toUpperCase("Straße"));  // STRASSE
println(StringLibrary.replace("aaaa")("aa")("X"));  // XX
```

Non-String receivers return TypeMismatch. Existing optional-argument fallbacks
are retained: search returns false, split returns the original string as one
part, replace/repeat return the original string, and join returns an empty
string. Error arguments follow ordinary language call rules. Functions are
ordinary QLang functions, including the language's partial application rules.
There is no native-only function metadata or separate dispatcher algorithm.

Replace processes all non-overlapping matches. Empty patterns match scalar
boundaries, including both ends; split with an empty separator retains empty
ends. Indices are finite integers and may be negative. Repeat rejects negative,
fractional and nonfinite counts with RangeError. Empty input returns immediately
for any valid count. This implementation limits repeat results to 16,777,216
Unicode scalars and reports RangeError before concatenating larger results.
The bound is expressed in scalars and does not require backend byte access.

Unicode whitespace follows White_Space; U+200B and U+FEFF are not stripped.
Case conversion uses default, locale-independent mappings. Unicode data is
covered by [its license](unicode-LICENSE.txt). To regenerate, download the four
source files named in the generator from the pinned Unicode UCD directory:

```sh
python3 stdlib/generate_unicode_tables.py --ucd-dir /path/to/ucd-15.1 --check
```

The generated header records each source's SHA-256. The casing rules follow
[Unicode's default case algorithms](https://www.unicode.org/versions/Unicode15.1.0/),
with property data from DerivedCoreProperties.txt and PropList.txt.

The portable fixture is `aot/tests/t30_strings.ql` (193 checks). Its dedicated
runner additionally compares every Unicode 15.1 scalar with nonidentity casing
against Python's independently bundled Unicode 15.1 data, checks sigma contexts
and whitespace, and verifies unhandled errors at both LLVM optimization levels:

```sh
python3 stdlib/run_string_tests.py \
  --compiler target/array-library-check/bootstrap \
  --interpreter target/array-library-check/core/interpreter
```

Python is a test oracle only; the resulting QLang program does not call it.

Verified in this migration step: all 193 contracts pass on direct LLVM output
at `-O0`/`-O2`, the native QLang core and the Rust-hosted QLang core. The independent
Unicode oracle passes on both LLVM optimization levels and the native core;
four unhandled-error cases pass at both optimization levels. Logs are retained
under `target/string-check/`. Those results preceded automatic installation. Loader verification is tracked
separately under `target/library-load-check/`; the Rust sources remain unchanged.

## Source bundle construction

Run from the repository root. The bundler itself is QLang and can be compiled
with the QLang compiler or run with the retained initial bootstrap executable:

```sh
./target/release/qlang stdlib/build_bundle.ql > /tmp/qlang-library-bundle.ql
# Publish only after successful generation and review/verification of the output.
cp /tmp/qlang-library-bundle.ql stdlib/bundle.ql
./target/release/qlang stdlib/build_bundle.ql --check
# The compiled build-bundle executable accepts the same --check argument.
```

`manifest.json` fixes dependency and export order with explicit arrays; the packager rejects dependencies not
already bundled. It preserves Unicode line/paragraph separators inside string
literals and escapes library interpolation syntax during source embedding.
Original source line ranges are retained in `standardLibraryOrigins`.
Python remains a Unicode data-generation and test utility, not a requirement
of this source-bundling or language execution path.

`array.ql` supplies default `std.Array` through the same shared loader. Its
algorithms use indexed access/append and the language's existing bound Array
removal operation. `object.ql` now supplies values, merge, hasOwn, get and field
through the same loader; it still depends on existing Object.keys reflection.
`number.ql` supplies parseFloat and numeric predicates, while `json.ql` and
`json_quote.ql` supply JSON.stringify traversal and escaping. JSON.parse and
Number.toString remain runtime-provided. See the capability-gap document above
for the remaining portable interfaces and exact migration status.

After lazy table initialization and traversal fixes, the **default** String
namespace passes the same complete dedicated suite, including the Unicode
oracle: `target/library-scan-check/strings.log`. Further interpreter value-access
fixes have since passed their integration gates; current applied revisions and
scope are recorded in the compiler roadmap. To validate the portable Array
module explicitly as well as its default installation:

```sh
python3 aot/run_array_tests.py --compiler /path/to/compiler \
  --library stdlib/array.ql --interpreter /path/to/interpreter
```
