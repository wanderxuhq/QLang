// QLang 数值契约驱动(不依赖 Python):792 行冻结语料 + O0/O2 + libm 符号 + 熵故障。
//
//   run_numeric [--compiler <c>] [--stdlib <dir>] [--root <repo>] [--tmp <base>]
//
// 覆盖原 Python 套件 aot/run_numeric_tests.py 的数值主体:
//   1) aot/tests/data/numeric_oracle.ql 是 Python 版 cases()(seed 20260926)的冻结
//      快照:parse 85 / mod 109 / and-or-xor 各 46 / sqrt 76 / sin-cos 各 101 /
//      pow 182 = 792 行。每行存 expected = m * 2^e 与 ULP 容差(3/12/8);
//      本驱动只用 std.Number.ldexp + 算术从 (m,e) 还原 expected,不用 std.Math。
//   2) 生成一个循环 rows 的 QLang 程序,分别 --opt 0/2 链接运行;每行输出
//      op、isNaN/isFinite/n<0、toString、frexp 的 (m,e)、JSON.stringify。
//      实际值用 ldexp(m,e) 精确还原;精确行按位等值,ULP 行按 2^e*tol 比较;
//      -0 用 std.Number.toString 的 "-0" 区分。
//   3) llvm-nm -u 不得出现 fmod/pow/sqrt/sin/cos/floor/ceil/round/trunc
//      (按符号名精确比较,不用正则)。
//   4) 熵故障:--wrap=ql_getrandom 的 C shim 覆盖 short-eintr / -5 / 0,
//      std.Math.random 必须分别得到 true / IOError / IOError。
//
// 冻结数据不在这里重新生成;生成脚本只在 /tmp 一次性运行,仓库里没有 .py。
import ./tests/data/numeric_oracle.ql;

let compiler = "target/selfhost/stage2";
let stdlibDir = "";
let root = ".";
let base = "/tmp/qlang-numeric-q";
let runtime = "aot/runtime.ql";
let linkTool = "target/tools/link";
let rest = [];
let ai = 0;
while ai < args.length {
  let a = args[ai];
  if a == "--compiler" { ai = ai + 1; compiler = args[ai]; }
  else if a == "--stdlib" { ai = ai + 1; stdlibDir = args[ai]; }
  else if a == "--root" { ai = ai + 1; root = args[ai]; }
  else if a == "--tmp" { ai = ai + 1; base = args[ai]; }
  else { rest[rest.length] = a; };
  ai = ai + 1;
};
if rest.length > 0 { stdlibDir = rest[0]; };
if stdlibDir == "" { assert(false, "usage: run_numeric <stdlib-dir>"); 1; };
if base == "" || base == "/" { assert(false, "run_numeric: refusing empty/root tmp"); 1; };

let num = (n) -> std.Number.toString(n);
let writeFile = (path, text) -> {
  let r = std.fs.writeText(path, text);
  if isError(r) { assert(false, "cannot write " + path); 1; };
  null;
};
let readFile = (path) -> {
  let r = std.fs.readFileText(path);
  if isError(r) { assert(false, "cannot read " + path); 1; };
  r;
};
let pass = 0; let fail = 0; let failed = "";
let record = (ok, label) -> {
  if ok { pass = pass + 1; } else { fail = fail + 1; failed = failed + " " + label; };
  null;
};
let firstFailure = "";
let abs = (x) -> { if x < 0 { -x; } else { x; }; };

std.process.run(["rm", "-rf", base]);
std.process.run(["mkdir", "-p", base]);

