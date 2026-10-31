// QLang 值契约驱动(不依赖 Python):数组/对象/调用/JSON 数字的 native 契约。
//
//   run_value_contracts [<stdlib-dir>] [--compiler <c>] [--root <repo>]
//
// 覆盖原 Python 套件:
//   run_array_tests.py         t29 @ O0/O2 + 8 个未处理错误探针
//   run_array_tests.py --library  stdlib/array.ql 可移植性 + t29/8 探针走 ArrayLibrary.
//   run_object_tests.py        t28 @ O0/O2 + 8 个未处理错误探针
//   run_call_tests.py          t27 @ O0/O2、t24 @ O0/O2、legacy runtime 拒绝、
//                              t24 压力(j < 20000)@ O0/O2 + 入口 alloca 扫描、
//                              插桩 ql_alloc 计分配(1000/2000 相等,100000 走 1 MiB 栈)
//   run_json_numeric_tests.py  30 个十进制字面量 host/native 逐字节一致
//
// 仓库相对路径按当前目录解析(与 aot/build.ql、aot/run_modules.ql 一样,从仓库根运行);
// --root 只交给 target/tools/link,让链接器自己解析 runtime/toolchain/verify。
let compiler = "target/selfhost/stage2";
let stdlibDir = "";
let linkTool = "target/tools/link";
let root = ".";
let runtime = "aot/runtime.ql";
let base = "/tmp/qlang-values-q";
let rest = [];
let ai = 0;
while ai < args.length {
  let a = args[ai];
  if a == "--compiler" { ai = ai + 1; compiler = args[ai]; }
  else if a == "--root" { ai = ai + 1; root = args[ai]; }
  else if a == "--stdlib-dir" { ai = ai + 1; stdlibDir = args[ai]; }
  else { rest[rest.length] = a; };
  ai = ai + 1;
};
if rest.length > 0 { stdlibDir = rest[0]; };
if stdlibDir == "" { assert(false, "usage: run_value_contracts <stdlib-dir>"); 1; };

std.process.run(["rm", "-rf", base]);
std.process.run(["mkdir", "-p", base]);
let pass = 0; let fail = 0; let failed = "";
let num = (n) -> std.Number.toString(n);
let contains = (text, needle) -> std.String.includes(text)(needle);
let startsWith = (text, prefix) -> std.String.startsWith(text)(prefix);
let endsWith = (text, suffix) -> {
  if text.length < suffix.length { return false; };
  std.Bytes.slice(text, text.length - suffix.length, suffix.length) == suffix;
};
let repo = if root == "." { "" } else { if endsWith(root, "/") { root } else { root + "/" }; };
let record = (ok, label) -> {
  if ok { pass = pass + 1; } else { fail = fail + 1; failed = failed + " " + label; };
  null;
};
let startGroup = () -> fail;
let endGroup = (before, label) -> {
  if fail == before { println("PASS " + label); } else { println("FAIL " + label); };
  null;
};
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
let showFailure = (label, run) -> {
  println("DETAIL " + label + " status=" + num(run.status));
  if run.stdout != "" { println("DETAIL " + label + " stdout=" + std.Bytes.slice(run.stdout, 0, std.Math.min(run.stdout.length, 400))); };
  if run.stderr != "" { println("DETAIL " + label + " stderr=" + std.Bytes.slice(run.stderr, 0, std.Math.min(run.stderr.length, 400))); };
  null;
};
// 对象化构建:emit 只发用户模块,链接器用标准库对象 + 静态字符串校验。
// `runtimeObject` 非空时替换 aot/runtime.c(分配计数腿用插桩后的 runtime)。
let buildWith = (source, binary, opt, runtimeObject) -> {
  let emitted = std.process.run([compiler, "--emit-llvm-split", source, runtime,
                                stdlibDir + "/symbols.tsv", stdlibDir + "/mod.ql"]);
  if emitted.status != 0 { return { ok: false, run: emitted, ir: "" }; };
  let ir = binary + ".ll";
  writeFile(ir, emitted.stdout);
  let argv = [linkTool, ir, "-o", binary, "--opt", num(opt),
              "--stdlib-object", stdlibDir + "/stdlib.o", "--root", root];
  if runtimeObject != "" {
    argv[argv.length] = "--runtime-object";
    argv[argv.length] = runtimeObject;
  };
  let linked = std.process.run(argv);
  return { ok: linked.status == 0, run: linked, ir: ir };
};
let build = (source, binary, opt) -> buildWith(source, binary, opt, "");
let runBinary = (binary, extra) -> {
  let command = [binary];
  let k = 0;
  while k < extra.length { command[command.length] = extra[k]; k = k + 1; };
  std.process.run(command);
};
let lineCount = (text) -> {
  let parts = std.String.split(text)("\n");
  let n = parts.length;
  if n > 0 && parts[n - 1] == "" { n = n - 1; };
  n;
};

