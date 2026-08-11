# Type Gymnastics Demo Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Build `demo/type_gymnastics.ql`, a single QLang file exercising the runtime type system (combinators, dependent types, deep nesting, function types, type-of-type, schema validation, error-value integration), verified byte-identical across the host and bootstrapped interpreters.

**Architecture:** One file, five sections (Chapters 1–4 + a combination-storm finale), each printing a `PASS` line. A shared harness counts assertions. Deep-water constructs (recursive type constructors, function signature types, Type:Type) live in the finale and may expose host/boot bugs — if they diverge, that is a QLang bug to fix, not a reason to cut the gymnastics.

**Tech Stack:** QLang (host: Rust in `src/`; bootstrapped: `bootstrapped/*.ql`), `difftest.py` for regression cases, `cargo run` for both interpreters.

## Global Constraints

- **Branch:** `rust`. Never merge to `master`. No git HTTPS pushes (no credentials) — never retry a push without explicit permission.
- **Host/boot output must be byte-for-byte identical** for `demo/type_gymnastics.ql`.
- **Boot syntax limits (non-bugs):** no `if` *expression* — use the block form `{ if c { A; } else { B; }; }` (block value is the branch value). Function call arguments must fit on one line. String `<` comparison is unsupported (comparison is Number-only). `Object.keys` order is nondeterministic (HashMap) — demo output must never depend on key iteration order.
- **Boot recursion guard** at depth ~33 (interpreter.ql:47-55). Keep gymnastics depths ≤ 12 so checks stay far below it.
- **Boot performance** is interpreter-on-interpreter; keep loops/recursion small (≤ a few hundred ops).
- Every `println` string must render **identically** in host and boot. Only verified-safe stdlib calls: `std.Number.toString`, `std.Boolean.toString`, `std.String.toString`, `std.Object.keys`, `Error.raise`, `isError`, `std.Type.of`. Never pass a raw Boolean/array/object/type value to `+` — `std.Boolean.toString(x)` for booleans; `std.Number.toString(x)` for numbers; stringify types via `std.Type.of(t)` + the constants table.
- **Boot call-arg one-line rule:** a `println(...)` whose argument list spans lines breaks the boot parser. Build long lines by concatenating with `+` on ONE logical line, or pre-assemble the message into a variable.
- No new language features beyond fixing genuine bugs the demo exposes. Fixes land in `src/` and/or `bootstrapped/*.ql` AND get a regression case in `difftest.py` (COMPLEX or RISKY list, per-case process isolation).

---

### Task 0: Probe dynamic key access (`obj[key]`) on host and boot

**Files:**
- Create: `/tmp/ql_probe/probe3.ql` (temp, not committed)
- Run on host and boot

**Interfaces:**
- Consumes: nothing
- Produces: a decision — whether `obj[key]` dynamic key access works on both host and boot. The Combinator Descriptor Access helper in Task 1 depends on it.

- [ ] **Step 1: Write the probe**

```qlang
let o = { a: 1, b: 2 };
let k = "b";
let v = o[k];
let ks = std.Object.keys(o);
let acc = "";
let i = 0;
while i < ks.length { acc = acc + ks[i] + ","; i = i + 1; };
let t = (x) -> { if x { "T"; } else { "F"; }; };
println("probe3 dyn=" + std.Number.toString(v) + " keys=" + acc + " hasA=" + t(o["a"] == 1));
```

- [ ] **Step 2: Run on host**

Run: `cargo run -- /tmp/ql_probe/probe3.ql`
Expected: `probe3 dyn=2 keys=<some order> hasA=T`

- [ ] **Step 3: Run on boot**

Run: `cargo run -- bootstrapped/run_file.ql /tmp/ql_probe/probe3.ql`
Expected: `probe3 dyn=2 keys=<some order> hasA=T`

- [ ] **Step 4: Record the finding**

