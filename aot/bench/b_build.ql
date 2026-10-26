// Allocation-dominated loop: one small object per iteration, plus field reads.
let run = (n: Number): Number -> {
  let total: Number = 0;
  let i: Number = 0;
  while i < n {
    let o = { kind: "Let", name: "x", value: i };
    total = total + o.value;
    i = i + 1;
  };
  total;
};
println(run(2000000));
