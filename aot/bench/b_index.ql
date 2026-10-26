// Array element access in a hot loop. `chars` is annotated so the compiler knows
// the receiver is an Array; without the inline fast path every element read is a
// generic `__get_index` dispatch.
let scan = (chars: AnyArray): Number -> {
  let n = chars.length;
  let total = 0;
  let round = 0;
  while round < 500 {
    let i = 0;
    while i < n {
      if chars[i] == " " { total = total + 1; };
      i = i + 1;
    };
    round = round + 1;
  };
  total;
};
let source = std.fs.readFileText("aot/runtime.ql")?;
let chars: AnyArray = std.String.split(source)("");
println(scan(chars));
