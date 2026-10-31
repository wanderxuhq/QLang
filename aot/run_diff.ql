// debug/release 差分驱动(不依赖 Python):每个用例两档各编一次,输出必须逐字节相同。
// 判据是"两档一致":debug 档是保守发射(不直调/不内联/不 unbox/不省检查),
// 它与 release 的行为差就是优化不健全的信号。
//
//   run_diff <stdlib-dir> [--compiler <c>] [--jobs <n>]
let compiler = "target/selfhost/stage2";
let linkTool = "target/tools/link";
let stdlibDir = "";
let jobs = 4;
let rest = [];
let i = 0;
while i < args.length {
  let a = args[i];
  if a == "--compiler" { i = i + 1; compiler = args[i]; }
  else if a == "--jobs" { i = i + 1; jobs = std.Number.parseFloat(args[i]); }
  else { rest[rest.length] = a; };
  i = i + 1;
};
if rest.length > 0 { stdlibDir = rest[0]; };
if stdlibDir == "" { assert(false, "usage: run_diff <stdlib-dir> [--compiler <c>] [--jobs <n>]"); 1; };
if jobs < 1 { jobs = 1; };
let sq = (v) -> "'" + std.String.replace(v)("'")("'\\''") + "'";
let base = "/tmp/qlang-diff-q";
std.process.run(["rm", "-rf", base]);
std.process.run(["mkdir", "-p", base]);
let names = std.String.split(std.fs.readFileText("aot/tests/split.txt")?)("\n");
let pass = 0; let fail = 0; let failed = "";
let caseCmd = (name) -> {
  let src = "aot/tests/" + name + ".ql";
  let sym = stdlibDir + "/symbols.tsv"; let mod = stdlibDir + "/mod.ql";
  let obj = stdlibDir + "/stdlib.o";
  "set -e; " +
  sq(compiler) + " --emit-llvm-split " + sq(src) + " aot/runtime.ql " + sq(sym) + " " + sq(mod) + " > " + sq(base + "/" + name + ".rel.ll") + "; " +
  sq(linkTool) + " " + sq(base + "/" + name + ".rel.ll") + " -o " + sq(base + "/" + name + ".rel") + " --stdlib-object " + sq(obj) + "; " +
  sq(compiler) + " --debug --emit-llvm-split " + sq(src) + " aot/runtime.ql " + sq(sym) + " " + sq(mod) + " > " + sq(base + "/" + name + ".dbg.ll") + "; " +
  sq(linkTool) + " " + sq(base + "/" + name + ".dbg.ll") + " -o " + sq(base + "/" + name + ".dbg") + " --stdlib-object " + sq(obj) + " --debug; " +
  // 记录两档的退出码:只比 stdout 会把「打印完期望输出再崩溃」当通过。
  "set +e; " + sq(base + "/" + name + ".rel") + " > " + sq(base + "/" + name + ".rel.out") + " 2>" + sq(base + "/" + name + ".rel.err") + "; echo $? > " + sq(base + "/" + name + ".rel.st") + "; " +
  sq(base + "/" + name + ".dbg") + " > " + sq(base + "/" + name + ".dbg.out") + " 2>" + sq(base + "/" + name + ".dbg.err") + "; echo $? > " + sq(base + "/" + name + ".dbg.st") + "; true";
};
let running = []; let runningNames = [];
let drain = (all) -> {
  if running.length > 0 && (all || running.length >= jobs) {
    let h = running[0]; let name = runningNames[0];
    let r = std.process.wait(h);
    let kept = []; let keptNames = []; let j = 1;
    while j < running.length { kept[kept.length] = running[j]; keptNames[keptNames.length] = runningNames[j]; j = j + 1; };
    running = kept; runningNames = keptNames;
    if r.status != 0 { fail = fail + 1; failed = failed + " " + name + "(cmd)"; }
    else {
      let rel = std.fs.readFileText(base + "/" + name + ".rel.out");
      let dbg = std.fs.readFileText(base + "/" + name + ".dbg.out");
      let relSt = std.fs.readFileText(base + "/" + name + ".rel.st");
      let dbgSt = std.fs.readFileText(base + "/" + name + ".dbg.st");
      if isError(rel) || isError(dbg) { fail = fail + 1; failed = failed + " " + name + "(out)"; }
      else if rel != dbg { fail = fail + 1; failed = failed + " " + name + "(output)"; }
      else if isError(relSt) || isError(dbgSt) { fail = fail + 1; failed = failed + " " + name + "(status)"; }
      else if relSt != dbgSt { fail = fail + 1; failed = failed + " " + name + "(exit)"; }
      else {
        let expected = std.fs.readFileText("aot/tests/" + name + ".expected");
        // smoke case: both grades agree, and a crash (status > 1) is not a pass.
        if isError(expected) { if relSt == "0\n" && dbgSt == "0\n" { pass = pass + 1; } else { fail = fail + 1; failed = failed + " " + name + "(exit)"; }; }
        else if relSt != "0\n" || dbgSt != "0\n" { fail = fail + 1; failed = failed + " " + name + "(exit)"; }
        else if rel == expected { pass = pass + 1; }
        else { fail = fail + 1; failed = failed + " " + name + "(expect)"; };
      };
    };
  };
  null;
};
let k = 0;
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
println("debug/release 差分:" + std.String.toString(pass) + " 通过 / " + std.String.toString(fail) + " 失败 (jobs=" + std.Number.toString(jobs) + ")");
if failed != "" { println("失败:" + failed); };
if fail > 0 { assert(false, "diff failed"); 1; };
0;
