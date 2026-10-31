// 原生平台契约驱动(不依赖 Python):argv、文件文本、规范路径与描述符清理。
//
//   aot/run_platform.ql <stdlib-dir> [--compiler <c>] [--stdlib-object <obj>]
//
// 覆盖原 Python 套件 aot/run_platform_tests.py:
//   1) 被测程序回显 argv(JSON)、readFileText/canonicalPath 的结果或 {error:kind},
//      再固定打印四个错误类型(42 / null / 含 NUL 路径);
//   2) 无参数、8 个负载用例(空文件、Unicode+NUL、跨块大文本、5 种非法 UTF-8);
//   3) 缺失文件、目录、symlink 后跟 ".." 的规范路径;
//   4) ulimit -n 64 下 100 组 read/canonical 的描述符清理。
//
// 非法 UTF-8 负载用 `sh -c "printf ..."` 写:QLang 字符串表达不了那些字节。
let compiler = "target/selfhost/stage2";
let linkTool = "target/tools/link";
let runtime = "aot/runtime.ql";
let stdlibDir = "";
let stdlibObject = "";
let rest = [];
let ai = 0;
while ai < args.length {
  let arg = args[ai];
  if arg == "--compiler" { ai = ai + 1; compiler = args[ai]; }
  else if arg == "--stdlib-object" { ai = ai + 1; stdlibObject = args[ai]; }
  else { rest[rest.length] = arg; };
  ai = ai + 1;
};
if rest.length > 0 { stdlibDir = rest[0]; };
let fail = (message) -> { assert(false, "run_platform: " + message); 1; };
let dirOf = (path) -> {
  let parts = std.String.split(path)("/");
  if parts.length <= 1 { return "."; };
  let out = ""; let i = 0;
  while i < parts.length - 1 {
    if i == 0 { out = parts[i]; } else { out = out + "/" + parts[i]; };
    i = i + 1;
  };
  out;
};
if stdlibObject == "" {
  if stdlibDir == "" { fail("usage: run_platform <stdlib-dir> [--compiler <c>] [--stdlib-object <obj>]"); };
  stdlibObject = stdlibDir + "/stdlib.o";
} else if stdlibDir == "" {
  stdlibDir = dirOf(stdlibObject);
};
let symbols = stdlibDir + "/symbols.tsv";
let interface = stdlibDir + "/mod.ql";

// ---- 驱动辅助 --------------------------------------------------------------
let sq = (v) -> "'" + std.String.replace(v)("'")("'\\''") + "'";
let sh = (cmd) -> std.process.run(["sh", "-c", cmd]);
let num = (n) -> std.Number.toString(n);
let linesOf = (text) -> {
  let parts = std.String.split(text)("\n");
  let out = [];
  let i = 0;
  while i < parts.length {
    // Drop only the artifact of the trailing newline println emits.
    if !(i == parts.length - 1 && parts[i] == "") { out[out.length] = parts[i]; };
    i = i + 1;
  };
  out;
};
let sameLines = (a, b) -> {
  if a.length != b.length { return false; };
  let i = 0;
  while i < a.length {
    if a[i] != b[i] { return false; };
    i = i + 1;
  };
  true;
};
let pass = 0; let failures = 0; let failed = "";
let check = (ok, label) -> {
  if ok { pass = pass + 1; } else { failures = failures + 1; failed = failed + " " + label; };
  null;
};
let resolve = (path) -> {
  let r = std.process.run(["realpath", path]);
  if r.status != 0 { fail("realpath failed for " + path + ": " + r.stderr); };
  std.String.split(r.stdout)("\n")[0];
};

let base = "/tmp/qlang-platform-q";
let source = base + "/platform.ql";
let exe = base + "/platform";
std.process.run(["rm", "-rf", base]);
std.process.run(["mkdir", "-p", base]);

// ---- 被测程序(与 aot/run_platform_tests.py 的 SOURCE 一致) -----------------
let program =
  'if args.length == 0 { println(std.JSON.stringify(args)); }\n' +
  'else if args[0] == "--repeat" {\n' +
  '  let i = 0;\n' +
  '  while i < 100 {\n' +
  '    std.fs.readFileText(args[1])?;\n' +
  '    std.fs.canonicalPath(args[1])?;\n' +
  '    i = i + 1;\n' +
  '  };\n' +
  '  println("PASS descriptor cleanup");\n' +
  '} else {\n' +
  '  println(std.JSON.stringify(args));\n' +
  '  let text = std.fs.readFileText(args[0]);\n' +
  '  if isError(text) { println(std.JSON.stringify({error: text.type})); }\n' +
  '  else { println(std.JSON.stringify(text)); };\n' +
  '  let path = std.fs.canonicalPath(args[0]);\n' +
  '  if isError(path) { println(std.JSON.stringify({error: path.type})); }\n' +
  '  else { println(std.JSON.stringify(path)); };\n' +
  '};\n' +
  'println(std.fs.readFileText(42).type);\n' +
  'println(std.fs.canonicalPath(null).type);\n' +
  'println(std.fs.readFileText("bad\\0path").type);\n' +
  'println(std.fs.canonicalPath("bad\\0path").type);\n';
let wroteSource = std.fs.writeText(source, program);
if isError(wroteSource) { fail("cannot write " + source); };

// ---- 构建:split 发射 + 链接 O2 --------------------------------------------
let emitted = std.process.run([compiler, "--emit-llvm-split", source, runtime, symbols, interface]);
if emitted.status != 0 { fail("emit failed:\n" + emitted.stderr); };
let ir = base + "/platform.ll";
let wroteIR = std.fs.writeText(ir, emitted.stdout);
if isError(wroteIR) { fail("cannot write " + ir); };
let linked = std.process.run([linkTool, ir, "-o", exe, "--opt", "2",
                              "--stdlib-object", stdlibObject, "--root", "."]);
