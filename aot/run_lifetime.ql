// QLang 生命周期测试驱动(不依赖 Python):栈槽不变量 + t22 压力用例 + 分配计数。
//
//   run_lifetime [--compiler <c>] [--stdlib <dir>] [--root <repo>] [--tmp <base>] [--full-ir]
//
// 覆盖原 Python 套件 aot/run_lifetime_tests.py:
//   1) IR 不变量:压力程序里每条 alloca 都挂在 `entry:` 下,且计数 > 0
//      (按行扫描:标签行以 ':' 结尾且全体字符属于 [A-Za-z0-9_.-],`define ` 重置标签);
//   2) t22_lifetimes.ql 把 println(loop(1000)) 改成 100000,分别 --opt 0/2 链接,
//      在 `ulimit -s 1024`(1 MiB 栈)下运行:退出码 0、输出 = .expected(1000→100000)、stderr 为空;
//   3) 插桩 runtime.c 的 ql_alloc 计数:1000/2000 次标量循环的分配次数必须完全相等。
//
// 默认不变量扫的是链接用的同一份 split IR(用户模块),与 Python 版在
// QLANG_STDLIB_SYMBOLS 快路径下的行为一致;`--full-ir` 改为扫整模块 IR(含 runtime/标准库,
// 与 Python 默认路径同覆盖面,但 QLang 侧 split+扫描 15MB IR 约需 75s/次)。
let compiler = "target/selfhost/stage2";
let stdlibDir = "";
let root = ".";
let base = "/tmp/qlang-lifetime-q";
let runtime = "aot/runtime.ql";
let linkTool = "target/tools/link";
let fullIR = false;
let rest = [];
let i = 0;
while i < args.length {
  let a = args[i];
  if a == "--compiler" { i = i + 1; compiler = args[i]; }
  else if a == "--stdlib" { i = i + 1; stdlibDir = args[i]; }
  else if a == "--root" { i = i + 1; root = args[i]; }
  else if a == "--tmp" { i = i + 1; base = args[i]; }
  else if a == "--full-ir" { fullIR = true; }
  else { rest[rest.length] = a; };
  i = i + 1;
};
if rest.length > 0 { stdlibDir = rest[0]; };
if stdlibDir == "" { assert(false, "usage: run_lifetime <stdlib-dir>"); 1; };

std.process.run(["rm", "-rf", base]);
std.process.run(["mkdir", "-p", base]);
let num = (n) -> std.Number.toString(n);
let sq = (v) -> "'" + std.String.replace(v)("'")("'\\''") + "'";
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
let countOccurrences = (text, needle) -> {
  if needle == "" { return 0; };
  std.String.split(text)(needle).length - 1;
};
let pass = 0; let fail = 0; let failed = "";
let record = (ok, label) -> {
  if ok { pass = pass + 1; } else { fail = fail + 1; failed = failed + " " + label; };
  null;
};
let emitSplit = (source, ir) -> {
  let r = std.process.run([compiler, "--emit-llvm-split", source, runtime,
                           stdlibDir + "/symbols.tsv", stdlibDir + "/mod.ql"]);
  if r.status != 0 { return r; };
  writeFile(ir, r.stdout);
  r;
};
let emitFull = (source) -> {
  let r = std.process.run([compiler, "--emit-llvm", source, runtime]);
  if r.status != 0 { return { status: r.status, text: "" }; };
  { status: 0, text: r.stdout };
};
let linkIR = (ir, out, opt, runtimeObj) -> {
  let argv = [linkTool, ir, "-o", out, "--opt", num(opt),
              "--stdlib-object", stdlibDir + "/stdlib.o", "--root", root];
  if runtimeObj != "" {
    argv[argv.length] = "--runtime-object";
    argv[argv.length] = runtimeObj;
  };
  std.process.run(argv);
};

