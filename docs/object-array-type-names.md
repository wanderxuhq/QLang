# Object/array type names — what the analysis may conclude

Status: research note (pre-implementation). Motivates the `.length`-style member rules and the
declared-vs-derived consistency check. See `unboxed-values-handoff.md` §5⑥a/§5⑨ for how this came up:
annotating a library helper `: Object` made the **interpreter** reject a plain object, while the
compiler only *looked* fine because it proves the return-edge check dead when the declared name equals
the derived name.

## 1. The forms (as they exist in the runtime and in the language)

| form | runtime entity | is a type value? | notes |
|---|---|---|---|
| `Array`, `Object` | `__arr_ctor`, `__obj_ctor` (`aot/runtime.ql:1907-1908`) | **no** | *constructors*: applied to derive a type — `Array(T)`, `Object(schema)`, `Object(pred)` (`aot/runtime.ql:1033/1064/1099`) |
| `AnyArray`, `AnyObject` | `{check: __pred_array}` / `{check: __pred_object}` (`aot/runtime.ql:1347-1348`) | **yes** | *concrete* types, on the same footing as `Number`: members may be of any type |
| `Array(T)` / `Object(...)` | a fresh type value built by the constructor | yes | each application yields a **distinct** type; its `check` enforces the element type / schema / predicate |
| `[1, 2]` / `{a: 1}` | a plain array/object value | — | belongs to the *family*; today the analysis names it `Array` / `Object` — i.e. it reuses the **constructor's** name for a value type |
| `Number` `String` `Boolean` `Null` | `typeScalar` (`aot/types.ql:12`) | yes | scalars: single machine word, unboxable |

Consequence of the third row: `Object.check`/`Array.check` do not exist — that is why `Object.check(o)`
returns an *error* in **both** engines (verified with a minimal repro), and why it is not an
interpreter bug.

## 2. Are two `AnyObject`s interchangeable? (the open question)

**No — and the same for `AnyArray`.** "Any members" describes what is accepted, not what is *known*:
two values the analysis both calls `AnyObject` may hold different member types, and a value that came
from `Object(schema)`/`Object(pred)` is *narrower* than `AnyObject`. The direction matters:

- `AnyObject` **accepts** a derived object value (it is still an object) — so a declared `: AnyObject`
  is satisfied by any object.
- A derived type does **not** accept an `AnyObject` value in general — its `check` may reject it. That
  rejection is a *runtime* verdict; it must not be a compile-time error.

So the object/array family is **not a lattice of interchangeable names**; the only compile-time fact
available for a family value is *"it belongs to the family"*.

## 3. What the analysis may therefore conclude

1. **Family membership only.** From a literal, or from any value whose type is an object/array family
   member, the analysis may conclude "array" or "object" — nothing narrower. Member rules keyed on the
   family (`.length -> Number` on arrays, key indexing on objects) may fire on that basis.
2. **No narrow comparisons.** The declared-vs-derived *mismatch* check is sound for scalars (equality
   of names is meaningful there) but **must not** fire inside the object/array family: a derived
   annotation and a literal, or two different concrete members, are compatible-as-family and the
   runtime check decides the rest. Reporting a compile error there would reject valid programs (and it
   would have rejected `stdlib`'s own annotations).
3. **Applied annotations must be recognised as family members.** `annotationBuiltinName` only resolves
   *bare* builtin names, so `Array(Number)` / `Object({a: Number})` currently resolve to "" — the
   annotation is inert (no check, no information). Whatever the family predicate becomes, the
   annotation reader must classify applied constructors as family members before any rule can use them.

## 4. Implementation consequences (not yet done)

1. Literal derivation names: `tagType(node, "AnyObject")` / `"AnyArray"` instead of the constructor
   names `Object` / `Array` (`aot/types.ql:529/535`) — so that annotating with the *concrete* types is
   consistent with what the analysis derives.
2. A family predicate (`isArrayType(name)` / `isObjectType(name)`), used instead of name equality by:
   - the `.length -> Number` rule (`aot/types.ql:585`);
   - the declared-vs-derived consistency check (`aot/types.ql:675`);
   - the annotation reader, extended to cover applied constructors (§3.3).
3. Re-audit the existing annotations on this chain: `aot/runtime.ql`'s four `: Array` returns
   (`__obj_keys`, `__num_frexp`, …) and the fixtures using `: Array(Number)` / `: Object({a: Number})`
   (`aot/tests/t13_bindings.ql:56/60`), which are the design's intended spelling and must keep working.

Sequencing: this note first, then 1–3, then resume the std annotation campaign (object/array returns
become annotatable, and the concrete `AnyObject`/`AnyArray` names become referenceable).
