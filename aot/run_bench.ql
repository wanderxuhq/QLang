// 基准驱动(不依赖 Python):每个 bench 测单模块(mono)与标准库对象(split)两档。
//
//   run_bench <stdlib-dir> [--compiler <c>] [--runs <n>] [--only <substr>] [--no-run] [--keep]
//
// 指标口径与 aot/bench/run_bench.py 对齐:
//   front(s)  = 编译器 emit 耗时(只发 IR);
//   clang(s)  = `clang -O2 -S <ir> -o <asm>` 耗时;它同时是模块合法性闸门,失败即硬失败;
//   build(s)  = emit + clang -S + link 的整条构建链耗时;--no-run 时只到 clang;
//   insns     = clang 汇编里匹配 ^\s+[a-z] 的行数(AArch64 指令口径,验收只看机器指令)。
//               **只统计 mono 的 IR**:split 的 IR 只含用户模块,和 mono 不可比,故留 "-";
//   run(s)    = `--runs` 次单跑墙钟的最小值(非平均);
//   cpu(s)    = 子进程 CPU:每次 `sh -c '<bin>; times'`,取 times 第二行(children)的
//               user+sys,同样取 `--runs` 次最小值(dash 分辨率 10ms);
//   same      = mono 与 split 的 stdout 逐字节相等(两者都必须 exit 0)。
//
// 墙钟仍靠 `date +%s%N` 子进程(本机 /proc/uptime 冻结,/proc/self/stat 只算本进程 CPU)。
// 每次测量单独取时间戳,因此带少量进程开销;动辄几十 ms 以上的 bench 可忽略。
let compiler = "target/selfhost/stage2";
let linkTool = "target/tools/link";
let stdlibDir = "";
let runs = 5;
let only = "";
let noRun = false;
let keep = false;
let rest = [];
let i = 0;
while i < args.length {
  let a = args[i];
  if a == "--compiler" { i = i + 1; compiler = args[i]; }
  else if a == "--runs" { i = i + 1; runs = std.Number.parseFloat(args[i]); }
  else if a == "--only" { i = i + 1; only = args[i]; }
  else if a == "--no-run" { noRun = true; }
  else if a == "--keep" { keep = true; }
  else { rest[rest.length] = a; };
  i = i + 1;
};
if rest.length > 0 { stdlibDir = rest[0]; };
if stdlibDir == "" {
  assert(false, "usage: run_bench <stdlib-dir> [--compiler <c>] [--runs <n>] [--only <substr>] [--no-run] [--keep]");
  1;
};
if isError(runs) || runs != runs || runs < 1 || runs % 1 != 0 { runs = 1; };
let runsText = std.Number.toString(runs);
let sq = (v) -> "'" + std.String.replace(v)("'")("'\\''") + "'";
let base = "/tmp/qlang-bench-q";
std.process.run(["rm", "-rf", base]);
std.process.run(["mkdir", "-p", base]);
let nowMs = () -> {
  let r = std.process.run(["date", "+%s%N"]);
  if r.status != 0 { return 0; };
  std.Number.parseFloat(std.String.trim(r.stdout)) / 1000000;
};
// Right-align / left-align without printf: String.repeat gives the padding.
let padLeft = (s, width) -> {
  if s.length >= width { return s; };
  std.String.repeat(" ")(width - s.length) + s;
};
let padRight = (s, width) -> {
  if s.length >= width { return s; };
  s + std.String.repeat(" ")(width - s.length);
};
// Fixed-point rendering: std.Math.round then integer split, so 0.07 never prints
// as 0.06999999999999999.
let fixed = (v, digits) -> {
  if std.Number.isNaN(v) { return "-"; };
  let neg = v < 0;
  if neg { v = -v; };
  let scale = 1; let d = 0;
  while d < digits { scale = scale * 10; d = d + 1; };
  let n = std.Math.round(v * scale);
  let whole = std.Math.floor(n / scale);
  let frac = n - whole * scale;
  let fracText = std.Number.toString(frac);
  while fracText.length < digits { fracText = "0" + fracText; };
  let text = std.Number.toString(whole);
  if digits > 0 { text = text + "." + fracText; };
  if neg && (whole != 0 || frac != 0) { return "-" + text; };
  text;
};
let truncateText = (text, limit) -> {
  if text.length <= limit { return text; };
  let out = ""; let i = 0;
  while i < limit { out = out + text[i]; i = i + 1; };
  out + "...";
};
// 比较用码点,不用字符串关系运算:`c >= "a"` 在 QLang 里是 Error 值(truthy),
// 拿它当条件会把每一条缩进行都算成指令(实测 143007 -> 178788)。
let charCode = (c) -> std.String.codePointAt(c)(0);
let isSpaceChar = (c) -> {
  let code = charCode(c);
  code == 32 || code == 9 || code == 13;
};
let isLowerChar = (c) -> {
  let code = charCode(c);
  code >= 97 && code <= 122;
};
// Instruction count: lines matching ^\s+[a-z]. The leading whitespace matters:
// AArch64 instructions are emitted as "\t<mnemonic>", while labels/directives
// start at column 0 or with '.'.
let firstNonSpace = (line) -> {
  let j = 0;
  while j < line.length {
    if !isSpaceChar(line[j]) { return j; };
    j = j + 1;
  };
  -1;
};
let insnCount = (text) -> {
  let lines = std.String.split(text)("\n");
  let count = 0; let i = 0;
  while i < lines.length {
    let line = lines[i];
    let j = firstNonSpace(line);
    if j > 0 {
      if j < line.length {
        if isLowerChar(line[j]) { count = count + 1; };
      };
    };
    i = i + 1;
  };
  count;
};
let nonEmpty = (cells) -> {
  let out = []; let i = 0;
  while i < cells.length {
    if cells[i] != "" { out[out.length] = cells[i]; };
    i = i + 1;
  };
  out;
};
// "0m0.070000s" -> seconds.
let parseTimesToken = (token) -> {
  let t = std.String.trim(token);
  let parts = std.String.split(t)("m");
  if parts.length != 2 { return -1; };
  let mins = std.Number.parseFloat(parts[0]);
  let secParts = std.String.split(parts[1])("s");
  if secParts.length < 1 { return -1; };
  let secs = std.Number.parseFloat(secParts[0]);
  if std.Number.isNaN(mins) || std.Number.isNaN(secs) { return -1; };
  mins * 60 + secs;
};
// Child CPU from `times`: line 1 is the shell itself, line 2 is its children.
let timesChildren = (stdoutText) -> {
  let lines = nonEmpty(std.String.split(stdoutText)("\n"));
  if lines.length < 2 { return -1; };
  let cells = nonEmpty(std.String.split(std.String.trim(lines[1]))(" "));
  if cells.length < 2 { return -1; };
  let user = parseTimesToken(cells[0]);
  let sys = parseTimesToken(cells[1]);
  if user < 0 || sys < 0 { return -1; };
  user + sys;
};
let measureCpu = (bin, name, mode) -> {
  let best = -1; let k = 0;
  while k < runs {
    let r = std.process.run(["sh", "-c", sq(bin) + " > /dev/null; times"]);
    if r.status != 0 {
      assert(false, name + " " + mode + ": cpu probe failed: " + truncateText(r.stderr, 300));
    };
    let total = timesChildren(r.stdout);
    if total < 0 {
      assert(false, name + " " + mode + ": cannot parse times output: " + truncateText(r.stdout, 200));
    };
    if best < 0 || total < best { best = total; };
    k = k + 1;
  };
  if best < 0 { 0; } else { best; };
};
let measureRun = (bin, name, mode, outPath, errPath) -> {
  let cmd = "i=0; while [ $i -lt " + runsText + " ]; do " +
            "t0=$(date +%s%N); " + sq(bin) + " > " + sq(outPath) + " 2> " + sq(errPath) + "; rc=$?; " +
            "t1=$(date +%s%N); echo $((t1-t0)) $rc; i=$((i+1)); done";
  let w = std.process.run(["sh", "-c", cmd]);
  if w.status != 0 {
    assert(false, name + " " + mode + ": run loop failed: " + truncateText(w.stderr, 300));
  };
  let lines = std.String.split(w.stdout)("\n");
  let best = -1; let failed = "";
  let i = 0;
  while i < lines.length {
    if lines[i] != "" {
      let cells = nonEmpty(std.String.split(std.String.trim(lines[i]))(" "));
      if cells.length < 2 {
        assert(false, name + " " + mode + ": bad timing line: " + truncateText(lines[i], 120));
      };
      let ns = std.Number.parseFloat(cells[0]);
      let rc = std.Number.parseFloat(cells[1]);
      if std.Number.isNaN(ns) || std.Number.isNaN(rc) {
        assert(false, name + " " + mode + ": bad timing line: " + truncateText(lines[i], 120));
      };
      if rc != 0 { failed = "exit " + std.Number.toString(rc); };
      if best < 0 || ns < best { best = ns; };
    };
    i = i + 1;
  };
  if failed != "" {
    let errText = std.fs.readFileText(errPath) ?? "";
    assert(false, name + " " + mode + ": binary failed (" + failed + "): " + truncateText(errText, 300));
  };
  let cpu = measureCpu(bin, name, mode);
  { wall: best / 1000000000, cpu: cpu };
};
// 一档的完整测量。clang 失败/链接失败/运行非零一律硬失败(assert 直接 exit 1)。
let measure = (name, mode, src) -> {
  let tag = base + "/" + name + "." + mode;
  let ir = tag + ".ll"; let asm = tag + ".s"; let bin = tag;
  let outPath = tag + ".out"; let errPath = tag + ".err";
  let t0 = nowMs();
  let emitCmd = "";
  if mode == "mono" {
    emitCmd = sq(compiler) + " --emit-llvm " + sq(src) + " aot/runtime.ql > " + sq(ir);
  } else {
    emitCmd = sq(compiler) + " --emit-llvm-split " + sq(src) + " aot/runtime.ql " +
              sq(stdlibDir + "/symbols.tsv") + " " + sq(stdlibDir + "/mod.ql") + " > " + sq(ir);
  };
  let e = std.process.run(["sh", "-c", emitCmd]);
  let t1 = nowMs();
  if e.status != 0 {
    assert(false, name + " " + mode + ": compiler failed: " + truncateText(e.stderr, 400));
  };
  let frontend = (t1 - t0) / 1000;
  let c = std.process.run(["clang", "-O2", "-S", ir, "-o", asm]);
  let t2 = nowMs();
  if c.status != 0 {
    assert(false, name + " " + mode + ": clang -O2 -S failed: " + truncateText(c.stderr, 400));
  };
  let backend = (t2 - t1) / 1000;
  let insns = -1;
  if mode == "mono" {
    let text = std.fs.readFileText(asm);
    if isError(text) { assert(false, name + " mono: cannot read asm"); };
    insns = insnCount(text);
  };
  if noRun {
    { insns: insns, frontend: frontend, backend: backend, build: (t2 - t0) / 1000,
      run: 0, cpu: 0, out: "" };
  } else {
    let linkArgs = [linkTool, ir, "-o", bin];
    if mode != "mono" {
      linkArgs[linkArgs.length] = "--stdlib-object";
      linkArgs[linkArgs.length] = stdlibDir + "/stdlib.o";
    };
    let l = std.process.run(linkArgs);
    let t3 = nowMs();
    if l.status != 0 {
      assert(false, name + " " + mode + ": link failed: " + truncateText(l.stderr, 400));
    };
    let build = (t3 - t0) / 1000;
    let r = measureRun(bin, name, mode, outPath, errPath);
    let text = std.fs.readFileText(outPath);
    if isError(text) { assert(false, name + " " + mode + ": cannot read stdout"); };
    { insns: insns, frontend: frontend, backend: backend, build: build,
      run: r.wall, cpu: r.cpu, out: text };
  };
};
let allNames = std.String.split(std.fs.readFileText("aot/bench/benches.txt")?)("\n");
let names = [];
let ni = 0;
while ni < allNames.length {
  let name = allNames[ni];
  if name != "" {
    if only == "" || std.String.includes(name)(only) { names[names.length] = name; };
  };
  ni = ni + 1;
};
if names.length == 0 {
  assert(false, "no benchmarks found" + if only != "" { " for --only " + only; } else { ""; });
  1;
};
if noRun { println("--no-run: 跳过链接与运行,insns 仍取 mono 的 clang -O2 汇编"); };
let nameWidth = 5;
let wi = 0;
while wi < names.length {
  if names[wi].length > nameWidth { nameWidth = names[wi].length; };
  wi = wi + 1;
};
let header = padRight("bench", nameWidth) + "  " + padRight("mode", 5) + "  " +
             padLeft("insns", 8) + "  " + padLeft("front(s)", 8) + "  " +
             padLeft("clang(s)", 8) + "  " + padLeft("build(s)", 8) + "  " +
             padLeft("run(s)", 7) + "  " + padLeft("cpu(s)", 7) + "  same";
