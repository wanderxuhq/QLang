// Per-character hot loop, function-scoped (the shape the lexer runs).
// `split("")` yields ["", c1, ..., cn, ""] — the same single-char strings the
// lexer used to build, without the boot-only toChars shim.
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
let chars = std.String.split(source)("");
println(scan(chars));
