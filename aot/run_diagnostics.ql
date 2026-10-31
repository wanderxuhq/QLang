// QLang 诊断测试驱动(不依赖 Python):编译期诊断 + 运行期诊断 + assignment 契约。
//
//   run_diagnostics [<stdlib-dir>] [--compiler <c>] [--interpreter <i>] [--opt 0,2] [--skip-interpreter]
//
// 覆盖原 Python 套件:
//   run_semantic_diagnostic_tests.py  编译错误的位置/消息/无实现栈
//   run_diagnostic_tests.py           解析错误(compiler + core)与 return 作用域
//   run_assignment_tests.py           顶层赋值失败面 + failed module 不发布 export
//   run_runtime_diagnostic_tests.py   t38/t39 的 argv 模式与精确 `  at ` 帧
//   run_source_context_tests.py       t40/native_source_bridge 的上下文模式
//
// 所有用例都在临时目录里现写,避免污染 aot/tests;fixture 只读。
let compiler = "target/selfhost/stage2";
let interpreter = "target/native-interpreter/interpreter";
let linkTool = "target/tools/link";
let runtime = "aot/runtime.ql";
let stdlibDir = "";
let optLevels = [0, 2];
let skipInterpreter = false;
let rest = [];
let i = 0;
while i < args.length {
  let a = args[i];
  if a == "--compiler" { i = i + 1; compiler = args[i]; }
  else if a == "--stdlib-dir" { i = i + 1; stdlibDir = args[i]; }
  else if a == "--interpreter" { i = i + 1; interpreter = args[i]; }
  else if a == "--opt" {
    i = i + 1;
    let parts = std.String.split(args[i])(",");
    let levels = []; let j = 0;
    while j < parts.length { levels[levels.length] = std.Number.parseFloat(parts[j]); j = j + 1; };
    optLevels = levels;
  }
  else if a == "--skip-interpreter" { skipInterpreter = true; }
  else { rest[rest.length] = a; };
  i = i + 1;
};
if rest.length > 0 { stdlibDir = rest[0]; };
let base = "/tmp/qlang-diagnostics-q";
std.process.run(["rm", "-rf", base]);
std.process.run(["mkdir", "-p", base + "/lib"]);
std.process.run(["mkdir", "-p", base + "/return-modules"]);
// 编译器/解释器把 source 规范化成绝对路径,fixture 断言也要用绝对路径。
let root = std.fs.canonicalPath(".");
if isError(root) { root = "."; };
let abs = (path) -> if std.String.startsWith(path)("/") { path; } else { root + "/" + path; };

let pass = 0; let fail = 0; let failed = "";
let num = (n) -> std.Number.toString(n);
let contains = (text, needle) -> std.String.includes(text)(needle);
let startsWith = (text, prefix) -> std.String.startsWith(text)(prefix);
let record = (ok, label) -> {
  if ok { pass = pass + 1; } else { fail = fail + 1; failed = failed + " " + label; };
  null;
};
let writeFile = (path, text) -> {
  let r = std.fs.writeText(path, text);
  if isError(r) { assert(false, "cannot write " + path + ": " + r.message); 1; };
  null;
};
let readFile = (path) -> {
  let r = std.fs.readFileText(path);
  if isError(r) { assert(false, "cannot read " + path + ": " + r.message); 1; };
  r;
};
let frameLines = (stderr) -> {
  let out = []; let rows = std.String.split(stderr)("\n"); let k = 0;
  while k < rows.length {
    if startsWith(rows[k], "  at ") { out[out.length] = rows[k]; };
    k = k + 1;
  };
  out;
};
let sameFrames = (actual, wanted) -> {
  if actual.length != wanted.length { return false; };
  let k = 0;
  while k < actual.length {
    if actual[k] != wanted[k] { return false; };
    k = k + 1;
  };
  return true;
};
let framesText = (frames) -> {
  let out = ""; let k = 0;
  while k < frames.length { out = out + "[" + frames[k] + "]"; k = k + 1; };
  out;
};
// 编译 + 链接一次;返回 { ok, stage, result }。
let build = (source, binary, opt) -> {
  let emitArgs = [compiler, "--emit-llvm", source, runtime];
  if stdlibDir != "" {
    emitArgs = [compiler, "--emit-llvm-split", source, runtime,
                stdlibDir + "/symbols.tsv", stdlibDir + "/mod.ql"];
  };
  let emitted = std.process.run(emitArgs);
  if emitted.status != 0 { return { ok: false, stage: "emit", run: emitted }; };
  let ir = binary + ".ll";
  let wrote = std.fs.writeText(ir, emitted.stdout);
  if isError(wrote) { return { ok: false, stage: "write-ir", run: wrote }; };
  let linkArgs = [linkTool, ir, "-o", binary, "--opt", num(opt), "--root", "."];
  if stdlibDir != "" {
    linkArgs[linkArgs.length] = "--stdlib-object";
    linkArgs[linkArgs.length] = stdlibDir + "/stdlib.o";
  };
  let linked = std.process.run(linkArgs);
  if linked.status != 0 { return { ok: false, stage: "link", run: linked }; };
  return { ok: true, stage: "", run: linked };
};

