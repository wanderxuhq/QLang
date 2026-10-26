let add = (a: Number, b: Number): Number -> a + b;
let compose = (a: Number, b: Number): Number -> add(a, 1) + b;
let i = 0;
let s = 0;
while i < 1000 { s = s + compose(1, i); i = i + 1; };
println(s);

let local = (x: Number): Number -> { let g = (y) -> y + x; g(1); };
println(local(5));

let fact = (n: Number): Number -> { if n < 2 { 1 } else { n * fact(n - 1) } };
println(fact(5));

let early = (x: Number): Number -> late(x) + 1;
let late = (x: Number): Number -> x * 2;
println(early(3));

let a = (n: Number): Number -> { if n < 1 { 0 } else { b(n - 1) + 1 } };
let b = (n: Number): Number -> { if n < 1 { 0 } else { a(n - 1) + 1 } };
println(a(4));

let selfAlias = (x: Number): Number -> { let g = selfAlias; if x < 1 { 0 } else { g(x - 1) + 1 } };
println(selfAlias(3));