if linked.status != 0 { fail("link failed:\n" + linked.stdout + linked.stderr); };
let suffix = ["TypeMismatch", "TypeMismatch", "IOError", "IOError"];
let expectedTail = (head) -> [head, suffix[0], suffix[1], suffix[2], suffix[3]];

// ---- 无参数 ----------------------------------------------------------------
let none = std.process.run([exe]);
check(none.status == 0, "no-args:status");
check(sameLines(linesOf(none.stdout), expectedTail("[]")), "no-args:output");

// ---- 显式 argv 用例:空串、含空格、Unicode ---------------------------------
let argvCase = std.process.run([exe, "", "two words", "中文🙂"]);
let argvGot = linesOf(argvCase.stdout);
check(argvCase.status == 0 && sameLines(argvGot, [std.JSON.stringify(["", "two words", "中文🙂"]),
                                                  '{"error":"IOError"}', '{"error":"IOError"}',
                                                  suffix[0], suffix[1], suffix[2], suffix[3]]),
      "argv");

// ---- 8 个负载用例 ----------------------------------------------------------
let big = std.String.repeat("a")(65535) + "🙂" + std.String.repeat("z")(100);
if isError(big) { fail("cannot build chunks payload"); };
let cases = [
  { name: "empty", mode: "write", payload: "" },
  { name: "unicode", mode: "write", payload: "中文🙂\nA\0Z" },
  { name: "chunks", mode: "write", payload: big },
  { name: "bad-continuation", mode: "printf", payload: "\\302A" },
  { name: "overlong", mode: "printf", payload: "\\300\\257" },
  { name: "surrogate", mode: "printf", payload: "\\355\\240\\200" },
  { name: "too-large", mode: "printf", payload: "\\364\\220\\200\\200" },
  { name: "truncated", mode: "printf", payload: "\\360\\237" }
];
let ci = 0;
while ci < cases.length {
  let c = cases[ci];
  let path = base + "/" + c.name;
  if c.mode == "printf" {
    // printf interprets the octal escapes into the raw bytes the fixture needs.
    let made = sh("printf '" + c.payload + "' > " + sq(path));
    if made.status != 0 { fail("cannot write " + path + ": " + made.stderr); };
  } else {
    let made = std.fs.writeText(path, c.payload);
    if isError(made) { fail("cannot write " + path); };
  };
  let expectedText = if c.mode == "printf" { '{"error":"IOError"}'; } else { std.JSON.stringify(c.payload); };
  let expectedArgs = std.JSON.stringify([path, "", "two words", "中文🙂"]);
  let r = std.process.run([exe, path, "", "two words", "中文🙂"]);
  let got = linesOf(r.stdout);
  let ok = r.status == 0 && sameLines(got, [expectedArgs, expectedText, std.JSON.stringify(resolve(path)),
                                           suffix[0], suffix[1], suffix[2], suffix[3]]);
  check(ok, c.name);
  if !ok {
    println("FAIL platform: " + c.name);
    println("  status=" + num(r.status) + " stdout=" + std.JSON.stringify(r.stdout));
  };
  ci = ci + 1;
};

// ---- 缺失文件 / 目录 -------------------------------------------------------
let missing = base + "/missing";
let mr = std.process.run([exe, missing]);
let mg = linesOf(mr.stdout);
check(mr.status == 0 && sameLines(mg, [std.JSON.stringify([missing]), '{"error":"IOError"}',
                                       '{"error":"IOError"}', suffix[0], suffix[1], suffix[2], suffix[3]]),
      "missing-file");
let dr = std.process.run([exe, base]);
let dg = linesOf(dr.stdout);
check(dr.status == 0 && sameLines(dg, [std.JSON.stringify([base]), '{"error":"IOError"}',
                                       std.JSON.stringify(resolve(base)), suffix[0], suffix[1], suffix[2], suffix[3]]),
      "directory");

// ---- symlink 后跟 ".." 的规范路径 -----------------------------------------
std.process.run(["mkdir", "-p", base + "/real/nested"]);
let wroteValue = std.fs.writeText(base + "/real/value", "resolved");
if isError(wroteValue) { fail("cannot write real/value"); };
std.process.run(["ln", "-s", base + "/real/nested", base + "/link"]);
let linkedPath = base + "/link/../value";
let lr = std.process.run([exe, linkedPath]);
let lg = linesOf(lr.stdout);
check(lr.status == 0 && sameLines(lg, [std.JSON.stringify([linkedPath]), '"resolved"',
                                       std.JSON.stringify(resolve(linkedPath)),
                                       suffix[0], suffix[1], suffix[2], suffix[3]]),
      "symlink-dotdot");

// ---- 描述符清理:64 个描述符上限下 100 组 read/canonical -------------------
let limited = sh("ulimit -n 64; exec " + sq(exe) + " --repeat " + sq(base + "/empty"));
check(limited.status == 0 && sameLines(linesOf(limited.stdout), expectedTail("PASS descriptor cleanup")),
      "descriptor-cleanup");

// ---- 汇总 ------------------------------------------------------------------
if failures > 0 {
  println("Platform suite: " + num(failures) + " FAILED");
  println("失败:" + failed);
  assert(false, "platform suite failed");
};
println("PASS platform: no args, explicit argv, 8 payload cases, missing/directory/symlink");
println("PASS platform: 100 read/resolve pairs with a 64-descriptor limit");
println("Platform suite: ALL PASS");
0;
