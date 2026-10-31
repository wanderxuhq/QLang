// QLang 解释器契约驱动(**不依赖 Python**)。
//
//   run_interpreter_contracts [--interpreter <path>] [<stdlib-dir>]
//
// 补上 aot/run_interpreter_tests.py 里主夹具循环(aot/tests/interpreter.txt,由
// `aot/run_tests.ql --interpreter` 跑)之外的部分,外加 aot/run_argument_tests.py:
//
//   1) assert(false) 是致命契约违反:rc 1,stdout 有 before 没有 after,stderr 有
//      `AssertionFailed: boom`;
//   2) demo/type_gymnastics.ql 的 419 条类型断言;
//   3) 函数内 import 按**定义该函数的源文件**解析(不是在 cwd 或调用方);
//   4) 13 个负例(前端错误 / 运行期错误 / 源文件读不到),rc 1 + stderr 命中 kind,
//      且 stdout 里没有 UNREACHABLE;
//   5) 2 个正例(`let x; x = null; x;` 与 `println(Null.check(null));`),rc 0 且 body 精确;
//   6) cwd 隔离:`cd /tmp && exec <interp> <绝对源路径>` 仍要跑对(import 不算 cwd);
//   7) 解释器 CLI 的 args 契约(3 个场景 / 15 行输出,来自 aot/run_argument_tests.py)。
//
// 解释器由调用方提供(默认 target/native-interpreter/interpreter);本驱动只发子进程,
// 不编译任何东西,所以不需要编译器;位置参数 `<stdlib-dir>` 只为与其他驱动同形,可省。
let interpreter = "target/native-interpreter/interpreter";
let rest = [];
let ai = 0;
while ai < args.length {
  let a = args[ai];
  if a == "--interpreter" { ai = ai + 1; interpreter = args[ai]; }
  else { rest[rest.length] = a; };
  ai = ai + 1;
};
// 统一用绝对路径:第 6 项要在 /tmp 里 exec,相对路径会失效。
let absInterpreter = std.fs.canonicalPath(interpreter);
if isError(absInterpreter) { assert(false, "interpreter not found: " + interpreter); 1; };

let base = "/tmp/qlang-interp-q";
std.process.run(["rm", "-rf", base]);
std.process.run(["mkdir", "-p", base]);

let pass = 0; let fail = 0; let failed = "";
let num = (n) -> std.Number.toString(n);
let contains = (text, needle) -> std.String.includes(text)(needle);
let record = (ok, label, detail) -> {
  if ok { pass = pass + 1; }
  else {
    fail = fail + 1;
    failed = failed + " " + label;
    if detail != "" { println("  FAIL " + label + ": " + detail); };
  };
  ok;
};
let sq = (v) -> "'" + std.String.replace(v)("'")("'\\''") + "'";
let sh = (cmd) -> std.process.run(["sh", "-c", cmd]);
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

// 解释器正常输出被 `Interpreting...\n` 与 `Execution complete.` 包裹;
// body 是两者之间的程序输出。诊断类错误没有 wrapper,单独按 rc/stderr 判。
let MARK = "Interpreting...\n";
let END = "Execution complete.";
let indexOf = (text, needle, from) -> {
  let i = from; let found = -1;
  while found < 0 && i + needle.length <= text.length {
    if std.Bytes.slice(text, i, needle.length) == needle { found = i; } else { i = i + 1; };
  };
  found;
};
let hasMarker = (stdout) -> indexOf(stdout, MARK, 0) >= 0;
let bodyOf = (stdout) -> {
  let start = indexOf(stdout, MARK, 0);
  if start < 0 { return ""; };
  let inner = std.Bytes.slice(stdout, start + MARK.length, stdout.length - start - MARK.length);
  let stop = indexOf(inner, END, 0);
  if stop < 0 { return inner; };
  std.Bytes.slice(inner, 0, stop);
};
let terminated = (stdout) -> std.String.endsWith(stdout)("Execution complete.\n");
// 正常执行的完整外壳:rc 0、无 stderr、两个标记都在(以 END 结尾)。
let wrapperOk = (r) -> r.status == 0 && r.stderr == "" && hasMarker(r.stdout) && terminated(r.stdout);
let runInterp = (source, extras) -> {
  let cmd = [absInterpreter, source];
  let i = 0;
  while i < extras.length { cmd[cmd.length] = extras[i]; i = i + 1; };
  std.process.run(cmd);
};
let failDetail = (r) -> "status=" + num(r.status) + " stderr=" + r.stderr + " body=" + bodyOf(r.stdout);

