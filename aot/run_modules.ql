// QLang 模块测试驱动(不依赖 Python):多文件 import、O0/O2、删源码后执行。
//
//   run_modules <stdlib-dir> [--compiler <c>] [--interpreter <i>]
//
// 覆盖原 Python 套件:
//   run_module_tests.py          t15 boot/native 一致 + 删源码 + 6 个拒绝 + 循环
//   run_scoped_module_tests.py   t35 @ O0/O2 + 删源码 + 3 个作用域拒绝
//   run_lazy_module_tests.py     t36 @ O0/O2 + 删源码 + active/inactive root
let compiler = "target/selfhost/stage2";
let interpreter = "target/native-interpreter/interpreter";
let linkTool = "target/tools/link";
let runtime = "aot/runtime.ql";
let stdlibDir = "";
let rest = [];
let i = 0;
while i < args.length {
  let a = args[i];
  if a == "--compiler" { i = i + 1; compiler = args[i]; }
  else if a == "--interpreter" { i = i + 1; interpreter = args[i]; }
  else { rest[rest.length] = a; };
  i = i + 1;
};
if rest.length > 0 { stdlibDir = rest[0]; };
if stdlibDir == "" { assert(false, "usage: run_modules <stdlib-dir> [--compiler <c>] [--interpreter <i>]"); 1; };

