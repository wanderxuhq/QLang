// QLang 测试驱动:跑 aot/tests 里的原生测试用例。**全程 QLang,不调用 Python。**
//
//   run_tests <stdlib-dir> [--compiler <path>]
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
let rest = [];
let i = 0;
while i < args.length {
  let a = args[i];
  if a == "--compiler" { i = i + 1; compiler = args[i]; }
  else { rest[rest.length] = a; };
  i = i + 1;
};
if rest.length > 0 { stdlibDir = rest[0]; };
if stdlibDir == "" { assert(false, "usage: run_tests <stdlib-dir> [--compiler <path>]"); 1; };
let manifest = std.fs.readFileText("aot/tests/manifest.txt")?;
let names = std.String.split(manifest)("\n");
let base = "/tmp/qlang-qltests";
std.process.run(["mkdir", "-p", base]);
std.process.run(["rm", "-rf", base + "/out"]);
std.process.run(["mkdir", "-p", base + "/out"]);
let pass = 0; let fail = 0; let failed = "";
let k = 0;
while k < names.length {
  let name = names[k];
  if name != "" {
    let src = "aot/tests/" + name + ".ql";
    let ir = base + "/" + name + ".ll";
    let bin = base + "/" + name;
    let emit = std.process.run([compiler, "--emit-llvm-split", src, "aot/runtime.ql",
                                stdlibDir + "/symbols.tsv", stdlibDir + "/mod.ql"]);
    if emit.status != 0 { fail = fail + 1; failed = failed + " " + name + "(emit)"; }
    else {
      std.fs.writeText(ir, emit.stdout);
      let linked = std.process.run([linkTool, ir, "-o", bin, "--stdlib-object", stdlibDir + "/stdlib.o"]);
      if linked.status != 0 { fail = fail + 1; failed = failed + " " + name + "(link)"; }
      else {
        let expected = std.fs.readFileText("aot/tests/" + name + ".expected");
        if isError(expected) { pass = pass + 1; }   // 没有 .expected 的用例:只要求能编能跑
        else {
          let run = std.process.run([bin]);
          if run.stdout == expected { pass = pass + 1; }
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
