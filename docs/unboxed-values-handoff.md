# Handoff — Unboxed values / compile-time reduction of emitted IR

Status: work in progress, branch `unboxed-values`. Not merged. `dancing-with-dragon` untouched.
Audience: whoever picks this up next (human or agent) — written to be read cold, by someone
who has never seen this repo. Everything needed to resume is in here; nothing is assumed.

> **Copy-paste prompt for a fresh session**
>
> "Read `docs/unboxed-values-handoff.md` in full, especially §11 (plan and decision log).
> Then: run the two verification suites for the uncommitted `aot/types.ql` change if they are
> not green yet, commit it if they are, and continue from §5 ① (per-program probe breakdown)
> and §5 ② (read-side Error-test elision). Report hit counts before IR line counts. Do not
> merge into `dancing-with-dragon` without asking."

---

## 0. What QLang is, and what this work is

QLang is a small dynamically-typed language with its own toolchain in this repo. The pipeline is:

    lexer -> parser -> compile-time analysis -> code generation

The current effort is a native (LLVM IR) AOT compiler written **in QLang itself**, which is
self-hosted: `stage1 --emit-llvm aot/qlangc.ql aot/runtime.ql` -> link -> `stage2`, i.e. the
compiler compiling itself (see §3). The build/test loop is expected to go through that
self-hosted native path rather than the older Rust host interpreter — the native path is
~20x faster and exercises the shipping path.

The theme of the current work, in the user's words:

> "Compile-time provides enough information that code generation can emit fewer instructions."

Concretely: the analysis layer derives, for each node, its **type** and its **natural
representation** (raw `double` / raw `i1` / boxed `%ql_value`); the generator is a pure
consumer that reads those facts and emits the direct path. Every IR line saved comes from one
of two families:

- **(a) "the static type is known, therefore this check / this slot / this error test is
  dead"** — delete the check and its cold path. Historically the *bigger* win by far.
- **(b) "the static representation is raw, therefore the box/unbox round-trips are
  unnecessary"** — unboxing proper.

Family (a) is the main line of work. Family (b) — the thing this branch is named after — is a
secondary layer that only pays off once the types are complete, and is currently expected to
be worth a few thousand IR lines, not tens of thousands (§7).

### 0.1 Roadmap

Status per phase. "IR" always means `wc -l` of `/tmp/t20.ql`'s emitted IR on the accepted
seed; the accepted baseline is **215 919** and the **current total is 194 812 ⇒ −21 107 lines
(−9.8 %)**. (The pre-branch work already on `main` — phase A — accounts for roughly another
−6 900, so the "compile-time information ⇒ fewer instructions" line as a whole is ≈ −28 k.)

| Phase | Goal | Deliverable / evidence | Status |
|---|---|---|---|
| **A. Infrastructure** (pre-existing, on main) | The analysis exists at all, and the generator consumes only its outputs | self-hosted native compiler; per-binding type slot / check omission **−5830 IR lines**; numeric specialization; parameter and return annotations; stdlib annotations + bundle regeneration **−1086** | done |
| **B. Make the type information complete** *(this branch)* | Give the analysis everything it needs to say "known" with confidence, so family (a) fires everywhere and family (b) has fuel | B1 runtime program analyzed ✓ **−11 492**; B2 `.length -> Number` ✓ `a3a4120` **−593**; B3 per-program probe ✓ `464f72c`; B4 error-test elision ✓ `9cceff7` **−1 929** (see §5②); B5 return-type signatures ✓ `47a4e97`; B6 general module resolution ✓ `0b8e239`; B7 declare the runtime signatures ✓ `d5cc108` **−151**; **B8 analysis completeness** ✓ `4c9f0e2` **−3 150** + `047f390` **−1 274** (see §5⑧); **B9 bind-level keying** ✓ `6b3a4cf` **−1 258** (§5⑨); `74019f4` family-aware consistency + a compile-time diagnostic for `: Array`/`: Object` (constructors are not types) — IR ±0; `69d36a8` scalar std annotations **−1** | **in progress — only §5⑥ (annotate std) is left** |
| **C. Consumer pass — unboxing** | `emitValue` reads `staticRep` and emits the raw or boxed direct path; `boxIfNeeded` at use sites; the speculative machinery is deleted | **C1 landed `2f847f6`**: computed `BinaryOp`/`UnaryOp` nodes keep a raw `double`/`i1`, boxed only at use sites, `if`/`while` conditions `br i1` directly, raw slot writes touch only the payload (tag stays `NUMBER`, so frame/ABI unchanged) — **−871**; `aceb23a` div/mod fast path **−543**. Raw reads of `unboxType` slots measured as a *loss* (boxed read is 1 line); raw parameters/returns are **measured and deferred** (§5⑪: ②b ≈ 170–251 sites, ②c 0 today because no parameter annotation is effective — it needs §5⑥) | **in progress (C1 done, rest measured & deferred)** |
| **D. Widen the unboxing domain** | Extend raw representation to more shapes, only where static evidence exists | raw Boolean slots (`i1` fits in a byte); module-root bindings once the extension-bridge `memcpy` frame ABI problem is solved; array/object payload representations. **Not needed for the annotated-family work**: per §5⑨/`docs/object-array-type-names.md`, anything that is not a *designated* type stays boxed | not started |
| **E. Keep hunting family (a)** | The check / slot / error-test levers keep proving bigger than unboxing; keep looking for "information ⇒ dead code" | B4 landed (`9cceff7`); the same `cannotBeError` predicate now applies to `emitPropagateError` (`?` / aggregate assignment) and to error tests reachable only through provably-checked call sites (§6). **Counted but not yet taken (§5⑩):** the div/mod-by-a-non-zero-literal cold path, one-side-known dispatch, and `ql_truthy` on a known Boolean | continuous |

The ordering rule that drives all of this: **family (a) is representation-agnostic** — eliding
an Error test helps a boxed slot exactly as much as a raw one — and it is measurably bigger
(§7). So phase B precedes C, and within B, the runtime analysis (B1) had to come first because
until it landed, *none* of the family (a) levers had ever fired on the runtime's own 1900
lines.

---

## 0.2 Where things stand right now (read this first)

| Item | State |
|---|---|
| Branch | `unboxed-values` (working tree = `/root/projects/QLang`) |
| Last commit | `d24a9ac` — docs: ⑫ recorded as attempted/landed/reverted |
| IR total | **215 919 → 194 812 = −21 107 lines (−9.8 %)** on `/tmp/t20.ql` (program output still `20`); phase A on `main` adds ≈ −6 900, so the whole line is ≈ −28 k. Per-step numbers are in the block below |
| Landed since this doc was written | `a3a4120` `.length -> Number` (−593); `464f72c` per-program probe (B3/①); `9cceff7` error-test elision (B4/②, −1 929); `47a4e97` return-type signatures; `0b8e239` general module resolution; `d5cc108` declared runtime signatures (−151); `4c9f0e2` call callee+arguments (−3 150); `047f390` literals/aggregates/index/if (−1 274); `2f847f6` consumer pass C1 (−871); `aceb23a` div/mod fast path (−543); `6b3a4cf` bind-level keying (⑨, −1 258); `69d36a8` scalar std annotations (−1); `74019f4` family-aware consistency + constructor diagnostic (IR ±0) |
| Verification | both suites green on `/tmp/nk`: interpreter `ALL CHECKS PASS` (56 PASS), selfhost `ALL REQUESTED CHECKS PASS` (47 PASS) |
| Backup branch | `backup/nan-removal-stage1` (→ `35257b3`) — the NaN/∞ removal attempt (`4903d57` stage 1 + `35257b3` literal diagnostic); see §5⑫, the decision was reversed |
| Next (see §5) | **⑥ annotate std** (mandatory per the author; rules measured: return annotations free, parameter annotations only where the argument type is proven, object/array returns deferred — see §5⑥a); **⑩** count the three family (a) candidates; **⑪** raw ABI (②b/②c) |
| Untracked noise | `_b.ql`, `.commandcode/`, `docs/compiler-next-steps.zh.md` |
| Merge policy | **Do not merge into `dancing-with-dragon` without explicit approval from the user.** |