// 行数/op 分布必须与冻结快照一致;少了或多了都说明数据被改动。
let opNames = ["parse", "mod", "and", "or", "xor", "sqrt", "sin", "cos", "pow"];
let opCounts = {};
let oi = 0;
while oi < rows.length {
  let op = rows[oi].op;
  let prior = opCounts[op];
  if isError(prior) { prior = 0; };
  opCounts[op] = prior + 1;
  oi = oi + 1;
};
let countText = "";
let ci = 0;
while ci < opNames.length {
  let c = opCounts[opNames[ci]];
  if isError(c) { c = 0; };
  countText = countText + " " + opNames[ci] + "=" + num(c);
  ci = ci + 1;
};
record(rows.length == 792, "row-count");
let expectedCounts = { parse: 85, mod: 109, and: 46, or: 46, xor: 46, sqrt: 76, sin: 101, cos: 101, pow: 182 };
let countsOk = true;
let ei = 0;
while ei < opNames.length {
  let c = opCounts[opNames[ei]];
  if isError(c) { c = 0; };
  if c != expectedCounts[opNames[ei]] { countsOk = false; };
  ei = ei + 1;
};
record(countsOk, "op-counts");
println("numeric oracle rows=" + num(rows.length) + countText);

// 冻结模块同时喂给被测程序;生成程序在 base 里 import 同目录副本。
let copied = std.process.run(["cp", "aot/tests/data/numeric_oracle.ql", base + "/numeric_oracle.ql"]);
record(copied.status == 0, "copy-oracle");
let program =
  "import ./numeric_oracle.ql;\n" +
  "let i = 0;\n" +
  "while i < rows.length {\n" +
  "  let c = rows[i];\n" +
  "  let a = std.Number.parseFloat(c.a);\n" +
  "  let b = std.Number.parseFloat(c.b);\n" +
  "  let n = a;\n" +
  "  if c.op == \"mod\" { n = a % b; }\n" +
  "  else if c.op == \"and\" { n = a & b; }\n" +
  "  else if c.op == \"or\" { n = a | b; }\n" +
  "  else if c.op == \"xor\" { n = a ^ b; }\n" +
  "  else if c.op == \"sqrt\" { n = std.Math.sqrt(a); }\n" +
  "  else if c.op == \"sin\" { n = std.Math.sin(a); }\n" +
  "  else if c.op == \"cos\" { n = std.Math.cos(a); }\n" +
  "  else if c.op == \"pow\" { n = std.Math.pow(a)(b); };\n" +
  "  let parts = std.Number.frexp(n);\n" +
  "  println(std.JSON.stringify([c.op, std.Number.isNaN(n), std.Number.isFinite(n), n < 0, std.Number.toString(n), parts[0], parts[1], std.JSON.stringify(n)]));\n" +
  "  i = i + 1;\n" +
  "};\n";
writeFile(base + "/numbers.ql", program);
let emitted = std.process.run([compiler, "--emit-llvm-split", base + "/numbers.ql", runtime,
                               stdlibDir + "/symbols.tsv", stdlibDir + "/mod.ql"]);
record(emitted.status == 0, "numbers:emit");
if emitted.status == 0 {
  writeFile(base + "/numbers.ll", emitted.stdout);
} else {
  println(emitted.stderr);
};
let linkIR = (ir, out, opt) -> std.process.run([linkTool, ir, "-o", out, "--opt", num(opt),
                                                "--stdlib-object", stdlibDir + "/stdlib.o",
                                                "--root", root]);

// expected 完全由 (m,e) 与算术/ldexp 还原;nan/inf/sign 走分类字段。
let checkRow = (row, fields) -> {
  let nan = fields[1]; let finite = fields[2]; let neg = fields[3];
  if row.nan == 1 {
    if nan && !finite { return ""; };
    return "nan";
  };
  if row.inf == 1 {
    if !nan && !finite && neg == (row.sign < 0) { return ""; };
    return "inf";
  };
  if !finite || nan { return "not-finite"; };
  let actual = std.Number.ldexp(fields[5])(fields[6]);
  if isError(actual) { return "actual-ldexp"; };
  // JSON.stringify(n) 必须能经 parseFloat 逐位往返(Python 版就是 float(literal))。
  let viaJson = std.Number.parseFloat(fields[7]);
  if isError(viaJson) { return "json-parse"; };
  if row.m == 0 {
    let want = if row.sign < 0 { "-0"; } else { "0"; };
    if actual == 0 && fields[4] == want && viaJson == 0 && std.Number.toString(viaJson) == want { return ""; };
    return "zero";
  };
  if viaJson != actual { return "json-roundtrip"; };
  let expected = std.Number.ldexp(row.m)(row.e);
  if isError(expected) { return "expected-ldexp"; };
  if row.exact == 1 {
    if actual == expected { return ""; };
    return "exact";
  };
  let error = abs(actual - expected);
  let limit = std.Number.ldexp(1)(row.e) * row.tol;
  if isError(limit) { return "limit-ldexp"; };
  if error <= limit { return ""; };
  return "ulp";
};

