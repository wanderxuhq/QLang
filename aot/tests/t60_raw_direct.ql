// Raw direct functions: annotated Number parameters, no value use, and every
// call site exact-arity with Number non-Error arguments. The closure box is
// replaced by the definition environment pointer, and calls pass raw doubles.
let add = (a: Number, b: Number): Number -> a + b;
let v1 = add(1, 2);
let v2 = add(3, 4);
let v3 = add(5, 6);
let v4 = add(7, 8);
let v5 = add(9, 10);
println(v1 + v2 + v3 + v4 + v5);

// The raw entry resolves globals through its stored definition environment.
let base = 10;
let addBase = (x: Number): Number -> x + base;
println(addBase(1) + addBase(2));

// A leaf body may write captured state; the raw entry uses its own definition
// frame, so the write lands in the same slot the boxed path would use.
let counter = 0;
let bumpG = (x: Number): Number -> { counter = counter + x; counter };
println(bumpG(2));
println(bumpG(3));

// One Error-prone argument disqualifies every call site of the binding: the
// raw entry has no boxed argument policy, so the function stays generic.
let z = 0;
let add2 = (a: Number, b: Number): Number -> a + b;
println(isError(add2(1 / z, 2)));
println(add2(3, 4));

// Per-frame environments: each returned closure keeps its own definition frame.
let outer = (k: Number) -> {
  let addK = (x: Number): Number -> x + k;
  let get = () -> addK(2);
  get
};
let g1 = outer(10);
let g2 = outer(20);
println(g1());
println(g2());

// A value use disqualifies the binding and keeps a real closure value.
let val = (x: Number): Number -> x + 1;
let alias = val;
println(alias(5));

// Partial application disqualifies the binding: the raw entry has no boxed
// dispatch, so the whole function keeps the generic path.
let part = (a: Number, b: Number): Number -> a + b;
let half = part(1);
println(half(2));

// Writing a parameter disqualifies raw ABI (the slot would need re-checking).
let bump = (x: Number): Number -> { x = x + 1; x };
println(bump(1));

// A loop-defined raw function reads the current frame through its slot.
let i = 0;
let total = 0;
while i < 3 {
  let addI = (x: Number): Number -> x + i;
  total = total + addI(10);
  i = i + 1;
};
println(total);

// Zero-parameter functions keep the boxed path.
let zero = (): Number -> 7;
println(zero());

// Recursion is not a leaf, so the boxed closure is kept.
let fact = (n: Number): Number -> {
  if n < 2 { 1 } else { n * fact(n - 1) }
};
println(fact(5));

// An import can bind or overwrite the same name. That disqualifies direct/raw
// targets for the name, so the imported function (not the local one) is called.
let shadow = (x: Number): Number -> x + 1;
println(shadow(1));
import ./modules/raw_shadow.ql;
println(shadow(2));