IR line metric on the accepted fixture, all points measured on the same seed:

```
/tmp/t20.ql    pre-runtime-analysis (n0/n3/n6)   215 919
               runtime analyzed (n7, commit 7a55cac)   204 427   (-11 492, -5.3%)
               + .length -> Number (n8 = a3a4120)      203 834   (-593)
               + per-program probe (464f72c)           203 838   (+4 comment lines; IR otherwise byte-identical)
               + located-error elision (9cceff7)        201 909   (-1 929, hits 155)
               + return-type signatures (47a4e97)       201 909   (no annotations in the corpus → byte-identical)
               + general module resolution (0b8e239)    201 910   (+1 probe comment; the channel itself is IR-neutral)
               + declared runtime signatures (d5cc108)  201 758   (-151; probe: ns-resolve resolved 5 / unresolved 23)
               + call callee + arguments inferred (4c9f0e2) 198 759   (-3 150!)
               + literals/aggregates/index/if (047f390) 197 485   (-1 274; ns-resolve resolved 8 / unresolved 30)
               + consumer pass C1 (2f847f6)             196 614   (-871; computed nodes keep their raw rep)
               + div/mod fast path (aceb23a)            196 071   (-543; both sides statically Number)
                + bind-level keying (6b3a4cf)            194 813   (-1 258; std annotations start to bite)
                + scalar std annotations (69d36a8)       194 812   (-1)
                + family rules + constructor diagnostic (74019f4) 194 812   (±0)
                (the NaN/∞ removal 4903d57/35257b3 measured 194 636, then was reverted — §5⑫)
program output unchanged throughout: 20
```

Everything else after this point is the map.

---

## 1. The goal, in the user's words

> "Compile-time provides enough information that code generation can emit fewer instructions."

The user's architecture (authoritative — this is not a suggestion, and a generator-side
workaround was explicitly rejected once already):

1. **The analysis layer computes types and representations.** The generator is only a
   *consumer*: it reads annotations and emits the direct path. It must not guess, and it must
   not "try then fall back".
2. **Representation belongs to the value; boxing belongs to the use site.** A value has one
   natural representation — raw `double`, raw `i1`, or boxed `%ql_value`. If a use site needs
   a box, boxing happens **at that use site only**. Never downgrade a value globally because
   one consumer wants a box.
3. **Raw values may cross boundaries.** Calls, returns and writes are *use sites*. If the
   callee signature / target slot is statically known and accepts a raw value, pass it raw;
   if unknown, box at that one site.
4. **One emission path per node**, chosen by a compile-time fact stamped on the node. No
   trial emission, no operand reuse, no speculative fallback (that machinery is to be
   deleted — see step ⑦).

A note from the user that matters for interpretation: he calls the type annotation on a
binding **"类型信息" / "type information"**, not "annotation". Use his vocabulary in
conversation.

---

## 2. Instrumentation and measuring conventions

**The probe.** `qlangc.ql` emits IR comment lines prefixed `; typeRep ...` / `; unboxable ...`
that report live counters. They are comments, so they cost no instructions, but they *do*
count in `wc -l` (keep that in mind when comparing IR sizes; all numbers in this doc include
them).

Current shape of the probe lines (around `qlangc.ql:1837`):

```
; typeRep raw: lit=... read=... arith=... cmp=... not=...
; typeRep boxed reads: num=... str=... unk=...
; typeRep boxed binops: num=... cmp=... str=... unk=...
; typeRep unknown: binds=... params=...
; typeRep unknown binds[lib]: <names...>          (capped at 40)
; typeRep unknown params[lib]: <names...>         (capped at 40)
; typeRep runtime: analysisErrors=...
```

Counter keys are `NodeKind / staticType / representation`. So `Identifier//boxed` is "a read
whose static type could not be determined". The `unknown binds[lib]` / `unknown params[lib]`
lines are the actual **worklist** for "make the types complete".

**Numbers, two eras — do not compare across the boundary.** Before `7a55cac` the runtime
program was *not* analyzed, so it contributed no nodes to the counters. From `7a55cac` on it
does, and it is a large low-level program, so the totals jump:

| counter | pre-runtime (library+entry only) | post-runtime (includes runtime program) |
|---|---|---|
| raw lit / read / arith / cmp | 425 / 77 / 30 / 24 | 1107 / 419 / 103 / 201 |
| boxed reads num / str / unk | 198 / 34 / 329 | 276 / 56 / 701 |
| boxed binops num / cmp / str / unk | 111 / 292 / 32 / 128 | 157 / 722 / 66 / 232 |

Consequence: **the probe needs a per-program breakdown** (library / entry / each module /
runtime on its own line), otherwise the runtime's ~700 unknown reads drown the numbers that
actually matter for unboxing — the library and entry code. That is step ① below.

**Line-count metric caveat.** Any change that alters register numbering shifts the *whole*
IR, so `diff` line counts are useless (one such diff read 385 360 lines for an 11 492-line
reduction). To characterise a change, compare **opcode histograms** instead:

```bash
python3 - <<'PY'
import re, collections
def hist(p):
    c = collections.Counter()
    for l in open(p):
        s = l.strip()
        if not s or s.startswith(';') or s.endswith(':'): continue
        m = re.match(r'%[\w.]+ = (\w+)', s)
        if m: c[m.group(1)] += 1; continue
        m = re.match(r'(\w+)', s)
        if m: c['(top) '+m.group(1)] += 1
    return c
a, b = hist('OLD.ll'), hist('NEW.ll')
for k in sorted(set(a)|set(b)):
    if b[k]-a[k]: print(f"{k:26s} {a[k]:8d} -> {b[k]:8d}  {b[k]-a[k]:+d}")
PY
```

**Reporting order (user requirement): report the number of affected sites (hits) first, then
IR lines.**

---

## 3. Build / measure / verify recipes

Seed compiler (there is an existing one; if it is gone, build/link one first):

```bash
SEED=/tmp/gE
R=aot/runtime.ql

# 1. rebuild the compiler under test
$SEED --emit-llvm aot/qlangc.ql $R > /tmp/nN.ll 2>/tmp/nN.err
python3 aot/native_link.py /tmp/nN.ll -o /tmp/nN

# 2. emit IR for the fixture
/tmp/nN --emit-llvm /tmp/t20.ql $R > /tmp/ir20_nN.ll
wc -l < /tmp/ir20_nN.ll            # compare against 203 834 / 204 427 / 215 919
grep '; typeRep' /tmp/ir20_nN.ll   # hit counts

# 3. run the fixture
python3 aot/native_link.py /tmp/ir20_nN.ll -o /tmp/run20_nN && /tmp/run20_nN

# 4. regenerate the stdlib bundle after ANY stdlib/*.ql edit
./target/release/qlang stdlib/build_bundle.ql > stdlib/bundle.ql
#    (--check validates freshness; see stdlib/README.md)
```