// ---- 1) assert(false) 是致命契约违反,不是可捕获的 Error 值 ------------------
let assertSource = base + "/assert-fatal.ql";
writeFile(assertSource, "println(\"before\");\nassert(false, \"boom\");\nprintln(\"after\");\n");
let ar = runInterp(assertSource, []);
record(ar.status == 1 && contains(ar.stdout, "before\n") && !contains(ar.stdout, "after\n") &&
       contains(ar.stderr, "AssertionFailed: boom"),
       "assert-fatal", failDetail(ar));

// ---- 2) 419 条类型系统断言(两引擎必须输出一致) ---------------------------
let tg = runInterp("demo/type_gymnastics.ql", []);
record(wrapperOk(tg) && contains(bodyOf(tg.stdout), "RESULT: 419/419 asserts passed"),
       "type-gymnastics:419", failDetail(tg));

// ---- 3) 函数内 import 按定义文件解析 ---------------------------------------
std.process.run(["mkdir", "-p", base + "/modules"]);
writeFile(base + "/modules/value.ql", "export { answer: 42 };");
writeFile(base + "/modules/factory.ql",
          "let load = () -> { let m = import ./value.ql; m.answer; }; export load;");
writeFile(base + "/dynamic.ql", "let m = import ./modules/factory.ql; println(m.load());");
let dyn = runInterp(base + "/dynamic.ql", []);
record(wrapperOk(dyn) && bodyOf(dyn.stdout) == "42\n", "dynamic-import:def-path", failDetail(dyn));

// ---- 4) 13 个负例(源码文本与 aot/run_interpreter_tests.py 逐字一致) --------
let negativeCases = [
  // 读未确定赋值的绑定现在是前端错误。
  { name: "uninitialized", text: "let x; x;", kind: "reading uninitialized variable: x" },
  { name: "propagate", text: "let x; x?; println(\"UNREACHABLE\");", kind: "reading uninitialized variable: x" },
  { name: "undeclared", text: "missing;", kind: "UndefinedVariable" },
  { name: "assign-undeclared", text: "missing = 1; println(\"UNREACHABLE\");", kind: "UndefinedVariable" },
  { name: "assign-hidden", text: "if true { let x = 1; }; x = 2; println(\"UNREACHABLE\");", kind: "UndefinedVariable" },
  { name: "assign-member", text: "missing.field = 1; println(\"UNREACHABLE\");", kind: "UndefinedVariable" },
  { name: "assign-index", text: "missing[0] = 1; println(\"UNREACHABLE\");", kind: "UndefinedVariable" },
  { name: "assign-uninitialized-member", text: "let x; x.field = 1; println(\"UNREACHABLE\");", kind: "reading uninitialized variable: x" },
  { name: "assign-uninitialized-index", text: "let x; x[0] = 1; println(\"UNREACHABLE\");", kind: "reading uninitialized variable: x" },
  { name: "parse", text: "let f = (1) -> 2; println(\"UNREACHABLE\");", kind: "ParseError" },
  { name: "error", text: "Error.raise(\"intentional\");", kind: "Error: intentional" },
  // `??` 不会让读未初始化的绑定合法。
  { name: "coalesce-uninitialized", text: "let x; x ?? null;", kind: "reading uninitialized variable: x" },
  // 源文件不存在:开跑前就报 IOError。
  { name: "read", text: null, kind: "IOError" }
];
let ni = 0;
while ni < negativeCases.length {
  let c = negativeCases[ni];
  let source = base + "/" + c.name + ".ql";
  if c.text != null { writeFile(source, c.text); } else { std.fs.remove(source); };
  let r = runInterp(source, []);
  record(r.status == 1 && contains(r.stderr, c.kind) && !contains(r.stdout, "UNREACHABLE"),
         "negative:" + c.name, failDetail(r));
  ni = ni + 1;
};