// ---- 1) 四个夹具 @ O0/O2 ------------------------------------------------
let fixture = (name) -> {
  let source = "aot/tests/" + name + ".ql";
  let expected = readFile("aot/tests/" + name + ".expected");
  let b0 = build(source, base + "/" + name + "-O0", 0);
  let b2 = build(source, base + "/" + name + "-O2", 2);
  record(b0.ok, name + ":build-O0");
  record(b2.ok, name + ":build-O2");
  if !b0.ok { showFailure(name + ":build-O0", b0.run); };
  if !b2.ok { showFailure(name + ":build-O2", b2.run); };
  if b0.ok {
    let r = std.process.run([base + "/" + name + "-O0"]);
    record(r.status == 0 && r.stdout == expected && r.stderr == "", name + ":O0");
    if r.status != 0 || r.stdout != expected || r.stderr != "" { showFailure(name + ":O0", r); };
  };
  if b2.ok {
    let r = std.process.run([base + "/" + name + "-O2"]);
    record(r.status == 0 && r.stdout == expected && r.stderr == "", name + ":O2");
    if r.status != 0 || r.stdout != expected || r.stderr != "" { showFailure(name + ":O2", r); };
  };
  null;
};
let group = startGroup();
fixture("t29_arrays");
fixture("t28_objects");
fixture("t27_native_calls");
fixture("t24_call_buffers");
endGroup(group, "fixtures t29_arrays/t28_objects/t27_native_calls/t24_call_buffers @ O0/O2");

// ---- 2) 8 数组 + 8 对象未处理错误探针(表达式/名字取自 Python 套件) ------
// 与 run_array_tests.py / run_object_tests.py 一样分成两个探针程序,分派名字保持原样。
let arrayProbeCases = [
  { name: "length", code: "std.Array.length({})" },
  { name: "add", code: "std.Array.add(42)" },
  { name: "push", code: "std.Array.push(null)" },
  { name: "pop", code: "std.Array.pop(false)" },
  { name: "get", code: "std.Array.get(\"text\")" },
  { name: "reverse", code: "std.Array.reverse(x -> x)" },
  { name: "concat", code: "std.Array.concat([])({})" },
  { name: "at", code: "std.Array.at([], \"0\")" }
];
let objectProbeCases = [
  { name: "keys", code: "std.Object.keys([])" },
  { name: "values", code: "std.Object.values(42)" },
  { name: "merge-first", code: "std.Object.merge(false)" },
  { name: "merge-second", code: "std.Object.merge({})(null)" },
  { name: "hasOwn", code: "std.Object.hasOwn(\"text\")" },
  { name: "get", code: "std.Object.get(x -> x)" },
  { name: "field-receiver", code: "std.Object.field([], \"x\")" },
  { name: "field-key", code: "std.Object.field({}, {})" }
];
let probeText = (cases) -> {
  let text = "";
  let i = 0;
  while i < cases.length {
    text = text + "if args[0] == \"" + cases[i].name + "\" { (" + cases[i].code + ")?; };\n";
    i = i + 1;
  };
  text + "println(\"UNREACHABLE\");\n";
};
// `prefix` 非空时前置(`import <library>;`)并把 std.Array. 改写成 ArrayLibrary.
// —— 与 run_array_tests.py --library 的探针程序一致。
let probeSuite = (tag, cases, prefix) -> {
  let source = base + "/" + tag + "-errors.ql";
  let text = probeText(cases);
  if prefix != "" { text = prefix + std.String.replace(text)("std.Array.")("ArrayLibrary."); };
  writeFile(source, text);
  let b0 = build(source, base + "/" + tag + "-errors-O0", 0);
  let b2 = build(source, base + "/" + tag + "-errors-O2", 2);
  record(b0.ok, tag + ":probe-build-O0");
  record(b2.ok, tag + ":probe-build-O2");
  if !b0.ok { showFailure(tag + ":probe-build-O0", b0.run); };
  if !b2.ok { showFailure(tag + ":probe-build-O2", b2.run); };
  let oi = 0;
  while oi < 2 {
    let opt = if oi == 0 { 0 } else { 2 };
    let built = if opt == 0 { b0 } else { b2 };
    if built.ok {
      let binary = base + "/" + tag + "-errors-O" + num(opt);
      let ci = 0;
      while ci < cases.length {
        let name = cases[ci].name;
        let r = runBinary(binary, [name]);
        record(r.status == 1 && r.stdout == "" && contains(r.stderr, "TypeMismatch"),
               tag + ":O" + num(opt) + ":" + name);
        if r.status != 1 || r.stdout != "" || !contains(r.stderr, "TypeMismatch") {
          showFailure(tag + ":O" + num(opt) + ":" + name, r);
        };
        ci = ci + 1;
      };
    };
    oi = oi + 1;
  };
  null;
};
let group = startGroup();
probeSuite("array", arrayProbeCases, "");
probeSuite("object", objectProbeCases, "");
endGroup(group, "unhandled errors: 8 array + 8 object @ O0/O2 (rc 1, empty stdout, TypeMismatch)");

