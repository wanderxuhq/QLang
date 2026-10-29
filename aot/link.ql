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
let startsWith = (text, prefix) -> std.String.startsWith(text)(prefix);
let clean = (paths) -> { let i = 0; while i < paths.length { std.process.run(["rm", "-f", paths[i]]); i = i + 1; }; null; };

let irPath = ""; let output = ""; let stdlibObject = ""; let runtimeObject = "";
let verifyTool = "target/tools/verify"; let stdlibIr = ""; let skipVerify = false;
let optLevel = "2"; let sharedMode = false; let ltoMode = false; let ltoOpt = "2";
let ai = 0;
while ai < args.length {
  let arg = args[ai];
  if arg == "-o" { ai = ai + 1; output = args[ai]; }
  else if arg == "--stdlib-object" { ai = ai + 1; stdlibObject = args[ai]; }
  else if arg == "--runtime-object" { ai = ai + 1; runtimeObject = args[ai]; }
  else if arg == "--verify" { ai = ai + 1; verifyTool = args[ai]; }
  else if arg == "--stdlib-ir" { ai = ai + 1; stdlibIr = args[ai]; }   // 可以是 IR,也可以是对象旁的 strings.tsv
  else if arg == "--no-verify" { skipVerify = true; }
  else if arg == "--opt" { ai = ai + 1; optLevel = args[ai]; }
  else if arg == "--shared" { sharedMode = true; }
  else if arg == "--lto" { ltoMode = true; }
  else if arg == "--lto-opt" { ai = ai + 1; ltoOpt = args[ai]; }
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

if sharedMode { runtimeObject = ""; };
let bitcode = output + ".bc";
let object = output + ".user.o";
let staged = output + ".tmp";

if ltoMode {
  // 库只编一次(bitcode),这里做跨模块内联:llvm-link → opt → llc。
  let stdlibBc = stdlibObject;
  if stdlibBc == "" { fail("--lto requires --stdlib-object (next to stdlib.bc)"); };
  if std.String.endsWith(stdlibBc)(".o") { stdlibBc = std.String.replace(stdlibBc)(".o")("") + ".bc"; };
  let merged = output + ".merged.bc"; let mergedOpt = output + ".lto.bc";
  let linkStep = std.process.run(["llvm-link", irPath, stdlibBc, "-o", merged]);
  if linkStep.status != 0 { clean([merged]); fail("llvm-link failed:\n" + linkStep.stderr); };
  // clang 的 LTO 驱动做两件我们之前漏掉的事:**先 internalize+globaldce**(把库函数变成
  // internal 并删掉没人用的),然后跑 **lto<O> 管线**(LTO 专用的优化顺序)。缺了这两步,
  // 库函数停留在 hidden、内联/DCE 都保守,热循环会慢 15–20%。
  let passes = "lto<O" + ltoOpt + ">";
  let optArgs = ["opt"];
  if !sharedMode {
    passes = "internalize,globaldce," + passes;
    optArgs[optArgs.length] = "-internalize-public-api-list=main";
  };
  optArgs[optArgs.length] = "-passes=" + passes;
  optArgs[optArgs.length] = merged;
  optArgs[optArgs.length] = "-o";
  optArgs[optArgs.length] = mergedOpt;
  let optimized = std.process.run(optArgs);
  if optimized.status != 0 { clean([merged, mergedOpt]); fail("opt (lto) failed:\n" + optimized.stderr); };
  let ltoLlc = ["llc", "-O" + ltoOpt, "-filetype=obj", mergedOpt, "-o", object];
  if sharedMode { ltoLlc = ["llc", "-O" + ltoOpt, "-relocation-model=pic", "-filetype=obj", mergedOpt, "-o", object]; };
  let compiledLto = std.process.run(ltoLlc);
  clean([merged, mergedOpt]);
  if compiledLto.status != 0 { fail("llc (lto) failed:\n" + compiledLto.stderr); };
  stdlibObject = "";
} else {
let optimized = std.process.run(["opt", "-O2", irPath, "-o", bitcode]);
if optimized.status != 0 { fail("opt failed:\n" + optimized.stderr); };
let llcArgs = ["llc", "-O2", "-filetype=obj", bitcode, "-o", object];
if sharedMode { llcArgs = ["llc", "-O2", "-relocation-model=pic", "-filetype=obj", bitcode, "-o", object]; };
let compiled = std.process.run(llcArgs);
if compiled.status != 0 { fail("llc failed:\n" + compiled.stderr); };
};

let cfgText = std.fs.readFileText("aot/toolchain/aarch64-android24.cfg");
if isError(cfgText) { fail("cannot read toolchain template"); };
let lines = std.String.split(cfgText)("\n");
let template = "";
let wantKey = if sharedMode { "shared " } else { "exe " };
let li = 0;
while li < lines.length {
  let candidate = lines[li];
  if startsWith(candidate, wantKey) {
    template = std.Bytes.slice(candidate, wantKey.length, candidate.length - wantKey.length);
    li = lines.length;
  } else {
    li = li + 1;
  };
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

// 校验:链接产物里的静态字符串必须和 IR 一致。校验不过就不发布(保留旧产物)。
if !skipVerify && !sharedMode {
  let checkArgs = [verifyTool, staged, if stdlibIr == "" { "-"; } else { stdlibIr; }, irPath];
  if ltoMode { checkArgs[checkArgs.length] = "--lto"; };
  let checked = std.process.run(checkArgs);
  if checked.status != 0 {
    clean([bitcode, object, staged]);
    fail("verification failed:\n" + checked.stdout + checked.stderr);
  };
};

let published = std.process.run(["mv", staged, output]);
clean([bitcode, object]);
if published.status != 0 { fail("cannot publish " + output + "\n" + published.stderr); };
