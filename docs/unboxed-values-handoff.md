# Handoff — Unboxed values / compile-time reduction of emitted IR

Status: work in progress, branch `unboxed-values`. Not merged. `dancing-with-dragon` untouched.
Audience: whoever picks this up next (human or agent). Everything below is meant to be
enough to resume without re-deriving anything.

---

## 0. Where things stand right now (read this first)

| Item | State |
|---|---|
| Branch | `unboxed-values` (working tree = `/root/projects/QLang`) |
| Last commit | `7a55cac` — runtime program now goes through the compile-time analysis (−11 492 IR lines) |
| Uncommitted | `aot/types.ql` — one new rule: `Array/String.length -> Number` (−593 IR lines) |
| Verification running | interpreter suite (`--compiler /tmp/n8`) + selfhost gate (`--compiler /tmp/n8`), started 2026-10-11 04:53 |
| Untracked noise | `_b.ql`, `.commandcode/`, `docs/compiler-next-steps.zh.md` |
| Merge policy | **Do not merge into `dancing-with-dragon` without explicit approval from the user.** |

IR line metric on the accepted fixture, all three points measured on the same seed:

```
/tmp/t20.ql    pre-runtime-analysis (n0/n3/n6)   215 919
               runtime analyzed (n7, commit 7a55cac)   204 427   (-11 492, -5.3%)
               + .length -> Number (n8, uncommitted)   203 834   (-593, -2.6% of the change)
program output in all three cases: 20 (unchanged)
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

### ① Per-program probe breakdown

Split the `; typeRep ...` counters by program (library / entry / module N / runtime). Without
this, the fuel numbers for the code we actually care about are invisible. Mechanical, IR-neutral
apart from the comment lines.

### ② Read-side Error-test elision (the big lever)

A read can produce an Error **iff some write could have put an Error there**. The analysis
already knows when that is impossible:

- the binding's static type is a builtin (`Number`/`String`/`Boolean`/`Null`) — an Error
  belongs to none of them; and
- every write to that binding has a statically known RHS type (this is the existing
  `runtimeTypeFree` predicate) — a mismatched write is stopped *at the write point*, so the
  slot either holds a legal value or control has already left with an error.

Then the read's test is dead. Stamp it on the node in the analysis (e.g. `cannotBeError`,
carried through a scope stack exactly like `staticRep`), and in the generator remove the
**whole block** — the tag fetch, the compare, the branch, the cold path and the `phi` — not
just the `ql_tag` call. `ql_tag` appears at many sites (grep shows ~180, 414, 530, 566–567,
596, 620, 1057, 1621, 1911, …); the binding-read path is the one to identify explicitly, and
several of those other sites belong to operator / statement-value paths that must not be
touched in this step.

Pools on the fixture (pre-runtime-era numbers, i.e. for the code we can actually unbox):
reads with a known type ≈ 309 (275 Number + 34 String), boxed binops with a known type ≈ 403
(111 arithmetic + 292 comparisons); the unknown pools (329 reads / 128 binops) keep their
tests.

Two traps, both paid for already:

- **Writes from closures / a different function body.** Judge against the *whole-program*
  write set (the analysis already tracks writes per namespace — `typeUnknownWrites`), not
  just the current body. `t35_scoped_modules` is the regression that catches this.
- **Shadowing.** Use the scope stack; the existing type-free path in the generator does the
  same thing (`curScope.typeFree`, `qlangc.ql:853–855`, `:901`), so mirror its structure.

Rough estimate of the payoff: ≈8 IR lines per elided test on top of what unboxing removes
(see §7).

### ③ Publish runtime member signatures into the cross-program index

Today the analysis resets its scopes per program, so even though the runtime is analyzed, the
library and the user program cannot see its member signatures; `ldexp`, `frexp`,
`codePointAt`, `Object.keys` etc. still resolve to unknown. Publish the runtime's member
objects (`stdNumber`, `stdString`, `stdMath`, `Number = {check}` …) into the existing
cross-program indices (`stdModuleBinds` / `stdFieldCall` / `stdFieldValue`).

The user's constraint here is explicit: **do not write a duplicate interface table.** If the
source can derive it, a second copy is the wrong answer (that was the original objection that
redirected this whole step from "declare an interface" to "analyze the runtime source").

### ④ Make runtime members total + parameter annotations

Runtime members currently may return `__err("TypeMismatch", …)` internally. Remove that
internal error return and annotate parameters, so their signatures become derivable and
total. Consequence to accept and handle: the error moves from a member-internal `TypeMismatch`
to a call-site `TypeCheck`, so affected fixtures change. (See §6 for the obligation this
creates for call sites.)

### ⑤ Drop the temporary runtime `check` predicate table

Added in `4dec1d5` as scaffolding for ④. Delete it once ④ lands.

### ⑥ Chain-annotate the stdlib

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