// ---- 3) JSON 十进制/f64 边界:host 与 native 逐字节一致 ------------------
// 前 14 个固定,后 16 个来自 random.Random(20260923)(一次性生成后硬编码)。
let decimals = [
  "5e-324", "2.2250738585072014e-308", "1.7976931348623157e308",
  "2.2250738585072011e-308", "1e-300", "1e300", "-0.0", "0.1", "3.14",
  "9007199254740993", "2.4703282292062327e-324", "2.4703282292062328e-324",
  "1.00000000000000011102230246251565404236316680908203125",
  "1.00000000000000011102230246251565404236316680908203126",
  "0.00013302445241885293", "3.4253441890293775e+148",
  "-4.7451781815962354e+265", "3.7522597982638785e+211",
  "1.8287126424563967e-57", "-2.4414904253840378e+67",
  "3.3545829305888605e-268", "-4.970770826032085e+133",
  "2.4765830716952035e-50", "-4.5351709517781875e-208",
  "1.510614421690557e+290", "-5.219629001927558e+229",
  "8.864726692592986e-206", "-4.218624032199959e+200",
  "-3.8784289274767554e+208", "2.5130187179881185e-270"
];
let jsonArray = "[";
let di = 0;
while di < decimals.length {
  if di > 0 { jsonArray = jsonArray + ", "; };
  jsonArray = jsonArray + "\"" + decimals[di] + "\"";
  di = di + 1;
};
jsonArray = jsonArray + "]";
let numbersSource = "let values = " + jsonArray + ";\n"
  + "let i = 0; while i < values.length {\n"
  + "  println(std.JSON.stringify(std.JSON.parse(values[i])));\n"
  + "  i = i + 1;\n"
  + "};\n";
