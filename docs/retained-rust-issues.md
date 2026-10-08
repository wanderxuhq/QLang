# Retained Rust implementation: deferred discrepancies

Per the current project direction, prioritize the QLang compiler/runtime and
self-hosted interpreter. Record Rust discrepancies instead of repairing them,
unless they block QLang work and cannot be handled in the QLang layer. Existing
Rust changes from earlier milestones are retained.

## Array operations (2026-09-26)

- `src/stdlib/mod.rs`: `Array.get` casts fractional indices to integers, and NaN
  may become index zero. QLang get requires a finite integral index and returns
  null for invalid/out-of-range indices. The QLang interpreter performs this
  operation itself so Rust bootstrap execution cannot reintroduce truncation.
- `Array.indexOf/includes` use Rust `Value::PartialEq`, which recursively compares
  Arrays/Objects. This differs from the language's `==` reference identity and
  may recurse indefinitely for cycles. The QLang runtime and core interpreter
  use scalar equality / reference identity without traversing aggregates.

These Rust sources were not changed for this Array work. The QLang regression
fixture is `aot/tests/t29_arrays.ql`; it is a language contract, not a requirement
that the deferred direct Rust implementation currently passes every case.

## String.repeat (2026-09-26)

The retained Rust String.repeat casts its count to usize before calling Rust
String::repeat. Fractional/nonfinite/negative/very large inputs do not receive
the portable QLang library's validation and may truncate, saturate or attempt
unreasonable allocations. No Rust repair is part of this work. The portable
`stdlib/string.ql` uses its own QLang validation and concatenation algorithm,
including a documented scalar-count resource limit, on either execution path.


## Ordinary QLang library calls

Migrated String and Array members are ordinary QLang closures in the QLang core and LLVM
programs. They follow ordinary partial application rules (for example,
`std.String.length()("x")`), rather than retained Rust native exact-arity/name
metadata rules. No library-name exception is added to the LLVM dispatcher.
The retained direct Rust namespace is not automatically replaced by the QLang
bundle; the Rust-hosted QLang core loads the shared library itself.

## Newline after a binary operator

The retained Rust parser rejects a newline after `||` in an `if` condition
(`UnexpectedToken(Newline)`), while the QLang parser accepts it. This surfaced
while bootstrapping the numeric lexer. The source condition was kept on one
line so the retained bootstrap path still works; Rust was not changed.

- Computed `import (expression)` is now parsed by the QLang parser for native
  extension loading. The retained Rust parser/loader does not implement this
  form; it does not block compiling the QLang compiler with the existing host.

- The retained Rust `--compile` convenience driver's raw Clang command does not
  export the host runtime symbols required by native extensions. Extension
  hosts must use the QLang compiler plus `aot/native_link.py`, which exports the
  leaves and performs ELF checks. This does not block the authoritative QLang
  build path, so the Rust driver is unchanged in this round.

- Object-key iteration order differs: the retained host preserves insertion
  order, while the current native table enumerates hash buckets. ABI generation
  now reorders into preallocated slot storage, independent of either traversal.
  A direct probe confirmed both runtimes reject sparse Array assignment; this
  was a QLang compiler ordering assumption, not a Rust bounds-check bug.

## Negative-zero display on the retained host

The retained host renders `-0.0` as `0` through Number.toString, string
interpolation and println, while its JSON.stringify preserves `-0`. A four-line
probe reproduced exactly `0`, `0`, `0`, `-0` (exit0;
`target/number-rendering-check/retained-rendering-probe.log`). The numeric
integer-display fast path in src/value.rs drops the sign. This can also affect
QLang-core output when that core is hosted by Rust. Rust remains unchanged;
native QLang rendering verification uses the LLVM runtime and a newly compiled
QLang core, including negative-zero round trips. Do not claim the retained-host
rendering fixture passes based on those native results.

## Function-only return (2026-10-05)

The approved QLang rule permits `return` only in a lexical function body. The
retained Rust parser still constructs ReturnStmt without checking function
context (`src/parser.rs`, `parse_return_statement`); this is a deferred parser
discrepancy, identified by source inspection. It does not block the shared
QLang parser or the native self-hosted build. No Rust change is included.

## Approved mechanism parity added to the host (2026-10-07)

Two new language mechanisms were approved by the user, and the portable QLang
library calls them, so the Rust-hosted QLang core must expose them too (per the
"Ordinary QLang library calls" note above, that core loads the shared library
itself). `src/stdlib/mod.rs` therefore now provides:

- `String.fromCodePoint(n)`: the inverse of `codePointAt`, rejecting
  non-integral, out-of-range and surrogate code points with RangeError. Mirrors
  the AOT runtime's `__s_from_codepoint`.
- `Number.frexp(x)` -> `[mantissa in [1,2), exponent]` and `Number.ldexp(m)(e)`
  -> `m * 2^e`, staged for subnormal/overflow exactly like the AOT
  `__math_scale` (both built from the same bit assembly as `ql_number_bits`).

These are additive parity for approved mechanisms, not repairs of a
discrepancy. The host's `Number.toString` still renders `-0` as `0` (see the
negative-zero section above), so on the host the library's only oracle for a
negative zero is that text; AOT rendering — the product path — is correct.
