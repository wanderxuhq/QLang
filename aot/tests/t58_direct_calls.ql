// Direct calls: only immutable, leaf, unannotated-parameter functions are
// direct-called; every other form must keep the generic path's semantics.
let add = (a, b) -> a + b;
let i = 0; let s = 0;
while i < 5 { s = add(i, 1); i = i + 1; };
println(s);

// A safe direct call with literal arguments.
println(add(2, 3));

// Alias: not the direct-call binding, so the generic path must be used.
let alias = add;
println(alias(10, 2));

// An Error argument is rejected by the generic argument policy.
let z = 0;
println(isError(add(1 / z, 2)));

// Partial application stays generic.
let partial = add(5);
println(partial(2));

// A non-leaf function is not direct-called; its inner call must still work.
let twice = (a) -> add(a, a);
println(twice(3));

// Parameter annotations are owned by the dispatcher, so this stays generic.
let annotated = (a: Number, b: Number): Number -> a + b;
println(annotated(2, 4));
println(isError(annotated("x", 1)));

// Assigning the binding anywhere disables direct calls for that name.
let mutable = (a, b) -> a + b;
mutable = (a, b) -> a - b;
println(mutable(5, 2));

// Return annotations are checked at the return edge and do not block direct calls.
let ret = (a, b): Number -> a + b;
println(ret(7, 8));

// A leaf body may still assign captured state; the direct call preserves it.
let counter = 0;
let bump = (a) -> { counter = counter + a; counter; };
println(bump(2));
println(bump(3));

// A leaf body can produce an Error; the direct call returns it unchanged.
let divide = (a, b) -> a / b;
let zero = 0;
println(isError(divide(1, zero)));

// A pure Number function with exactly one call site is raw-inlined: no
// closure/function body is emitted, and the loop body is just fadd.
let pure = (a: Number, b: Number): Number -> a + b;
let j = 0; let t = 0;
while j < 5 { t = pure(j, 1); j = j + 1; };
println(t);

// Redeclaration replaces the binding; an old direct target must not survive.
let pure2 = (a: Number, b: Number): Number -> a + b;
println(pure2(2, 3));
let pure2 = 9;
println(pure2);

// A value use (alias) must prevent raw inlining and keep a real function value.
let vpure = (a: Number, b: Number): Number -> a + b;
println(vpure(2, 3));
let vf = vpure;
println(vf(4, 5));