// ---- 1. 编译期诊断 ---------------------------------------------------------
// `runs`: "c" = compiler, "ci" = compiler + interpreter; position 用 `origin` 指定。
let compileCases = [
  // semantic diagnostics (compiler only)
  { name: "sem-unicode-read", file: "sem-unicode-read.ql", source: "\"中😀\";\r\n  println((missing));",
    origin: "self", line: 2, col: 12, message: "undeclared name: missing", runs: "c" },
  { name: "sem-assignment", file: "sem-assignment.ql", source: "let f = () -> {\n  unknown = 3;\n};",
    origin: "self", line: 2, col: 3, message: "assignment to undeclared name: unknown", runs: "c" },
  { name: "sem-dependency", file: "sem-dependency.ql", source: "import \"./lib.ql\";",
    depPath: "lib.ql", depSource: "\nlet f = () -> {\n  println(missing);\n};",
    origin: "lib.ql", line: 3, col: 11, message: "undeclared name: missing", runs: "c" },
  { name: "sem-import-site", file: "sem-import-site.ql", source: "\n  import \"./absent.ql\";",
    origin: "self", line: 2, col: 3, message: "", runs: "c" },
  { name: "sem-uninitialized-field", file: "sem-uninitialized-field.ql", source: "let x; x.field = 1;",
    origin: "self", line: 1, col: 8, message: "reading uninitialized variable: x", runs: "c" },
  { name: "sem-uninitialized-index", file: "sem-uninitialized-index.ql", source: "let x = []; let index; x[index] = 1;",
    origin: "self", line: 1, col: 26, message: "reading uninitialized variable: index", runs: "c" },
  { name: "sem-annotation-literal", file: "sem-annotation-literal.ql", source: "let bad: Number = \"x\";",
    origin: "self", line: 1, col: 1,
    message: "type mismatch: value of type String does not match the annotated type Number", runs: "c" },
  { name: "sem-propagate-number", file: "sem-propagate-number.ql",
    source: "let f = (): Number -> {\n  let z = 0;\n  let v = (1 / z)?;\n  v;\n};",
    origin: "self", line: 3, col: 18, message: "? requires a Result or Option return type", runs: "c" },
  { name: "sem-propagate-string", file: "sem-propagate-string.ql",
    source: "let f = (): String -> {\n  let z = 0;\n  let v = (1 / z)?;\n  v;\n};",
    origin: "self", line: 3, col: 18, message: "? requires a Result or Option return type", runs: "c" },
  { name: "sem-propagate-interpolation", file: "sem-propagate-interpolation.ql",
    source: "let f = (): Number -> {\n  let z = 0;\n  let s = `\${(1 / z)?}`;\n  s;\n};",
    origin: "self", line: 3, col: 21, message: "? requires a Result or Option return type", runs: "c" },
  { name: "sem-array-placeholder", file: "sem-array-placeholder.ql", source: "let T = Array(3);",
    origin: "self", line: 1, col: 9, message: "Array is a placeholder", runs: "c" },
  // parse diagnostics (compiler + interpreter)
  { name: "parse-array", file: "parse-array.ql", source: "// comment\nlet x = [1;\nprintln(\"UNREACHABLE\");",
    origin: "self", line: 2, col: 11, message: "", runs: "ci" },
  { name: "parse-call", file: "parse-call.ql", source: "println(1;\nprintln(\"UNREACHABLE\");",
    origin: "self", line: 1, col: 10, message: "", runs: "ci" },
  { name: "parse-block", file: "parse-block.ql", source: "let f = () -> {\n 1;",
    origin: "self", line: 2, col: 4, message: "", runs: "ci" },
  { name: "parse-unicode", file: "parse-unicode.ql", source: "\"中😀\"; let x = ;\nprintln(\"UNREACHABLE\");",
    origin: "self", line: 1, col: 15, message: "", runs: "ci" },
  { name: "parse-crlf", file: "parse-crlf.ql", source: "// comment\r\nlet x = ;",
    origin: "self", line: 2, col: 9, message: "", runs: "ci" },
  { name: "parse-interpolation", file: "parse-interpolation.ql", source: "let x = `text \${1 + }`;",
    origin: "self", line: 1, col: 21, message: "", runs: "ci" },
  { name: "parse-comment", file: "parse-comment.ql", source: "\n/* unclosed",
    origin: "self", line: 2, col: 1, message: "", runs: "ci" },
  { name: "parse-chain", file: "parse-chain.ql",
    source: "println(\"UNREACHABLE\");\nlet a = 0; let b = 0;\na = b = 1;",
    origin: "self", line: 3, col: 7, message: "", runs: "ci" },
  { name: "parse-chain-member", file: "parse-chain-member.ql",
    source: "println(\"UNREACHABLE\");\nlet o = {}; let b = 0;\no.x = b = 1;",
    origin: "self", line: 3, col: 9, message: "", runs: "ci" },
  { name: "parse-chain-index", file: "parse-chain-index.ql",
    source: "println(\"UNREACHABLE\");\nlet a = []; let b = 0;\na[0] = b = 1;",
    origin: "self", line: 3, col: 10, message: "", runs: "ci" },
  { name: "parse-chain-function", file: "parse-chain-function.ql",
    source: "println(\"UNREACHABLE\");\nlet f = () -> { a = b = 1; };",
    origin: "self", line: 2, col: 23, message: "", runs: "ci" },
  { name: "parse-chain-crlf", file: "parse-chain-crlf.ql",
    source: "\"中😀\";\r\na =\r\n b = 1;\nprintln(\"UNREACHABLE\");",
    origin: "self", line: 3, col: 4, message: "", runs: "ci" },
  // return scope (compiler + interpreter)
  { name: "return-root-after-marker", file: "return-root-after-marker.ql",
    source: "println(\"UNREACHABLE before\"); return 1; println(\"UNREACHABLE after\");",
    origin: "self", line: 1, col: 32, message: "return is only allowed inside a function", runs: "ci" },
  { name: "return-dead-branch", file: "return-dead-branch.ql",
    source: "if false { println(\"UNREACHABLE\"); return 1; };",
    origin: "self", line: 1, col: 36, message: "return is only allowed inside a function", runs: "ci" },
  { name: "return-after-function", file: "return-after-function.ql",
    source: "let f = () -> { return 1; }; return 2;",
    origin: "self", line: 1, col: 30, message: "return is only allowed inside a function", runs: "ci" },
  { name: "return-param-annotation", file: "return-param-annotation.ql",
    source: "let f = (x: if true { return Number; } else { Number; }) -> x;",
    origin: "self", line: 1, col: 23, message: "return is only allowed inside a function", runs: "ci" },
  { name: "return-interpolation", file: "return-interpolation.ql",
    source: "let text = \"v=\${if true { return 1; } else { 2; }}\";",
    origin: "self", line: 1, col: 27, message: "return is only allowed inside a function", runs: "ci" },
  { name: "return-import-direct", file: "return-modules/return-import-direct.ql",
    source: "import \"./bad.ql\"; println(\"UNREACHABLE ENTRY\");",
    depPath: "return-modules/bad.ql", depSource: "println(\"UNREACHABLE MODULE\");\r\nreturn 3;",
    origin: "return-modules/bad.ql", line: 2, col: 1,
    message: "return is only allowed inside a function", runs: "ci" },
  { name: "return-import-from-function", file: "return-modules/return-import-from-function.ql",
    source: "let load = () -> { import \"./bad.ql\"; }; load();",
    depPath: "return-modules/bad.ql", depSource: "println(\"UNREACHABLE MODULE\");\r\nreturn 3;",
    origin: "return-modules/bad.ql", line: 2, col: 1,
    message: "return is only allowed inside a function", runs: "ci" },
  { name: "parse-imported-unicode", file: "main.ql",
    source: "import \"./lib/中 file.ql\"; println(\"UNREACHABLE\");",
    depPath: "lib/中 file.ql", depSource: "// imported\n\nlet x = ;",
    origin: "lib/中 file.ql", line: 3, col: 9, message: "", runs: "ci" }
];

