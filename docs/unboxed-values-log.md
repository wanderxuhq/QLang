# Unboxed values / compile-time reduction of emitted IR — **session log (evidence)**

> **This is the historical record, not the handover.** For the current state, the rules, and what to do
> next, read **`docs/unboxed-values-handoff.md`** first. This file holds every measurement, hit count,
> dead end and war story in the order it happened, plus the item-by-item reasoning behind the decisions
> the handover refers to as §5①–⑬. Cross-references below (§5…, §7…) are internal to this file.


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

> Vocabulary, so the two documents line up: **"the roadmap"** = this phase table (§0.1, phases A–E) plus
> the numbered worklist in **§5** (`①`–`⑬`, item-by-item reasoning and measurements). The handover
> carries the same two things in condensed form: its **§3 "Roadmap — the phases and the IR ledger"** and
> its **§4 "The ordered worklist — what to do next"**.

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
#    a native alternative: build stdlib/build_bundle.ql with the compiler under test and run it —
#    verified to produce a byte-identical bundle, and it exercises the shipping path
```

**Builder hygiene (learned the hard way — see §5⑬).** The library text is embedded at *compiler build*
time, so a stale or mis-built compiler produces failures that are not in the sources. Before believing a
failure:

- rebuild the compiler under test from the current tree **with a builder that is itself verified** (the
  last compiler whose gates were green), and keep using that chain;
- if the failure looks bizarre — in particular `CompileError …:1:1: Expected ']' after array`, a *parse*
  error at a bogus position, which is the signature of a failure *inside the embedded library* text —
  **reproduce it with a second, independently built compiler before investigating**. Three attempts at
  §5⑫ were wasted on exactly this.<br>Verified chains used this session: `/tmp/n67 → nc → nd` (good),
  whereas `/tmp/n70` was a bad builder.

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

### ⑭ The `lifetime` experiment — a **measured rejection** (and what forced the `-O2` gate)

Motivation: `llvm.lifetime.start/end` is **10 442 IR lines (5.4 %)** — half of all call lines — and looks
like pure noise, so it was candidate #1 for deletion. The experiment needs **no rebuild**: the calls are
pure hints, so they can be stripped from the emitted text and the result is exactly "as if not emitted".

| | IR lines | `-O2` AArch64 instructions |
|---|---|---|
| as emitted | 194 812 | 130 505 |
| `lifetime` stripped | 184 368 (**−10 444, −5.4 %**) | 134 366 (**+3 861, +2.96 %**) |

The stripped build **links and runs correctly (prints `20`)** ⇒ this is not a bug, it is a genuine loss:
LLVM uses the lifetime markers to merge stack slots. **REJECTED — do not re-open without new evidence.**
This single experiment *proves the measurement rule* now in the handover §5: an IR-line win that removes
slot/box movement can be **absorbed by LLVM, or even come back as a loss**. Count **machine instructions
after `-O2`**, not lines.

Counts taken at the same time (all read-only, IR-neutral):

- **⑦ whole-stdlib linking**: 280 functions defined, 107 directly called ⇒ **189 (67.5 %)** are reached
  only through closure code pointers ⇒ *statically undroppable*; only real laziness could drop them.
  Sizes the "on-demand stdlib" lever (feature-sized; recorded, not started).
- **③ error edge after a call**: the "is this an Error?" test is `call @ql_tag` + `icmp eq i64 …`, but it
  is **not adjacent** to the call in the text, so adjacency counting is invalid — a count needs an
  **emitter-side counter** at the site that emits the check.
- **IR composition** (194 812 lines): slot/frame traffic **51.3 %**, calls 11.9 % (of which `lifetime`
  **5.4 %**), control flow 10.2 %, labels/non-instructions 9.2 %, boxing/unboxing **7.3 %**,
  pointer/number casts 6.3 %, type tests 2.8 %, arithmetic **0.9 %**.
- **`-O2` machine composition** (130 206): memory **43.7 %**, `mov`/immediates 12.8 %, branches 9.7 %,
  `bl` 3.0 %; and O0→O2 removes 61.5 % of all instructions, **76 % of the removals being memory traffic**.
- **Hand-written vs generated**: `aot/runtime.c` compiles to **559** instructions (0.4 % of the module)
  ⇒ ~99.6 % of the artifact is QLang-emitted. Density ≈ **17 instructions per analysed operation**
  (7 472 operations) vs ~1–2 for a typed C-like language and **56 instructions for V8/TurboFan's
  optimized `add(a,b)`** — i.e. we sit at V8's *optimizing-tier order*, not C's.

### ⑮ Error 设计 —— 从「每个值都可能是 Error」到「全函数 + 只能被携带」

起因:实测错误机制占优化后机器码最多 **31 %**(§5⑭)。以下是讨论结论,**尚未实现**。

**判据(每个操作问一句):能不能给它一个「在其定义域上处处有意义的值」?**

| 类 | 处理 |
|---|---|
| **(a) 类型保证不可能** | 编译期拒绝 / 先收窄 ⇒ 零运行时检查 |
| **(b) 有有意义的值** | 全函数(`${x/0}=±∞`、缺失 = `Null`、插值 = 默认渲染)⇒ 零检查 |
| **(c) 真的没有值** | **唯一**保留部分性的地方 ⇒ `Result`/`Option` |

原则:**尽量把 (c) 推成 (a) 或 (b)**。注意:"运行时总有值 + 类型精确"不可兼得;只有前者就是今天
(`Number` 意味着 Number 或 Error),那正是 1 521 个检查点的来源。

**失败源清点(实测)**

- **语法**:编译器认识 20 种节点,其中 **9 种会失败** —— `a op b`(类型 ✓ / 除零 ✓ / `&&`·`||` 遇
  Error ✓)、一元 `-`·`+` ✓、`a[i]` ✓、`a.b` ✓、赋值 ✓、**注解检查(最大一类)** ✓、`Call` 元数 ✓、
  插值 ✓、`import` ✓。
- **运行期原语 7 个**:`__op_zone_error` ✓、`__neg_error`/`__pos_error` ✓、`__op_div0` ✓、
  `__arity_error` ✓、`__error_raise` ✓、`__exit_error` ✓(另有 `__source_error` 只做溯源 ✓)。
- **库层 26 处 `std.Error.raise`**:`TypeMismatch` 17 ✓、`BundleError` 3 ✓(构建期)、`RangeError` 2 ✓、
  `UndefinedField` 1 ✓、`IndexOutOfBounds` 1 ✓、其余 2 ✓ ⇒ ≈ 运行期相关 22 处。
- **宿主 6 个**:`ql_openat`/`ql_read`/`ql_write`/`ql_readlinkat`/`ql_getrandom`/`ql_alloc`(OOM)——
  **今天完全没建模**(abort / 哨兵值)⇒ 必须补成 `Result`。

⇒ 全函数化之后,**`(c)` 只剩「解析/转换 + 宿主 I/O」约 8 个原语**。

**Error 的地位:三档,只能选一档 —— 定 ②**

| 档 | Error 是什么 | 类型精确 | 要写处理 | 静态可删检查 | 隐式出口 |
|---|---|---|---|---|---|
| ① 普通值(今天) | 处处可入的值 | ✗ | 不用 | ✗ | 有 |
| **② 只能被携带(定)** | `Result`/`Option` 的错误侧 | **✓** | 要 | **✓** | 无 |
| ③ 控制流(异常) | 逃逸机制 | ✓ | 不用 | ✗ | 有 |

选 ② 的理由:三者里**唯一**同时「类型精确 + 静态可删」⇒ 31 % 才有**制度性**的消除路径。要点:

- **表示层不动**:`Ok(v)` 就是 `v`,`Err(e)` 就是 Error 对象(tag 8 照旧)⇒ **零运行时开销**;
- **「一致性」= 规则统一**(凡类型里带 `Result`/`Null` 一律同样处理),不是「所有操作长得一样」;
- **可证性只做两件事**:删死代码 ✓、可证为错时报诊断 ✓ —— **绝不改变你写什么**;
- **语法形式永不产生 Error 值**:类型已知 ⇒ 编译期拒 ✓;`/0` ⇒ IEEE ✓;`a[i]`·`a.b` ⇒ `Null`
  (普通值 ✓);注解 ⇒ 静态消解 ✓;插值 ⇒ 默认渲染 ✓ ⇒ 于是**既没有「值污染」也没有「隐式跳过」** ✓;
- 错误只出现在 (c) 的**调用点** ✓,出口**显式**(`?` 透传 ✓ / 判一下收敛 ✓)⇒ 「半执行 / 隐式退出」
  那类坑不成立 ✓。
- **传播不对称(已定)**:语法侧不需要也不产生任何东西(永不失败 ✓);函数侧「该怎么处理怎么处理」✓,
  要透传就**显式写 `?`** ✓ —— 语法不开通道 ✓,类型也不被编译器偷偷改写 ✓。

**② 的缺陷(要认)**:传染(可失败沿调用链上蔓延,规模 ∝ `(c)`)✓、happy path 被处理代码打散 ✓、
处理策略无默认答案 ✓、`Null` 与 `Error` 两个标记 ✓、容器交织需明确规则(`Array(Result(T))` vs
`Result(Array(T))`)✓。

**② 成立的两个前提**:① **全函数化**,把 `(c)` 压到最小;② **边界必须声明**(函数签名 / 模块导出 /
FFI)⇒ 这就是「`std` 必须携带作者声明的类型信息」那条规则的**根本理由**(静态性质在类型丢失处会漏 ✓)。

**待决**:`/0` 改 IEEE 并去掉 `__op_div0` ✓;缺失统一用 `Null` ✓;命名统一(`Result(T)`/`Option(T)` 都
只是普通类型,`Error` 是 `Null` 的有信息形式)✓;传播糖**全局一次性选择**(全用 `?` 或全显式)✓。

### ⑯ 收窄(守卫后的落到点)—— 切片 1 落地(`2cbc2e5`)

§5⑮ 设计的第一步实现。语料里的惯用法是「守卫 + 提前返回」(`if !Number.check(v) { return raise };`),
所以收窄必须落在**落到点**上,而不是分支体内。

- `types.ql` 五处:新增收窄事实栈 `typeNarrowScopes`(与 `typeScopes` 同深同栈 ✓)+ 查询 ✓;
  `branchAlwaysExits`(末句 `return` ⟺ 必然退出 ✓);`narrowAfterGuard`(`!X.check(v)` 为假 ⇒ 落到点
  `v` 是 `X` ✓;`isError(v)` 为假 ⇒ 落到点 `v` 不是 Error ✓;**「不是 X」无法用现有类型表达 ⇒ 忽略,
  不假装** ✓);语句位置 `If` 在 `typePop()` **之后**把事实写进**外层**作用域(即落到点所在者 ✓);
  `Identifier` 分支把被收窄的名字置 `cannotBeError` ✓(错误边随之成为死代码 ✓);`Assign` 作废收窄事实 ✓。
- **量测**(t20):IR **194 812 → 194 640(−172,−0.09 %)** ✓;`-O2` 机器指令 **130 505 → 129 040
  (−1 465,−1.12 %)** ✓;输出仍为 `20` ✓;两套门禁全绿 ✓(interpreter / selfhost ✓)。
- **比例教训(值得记住)**:IR 只降 0.09 %,机器码降 1.12 % ⇒ 收窄删掉的是**非访存**代码(检查 +
  分支 ✓),O2 不会把它们变回来 ✓ —— 对比 ⑭ 的 lifetime:IR −5.4 % 而机器码 **+3 %** ✗。
- **踩坑记录**:门禁第一次跑看起来「卡住」且日志为空 —— 原因是我把输出管进了 `tail -5`(缓冲 ⇒ 整套
  跑完前无输出 ✓),于是**无法区分「慢」与「卡」** ✗。规则升级:**门禁输出禁止管道缓冲**,直接重定向
  或用 `tee`,后台任务不要带 `tail` ✓。
- 下一步(仍待决):`/0` ⇒ IEEE 并去掉 `__op_div0` ✓;缺失 ⇒ `Null` ✓ —— 两者都要先动成文契约与
  既有断言(`docs/numeric-semantics.md` + `t14`/`t25`/`t36`)✓。

### ⑰ 「除数可证明非零 ⇒ 去菱形」—— 试做**失败**,已回滚(被 `-O2` 与健全性检查逮住)

动机:⑩ 的第一条候选 —— 除数是非零字面量(语料里 `% 2` 遍地)⇒ 除零菱形不可能走 ⇒ 纯减少。

做法:`types.ql` 在 `BinaryOp` 推导里,对 `/`·`%` 且右操作数为**非零 `Number` 字面量**者盖章
`divisorNonZero`;`qlangc.ql` 的 `emitNumOp` 加第 4 参,命中时直接 `fdiv` / `__num_rem` 并 `return`,
跳过整个菱形(标签、比较、phi)。

**结果:失败,已回滚(未提交)。** 发射出的 IR 是**坏的**:

```text
clang: /tmp/ir_nz.ll:1498:39: error: use of undefined value '%t1006'
       %t1007 = call i64 @ql_tag(%ql_value %t1006)