// ---- IR 不变量:alloca 只能出现在 entry 基本块 ----------------------------
let digitOrWord = "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_-.";
let isLabelLine = (line) -> {
  if line.length < 2 { return false; };
  if std.Bytes.slice(line, line.length - 1, 1) != ":" { return false; };
  let k = 0;
  while k < line.length - 1 {
    if !std.String.includes(digitOrWord)(std.Bytes.slice(line, k, 1)) { return false; };
    k = k + 1;
  };
  true;
};
let checkEntryAllocas = (irText) -> {
  let lines = std.String.split(irText)("\n");
  let label = null;
  let count = 0; let bad = 0; let firstBad = "";
  let k = 0;
  while k < lines.length {
    let line = lines[k];
    if std.String.startsWith(line)("define ") { label = null; }
    else if isLabelLine(line) { label = std.Bytes.slice(line, 0, line.length - 1); }
    else if std.String.includes(line)(" = alloca ") {
      count = count + 1;
      if label != "entry" {
        bad = bad + 1;
        if firstBad == "" { firstBad = line; };
      };
    };
    k = k + 1;
  };
  { count: count, bad: bad, firstBad: firstBad };
};
let moduleInvariant = (irPath, source) -> {
  if fullIR {
    let full = emitFull(source);
    if full.status != 0 { return { count: 0, bad: 0, firstBad: "emit failed" }; };
    return checkEntryAllocas(full.text);
  };
  checkEntryAllocas(readFile(irPath));
};

// ---- 1) t22 压力用例:loop(1000) -> loop(100000),O0/O2 + 1 MiB 栈 --------
let sourceText = readFile("aot/tests/t22_lifetimes.ql");
let loopNeedle = "println(loop(1000));";
let loopReplacement = "println(loop(100000));";
record(countOccurrences(sourceText, loopNeedle) > 0, "stress:source-patch");
let stressSource = base + "/lifetime-stress.ql";
writeFile(stressSource, std.String.replace(sourceText)(loopNeedle)(loopReplacement));
let expected = readFile("aot/tests/t22_lifetimes.expected");
record(countOccurrences(expected, "\n1000\n") > 0, "stress:expected-patch");
let expectedOut = std.String.replace(expected)("\n1000\n")("\n100000\n");

let stressIR = base + "/lifetime.ll";
let stressEmit = emitSplit(stressSource, stressIR);
record(stressEmit.status == 0, "stress:emit");
let stressInv = { count: 0, bad: 0, firstBad: "emit failed" };
if stressEmit.status == 0 { stressInv = moduleInvariant(stressIR, stressSource); };
println("stress IR:" + num(stressInv.count) + " 个 alloca,entry 之外 " + num(stressInv.bad) + " 个");
if stressInv.firstBad != "" { println("第一个违规:" + stressInv.firstBad); };
record(stressInv.count > 0 && stressInv.bad == 0, "stress:invariant");
if stressEmit.status == 0 {
  let stressRun = (opt) -> {
    let bin = base + "/lifetime-O" + num(opt);
    let linked = linkIR(stressIR, bin, opt, "");
    if linked.status != 0 { return false; };
    // 1 MiB 栈:帧内 alloca 若随循环重复就必然溢出。
    let run = std.process.run(["sh", "-c", "ulimit -s 1024; exec " + sq(bin)]);
    run.status == 0 && run.stdout == expectedOut && run.stderr == "";
  };
  record(stressRun(0), "stress:O0");
  record(stressRun(2), "stress:O2");
} else {
  record(false, "stress:O0");
  record(false, "stress:O2");
};