writeFile(base + "/numbers.ql", numbersSource);
let group = startGroup();
record(decimals.length == 30, "json:literal-count");
let host = std.process.run([repo + "target/release/qlang", base + "/numbers.ql"]);
record(host.status == 0, "json:host-status");
if host.status != 0 { showFailure("json:host", host); };
let jsonBuild = build(base + "/numbers.ql", base + "/numbers", 2);
record(jsonBuild.ok, "json:build");
if !jsonBuild.ok { showFailure("json:build", jsonBuild.run); };
if host.status == 0 && jsonBuild.ok {
  let native = std.process.run([base + "/numbers"]);
  record(native.status == 0, "json:native-status");
  if native.status != 0 { showFailure("json:native", native); };
  record(native.stdout == host.stdout, "json:byte-identical");
  record(lineCount(host.stdout) == 30, "json:host-lines");
  record(lineCount(native.stdout) == 30, "json:native-lines");
  if native.stdout != host.stdout {
    let hostLines = std.String.split(host.stdout)("\n");
    let nativeLines = std.String.split(native.stdout)("\n");
    let li = 0;
    while li < hostLines.length && li < nativeLines.length {
      if hostLines[li] != nativeLines[li] {
        println("MISMATCH " + decimals[li] + ": host=" + hostLines[li] + " native=" + nativeLines[li]);
        li = hostLines.length;
      } else {
        li = li + 1;
      };
    };
  };
};
endGroup(group, "JSON decimals: 30 literals host/native byte-identical, exact line count");

// ---- 4) 旧 runtime 必须在代码生成前拒绝 --------------------------------
let group = startGroup();
let runtimeText = readFile("aot/runtime.ql");
let legacyText = std.String.replace(runtimeText)("let __call = __call_borrowed;\n")("");
legacyText = std.String.replace(legacyText)("__call_borrowed")("__call");
record(legacyText != runtimeText, "legacy:rewrite");
writeFile(base + "/legacy-runtime.ql", legacyText);
writeFile(base + "/legacy-probe.ql", "println(1);");
let legacy = std.process.run([compiler, "--emit-llvm", base + "/legacy-probe.ql",
                             base + "/legacy-runtime.ql"]);
record(legacy.status == 1, "legacy:status");
record(legacy.stdout == "", "legacy:no-ir");
record(contains(legacy.stderr, "missing runtime binding: __call_borrowed"), "legacy:diagnostic");
if legacy.status != 1 || legacy.stdout != "" || !contains(legacy.stderr, "missing runtime binding: __call_borrowed") {
  showFailure("legacy", legacy);
};
endGroup(group, "legacy call runtime rejected before code generation");

// ---- 5) t24 压力(j < 20000)@ O0/O2 + 入口 alloca 扫描 -------------------
let isLabelLine = (line) -> {
  if line.length < 2 { return false; };
  if !endsWith(line, ":") { return false; };
  if contains(line, " ") { return false; };
  if contains(line, "=") { return false; };
  if startsWith(line, ";") { return false; };
  if contains(line, "\"") { return false; };
  if contains(line, "{") { return false; };
  if contains(line, "}") { return false; };
  true;
};
let scanAllocas = (irPath) -> {
  let lines = std.String.split(readFile(irPath))("\n");
  let label = "";
  let count = 0; let bad = "";
  let i = 0;
  while i < lines.length {
    let line = lines[i];
    if startsWith(line, "define ") { label = ""; }
    else if isLabelLine(line) { label = std.Bytes.slice(line, 0, line.length - 1); }
    else if contains(line, " = alloca ") {
      count = count + 1;
      if label != "entry" { bad = line; };
    };
    i = i + 1;
  };
  return { count: count, bad: bad };
};
let group = startGroup();
let t24Text = readFile("aot/tests/t24_call_buffers.ql");
let stressText = std.String.replace(t24Text)("j < 1000")("j < 20000");
record(stressText != t24Text, "stress:rewrite");
writeFile(base + "/retained.ql", stressText);
let t24Expected = readFile("aot/tests/t24_call_buffers.expected");
let s0 = build(base + "/retained.ql", base + "/retained-O0", 0);
let s2 = build(base + "/retained.ql", base + "/retained-O2", 2);
record(s0.ok, "stress:build-O0");
record(s2.ok, "stress:build-O2");
if !s0.ok { showFailure("stress:build-O0", s0.run); };
if !s2.ok { showFailure("stress:build-O2", s2.run); };
if s0.ok {
  let scan = scanAllocas(s0.ir);
  record(scan.count > 0 && scan.bad == "", "stress:O0-allocas");
  if scan.count == 0 || scan.bad != "" { println("DETAIL stress:O0-allocas count=" + num(scan.count) + " bad=" + scan.bad); };
  let r = std.process.run([base + "/retained-O0"]);
  record(r.status == 0 && r.stdout == t24Expected && r.stderr == "", "stress:O0");
  if r.status != 0 || r.stdout != t24Expected || r.stderr != "" { showFailure("stress:O0", r); };
};
if s2.ok {
  let scan = scanAllocas(s2.ir);
  record(scan.count > 0 && scan.bad == "", "stress:O2-allocas");
  if scan.count == 0 || scan.bad != "" { println("DETAIL stress:O2-allocas count=" + num(scan.count) + " bad=" + scan.bad); };
  let r = std.process.run([base + "/retained-O2"]);
  record(r.status == 0 && r.stdout == t24Expected && r.stderr == "", "stress:O2");
  if r.status != 0 || r.stdout != t24Expected || r.stderr != "" { showFailure("stress:O2", r); };
};
endGroup(group, "t24 stress j<20000 @ O0/O2, stdout expected, entry-only allocas");