// 19 个非法数字字面量,全在 2:9。
let numberLiterals = ["0x", "0X", "0xg", "0x1g", "0x1.2", "0x1p2",
                      "1e", "1e+", "1e-", "1.e", "1e++2", "1e2x",
                      "1.2.3", "1..2", ".5.6", "12abc", "1_000", "0b10", "0o10"];
let ni = 0;
while ni < numberLiterals.length {
  compileCases[compileCases.length] = {
    name: "number-" + num(ni), file: "number-" + num(ni) + ".ql",
    source: "// number\nlet x = " + numberLiterals[ni] + ";\nprintln(\"UNREACHABLE\");",
    origin: "self", line: 2, col: 9, message: "", runs: "ci"
  };
  ni = ni + 1;
};

let ensureInterpreter = () -> {
  if skipInterpreter { return null; };
  let probe = std.fs.readFileText(interpreter);
  if isError(probe) {
    let dir = "target/native-interpreter";
    std.process.run(["mkdir", "-p", dir]);
    let emitted = std.process.run([compiler, "--emit-llvm", "bootstrapped/run_file.ql", runtime]);
    if emitted.status != 0 { assert(false, "cannot emit interpreter: " + emitted.stderr); 1; };
    let ir = base + "/interpreter.ll";
    writeFile(ir, emitted.stdout);
    let linked = std.process.run([linkTool, ir, "-o", interpreter, "--root", "."]);
    if linked.status != 0 { assert(false, "cannot link interpreter: " + linked.stderr); 1; };
  };
  null;
};

