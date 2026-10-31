// String/Unicode 测试驱动(QLang,不调用 Python)。
//
//   run_string <stdlib-dir|stdlib.o> [--compiler <c>] [--interpreter <i>] [--link <l>]
//
// 覆盖 stdlib/run_string_tests.py 的四条腿:
//   1) t30_strings:--opt 0 / --opt 2 + native 解释器,stdout == .expected、stderr 为空;
//   2) 独立 Unicode 参照 aot/unicode_oracle.ql:O0/O2 直接跑;解释器腿跑 oracle 生成的
//      夹具(同一批输入/期望值,避免 AST 解释器逐字符解析 50 KB UCD 派生表);
//   3) 未处理的 String 错误:4 个来源 × O0/O2 ⇒ exit 1、stdout 空、stderr 含错误 kind;
//   4) 静态边界:stdlib/string.ql 不得含后端/宿主 std 泄漏记号。
let compiler = "target/selfhost/stage2";
let interpreter = "target/native-interpreter/interpreter";
let linkTool = "target/tools/link";
let stdlibPath = "";
let rest = [];
let i = 0;
while i < args.length {
  let a = args[i];
  if a == "--compiler" { i = i + 1; compiler = args[i]; }
  else if a == "--interpreter" { i = i + 1; interpreter = args[i]; }
  else if a == "--link" { i = i + 1; linkTool = args[i]; }
  else { rest[rest.length] = a; };
  i = i + 1;
};
if rest.length > 0 { stdlibPath = rest[0]; };
if stdlibPath == "" { assert(false, "usage: run_string <stdlib-dir|stdlib.o> [--compiler <c>] [--interpreter <i>] [--link <l>]"); 1; };
// 允许传标准库对象本身:目录 = 它的父目录。
let dirOf = (path) -> {
  let parts = std.String.split(path)("/");
  if parts.length <= 1 { return "."; };
  let out = ""; let k = 0;
  while k < parts.length - 1 {
    if k == 0 { out = parts[k]; } else { out = out + "/" + parts[k]; };
    k = k + 1;
  };
  out;
};
let stdlibDir = stdlibPath;
if stdlibPath.length >= 2 && std.String.split(stdlibPath)(".")[std.String.split(stdlibPath)(".").length - 1] == "o" { stdlibDir = dirOf(stdlibPath); };

let base = "/tmp/qlang-string-q";
std.process.run(["rm", "-rf", base]);
std.process.run(["mkdir", "-p", base]);
let num = (n) -> std.Number.toString(n);
let contains = (text, needle) -> std.String.includes(text)(needle);
let pass = 0; let fail = 0; let failed = "";
let record = (ok, label) -> {
  if ok { pass = pass + 1; } else { fail = fail + 1; failed = failed + " " + label; };
  null;
};
let readFile = (path) -> {
  let r = std.fs.readFileText(path);
  if isError(r) { assert(false, "cannot read " + path); 1; };
  r;
};
let writeFile = (path, text) -> {
  let r = std.fs.writeText(path, text);
  if isError(r) { assert(false, "cannot write " + path); 1; };
  null;
};
let build = (source, binary, opt) -> {
  let emitted = std.process.run([compiler, "--emit-llvm-split", source, "aot/runtime.ql",
                                stdlibDir + "/symbols.tsv", stdlibDir + "/mod.ql"]);
  if emitted.status != 0 { return { ok: false, detail: emitted.stderr }; };
  let ir = binary + ".ll";
  writeFile(ir, emitted.stdout);
  let linked = std.process.run([linkTool, ir, "-o", binary, "--opt", num(opt),
                                "--stdlib-object", stdlibDir + "/stdlib.o", "--root", "."]);
  return { ok: linked.status == 0, detail: linked.stdout + linked.stderr };
};
// 解释器输出:去掉 banner 与 `Execution complete.` 之后的内容。
let interpretedBody = (stdout) -> {
  let marker = "Interpreting...\n";
  let idx = -1; let k = 0;
  while k + marker.length <= stdout.length {
    if std.Bytes.slice(stdout, k, marker.length) == marker { idx = k; k = stdout.length; } else { k = k + 1; };
  };
  if idx < 0 { return ""; };
  let rest = std.Bytes.slice(stdout, idx + marker.length, stdout.length - idx - marker.length);
  let done = "Execution complete.";
  let end = -1; let j = 0;
  while j + done.length <= rest.length {
    if std.Bytes.slice(rest, j, done.length) == done { end = j; j = rest.length; } else { j = j + 1; };
  };
  if end < 0 { return rest; };
  std.Bytes.slice(rest, 0, end);
};
let run = (binary, pathArgs) -> {
  let argv = [binary];
  let k = 0;
  while k < pathArgs.length { argv[argv.length] = pathArgs[k]; k = k + 1; };
  std.process.run(argv);
};

// ---- 1) t30_strings:O0 / O2 / 解释器 ---------------------------------------
let t30 = "aot/tests/t30_strings.ql";
let t30Expected = readFile("aot/tests/t30_strings.expected");
let b0 = build(t30, base + "/t30-O0", 0);
let b2 = build(t30, base + "/t30-O2", 2);
record(b0.ok, "t30:build-O0");
record(b2.ok, "t30:build-O2");
if b0.ok {
  let r = run(base + "/t30-O0", []);
  record(r.status == 0 && r.stderr == "" && r.stdout == t30Expected, "t30:O0");
  if !(r.status == 0 && r.stderr == "" && r.stdout == t30Expected) { println("t30 O0 detail: status=" + num(r.status) + " stderr=[" + r.stderr + "]"); };
};
if b2.ok {
  let r = run(base + "/t30-O2", []);
  record(r.status == 0 && r.stderr == "" && r.stdout == t30Expected, "t30:O2");
  if !(r.status == 0 && r.stderr == "" && r.stdout == t30Expected) { println("t30 O2 detail: status=" + num(r.status) + " stderr=[" + r.stderr + "]"); };
};
let t30Boot = run(interpreter, [t30]);
record(t30Boot.status == 0 && t30Boot.stderr == "" && interpretedBody(t30Boot.stdout) == t30Expected, "t30:interp");
println("t30_strings: 193 portable String contracts(O0/O2/解释器)");

