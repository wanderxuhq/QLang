// 基准驱动(不依赖 Python):每个 bench 测"构建耗时"与"运行耗时",单模块 vs 标准库对象两档。
//
//   run_bench <stdlib-dir> [--compiler <c>] [--runs <n>]
//
// 时间来源:`date +%s%N` 子进程(本机 /proc/uptime 是冻结的,/proc/self/stat 只反映本进程 CPU,
// 量不了子进程墙钟)。运行耗时用"一次测量跑 n 遍"摊掉 ~25ms 的子进程开销。
let compiler = "target/selfhost/stage2";
let linkTool = "target/tools/link";
let stdlibDir = "";
let runs = 5;
let rest = [];
let i = 0;
while i < args.length {
  let a = args[i];
  if a == "--compiler" { i = i + 1; compiler = args[i]; }
  else if a == "--runs" { i = i + 1; runs = std.Number.parseFloat(args[i]); }
  else { rest[rest.length] = a; };
  i = i + 1;
};
if rest.length > 0 { stdlibDir = rest[0]; };
if stdlibDir == "" { assert(false, "usage: run_bench <stdlib-dir> [--compiler <c>] [--runs <n>]"); 1; };
let base = "/tmp/qlang-bench-q";
std.process.run(["rm", "-rf", base]);
std.process.run(["mkdir", "-p", base]);
let nowMs = () -> {
  let r = std.process.run(["date", "+%s%N"]);
  if r.status != 0 { return 0; };
  std.Number.parseFloat(std.String.trim(r.stdout)) / 1000000;
};
let names = std.String.split(std.fs.readFileText("aot/bench/benches.txt")?)("\n");
println("bench              mono构建  split构建  mono运行  split运行  输出一致");
let k = 0;
let bad = 0;
while k < names.length {
  let name = names[k];
  if name != "" {
    let src = "aot/bench/" + name + ".ql";
    let monoIr = base + "/" + name + ".mono.ll"; let monoBin = base + "/" + name + ".mono";
    let splitIr = base + "/" + name + ".split.ll"; let splitBin = base + "/" + name + ".split";
    let t0 = nowMs();
    let em = std.process.run([compiler, "--emit-llvm", src, "aot/runtime.ql"]);
    let lm = std.process.run(["sh", "-c", compiler + " --emit-llvm " + src + " aot/runtime.ql > " + monoIr +
                              " && " + linkTool + " " + monoIr + " -o " + monoBin]);
    let t1 = nowMs();
    let ls = std.process.run(["sh", "-c", compiler + " --emit-llvm-split " + src + " aot/runtime.ql " + stdlibDir +
                              "/symbols.tsv " + stdlibDir + "/mod.ql > " + splitIr + " && " + linkTool + " " + splitIr +
                              " -o " + splitBin + " --stdlib-object " + stdlibDir + "/stdlib.o"]);
    let t2 = nowMs();
    let monoRun = 0; let splitRun = 0; let same = "?";
    if lm.status == 0 && ls.status == 0 {
      let loop = std.String.toString(runs);
      let a0 = nowMs();
      std.process.run(["sh", "-c", "i=0; while [ $i -lt " + loop + " ]; do " + monoBin + " > /dev/null; i=$((i+1)); done"]);
      let a1 = nowMs();
      std.process.run(["sh", "-c", "i=0; while [ $i -lt " + loop + " ]; do " + splitBin + " > /dev/null; i=$((i+1)); done"]);
      let a2 = nowMs();
      monoRun = (a1 - a0) / runs; splitRun = (a2 - a1) / runs;
      let om = std.process.run([monoBin]); let os = std.process.run([splitBin]);
      same = if om.stdout == os.stdout { "yes"; } else { bad = bad + 1; "NO"; };
    } else { bad = bad + 1; };
    let ms = (v) -> std.Number.toString(std.Math.floor(v));
    println(name + "  " + ms(t1 - t0) + "ms  " + ms(t2 - t1) + "ms  " + ms(monoRun) + "ms  " + ms(splitRun) + "ms  " + same);
    if em.status != 0 { bad = bad + 1; };
  };
  k = k + 1;
};
if bad > 0 { println("注意:" + std.Number.toString(bad) + " 项失败或不一致"); };
0;
