# Type Gymnastics Demo — Design

Date: 2026-08-11
Branch: `rust` (never merge to `master`)

## 1. Goal

A single QLang source file, `demo/type_gymnastics.ql`, that exercises the
runtime type system ("types as data") as hard as QLang can take it: type
combinators, dependent types, deep recursive type constructors, function
signature types, type-of-type (self-reference), complex nested schema
validation, and error-value integration. The demo is the **showcase**, not a
test-suite entry: it is verified by running the same file through both the
host interpreter and the bootstrapped interpreter and diffing the output.

**Hard constraint:** if any construct proves impossible to run — in the host
*or* the bootstrapped interpreter — that is a QLang bug, not a reason to cut
the gymnastics. The bug is recorded and fixed (host `src/` and/or
`bootstrapped/*.ql`) until host/boot outputs agree.

## 2. Acceptance criteria

1. `demo/type_gymnastics.ql` runs to completion on the host:
   `cargo run -- demo/type_gymnastics.ql`
2. The same file runs on the bootstrapped interpreter:
   `cargo run -- bootstrapped/run_file.ql demo/type_gymnastics.ql`
3. The two outputs are byte-for-byte identical.
4. Every chapter ends with a PASS count; the final line is a summary.
5. Each "deep water" feature (Section 6) either works on both, or lands on a
   fix list that is resolved before acceptance.

## 3. Architecture: descriptors vs type values

QLang type values produced by `std.Type.make(f)` are **opaque**: only the
`check` field is inspectable; you cannot decompose a type value to learn what
it was built from. Therefore the program operates on two layers:

- **Schema descriptors** — ordinary data (objects, arrays, strings, numbers):
  `{a: Number, b: String}`, `["a", "b"]`, `{length: 3, element: Number}`,
  `{key: String, value: Number}`. Descriptors are traversable, printable, and
  combinable (this is the source layer of the type world).
- **Type values** — the "compiled" layer, built from descriptors via
  `std.Type.make`, `Array(x)`, `Object(x)`, and combinators. The `Object`
  constructor is a **union**: `Object(Type)` = all keys pass `T.check`;
  `Object(shapeObject)` = strict schema (every field present and passing);
  `Object((obj) -> bool)` = **key-predicate** — the function receives the whole
  object and returns whether it satisfies an arbitrary, possibly key-dependent
  condition (e.g. "if `a` is present then `b` must be, and `c` must not be").
  The predicate member is what makes `Partial` and key-dependence expressible.

**Structure-aware combinators** (`Pick`, `Partial`, `Record`, `NamedArray`,
`Intersection`) operate on descriptors and emit type values. **Predicate
combinators** (`Union`, `Optional`, `Nullable`) operate directly on type
values via `check` booleans.

## 4. Program structure: four chapters + finale

Each chapter prints a header, runs its asserts, and prints a `PASS n/m` line.
The final line is `X/4 chapters PASS`.

### Chapter 1 — Combinator library

Definitions + verification:

