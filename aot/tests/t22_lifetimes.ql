// A local read now and later keeps the same value across other allocations.
let later = (x) -> {
  let a = x + 1;
  let first = a * 2;
  let noise = [x + 2, x + 3, { value: x + 4 }];
  first + a + noise[0];
};
println(later(10));
// Copying a value into another binding preserves the previous value on update.
let aliases = (x) -> {
  let a = x + 1; let b = a;
  a = a + 10;
  [a, b];
};
let pair = aliases(5);
println(pair[0]); println(pair[1]);
// A returned scalar or aggregate outlives the frame that constructed it.
let number = (x) -> (x + 1) * (x + 2);
let kept = number(3); number(20); println(kept);
let build = (x) -> { let a = x + 1; { value: a, more: [a + 1] }; };
let object = build(40); build(100);
println(object.value); println(object.more[0]);
// Captured frames and per-iteration bindings must remain distinct.
let make = (x) -> { let cell = x + 1; () -> { cell = cell + 1; cell; }; };
let f = make(3); let g = make(20);
println(f()); println(g()); println(f());
let closures = []; let i = 0;
while i < 4 {
  let local = i + 10;
  closures.add(() -> local);
  i = i + 1;
};
println(closures[0]()); println(closures[3]());
// A borrowed arithmetic operand must not leak into an aggregate result.
let stored = []; i = 0;
while i < 4 { stored.add((i + 1) * (i + 2)); i = i + 1; };
println(stored[0]); println(stored[3]);
// Repeated conditional/argument temporaries must not grow the native stack.
let loop = (limit) -> {
  let n = 0;
  while (n + 1) * 2 <= limit * 2 {
    if (n + 1) % 2 == 0 { let next = n + 1; n = next; }
    else { n = n + 1; };
  };
  n;
};
println(loop(1000));
// Return and ? leave stack frames safely, with heap results/errors retained.
let early = (x) -> { if x > 0 { return (x + 1) * 2; }; 0; };
println(early(4)); println(early(0));
let cause = () -> { let x = Error.raise("kept"); x + (3 + 4); };
let caught = cause(); println(caught.cause.message);
// Branch results, short circuit and fallback can themselves escape.
let choose = (x) -> if x > 0 { x + 2 } else { x - 2 };
let selected = [choose(3), choose(-3), false || (4 + 5), Error.raise("x") ?? (6 + 7)];
println(selected[0]); println(selected[1]); println(selected[2]); println(selected[3]);
println(std.JSON.stringify([true, false, 3.14159, -0]));