// ---- 6) 分配抖动:插桩 ql_alloc 的 runtime.c + 常数循环 -------------------
// 锚点先确认命中:替换静默落空会让「分配次数相等」退化成对空 stderr 的假绿。
let countOccurrences = (text, needle) -> {
  if needle == "" { return 0; };
  std.String.split(text)(needle).length - 1;
};
let group = startGroup();
let runtimeText = readFile("aot/runtime.c");
let includeNeedle = "#include <stddef.h>";
let includeReplacement = "#include <stdio.h>\n#include <stddef.h>";
let allocNeedle = "void* ql_alloc(size_t n) {";
let allocReplacement = "static unsigned long long allocations;\n"
  + "__attribute__((destructor)) static void report(void) { fprintf(stderr, \"ALLOCATIONS %llu\\n\", allocations); }\n"
  + "void* ql_alloc(size_t n) { ++allocations;";
let includeHits = countOccurrences(runtimeText, includeNeedle);
let allocHits = countOccurrences(runtimeText, allocNeedle);
record(includeHits > 0, "churn:runtime-patch-stdio");
record(allocHits > 0, "churn:runtime-patch-alloc");
if includeHits == 0 || allocHits == 0 { assert(false, "runtime.c instrumentation anchors missing"); };
let instrumented = base + "/count-runtime.c";
writeFile(instrumented, std.String.replace(
  std.String.replace(runtimeText)(includeNeedle)(includeReplacement))(allocNeedle)(allocReplacement));
let runtimeObject = base + "/count-runtime.o";
let cc = std.process.run(["clang", "-O2", "-c", instrumented, "-o", runtimeObject]);
record(cc.status == 0, "churn:runtime-compile");
if cc.status != 0 { showFailure("churn:runtime-compile", cc); };

let churnSource = (n) -> "let run = (limit) -> { let i = 0; while i < limit { i = i + 1; }; i; };\n"
  + "println(run(" + num(n) + "));\n";
// stderr 只允许 `ALLOCATIONS <digits>\n`;合格返回数字串,不合格返回空串。
let allocDigits = (stderr) -> {
  let head = "ALLOCATIONS ";
  if !startsWith(stderr, head) { return ""; };
  if stderr.length < head.length + 2 { return ""; };
  if std.Bytes.slice(stderr, stderr.length - 1, 1) != "\n" { return ""; };
  let digits = std.Bytes.slice(stderr, head.length, stderr.length - head.length - 1);
  let k = 0;
  while k < digits.length {
    if !contains("0123456789", std.Bytes.slice(digits, k, 1)) { return ""; };
    k = k + 1;
  };
  digits;
};
let churnCounts = [];
let churnValues = [1000, 2000, 100000];
let ni = 0;
while ni < churnValues.length {
  let n = churnValues[ni];
  let tag = "churn:" + num(n);
  let source = base + "/churn-" + num(n) + ".ql";
  writeFile(source, churnSource(n));
  let built = buildWith(source, base + "/churn-" + num(n), 2, runtimeObject);
  record(built.ok, tag + ":build");
  if !built.ok { showFailure(tag + ":build", built.run); };
  if built.ok {
    let binary = base + "/churn-" + num(n);
    // 100000 次循环压 1 MiB 栈:每次循环多占一帧都会溢出。
    let r = if n == 100000 {
      std.process.run(["sh", "-c", "ulimit -s 1024; exec " + sq(binary)]);
    } else {
      std.process.run([binary]);
    };
    record(r.status == 0 && r.stdout == num(n) + "\n", tag + ":run");
    if r.status != 0 || r.stdout != num(n) + "\n" { showFailure(tag + ":run", r); };
    let digits = allocDigits(r.stderr);
    record(digits != "", tag + ":stderr");
    if digits == "" { showFailure(tag + ":stderr", r); };
    // 1000/2000 用等宽输出比较:循环翻倍不应新增任何堆分配。
    if n != 100000 && digits != "" { churnCounts[churnCounts.length] = std.Number.parseFloat(digits); };
  };
  ni = ni + 1;
};
let churnEqual = churnCounts.length == 2 && churnCounts[0] == churnCounts[1];
record(churnEqual, "churn:no-growth");
if !churnEqual && churnCounts.length == 2 {
  println("DETAIL churn:no-growth counts=" + num(churnCounts[0]) + "," + num(churnCounts[1]));
};
endGroup(group, "allocation churn: instrumented runtime.c, n=1000/2000 equal, n=100000 on 1 MiB stack");

