// Known-safe propagation: a single-call pure Number function is proven unable
// to return Error, so the accumulator is no longer prone and the loop takes the
// inline/raw path without any new runtime check.
let add = (a: Number, b: Number): Number -> a + b;
let i = 0;
let s = 0;
while i < 1000 { s = add(s, i); i = i + 1; };
println(s);

// Proven-Number returns come back as raw doubles (arithmetic, condition, !).
let safe = (a: Number, b: Number): Number -> a + b;
println(safe(2, 3) * 2);
if safe(1, 2) { println("truthy"); };
println(!safe(0, 0));
let n = 0;
while safe(0, n) < 3 { n = n + 1; };
println(n);

// Division can return an Error: the return is not proven, so it stays boxed.
let zero = 0;
let divide = (a: Number, b: Number): Number -> a / b;
println(isError(divide(1, zero)));
println(divide(6, 3));

// Multiple call sites keep the function raw but do not feed safe-call
// propagation (which requires exactly one call site and no value use).
let twice = (a: Number, b: Number): Number -> a + b;
println(twice(1, 2));
println(twice(3, 4));

// A value use disqualifies the binding and keeps a real closure value.
let aliasFn = (a: Number, b: Number): Number -> a + b;
let af = aliasFn;
println(af(5, 6));

// Writing a parameter disqualifies raw ABI and safe-call propagation.
let bump = (x: Number): Number -> { x = x + 1; x };
println(bump(1));