if !skipInterpreter { ensureInterpreter(); };

// compiler usage contract
let usage = std.process.run([compiler]);
record(usage.status == 1, "usage:status");
record(usage.stdout == "", "usage:stdout-empty");
record(usage.stderr == "CompileError: usage: qlangc --emit-llvm|--emit-module source.ql runtime.ql\n", "usage:stderr-exact");

let ci = 0;
while ci < compileCases.length {
  let c = compileCases[ci];
  let path = base + "/" + c.file;
  if std.Object.hasOwn(c)("depPath") {
    writeFile(base + "/" + c.depPath, c.depSource);
  };
  writeFile(path, c.source);
  let originPath = if c.origin == "self" { path; } else { base + "/" + c.origin; };
  let position = originPath + ":" + num(c.line) + ":" + num(c.col) + ": ";
  let emitted = std.process.run([compiler, "--emit-llvm", path, runtime]);
  record(emitted.status == 1, c.name + ":compile-status");
  record(emitted.stdout == "", c.name + ":compile-no-ir");
  record(contains(emitted.stderr, "CompileError"), c.name + ":compile-error");
  record(contains(emitted.stderr, position), c.name + ":compile-position");
  if c.message != "" { record(contains(emitted.stderr, c.message), c.name + ":compile-message"); };
  record(!contains(emitted.stderr, "/aot/qlangc.ql:"), c.name + ":no-emitter-frame");
  record(!contains(emitted.stderr, "/bootstrapped/"), c.name + ":no-bootstrap-frame");
  if c.runs == "ci" && !skipInterpreter {
    let interpreted = std.process.run([interpreter, path]);
    record(interpreted.status == 1, c.name + ":interp-status");
    record(contains(interpreted.stderr, "ParseError"), c.name + ":interp-parse-error");
    record(contains(interpreted.stderr, position), c.name + ":interp-position");
    record(!contains(interpreted.stdout, "UNREACHABLE"), c.name + ":interp-no-unreachable");
  };
  ci = ci + 1;
};

// 核心解释器在函数体里 import 时,位置必须落在被 import 的文件。
let factoryPath = base + "/lib/factory.ql";
writeFile(factoryPath, "let load = () -> { import \"./中 file.ql\"; }; export load;");
let factoryEntry = base + "/factory-entry.ql";
writeFile(factoryEntry, "import \"./lib/factory.ql\"; load()?; println(\"UNREACHABLE\");");
if !skipInterpreter {
  let r = std.process.run([interpreter, factoryEntry]);
  record(r.status == 1, "factory-import:status");
  record(contains(r.stderr, base + "/lib/中 file.ql:3:9:"), "factory-import:position");
  record(!contains(r.stdout, "UNREACHABLE"), "factory-import:no-unreachable");
};