// ---- 7) 可移植 Array:显式 ArrayLibrary 模块(t29 + 错误探针)------------
// 与 run_array_tests.py --library 一致:库源码不得触碰 runtime 叶子,
// t29 与 8 个错误探针都改走 import 进来的 ArrayLibrary。
let group = startGroup();
let libraryText = readFile("stdlib/array.ql");
let forbidden = ["ql_mem_", "readU64", "writeU64", "ql_alloc", "std.Array."];
let fi = 0;
while fi < forbidden.length {
  let needle = forbidden[fi];
  record(!contains(libraryText, needle), "library:forbidden-" + needle);
  if contains(libraryText, needle) { println("DETAIL library:forbidden-" + needle); };
  fi = fi + 1;
};
let t29Text = readFile("aot/tests/t29_arrays.ql");
let rewritten = std.String.replace(t29Text)("std.Array.")("ArrayLibrary.");
let pwdText = std.String.trim(std.process.run(["pwd"]).stdout);
let libraryPath = pwdText + "/stdlib/array.ql";
let prefix = "import " + libraryPath + ";\n";
let portablePath = base + "/portable-arrays.ql";
writeFile(portablePath, prefix + rewritten);
let rewriteOk = rewritten != t29Text && !contains(rewritten, "std.Array.");
let pathOk = endsWith(libraryPath, "stdlib/array.ql") && startsWith(prefix, "import ");
record(rewriteOk && pathOk, "library:rewrite");
let portableExpected = readFile("aot/tests/t29_arrays.expected");
let p0 = build(portablePath, base + "/portable-arrays-O0", 0);
let p2 = build(portablePath, base + "/portable-arrays-O2", 2);
record(p0.ok, "library:build-O0");
record(p2.ok, "library:build-O2");
if !p0.ok { showFailure("library:build-O0", p0.run); };
if !p2.ok { showFailure("library:build-O2", p2.run); };
if p0.ok {
  let r = std.process.run([base + "/portable-arrays-O0"]);
  record(r.status == 0 && r.stdout == portableExpected && r.stderr == "", "library:O0");
  if r.status != 0 || r.stdout != portableExpected || r.stderr != "" { showFailure("library:O0", r); };
};
if p2.ok {
  let r = std.process.run([base + "/portable-arrays-O2"]);
  record(r.status == 0 && r.stdout == portableExpected && r.stderr == "", "library:O2");
  if r.status != 0 || r.stdout != portableExpected || r.stderr != "" { showFailure("library:O2", r); };
};
probeSuite("library", arrayProbeCases, prefix);
endGroup(group, "portable Array: stdlib/array.ql free of runtime leaves, t29 + 8 errors @ O0/O2");

println("QLang 值契约驱动:" + num(pass) + " 通过 / " + num(fail) + " 失败");
if failed != "" { println("失败:" + failed); };
if fail > 0 { assert(false, "value contracts failed"); 1; };
0;