// ---- 2) 独立 Unicode 参照:O0 / O2 / 解释器 --------------------------------
let oracle = "aot/unicode_oracle.ql";
let o0 = build(oracle, base + "/oracle-O0", 0);
let o2 = build(oracle, base + "/oracle-O2", 2);
record(o0.ok, "oracle:build-O0");
record(o2.ok, "oracle:build-O2");
if o0.ok {
  let r = run(base + "/oracle-O0", []);
  record(r.status == 0 && r.stderr == "" && contains(r.stdout, "0 处不一致"), "oracle:O0");
  if r.status != 0 { println("oracle O0 detail: status=" + num(r.status) + " out=[" + r.stdout + "] err=[" + r.stderr + "]"); };
};
if o2.ok {
  let r = run(base + "/oracle-O2", []);
  record(r.status == 0 && r.stderr == "" && contains(r.stdout, "0 处不一致"), "oracle:O2");
  if r.status != 0 { println("oracle O2 detail: status=" + num(r.status) + " out=[" + r.stdout + "] err=[" + r.stderr + "]"); };
};
// 解释器腿:UCD 派生表由逐字符 QLang 循环解析,在 AST 解释器里是分钟级;
// 原生 oracle 用同一份独立期望值生成一个小夹具,解释器只执行 casing/trim。
let oracleBoot = { status: 1, stdout: "", stderr: "oracle O2 unavailable" };
if o2.ok {
  let emitted = std.process.run([base + "/oracle-O2", "--emit-interpreter-fixture"]);
  if emitted.status == 0 {
    let fixture = base + "/oracle-fixture.ql";
    writeFile(fixture, emitted.stdout);
    oracleBoot = run(interpreter, [fixture]);
  } else {
    oracleBoot = { status: emitted.status, stdout: emitted.stdout, stderr: emitted.stderr };
  };
};
record(oracleBoot.status == 0 && oracleBoot.stderr == "" && contains(interpretedBody(oracleBoot.stdout), "0 处不一致"), "oracle:interp");
if !(oracleBoot.status == 0 && oracleBoot.stderr == "" && contains(interpretedBody(oracleBoot.stdout), "0 处不一致")) {
  println("oracle interp detail: status=" + num(oracleBoot.status) + " out=[" + oracleBoot.stdout + "] err=[" + oracleBoot.stderr + "]");
};
println("Unicode oracle: 全平面简单/完整映射 + 46x64 字符串 + 120 随机串 + 6 sigma + trim");

// ---- 3) 未处理的 String 错误:4 个来源 × O0/O2 ------------------------------
let errorSource = 'if args[0] == "receiver" { std.String.trim(42)?; };\n'
  + 'if args[0] == "repeat" { std.String.repeat("x")(0.5)?; };\n'
  + 'if args[0] == "limit" { std.String.repeat("x")(16777217)?; };\n'
  + 'if args[0] == "index" { std.String.at("x", 2)?; };\n'
  + 'println("UNREACHABLE");\n';
writeFile(base + "/errors.ql", errorSource);
let e0 = build(base + "/errors.ql", base + "/errors-O0", 0);
let e2 = build(base + "/errors.ql", base + "/errors-O2", 2);
record(e0.ok, "errors:build-O0");
record(e2.ok, "errors:build-O2");
let cases = [["receiver", "TypeMismatch"], ["repeat", "RangeError"], ["limit", "RangeError"], ["index", "IndexOutOfBounds"]];
let optIndex = 0;
while optIndex < 2 {
  let built = if optIndex == 0 { e0; } else { e2; };
  if built.ok {
    let name = if optIndex == 0 { base + "/errors-O0"; } else { base + "/errors-O2"; };
    let ci = 0;
    while ci < cases.length {
      let c = cases[ci];
      let r = run(name, [c[0]]);
      record(r.status == 1 && r.stdout == "" && contains(r.stderr, c[1]), "errors:O" + num(optIndex * 2) + ":" + c[0]);
      if !(r.status == 1 && r.stdout == "" && contains(r.stderr, c[1])) {
        println("error detail " + c[0] + " O" + num(optIndex * 2) + ": status=" + num(r.status) + " out=[" + r.stdout + "] err=[" + r.stderr + "]");
      };
      ci = ci + 1;
    };
  };
  optIndex = optIndex + 1;
};
println("unhandled errors: receiver/repeat/limit/index ⇒ exit 1 + kind,stdout 为空");

// ---- 4) 静态边界:库源码不得引用后端/宿主 std 实现 -------------------------
let library = readFile("stdlib/string.ql");
let forbidden = ["ql_mem_", "readU64", "writeU64", "ql_alloc", "std.String.", "std.Math."];
let bi = 0;
while bi < forbidden.length {
  record(!contains(library, forbidden[bi]), "boundary:" + forbidden[bi]);
  bi = bi + 1;
};
println("static boundary: stdlib/string.ql 无 ql_mem_/readU64/writeU64/ql_alloc/std.String./std.Math.");

println("QLang String 驱动:" + num(pass) + " 通过 / " + num(fail) + " 失败");
if failed != "" { println("失败:" + failed); };
if fail > 0 { assert(false, "string tests failed"); 1; };
0;