// ---- 2. assignment 顶层失败面 ----------------------------------------------
let assignCases = [
  { name: "uninitialized-through-call", code: "let x; let f = () -> x; f().field = 1;", kind: "Uninitialized" },
  { name: "null-field", code: "let x = null; x.field = 1;", kind: "NotAnObject" },
  { name: "number-field", code: "let x = 42; x.field = 1;", kind: "NotAnObject" },
  { name: "null-index", code: "let x = null; x[0] = 1;", kind: "CannotIndex" },
  { name: "string-index", code: "let x = \"abc\"; x[0] = 1;", kind: "CannotIndex" },
  { name: "array-far", code: "let x = [1]; x[2] = 1;", kind: "IndexOutOfBounds" },
  { name: "array-negative", code: "let x = [1]; x[-2] = 1;", kind: "IndexOutOfBounds" },
  { name: "array-fraction", code: "let x = [1]; x[0.5] = 1;", kind: "IndexOutOfBounds" },
  { name: "array-string", code: "let x = [1]; x[\"0\"] = 1;", kind: "CannotIndex" },
  { name: "object-bool", code: "let x = {}; x[true] = 1;", kind: "CannotIndex" },
  { name: "object-array", code: "let x = {}; x[[]] = 1;", kind: "CannotIndex" },
  { name: "missing-parent", code: "let x = {}; x.missing.field = 1;", kind: "UndefinedField" },
  { name: "protected-field", code: "Number.check = (v) -> false;", kind: "Custom" },
  { name: "protected-index", code: "let alias = Error; alias[\"raise\"] = null;", kind: "Custom" },
  { name: "loop", code: "while true { if true { let x = []; x[1] = 2; }; };", kind: "IndexOutOfBounds" }
];

let dispatch = "";
let ai = 0;
while ai < assignCases.length {
  dispatch = dispatch + "if args[0] == \"" + assignCases[ai].name + "\" { " + assignCases[ai].code + " };\n";
  ai = ai + 1;
};
let exitsSource = base + "/exits.ql";
writeFile(exitsSource, dispatch + "println(\"UNREACHABLE\");\n");
let exitsBuild = build(exitsSource, base + "/exits", 2);
record(exitsBuild.ok, "assignment:build");
if exitsBuild.ok {
  let ai2 = 0;
  while ai2 < assignCases.length {
    let c = assignCases[ai2];
    let r = std.process.run([base + "/exits", c.name]);
    record(r.status == 1, "assignment:" + c.name + ":status");
    record(r.stdout == "", "assignment:" + c.name + ":stdout-empty");
    record(contains(r.stderr, c.kind), "assignment:" + c.name + ":kind");
    ai2 = ai2 + 1;
  };
};

// t21 聚合 fixture:原生 + 解释器,stdout 精确、stderr 为空。
let t21 = "aot/tests/t21_assignments.ql";
let t21Expected = readFile("aot/tests/t21_assignments.expected");
let t21Build = build(t21, base + "/t21", 2);
record(t21Build.ok, "assignment:t21-build");
if t21Build.ok {
  let r = std.process.run([base + "/t21"]);
  record(r.status == 0, "assignment:t21:status");
  record(r.stdout == t21Expected, "assignment:t21:stdout");
  record(r.stderr == "", "assignment:t21:stderr");
};
if !skipInterpreter {
  let r = std.process.run([interpreter, t21]);
  let body = std.String.split(r.stdout)("Interpreting...\n");
  let out = if body.length > 1 { std.String.split(body[1])("Execution complete.")[0]; } else { ""; };
  record(r.status == 0, "assignment:t21-interp:status");
  record(out == t21Expected, "assignment:t21-interp:stdout");
};

// 解释器逐例:每个源文件独立,失败后 CANNOT 继续执行。
if !skipInterpreter {
  let aj = 0;
  while aj < assignCases.length {
    let c = assignCases[aj];
    let path = base + "/interp-" + c.name + ".ql";
    writeFile(path, c.code + "\nprintln(\"UNREACHABLE\");\n");
    let r = std.process.run([interpreter, path]);
    record(r.status == 1, "assignment-interp:" + c.name + ":status");
    record(contains(r.stderr, c.kind), "assignment-interp:" + c.name + ":kind");
    record(!contains(r.stdout, "UNREACHABLE"), "assignment-interp:" + c.name + ":no-unreachable");
    aj = aj + 1;
  };
};

// failed module 不发布 export,调用方已有绑定不被覆盖。
let failedModule = base + "/failed-module.ql";
let importsSource = base + "/imports.ql";
writeFile(failedModule, "export { leaked: 99 }; let a = []; a[1] = 2; println(\"UNREACHABLE\");");
writeFile(importsSource, "let leaked = 7; let m = import ./failed-module.ql; println(m.type); println(leaked);");
let importsBuild = build(importsSource, base + "/imports", 2);
record(importsBuild.ok, "failed-module:build");
if importsBuild.ok {
  let r = std.process.run([base + "/imports"]);
  record(r.status == 0, "failed-module:status");
  record(r.stdout == "IndexOutOfBounds\n7\n", "failed-module:stdout");
  record(r.stderr == "", "failed-module:stderr");
};

