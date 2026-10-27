// String element access in a hot loop: `s[i]` must build a one-character string.
// With interned ASCII chars it is a shared box instead of a fresh allocation.
let scan = (s: String): Number -> {
  let n = s.length;
  let total = 0;
  let round = 0;
  while round < 200 {
    let i = 0;
    while i < n {
      if s[i] == " " { total = total + 1; };
      i = i + 1;
    };
    round = round + 1;
  };
  total;
};
let source = std.fs.readFileText("aot/runtime.ql")?;
println(scan(source));
