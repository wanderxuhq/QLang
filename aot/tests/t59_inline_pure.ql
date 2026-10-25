// A pure Number function with one direct call site is raw-inlined: no closure
// or function body is emitted, and the loop body is just fadd.
let pure = (a: Number, b: Number): Number -> a + b;
let i = 0; let s = 0;
while i < 5 { s = pure(i, 1); i = i + 1; };
println(s);

// Inline target is invalidated by a later let of the same name.
let p = (a: Number, b: Number): Number -> a + b;
println(p(1, 2));
let p = 9;
println(p);

// A value use keeps the function value and disables inlining.
let q = (a: Number, b: Number): Number -> a + b;
println(q(2, 3));
let qa = q;
println(qa(4, 5));

// A function body emitted before a redeclaration must not keep a stale target.
let h = () -> 1;
let callh = () -> h();
let h = () -> 2;
println(callh());

// The same for an assignment after the caller body is emitted.
let m = () -> 1;
let callm = () -> m();
m = () -> 2;
println(callm());

// A captured free variable must prevent inlining: the function closes over the
// defining scope, not the caller's shadowed binding.
let g = 10;
let cap = (a: Number): Number -> a + g;
let run = () -> { let g = 100; cap(1); };
println(run());