let worst = {};
let worstOf = (op) -> { let v = worst[op]; if isError(v) { 0; } else { v; }; };
let noteWorst = (row, fields) -> {
  if row.exact == 0 && row.m != 0 && row.nan == 0 && row.inf == 0 {
    let actual = std.Number.ldexp(fields[5])(fields[6]);
    let expected = std.Number.ldexp(row.m)(row.e);
    let ulp = std.Number.ldexp(1)(row.e);
    if !isError(actual) && !isError(expected) && !isError(ulp) {
      let ratio = abs(actual - expected) / ulp;
      let prior = worstOf(row.op);
      if ratio > prior { worst[row.op] = ratio; };
    };
  };
  null;
};

let outputLines = (out) -> {
  let lines = std.String.split(out)("\n");
  if lines.length > 0 && lines[lines.length - 1] == "" { lines.remove(lines.length - 1); };
  lines;
};
let checkRun = (opt) -> {
  let bin = base + "/numbers-O" + num(opt);
  let linked = linkIR(base + "/numbers.ll", bin, opt);
  if linked.status != 0 { record(false, "numbers:link-O" + num(opt)); println(linked.stdout + linked.stderr); return null; };
  let run = std.process.run([bin]);
  if run.status != 0 || run.stderr != "" {
    record(false, "numbers:run-O" + num(opt));
    println("O" + num(opt) + " status=" + num(run.status) + " stderr=" + run.stderr);
    return null;
  };
  let lines = outputLines(run.stdout);
  if lines.length != rows.length {
    record(false, "numbers:lines-O" + num(opt));
    println("O" + num(opt) + " lines=" + num(lines.length));
    return null;
  };
  let bad = 0; let j = 0;
  while j < rows.length {
    let fields = std.JSON.parse(lines[j]);
    if isError(fields) {
      bad = bad + 1;
      if firstFailure == "" { firstFailure = "O" + num(opt) + " row " + num(j) + " json: " + lines[j]; };
    } else {
      let reason = checkRow(rows[j], fields);
      if reason != "" {
        bad = bad + 1;
        if firstFailure == "" {
          firstFailure = "O" + num(opt) + " row " + num(j) + " " + rows[j].op + " " + reason +
                         " a=" + rows[j].a + " b=" + rows[j].b + " line=" + lines[j];
        };
      } else {
        noteWorst(rows[j], fields);
      };
    };
    j = j + 1;
  };
  record(bad == 0, "numbers:O" + num(opt) + "(" + num(rows.length - bad) + "/" + num(rows.length) + ")");
  null;
};
if emitted.status == 0 {
  checkRun(0);
  checkRun(2);
};