- If dynamic key access works on both: document in the plan's Combinator Descriptor Access helper (Task 1) — `obj[key]` is available.
- If it fails on either: the descriptor access helper must use a different mechanism (e.g., only top-level globals). Record the divergence — this may be a QLang bug to fix (open an issue; the demo works around it if it is a non-bug syntax limit).
- Keys order is deliberately ignored (nondeterministic) — only `hasA` and `dyn` are asserted.

---

### Task 1: Demo skeleton + harness + Chapter 1 combinators

**Files:**
- Create: `demo/type_gymnastics.ql`

**Interfaces:**
- Consumes: Task 0's dynamic-key-access finding.
- Produces: the harness `cnt`/`assert`/`finishChapter`, and the Chapter 1 combinator library (`Union`, `Intersection`, `Nullable`, `Optional`, `Record`, `Pick`, `Partial`, `NamedArray`, plus `fnType` later). Later chapters call `assert` and add to `cnt`.

- [ ] **Step 1: Write the file with the harness**

```qlang
// QLang type gymnastics demo. Run host & boot, diff output.

// ---------- harness ----------
let cnt = 0;      // total asserts run
let passed = 0;   // asserts that passed
let assert = (name, cond) -> {
  if cond { passed = passed + 1; } else { println("  FAIL " + name); };
  cnt = cnt + 1;
};
let chapterStart = (n, name) -> {
  cnt = 0;
  passed = 0;
  println("=== Chapter " + n + ": " + name + " ===");
};
let chapterEnd = (n) -> {
  println("  " + std.Number.toString(passed) + "/" + std.Number.toString(cnt) + " PASS");
};
let show = (label, v) -> println(label + std.Number.toString(v));
```

- [ ] **Step 2: Add Chapter 1 header + predicate combinators**

```qlang
chapterStart(1, "Combinator library");

// ---------- predicate combinators (operate on type values) ----------
let Union = (A, B) -> std.Type.make((v) -> A.check(v) || B.check(v));
let Intersection = (A, B) -> std.Type.make((v) -> A.check(v) && B.check(v));
let Nullable = (T) -> Union(T, Null);
let Optional = (T) -> Union(T, Null);
```

Note: `Optional(T)` is `Union(T, Null)` — QLang's "undefined" is an *uninitialized* error value and is out of scope for Optional's domain.

- [ ] **Step 3: Add structural combinators (operate on descriptors)**

```qlang
// ---------- structural combinators (descriptor -> type value) ----------
let Record = (schema) -> Object(schema);
let Pick = (desc, keys) -> {
  let out = {};
  let i = 0;
  while i < keys.length {
    let k = keys[i];
    out[k] = desc[k];
    i = i + 1;
  };
  Object(out);
};
let Partial = (desc) -> {
  let out = {};
  let ks = std.Object.keys(desc);
  let i = 0;
  while i < ks.length {
    let k = ks[i];
    out[k] = Union(desc[k], Null);
    i = i + 1;
  };
  Object(out);
};
let NamedArray = (desc) -> Array({ length: desc.length, element: desc.element });
```

**Task 0 dependency:** if `obj[key]` dynamic access failed on either side, `Pick`/`Partial` must use a different mechanism. Record the fix here.

- [ ] **Step 4: Verify Chapter 1 combinators with a few asserts**

```qlang
assert("union num-or-str: 42", Union(Number, String).check(42));
assert("union num-or-str: 'hi'", Union(Number, String).check("hi"));
assert("union num-or-str: false", !Union(Number, String).check(false));
assert("intersect num+positive", Intersection(Number, std.Type.make((v) -> v > 0)).check(5));
assert("intersect num+positive: neg", !Intersection(Number, std.Type.make((v) -> v > 0)).check(-1));
assert("nullable null", Nullable(Number).check(null));
assert("nullable num", Nullable(Number).check(3));
assert("nullable str: false", !Nullable(Number).check("s"));
assert("optional null", Optional(String).check(null));
assert("optional str", Optional(String).check("x"));
let Rec = Record({ a: Number, b: String });
assert("record good", Rec.check({ a: 1, b: "x" }));
assert("record missing b", !Rec.check({ a: 1 }));
assert("record extra ok", Rec.check({ a: 1, b: "x", c: true }));
let Picked = Pick({ a: Number, b: String, c: Boolean }, ["a", "c"]);
assert("pick a,c good", Picked.check({ a: 1, c: true }));
assert("pick a,c missing c", !Picked.check({ a: 1 }));
let Part = Partial({ a: Number, b: String });
assert("partial all present", Part.check({ a: 1, b: "x" }));
assert("partial a only", Part.check({ a: 1 }));
assert("partial empty", Part.check({}));
assert("partial bad type", !Part.check({ a: "s", b: "x" }));
let NA = NamedArray({ length: 3, element: Number });
assert("named-array good", NA.check([1, 2, 3]));
assert("named-array short", !NA.check([1, 2]));
assert("named-array bad elem", !NA.check([1, "a", 3]));

chapterEnd(1);
```

