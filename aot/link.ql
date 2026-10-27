// QLang 链接器(取代 aot/native_link.py 的构建路径)。
//
//   link <ir> -o <out> [--stdlib-object <obj>] [--runtime-object <obj>]
//
// 全程 QLang 驱动:opt(IR 优化)→ llc(代码生成)→ ld.lld(链接)。
// clang 只在"编译 runtime.c"这一处出现,而且结果按平台缓存,正常构建不再付这笔钱。
// 链接模板按目标平台放在 aot/toolchain/<target>.cfg(由 clang -### 抓取的一次性事实)。
//
// 这是一个**顶层脚本**:运行时把命令行参数放进全局 `args`(不含程序名)。

let fail = (message) -> { assert(false, "link: " + message); 1; };
let clean = (paths) -> { let i = 0; while i < paths.length { std.process.run(["rm", "-f", paths[i]]); i = i + 1; }; null; };

let irPath = ""; let output = ""; let stdlibObject = ""; let runtimeObject = "";
let ai = 0;
while ai < args.length {
  let arg = args[ai];
  if arg == "-o" { ai = ai + 1; output = args[ai]; }
  else if arg == "--stdlib-object" { ai = ai + 1; stdlibObject = args[ai]; }
  else if arg == "--runtime-object" { ai = ai + 1; runtimeObject = args[ai]; }
  else if irPath == "" { irPath = arg; };
  ai = ai + 1;
};
if irPath == "" || output == "" { fail("usage: link <ir> -o <out> [--stdlib-object <obj>] [--runtime-object <obj>]"); };

// runtime.c → runtime.o(一次;键 = 平台)
if runtimeObject == "" {
  runtimeObject = "/tmp/.qlang-runtime-aarch64.o";
  let probe = std.fs.readFileText(runtimeObject);
  if isError(probe) || probe.length < 64 {
    let built = std.process.run(["clang", "-O2", "-c", "aot/runtime.c", "-o", runtimeObject]);
    if built.status != 0 { fail("runtime.c compile failed:\n" + built.stderr); };
  };
};

let bitcode = output + ".bc";
let object = output + ".user.o";
let staged = output + ".tmp";

let optimized = std.process.run(["opt", "-O2", irPath, "-o", bitcode]);
if optimized.status != 0 { fail("opt failed:\n" + optimized.stderr); };
let compiled = std.process.run(["llc", "-O2", "-filetype=obj", bitcode, "-o", object]);
if compiled.status != 0 { fail("llc failed:\n" + compiled.stderr); };

let cfgText = std.fs.readFileText("aot/toolchain/aarch64-android24.cfg");
if isError(cfgText) { fail("cannot read toolchain template"); };
let lines = std.String.split(cfgText)("\n");
let template = "";
let li = 0;
while li < lines.length {
  let candidate = lines[li];
  if candidate.length > 0 && candidate[0] != "#" { template = candidate; };
  li = li + 1;
};
if template == "" { fail("empty toolchain template"); };

let tokens = std.String.split(template)(" ");
let command = ["ld.lld"];
let ti = 0;
while ti < tokens.length {
  let token = tokens[ti];
  if token == "@USER@" { token = object; }
  else if token == "@RUNTIME@" { token = runtimeObject; }
  else if token == "@STDLIB@" { token = stdlibObject; }
  else if token == "@OUT@" { token = staged; };
  if token != "" { command[command.length] = token; };
  ti = ti + 1;
};
let linked = std.process.run(command);
if linked.status != 0 {
  clean([bitcode, object, staged]);
  fail("ld.lld failed:\n" + linked.stderr);
};

let published = std.process.run(["mv", staged, output]);
clean([bitcode, object]);
if published.status != 0 { fail("cannot publish " + output + "\n" + published.stderr); };
