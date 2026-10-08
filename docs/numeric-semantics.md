# Native numeric semantics

The QLang frontend and LLVM emitter consume the same AST as the self-hosted
interpreter. Number values use IEEE binary64. Math algorithms, decimal parsing,
argument validation and language errors are implemented in `aot/runtime.ql`.
LLVM supplies primitive arithmetic, bit operations, integer remainder and value
representation operations. `runtime.c` exposes raw memory and operating-system
leaves, including entropy; it contains no Math algorithms or libm calls.

The addition of predefined `Infinity` and `NaN` names is undecided. Do not
introduce these global bindings during numeric syntax work. Existing nonfinite
results and conversion behavior below are separate from exposing global names;
this documentation records current behavior, not a decision to retain it.

## Operators and conversion

- Unary `+` evaluates its operand once and accepts only Number. It returns the
  Number unchanged, including the sign of zero; it does not coerce other types.
  Other types produce `TypeMismatch` and an Error operand is retained as cause.
- Unary `-` evaluates its operand once and accepts only Number. Other types
  produce `TypeMismatch`; an Error operand is retained as the cause. Negating
  positive zero produces negative zero.
- `%` uses the dividend's sign and truncation-based remainder. A zero divisor
  produces `DivisionByZero`, including for nonfinite dividends. NaN operands or
  an infinite dividend with a nonzero divisor produce NaN. A finite dividend
  modulo infinity returns the dividend. Exact multiples preserve signed zero.
- `&`, `|` and `^` first truncate toward zero and clamp to the signed 64-bit
  range; NaN converts to zero. The integer result converts back to Number.
  Large integer results may round because Number has 53 bits of precision.
- `Number.parseFloat` accepts a complete decimal string after trimming Unicode
  White_Space. Signs, leading zeros, leading/trailing decimal points, and decimal
  exponents are accepted when the significand has a digit. An exponent must
  have digits. Case-insensitive `inf`, `infinity` and `nan` are accepted.
  Malformed input, suffixes, hexadecimal syntax and non-string data produce NaN.
  Error arguments follow the usual function-call Error policy. Decimal numbers
  use the existing exact integer-limb conversion with one ties-to-even rounding.
  Overflow produces signed infinity; underflow preserves the sign of zero.
- NaN is an ordinary Number. It is unrelated to binding initialization.
  `null` is the initialized value of type `Null`; no new language value is added.

## Math

Math Number arguments are validated. `sqrt` rejects negative inputs and NaN
with `TypeMismatch`, following the existing core behavior, and preserves -0.
`round` breaks ties away from zero. `abs`, `floor`, `ceil`, `round` and `trunc`
handle signed zero and nonfinite inputs without an unsafe integer conversion.

`pow(base)(exponent)` supports fractional and negative exponents, subnormals,
overflow, signed zeros, NaNs and infinities. Finite negative bases with
nonintegral exponents produce NaN. Any base raised to zero is one; one raised to
any exponent is one. Zero raised to a negative exponent produces infinity,
with a negative sign for negative zero and an odd integral exponent.

`min` and `max` accept any number of positional Number arguments, including
zero and one. `max()` returns negative infinity; `min()` returns positive
infinity. Any NaN makes the numeric result NaN. All argument types are still
validated, including after a NaN; no string coercion or implicit Array spreading
occurs. Among equal zeros, max selects +0 if present and min selects -0 if
present; a singleton or a list containing only -0 preserves -0.

The ordinary call policy rejects Error arguments first, retaining the first
Error as the cause. Every argument expression is evaluated once, left to right,
before validation. Function aliases, imported members, computed callees and
higher-order calls retain these rules. The native dispatcher borrows the whole
argument list for a synchronous QLang reduction. The self-hosted interpreter
forwards the entire positional list through its internal native-call bridge;
user replacement functions retain ordinary user-call behavior.
The retained Rust implementation mirrors these contracts for bootstrap/library
compatibility; compiled Math algorithms remain in QLang.

Square root normalizes the binary exponent before Newton iteration. Integral
powers up to magnitude 64 use normalized double-double multiplication and a
separate exponent. General powers use double-double log/exp range reduction and
series evaluation. Sine/cosine use a 1216-bit fixed-point 2/pi constant to reduce
large finite inputs before evaluating small-argument series. Infinite or NaN
trigonometric inputs produce NaN. `sin(-0)` preserves -0.

These transcendental algorithms are not claimed to be correctly rounded for
every binary64 input. The deterministic suite permits 3 ULP for sqrt, 12 ULP
for sine/cosine, and 8 ULP for powers. On the 2026-09-26 sample set, observed
maxima at both optimization levels were respectively 1, 2, 2 and 0 ULP relative
to the platform reference. Zero signs, nonfinite classifications, decimal
parsing, remainder and bitwise results are checked exactly.

`Math.random()` builds a uniform 53-bit integer from seven OS entropy bytes,
then divides by 2^53 to obtain a Number in [0,1). QLang handles interrupted
calls and partial reads. Entropy failure returns `IOError`; there is no constant
or predictable fallback. The only new C leaf is the raw AArch64 Linux
`getrandom` syscall wrapper. Python and platform math functions are used only
as development-time test references, never by a compiled QLang program.

## Verification and remaining work

Run from the repository root with a compiler built from the current sources:

```sh
python3 aot/run_numeric_tests.py --compiler target/selfhost/stage2
python3 aot/run_json_numeric_tests.py --compiler target/selfhost/stage2
python3 aot/run_selfhost_tests.py --compiler target/selfhost/stage2 --self
python3 aot/run_interpreter_tests.py --compiler target/selfhost/stage2
python3 aot/generate_math_constants.py
```

`t25_numeric.ql` asserts 83 fixed language contracts independently of the Rust
implementation. The numeric runner adds 792 seeded boundary/random cases at
`-O0` and `-O2`, native-symbol checks, and entropy fault injection. The table
generator uses Machin's formula at two decimal precisions to reproduce all 76
base-65536 limbs; it is not needed to build or run native programs.

`t26_extrema.ql` adds 51 shared checks for variadic extrema, including aliases,
imports, user replacements, ordered evaluation, Error causes and special values.
It runs at both optimization levels in the numeric suite, in the native core
and self-host gates, and as a Rust compatibility integration test.

This work does not complete standard-library parity. Non-JSON finite-number display formatting,
validation of other standard-library functions, missing built-ins and source
positions in native diagnostics also remain. The memory manager is unchanged.

## Numeric source syntax (validation in progress)

The shared QLang lexer accepts decimal integers, leading/trailing decimal
points, decimal exponents with optional signs, and `0x`/`0X` hexadecimal
integers. Leading `+` and `-` are ordinary unary AST operators. Decimal
conversion uses the existing exact conversion. Hexadecimal integers keep
significand, guard and sticky bits and round once to binary64, ties to even.
Incomplete prefixes/exponents, identifier suffixes, and repeated decimal
points are rejected at the number's source location. `Infinity` and `NaN`
remain ordinary identifier tokens, without implicit global declarations.

`bootstrapped/tests/numeric_syntax.ql` covers tokens, spans, values, ASTs and
19 invalid forms. `aot/tests/t34_numeric_syntax.ql` covers direct execution,
unary validation/causes/side effects and signed zero (71 checks). The ordinary
selfhost/core runners include these fixtures; native validation is in progress.
