// Control-flow values, lexical scopes, and closures must match HOST and BOOT.
let classify = (n) -> {
  if n == 0 { "zero"; }
  else if n == 1 { "one"; }
  else if n == 2 { "two"; }
  else { "other"; };
};
println(classify(0));
println(classify(1));
println(classify(2));
println(classify(3));
let outer = 10;
let closure = () -> 0;
if true {
  let outer = 20;
  let inner = 30;
  closure = () -> outer + inner;
  println(outer);
};
println(outer);
println(closure());
let funcs = [];
let i = 0;
while i < 3 {
  let captured = i;
  let f = () -> captured;
  funcs[funcs.length] = f;
  i = i + 1;
};
let f0 = funcs[0];
let f1 = funcs[1];
let f2 = funcs[2];
println(f0());
println(f1());
println(f2());
let truth = (v) -> { if v { "T"; } else { "F"; }; };
println(truth(""));
println(truth("x"));
println(truth([]));
println(truth([0]));
println(truth({}));
println(truth(closure));
println(truth(null));
println(truth(0));
println(truth(false));
println(!std.Error.raise("K", "m", null));
let count = 0;
let fallback = () -> { count = count + 1; "fallback"; };
println(42 ?? fallback());
println(null ?? fallback());
println(false ?? fallback());
println(std.Error.raise("K", "m", null) ?? fallback());
println(count);
println((std.Error.raise("K", "m", null) ?? std.Error.raise("K", "m", null)) ?? 7);
let recover = () -> { let x = (std.Error.raise("K", "m", null) ?? 9)?; x + 1; };
println(recover());
let propagate = () -> { let x = std.Error.raise("K", "m", null)?; count = 99; x; };
println(propagate() ?? "propagated");
println(count);

// If expressions and computed callees (including curried calls).
println(if true { "then"; } else { "else"; });
let selected = if false { 0; } else if true { 17; } else { 99; };
println(selected);
println((if true { std.Error.raise("K", "m", null); } else { 1; }) ?? 11);
let curry = (a) -> (b) -> a + b;
println(curry(3)(4));
println(funcs[2]());
println(((x) -> x + 2)(5));

// Explicit returns from nested branches/loops must terminate the function.
let early = (x) -> {
  while true {
    if x > 0 { return x + 1; } else { return 0; };
  };
  99;
};
println(early(4));
println(early(0));

// Propagation evaluates a side-effecting operand exactly once.
let calls = 0;
let once = () -> { calls = calls + 1; calls; };
println(once()?);
println(calls);
