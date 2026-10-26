// Call-dominated loop: one annotated-Number leaf call per iteration.
let add = (a: Number, b: Number): Number -> a + b;
let run = (n: Number): Number -> {
  let acc: Number = 0;
  let i: Number = 0;
  while i < n { acc = add(acc, i); i = i + 1; };
  acc;
};
println(run(2000000));