println(header);
let bad = 0;
let k = 0;
while k < names.length {
  let name = names[k];
  let src = "aot/bench/" + name + ".ql";
  let mono = measure(name, "mono", src);
  let split = measure(name, "split", src);
  let same = "?";
  if !noRun {
    if mono.out == split.out { same = "yes"; }
    else { bad = bad + 1; same = "NO"; };
  };
  let monoInsns = if mono.insns < 0 { "-"; } else { std.Number.toString(mono.insns); };
  println(padRight(name, nameWidth) + "  " + padRight("mono", 5) + "  " +
          padLeft(monoInsns, 8) + "  " + padLeft(fixed(mono.frontend, 2), 8) + "  " +
          padLeft(fixed(mono.backend, 2), 8) + "  " + padLeft(fixed(mono.build, 2), 8) + "  " +
          padLeft(fixed(mono.run, 3), 7) + "  " + padLeft(fixed(mono.cpu, 3), 7) + "  " + same);
  println(padRight(name, nameWidth) + "  " + padRight("split", 5) + "  " +
          padLeft("-", 8) + "  " + padLeft(fixed(split.frontend, 2), 8) + "  " +
          padLeft(fixed(split.backend, 2), 8) + "  " + padLeft(fixed(split.build, 2), 8) + "  " +
          padLeft(fixed(split.run, 3), 7) + "  " + padLeft(fixed(split.cpu, 3), 7));
  if !keep {
    std.process.run(["rm", "-f", base + "/" + name + ".mono.ll", base + "/" + name + ".mono.s",
                     base + "/" + name + ".mono", base + "/" + name + ".mono.out", base + "/" + name + ".mono.err",
                     base + "/" + name + ".split.ll", base + "/" + name + ".split.s",
                     base + "/" + name + ".split", base + "/" + name + ".split.out", base + "/" + name + ".split.err"]);
  };
  k = k + 1;
};
if keep { println("中间文件保留在 " + base + "/"); };
if bad > 0 { assert(false, "bench: " + std.Number.toString(bad) + " 项输出不一致"); 1; };
0;