let base = "/tmp/qlang-modules-q";
std.process.run(["rm", "-rf", base]);
std.process.run(["mkdir", "-p", base]);
let pass = 0; let fail = 0; let failed = "";
let num = (n) -> std.Number.toString(n);
let contains = (text, needle) -> std.String.includes(text)(needle);
let record = (ok, label) -> {
  if ok { pass = pass + 1; } else { fail = fail + 1; failed = failed + " " + label; };
  null;
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
let build = (source, binary, opt) -> {
  let emitted = std.process.run([compiler, "--emit-llvm-split", source, runtime,
                                stdlibDir + "/symbols.tsv", stdlibDir + "/mod.ql"]);
  if emitted.status != 0 { return { ok: false, run: emitted }; };
  let ir = binary + ".ll";
  writeFile(ir, emitted.stdout);
  let linked = std.process.run([linkTool, ir, "-o", binary, "--opt", num(opt),
                                "--stdlib-object", stdlibDir + "/stdlib.o", "--root", "."]);
  return { ok: linked.status == 0, run: linked };
};
// 解释器输出:去掉 banner 与 Execution complete. 之后的内容。
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
let boot = (source) -> {
  let r = std.process.run([interpreter, source]);
  return { status: r.status, stdout: r.stdout, stderr: r.stderr, body: interpretedBody(r.stdout) };
};

// ---- t15: boot/native 一致,删源码后 native 仍可执行 ----------------------
let t15Dir = base + "/t15";
std.process.run(["mkdir", "-p", t15Dir]);
let prepared = sh("cp -a aot/tests/modules " + sq(t15Dir + "/modules") +
                  " && cp aot/tests/t15_modules.ql " + sq(t15Dir + "/main.ql"));
record(prepared.status == 0, "t15:prepare");
let t15Boot = boot(t15Dir + "/main.ql");
record(t15Boot.status == 0 || t15Boot.status == 1, "t15:boot-status");
let t15Build = build(t15Dir + "/main.ql", base + "/t15-bin", 2);
record(t15Build.ok, "t15:build");
if t15Build.ok {
  sh("rm -rf " + sq(t15Dir));
  let r = std.process.run([base + "/t15-bin"]);
  record(r.status == 0 || r.status == 1, "t15:native-status");
  record(r.stdout == t15Boot.body, "t15:boot-native-stdout");
};

// ---- 未处理的模块初始化错误 ------------------------------------------------
let badDir = base + "/bad";
std.process.run(["mkdir", "-p", badDir]);
writeFile(badDir + "/bad.ql", "let zero = 0; export let hidden = 1; 1 / zero;");
writeFile(badDir + "/main.ql", "import \"./bad.ql\";");
let badBuild = build(badDir + "/main.ql", base + "/bad-bin", 2);
record(badBuild.ok, "bad-init:build");
if badBuild.ok {
  let r = std.process.run([base + "/bad-bin"]);
  record(r.status == 1, "bad-init:native-status");
  record(contains(r.stderr, "DivisionByZero"), "bad-init:native-kind");
};
let badBoot = boot(badDir + "/main.ql");
record(badBoot.status == 1, "bad-init:boot-status");
record(contains(badBoot.stdout + badBoot.stderr, "DivisionByZero"), "bad-init:boot-kind");

// ---- 函数内 import 按定义文件解析 ------------------------------------------
let fnDir = base + "/fn";
std.process.run(["mkdir", "-p", fnDir + "/lib"]);
writeFile(fnDir + "/lib/value.ql", "export let value = 42;");
writeFile(fnDir + "/lib/loader.ql", "let load = () -> { let m = import \"./value.ql\"; m.value; }; export load;");
writeFile(fnDir + "/main.ql", "import \"./lib/loader.ql\"; println(load());");
record(boot(fnDir + "/main.ql").body == "42\n", "def-path:boot");
let fnBuild = build(fnDir + "/main.ql", base + "/fn-bin", 2);
record(fnBuild.ok, "def-path:build");
if fnBuild.ok {
  let r = std.process.run([base + "/fn-bin"]);
  record(r.status == 0 && r.stdout == "42\n", "def-path:native");
};

// ---- 静态循环:编译允许,执行到重入才是 ImportCycle ----------------------
let cycleCases = [
  { name: "cycle", text: "import \"./lib/../main.ql\";",
    deps: [{ path: "lib/.keep", text: "" }] },
  { name: "transitive-cycle", text: "import \"./a.ql\";",
    deps: [{ path: "a.ql", text: "import \"./b.ql\";" },
           { path: "b.ql", text: "import \"./a.ql\";" }] }
];
let cci = 0;
while cci < cycleCases.length {
  let c = cycleCases[cci];
  let dir = base + "/" + c.name;
  sh("mkdir -p " + sq(dir) + " " + sq(dir + "/lib"));
  let di = 0;
  while di < c.deps.length {
    let dep = c.deps[di];
    let full = dir + "/" + dep.path;
    writeFile(full, dep.text);
    di = di + 1;
  };
  writeFile(dir + "/main.ql", c.text);
  let b = build(dir + "/main.ql", base + "/" + c.name + "-bin", 2);
  record(b.ok, "cycle:" + c.name + ":compile");
  if b.ok {
    let r = std.process.run([base + "/" + c.name + "-bin"]);
    record(r.status == 1, "cycle:" + c.name + ":status");
    record(contains(r.stderr, "ImportCycle"), "cycle:" + c.name + ":kind");
  };
  cci = cci + 1;
};

// ---- 6 个编译拒绝 ----------------------------------------------------------
let rejectCases = [
  { name: "missing", text: "import \"./missing.ql\";", deps: [] },
  { name: "syntax", text: "import \"./bad.ql\";", deps: [{ path: "bad.ql", text: "let x = ;" }] },
  { name: "private", text: "let secret = 42; import \"./lib.ql\";",
    deps: [{ path: "lib.ql", text: "export let value = secret;" }] },
  { name: "hidden-export", text: "import \"./lib.ql\"; println(secret);",
    deps: [{ path: "lib.ql", text: "let secret = 1; export let public = 2;" }] },
  { name: "interpolated-path", text: "import \"\\${1}.ql\";", deps: [] },
  { name: "empty-path", text: "import \"\";", deps: [] }
];
let rji = 0;
while rji < rejectCases.length {
  let c = rejectCases[rji];
  let dir = base + "/reject-" + c.name;
  sh("mkdir -p " + sq(dir));
  let di = 0;
  while di < c.deps.length {
    writeFile(dir + "/" + c.deps[di].path, c.deps[di].text);
    di = di + 1;
  };
  writeFile(dir + "/main.ql", c.text);
  let r = std.process.run([compiler, "--emit-llvm-split", dir + "/main.ql", runtime,
                           stdlibDir + "/symbols.tsv", stdlibDir + "/mod.ql"]);
  record(r.status == 1, "reject:" + c.name + ":status");
  record(r.stdout == "", "reject:" + c.name + ":no-ir");
  record(contains(r.stderr, "CompileError"), "reject:" + c.name + ":CompileError");
  let exists = std.process.run(["test", "-e", dir + "/artifact"]);
  record(exists.status != 0, "reject:" + c.name + ":no-artifact");
  rji = rji + 1;
};

// ---- t35/t36:O0/O2 + 解释器 + 删源码 --------------------------------------
let moduleFixture = (name, fixture, modulesDir, expectedName) -> {
  let dir = base + "/" + name;
  sh("mkdir -p " + sq(dir + "/modules"));
  let prep = sh("cp -a " + sq("aot/tests/modules/" + modulesDir) + " " + sq(dir + "/modules/" + modulesDir) +
                " && cp " + sq("aot/tests/" + fixture + ".ql") + " " + sq(dir + "/main.ql"));
  record(prep.status == 0, name + ":prepare");
  let expected = readFile("aot/tests/" + fixture + ".expected");
  record(boot(dir + "/main.ql").body == expected, name + ":interp");
  let b0 = build(dir + "/main.ql", base + "/" + name + "-O0", 0);
  let b2 = build(dir + "/main.ql", base + "/" + name + "-O2", 2);
  record(b0.ok, name + ":build-O0");
  record(b2.ok, name + ":build-O2");
  sh("rm -rf " + sq(dir));
  if b0.ok {
    let r = std.process.run([base + "/" + name + "-O0"]);
    record(r.status == 0 && r.stdout == expected && r.stderr == "", name + ":O0");
  };
  if b2.ok {
    let r = std.process.run([base + "/" + name + "-O2"]);
    record(r.status == 0 && r.stdout == expected && r.stderr == "", name + ":O2");
  };
  null;
};
moduleFixture("scoped", "t35_scoped_modules", "scoped", "scoped module checks: 22\n");
moduleFixture("lazy", "t36_lazy_modules", "lazy", "lazy module checks: 9\n");

// ---- t36 的 active/inactive root ------------------------------------------
let rootCase = (name, text, status, expected, kind) -> {
  let dir = base + "/root-" + name;
  sh("mkdir -p " + sq(dir) + " " + sq(dir + "/lib"));
  writeFile(dir + "/lib/.keep", "");
  writeFile(dir + "/main.ql", text);
  let b0 = build(dir + "/main.ql", base + "/root-" + name + "-O0", 0);
  let b2 = build(dir + "/main.ql", base + "/root-" + name + "-O2", 2);
  record(b0.ok && b2.ok, "root-" + name + ":build");
  if b0.ok {
    let r = std.process.run([base + "/root-" + name + "-O0"]);
    record(r.status == status, "root-" + name + ":O0-status");
    record(r.stdout == expected, "root-" + name + ":O0-stdout");
    if kind != "" { record(contains(r.stderr, kind), "root-" + name + ":O0-kind"); };
    if expected == "" { record(!contains(r.stdout, "UNREACHABLE"), "root-" + name + ":O0-no-unreachable"); };
  };
  if b2.ok {
    let r = std.process.run([base + "/root-" + name + "-O2"]);
    record(r.status == status, "root-" + name + ":O2-status");
    record(r.stdout == expected, "root-" + name + ":O2-stdout");
    if kind != "" { record(contains(r.stderr, kind), "root-" + name + ":O2-kind"); };
    if expected == "" { record(!contains(r.stdout, "UNREACHABLE"), "root-" + name + ":O2-no-unreachable"); };
  };
  null;
};
rootCase("active", "import \"./lib/../main.ql\"; println(\"UNREACHABLE\");\n", 1, "", "ImportCycle");
rootCase("inactive", "if false { import \"./main.ql\"; }; println(\"OK\");\n", 0, "OK\n", "");

// ---- 3 个作用域拒绝 --------------------------------------------------------
let scopeCases = [
  { name: "function-local", text: "let f = () -> { import \"./value.ql\"; }; println(answer);" },
  { name: "block-local", text: "if true { import \"./value.ql\"; }; println(answer);" },
  { name: "unexecuted-name", text: "let f = () -> { export let private = 1; }; println(private);" }
];
let sji = 0;
while sji < scopeCases.length {
  let c = scopeCases[sji];
  let dir = base + "/scope-" + c.name;
  sh("mkdir -p " + sq(dir));
  writeFile(dir + "/value.ql", "export let answer = 42;");
  writeFile(dir + "/main.ql", c.text);
  let r = std.process.run([compiler, "--emit-llvm-split", dir + "/main.ql", runtime,
                           stdlibDir + "/symbols.tsv", stdlibDir + "/mod.ql"]);
  record(r.status == 1, "scope:" + c.name + ":status");
  record(r.stdout == "", "scope:" + c.name + ":no-ir");
  record(contains(r.stderr, "CompileError"), "scope:" + c.name + ":CompileError");
  sji = sji + 1;
};

println("QLang 模块驱动:" + num(pass) + " 通过 / " + num(fail) + " 失败");
if failed != "" { println("失败:" + failed); };
if fail > 0 { assert(false, "modules failed"); 1; };
0;