Gate suites (both must pass; the gate takes ~40 min, the interpreter suite a few minutes):

```bash
python3 aot/run_interpreter_tests.py --compiler /tmp/nN     # "ALL CHECKS PASS"
python3 aot/run_selfhost_tests.py --compiler /tmp/nN        # "ALL REQUESTED CHECKS PASS"
```

**Do not pipe these through `| tail`.** A `| tail -30` pipeline buffers everything, so the
log stays empty for the entire 40 minutes and you cannot tell progress from a hang. Run them
plain (the harness captures output) and read the log file.

Expected-output gates that must not move: 20 / 20 / 21 / 4 (the standard trio) and
`t20_native_bridge` = 42 / 2.

---

## 4. What has already landed on this branch

Commits (oldest → newest): `6679839`, `348b028`, `8f98254`, `cb53a6b`, `6f935c3`, `86ff81b`,
`c0b6548`/`d28af6e`, `4dec1d5`, `df65de1`, `7a55cac`.

**Landed, IR-neutral (information only):**

- `emitExpr -> {reg, raw}` contract in the generator (`8f98254`). IR byte-identical. Its
  meaning is narrow and must stay narrow: *what is this value's natural representation* —
  there is no `want` parameter and consumers do not get to inspect it.
- `staticRep` computed bottom-up in the analysis, plus scope-carried representation tables
  (`typeRepScopes`) and per-program layered counters. IR-neutral.
- Measurement sets that justify the ordering (all pre-runtime-era, library+entry only):
  unboxable bindings **11 → 76**; raw reads 56 → 77; raw comparisons 9 → 24; raw arithmetic
  45 → 30; boxed reads 654 → 633; boxed binops 563 → 563.

**Landed, changes codegen:**

- `7a55cac` — **the runtime program is now run through `inferTypes`.** The runtime source was
  previously *parsed* (so the compiler knows which names are runtime functions) but never
  *analyzed*, so every "static type is known ⇒ this check is dead code" lever had never fired
  on it. Effect: `215 919 -> 204 427` IR lines, program output unchanged, and the runtime's
  own analysis reports **0 static errors**.

  What disappeared, by opcode (measured with the histogram script): `and`,
  `extractvalue`, `inttoptr`, `phi` each **−392**; `icmp` **−784** (=2×392); `br` and `call`
  each **−1176** (=3×392); `getelementptr` −2154; `load` −1777; `store` −887; `alloca` −17.
  That signature is a single pattern repeated 392 times: a *type / is-this-an-Error?* test
  together with its cold path (3 branches + 3 calls to error construction), plus the slot
  reads/writes and box addressing that fed it. ≈29 IR lines per elided block.

  **Only runtime code is affected** — the same checks in library and user code were already
  handled by the existing rules.

  Diagnostics safety: the runtime's own type errors are subtracted from the user-facing
  diagnostic list (`base = typeErrors.length; inferTypes(...); <record delta>; <remove
  delta>`), and the delta is reported in the probe instead of being dropped silently. Today
  the delta is 0, so this is a guard, not a cover-up. The reasoning, which the user accepted:
  internal code *should* eventually pass the analysis cleanly — that is its own follow-up task
  with its own gate — but the runtime's analysis errors must not fail a *user's* compilation
  today, because the analysis does not understand the host primitives and the runtime
  manipulates raw representations, so those reports are mostly false positives.

**Uncommitted (verify first):**

- `aot/types.ql`: receiver statically typed `Array` or `String` ⇒ `length` is `Number`.
  Rationale: it is a *total* member — it returns a length number for any input and never
  returns an Error — so the declaration is sound without any call-site obligation (same
  character as the `check` predicates). `Object.length` is deliberately **not** declared,
  because there it can be a user field holding anything. Measured: `204 427 -> 203 834`, i.e.
  **−593**, output still 20.

---

## 5. The ordered worklist

Each step: make the change → report hit counts → report IR lines → run both suites → commit
only when green. Do not bundle steps.

### ① Per-program probe breakdown — *done* (`464f72c`)

Each program now gets its own probe line: 1 = library, 2 = entry, the middle ones the imported
modules by path, the last = runtime. On `/tmp/t20.ql` the library is *p1* (`boxed reads num=158
str=34 unk=329`; `boxed binops num=73 cmp=292 str=32 unk=126`) and the runtime's ~700 unknown
reads stay on *p4*, so the fuel that matters is visible. IR +4 comment lines; ignoring `;` lines
the IR is byte-identical. Validated on `t35_scoped_modules` (8 programs). Mechanical, IR-neutral
apart from the comment lines and the one `; located-error elided:` line at the end.

### ② Error-test elision — *done* (`9cceff7`), but not where this section first said

Two measured facts rewrite the step:

