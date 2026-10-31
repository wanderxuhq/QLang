// QLang 编译器契约驱动(不依赖 Python):CLI 拒绝、assert 致命、前端 fixture。
//
//   run_compiler <stdlib-dir> [--compiler <c>]
//
// 覆盖原 run_selfhost_tests.py 中与"自举固定点"无关的检查:
//   check_rejections / check_assert_fatal / check_return_scope_rejections
//   6 个 bootstrapped/tests 前端 fixture(stage2-functions 由 run_selfhost.ql 负责)
let compiler = "target/selfhost/stage2";
let runtime = "aot/runtime.ql";
let linkTool = "target/tools/link";
let stdlibDir = "";
let rest = [];
let i = 0;
while i < args.length {
  let a = args[i];
  if a == "--compiler" { i = i + 1; compiler = args[i]; }
  else { rest[rest.length] = a; };
  i = i + 1;
};
if rest.length > 0 { stdlibDir = rest[0]; };
if stdlibDir == "" { assert(false, "usage: run_compiler <stdlib-dir> [--compiler <c>]"); 1; };

let base = "/tmp/qlang-compiler-q";
std.process.run(["rm", "-rf", base]);
std.process.run(["mkdir", "-p", base + "/modules"]);
let root = std.fs.canonicalPath(".");
if isError(root) { root = "."; };
let abs = (path) -> if std.String.startsWith(path)("/") { path; } else { root + "/" + path; };

let pass = 0; let fail = 0; let failed = "";
let num = (n) -> std.Number.toString(n);
let contains = (text, needle) -> std.String.includes(text)(needle);
let record = (ok, label) -> {
  if ok { pass = pass + 1; } else { fail = fail + 1; failed = failed + " " + label; };
  null;
};
let writeFile = (path, text) -> {
  let r = std.fs.writeText(path, text);
  if isError(r) { assert(false, "cannot write " + path); 1; };
  null;
};
let emit = (source, mode, runtimePath, out) -> {
  let r = std.process.run([compiler, mode, source, runtimePath]);
  if r.status == 0 { writeFile(out, r.stdout); };
  return r;
};
let build = (source, binary) -> {
  let emitted = std.process.run([compiler, "--emit-llvm-split", source, runtime,
                                stdlibDir + "/symbols.tsv", stdlibDir + "/mod.ql"]);
  if emitted.status != 0 { return { ok: false, run: emitted }; };
  let ir = binary + ".ll";
  writeFile(ir, emitted.stdout);
  let linked = std.process.run([linkTool, ir, "-o", binary, "--stdlib-object",
                                stdlibDir + "/stdlib.o", "--root", "."]);
  return { ok: linked.status == 0, run: linked };
};

// ---- CLI 拒绝 -------------------------------------------------------------
let rejectCases = [
  { name: "undeclared", text: "println(missing);" },
  { name: "private-runtime-read", text: "println(__arr_add);" },
  { name: "private-runtime-assign", text: "__arr_add = 1;" },
  { name: "unbound-Type", text: "println(Type);" },
  { name: "missing-module", text: "import \"./missing.ql\";" },
  { name: "invalid-parameter", text: "let f = (1) -> 2;" }
];
let ri = 0;
while ri < rejectCases.length {
  let c = rejectCases[ri];
  let source = base + "/" + c.name + ".ql";
  writeFile(source, c.text);
  let r = std.process.run([compiler, "--emit-llvm", source, runtime]);
  record(r.status == 1, "reject:" + c.name + ":status");
  record(r.stdout == "", "reject:" + c.name + ":no-ir");
  record(contains(r.stderr, "CompileError"), "reject:" + c.name + ":CompileError");
  ri = ri + 1;
};
// 运行时文件自身不完整:编译空程序 + 残缺 runtime。
let emptySource = base + "/empty.ql";
let badRuntime = base + "/incomplete-runtime.ql";
writeFile(emptySource, "");
writeFile(badRuntime, "let args = [];");
let incomplete = std.process.run([compiler, "--emit-llvm", emptySource, badRuntime]);
record(incomplete.status == 1, "reject:incomplete-runtime:status");
record(incomplete.stdout == "", "reject:incomplete-runtime:no-ir");
record(contains(incomplete.stderr, "CompileError"), "reject:incomplete-runtime:CompileError");

