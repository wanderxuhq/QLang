// QLang 自举测试驱动(不依赖 Python):并行跑用例 + 验证 stage2/stage3 的 IR 逐字节相同。
//
//   run_selfhost <stdlib-dir> [--compiler <c>] [--jobs <n>] [--no-fixed-point]
//
// 每个用例由 `sh -c` 子进程完成"发 IR → 链接 → 跑",把输出写到文件;驱动只负责调度与比对,
// 所以并行是进程级的(`std.process.spawn`/`wait`)。
let compiler = "target/selfhost/stage2";
let linkTool = "target/tools/link";
let stdlibDir = "";
let jobs = 4;
let fixedPoint = true;
let rest = [];
let i = 0;
while i < args.length {
  let a = args[i];
  if a == "--compiler" { i = i + 1; compiler = args[i]; }
  else if a == "--jobs" { i = i + 1; jobs = std.Number.parseFloat(args[i]); }
  else if a == "--no-fixed-point" { fixedPoint = false; }
  else { rest[rest.length] = a; };
  i = i + 1;
};
if rest.length > 0 { stdlibDir = rest[0]; };
if stdlibDir == "" { assert(false, "usage: run_selfhost <stdlib-dir> [--compiler <c>] [--jobs <n>]"); 1; };
if jobs < 1 { jobs = 1; };
let base = "/tmp/qlang-selfhost-q";
std.process.run(["rm", "-rf", base]);
std.process.run(["mkdir", "-p", base]);
// 自举用清单:比原生清单少三个"多文件 import"用例(t13/t14/t15)——它们在 split 模式下
// 需要模块图,不属于自举要验证的东西(那些由 module 测试覆盖)。
let manifest = std.fs.readFileText("aot/tests/split.txt")?;
let names = std.String.split(manifest)("\n");
let pass = 0; let fail = 0; let failed = "";

// 一组"跑一个用例"的命令行:编译 → 链接 → 跑,输出重定向到 base/<name>.out
let caseCmd = (name) -> {
  let src = "aot/tests/" + name + ".ql";
  let ir = base + "/" + name + ".ll";
  let bin = base + "/" + name;
  let out = base + "/" + name + ".out";
  "set -e; " + compiler + " --emit-llvm-split " + src + " aot/runtime.ql " + stdlibDir +
  "/symbols.tsv " + stdlibDir + "/mod.ql > " + ir + "; " + linkTool + " " + ir + " -o " + bin +
  " --stdlib-object " + stdlibDir + "/stdlib.o; " + bin + " > " + out + " 2>/dev/null";
};
let running = []; let runningNames = [];
let k = 0;
let drain = (all) -> {
  if running.length > 0 && (all || running.length >= jobs) {
    let h = running[0];
    let name = runningNames[0];
    let r = std.process.wait(h);
    let kept = []; let keptNames = [];
    let j = 1;
    while j < running.length { kept[kept.length] = running[j]; keptNames[keptNames.length] = runningNames[j]; j = j + 1; };
    running = kept; runningNames = keptNames;
    let expected = std.fs.readFileText("aot/tests/" + name + ".expected");
    if r.status != 0 { fail = fail + 1; failed = failed + " " + name + "(cmd)"; }
    else if isError(expected) { pass = pass + 1; }
    else {
      let got = std.fs.readFileText(base + "/" + name + ".out");
      if !isError(got) && got == expected { pass = pass + 1; }
      else { fail = fail + 1; failed = failed + " " + name; };
    };
  };
  null;
};
while k < names.length {
  let name = names[k];
  if name != "" {
    running[running.length] = std.process.spawn(["sh", "-c", caseCmd(name)]);
    runningNames[runningNames.length] = name;
    while running.length >= jobs { drain(false); };
  };
  k = k + 1;
};
while running.length > 0 { drain(true); };

// 自举固定点:stage2 发 stage3 的 IR,再让 stage3 发一遍,两份 IR 必须逐字节相同。
if fixedPoint {
  let ir2 = base + "/compiler-s2.ll"; let ir3 = base + "/compiler-s3.ll";
  let s2 = base + "/stage2-copy";
  let e2 = std.process.run([compiler, "--emit-llvm", "aot/qlangc.ql", "aot/runtime.ql"]);
  if e2.status != 0 { fail = fail + 1; failed = failed + " stage2-emit"; }
  else {
    std.fs.writeText(ir2, e2.stdout);
    let l2 = std.process.run([linkTool, ir2, "-o", s2]);
    if l2.status != 0 { fail = fail + 1; failed = failed + " stage2-link"; }
    else {
      let e3 = std.process.run([s2, "--emit-llvm", "aot/qlangc.ql", "aot/runtime.ql"]);
      if e3.status != 0 { fail = fail + 1; failed = failed + " stage3-emit"; }
      else if e3.stdout == e2.stdout { pass = pass + 1; }
      else { fail = fail + 1; failed = failed + " fixed-point"; };
    };
  };
};
println("QLang 自举驱动:" + std.String.toString(pass) + " 通过 / " + std.String.toString(fail) + " 失败 (jobs=" + std.Number.toString(jobs) + ")");
if failed != "" { println("失败:" + failed); };
if fail > 0 { assert(false, "selfhost failed"); 1; };
0;
