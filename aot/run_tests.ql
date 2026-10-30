// QLang 测试驱动:跑 aot/tests 里的原生测试用例。**全程 QLang,不调用 Python。**
//
//   run_tests <stdlib-dir> [--compiler <path>] [--interpreter]
//
// 带 `--interpreter` 时改跑解释器套件:确保 native 解释器存在(编 bootstrapped/run_file.ql),
// 按 aot/tests/interpreter.txt 逐个跑,剥掉 "Interpreting..."/"Execution complete." 外壳后
// 与 `.expected` 比对。
//
// 每个用例:
//   1) 编译器发用户模块 IR(`--emit-llvm-split`);
//   2) tools/link 链接成可执行(带 stdlib.o);
//   3) 跑它,标准输出与 `<name>.expected` 逐字节比对。
//
// 清单在 aot/tests/manifest.txt(一行一个用例名);没有目录列举原语,所以清单是显式文件。
// 用法:`stage2 --emit-llvm aot/run_tests.ql aot/runtime.ql > /tmp/rt.ll && tools/link /tmp/rt.ll -o /tmp/rt`
let compiler = "target/selfhost/stage2";
let linkTool = "target/tools/link";
let stdlibDir = "target/stdlib/" + "";
let interpreterMode = false;
let rest = [];
let i = 0;
while i < args.length {
  let a = args[i];
  if a == "--compiler" { i = i + 1; compiler = args[i]; }
  else if a == "--interpreter" { interpreterMode = true; }
  else { rest[rest.length] = a; };
  i = i + 1;
};
if rest.length > 0 { stdlibDir = rest[0]; };
if stdlibDir == "" { assert(false, "usage: run_tests <stdlib-dir> [--compiler <path>]"); 1; };
let manifestPath = if interpreterMode { "aot/tests/interpreter.txt"; } else { "aot/tests/manifest.txt"; };
let manifest = std.fs.readFileText(manifestPath)?;
// Smoke cases (no .expected) normally must exit 0; a few legitimately exit 1
// (unhandled top-level error) and are listed here with their expected status.
let smokeStatus = {};
let smokeText = std.fs.readFileText("aot/tests/smoke_status.txt");
if !isError(smokeText) {
  let rows = std.String.split(smokeText)("\n"); let si = 0;
  while si < rows.length {
    if rows[si] != "" {
      let cells = std.String.split(rows[si])("\t");
      if cells.length >= 2 { smokeStatus[cells[0]] = std.Number.parseFloat(cells[1]); };
    };
    si = si + 1;
  };
};
let smokeWant = (name) -> { let v = smokeStatus[name]; if isError(v) { 0; } else { v; }; };
let names = std.String.split(manifest)("\n");
let base = "/tmp/qlang-qltests";
std.process.run(["mkdir", "-p", base]);
std.process.run(["rm", "-rf", base + "/out"]);
std.process.run(["mkdir", "-p", base + "/out"]);
let interp = "target/native-interpreter/interpreter";
if interpreterMode {
  let probe = std.fs.readFileText(interp);
  if isError(probe) {
    std.process.run(["mkdir", "-p", "target/native-interpreter"]);
    let e2 = std.process.run([compiler, "--emit-llvm", "bootstrapped/run_file.ql", "aot/runtime.ql"]);
    if e2.status != 0 { assert(false, "cannot build interpreter"); 1; };
    std.fs.writeText(base + "/interpreter.ll", e2.stdout);
    let l2 = std.process.run([linkTool, base + "/interpreter.ll", "-o", interp]);
    if l2.status != 0 { assert(false, "cannot link interpreter"); 1; };
  };
};
let pass = 0; let fail = 0; let failed = "";
let k = 0;
while k < names.length {
  let name = names[k];
  if name != "" {
    let src = "aot/tests/" + name + ".ql";
    let ir = base + "/" + name + ".ll";
    let bin = base + "/" + name;
    if interpreterMode {
      let run0 = std.process.run([interp, src, "aot/runtime.ql"]);
      let body = std.String.split(run0.stdout)("Interpreting...\n");
      let out0 = if body.length > 1 { std.String.split(body[1])("Execution complete.")[0]; } else { ""; };
      let exp0 = std.fs.readFileText("aot/tests/" + name + ".expected");
      // A missing golden file is a broken fixture, not a pass: otherwise deleting
      // the .expected silently removes the check (and the case is never compared).
      // No golden file = smoke case, but it must still execute and exit 0 (the
      // old code skipped execution entirely for the native branch).
      // No golden file = smoke case. 0 or 1 are the language's own exit codes
      // (1 = unhandled top-level error); anything else is a crash.
      if isError(exp0) { if run0.status == smokeWant(name) { pass = pass + 1; } else { fail = fail + 1; failed = failed + " " + name + "(exit)"; }; }
      else if run0.status != 0 { fail = fail + 1; failed = failed + " " + name + "(exit)"; }
      else if out0 == exp0 { pass = pass + 1; }
      else { fail = fail + 1; failed = failed + " " + name; };
    }
    else {
      let emit = std.process.run([compiler, "--emit-llvm-split", src, "aot/runtime.ql",
                                  stdlibDir + "/symbols.tsv", stdlibDir + "/mod.ql"]);
      if emit.status != 0 { fail = fail + 1; failed = failed + " " + name + "(emit)"; }
      else {
        std.fs.writeText(ir, emit.stdout);
        let linked = std.process.run([linkTool, ir, "-o", bin, "--stdlib-object", stdlibDir + "/stdlib.o"]);
        if linked.status != 0 { fail = fail + 1; failed = failed + " " + name + "(link)"; }
        else {
          let expected = std.fs.readFileText("aot/tests/" + name + ".expected");
          let run = std.process.run([bin]);
          if isError(expected) {
            // smoke case: expected status per smoke_status.txt (default 0)
            if run.status == smokeWant(name) { pass = pass + 1; } else { fail = fail + 1; failed = failed + " " + name + "(exit)"; };
          }
          else if run.status != 0 { fail = fail + 1; failed = failed + " " + name + "(exit)"; }
          else if run.stdout == expected { pass = pass + 1; }
          else { fail = fail + 1; failed = failed + " " + name; };
        };
      };
    };
  };
  k = k + 1;
};
println("QLang 测试驱动:" + std.String.toString(pass) + " 通过 / " + std.String.toString(fail) + " 失败");
if failed != "" { println("失败:" + failed); };
if fail > 0 { assert(false, "tests failed"); 1; };
0;