- `Union(A, B)` = `std.Type.make((v) -> A.check(v) || B.check(v))`
- `Intersection(A, B)` = `std.Type.make((v) -> A.check(v) && B.check(v))`
- `Nullable(T)` = `Union(T, Null)` — value is `T` or `null`
- `Optional(T)` = accepts `null` or `T` (a safe `?? null`-style optional;
  QLang's "undefined" is an *uninitialized* error value and is out of scope
  for Optional's domain — Optional answers "is this a `T` or `null`")
- `Record(schema)` = `Object(schema)` — a required-fields subset record
- `Pick(recordDesc, keys)` — build a new descriptor with only `keys`, then
  `Record` it
- `Partial(recordDesc)` — make every field nullable: each key maps to
  `Nullable(fieldType)`
- `KeyDependent(rules)` — built on `Object((obj) -> bool)`: the predicate
  reads fields directly (`!isError(obj.a)`) and/or `Object.keys(obj)`, and
  returns a bool. Demonstrates **key dependence** the shape form cannot
  express: "if `a` present then `b` must be present", "if `a` present then
  `c` must NOT be", "either `x` or `y` present"
- `NamedArray(desc)` — `Array({length, element})`; `desc` is
  `{length: n, element: T}` or a plain list of type values (tuple form)

Each combinator gets 1–2 true/false asserts accumulated into the PASS count.

**Cross-link:** combinator inputs are themselves products of other chapters —
e.g. `Optional(Vect(3, Number))`, `Union(Matrix, String)`,
`Nullable(Record(...))`, `Pick(..., Partial(...))`.

### Chapter 2 — Dependent types (type constructors are functions)

- `Vect(n, T)` = `std.Type.make((v) -> std.Type.of(v) == AnyArray && v.length == n && every element passes T.check)`
- `Matrix(r, c, T)` = `Vect(r, Vect(c, T))`
- `TupleOf(ts)` = `Array([t1, t2, ...])` tuple form
- `Shape(sample)` — recursively derive a descriptor from a runtime sample:
  scalar → the type constant; array → `{length, element}` from the first
  element (via `Shape`); object → schema of `Shape` per field. `Shape` output
  feeds `Record`/`Pick`/`Partial`, so descriptors can be *inferred* at runtime
  and then compiled into types.
- Demonstrates: `Vect(3, Number)` accepts `[1,2,3]` rejects `[1,2]`; a
  `Matrix(2,3,Number)`; `Shape([1,2,3])` is semantically `Vect(3, Number)`.

### Chapter 3 — Complex nested schema validation

- `ServerConfig` descriptor: `port`, `host`, `routes` (array of route
  records), `middleware` (optional), and at least one field that is itself a
  dependent type (`vector: Vect(3, Number)`, `matrix: Matrix(2,2,Number)`),
  plus a function-type field (Section 6).
- One good instance passes fully; several bad instances each fail on exactly
  one dimension (missing field / wrong scalar type / bad array element /
  wrong vector length / wrong function signature).
- `describe(desc)` — render any descriptor to a readable (possibly nested /
  indented) string and print it, demonstrating that descriptors are printable
  data.

### Chapter 4 — Error-value integration

- A `validate` wrapper turns a failed `Record`-type check into an
  `Error.raise` error value (with the failing field name in the message).
- `?` propagation: a function returning the error value is called, the caller
  uses `?` to abort-and-return, and `isError` / `.type` / `.message` are
  asserted on the result.

### Finale — Combination storm (single continuous scenario)

1. `Shape` derives `user` and `role` descriptors from samples.
2. `Partial` + `Pick` build `UpdateUser` and `UserSummary` types.
3. `Record` nests them: `AuditLog = Record({ user: UpdateUser, ts: Number,
   meta: NamedArray({length: 2, element: UserSummary}) })`.
4. `Nullable`/`Optional` wrap dependent types: `Optional(Vect(3, Number))`
   accepts `null`, `undefined`-safe, and `[1,2,3]`.
5. Validators turn failures into error values; `?` propagates; `.message` is
   asserted to name the right field.
6. `describe` renders a deep descriptor as a tree; both interpreters print it.
7. Deep-water constructs from Section 6 are exercised and their results
   printed.

## 5. Verification procedure

For every iteration:

```bash
cargo run -- demo/type_gymnastics.ql            > /tmp/tg_host.out
cargo run -- bootstrapped/run_file.ql demo/type_gymnastics.ql > /tmp/tg_boot.out
diff /tmp/tg_host.out /tmp/tg_boot.out   # must be empty
```

The demo must stay within boot's performance envelope (interpreted-on-top-of-
interpreted): deep recursion depths and array sizes are chosen so the boot run
finishes in well under a timeout (target: seconds, ceiling tens of seconds).

## 6. Deep water (may require fixing QLang)