1. **The read path was already unchecked before this branch.** `0d02ef0` ("stop checking plain
   reads") removed `Identifier` from `emitLocatedError`'s kind list, and it is an ancestor of
   this branch (shared with `dancing-with-dragon`). Measured now: one read costs **2 IR lines**
   and emits **no** Error test (bare `x;` = 2). The old estimate here ("≈7 lines per read",
   309 typed reads) was a pre-`0d02ef0` reading — the literal read-side hit count is **0**.
2. **The same lever survives on the operator sites.** `emitLocatedError` wraps every
   `BinaryOp`/`UnaryOp`/`Call`/`MemberAccess`/`IndexAccess` result; those blocks are dead when
   the result provably cannot be an Error.

What landed: a per-program, per-binding **fixpoint over the write set** (`typeProneOf` /
`typeBindingProne` / `typeSolveWrites` in `aot/types.ql`). A binding is *safe* iff its type is a
builtin scalar **and** every write to it cannot produce an Error; a `BinaryOp` is safe iff the
operator itself cannot error at the known operand types (`typeOpCreatesError`) and both operands
are safe. `/`, `%`, `&&`, `||`, mixed-type `+`, unary `-`/`+` on a non-Number, calls, member and
index access, and anything unproven stay unsafe. Soundness is structural, not a claim about
static types: `1 / z` and `__op_eq(e, 1)` (zone error on an Error operand) both carry a scalar
static type yet produce Errors.

Result: **155 sites** elided on `/tmp/t20.ql`, IR 203 838 → 201 909 (**−1 929**), output 20,
compile 18 s → 12 s. Both suites green.

**Trap paid for here — do not repeat.** The binding graph must live in a compiler-internal table
keyed by a **numeric id stored on the node**; never as node references. `reserveModuleBindings`,
`loadModuleNode` and `collectModuleExports` walk *every property of every AST node*
(`std.Object.keys(node)`), so a node-valued property (`node.bindingRef`, `node.bindWrites`)
builds a cycle and the walk never terminates (18 s → >240 s, nothing emitted).

Next user of the same predicate: `emitPropagateError` (the `?` operator and the aggregate
assignment paths) is the same tag==8 block.

### ③ Return-type signatures — *done* (`47a4e97`); the old ③/④/⑤ are superseded

**The old ③/④ assumed the runtime members' signatures could be *derived*.** They cannot: their tails
hang on host/representation primitives — `__number_bits = (…) -> ql_number_bits(…)` (`runtime.ql:1637`),
`Number.toString`'s tail is `__str_new(...)`, `Object.keys`' tail is `res = allocBox(...)`,
`String.codePointAt`'s inner tail is `cp ← ql_mem_get`. Removing the internal `__err` (the old ④) is
necessary but *not* sufficient: it buys exactly one member (`Number.frexp`, whose tail is an Array
literal via `__math_parts`).

So the fix is a **language feature: function return-type signatures**, `(params): T -> body`
(`47a4e97`). The author declares the type; both engines enforce it — compile error where provable,
runtime check at the return edges otherwise (`?` propagation exempt) — and the compiler only consumes
it:

- `parser.ql`: after a parenthesized parameter list, before `->`; a bare `x -> …` cannot carry one, so
  `x: T -> …` stays unambiguous with a parameter annotation; `suppressArrowLambda` stops the trailing
  `->` from being read as a lambda body.
- `ast.ql`: `FunctionExpr(params, body, returnTypeAnnotation)`.
- `types.ql`: the declaration is authoritative (`declaredReturnType`); a provable mismatch on *every*
  path is a compile error (the derived intersection must be non-empty, so unreachable returns cannot
  trip it); `derivedReturnType` drives the generator's skip.
- `qlangc.ql` / `interpreter.ql`: the runtime check, uniform with parameter annotations (*any*
  annotation is enforced, not only builtin scalars); if the whole function provably returns the
  declared builtin, no check is emitted at all.

IR-neutral on the existing corpus (no annotations yet): `/tmp/t20.ql` byte-identical, 201909.
Fixture `t55_return_types` (10 checks, both engines).

**Landed as `0b8e239` + `d5cc108`** (plan `~/.commandcode/plans/unboxed-03-04-std-member-index.zh.md`):

1. **The channel — general module resolution (`0b8e239`).** The index was dormant for *two* reasons,
   and the second was a real bug: `stdScanExports` needed a shape the bundle does not produce, **and**
   `inferExpr`'s `Call` branch never inferred its callee (it only read `callee.memberReturn`), so a
   `std.<X>.<m>(…)` callee was never analysed at all. Both fixed: the `Call` branch now does
   `inferExpr(node.callee)`; export tables are taken at face value (an Object literal that is a
   function body's **tail statement**, or `let std = {…}`), the field name is the module name whatever
   the value's kind, a name may bind several values (library + runtime union), the runtime is analysed
   first, and `std.<X>` is typed by the exported value — never a forced `"Object"`. Members resolve
   only where the value is statically visible (factory-built `ObjectLibrary`/`JSONLibrary` stay
   unknown: a knowability limit, not a privilege). Probe `; ns-resolve: resolved=5 unresolved=23`
   (28 sites reached). IR-neutral (201 910).
2. **The signatures — declared runtime return types (`d5cc108`).** `__obj_keys: Array`,
   `__num_frexp: Array`, `__itoa: String`, `__number_bits: Number`, `__s_codepoint`'s inner `: Number`
   (which also types `__math_scale` and `Number.ldexp`). **Form measured, not assumed:** the ④ form
   (parameter annotations + dropping the internal `__err`) moves the failure to a call-site `TypeCheck`
   (fixtures change) *and* pays a call-site check — only **−58**. Return annotations only, internal
   `__err` kept, gives **−151** with no semantic change: the declared type is honest for legal inputs
   and illegal ones are still caught internally. So "signatures derivable from source" is no longer
   required — declaring suffices, and keeping the internal check is cheaper and safer. Runtime code
   defines the type singletons (`let Number = {check: …}`), so `typeDefinesBuiltins` lets annotations
   through there; user code that shadows a builtin name still resolves to unknown.

Still open (measured): unresolved = 23 — dominated by `std.Error.raise` (never a scalar type),
`fromCodePoint` / `Math.max/min/random` / `fs.*` (genuine value-dependent errors), and the
factory-built modules. `typeRuntimePredicates` also survives: `Number.check` needs it until the type
singletons themselves resolve through the index (they are object literals in the runtime, so the
general rule can eventually cover them).

### ⑥ Chain-annotate the stdlib — **mandatory, per the user's directive**

**User decision (this session):** `std` must carry author-declared type information — parameter *and*
return annotations — **even where it shows no IR gain**. It is the language-declared interface, not an
optimization switch. The single exception: an annotation that is **net-negative** is reported and
skipped, not kept.

Scale: `stdlib/*.ql` = 62 functions, `aot/runtime.ql` = 132 functions. Do it in batches, report the IR
delta per batch, and keep both gates green.

**Prerequisite: ⑨ must land first** — today every annotation added here is inert.

### ⑥a First batch result (measured): returns are free, params are not — and a blocker

Measured per batch (regenerate the bundle, rebuild the compiler, count `/tmp/t20.ql`):

| variant | t20 IR | |
|---|---|---|
| baseline | 194 813 | |
| 6 return annotations + 9 param annotations (`string.ql`) | 195 923 | **+1 110** ✗ |
| the 6 return annotations alone | 194 813 | ±0 ✓ |
| `finite(n: Number)` alone | 194 812 | −1 ✓ |

- **Return annotations are free** (the return-edge check is proven dead once the derived type
  matches) ⇒ annotate returns freely.
- **A parameter annotation costs an inline check at every call site** (~18 lines per
  parameter×callsite) **unless the argument's static type is already proven** — `finite(n: Number)`
  is free because both call sites pass known Numbers; `casing(s: String)`/`matches(s: String…)`/
  `has(c: String)` are not, because their arguments come from `s[i]` (index results stay
  conservative). So: annotate a parameter only where the call sites' argument types are proven
  (the `numargs=315` criterion); treat the rest as net-negative and skip, per the rule.

**Blocker — diagnosed, and it was NOT an interpreter bug.** The 6 return annotations in `string.ql`
made `t19_literals` print `false`×16 under the interpreter while the compiled binary printed `true`×16.
Root cause, confirmed by a minimal repro run through *both* engines:

```
let o = {}; o["a"] = true;
println(Object.check(o));      // ?Error  <-- in BOTH engines
println(AnyObject.check(o));   // true
```

So `Object.check` (the runtime type singleton) **rejects a plain object**; the "any object" type is
`AnyObject`. The compiler only *looked* fine because it elides the return-edge check when the declared
type equals the derived type (`proven`), whereas the interpreter — which has no analysis — always runs
the check. Hence the asymmetry.

Consequence for the campaign:

- **Scalars are safe and consistent** (`Number`/`Boolean`/`String`) — annotate those (done: `finite`,
  `has`, `casing`, `matches` + `finite(n: Number)`, IR −1, both engines verified on `t19_literals` and
  `t55_return_types`).
- **Object/array returns are blocked on a naming/semantics question**: the analysis *derives* `Object`
  for an object literal, but `Object` is a **constructor** (`__obj_ctor`, used to derive
  `Object(schema)`/`Object(pred)`), not a type value — `AnyObject`/`AnyArray` are the *concrete* types
  (`{check: __pred_object}`/`{check: __pred_array}`), on the same footing as `Number`. So the literal's
  derived name should be `AnyObject`/`AnyArray`, the family rules (`.length`) must key on the family
  rather than on a name, and the declared-vs-derived mismatch check must not fire *inside* the family
  (two `AnyObject`s are not interchangeable — only family membership is statically knowable).
  **See `docs/object-array-type-names.md` (+ `.zh.md`) for the full note**; implement that before
  adding object/array annotations.

  **Update — the note's rules 2/4/5/6 have landed (`74019f4`, IR ±0, both gates green):** family-aware
  consistency (a mismatch *inside* the family is no longer reported), a compile-error diagnostic for
  a bare-constructor annotation (`: Array`/`: Object` — "use `AnyArray` … or a constructed form"),
  `: AnyArray` on the runtime's four array-returning functions, and a family label for
  `.length -> Number`. **Deliberately NOT done:** the `proven` family extension that would make
  object/array return annotations free — the author is not yet sure that equating the base names
  (`Object`/`Array`) with the widest concrete types (`AnyObject`/`AnyArray`) is safe as the type system
  grows ("以后加功能会不会出事"). Consequence: object/array return annotations cost **+164** today ⇒
  net-negative ⇒ **deferred**; the std campaign continues with **scalars only** (free, verified).

Original plan's rules, kept:

`stdlib/string.ql` (29/29 functions unannotated), `array.ql` (24/24), `json.ql` (15/15),
`object.ql` (11/11), `math.ql` (17 of 29), `decimal.ql` (8/8), `number.ql` (4/4),
`result.ql` (2/2 — genuinely unannotatable, `T` is a type parameter).

Rules learned the hard way:

- **Annotate leaf-up (chains), never single points.** A single-point annotation is a net
  *loss*: the gain only appears when the return type is inferred and the caller can consume
  it. `decimalDigit(c: String)` was +135 IR lines and was reverted.
- **Never annotate a parameter that intentionally accepts arbitrary values**:
  `String.check`/`Number.check` guards, `parseFloat`/`isNaN`/`isFinite`, `result.ql`'s `T`.
- `decimal.ql` is already a working chain: `decimalBig -> Array`,
  `decimalCompare`/`decimalCompose -> Number`, `decimalNumber -> Number`.
- After every stdlib edit, **regenerate `stdlib/bundle.ql`**, or nothing you changed is in
  effect. (This has been forgotten once.)
- An index result must stay conservative: `del[k]` for a missing key yields an Error at
  runtime, so it cannot be claimed as `Number`. Only literal-key lookups into literal
  objects/arrays may be typed.
- Module-root bindings stay unboxed-excluded because of the extension bridge's `memcpy`
  frame ABI.

### ⑦ The unified consumer-side change (unboxing proper)

Only after the types are complete. One pass, no speculation:

- `emitValue(node)` reads `staticRep` and emits the raw / boxed direct path;
- use sites that need `%ql_value` call `boxIfNeeded(value)` — boxing at that site only;
- **delete the speculative machinery**: `emitMayBeRaw` (renamed `emitCouldBeRaw` at some
  point), `emitRawCmp`, the trial-emission block, and the fallback branch.

Then: both suites green → **stop and ask before merging.**

---

### ⑧ Analysis completeness — *done* (`4c9f0e2` + `047f390`), the biggest remaining lever

Chasing why `std.<X>.<m>` never resolved turned up a family of gaps: **the analysis traverses only
part of the AST**, so whole sub-expressions are never stamped and the generator can only fall back to
the generic path.

- `Call` never inferred its **callee** (`0b8e239`) nor its **arguments** (`4c9f0e2`). So everything
  nested inside a call — `println(std.String.toString(x))`, `f(g(x) + 1)` — was invisible. −3 150.
- **Literals and aggregates did not recurse** (`047f390`): string interpolation parts, object-literal
  field values, array-literal elements, `IndexAccess`'s object/index, and expression-position `if`
  bodies. −1 274.
- Together with the return-type signatures and the module index, the compiler's own source now shows
  `ns-resolve: resolved=109 unresolved=44`, and the unresolved 44 are **untypeable by design**:
  `Error.raise` (42 — always an Error, never a scalar), `String.fromCodePoint` (14 — genuine
  `RangeError`), `String.codePointAt` (4 — a curried native whose outer application yields a
  function). So B8 ("chain-annotate the stdlib") needed no bulk annotation pass: the traversal fixes
  delivered it.

Lesson for the next lever: when a "known type" lever under-delivers, check whether the analysis ever
*reaches* the node before adding another rule.

### ⑨ Bind-level keying for the unbox decisions — *done* (`6b3a4cf`, −1 258)

**The blocker this fixes: today `std`'s existing annotations have zero effect.** Both unbox decisions
are keyed by *name within a program*, not by binding:

- parameters — `aot/types.ql:408`: `isError(typeAssignedNames[typeProgram][param.name])`
- `let` bindings — `aot/types.ql:708`: `isError(typeUnknownWrites[typeProgram][s.name])`

So a single assignment (or one unknown-typed write) to *any* same-named binding anywhere in the same
program disables unboxing for all of them. Measured: `stdlib/math.ql` annotates
`(a: Number) (b: Number) (n: Number)`, while stdlib assigns `a` 9×, `n` 2×, `b` 1× ⇒ the probe reports
`anyparam=0 rawparams=0` over 1300 analysed functions.

The bind-level machinery already exists (`s.bindId`, `typeBindTable[program][bindId] =
{ base, prone, busy, done, writes: [...] }`, two passes via `typeCollectWrites`) — the fix is to decide
from each binding's own collected writes.

Direct IR effect is **small** (the only visible change is fewer lines on unboxed `let` stores, because
C1 deliberately keeps *reads* boxed). The point is the information itself — per the user's rule, and it
is the prerequisite for ②c.

### ⑩ family (a): count first, then elide

The biggest levers have been "information ⇒ dead code". Three candidates to **count first** (IR-neutral
counters, exactly like the ②a probe), then implement only the ones with large hit counts:

1. **Div/mod by a statically non-zero literal** ⇒ the `fcmp oeq %f2, 0.0` test, its branch and the
   `__op_div0` cold path are all dead. The corpus is full of `% 2` (hashing, UTF-8, string ops).
2. **Dispatch when one side's type is known** (`"a" + b`) ⇒ the two tag tests, the branch and the phi
   are dead; go straight to `__op_add`.
3. **`ql_truthy` on a statically-known Boolean** condition (boxed case; the raw `i1` case is already
   done in C1).

### ⑪ Status of the raw-ABI work (②b / ②c) — measured, not started

- **②b raw returns**: **340** call sites, all pointing at the 6 functions that *declare* `: Number`.
  **Measurement gap to close:** only *declared* returns were counted; re-count with *derived* `Number`
  returns too — the generator is allowed to consume derived conclusions, so the real fuel is likely
  larger than 340.
- **②c raw parameters**: **0** today — blocked on ⑨ + ⑥ (no parameter annotation takes effect).
- **Emit-order discount** (measured): 92 % of user/library-internal calls have their callee already
  emitted (285/309 on t20, 287/312 on a mutual-recursion sample). Whole module: **23 025 direct vs 307
  indirect calls (98.7 %)** — the "no forward `declare`" constraint is essentially already absorbed.

### ⑫ No NaN, no Infinity — **attempted, landed, then REVERTED by decision**

**Status:** the author first decided "绝对不要 nan 和无穷", then reversed it in the same session
("算了,把 nan 和 infinity 加回来吧"). The removal was landed as `4903d57` (+ `35257b3` for the literal
diagnostic) and then undone with `git reset --hard 4903d57^`; **all three commits are preserved on the
branch `backup/nan-removal-stage1` (→ `35257b3`)**, so the attempt is fully recoverable. The design
reasoning below is kept for the case the decision is ever revisited.

What the attempt established, and what stays valid regardless of the reversal:

- the **five producers** and their exact sites — `stdlib/number.ql` (5), **`stdlib/decimal.ql`** (4, on
  the *parse* path, plus the exponent-range guard the general branch needs), `stdlib/math.ql` (10), and
  the runtime's `__math_extreme` **±∞ sentinel** for the empty `Math.max`/`min` case;
- **an Error as a call argument is rejected** (`TypeMismatch: attempt to pass error value as
  argument`) ⇒ a `check(<call that now errors>)` silently stops counting (t34's 67 vs 70) — a
  fixture-side rule that applies to *any* future std change;
- the **stage-2 sizing**: 685 Number-typed arithmetic sites would need a trap (602 fast-path + 83 raw)
  and **`constFoldable=0`** — their operands are never literals — ⇒ ≈ **+1.4–2.7 k IR**, with 4b
  (bounded domains) as the only offset. So the price of "no NaN/∞" is IR *size* (the repo's metric),
  not runtime speed;
- and ⑬'s builder lesson, which was the real blocker for the first three attempts.

**The original decision text (kept for reference):**

**Author's decision (this session):** NaN and ±∞ must be **unreachable** in the language — "绝对不要
nan 和无穷这两个沙雕东西,任何理由都不要". The chain that gets there: division by zero is *already*
an error (`aot/runtime.ql:144`, `__op_div0`); if **overflow is also an error**, ±∞ becomes unreachable;
NaN can only come from an ∞ operand (`∞-∞`, `∞/∞`, `0*∞`) or `0/0`, so it goes with them.

Stages, and what each costs:

1. **Cut the sources in std** (approved; attempted twice and reverted this session because it cannot
   land alone — the fixture/`.expected` rewrite is part of it). Measured scope:
   - `stdlib/number.ql`: delete `invalidNumber`; non-String ⇒ `TypeMismatch`; malformed text — **and the
     `"inf"`/`"infinity"`/`"NaN"` spellings** — ⇒ `RangeError` (5 sites; the `i`/`N` word branch goes
     away entirely).
   - **`stdlib/decimal.ql` — the fifth producer, found on the second attempt** (it is on the parse
     path: `Number.parseFloat` → `decimalNumber`/`decimalCompose`): line 65 `value = 1e308 * 1e308;`
     (the `biasedExponent == 2047` branch) and lines 76/97/121 `return decimalCompose(0, 2047, …)`
     (overflow ⇒ ∞). These must raise too, or `parseFloat("1e400")` still manufactures ∞.
   - `stdlib/math.ql`: delete `nanNumber`/`infiniteNumber`/`signedInfinity`; `exponential` (64),
     `integerPower` (90), `power` (106/110/117/122/124/135/140), `trig` (195) ⇒ `RangeError`; `sqrt`'s
     non-finite path ⇒ `RangeError`. **Careful:** the two assignment-style sites inside `power`
     (135/140) must become early `return`s, or the later `-result` turns the Error into a TypeMismatch.
   - `aot/runtime.ql` — `__math_extreme` (1509): the running extreme was seeded with
     `__number_bits(0, 2047, maximum)` = **±∞**, i.e. the empty-argument sentinel. Per the decision the
     empty call is an `RangeError` and the seed becomes the first *checked* argument (the NaN branch
     below stays until stage 3 makes NaN unreachable). **Not landed yet** — see below.
   - **Confirmed mechanism for the silent coverage loss (root-caused):** with the std edits applied,
     `t43_number_library` fails with exactly this chain — `TypeMismatch: attempt to pass error value as
     argument` ⊂ `stdlib/number.ql` `RangeError: Number.parseFloat cannot parse` — i.e. when a std call
     now *returns* an Error and that Error is used as a **call argument** (`check(parseFloat(x), …)`),
     the whole call is **rejected** and never runs, so `check`'s counter silently does not increment
     (that is the t34 67-vs-70). Fixture rewrites must therefore never pass the Error as an argument:
     inspect it inline (`parse(x).type == "RangeError"`, `isError(parse(x))`) — `isError`/`print` are on
     the runtime's exempt list, so those forms work.
   - **Unresolved, blocks landing:** compiling `aot/tests/t34_numeric_syntax.ql` against a compiler built
     with the edited library fails with `CompileError …:1:1: Expected ']' after array` — a *parse*
     error at a bogus position. Narrowed but not explained: the edited library parses fine in other
     contexts (t25/t26/t43 compile; minimal programs using `parseFloat`, the odd literals `.5`/`5.`/
     `1.e2`/`00012`, and `let Infinity = 7; let NaN = 8;` all parse), and t34 is unchanged and parses
     against the old library. Since the library is embedded at *compiler build* time, per-file bisects
     must **rebuild the compiler each step** (the earlier attempt was invalid: the stale compiler still
     embedded the edited bundle). Next diagnostic: rebuild per-file, or add a parse-only mode that
     reports the position inside the parsed text rather than in the entry program.
   - **Do not land stage 1 until that parse failure is explained** — an unexplained compile failure is
     worse than the NaN/∞ it removes.
2. **Language-level trapping arithmetic**: `+ - * / %` on Numbers whose result is ±∞/NaN ⇒ error.
   Literal/constant overflow ⇒ **compile-time** error (static detection, per the author's preference).
3. **Delete what becomes dead**: `Number.isNaN`/`isFinite`, the `"NaN"`/`"Infinity"` branches of
   `Number.toString`, the runtime's `__num_nan` and its NaN detection, the saturating bit-conversion
   paths for NaN/∞; mirror all of it in the interpreter; rewrite `t26_extrema`'s NaN/∞ cases.
4. **Offset the cost**: stage 2 makes "arithmetic cannot produce an Error" false ⇒ the located-error
   elision (worth **−1 929** lines / 155 sites, `9cceff7`) comes back. Offsetting it needs magnitude
   reasoning, staged cheaply: (4a) constant folding + literal diagnostics (free), (4b) bounded domains
   (loop counters, indices — the bulk of real sites), (4c) a fallback `fcmp`+branch on the Number path
   only, with the cold path going through the existing outlined helper.

Fixture fallout measured for stage 1 (before revert): `t19_literals` and `t54_json_stringify` unaffected;
`t25_numeric` 83→53 checks, `t26_extrema` 51→37, `t34_numeric_syntax` 70→67, `t43_number_library` aborts
at 11:2. The rewrite pattern is mechanical where the case survives — a *failing* std call yields an
Error **value** you can inspect inline (`check(parse("bad").type == "RangeError", …)`, like `t25`'s
existing `std.Math.sqrt(-1).type == "TypeMismatch"`) — and cases whose *input or output is itself*
NaN/∞ (all of `t26`'s NaN min/max, `t25`'s `nan | 0` / `inf & 1` / `sqrt(inf)`) simply disappear, i.e.
that coverage is knowingly given up.

### ⑬ Bootstrap divergence: a compiler built from the same sources cannot compile `t34_numeric_syntax`

**Found while trying to land ⑫, and it is a *separate*, more basic defect.** Baseline test (clean tree,
no working-tree edits):

```
/tmp/nb  = built BY /tmp/n70 FROM the committed sources  -> compiling t34: CompileError …:1:1:
                                                           Expected ']' after array
/tmp/n70 = built earlier in the session from an earlier source state -> compiling t34: OK
```

So **the same committed sources produce a compiler whose behaviour depends on which compiler built it** —
this toolchain is currently **not faithfully self-reproducing**. Consequences:

- every attempt to land ⑫ ran into this same wall (three attempts, each reverted);
- a per-file bisect of the stdlib edits is **useless** until this is fixed: with all four edited files
  reverted one at a time (rebuilding each step) the failure persisted, and it also persists on a
  **fully clean tree** — hence not caused by the stdlib edits at all;
- the gate coverage question: `run_selfhost_tests.py:152` *does* use `t34_numeric_syntax`, and the
  selfhost gate was green at `74019f4` — with the compiler built *then*. So the divergence is
  **generation-dependent**, not a simple one-commit regression walk.

Next diagnostic (cheap, decisive): **bisect by generation** — rebuild in a chain (`n70 → n71 → n72 …`)
from one fixed source state and find the generation at which compiling t34 starts failing, then diff the
two neighbouring compilers. That pins whether the cause is in the analysis (the probe counters, the
family/`typeMismatch` change) or in the emitter, and whether the parser itself is being *miscompiled*
(the message is a *parse* error with a bogus position).

Do this **before** resuming ⑫: an unreproducible bootstrap will keep eating every attempt at landing
anything, and a silently miscompiled parser is a correctness problem in its own right.

## 6. The design obligation for step ④ (call-site checks)

Removing a member's internal error return is only sound if the *claim* stays honest: the
moment a callee's signature is used to prove something at the call site, the call site owes a
check that the value really is what was claimed. That is the same obligation as the
"call-site `TypeCheck`" above, and it is the link between ② (eliding Error tests) and ④
(trusting signatures). Do not elide a test on the strength of a signature that nobody checks.

---

## 7. Estimated payoff (order-of-magnitude, not a promise)

Per site, from the operator-path breakdown in the design docs: a Number operation whose types
are known still pays a read/write "is this an Error?" test (≈7 lines) plus box round-trips
(≈9 lines); the raw path is `load double; fadd; store double` (≈3). So ≈7 lines/site
conservatively, up to ≈16/site if the Error test also goes (a Number cannot be an Error).

Applied to the pools in §5②:

- Error-test elision alone: `(309 + 403) × ≈8 ≈ −5k … −6k` lines (≈3%);
- plus unboxing on the convertible subset (~1/3 of those sites today): a further
  `−2k … −4k`;
- combined, current type coverage: **≈ −7k … −10k (3.5%–5%)**;
- if the type coverage is completed, the pools roughly double on the fixable subset:
  **≈ −12k … −20k (6%–10%)** — but see the correction below; treat the upper end as
  optimistic.

Honest caveats:

1. The "convertible fraction" is a guess. Measuring it is exactly what step ① enables.
2. The ≈29 lines/block figure comes from the *runtime*; library/user-side blocks are likely
   smaller.
3. The Error-test elision is the **bigger** of the two levers and it does **not** care about
   representation (it applies to boxed slots too), which is why it is sequenced before
   unboxing.
4. **Correction to an earlier estimate:** of the 457 "unknown" sites (329 reads + 128 binops),
   a permanent subset can never become known *by design* — dynamic index results may be Error
   values, and forcing a type on them would break `isError(...)` guards. So "complete the
   types ⇒ all 457 convert" is false; the upper bound of the range above has been lowered
   accordingly.
5. For calibration: the two levers already landed are the same order of magnitude —
   per-binding type-slot/check omission **−5830**, runtime analysis **−11492**.

---

## 8. What the 457 unknown sites are (and why it is the next measurement)

They are the `Identifier//boxed` (329) and `BinaryOp//boxed` (128) buckets: nodes whose
`staticType` is empty, so they can neither be given a representation nor have their Error test
elided. Their causes, from the sample names in the probe
(`chunk size key map length c mapped candidate s v e hi p ca ah al …` — mostly `string.ql`'s
table-building locals):

1. **dynamic indexing** (`table[i]`, `chunks[k]`) — intentionally unknown, keep it that way;
2. **untyped member access** — most importantly `.length`, now partly fixed by the
   uncommitted rule; `.length` on `Object` stays unknown;
3. **runtime members with no signature** — fixed by ③/④;
4. **chain propagation** — a function whose return type cannot be derived poisons every
   caller; fixed by ⑥.

Next measurement: bucket the unknowns **by cause** (the probe already carries node kind and
static type; add a cause dimension) and produce a priority table of "how many, and can each be
fixed". That is more reliable than guessing fractions, and it is the input for ③/④/⑥.

---

## 9. War stories — mistakes worth not repeating

- **`tagRep` must return the node's *current static type*, not the representation.** When it
  returned the representation (`""` for many kinds), `Boolean/Null/String/Object/Array/
  Function/Call/MemberAccess` branches all returned `""`, and codegen grew **+4780** lines.
- **A counter that was `| tail`-ed hid a 40-minute run.** See §3.
- **`sh` process substitution is unavailable** in this environment; use temp files.
- **Measure the binary you think you are measuring.** An earlier "arm2" measurement
  accidentally rebuilt unchanged source (a regex assertion failed and aborted the patch step,
  so the numbers reported as arm2 were really arm3), and a compile-time self-check had to be
  added that the two builds' binaries actually differ. Compare hashes/dates of the built
  binary before trusting a number.
- Arms measured during the rejected generator-side experiment (kept for the record):
  A 215 919 (baseline), D 225 600, arm2 228 158, arm3 233 570; of 897 `fcmp` sites only 2 had
  both operands raw — i.e. the fuel for unboxing is exactly why the user's "complete the
  types first" ordering is right.
- **`stdlib/bundle.ql` must be regenerated** after stdlib edits (§3).
- **Never put node references on AST nodes.** The generator's `reserveModuleBindings`,
  `loadModuleNode` and `collectModuleExports` walk every property of every node
  (`std.Object.keys(node)`), so a node-valued property cycles and the compile never finishes
  (measured: `18 s → >240 s`, nothing emitted). Keep per-binding analysis state in a
  compiler-internal table and store only a **number** on the node (§5②).
- A "silently drop the runtime's diagnostics" reading is wrong: report the count, keep the
  worklist.

---

## 10. Acceptance criteria and boundaries

1. Report **hit counts first, then IR lines**.
2. IR below the accepted baseline (215 919) on `/tmp/t20.ql` — currently satisfied (203 834),
   but note that today's win comes from the runtime analysis lever, *not* from unboxing.
3. Program output unchanged: 20 / 20 / 21 / 4, and `t20_native_bridge` 42 / 2.
4. `run_interpreter_tests.py` 53/53 and `run_selfhost_tests.py` 47/47
   ("ALL CHECKS PASS" / "ALL REQUESTED CHECKS PASS").
5. Commit only when both are green; **never merge into `dancing-with-dragon` without the
   user's explicit approval.**
6. Taste/preference notes that apply here: the user expects performance to be *measured*, not
   assumed; expects failures to be root-caused with evidence (re-run against a baseline before
   blaming a change); prefers static/compile-time detection over runtime checks in generated
   code; is comfortable with breaking semantics when it buys compile-time checking; approves a
   proposed ordering with a terse "可以" and expects the work to simply proceed.

---

## 11. The plan, and the decisions behind it (decision log)

Each entry is a decision that was made deliberately. Several are corrections from the user;
the corrections are the important part — do not re-litigate them.

- **Compile-time decides representation; the generator only consumes it.** An earlier attempt
  patched the *generator* (trial emission: emit a raw path, fall back if it does not work,
  reuse already-emitted operands). The user rejected it and required the compile-time plan.
  Consequence: `emitValue(node) -> {reg, raw}` answers only "what is this value's natural
  representation"; there is no `want` parameter, consumers never inspect it, and use sites
  call `boxIfNeeded`.
- **Representation belongs to the value; boxing belongs to the use site.** The user's
  invariant: a raw value may cross a boundary, and if a *particular* consumer needs a box, it
  boxes *there* — never globally, because a global downgrade would box that value everywhere.
- **Types before unboxing.** Measured, not assumed: of 897 `fcmp` sites only 2 had both
  operands raw — the generator already knows how to use raw values and simply has almost no
  fuel. The user set the order explicitly: finish the standard library's types first, then
  make one unified consumer-side change.
- **No duplicate runtime interface table.** The first proposal was to declare an interface for
  runtime members. The user's objection: the source can *derive* it, so a written copy is a
  duplicate of the truth and will drift. This was superseded by "analyze the runtime source",
  which is why B1 exists at all.
- **Standard-library members must not return errors internally.** The original plan was to
  annotate declarations while runtime members still returned `__err("TypeMismatch", ...)`.
  The user's correction: std should simply not do that, so signatures become derivable from
  the source. That is B6, and it creates the call-site-check obligation in §6.
- **The runtime program must be analyzed.** It was only ever parsed. Largest single win so far
  (−11 492) — and note that it is family (a), not unboxing.
- **Semantics may be broken to buy compile-time checking.** The user explicitly chose "change
  the semantics" over "keep the semantics and move checks opportunistically", and accepts the
  fallout on docs, fixtures and retained-host tests.
- **Failures are root-caused with evidence.** If a suite fails after a change, prove whether
  it is pre-existing or environmental by re-running against a baseline (older compiler /
  build / binary) before attributing it to the new work.
- **Performance is measured, not assumed.** Before/after IR counts and timings, every time;
  hit counts reported before line counts.
- **Ask before adding new features unilaterally.** The user prefers being asked, and for
  multi-step plans he approves a recommended ordering with a terse "可以" and then expects the
  work to proceed without further check-ins.
- **Return types are *declared*, not derived** (2026-10-11). The runtime members' return types cannot
  be derived — their tails hang on host/representation primitives — so removing the internal `__err`
  alone buys one member. Fix: the language feature `(params): T -> body` (`47a4e97`), the author's
  declaration authoritative. The syntax (`: T` *before* the arrow) is the user's choice, because
  `-> T { … }` is ambiguous with an expression-bodied lambda followed by a block. Enforcement:
  compile error where provable, runtime check otherwise; and, per the user, uniform with parameter
  annotations — *any* annotation is enforced, not only builtin scalars.
- **Module/namespace resolution must be general, not a `std` privilege.** An export *is* the value it
  is bound to and `import` hands that value over directly; module identity is the export table's field
  names regardless of the value's kind, and `std.<X>` is typed by that value — never a forced
  `"Object"`. The same rule must serve user `import`, or it is a privilege over ordinary objects.
- **Privileges stay only for language contracts/mechanisms**: a type value's `check` (it cannot come
  from the index — the predicate bodies are written against the opaque host primitive `readU64`), and
  `.length` on Array/String. Ordinary objects get none.
- **Return types before unblocking the channel, not after** (2026-10-11, order changed on evidence).
  Phase 2 (declaring runtime signatures) produced *zero* measurable change while the module index was
  dormant: `readU64`'s type turned out to be already derived, and the members whose types are not
  derivable are consumed only through `std.<X>.<m>`. So the index (the *channel*) landed first
  (`0b8e239`), then the declarations (`d5cc108`, −151). Declarations without a channel are not work.
- **Declare the return type; keep the internal `__err`** (2026-10-11). Measured on the same fixture:
  the ④ form (parameter annotations + dropping the internal error return) loses more to call-site
  checks than it gains and changes fixtures (−58); return annotations alone, internal check kept, give
  −151 with identical semantics. Once signatures can be declared, "derivable from the source" is no
  longer a requirement.
- **"Unknown" can mean the analysis never reached the node** (2026-10-11, the largest lever found).
  The `Call` branch skipped both its callee and its arguments, and literals/aggregates/`IndexAccess`/
  expression-`if` did not recurse — so large parts of the AST were never stamped and the generator
  could only emit the generic path. Two commits: −3 150 and −1 274. Before adding another "known
  type" rule, check whether the node is analysed at all; and note that this also subsumed the
  planned stdlib annotation pass.

## 12. Vocabulary (use the user's words)

- **"类型信息" / "type information"** — the type annotation/information on a binding. Not
  "annotation".
- **"裸值" / raw value** — an unboxed representation (`double`, `i1`).
- **"装箱" / boxing** — converting to `%ql_value`, performed at the use site that needs it.
- **"消费端" / consumer** — the generator side, as opposed to the analysis.
- **"分析期" / analysis phase** — the compile-time AST traversal. It is *static*: it does not
  execute the program and has no side effects, it only annotates AST nodes and fills
  compiler-internal tables. (This had to be explained to the user once — the phrase "analysis
  runs over runtime source" sounds like execution, and it is not.)
- **std** — the standard library, which must be authored in QLang itself, in the
  pure-language stdlib files. The runtime may only provide low-level language *mechanisms*
  (e.g. string indexing / length), never std-level helper functions exposed onto std.
- **M-milestones** — the AOT compiler was built in milestones (M1, M2, M3); design docs live
  under `docs/superpowers/specs/` and plans under `docs/superpowers/plans/`.
- **"返回类型签名" / return-type signature** — a declared return type, `(params): T -> body`:
  author-declared, enforced (compile-time where provable, runtime otherwise), consumed by the compiler.
- **"一般模块解析" / general module resolution** — the export table taken at face value (a module is
  a field name, whatever the value's kind), shared by `std` and user `import`; not a `std`-only index.

## 13. Open questions / the next measurements

In rough priority order — each is a measurement, not an opinion:

1. **Fuel, per program.** How many reads and binops in the *library and entry* code (not the
   runtime) are statically typed and unboxable? Step ① (B3) delivers this.
2. **Unknowns by cause.** Bucket the 457 unknown sites (329 reads + 128 binops) by cause —
   dynamic index / untyped member access / unsigned runtime member / chain propagation — and
   mark which are fixable. This is the input that orders B5, B6 and B7 instead of guessing
   conversion fractions.
3. **Conversion fraction.** What fraction of "known type" sites actually qualifies for
   unboxing (function-local *and* every write type-known)? This decides whether family (b) is
   worth thousands or hundreds of lines.
4. **How much family (a) is left on the read side.** *Answered:* 0 — `0d02ef0` already removed
   the read-side test; the lever moved to the operator sites and landed as `9cceff7` (§5②).
5. **Call-site check obligations.** As runtime member signatures start being trusted (B5/B6),
   enumerate which call sites owe a `TypeCheck`, so that elided tests stay sound (§6).