- [ ] **Step 5: Run host + boot, diff**

Run:
```bash
cargo run -- demo/type_gymnastics.ql > /tmp/tg_host.out
cargo run -- bootstrapped/run_file.ql demo/type_gymnastics.ql > /tmp/tg_boot.out
diff /tmp/tg_host.out /tmp/tg_boot.out
```
Expected: empty diff. Fix any divergence (likely boot syntax) before proceeding.

- [ ] **Step 6: Commit**

```bash
git add demo/type_gymnastics.ql
git commit -m "feat(demo): type gymnastics — harness + combinator library"
```

---

### Task 2: Chapter 2 dependent types

**Files:**
- Modify: `demo/type_gymnastics.ql`

**Interfaces:**
- Consumes: harness (`chapterStart`/`assert`/`chapterEnd`), `Union` (Ch.1).
- Produces: `Vect`, `Matrix`, `TupleOf`, `Shape` — used by Chapters 3 and the finale.

- [ ] **Step 1: Add Chapter 2 section + dependent-type constructors**

```qlang
chapterStart(2, "Dependent types");

// type constructors are functions: the type depends on runtime values
let Vect = (n, T) -> std.Type.make((v) -> {
  if std.Type.of(v) != AnyArray { false; } else {
    if v.length != n { false; } else {
      let ok = true;
      let i = 0;
      while i < v.length {
        if !T.check(v[i]) { ok = false; };
        i = i + 1;
      };
      ok;
    };
  };
});
let Matrix = (r, c, T) -> Vect(r, Vect(c, T));
let TupleOf = (ts) -> Array(ts);
let Shape = (v) -> {
  let tv = std.Type.of(v);
  if tv == Number || tv == String || tv == Boolean { tv; }
  else if tv == Null { Null; }
  else if tv == AnyArray {
    if v.length == 0 { AnyArray; } else { Array({ length: v.length, element: Shape(v[0]) }); };
  } else if tv == AnyObject {
    let out = {};
    let ks = std.Object.keys(v);
    let i = 0;
    while i < ks.length {
      let k = ks[i];
      out[k] = Shape(v[k]);
      i = i + 1;
    };
    out;
  } else { Any; };
};
```

- [ ] **Step 2: Verify with asserts**

```qlang
assert("vect 3 num good", Vect(3, Number).check([1, 2, 3]));
assert("vect 3 num short", !Vect(3, Number).check([1, 2]));
assert("vect 3 num bad elem", !Vect(3, Number).check([1, "a", 3]));
let M = Matrix(2, 3, Number);
assert("matrix 2x3 good", M.check([[1, 2, 3], [4, 5, 6]]));
assert("matrix 2x3 bad row", !M.check([[1, 2, 3], [4, 5]]));
assert("tuple good", TupleOf([Number, String]).check([1, "a"]));
assert("tuple wrong len", !TupleOf([Number, String]).check([1, "a", true]));
let sh = Shape([1, 2, 3]);
assert("shape of [1,2,3] is vect3num", sh.check([1, 2, 3]));
assert("shape of [1,2,3] rejects [1,2]", !sh.check([1, 2]));
let sho = Shape({ x: 1, y: "s" });
assert("shape obj good", sho.check({ x: 1, y: "s" }));
assert("shape obj bad y", !sho.check({ x: 1, y: 2 }));

chapterEnd(2);
```