These are the constructs most likely to expose host/boot divergence or
outright crashes. Each is attempted; a failure is logged and fixed.

1. **Recursive type constructors** — `DeepArray(depth, T)` builds
   `Array(Array(...T))` 7–8 levels; `buildDeep(depth, v)` builds matching
   data; the two are checked symmetric (good and bad shapes). If recursive
   `Array()` nesting or deep `check` blows the stack in either interpreter,
   that is a bug to fix.
2. **TypeChain** — alternating `Record`/`Array` nesting to ~5 levels, e.g.
   `TypeChain(3, T)` = `Record({ inner: Array(TypeChain(2, T)) })`.
3. **Function signature types** — `Fn(ArgT, RetT)` uses a probe value to call
   the function and compare the result type: accepts `(x) -> x * 2` under
   `Fn(Number, Number)`, rejects `(x) -> "s"`. `Fn2` is the two-argument
   variant. Function types nest inside schema fields.
4. **Type-of-type** — `std.Type.of(std.Type) == std.Type` (self-reference);
   `exactType(T)` builds "exactly this type value" (`std.Type.of(v) == T`),
   distinguishing `Number.check(42)` from `exactType(Number).check(Number)`.
5. **Type values as data** — a binding annotated `: std.Type` holds a type
   value; a `Type`-typed list stores multiple type values; a type value is
   passed through and returned from a function.
6. **`Object((obj) -> bool)` predicate + boot object natives** — the
   key-predicate constructor member (Section 3). Inside the predicate, three
   operations must agree on both interpreters: field reads (`obj.a`), field
   existence (`!isError(obj.a)`), and `Object.keys(obj)`/`Object.values(obj)`.
   Field reads and existence already agree (boot's MemberAccess reads
   `obj.value[field]` on the wrapper view). **`Object.keys` does NOT agree**:
   boot object literals evaluate to the wrapper view
   `{type:"Object", value:fields}` (interpreter.ql:468), and boot's native
   branch keeps `Object`-tagged args wrapped (interpreter.ql:1000), so host
   `Object.keys` receives the wrapper (itself a host `Value::Object` with
   fields `type`/`value`) and correctly returns `["type","value"]` — the
   *envelope*, not the user's keys. **Fix: in boot's native branch, unwrap
   `Object`-tagged args to `a.value` for ALL natives** (`isNative && tag ==
   "Object"`). The name-family version (matching `func.name` against
   `Object.keys`/`Object.values`/`Object.merge`/…) was insufficient: **curried**
   natives carry a `"<curried>"` name suffix, so the second application of
   `std.Object.merge({x:1,y:2})({y:3,z:4})` slipped past the family check and
   merged the envelope's `{type, value}` keys. Unwrapping for every native is
   safe — boot QLang functions (stdlib.ql) probe `func.name` as an error, so
   `isNative` is false and they keep the wrapper view. This restores the
   "pass an object, get its keys" contract inside user predicates. A related
   rawArgs fix passes raw host values (`.type` probe errors) through unchanged
   instead of `a.value`, so host-native results like
   `std.Object.keys({a:1,b:2})[0]` work when fed to further natives.

## 7. In scope / out of scope

- In scope: the demo file, host/boot parity fixes required by the demo, and
  this spec.
- Out of scope: new language features beyond fixing genuine bugs the demo
  exposes; changes to existing test suites; anything on `master`.
- The demo is a showcase; it does **not** join `difftest.py`'s suites (per
  the chosen "独立 demo 程序" path). Fixes it forces (if any) DO get
  regression tests in the normal suites.

## 8. Deliverables

1. `demo/type_gymnastics.ql`
2. Any host (`src/`) and/or boot (`bootstrapped/*.ql`) fixes the deep-water
   section requires, each with a regression case in the appropriate suite.
3. Host/boot output diff empty (Section 5).
4. A short README or doc section pointing at the demo (optional if README is
   already long; decide at the end).