// ---- return 作用域(CLI + --emit-module + import 归因) --------------------
let badModule = base + "/modules/bad.ql";
writeFile(badModule, "return 2;");
let returnCases = [
  { name: "return-top-level", text: "return 1;", mode: "--emit-llvm", file: "return-top-level.ql", origin: "" },
  { name: "return-emit-module", text: "return 1;", mode: "--emit-module", file: "return-emit-module.ql", origin: "" },
  { name: "return-import-direct", text: "import \"./modules/bad.ql\";", mode: "--emit-llvm",
    file: "return-import-direct.ql", origin: badModule },
  { name: "return-import-from-function", text: "let load = () -> { import \"./modules/bad.ql\"; }; load();",
    mode: "--emit-llvm", file: "return-import-from-function.ql", origin: badModule }
];
let rsi = 0;
while rsi < returnCases.length {
  let c = returnCases[rsi];
  let source = base + "/" + c.file;
  writeFile(source, c.text);
  let r = std.process.run([compiler, c.mode, source, runtime]);
  let origin = if c.origin == "" { source; } else { c.origin; };
  record(r.status == 1, "return:" + c.name + ":status");
  record(r.stdout == "", "return:" + c.name + ":no-ir");
  record(contains(r.stderr, "CompileError"), "return:" + c.name + ":CompileError");
  record(contains(r.stderr, "return is only allowed inside a function"), "return:" + c.name + ":message");
  record(contains(r.stderr, abs(origin) + ":1:1:"), "return:" + c.name + ":origin");
  rsi = rsi + 1;
};

// ---- assert 是致命契约违反,不是 Error 值 ----------------------------------
let fatalSource = base + "/assert-fatal.ql";
writeFile(fatalSource, "println(\"before\");\nassert(false, \"boom\");\nprintln(\"after\");\n");
let fatalBuild = build(fatalSource, base + "/assert-fatal");
record(fatalBuild.ok, "assert:build");
if fatalBuild.ok {
  let r = std.process.run([base + "/assert-fatal"]);
  record(r.status == 1, "assert:status");
  record(r.stdout == "before\n", "assert:stdout");
  record(contains(r.stderr, "AssertionFailed: boom"), "assert:stderr");
};

// ---- 前端 fixture:必须由 native 编译器编出来并跑出确切 PASS 行 ------------
let frontendCases = [
  { source: "bootstrapped/tests/function_ast.ql",
    expected: "PASS function AST contracts (15 valid, 10 invalid)\n" },
  { source: "bootstrapped/tests/diagnostics.ql",
    expected: "PASS source diagnostics (39 invalid, 15 valid)\n" },
  { source: "bootstrapped/tests/return_scope.ql", expected: "" },
  { source: "bootstrapped/tests/ast_locations.ql",
    expected: "PASS AST locations (24 spans, 8 trivia cases)\n" },
  { source: "bootstrapped/tests/source_origins.ql",
    expected: "PASS bundled source origins (5 spans, wrappers, diagnostics, library)\n" },
  { source: "bootstrapped/tests/numeric_syntax.ql",
    expected: "PASS numeric syntax frontend (38 valid, 19 invalid)\n" }
];
let fi = 0;
while fi < frontendCases.length {
  let c = frontendCases[fi];
  let name = std.String.split(c.source)("/");
  let label = name[name.length - 1];
  let binary = base + "/frontend-" + num(fi);
  let b = build(c.source, binary);
  record(b.ok, "frontend:" + label + ":build");
  if b.ok {
    let expected = c.expected;
    if expected == "" {
      expected = std.fs.readFileText(std.String.replace(c.source)(".ql")(".expected"))?;
    };
    let r = std.process.run([binary]);
    record(r.status == 0, "frontend:" + label + ":status");
    record(r.stdout == expected, "frontend:" + label + ":stdout");
    record(r.stderr == "", "frontend:" + label + ":stderr");
  };
  fi = fi + 1;
};

println("QLang 编译器契约驱动:" + num(pass) + " 通过 / " + num(fail) + " 失败");
if failed != "" { println("失败:" + failed); };
if fail > 0 { assert(false, "compiler contracts failed"); 1; };
0;