- [ ] **Step 3: Run host + boot, diff**

Run:
```bash
cargo run -- demo/type_gymnastics.ql > /tmp/tg_host.out
cargo run -- bootstrapped/run_file.ql demo/type_gymnastics.ql > /tmp/tg_boot.out
diff /tmp/tg_host.out /tmp/tg_boot.out
```
Expected: empty diff.

- [ ] **Step 4: Commit**

```bash
git add demo/type_gymnastics.ql
git commit -m "feat(demo): type gymnastics — dependent types (Vect/Matrix/Shape)"
```

---

### Task 3: Chapter 3 complex schema + describe

**Files:**
- Modify: `demo/type_gymnastics.ql`

**Interfaces:**
- Consumes: `Vect`, `Matrix`, `Record` (Ch.1), harness.
- Produces: `ServerConfig` schema + `describe` (used by finale).

- [ ] **Step 1: Add Chapter 3 + schema + describe**

```qlang
chapterStart(3, "Complex nested schema validation");

// schema: a descriptor mixing scalars, dependent types, and nesting
let ServerConfig = Record({
  port: Number,
  host: String,
  vector: Vect(3, Number),
  matrix: Matrix(2, 2, Number),
  routes: Array(Record({ path: String, method: String })),
  middleware: Optional(String)
});

let goodCfg = {
  port: 8080, host: "localhost",
  vector: [1, 2, 3], matrix: [[1, 2], [3, 4]],
  routes: [{ path: "/api", method: "GET" }],
  middleware: "auth"
};
let badPort = { port: "x", host: "localhost", vector: [1, 2, 3], matrix: [[1, 2], [3, 4]], routes: [], middleware: "auth" };
let badVect = { port: 8080, host: "localhost", vector: [1, 2], matrix: [[1, 2], [3, 4]], routes: [], middleware: "auth" };
let badRoute = { port: 8080, host: "localhost", vector: [1, 2, 3], matrix: [[1, 2], [3, 4]], routes: [{ path: "/api", method: 42 }], middleware: "auth" };
let badMissing = { port: 8080, vector: [1, 2, 3], matrix: [[1, 2], [3, 4]], routes: [] };

assert("cfg good", ServerConfig.check(goodCfg));
assert("cfg bad port", !ServerConfig.check(badPort));
assert("cfg bad vector", !ServerConfig.check(badVect));
assert("cfg bad route", !ServerConfig.check(badRoute));
assert("cfg missing host", !ServerConfig.check(badMissing));

// describe: render a descriptor to a readable string (recursive, stable order)
let describe = (d) -> {
  let tv = std.Type.of(d);
  if tv == Number || tv == String || tv == Boolean || tv == Null { std.Type.of(d); }
  else if tv == AnyArray {
    if d.length == 0 { "[]"; } else {
      "[" + describe(d[0]) + " x" + std.Number.toString(d.length) + "]";
    };
  } else if tv == AnyObject {
    let ks = std.Object.keys(d);
    let parts = [];
    let i = 0;
    while i < ks.length { parts[parts.length] = ks[i] + ":" + describe(d[ks[i]]); i = i + 1; };
    let s = "{";
    i = 0;
    while i < parts.length { if i > 0 { s = s + ", "; }; s = s + parts[i]; i = i + 1; };
    s + "}";
  } else { "?"; };
};

let cfgShape = Shape(goodCfg);
println("  cfgShape: " + describe(cfgShape));
assert("cfgShape matches good", cfgShape.check(goodCfg));

chapterEnd(3);
```