// ---- 5) 正例:null 是已初始化,不是未初始化状态 ----------------------------
let positiveCases = [
  { name: "null-init", text: "let x; x = null; x;", expected: "" },
  { name: "null-check", text: "println(Null.check(null));", expected: "true\n" }
];
let pi = 0;
while pi < positiveCases.length {
  let c = positiveCases[pi];
  let source = base + "/" + c.name + ".ql";
  writeFile(source, c.text);
  let r = runInterp(source, []);
  record(wrapperOk(r) && bodyOf(r.stdout) == c.expected, "positive:" + c.name, failDetail(r));
  pi = pi + 1;
};

// ---- 6) cwd 隔离:在 /tmp 里用绝对源路径跑带 import 的夹具 ------------------
// t35 的 `import ./modules/scoped/exports.ql` 必须相对 aot/tests/ 解析,cwd 无关。
let absFixture = std.fs.canonicalPath("aot/tests/t35_scoped_modules.ql");
if isError(absFixture) { assert(false, "cannot resolve fixture path"); 1; };
let t35 = sh("cd /tmp && exec " + sq(absInterpreter) + " " + sq(absFixture));
record(wrapperOk(t35) && bodyOf(t35.stdout) == readFile("aot/tests/t35_scoped_modules.expected"),
       "cwd-isolation:t35_scoped_modules", failDetail(t35));
let absDynamic = std.fs.canonicalPath(base + "/dynamic.ql");
if isError(absDynamic) { assert(false, "cannot resolve dynamic import source"); 1; };
let dyn2 = sh("cd /tmp && exec " + sq(absInterpreter) + " " + sq(absDynamic));
record(wrapperOk(dyn2) && bodyOf(dyn2.stdout) == "42\n", "cwd-isolation:dynamic-import", failDetail(dyn2));

// ---- 7) 解释器 CLI 的 args 契约(3 个场景 / 15 行) --------------------------
writeFile(base + "/nested.ql", "export { nestedArgs: args };");
writeFile(base + "/module.ql",
          "let received = args;\n"
          + "args = [\"module rebound\"];\n"
          + "let child = import ./nested.ql;\n"
          + "let change = () -> { received[0] = \"changed\"; };\n"
          + "export { received, change, nestedArgs: child.nestedArgs, localArgs: args };\n");
let scenario = (name, text, extras, expected, label) -> {
  let source = base + "/" + name + ".ql";
  writeFile(source, text);
  let r = runInterp(source, extras);
  record(wrapperOk(r) && bodyOf(r.stdout) == expected, label, failDetail(r));
  null;
};
scenario("empty", "println(args.length);\n", [], "0\n", "args:empty");
scenario("values",
         "println(args.length);\n"
         + "println(String.check(args[0]));\n"
         + "println(args[0] == \"with spaces\");\n"
         + "println(args[1] == \"\");\n"
         + "println(args[2] == \"中文\");\n"
         + "println(args[3] == \"--flag\");\n",
         ["with spaces", "", "中文", "--flag"],
         "4\ntrue\ntrue\ntrue\ntrue\ntrue\n", "args:values");
scenario("scope",
         "let original = args;\n"
         + "if true { let args = [\"local\"]; println(args[0] == \"local\"); };\n"
         + "println(args[0] == \"process\");\n"
         + "args = [\"rebound\"];\n"
         + "let ns = import ./module.ql;\n"
         + "println(ns.received[0] == \"process\");\n"
         + "println(ns.nestedArgs[0] == \"process\");\n"
         + "println(ns.localArgs[0] == \"module rebound\");\n"
         + "ns.change();\n"
         + "println(original[0] == \"changed\");\n"
         + "println(ns.nestedArgs[0] == \"changed\");\n"
         + "println(args[0] == \"rebound\");\n",
         ["process"], "true\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\ntrue\n", "args:scope");

println("QLang 解释器契约驱动:" + num(pass) + " 通过 / " + num(fail) + " 失败");
if failed != "" { println("失败:" + failed); };
if fail > 0 { assert(false, "interpreter contracts failed"); 1; };
0;
