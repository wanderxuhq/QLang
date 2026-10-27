// Untyped function called in a hot loop: with the generic ABI every call marshals
// its arguments through a stack buffer; the register ABI passes them directly.
// This is the discriminating benchmark for that change (see probes §30).
let step = (x) -> x + 1;
let run = (n: Number): Number -> {
  let acc = 0;
  let i = 0;
  while i < n { acc = step(acc); i = i + 1; };
  acc;
};
println(run(5000000));
