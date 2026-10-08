# Array contracts

The ordinary QLang module `stdlib/array.ql` implements these contracts for both
the LLVM compiler and self-hosted interpreter through the shared library loader. Rust bootstrap
implementation discrepancies are tracked separately in
[retained Rust issues](retained-rust-issues.md).

## Receivers and indices

Array operations validate their receivers before accessing array storage.
Curried operations validate the receiver at the first application; `concat`
also validates the second array. Invalid receivers return `TypeMismatch`.
`toString` retains generic value conversion, including numbers and null.

| Operation | Valid index | Invalid index |
| --- | --- | --- |
| `Array.get(a)(i)` | Return stored value | Return null |
| `Array.at(a, i)` | Return stored value | Non-Number: `TypeMismatch`; other invalid index: `IndexOutOfBounds` |
| `Array.remove(a)(i)` | Remove element, return null | Leave array unchanged, return null |

Indices must be finite integral Numbers. Negative indices count from the end.
Strings are not coerced, fractions are not truncated, and NaN/infinity never
select an element. A retained curried operation observes subsequent mutations.

`add` returns null, `push` returns the new length, and `pop` returns the removed
value or null for an empty array. Mutations retain references to inserted values.

## Stored values and search

`get`, `at` and `pop` preserve stored Error values, callable functions and shared
aggregate references. `reverse` and `concat` create shallow arrays and preserve
all elements, including Errors; they do not invoke the public `add` call policy
while copying. The interpreter preserves its internal value wrappers across
these boundaries so later calls and mutations still reach the original values.

`indexOf` and `includes` use scalar equality and reference identity for arrays,
objects and functions, as the language's `==` does. They do not walk aggregate
contents, so searching cyclic arrays/objects terminates. NaN does not match
itself; positive and negative zero match. Error elements are skipped rather
than interpreted as successful comparisons. Passing an Error as the search
argument is rejected by the ordinary call policy, retaining its cause.

Ordinary QLang partial-application, arity and Error-argument rules apply to every
Array operation. Migrated functions have no native `.name` metadata. The bound
language methods `a.add` and `a.remove` retain their primitive call rules.
An Error rejected as an insertion argument leaves the array unchanged. These
rules are distinct from retrieving or copying an Error already stored in an
array.

## Text conversion

`join` renders elements recursively, with the supplied String separator.
A non-String separator defaults to a comma, subject to the ordinary Error
argument rule. `toString` uses the same recursive rendering as interpolation,
including nested arrays and objects. This work does not add cycle detection to
text rendering; the cyclic regression cases cover identity search only.

## Regression coverage

`aot/tests/t29_arrays.ql` contains 176 checks, included in the compiler selfhost
and native interpreter gates. `aot/run_array_tests.py` runs those checks at
`-O0` and `-O2`, plus eight unhandled invalid-input cases that must exit with
status 1 and a `TypeMismatch` diagnostic instead of crashing:

```sh
python3 aot/run_array_tests.py --compiler target/array-library-check/bootstrap
```

The same fixture runs through the QLang interpreter hosted on Rust. Direct
Rust interpreter compatibility is deferred and is not a gate for this change.

## Shared implementation

The compiler emits the library's ordinary AST; the interpreter evaluates the
same source as ordinary function records. Neither engine dispatches standard
Array algorithms by name. Array length, indexing, indexed append and bound
removal are language mechanisms. Runtime partial-application argument assembly
is kept separate from std.Array.

The default module passes all 176 checks at O0/O2 and through the native core,
plus eight invalid-input exits at both optimization levels and 18 shared-loader
isolation checks on both paths. Logs: `target/array-library-check/`. Complete
core and selfhost gates for this revision are still running from its preserved
source snapshot.
