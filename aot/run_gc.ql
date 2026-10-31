// QLang GC 测试驱动(不依赖 Python):分配器契约 + t18 GC 压力用例。
//
//   run_gc [--compiler <c>] [--stdlib <dir>] [--root <repo>] [--tmp <base>]
//
// 覆盖原 Python 套件 aot/run_gc_tests.py:
//   1) gc_allocator.c + runtime.c 在 -O0/-O2 下以 -Wall -Wextra -Werror 编译并跑通
//      (roots 与 interior pointer 必须跨原生回收存活);
//   2) t18_gc.ql 走 split 发射,分别 --opt 0/--opt 2 链接,退出码 0、
//      标准输出与 .expected 逐字节一致、stderr 为空。
//
// 分配器测试按 Python 版用 clang 直接编译;QLang 程序走 QLang 链接器。
let compiler = "target/selfhost/stage2";
let stdlibDir = "";
let root = ".";
let base = "/tmp/qlang-gc-q";
let runtime = "aot/runtime.ql";
let linkTool = "target/tools/link";
let rest = [];
let i = 0;
while i < args.length {
  let a = args[i];
  if a == "--compiler" { i = i + 1; compiler = args[i]; }
  else if a == "--stdlib" { i = i + 1; stdlibDir = args[i]; }
  else if a == "--root" { i = i + 1; root = args[i]; }
  else if a == "--tmp" { i = i + 1; base = args[i]; }
  else { rest[rest.length] = a; };
  i = i + 1;
};
if rest.length > 0 { stdlibDir = rest[0]; };
if stdlibDir == "" { assert(false, "usage: run_gc <stdlib-dir>"); 1; };

std.process.run(["rm", "-rf", base]);
std.process.run(["mkdir", "-p", base]);
let num = (n) -> std.Number.toString(n);
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
let pass = 0; let fail = 0; let failed = "";
let record = (ok, label) -> {
  if ok { pass = pass + 1; } else { fail = fail + 1; failed = failed + " " + label; };
  null;
};
// --emit-llvm-split:只发用户模块,库由 stdlib.o 补齐。
let emitSplit = (source, ir) -> {
  let r = std.process.run([compiler, "--emit-llvm-split", source, runtime,
                           stdlibDir + "/symbols.tsv", stdlibDir + "/mod.ql"]);
  if r.status != 0 { return r; };
  writeFile(ir, r.stdout);
  r;
};
let linkIR = (ir, out, opt) -> std.process.run([linkTool, ir, "-o", out, "--opt", num(opt),
                                                "--stdlib-object", stdlibDir + "/stdlib.o",
                                                "--root", root]);

// ---- 1) 分配器契约:roots + interior pointers @ -O0/-O2 --------------------
let allocatorCheck = (opt) -> {
  let bin = base + "/allocator-" + opt;
  let cc = std.process.run(["clang", opt, "-fuse-ld=lld", "-Wl,--threads=1",
                            "-Wl,--export-dynamic", "-Wall", "-Wextra", "-Werror",
                            "aot/tests/gc_allocator.c", "aot/runtime.c", "-ldl", "-o", bin]);
  if cc.status != 0 { return false; };
  std.process.run([bin]).status == 0;
};
record(allocatorCheck("-O0"), "allocator:-O0");
record(allocatorCheck("-O2"), "allocator:-O2");

// ---- 2) t18:split 发射 + --opt 0/2 链接 + 逐字节比对 ----------------------
let expected = readFile("aot/tests/t18_gc.expected");
let ir = base + "/t18_gc.ll";
let emitted = emitSplit("aot/tests/t18_gc.ql", ir);
record(emitted.status == 0, "t18:emit");
if emitted.status == 0 {
  let caseRun = (opt) -> {
    let bin = base + "/stress-O" + num(opt);
    let linked = linkIR(ir, bin, opt);
    if linked.status != 0 { return false; };
    let run = std.process.run([bin]);
    run.status == 0 && run.stdout == expected && run.stderr == "";
  };
  record(caseRun(0), "t18:O0");
  record(caseRun(2), "t18:O2");
} else {
  record(false, "t18:O0");
  record(false, "t18:O2");
};

println("QLang GC 驱动:" + num(pass) + " 通过 / " + num(fail) + " 失败");
if failed != "" { println("失败:" + failed); };
if fail > 0 { assert(false, "gc tests failed"); 1; };
0;
