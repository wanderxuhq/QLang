# Object standard-library contracts

The supported Object APIs validate public inputs in QLang before reading native
hash-table memory. Their receiver must be an Object. `merge` validates the first
receiver before returning its curried function, then validates the second
receiver when that function is called. Errors are recoverable `TypeMismatch`
values, with ordinary `?` and unhandled-error exit behavior.

| API | Key / result contract |
| --- | --- |
| `keys(object)` | A new Array of keys. |
| `values(object)` | A new Array of stored values, preserving reference identity and Error values. |
| `merge(left)(right)` | A fresh shallow object; right-hand fields replace matching left-hand fields. Inputs are unchanged. |
| `hasOwn(object)(key)` | String keys test presence independently of the stored value. Other non-Error key types return false. |
| `get(object)(key)` | String keys retrieve the stored value; missing or non-String keys return null. |
| `field(object, key)` | Requires a String key; a missing field produces `UndefinedField` with the field name. |

An existing field holding null or an Error is still present. `get` and `field`
return a stored Error as data; they do not translate it into a missing-field
result. Normal call policy still rejects Error arguments before body validation
and retains the first Error as the cause. Key errors are therefore distinct
from an Error stored in the object. Object key enumeration order remains
unspecified across execution engines.

The native table probe reports a private slot index independently of the stored
value. The core interpreter preserves existing value wrappers when Object
projections retrieve interpreted values; functions remain callable and mutable
arrays/objects retain their aliases. Interpreted function records are not valid
Object receivers despite being represented internally by host objects. User
objects with fields named `type` or `value` retain their ordinary meaning.

This does not add an undefined value or change variable initialization rules.
It also does not complete the missing Object APIs listed in the main README;
other standard-library modules still need argument-validation work.

## Verification

```sh
python3 aot/run_object_tests.py --compiler target/selfhost/stage2
python3 aot/run_interpreter_tests.py --compiler target/selfhost/stage2
cargo test --offline --test object_stdlib
```

`t28_objects.ql` contains 98 fixed checks shared by direct AOT, the native core,
the Rust-hosted core and retained Rust compatibility. The dedicated runner
checks the fixture and eight unhandled invalid-input cases at both `-O0` and
`-O2`. Coverage includes invalid receivers and keys, both stages of currying,
Error causes, null/Error presence, shallow merges, retrieved functions,
reference aliases, wrapper-like user objects, empty/NUL/Unicode keys, table
growth and appending to a collected Array.