```

并且 `fcmp oeq …, 0.0` **0 处**、`__num_rem` **0 处**、`@__op_div0` **定义 0 处** ⇒ 运行期那些函数
**根本没被发射** ⇒ 模块是**被截断**的 ⇒ 先前看到的「IR −15 739(−8.1 %)」是**截断假象**,不是减少 ✗。

**两条教训(都当场验证过):**

1. **IR 行数骤降要当可疑信号**:先验证模块**合法**(`clang -O2 -S` 会说话),再谈收益 ✓ —— 只看
   `wc -l` 会把「发射器中途失败」当成 −8.1 % 的胜利收下 ✗;
2. **健全性检查必须是行为级的**:动态除数用例(`let z = 0; println(1 / z);`)在坏版本里**连零比较都
   没有** ✗ ⇒ 若它侥幸链接成功,就是一个**静默语义 bug**;报错反而救了我们 ✓。

**待查(下一轮)**:为什么加了「提前 `return` + `emitFloatValue`」的那条路径后,发射器从这里开始产出
未定义临时量 —— 怀疑点在 `emitNumOp` 的**调用者契约**(它期待一个值)与该 `return` 的交互,而不是盖章
条件本身 ✓。回滚前的一切都留在 `/tmp/ir_nz_BROKEN.ll` 供比对 ✓。

**第二次试做(去 `return` + 字段永远存在)的结果 —— 也是否决,但原因完全不同 ✗:**

合法性与健全性都过了 ✓(`clang` 0 error ✓;动态除数用例仍有 106 处零比较且**仍报 `DivisionByZero`** ✓),
可是数字是负的:IR **194 640 → 194 964(+324)** ✗,`-O2` 机器指令 **129 040 → 130 697(+1 657,+1.28 %)** ✗。

查探针才看清:**动因不在发射器,而在分析** ✗:

| 探针 | 改动前 | 改动后 |
|---|---|---|
| `unboxable bindings` | **528** | **519** ✗(少 9 个) |
| `typeRep boxed binops num` | 70 | **102** ✗ |
| `fcmp oeq …, 0.0` / `= fdiv` | 105 / 48 | **105 / 48**(完全相同 ✓) |

⇒ 快速路径在 t20 里**一次都没触发** ✓(菱形计数未变 ✓),变大全部来自**解箱判定被扰动** ✓(9 个绑定从
可解箱变成装箱 ⇒ 多出 32 处装箱 ✓)。

**由此立第三条口径** ✓:**对 `types.ql` 的任何改动都必须先看探针**(`unboxable` / `typeRep boxed` /
`located-error elided`)—— 分析是**全局耦合**的 ✓,往里塞一个「纯语法事实」也会移动解箱的 fixpoint ✗。
下次的做法:要么把该事实**在发射端就地判定**(它是字面量的性质,不依赖推导 ✓),要么让它在**所有推导
结束后的独立后置遍历**里盖章 ✓ —— 不要在 `inferExpr` 的主分支里顺手写字段 ✗。

### ⑱ 除零菱形:「非零字面量除数」候选 —— 实测 **±0 机器指令**,结案不落地

第三次试做(这次把「除数是非零字面量」这个**纯字面量事实**放在**发射端就地判定** ✓,`types.ql` 一字未动 ✓):

| 检查 | 结果 |
|---|---|
| 探针(`unboxable` / `boxed num` / `located-error elided`) | **528 / 70 / 92,与基线完全一致** ✓(分析未被扰动 ✓) |
| 模块合法性(`clang -O2 -S`) | **0 error** ✓ |
| 行为(动态除数 `let z = 0; 1 / z;`) | **仍报 `DivisionByZero`** ✓ |
| IR 行数 | 194 640 → **192 613(−2 027)** ✓ |
| **`-O2` 机器指令** | 129 040 → **129 040(±0)** ✗ |
| 程序输出 | 仍 `20` ✓ |

⇒ **LLVM 本来就已经把「比较 + 分支 + 冷错误块」这个菱形优化掉了** ✓:删掉只让 IR 行数变好看,**机器码
一分不省** ✗。按现行口径(机器指令说话)**净零** ⇒ **不落地,候选结案** ✓。

**由此立第四条口径** ✓:**带冷错误块的 `fcmp`+`br` 菱形属于「O2 已吸收」那一类** —— 想动它们之前,先量机器
指令(IR 行数在这里完全不可信 ✗)。这条把 §5⑩ 的第一个候选**划掉** ✓,也说明:凡「热路径只多一条比较 +
一条分支」的检查,删了都可能白删 ✓。

**顺带一条操作口径** ✓:**构建/发射的 stderr 不许隐藏** ✗ —— 本次第一轮我把 `2>/dev/null` 写进了构建命令,
结果只看到「IR 0 行」,白跑一轮;露出来立刻看到 `expected ';' after statement`(我的 `if/else` 少了一个闭合
`;` ✓)。与「门禁不许 `tail`」同族:**长命令的可见性就是诊断能力** ✓。

### ⑲ ⑥ 首批(std 返回注解)、⑥ 的阻塞点、以及 panic 三条规矩的归属(已核对 Rust)

**⑲.0 后补校正(比 ⑲.2 更强,以后者为准)** ✓:⑲.2 说「声明返回类型 ⇒ 调用点可信」这条链**没接通**,
措辞过强 ✗ —— `types.ql:788` **已经**会把**稳定**(从未被重新赋值 ✓)的绑定之 `s.value.returnType`
登记进 `typeFnResults`,而调用点定型正是读 `typeFnLookup(callee.name)` ✓ ⇒ 链**可能本来就是通的** ✓。
那样一来,首批 ±0 的更合理解释是:**那些调用点本来就没有检查可删** ✓。

⇒ **结论:不要先建机制** ✓。**顺手验**即可(挂在任何碰到调用点定型的构建里 ✓):编一个**单文件夹具**
——一个带 `: Number` 返回注解的普通函数 + 对它的返回值做运算 —— 数调用点周围的 tag/派发检查 ✓。
**检查没了** ⇒ 没有机制要接 ✓;**检查还在** ⇒ 才动 `types.ql` ✓(并按第三条口径先看探针 ✓)。

**⑲.0f 结论:链**是通的** —— 是验收夹具不判别(⑲.0b–⑲.0e 全部作废)** ✓

在**发射端** `emitBinaryOp` 打现场后真相大白 ✓:

```text
BIN:+ both=1 L:Call=Number R:Call=Number     ← 不注解版**也是** both=1 ✗
```

⇒ **两版都走快速路径** ✓,发射结果逐字节相同是**必然的** ✓,与「链断没断」无关 ✗。原因:登记的门是
`s.value.returnType != ""` ✓,而**推导出的返回类型也会写进 `returnType`** ✓(⑲.0d 的 dump 里,不注解的
`f` 就是 `ret=Number` ✓)⇒ **不加注解同样登记** ✓、调用点同样拿到 `Number` ✓ ⇒ **链本来就是通的** ✓。

⇒ **⑲.0 的「可能本来就通」是对的**(✗ 我随后四处「链断了」全是**误判**)✓。四处误判之所以发生,都因为:
**夹具不具备判别力** ✗(它比较的是「加注解 vs 不加注解」,而在**推导类型已经正确**的函数上二者**必然相同** ✗)。

**第五条口径** ✓:**验收夹具必须能判别** —— 要选**推导类型推不出来**的函数(多路径 / 带 `raise` ⇒
`derived` 为空 ✓),注解才可能有增量 ✓。而那样的函数**正是会失败的那些** ✓ ⇒ **⑥ 的真正增量被 Error 设计卡住** ✓
(与 ⑲.3 一致 ✓):能失败的函数,要等「`Error` 只能被携带」立起来,声明才既真实又有收益 ✓。

⇒ **⑥ 的价值比 roadmap 原先假设的窄** ✓:对推导已完整的函数,注解**不带来调用点收益** ✓(至多省掉一行
返回边检查,而 `proven` 让那一行本来就是 0 ✓)。要动 ⑥,先按第五条口径**挑判别性样本** ✓。

**量测已全部回滚** ✓(`aot/types.ql` / `aot/qlangc.ql` 恢复到 `2cbc2e5` 的干净状态 ✓);结论留在本节 ✓。

**⑲.0e 分析内部现场:登记其实**发生了** ✓ —— 故障在消费侧** ✓

把量测打进分析内部(照 `typeRepReport()` / `typeNsReport()` 的先例,用**导出访问器**
`typeFnRegReport` 交给发射端打印 ✓;只观察、不改决策 ✓):

- 夹具 **`f=r:Number,g:1,d:1`** ✓ ⇒ **登记已发生**:`returnType` 非空 ✓、稳定性条件通过 ✓、
  写入 `typeFnResults[0]` ✓;
- 不注解者 **`g:0`** ✓(`returnType` 为空 ⇒ 不登记 ✓,与设计一致 ✓);
- ⇒ **链路的生产侧是好的** ✓;**故障在消费侧** —— 调用点为何没拿到 `Number` ✗。

⇒ 焦点收窄到一处:`bothNum = isStaticNumber(left) && isStaticNumber(right)` ✓。若 `isStaticNumber` 只接受
**可裸表示**的节点 ✗,而 **Call 的结果是装箱的 `%ql_value`** ✓,那么即便 `staticType == "Number"` ✓ 也不会走
快速路径 ✗ ⇒ **注解对「以调用结果为操作数」的运算天然惰性** ✓(这与「⑥ 首批 ±0」「夹具逐字节相同」全部吻合 ✓)。

查法:`grep isStaticNumber aot/types.ql` 看清判据 ✓,再决定是「扩展它」✓ 还是「在发射端对**已证明**的调用结果
先解箱再走数值路径」✓。

**⑲.0d 打现场:三个假设全部证伪 ⇒ 问题不在我读的那段代码上** ✓

量测 `; fnreg:`(已作为量测辅助提交 `3bc8b44`,只多一行 IR 注释 ✓)把每个「`let 名 = 函数`」的
`declaredReturnType` / `derivedReturnType` / `returnType` 打了出来 ✓。已证实与已证伪:

| 假设 | 检验 | 结论 |
|---|---|---|
| ①「字段名对不上 ⇒ 字段没值」 | 现场 dump | **证伪** ✗:`带注解 f:Function decl=Number ret=Number`;不注解 `decl=` 空、`ret=Number`(推导值)⇒ **字段都已填好** ✓ |
| ②「注册读的 `s.value.returnType` 与用户路径不符」 | 改注册处读 `declaredReturnType`(仅 declared==derived 时) | **证伪** ✗:夹具仍逐字节相同 ✓ |
| ③「`typeDepth - 1` 在顶层为 -1 ⇒ 写到负深度」 | 把深度夹到 ≥ 0 | **证伪** ✗:夹具仍相同(IR 的 +1 只是那条注释 ✓)、探针/数字不变 ✓ |

⇒ **三段读到的登记代码对「用户程序顶层的函数绑定」根本没有执行** ✗ —— 我读的 `inferStmts` Let 分支不是
那条路径 ✓(而 std 成员那条路确实是通的 ✓,这与既有现象一致 ✓)。

**下一步(不再猜,继续打现场)** ✓:**量测要打在分析内部** —— 在 `inferStmts` 的 Let 分支里累加一个
「登记尝试/通过」计数 ✓,再**照 `typeRepReport()` / `typeNsReport()` 的既有先例**用**导出函数**把它交给
发射端打印 ✓(不要用裸数组跨模块 ✓ —— 那会撞上「导入模块须 export」的规矩 ✓)。一次就能看清真正走的是哪条
路径 ✓、以及用户函数为何没被登记 ✓。

**⑲.0c 链接点的改法也无效(已回滚)** ✓:按 ⑲.0b 的方向改 `types.ql:841` —— 它原来读
`s.value.returnType` ✓(用户函数从不填这个字段 ✓),我改成「**declared == derived 时登记
`declaredReturnType`**」✓(只登记**被证明为真**的声明,保健全 ✓)。结果:

- 验收夹具**依旧逐字节相同** ✗(IR=193917、`@ql_tag`=3660 ✓);
- t20 探针 528/70/92 ✓、`clang` 0 error ✓、动态除数 ✓、输出 20 ✓、**IR 与机器指令全不变** ✓。

⇒ **注册依然没有发生** ✗ ⇒ 「字段名对不上」这个假设**不够** ✓。下一步不要接着猜 ✓(已经猜错两次 ✗):
**在注册处把现场打成一个 IR 注释** —— `s.name` / `declaredReturnType` / `derivedReturnType` / `typeDepth` /
`assignedNames` 五个值 ✓(纯量测、不改行为 ✓,与本分支一贯做法一致 ✓)—— 一次就能分清是「字段没值」✗、
「declared ≠ derived」✗ 还是「读写深度错位」✗。已回滚,树回到 `a97f3a5` ✓。

**⑲.0b 实测更正(推翻 ⑲.0,以本小节为准)** ✓

单文件夹具(同一程序,只差 `: Number`):

```qlang
let f = (n: Number): Number -> { n + 1; };   // 另一版不写 `: Number`
let x = f(1) + f(2);
println(x);
```

两版发射结果**逐字节相同**:`IR=193917`、`@ql_tag=3660`,逐行一致 ✓ ⇒ **声明的返回类型没有传到调用点** ✗。
反证很清楚:若传到了,`f(1) + f(2)` 两侧都将是静态 Number ⇒ 走 `bothNum` 快速路径 ⇒ 那两处派发 tag 测试
本来就该消失 ✓。

⇒ **⑲.2 成立,⑲.0 不成立(以 ⑲.2 为准)** ✓。定位方向:`types.ql:788` 注册 `typeFnResults` 时读的是
`s.value.returnType` ✓,而**用户函数的这个字段很可能根本没被填**(`returnType` 只走了 std 成员/模块索引那条
路 ⇒ `callee.memberReturn` ✓)⇒ 要么把 `declaredReturnType` 填进 `s.value.returnType`,要么在注册处直接用
`declaredReturnType` ✓。

**这个夹具从此就是那条链的验收工具** ✓:改完之后,带注解版与不带注解版**必须开始出现差异**(IR 行数与
`@ql_tag` 数都要更低 ✓);仍相同 ⇒ 链接点找错了 ✓。

**⑲.1 首批注解(已落地 `cc7c57e`)** ✓:`stdlib/decimal.ql` 的 `decimalCompare` / `decimalCompose` /
`decimalNumber`(解析路径枢纽)补 `: Number` —— 三者**永不返回 Error**,声明属实;bundle 已重生成
(diff 仅此三处,96470 → 96494 字节)。验收:探针 **528/70/92 与基线一致** ✓;`clang -O2 -S` **0 error** ✓;
动态除数用例仍报 `DivisionByZero` ✓;输出仍 `20` ✓;**IR 与 `-O2` 机器指令均 ±0** ✗。按规矩(零收益也要加,
只有负收益才不加)保留 ✓。

**⑲.2 本批真正的产出:定位了 ⑥ 的阻塞点** ✓ —— **「声明返回类型 ⇒ 调用点可信」这条链没接通** ✗:

- 没有返回注解的函数**本来就不发射返回边检查** ⇒ 加注解**不新增**代码 ✓;
- 调用端也**没有**因为被调者声明了 `Number` 而获得信任 ⇒ 检查**也没减少** ✓;
- 探针一字未变即是证据 ✓。落点在 `types.ql:691-700`:调用点类型取自 `typeFnLookup(callee.name)` 与
  `callee.memberReturn` —— **只有 std 成员那条路是通的**,普通函数绑定不在内 ✗。

下一步:把 `declaredReturnType` 登记进 `typeFnResults`(覆盖普通函数绑定),调用点才真正获信 ✓ ——
这同时是 Error 设计「类型不说谎」的前提 ✓。

**⑲.3 panic:三条规矩的归属(核对 Rust 后修正)** —— 我的初稿把三条都写成「Rust 的规矩」✗,核后:

| | 措辞 | 归属 |
|---|---|---|
| **R1** | 每个会 panic 的操作**必须**有可检查配套(`a[i]`↔`a.get(i)` ✓、`unwrap`↔`?` ✓、`checked_add`↔`+` ✓) | **本项目硬性规则** ✓(照 std 惯例加强;Rust 编译器并不强制 ✗) |
| **R2** | panic 只用于契约违反;数据失败一律 `Result` | **Rust 官方指导** ✓(std::panic 文档原文:「Panic for genuine programmer errors — broken invariants, indices out of bounds… Don't panic for expected failure modes like a missing file or invalid user input — those should return Result」) |
| **R3** | panic 集合尽量小;每取消一个失败就少一个坑 | **本项目原则** ✗(Rust 无此量化要求) |

**Rust 自己走形的三处(引以为戒)** ✓:

1. **整数溢出**:debug **panic** ✓ / release **wrap** ✗ ⇒ *同一份代码在两种构建下行为不同* ⇒ 我们若要动
   `/0` 之类,**必须选定一种行为,绝不做 build-mode 依赖** ✓;
2. **OOM**:`alloc` 失败是 **abort** ✓(一个数据条件被当成不可恢复)⇒ 与我们对 `ql_alloc` 的判定一致 ✓;
3. **panic 可配置**:`panic = "abort"` 使 `catch_unwind` 失效 ⇒ 我们**固定 abort**,比 Rust 更简单 ✓
   (也就没有「可被抓住的 panic」那套复杂度 ✓)。

出处:[std::panic 文档](https://rustdocshub.com/std/panic/) ✓、[learnrust 12.5](https://learnrust.net/chapter-12/when-to-panic/) ✓、
[programmingline panic! 指南](https://learn.programmingline.com/learn/rust/rust-panic) ✓。

**⑲.4 panic 在本仓的落地形状** ✓(尚未实现):`panic(kind, msg)` = 物化带**位置 + 消息**的 Error +
`__exit_error` + `unreachable` ⇒ **零新机制**(发射器在「顶层未处理错误」处已经就是这么发的 ✓)。
现存契约违反的承载者是 `__op_zone_error` / `__neg_error` / `__pos_error` / `__arity_error` ✓ —— 它们今天
**返回** Error ⇒ 进入类型 ⇒ 处处检查 ✗;改成 panic ⇒ **冷终结符 ⇒ 不产生错误边** ✓ ⇒ 那 1 521 点 / −31 %
才有结构性出路 ✓。顺序:**先加原语(不改任何行为)** ⇒ 再**逐类**改(每类**先补配套** ✓),每类仍按
「探针 → 合法性 → 行为 → IR + `-O2`」验收 ✓。

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