// ---- 无外部 libm 符号:按 llvm-nm -u 的符号名精确比较,不用正则 -------------
let forbidden = ["fmod", "pow", "sqrt", "sin", "cos", "floor", "ceil", "round", "trunc"];
let checkSymbols = (opt) -> {
  let bin = base + "/numbers-O" + num(opt);
  let nm = std.process.run(["llvm-nm", "-u", bin]);
  if nm.status != 0 { record(false, "libm:nm-O" + num(opt)); return null; };
  let lines = std.String.split(nm.stdout)("\n");
  let bad = "";
  let k = 0;
  while k < lines.length {
    let cells = std.String.split(lines[k])(" ");
    let name = ""; let c = 0;
    while c < cells.length { if cells[c] != "" { name = cells[c]; }; c = c + 1; };
    let at = std.String.split(name)("@");
    let bare = at[0];
    let f = 0;
    while f < forbidden.length {
      if bare == forbidden[f] { bad = bad + " " + bare; };
      f = f + 1;
    };
    k = k + 1;
  };
  record(bad == "", "libm:O" + num(opt));
  if bad != "" { println("forbidden undefined symbols:" + bad + " (O" + num(opt) + ")"); };
  null;
};
if emitted.status == 0 {
  checkSymbols(0);
  checkSymbols(2);
};

// ---- 熵故障:shim 通过 --wrap=ql_getrandom 覆盖宿主叶子 --------------------
let entropySource = "let n = std.Math.random(); if isError(n) { println(n.type); } else { println(n == 0.9999999999999999); };\n";
writeFile(base + "/entropy.ql", entropySource);
let entropyEmit = std.process.run([compiler, "--emit-llvm-split", base + "/entropy.ql", runtime,
                                    stdlibDir + "/symbols.tsv", stdlibDir + "/mod.ql"]);
record(entropyEmit.status == 0, "entropy:emit");
if entropyEmit.status == 0 {
  writeFile(base + "/entropy.ll", entropyEmit.stdout);
  let variants = [
    { name: "short-eintr",
      body: "static int calls; long __wrap_ql_getrandom(void* buf, long count) { if (++calls == 1) return -4; long n = count < 2 ? count : 2; memset(buf, 255, (size_t)n); return n; }",
      want: "true\n" },
    { name: "error",
      body: "long __wrap_ql_getrandom(void* buf, long count) { return -5; }",
      want: "IOError\n" },
    { name: "empty",
      body: "long __wrap_ql_getrandom(void* buf, long count) { return 0; }",
      want: "IOError\n" }
  ];
  let vi = 0;
  while vi < variants.length {
    let variant = variants[vi];
    let shimPath = base + "/" + variant.name + ".c";
    let bin = base + "/entropy-" + variant.name;
    writeFile(shimPath, "#include <string.h>\n" + variant.body + "\n");
    let cc = std.process.run(["clang", "-O2", "-fuse-ld=lld", "-Wl,--threads=1",
                              "-Wl,--export-dynamic", "-Wl,--wrap=ql_getrandom",
                              base + "/entropy.ll", stdlibDir + "/stdlib.o",
                              "aot/runtime.c", shimPath, "-ldl", "-o", bin]);
    if cc.status != 0 {
      record(false, "entropy:" + variant.name + ":cc");
      println(cc.stderr);
    } else {
      let run = std.process.run([bin]);
      let ok = run.status == 0 && run.stderr == "" && run.stdout == variant.want;
      record(ok, "entropy:" + variant.name);
      if !ok {
        println("entropy " + variant.name + " status=" + num(run.status) +
                " stdout=" + run.stdout + " stderr=" + run.stderr);
      };
    };
    vi = vi + 1;
  };
} else {
  record(false, "entropy:short-eintr");
  record(false, "entropy:error");
  record(false, "entropy:empty");
};

// 观测到的最大 ULP 误差(只统计非精确行;Python 版同样打印 worst)。
let worstText = "";
let wi = 0;
while wi < opNames.length {
  let op = opNames[wi];
  let v = worstOf(op);
  if v > 0 { worstText = worstText + " " + op + "=" + num(v); };
  wi = wi + 1;
};
if worstText != "" { println("max observed ULP errors:" + worstText); };
if firstFailure != "" { println("first failure: " + firstFailure); };
println("numeric oracle: " + num(pass) + " pass / " + num(fail) + " fail");
if failed != "" { println("failed:" + failed); };
if fail > 0 { assert(false, "numeric oracle failed"); 1; };
0;