// ---- 3. 运行期诊断 ---------------------------------------------------------
// 每个 fixture:按 opt 各建一次,再跑 default + modes。
let t38 = "aot/tests/t38_runtime_diagnostics.ql";
let t39 = "aot/tests/t39_runtime_module_diagnostics.ql";
let t40 = "aot/tests/t40_diagnostic_context.ql";
let bridge = "bootstrapped/tests/native_source_bridge.ql";

let t38Expected = "runtime source checks: 17\n";
let t39Expected = "runtime module source checks: 7\n";
let t40Expected = "diagnostic context checks: 12\n";
let bridgeExpected = "native source bridge checks: 8\n";

let t38Modes = [
  { name: "fail", origin: "t38", frames: null, extra: "caused by:" },
  { name: "cached", origin: "t38", frames: [], extra: "" },
  { name: "first", origin: "t38", frames: [{"file": "t38", "line": 9, "col": 13}], extra: "" },
  { name: "second", origin: "t38", frames: [{"file": "t38", "line": 10, "col": 14}], extra: "" },
  { name: "recursive", origin: "t38", frames: [
    {"file": "t38", "line": 17, "col": 52}, {"file": "t38", "line": 17, "col": 52},
    {"file": "t38", "line": 17, "col": 52}, {"file": "t38", "line": 18, "col": 17}
  ], extra: "" },
  { name: "library", origin: "library", frames: null, extra: "  at " + abs(t38) + ":34:" }
];
// 上面的 frames 是对象,统一展开成字符串。
let expandFrames = (fixture, mode) -> {
  if mode.frames == null { return null; };
  let out = []; let k = 0;
  while k < mode.frames.length {
    let f = mode.frames[k];
    let file = if f.file == "t38" || f.file == "t39" { abs(fixture); } else { f.file; };
    out[out.length] = "  at " + file + ":" + num(f.line) + ":" + num(f.col);
    k = k + 1;
  };
  out;
};

// t38 的 fail 需要两个 origin,单独跑。
let runT38 = (binary, opt) -> {
  let d = std.process.run([binary]);
  record(d.status == 0, "t38/O" + num(opt) + ":default-status");
  record(d.stdout == t38Expected, "t38/O" + num(opt) + ":default-stdout");
  record(d.stderr == "", "t38/O" + num(opt) + ":default-stderr");
  let mi = 0;
  while mi < t38Modes.length {
    let m = t38Modes[mi];
    let r = std.process.run([binary, m.name]);
    record(r.status == 1, "t38/O" + num(opt) + "/" + m.name + ":status");
    record(r.stdout == t38Expected, "t38/O" + num(opt) + "/" + m.name + ":stdout");
    if m.name == "library" {
      record(startsWith(r.stderr, "stdlib/string.ql:"), "t38/O" + num(opt) + "/library:origin");
      record(contains(r.stderr, "  at " + abs(t38) + ":34:"), "t38/O" + num(opt) + "/library:frame");
    } else if m.name == "fail" {
      record(contains(r.stderr, abs(t38) + ":20:15:"), "t38/O" + num(opt) + "/fail:origin-chain");
      record(contains(r.stderr, abs(t38) + ":3:14:"), "t38/O" + num(opt) + "/fail:origin-source");
      record(contains(r.stderr, "caused by:"), "t38/O" + num(opt) + "/fail:cause");
    } else {
      record(startsWith(r.stderr, abs(t38) + ":7:14:"), "t38/O" + num(opt) + "/" + m.name + ":origin");
      let frames = expandFrames(t38, m);
      record(sameFrames(frameLines(r.stderr), frames), "t38/O" + num(opt) + "/" + m.name + ":frames got " + framesText(frameLines(r.stderr)) + " want " + framesText(frames));
    };
    record(!contains(r.stderr, "/bootstrapped/"), "t38/O" + num(opt) + "/" + m.name + ":no-bootstrap");
    record(!contains(r.stderr, "<stdlib_bundle>"), "t38/O" + num(opt) + "/" + m.name + ":no-bundle");
    mi = mi + 1;
  };
  null;
};

