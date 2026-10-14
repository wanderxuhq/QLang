# Unboxed values / compile-time reduction of emitted IR — **handover**

**Read this file first; it is meant to be self-contained.** Two companions hold the rest:

- **`docs/unboxed-values-log.md`** — the long session-by-session record: every measurement, hit count,
  dead end and war story, in the order it happened. It is the *evidence*; this file is the *map*.
- **`docs/object-array-type-names.md`** (+ `.zh.md`) — the settled design note for object/array type
  names (`AnyArray`/`AnyObject` vs the `Array`/`Object` constructors).

---

## 0. Take over in five minutes

| | |
|---|---|
| Branch | `unboxed-values` — **do not merge into `dancing-with-dragon` without the author's explicit OK** |
| Working tree | clean at the tip of the branch |
| Gates | both green: interpreter `ALL CHECKS PASS`, selfhost `ALL REQUESTED CHECKS PASS` |
| Headline metric | `/tmp/t20.ql` emitted IR **215 919 → 194 812 = −21 107 lines (−9.8 %)**, program output still `20` |
| Backup branch | `backup/nan-removal-stage1` — the reverted "no NaN/∞" attempt (see §6.3) |
| Suggested first read | §1–§2 (the goal and the rules), then §4 (what to do next) |

```bash
# 1. build the compiler under test — and read §7.1 BEFORE trusting any failure
/tmp/<verified-compiler> --emit-llvm aot/qlangc.ql aot/runtime.ql > /tmp/nN.ll
python3 aot/native_link.py /tmp/nN.ll -o /tmp/nN

# 2. the headline metric + the probe's hit counts
/tmp/nN --emit-llvm /tmp/t20.ql aot/runtime.ql > /tmp/ir20.ll
wc -l < /tmp/ir20.ll
grep -E '; typeRep|; rawABI|; located-error elided' /tmp/ir20.ll

# 3. the gates — both must pass (interpreter a few minutes, selfhost ~40 min)
python3 aot/run_interpreter_tests.py --compiler /tmp/nN     # expect "ALL CHECKS PASS"
python3 aot/run_selfhost_tests.py  --compiler /tmp/nN       # expect "ALL REQUESTED CHECKS PASS"
```

## 1. What this work is

QLang is a self-hosting language with **two engines** — a native/AOT emitter (`aot/qlangc.ql`) and an AST
interpreter (`bootstrapped/interpreter.ql`) — both gated by the two suites above. This branch makes the
**compile-time analysis richer, so the code generator can emit fewer instructions**:

> In the author's words: *"compile-time provides enough information that code generation can emit fewer
> instructions."*

The shape of every change on this branch: the analysis (`aot/types.ql`, run before any code generation)
computes types *and representations* and stamps them on the AST; the emitter reads those conclusions and
only those; whatever the analysis can prove dead is deleted outright.

Two families of levers, and the measured fact that drove the ordering:

- **(a) information ⇒ dead code** — a runtime test disappears because the analysis knows its answer
  (Error tests, type checks, slot checks). **Representation-agnostic, and measurably the bigger lever.**
- **(b) unboxing** — a value keeps its natural machine representation (`Number` → raw `double`) instead
  of a boxed `%ql_value`.

## 2. Non-negotiable rules

1. **The analysis computes; the generator consumes.** No generator-side inference, no second guess.
2. **Representation belongs to the value; boxing belongs to the use site.** A node's representation is
   decided once, in the analysis, and stamped on the node; a consumer that needs a box pays for it at
   that one site. Never rewrite a value's representation because one consumer wanted a box.
3. **One emission path per node**, chosen by a compile-time fact stamped on that node.
4. **Ordinary objects get no privileges.** `std` *declares* the interface in the language; the runtime
   may supply only low-level **mechanisms** (e.g. string indexing), never helper functions exposed onto
   `std`.
5. **A compile-time fact beats a runtime check** — and a runtime check beats a wrong silence. Prefer
   reporting a violation statically over emitting a check for it.
