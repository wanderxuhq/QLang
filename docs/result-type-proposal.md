# A `Result(T, E)` type for QLang — design proposal

Status: proposal, for review. Nothing here is implemented yet.

## Motivation, measured

- Every value may implicitly be an Error, so every read/write pays an "is this an
  Error?" check: removing those checks shrinks a whole module by **19.5 %**
  (247,351 -> 199,072 lines).
- Not knowing types forces both a specialised and a general path at every operator:
  the same statement costs **21 lines** with known types and **62** without.
- The underlying defect is the one the user named: `Number` currently *means*
  "Number or Error", which is Java's `T or null` — the declared type is a lie and
  every consumer must handle the extra state.

## Key observation: this is smaller than it looks

Three facts about the current implementation make a Rust-style `Result` cheap:

1. **`?` already exists and is the propagation sugar.** `emitPropagateError` stores
   the error into the return slot and branches to the epilogue (or `__exit_error` at
   top level). There is no stack unwinding; propagation is a static branch. This is
   exactly "if Err, return it from the current function; otherwise yield the value".
2. **The runtime representation is already an unboxed sum.** A `%ql_value` is a
   tag plus a payload: an ordinary value, or tag 8 with the Error object. So
   `Ok(T)` *is* a plain `T` and `Err(E)` *is* the existing Error object — no wrapper
   allocation, no new representation, no new runtime work.
3. **A type value is just `{check: fn}`.** `let Number = { check: __pred_number };`
   and `std.Type.make(f)` build types as ordinary objects; `Array(Number)` and
   `Object({a: Number})` are library-level constructors. So a `Result(T)` type needs
   **no change to the type-system core** — it is a QLang function returning a
   `{check: …}` object.

Consequence: the work is a **typing** change (declarations, checks, and what the
compiler may assume), not a representation change.

## Design

1. **Representation: unchanged.** `Ok(v)` is `v`; `Err(e)` is the Error value.
   `Result(T)` therefore unboxes to `%ql_value` by construction — there is nothing
   to unbox.
2. **The type:** `std.Result(T)`, a QLang type constructor returning
   `{ check: (v) -> isError(v) || T.check(v) }`. QLang's only error carrier is the
   Error object, so the error side is fixed to `Error`; a two-parameter
   `Result(T, E)` can be added later if a second carrier ever exists.
3. **`?` semantics: unchanged.** `v?` already means "if v is an Error, return it
   from the current function; otherwise yield v" — which is precisely Result
   propagation over this representation. What changes is the *typing* of the
   result: after `?` the value is a `T`.
4. **The typing discipline** (the actual change):
   - a fallible binding or return is declared `Result(T)`; the annotation is
     enforced by the existing check machinery;
   - a `Number`-annotated binding can never hold an Error (already true since
     "a typed binding holds only its type", where a failed check propagates);
   - consuming a `Result(T)` as a `T` requires `?` — i.e. the failure must be
     acknowledged at the boundary, which is where Rust puts it too.

## What the compiler gains

- A binding known to be `Result(T)`: its Ok payload is a `T`, and after `?` it is a
  plain `T` — so the operator paths and the representation can be specialised
  (measured target for a typed `x + 1`: about 60 lines -> 2-3, against 21 for the
  statically-known case today).
- A value *not* declared as a `Result` cannot be an Error, so its per-value Error
  checks are provably dead — that is the 19.5 %, now justified by typing rather
  than by deleting the checks blindly.

## Migration, annotations first

- **A. Turn contagion off** — prerequisite for both models. Started: the read path
  no longer attaches checks (`contagion-off` branch, -9.8 %). Blocker: the
  interpreter is itself QLang and its expression handlers treat a propagating Error
  operand as an *exit* (`isExiting(right) -> return right`), so the two engines
  disagree; that is the interpreter-side alignment work.
- **B. Add `std.Result`** — a QLang type constructor plus documentation of `?` as
  its sugar. Small.
- **C. Annotate the std surface** — the fallible members get `Result(T)`
  declarations. This is a *declaration* change, not a rewrite: a library function
  that returns an Error value on failure already *is* the Err case.
- **D. Compiler specialisation** — recognise `Result` the way `Number` is
  recognised (a scope-aware name match), specialise through it, and drop the checks
  that become dead.
- **E. Optional later** — two-parameter/structural variants; tightening the
  interpreter's own error flow to match.

## Verification

- The existing suites, especially the position/trace ones (`t38`, `t40`,
  source-context), which are the sensitive ones for error diagnostics.
- Fixed point (stage2 vs stage3 IR) and the two engines agreeing on every fixture.
- New fixtures: `Result(Number)` accepts a Number and an Error and rejects a
  String; `?` through a call; and a soundness check that an Error cannot reach a
  `Number`-annotated binding.

## Open questions

- Static recognition of `Result` in the compiler (needed for specialisation) —
  same mechanism as the builtin type names, but it must not special-case the
  library: recognition is a scope-aware name match on the type value.
- Unannotated code keeps today's behaviour (fallback), so the change is additive.
- Whether `E` should ever be something other than `Error`.
- The interpreter's `isExiting`/`propagate` bookkeeping must keep serving `return`
  and `?` while no longer treating "an Error produced by an operation" as an exit.
