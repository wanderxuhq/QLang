// 扩展(native .so)测试驱动 —— 不依赖 Python。
//   run_extension <tmp-dir> --root <repo> [--compiler <c>]
// tmp-dir 必须是 dlopen 允许的路径(Android 上 /tmp 不行)。
let endsWith = (text, suffix) -> {
  if text.length < suffix.length { return false; }
  std.Bytes.slice(text, text.length - suffix.length, suffix.length) == suffix;
};
let compiler = "target/selfhost/stage2";
let linkTool = "target/tools/link";
let verifyTool = "";
let root = "";
let work = "";
let rest = [];
let i = 0;
while i < args.length {
  let a = args[i];
  if a == "--compiler" { i = i + 1; compiler = args[i]; }
  else if a == "--root" { i = i + 1; root = args[i]; }
  else { rest[rest.length] = a; };
  i = i + 1;
};
if work == "" && rest.length > 0 { work = rest[0]; };
if work == "" || root == "" { assert(false, "usage: run_extension <tmp-dir> --root <repo> [--compiler <c>]"); 1; };
if !endsWith(root, "/") { root = root + "/"; };
verifyTool = root + "target/tools/verify";
let runtime = root + "aot/runtime.ql";
let sh = (cmd) -> std.process.run(["sh", "-c", cmd]);
// Paths come from the caller: quote them before they enter `sh -c` (spaces would
// otherwise split arguments; `rm -rf` makes that dangerous).
let sq = (v) -> "'" + std.String.replace(v)("'")("'\\''") + "'";
let die = (what, r) -> { println("FAIL: " + what + "\n" + r.stderr); assert(false, what); 1; };
let prepare = sh("rm -rf " + sq(work) + " && mkdir -p " + sq(work + "/source") + " && cp " + sq(root + "aot/tests/extensions") + "/*.ql " + sq(work + "/source/") + " && cp " + sq(root + "aot/tests/t37_extensions.ql") + " " + sq(work + "/source/host.ql"));
if prepare.status != 0 { die("准备目录", prepare); };
let emit = (src, mode, out) -> {
  let r = std.process.run([compiler, mode, src, runtime]);
  if r.status != 0 { die("发 IR " + src, r); };
  std.fs.writeText(out, r.stdout);
  null;
};
let linkTo = (ir, out, opt, shared) -> {
  let args0 = [linkTool, ir, "-o", out, "--opt", opt, "--root", root];
  if shared { args0[args0.length] = "--shared"; };
  let r = std.process.run(args0);
  if r.status != 0 { die("链接 " + out, r); };
  null;
};
// 1) 宿主:扩展还不存在的时候就编好
emit(work + "/source/host.ql", "--emit-llvm", work + "/host.ll");
linkTo(work + "/host.ll", work + "/host-O0", "0", false);
linkTo(work + "/host.ll", work + "/host-O2", "2", false);
let hostV0 = std.process.run([verifyTool, work + "/host-O0", "-", work + "/host.ll"]);
let hostV2 = std.process.run([verifyTool, work + "/host-O2", "-", work + "/host.ll"]);
if hostV0.status != 0 || hostV2.status != 0 {
  assert(false, "host ELF verification failed\n" + hostV0.stderr + hostV2.stderr); 1;
};
println("PASS 编好宿主(此时还没有任何扩展)");
// 2) 四个独立扩展 × 两档优化
let names = ["plugin", "second", "failure", "cycle"];
let n = 0;
while n < names.length {
  let name = names[n];
  emit(work + "/source/" + name + ".ql", "--emit-module", work + "/" + name + ".ll");
  let extIr = std.fs.readFileText(work + "/" + name + ".ll")?;
  if std.String.includes(extIr)("define i32 @main") { assert(false, name + ": emitted a second main"); 1; };
  if std.String.includes(extIr)("define ptr @ql_alloc") { assert(false, name + ": emitted a second runtime"); 1; };
  linkTo(work + "/" + name + ".ll", work + "/" + name + "-O0.so", "0", true);
  linkTo(work + "/" + name + ".ll", work + "/" + name + "-O2.so", "2", true);
  // --shared 跳过链接器内置校验;这里显式补上静态字符串校验(Python validate 的等价物)。
  let v0 = std.process.run([verifyTool, work + "/" + name + "-O0.so", "-", work + "/" + name + ".ll"]);
  let v2 = std.process.run([verifyTool, work + "/" + name + "-O2.so", "-", work + "/" + name + ".ll"]);
  if v0.status != 0 || v2.status != 0 {
    assert(false, name + ": shared ELF verification failed\n" + v0.stderr + v2.stderr); 1;
  };
  println("PASS 独立扩展:" + name);
  n = n + 1;
};
// 3) 三个负例:ABI 不匹配 / 不是原生模块 / 没有入口符号
let secondIr = std.fs.readFileText(work + "/second.ll")?;
let abiGood = "\\71\\6C\\61\\6E\\67\\2D\\6E\\61\\74\\69\\76\\65\\2D\\76\\31";
let abiBad = "\\71\\6C\\61\\6E\\67\\2D\\6E\\61\\74\\69\\76\\65\\2D\\76\\39";
let wrongAbi = std.String.replace(secondIr)(abiGood)(abiBad);
if wrongAbi == secondIr { assert(false, "ABI 字符串没找到(转义不对)"); 1; };
std.fs.writeText(work + "/wrong-abi.ll", wrongAbi);
linkTo(work + "/wrong-abi.ll", work + "/wrong-abi.so", "0", true);
let noEntry = std.String.replace(secondIr)("@qlang_extension_init_v1(")("@not_the_entry(");
if noEntry == secondIr { assert(false, "入口符号没找到"); 1; };
std.fs.writeText(work + "/no-entry.ll", noEntry);
linkTo(work + "/no-entry.ll", work + "/no-entry.so", "0", true);
std.fs.writeText(work + "/not-native.so", "println(\"must not execute source\");");
println("PASS 负例:wrong-abi / no-entry / not-native");
// 4) 删源码,跑宿主,与 .expected 比对
let rm = sh("rm -f " + sq(work + "/source") + "/*.ql");
if rm.status != 0 { die("删除源码", rm); };
let expected = std.fs.readFileText(root + "aot/tests/t37_extensions.expected")?;
let ok = 0; let bad = 0;
let ext = 0;
while ext < 2 {
  let extOpt = if ext == 0 { "0"; } else { "2"; };
  // cycle 要放在 source/cycle.so 并按那个路径传(宿主用 import(路径) 触发重入,验证 ImportCycle)。
  let cpCycle = sh("cp " + sq(work + "/cycle-O" + extOpt + ".so") + " " + sq(work + "/source/cycle.so"));
  if cpCycle.status != 0 { die("拷贝 cycle", cpCycle); };
  let soPaths = [work + "/plugin-O" + extOpt + ".so", work + "/second-O" + extOpt + ".so", work + "/failure-O" + extOpt + ".so",
                 work + "/source/cycle.so", work + "/wrong-abi.so", work + "/not-native.so", work + "/no-entry.so"];
  let paths = ""; let spi = 0;
  while spi < soPaths.length { paths = paths + (if spi == 0 { ""; } else { " "; }) + sq(soPaths[spi]); spi = spi + 1; };
  let host = 0;
  while host < 2 {
    let hostOpt = if host == 0 { "0"; } else { "2"; };
    // cwd 隔离:扩展路径必须由 .so 的绝对路径解析,不能靠进程 cwd。
    let run = sh("cd /tmp && exec " + sq(work + "/host-O" + hostOpt) + " " + paths);
    if run.status == 0 && run.stdout == expected && run.stderr == "" {
      ok = ok + 1;
      println("PASS 宿主 O" + hostOpt + " × 扩展 O" + extOpt + ": 28 契约");
    } else {
      bad = bad + 1;
      println("FAIL 宿主 O" + hostOpt + " × 扩展 O" + extOpt + " status=" + std.Number.toString(run.status) + " stderr=" + run.stderr);
    };
    host = host + 1;
  };
  ext = ext + 1;
};
println("扩展测试:" + std.Number.toString(ok) + " 通过 / " + std.Number.toString(bad) + " 失败");
if bad > 0 { assert(false, "extension failed"); 1; };
0;