let runT39 = (binary, opt) -> {
  let d = std.process.run([binary]);
  record(d.status == 0, "t39/O" + num(opt) + ":default-status");
  record(d.stdout == t39Expected, "t39/O" + num(opt) + ":default-stdout");
  record(d.stderr == "", "t39/O" + num(opt) + ":default-stderr");
  let modes = [
    { name: "trace", origin: abs("aot/tests/runtime_diagnostics/lib.ql") + ":3:9",
      frames: [abs(t39) + ":12:19", abs(t39) + ":13:14"] },
    { name: "import", origin: abs("aot/tests/runtime_diagnostics/failure.ql") + ":2:3",
      frames: [abs(t39) + ":9:15"] },
    { name: "assign", origin: abs(t39) + ":18:57", frames: null }
  ];
  let mi = 0;
  while mi < modes.length {
    let m = modes[mi];
    let r = std.process.run([binary, m.name]);
    record(r.status == 1, "t39/O" + num(opt) + "/" + m.name + ":status");
    record(r.stdout == t39Expected, "t39/O" + num(opt) + "/" + m.name + ":stdout");
    record(startsWith(r.stderr, m.origin + ":"), "t39/O" + num(opt) + "/" + m.name + ":origin");
    if m.frames != null {
      let wanted = []; let k = 0;
      while k < m.frames.length { wanted[wanted.length] = "  at " + m.frames[k]; k = k + 1; };
      record(sameFrames(frameLines(r.stderr), wanted), "t39/O" + num(opt) + "/" + m.name + ":frames " + framesText(frameLines(r.stderr)));
    };
    record(!contains(r.stderr, "/bootstrapped/"), "t39/O" + num(opt) + "/" + m.name + ":no-bootstrap");
    record(!contains(r.stderr, "<stdlib_bundle>"), "t39/O" + num(opt) + "/" + m.name + ":no-bundle");
    mi = mi + 1;
  };
  null;
};

let runT40 = (binary, opt) -> {
  let d = std.process.run([binary]);
  record(d.status == 0, "t40/O" + num(opt) + ":default-status");
  record(d.stdout == t40Expected, "t40/O" + num(opt) + ":default-stdout");
  record(d.stderr == "", "t40/O" + num(opt) + ":default-stderr");
  let modes = [
    { name: "fresh", origin: "interpreted.ql:7:9", frames: [] },
    { name: "reused", origin: "interpreted.ql:7:9", frames: ["caller.ql:11:3"] },
    { name: "called", origin: abs(t40) + ":11:21", frames: ["caller.ql:11:3"] },
    { name: "after-native", origin: "caller.ql:11:3", frames: [] },
    { name: "after-restore", origin: "interpreted.ql:7:9", frames: [] },
    { name: "ordinary", origin: abs(t40) + ":24:16", frames: [] },
    { name: "following", origin: abs(t40) + ":28:17", frames: [] },
    { name: "partial", origin: abs(t40) + ":30:32", frames: [] },
    { name: "attached", origin: "interpreted.ql:7:9", frames: [] },
    { name: "inherited", origin: "interpreted.ql:7:9", frames: [] },
    { name: "same-point", origin: "interpreted.ql:7:9", frames: ["interpreted.ql:7:9"] }
  ];
  let mi = 0;
  while mi < modes.length {
    let m = modes[mi];
    let r = std.process.run([binary, m.name]);
    record(r.status == 1, "t40/O" + num(opt) + "/" + m.name + ":status");
    record(r.stdout == t40Expected, "t40/O" + num(opt) + "/" + m.name + ":stdout");
    record(startsWith(r.stderr, m.origin + ":"), "t40/O" + num(opt) + "/" + m.name + ":origin");
    let wanted = []; let k = 0;
    while k < m.frames.length { wanted[wanted.length] = "  at " + m.frames[k]; k = k + 1; };
    record(sameFrames(frameLines(r.stderr), wanted), "t40/O" + num(opt) + "/" + m.name + ":frames " + framesText(frameLines(r.stderr)));
    record(!contains(r.stderr, "/bootstrapped/interpreter.ql:"), "t40/O" + num(opt) + "/" + m.name + ":no-interp-frame");
    mi = mi + 1;
  };
  null;
};