// ---- 2) 插桩 ql_alloc:统计 1000/2000 次标量循环的堆分配次数 --------------
// 锚点必须先确认命中:文本替换静默落空会让插桩后的 runtime 失去计数器,
// 后面的「分配次数相等」就会退化成对空 stderr 的假绿。
let runtimeText = readFile("aot/runtime.c");
let includeNeedle = "#include <stddef.h>";
let includeReplacement = "#include <stdio.h>\n#include <stddef.h>";
let allocNeedle = "void* ql_alloc(size_t n) {";
let allocReplacement = "static unsigned long long allocations;\n"
  + "__attribute__((destructor)) static void report(void) { fprintf(stderr, \"ALLOCATIONS %llu\\n\", allocations); }\n"
  + "void* ql_alloc(size_t n) { ++allocations;";
let includeHits = countOccurrences(runtimeText, includeNeedle);
let allocHits = countOccurrences(runtimeText, allocNeedle);
record(includeHits > 0, "runtime-patch:stdio");
record(allocHits > 0, "runtime-patch:alloc");
assert(includeHits > 0 && allocHits > 0, "runtime.c instrumentation anchors missing");
let instrumented = base + "/count-runtime.c";
writeFile(instrumented, std.String.replace(
  std.String.replace(runtimeText)(includeNeedle)(includeReplacement))(allocNeedle)(allocReplacement));
let runtimeObject = base + "/count-runtime.o";
let cc = std.process.run(["clang", "-O2", "-c", instrumented, "-o", runtimeObject]);
record(cc.status == 0, "runtime:compile");

let countSource = (n) -> "let count = (limit) -> { let i = 0; while i < limit { i = i + 1; }; i; };\n"
  + "println(count(" + num(n) + "));\n";
// stderr 只允许 `ALLOCATIONS <digits>\n`;返回数字串(不合格则返回空串)。
let allocDigits = (stderr) -> {
  let prefix = "ALLOCATIONS ";
  if !std.String.startsWith(stderr)(prefix) { return ""; };
  if stderr.length < prefix.length + 2 { return ""; };
  if std.Bytes.slice(stderr, stderr.length - 1, 1) != "\n" { return ""; };
  let digits = std.Bytes.slice(stderr, prefix.length, stderr.length - prefix.length - 1);
  let k = 0;
  while k < digits.length {
    if !std.String.includes("0123456789")(std.Bytes.slice(digits, k, 1)) { return ""; };
    k = k + 1;
  };
  digits;
};
let counts = [];
let nValues = [1000, 2000];
let ci = 0;
while ci < nValues.length {
  let n = nValues[ci];
  let tag = "count:" + num(n);
  let src = base + "/count-" + num(n) + ".ql";
  writeFile(src, countSource(n));
  let irPath = base + "/count-" + num(n) + ".ll";
  let se = emitSplit(src, irPath);
  let inv = { count: 0, bad: 0, firstBad: "emit failed" };
  if se.status == 0 { inv = moduleInvariant(irPath, src); };
  let ok = se.status == 0 && inv.count > 0 && inv.bad == 0 && cc.status == 0;
  if ok {
    let bin = base + "/count-bin-" + num(n);
    let linked = linkIR(irPath, bin, 2, runtimeObject);
    if linked.status != 0 { ok = false; }
    else {
      let run = std.process.run([bin]);
      if run.status != 0 || run.stdout != num(n) + "\n" { ok = false; }
      else {
        let digits = allocDigits(run.stderr);
        if digits == "" { ok = false; }
        else {
          let value = std.Number.parseFloat(digits);
          if isError(value) { ok = false; } else { counts[counts.length] = value; };
        };
      };
    };
  };
  record(ok, tag);
  ci = ci + 1;
};
// 标量(含返回的计数器)是内联值:翻倍循环次数不应新增任何堆分配。
record(counts.length == 2 && counts[0] == counts[1], "count:no-growth");
if counts.length == 2 {
  println("allocations:" + num(counts[0]) + " (1000) / " + num(counts[1]) + " (2000)");
};

println("QLang 生命周期驱动:" + num(pass) + " 通过 / " + num(fail) + " 失败");
if failed != "" { println("失败:" + failed); };
if fail > 0 { assert(false, "lifetime tests failed"); 1; };
0;