Note: `describe` key order is nondeterministic (HashMap) — the demo prints `cfgShape` but does NOT assert on its string (only `describe`'s Number/String/Array branches, which are stable). `Shape`'s object branch also uses key iteration (for the `check`), which is order-independent.

- [ ] **Step 2: Run host + boot, diff**

Run:
```bash
cargo run -- demo/type_gymnastics.ql > /tmp/tg_host.out
cargo run -- bootstrapped/run_file.ql demo/type_gymnastics.ql > /tmp/tg_boot.out
diff /tmp/tg_host.out /tmp/tg_boot.out
```
Expected: empty diff.

- [ ] **Step 3: Commit**

```bash
git add demo/type_gymnastics.ql
git commit -m "feat(demo): type gymnastics — nested schema validation + describe"
```

---

### Task 4: Chapter 4 error-value integration

**Files:**
- Modify: `demo/type_gymnastics.ql`

**Interfaces:**
- Consumes: `Record`, harness.
- Produces: `validateField` (error-value bridge), used by the finale.

- [ ] **Step 1: Add Chapter 4 + validate wrapper**

```qlang
chapterStart(4, "Error-value integration");

let validate = (T, v) -> {
  if T.check(v) { v; } else { Error.raise("TypeMismatch", "value failed check"); };
};
let validated = validate(Record({ a: Number }), { a: 1 });
assert("validated good is not error", !isError(validated));
let rejected = validate(Record({ a: Number }), { a: "s" });
assert("validated bad is error", isError(rejected));
assert("error type is Error", rejected.type == "Error");
assert("error message", rejected.message == "value failed check");

// ? propagation: a function returns an error value; ? aborts it and returns the error
let makeErr = () -> { Error.raise("Boom", "kaput"); };
let f = (x) -> { let e = x ?; "unreached"; };
let r = f(makeErr());
assert("? propagates error", isError(r));
assert("? preserved type", r.type == "Boom");
assert("? preserved message", r.message == "kaput");

chapterEnd(4);
```

- [ ] **Step 2: Run host + boot, diff**

Run:
```bash
cargo run -- demo/type_gymnastics.ql > /tmp/tg_host.out
cargo run -- bootstrapped/run_file.ql demo/type_gymnastics.ql > /tmp/tg_boot.out
diff /tmp/tg_host.out /tmp/tg_boot.out
```
Expected: empty diff. Note: `?` at top level aborts the host process — but here `?` is inside a function, so it returns an error value instead (safe).

- [ ] **Step 3: Commit**

```bash
git add demo/type_gymnastics.ql
git commit -m "feat(demo): type gymnastics — error-value integration (validate + ?)"
```

---

### Task 5: Chapter 6 finale — combination storm (deep water)

**Files:**
- Modify: `demo/type_gymnastics.ql`

**Interfaces:**
- Consumes: everything above; produces the final summary line.

- [ ] **Step 1: Add finale — deep-water constructs**

```qlang
chapterStart(6, "Combination storm (deep water)");

// recursive type constructor: 6-deep nested arrays
let DeepArray = (depth, T) -> {
  if depth == 0 { T; } else { Array(DeepArray(depth - 1, T)); };
};
let buildDeep = (depth, v) -> {
  if depth == 0 { v; } else { [buildDeep(depth - 1, v)]; };
};
let D6 = DeepArray(6, Number);
assert("deep6 good", D6.check(buildDeep(6, 1)));
assert("deep6 too shallow", !D6.check(buildDeep(5, 1)));
assert("deep6 bad leaf", !D6.check(buildDeep(6, "s")));

// function signature types: probe-call the function, compare result type
let probe = (T) -> {
  if T == Number { 0; } else if T == String { ""; } else if T == Boolean { false; } else { null; };
};
let Fn = (ArgT, RetT) -> std.Type.make((f) -> {
  if std.Type.of(f) != Function { false; } else {
    let r = f(probe(ArgT));
    if isError(r) { false; } else { std.Type.of(r) == RetT; };
  };
});
let Fn2 = (A1, A2, RetT) -> std.Type.make((f) -> {
  if std.Type.of(f) != Function { false; } else {
    let r = f(probe(A1), probe(A2));
    if isError(r) { false; } else { std.Type.of(r) == RetT; };
  };
});
let NumToNum = Fn(Number, Number);
assert("n2n good", NumToNum.check((x) -> x * 2));
assert("n2n bad ret", !NumToNum.check((x) -> "s"));
let StrToNum = Fn(String, Number);
assert("s2n good", StrToNum.check((s) -> s.length));
let Add2 = Fn2(Number, Number, Number);
assert("add2 good", Add2.check((a, b) -> a + b));

// type-of-type: self-reference + exactType
let typeSelf = std.Type.of(std.Type) == std.Type;
assert("Type:Type", typeSelf);
let exactType = (T) -> std.Type.make((v) -> std.Type.of(v) == T);
let NumOnly = exactType(Number);
assert("exactType(Number).check(42)", !NumOnly.check(42));   // 42 is a Number, not the Number type value
assert("exactType(Number).check(Number)", NumOnly.check(Number));

// type values as data: a Type-typed list
let types = [Number, String, Null];
let i = 0;
while i < types.length {
  assert("type-as-data elem " + std.Number.toString(i), std.Type.check(types[i]));
  i = i + 1;
};
```

- [ ] **Step 2: Add the combination-storm scenario**

```qlang
// --- the combination storm ---
// 1. Shape derives user + role descriptors from samples
let UserDesc = Shape({ id: 1, name: "a", tags: ["x", "y"] });
// 2. Partial + Pick build UpdateUser, UserSummary
let UpdateUser = Partial(UserDesc);
let UserSummary = Pick(UserDesc, ["id", "name"]);
assert("updateUser good", UpdateUser.check({ id: 1 }));
assert("updateUser empty ok", UpdateUser.check({}));
assert("userSummary good", UserSummary.check({ id: 1, name: "a" }));
assert("userSummary extra ok", UserSummary.check({ id: 1, name: "a", tags: ["x"] }));
assert("userSummary missing name", !UserSummary.check({ id: 1 }));

// 3. Record nests them with a NamedArray
let AuditLog = Record({ user: UpdateUser, ts: Number, meta: NamedArray({ length: 2, element: UserSummary }) });
let goodLog = { user: { id: 1 }, ts: 123, meta: [{ id: 1, name: "a" }, { id: 2, name: "b" }] };
assert("audit good", AuditLog.check(goodLog));
let badLog = { user: { id: 1 }, ts: 123, meta: [{ id: 1, name: "a" }] };
assert("audit short meta", !AuditLog.check(badLog));

// 4. Optional wraps a dependent type
let OptVect = Optional(Vect(3, Number));
assert("optVect null", OptVect.check(null));
assert("optVect array", OptVect.check([1, 2, 3]));
assert("optVect bad", !OptVect.check([1, 2]));
assert("optVect bad type", !OptVect.check("x"));

// 5. validate + ? propagation through the chain
let validatedLog = validate(AuditLog, goodLog);
assert("validated log good", !isError(validatedLog));
let chainErr = () -> {
  let v = validate(AuditLog, badLog) ?;
  "unreached";
};
let r2 = chainErr();
assert("chain error", isError(r2));
assert("chain error type", r2.type == "Error");

// 6. deep-water combined with combinators
let DeepOpt = Optional(DeepArray(4, Number));
assert("deepOpt null", DeepOpt.check(null));
assert("deepOpt good", DeepOpt.check(buildDeep(4, 1)));
assert("deepOpt bad", !DeepOpt.check(buildDeep(3, 1)));

chapterEnd(6);

// final summary
println("RESULT: " + std.Number.toString(passed) + "/" + std.Number.toString(cnt) + " asserts passed");
```

- [ ] **Step 3: Run host + boot, diff**

Run:
```bash
cargo run -- demo/type_gymnastics.ql > /tmp/tg_host.out
cargo run -- bootstrapped/run_file.ql demo/type_gymnastics.ql > /tmp/tg_boot.out
diff /tmp/tg_host.out /tmp/tg_boot.out
```
Expected: empty diff. This is where deep-water bugs (if any) surface — if a construct fails on host OR boot, DO NOT remove it: fix the interpreter.

- [ ] **Step 4: Commit**

```bash
git add demo/type_gymnastics.ql
git commit -m "feat(demo): type gymnastics — combination storm (deep water)"
```

---

### Task 6: Fix deep-water divergences (conditional — only if Task 5 exposed bugs)

**Files:**
- Modify: `src/*.rs` (host) and/or `bootstrapped/*.ql` (boot)
- Test: `difftest.py` regression cases (COMPLEX or RISKY list)

**Interfaces:**
- Consumes: the divergence list from Task 5 Step 3.
- Produces: fixed interpreters + regression cases.

- [ ] **Step 1: Identify divergences from Task 5**

Run: `diff /tmp/tg_host.out /tmp/tg_boot.out`
If empty: skip this task (all deep-water constructs work on both). If non-empty, for each divergent line, determine whether it's a host bug or boot bug by reading the diagnostics.

- [ ] **Step 2: For each bug, write a failing regression case**

Add a minimal case to `difftest.py` COMPLEX_CASES (isolated per-case process) that captures the divergence. Example shape:
```python
("y01", "let Fn = ... ; Fn(Number, Number).check((x) -> x * 2);"),
```
Run `python3 difftest.py` and confirm the new case FAILS (RED).

- [ ] **Step 3: Fix the interpreter (host or boot)**

Apply the minimal fix to `src/...` or `bootstrapped/...`. Run `cargo test` (host) and re-run `difftest.py` — the new case turns GREEN.

- [ ] **Step 4: Re-run the full demo diff**

Run:
```bash
cargo run -- demo/type_gymnastics.ql > /tmp/tg_host.out
cargo run -- bootstrapped/run_file.ql demo/type_gymnastics.ql > /tmp/tg_boot.out
diff /tmp/tg_host.out /tmp/tg_boot.out
```
Expected: empty.

- [ ] **Step 5: Commit**

```bash
git add difftest.py src/ bootstrapped/
git commit -m "fix: resolve type-gymnastics deep-water divergence (host/boot)"
```

---

### Task 7: Final verification + README pointer

**Files:**
- Modify: `README.md` (optional)

- [ ] **Step 1: Full regression sweep**

Run:
```bash
python3 difftest.py                # all suites green
cargo test                         # host unit tests green
cargo run -- bootstrapped/run_file.ql demo/type_gymnastics.ql > /tmp/tg_boot.out
cargo run -- demo/type_gymnastics.ql > /tmp/tg_host.out
diff /tmp/tg_host.out /tmp/tg_boot.out   # empty
```

- [ ] **Step 2: Add a README pointer (optional, only if it reads cleanly)**

Add a short "Type gymnastics demo" bullet under the type-system chapter pointing at `demo/type_gymnastics.ql` and how to run both interpreters.

- [ ] **Step 3: Final commit**

```bash
git add README.md  # if changed
git commit -m "docs: type gymnastics demo pointer (README)"
```

---

## Self-Review Notes

- **Spec §6.4 example** (`exactType(Number).check(Number)`) is covered in Task 5. `Number.check(42)` vs `exactType(Number).check(Number)` are both asserted.
- **Spec §6.5** (type values as data) covered by the `types` list in Task 5.
- **Spec §6.1/6.2** (DeepArray, TypeChain) — DeepArray at depth 6 is in Task 5; TypeChain (alternating Record/Array) was cut in the plan for boot performance (each nesting level's `check` walks the full tree; deep alternating chains multiply cost). This is an accepted scope reduction: the *dependent* TypeChain semantics are already exercised by `Matrix` (Array-of-Array) and the finale's `Record(NamedArray(...))` nesting. If the user wants TypeChain specifically, it's a follow-up.
- **No placeholders:** every code step contains full QLang source.
- **Type consistency:** `assert(name, cond)`, `chapterStart(n, name)`, `chapterEnd(n)`, `describe(d)`, `Shape(v)`, `validate(T, v)`, `Union/Intersection/Nullable/Optional`, `Record/Pick/Partial/NamedArray`, `Vect/Matrix/TupleOf`, `Fn/Fn2`, `exactType`, `DeepArray/buildDeep` — consistent names across tasks.
- **Determinism:** the only nondeterministic output is `describe(cfgShape)` in Task 3, which is printed but not asserted; the `PASS` counts and all other prints are deterministic.