let runBridge = (binary) -> {
  let d = std.process.run([binary]);
  record(d.status == 0, "bridge:default-status");
  record(d.stdout == bridgeExpected, "bridge:default-stdout");
  record(d.stderr == "", "bridge:default-stderr");
  let modes = [
    { name: "native", origin: abs(bridge) + ":9:21", frames: ["user.ql:1:1"] },
    { name: "partial", origin: abs(bridge) + ":19:22", frames: ["partial-user.ql:1:1"] },
    { name: "callback", origin: "callback.ql:1:1", frames: ["outer-user.ql:1:1"] },
    { name: "after", origin: "host-scope.ql:80:2", frames: [] },
    { name: "no-leak", origin: abs(bridge) + ":33:14", frames: [] }
  ];
  let mi = 0;
  while mi < modes.length {
    let m = modes[mi];
    let r = std.process.run([binary, m.name]);
    record(r.status == 1, "bridge/" + m.name + ":status");
    record(r.stdout == bridgeExpected, "bridge/" + m.name + ":stdout");
    record(startsWith(r.stderr, m.origin + ":"), "bridge/" + m.name + ":origin");
    let wanted = []; let k = 0;
    while k < m.frames.length { wanted[wanted.length] = "  at " + m.frames[k]; k = k + 1; };
    record(sameFrames(frameLines(r.stderr), wanted), "bridge/" + m.name + ":frames " + framesText(frameLines(r.stderr)));
    mi = mi + 1;
  };
  null;
};

let oi = 0;
while oi < optLevels.length {
  let opt = optLevels[oi];
  let t38Bin = base + "/t38-O" + num(opt);
  let t39Bin = base + "/t39-O" + num(opt);
  let t40Bin = base + "/t40-O" + num(opt);
  let b38 = build(t38, t38Bin, opt);
  let b39 = build(t39, t39Bin, opt);
  let b40 = build(t40, t40Bin, opt);
  record(b38.ok, "t38/O" + num(opt) + ":build");
  record(b39.ok, "t39/O" + num(opt) + ":build");
  record(b40.ok, "t40/O" + num(opt) + ":build");
  if b38.ok { runT38(t38Bin, opt); };
  if b39.ok { runT39(t39Bin, opt); };
  if b40.ok { runT40(t40Bin, opt); };
  oi = oi + 1;
};
let bridgeBin = base + "/bridge";
let bridgeBuild = build(bridge, bridgeBin, 2);
record(bridgeBuild.ok, "bridge:build");
if bridgeBuild.ok { runBridge(bridgeBin); };

// ---- 4. 解释器诊断面 -------------------------------------------------------
// t38/t39 默认 + 模式;private std context 不可见。
let interpretedBody = (stdout) -> {
  let marker = "Interpreting...\n";
  let idx = -1; let k = 0;
  while k + marker.length <= stdout.length {
    if std.Bytes.slice(stdout, k, marker.length) == marker { idx = k; k = stdout.length; } else { k = k + 1; };
  };
  if idx < 0 { return ""; };
  let rest = std.Bytes.slice(stdout, idx + marker.length, stdout.length - idx - marker.length);
  let end = -1; let j = 0; let done = "Execution complete.\n";
  while j + done.length <= rest.length {
    if std.Bytes.slice(rest, j, done.length) == done { end = j; j = rest.length; } else { j = j + 1; };
  };
  if end < 0 { return rest; };
  return std.Bytes.slice(rest, 0, end);
};

if !skipInterpreter {
  let runInterpreted = (fixture, expected, modes) -> {
    let d = std.process.run([interpreter, fixture]);
    record(d.status == 0, fixture + "/interp:default-status");
    record(interpretedBody(d.stdout) == expected, fixture + "/interp:default-stdout");
    record(d.stderr == "", fixture + "/interp:default-stderr");
    let mi = 0;
    while mi < modes.length {
      let m = modes[mi];
      let r = std.process.run([interpreter, fixture, m.name]);
      record(r.status == 1, fixture + "/interp/" + m.name + ":status");
      record(interpretedBody(r.stdout) == expected, fixture + "/interp/" + m.name + ":stdout");
      mi = mi + 1;
    };
    null;
  };
  runInterpreted(t38, t38Expected, ["fail", "cached", "first", "second", "recursive", "library"]);
  runInterpreted(t39, t39Expected, ["trace", "import", "assign"]);
  let privateSource = base + "/private-context.ql";
  writeFile(privateSource, "println(std.Object.hasOwn(std)(\"__diagnostics\"));\n");
  let p = std.process.run([interpreter, privateSource]);
  record(p.status == 0, "private-context:status");
  record(interpretedBody(p.stdout) == "false\n", "private-context:stdout");
  record(p.stderr == "", "private-context:stderr");
};

// ---- report ---------------------------------------------------------------
println("QLang 诊断驱动:" + num(pass) + " 通过 / " + num(fail) + " 失败");
if failed != "" { println("失败:" + failed); };
if fail > 0 { assert(false, "diagnostics failed"); 1; };
0;
