# Object/array type names — what the analysis may conclude

Status: design note, settled with the author. Supersedes the earlier "lattice" framing.
Background: `unboxed-values-handoff.md` §5⑥a/§5⑨ (annotating a helper `: Object` made the
**interpreter** reject a plain object; the compiler only *looked* fine because it proves the return-edge
check dead when the declared name equals the derived name).

## 1. The forms

| form | runtime entity | is a type value? | notes |
|---|---|---|---|
| `Array`, `Object` | `__arr_ctor`, `__obj_ctor` (`aot/runtime.ql:1907-1908`) | **no** | *constructors*. Having no `check` is **expected**. They exist to derive types: `Array(T)`, `Object(schema)`, `Object(pred)` (`aot/runtime.ql:1033/1064/1099`) |
| `Array(T)` / `Object(...)` | a fresh type value built by the constructor | **yes — required** | **what a constructor produces must be a type** (it carries the `check` that enforces element type / schema / predicate) |
| `AnyArray`, `AnyObject` | `{check: __pred_array}` / `{check: __pred_object}` (`aot/runtime.ql:1347-1348`) | yes | *concrete* types, on the same footing as `Number`: members may be of any type |
| `[1, 2]` / `{a: 1}` | a plain array/object value | — | belongs to the *family*; the analysis tags it with a family label (today `Array` / `Object`) |
| `Number` `String` `Boolean` `Null` | `typeScalar` (`aot/types.ql:12`) | yes | scalars: single machine word, unboxable |

So `Object.check` not existing is not a defect — it is what a constructor is. The defect would be a
constructor whose *product* lacks `check`, and that is not the case.

## 2. The rule (the simplification that settles this)

**Only the designated types get special treatment; everything else is boxed.**

- *Representation*: a small designated set gets the raw/unboxed treatment (today: `Number`). Every
  other type — `AnyArray`, `Object(schema)`, `Array(Number)`, anything derived — is **boxed, always**.
  No ordering, no lattice, no interchangeability question. This is already the shape of
  `staticRep` / `unboxType`.
- *Static consistency*: the declared-vs-derived comparison is meaningful **only among designated
  types** (there, name equality means something). Inside the object/array family it must **not** fire:
  two `AnyObject`s are not interchangeable (member types differ; `Object(schema)`/`Object(pred)` are
  narrower than `AnyObject`), so the only statically knowable fact is *family membership* — everything
  narrower is a runtime verdict.

## 3. What still needs a judgement, and which one

1. **Family label for member rules.** `.length -> Number` on an array receiver (`aot/types.ql:585`)
   needs to know the receiver is an array. It needs a *family label* only — not a type lattice — and the
   label the literal already gets is enough.
2. **Applied constructors are types.** `Array(Number)` / `Object({a: Number})` are valid annotations and
   must be recognised as types (so their `check` runs). Today `annotationBuiltinName` resolves only
   *bare* builtin names, so these become "" — the annotation is **inert** (no check, no information).
   That is the gap to close; it is also the precondition for point 1 to be usable on annotated values.
3. **Bare constructors are not annotations.** `: Array` / `: Object` name a constructor, not a type, so
   they are **invalid** as annotations → **compile-time diagnostic** ("`Array` is a constructor, not a
   type; use `AnyArray` or a constructed form"), rather than a silently inert annotation or a runtime
   surprise. This is the mistake that produced §5⑥a, and a diagnostic catches it at once.

## 4. Implementation list

1. *(removed — renaming the literal's derived label to `AnyObject`/`AnyArray` is **not** needed: the
   family is never compared statically.)*
2. Confine the declared-vs-derived consistency check (`aot/types.ql:675`) to designated types.
3. Recognise applied constructors as type annotations (annotation reader), so `Array(T)`/`Object(...)`
   are no longer inert.
4. Diagnostic for a bare-constructor annotation (`: Array` / `: Object`).
5. Fix `aot/runtime.ql`'s four `: Array` returns → `: AnyArray`; re-audit `t13_bindings.ql:56/60`
   (`: Array(Number)` / `: Object({a: Number})` — the design's intended spelling, must keep working).
6. Member rules (`.length`) keep using the family label from derivation.

**Empirical note (measured, both engines):** the four `: Array` returns break nothing *today* —
`std.Object.keys({a:1,b:2})` returns a real array (`isError` false, `.length` 2) under both the
interpreter and the compiler — because the analysis derives `Array` for the return value, so the
declared name equals the derived name and the return-edge check is proven dead and never emitted. They
are therefore *inert*, not effective, which is exactly why §3.3 applies.

Sequencing: 2 → 4 (small, self-contained) → 3 → 5 → resume the std annotation campaign (object/array
returns become annotatable).

## 5. Measured status after rules 2/4/5/6 + the next cost to remove

Landed: family-aware consistency (2), the constructor diagnostic (4), the four `: Array` returns →
`: AnyArray` (5), the family label in `.length -> Number` (6). IR **±0** (`194812`), and:

- `let x: Array = [1, 2];` ⇒ **CompileError** "Array is a constructor, not a type: use AnyArray for any
  Array, or a constructed form like Array(Number)" (position points at the annotation).
- `: AnyArray` / `: AnyObject` are accepted; the interpreter's always-on return check now *passes* for
  them (`AnyObject.check` exists — verified: `t19_literals` prints `true` again with the annotated
  library).
- **But** annotating object returns costs **+164 IR** (`194812` → `194976` for two functions): the
  declared name (`AnyObject`) never equals the derived name (`Object`), so the return-edge check is
  never proven dead and is emitted at each return edge (~82 lines each).
- **Next step to make object/array annotations free:** extend the emitter's `proven` rule to the
  family — `declared == "Any" + X && derived ∈ family(X)` ⇒ the check is dead, which is sound because
  `AnyX` accepts *every* member of the family (that is what `__pred_object`/`__pred_array` mean). This
  is the family analogue of the scalar rule and removes the +164.

## 6. Decision: do **not** implement the `proven` family extension yet

*(Author, this session: "Object和Array绑到Any我不确定以后加功能会不会出事".)* The concern is
forward-looking: equating the *base* names (`Object`/`Array`) with the *widest concrete* types
(`AnyObject`/`AnyArray`) in order to elide checks bakes an equivalence into the compiler that a future
feature may invalidate. So:

- the `proven` predicate stays **name equality** (`declared == derived`) — no family case;
- **object/array return annotations stay deferred** (they cost +164 today ⇒ net-negative ⇒ skipped per
  the rule); the std campaign proceeds with scalars, which are free and verified;
- what *did* land (rules 2/4/5/6) is deliberately **weaker** than that equivalence, and does not assert
  the two names are the same type:
  - rule 2 only **abstains** from reporting a mismatch *inside* the family (the runtime check decides);
  - rule 6 uses a **family label** so member rules (`.length`) still fire on the concrete name;
  - rule 4 turns the invalid spelling (`: Array` as an annotation) into a compile error;
  - rule 5 gives the runtime's array-returning functions a *valid* annotation (`AnyArray`); note
    `Array(String)` would be **more precise** and would cost, because its check would run.

If the type system later settles that the base/concrete pairing is stable, this decision can be
revisited — the note keeps both the mechanism and its measured price (+164) so the trade-off is not
re-derived from scratch.