6. **Ask before changing a semantic rule.** (The author has reversed such decisions before; see §6.3.)
7. **Workflow per step:** report **hit counts first, then line counts**; commit only when **both** gates
   are green; keep the metric honest (the fixture's output must not change: it is `20` throughout).

## 3. Roadmap — the phases and the IR ledger

Metric: `wc -l` of `/tmp/t20.ql`'s emitted IR on the accepted seed. **Accepted baseline 215 919;
current 194 640 (−21 279, −9.9 %).** Phase A (already on `main`) accounts for ≈ another −6 900, so the
whole "compile-time information ⇒ fewer instructions" line is ≈ **−28 k**.

| step | commit | lines |
|---|---|---|
| B1 the runtime program is analysed too | `7a55cac` | −11 492 |
| B2 `.length -> Number` | `a3a4120` | −593 |
| B3 per-program probe (measurement) | `464f72c` | +4 comment lines |
| B4 error-test elision (`emitLocatedError`) | `9cceff7` | −1 929 (155 sites) |
| B5 return-type signatures | `47a4e97` | IR-neutral (no annotations in the corpus yet) |
| B6 general module resolution | `0b8e239` | +1 probe comment |
| B7 declared runtime signatures | `d5cc108` | −151 |
| B8 analysis completeness (the callee/args and the literals/aggregates/index/`if` gaps) | `4c9f0e2` + `047f390` | −3 150 / −1 274 |
| C1 consumer pass (computed nodes stay raw) | `2f847f6` | −871 |
| div/mod fast path (both sides statically `Number`) | `aceb23a` | −543 |
| B9 bind-level keying for the unbox decisions | `6b3a4cf` | −1 258 |
| family rules + a constructor diagnostic | `74019f4` | ±0 |
| scalar std annotations | `69d36a8` | −1 |
| guard post-fall-through narrowing (Error design, slice 1) | `2cbc2e5` | −172 (machine −1 465, −1.12 %) |

## 4. The ordered worklist — what to do next

**① §5⑥ — annotate `std` (the author's standing requirement).** `std` must carry author-declared
parameter *and* return annotations, even where that buys no IR; the only exception is a *net-negative*
annotation, which must be reported and skipped. Measured rules (do not re-derive them):

- **Return annotations are free** — when the declared type equals the type the analysis derives, the
  return-edge check is proven dead. Annotate returns freely.
- **A parameter annotation costs an inline check at *every* call site** (~18 lines per parameter ×
  call site) **unless the argument's static type is already proven**. `finite(n: Number)` is free (its
  call sites pass known Numbers); `casing(s: String)` / `matches(…)` are not (their arguments come from
  `s[i]`, and index results stay conservative). So annotate a parameter only where the call sites'
  argument types are proven.
- **Object/array returns are deferred** — today they cost **+164** (net-negative), see §6.2.
- **After any `stdlib/*.ql` edit you MUST regenerate the bundle** (`stdlib/bundle.ql`), or nothing you
  changed is in effect; `--check` validates freshness.
- Procedure: small batches (leaf-up chains, never single points), rebuild, measure the IR delta, keep
  the non-negative ones, and note the net-negative ones rather than keeping them.

**② §5⑩ — count, then elide, three family (a) candidates.** Add IR-neutral hit counters first (the
established pattern), then implement only what has a large hit count:

- the divide/modulo **cold path when the divisor is a statically non-zero literal** (`__op_div0` and its
  branch are dead);
- the **dispatch** when one operand's type is known (`"a" + b` cannot be the numeric path);
- `ql_truthy` on a condition whose value is a **known Boolean** (the raw-`i1` case is already done).

**② b — MEASURED AND REJECTED: do not remove the `llvm.lifetime.start/end` calls.** They are 10 442
lines of IR (5.4 %, half of all call lines) and look like pure noise, but they are what lets LLVM merge
stack slots: stripping them takes the IR from 194 812 to 184 368 lines and yet takes the **machine**
instruction count from 130 505 to **134 366 (+3 861, +2.96 %)** — with the program still printing `20`.
This is the cleanest demonstration of the measurement rule in §5: **an IR-line win can be a machine-code
loss.** Do not re-open it without new evidence.

**② c — the "error edge" after a call (counted next, not yet).** If the callee's declared return type
excludes `Error`, the caller's test of the returned tag is dead. The shape is now identified in the IR
(`call @ql_tag` + `icmp eq i64 …`) but a real count needs an **emitter-side counter** at the site that
emits the check (adjacency in the text does not work — the check is not the next line after the call).

**⑤ §5⑦ — the whole stdlib is linked: 189 of 280 functions (67.5 %) are reached only through closure
code pointers.** They are therefore *statically* undroppable (no analysis can remove them); only genuine
laziness/on-demand instantiation could. That is the ceiling of this lever, and it is a feature-sized
change — record it, don't start it.

**③ §5⑪ — the raw ABI (measured, needs a decision).** Declaring `: Number` parameters/returns raw
requires an ABI change; the numbers are already measured: ②b (raw returns) ≈ 170 call sites on declared
returns / 251 counting derived ones; ②c (raw parameters) is 0 today *because no parameter annotation is
effective yet* — it depends on ①. The emit-order constraint ("no forward `declare`") costs ~8 % of
call sites; the module is already 98.7 % direct calls. **Design sketch and the reason a single shared
entry cannot work are in the log, §5⑦/⑪.**

**④ §5⑬ — keep the builder hygiene** (§7.1) — it is not optional, it is what makes any of the above
debuggable.

**⑤ §5⑮ — the Error design (settled direction, not implemented).** Error may only be **carried** (by
`Result`/`Option`), never accepted by ordinary types ⇒ types are exact ⇒ the checks at every consumer are
provably dead (this is the only way the measured ~31 % error machinery becomes *systematically*
removable). Syntactic forms are made **total** instead of fallible (`/0` ⇒ IEEE, absence ⇒ `Null`,
interpolation ⇒ default rendering, type/annotation problems ⇒ compile-time rejection) ⇒ **no syntax ever
produces an Error value**, so neither "value poisoning" nor "invisible early exit" can arise. Errors then
exist only at the calls in the (c) set — parsing/conversion plus host I/O, ~8 primitives — with an
explicit exit (`?` to pass through, a test to settle). Criterion, the full failure inventory (9 syntactic
forms / 7 runtime primitives / 26 library `raise`s / 6 host primitives), the three-tier comparison and
②'s defects and premises are in the log §5⑮. **Its two premises:** full totality, and *declared
boundaries* (function signatures, module exports, FFI) — which is the real reason `std` must carry
author-declared type information. **Decisions still open:** `/0` as IEEE (drop `__op_div0`), absence via
`Null`, one name for the carriers, and the one global choice of propagation sugar. **Slice 1 has landed**
(`2cbc2e5`, −172 IR / −1 465 machine instructions): guard post-fall-through narrowing — `if !X.check(v) {
…always exits… }` narrows `v` to `X` and clears its error flag on the fall-through, so the checks that
were already dead are now emitted as nothing. The remaining slices (`/0` ⇒ IEEE, absence ⇒ `Null`) touch
written contracts and existing assertions, so they need an explicit decision first.

**Its shape: re-classify, do not re-implement.** Nothing about the *mechanism* needs rewriting — the Error
representation (tag 8, provenance) and the unrecoverable path are already exactly what the design wants:
`panic` = materialise an Error + `__exit_error` + `unreachable`, which the emitter *already* emits for an
unhandled top-level error, so `panic` is a new primitive of ~a dozen lines and **no new runtime**. What must
be redone is the *classification and the carrier*: the 7 runtime primitives, the 26 library `raise`s and the 9
fallible syntactic forms each move into one of four bins — (a) type-rejected, (b) total with a meaningful
value, (c) genuinely no value (in the type), (d) **panic** (contract violation) — plus the typing discipline
that makes a declared type *true* so the analysis can trust it. Do it one class at a time, each with the
four-step gate (probes → legality → behaviour → IR + `-O2`). Three rules for the panic side, with their real
provenance (**R1** companion rule = *our* hard rule; **R2** panic only for contract violations, data failures
always `Result` = Rust's official guidance; **R3** keep the panic set small = *our* principle), and Rust's own
three deviations to avoid (debug/release overflow behaving differently, OOM aborting, `panic = "abort"` making
`catch_unwind` useless — we fix abort and never make behaviour build-mode dependent) are in the log §5⑲.3.

**⑦ §5⑲ — verify, while working, whether annotated ordinary bindings already grant call-site trust.** The
wiring may already exist: `types.ql:788` registers `typeFnResults` from `s.value.returnType` for a *stable*
(never-reassigned) function binding, and call-site typing reads `typeFnLookup(callee.name)` — so the ±0 of the
first annotation batch (`cc7c57e`) may simply mean those call sites had no checks left to delete. **Do not
build a mechanism before checking.** Fold the check into any build that touches call-site typing: compile a
one-file fixture with an annotated ordinary function and count the tag/dispatch checks around its call site;
only if they survive is there something to wire.

## 5. How to build, measure and verify

See §0's commands. Two conventions worth calling out:

- **Never pipe the gates through `| tail`** — this is now a *must*, not advice: it bit us on `2cbc2e5`,
  where a `tail -5` pipeline buffered everything, the log stayed empty for the whole run, and a *stuck*
  suite was indistinguishable from a *slow* one (only a kill + an unbuffered re-run revealed that it had
  in fact been hung). Redirect to a file, or use `tee`; never `tail` a long-running gate.
- **Validate every lever at `-O2` as well as at the IR line count.** Measured facts: `clang -O2` takes the
  same emitted IR from 337 828 to **130 206** AArch64 instructions (−61.5 %), and 76 % of what it removes
  is memory traffic — so an IR-line win that only removes slot/box movement is largely *absorbed* by
  LLVM, and can even come back as a loss (see §4②b). The number that matters is
  `clang -O2 -S <ir> | grep -c '^\s\+[a-z]'`-style counting of **machine instructions**, not `wc -l`.
- The fixture's **program output must not change** (it is `20`); if it does, the change is wrong
  regardless of the line count.

## 6. Decisions taken, deferred, and reverted

1. **Taken.** Raw representations are decided by the analysis and stamped on nodes (C1: computed
   `BinaryOp`/`UnaryOp` nodes stay raw `double`/`i1`; raw slot writes touch only the payload word, so the
   frame layout and ABI are untouched — the slot stays a valid `NUMBER` box).
2. **Deferred — object/array return annotations.** They are net-negative today (+164): an `: AnyObject`
   return never matches the derived name `Object`, so the return-edge check is emitted. The fix would be
   to extend the emitter's "proven dead" rule to the family — but the author is explicitly unsure that
   equating the *base* names with the widest concrete types is safe as the type system grows, so it is
   **deliberately not done**. See `docs/object-array-type-names.md` §6.
3. **Reverted — "no NaN, no Infinity".** Landed as `4903d57` (+ `35257b3`), then undone by decision
   (`git reset --hard`); all of it is preserved on **`backup/nan-removal-stage1`**. The attempt's lasting
   findings (the five producers, the Error-as-argument rule, and the stage-2 sizing: 685 arithmetic
   sites, `constFoldable=0`, ≈ +1.4–2.7 k IR) are in the log §5⑫.
4. **Superseded.** The old "B8 = bulk-annotate the stdlib" plan: after the analysis-completeness fixes
   the compiler's own source resolves 109 std members with only 44 unresolved, all untypeable by design
   (`Error.raise`, `String.fromCodePoint`, the curried `String.codePointAt`) — so bulk annotation buys
   nothing; §4①'s targeted batches are what remains.

## 7. Traps (read before debugging)

1. **Builder hygiene.** The library text is embedded at *compiler build* time, so a stale or mis-built
   compiler produces failures that are not in the sources. Rebuild with a builder whose gates were green,
   keep that chain, and **if a failure looks bizarre reproduce it with a second, independently built
   compiler before investigating**. Signature of this class: `CompileError …:1:1: Expected ']' after
   array` — a *parse* error at a bogus position (the text being parsed is the embedded library, so the
   position belongs to the entry program). Three attempts were wasted on this.
2. **An Error as a call argument is rejected** (`TypeMismatch: attempt to pass error value as
   argument`), so a test written as `check(<call that can now error>, …)` **silently stops counting** —
   the call never runs, the counter never increments, and nothing is printed. Inspect inline instead
   (`isError(x)`, `x.type == "..."`) or short-circuit (`!bad && …`). This applies to *any* future change
   that turns a silent value into an error.
3. **The analysis must *reach* a node before a rule about it can fire.** When a "known type" lever
   under-delivers, first check whether the traversal ever visits the node — that gap was worth −4 424
   lines (the B8 work).
4. **Bindings, not names.** The unbox decisions are keyed by binding identity (`s.bindId`), never by
   "this name is assigned somewhere in the program" — the latter silently disabled every existing
   stdlib annotation (log §5⑨).
5. **Do not attach node references to AST nodes.** The emitter walks every property of a node in places;
   a node-valued property creates a cycle and the walk never terminates. Keep compiler-internal tables
   (keyed by a numeric id) instead — this is why the binding graph lives in `typeBindTable`.
