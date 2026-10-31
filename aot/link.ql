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
let endsWith = (text, suffix) -> {
  if text.length < suffix.length { return false; }
  std.Bytes.slice(text, text.length - suffix.length, suffix.length) == suffix;
};
let clean = (paths) -> { let i = 0; while i < paths.length { std.process.run(["rm", "-f", paths[i]]); i = i + 1; }; null; };

let irPath = ""; let output = ""; let stdlibObject = ""; let runtimeObject = "";
// `--root <repo>`:仓库相对路径(运行时叶子、toolchain 模板、verify 工具)都按它解析,
// 这样从任意 cwd 都能链接 —— QLang 写的驱动不必再 `cd` 到仓库根。
let root = "";
let verifyTool = ""; let stdlibIr = ""; let skipVerify = false;
let optLevel = "2"; let sharedMode = false; let ltoMode = false; let ltoOpt = "2"; let debugMode = false;
let ai = 0;
while ai < args.length {
  let arg = args[ai];
  if arg == "-o" { ai = ai + 1; output = args[ai]; }
  else if arg == "--stdlib-object" { ai = ai + 1; stdlibObject = args[ai]; }
  else if arg == "--runtime-object" { ai = ai + 1; runtimeObject = args[ai]; }
  else if arg == "--root" { ai = ai + 1; root = args[ai]; if !endsWith(root, "/") { root = root + "/"; }; }
  else if arg == "--verify" { ai = ai + 1; verifyTool = args[ai]; }
  else if arg == "--stdlib-ir" { ai = ai + 1; stdlibIr = args[ai]; }   // 优先 strings.tsv;IR/bitcode 只用于用户 IR 校验
  else if arg == "--no-verify" { skipVerify = true; }
  else if arg == "--opt" { ai = ai + 1; optLevel = args[ai]; }
  else if arg == "--shared" { sharedMode = true; }
  else if arg == "--lto" { ltoMode = true; }
  else if arg == "--debug" { debugMode = true; }
  else if arg == "--lto-opt" { ai = ai + 1; ltoOpt = args[ai]; }
  else if irPath == "" { irPath = arg; };
  ai = ai + 1;
};
if verifyTool == "" { verifyTool = root + "target/tools/verify"; };
if irPath == "" || output == "" { fail("usage: link <ir> -o <out> [--stdlib-object <obj>] [--runtime-object <obj>]"); };

// runtime.c → runtime.o。缓存键 = 平台 + 优化级 + 文件内容哈希(改 runtime.c 自动失效);
// 用 Bytes.read 读 ELF 判存在(按文本读必然 IOError,会导致每次链接都重编)。
let sqPath = (v) -> "'" + std.String.replace(v)("'")("'\\''") + "'";
let runtimeContentHash = (path, cfgPath) -> {
  // sha256(runtime.c + toolchain cfg): content and codegen template both invalidate.
  let r = std.process.run(["sh", "-c", "cat " + sqPath(path) + " " + sqPath(cfgPath) + " | sha256sum"]);
  if r.status != 0 { return std.Number.toString(std.Math.random()); };
  let hex = std.String.split(r.stdout)(" ");
  if hex.length < 1 { return "0"; };
  std.Bytes.slice(hex[0], 0, 16);
};
if runtimeObject == "" && !sharedMode {
  let runtimeSource = root + "aot/runtime.c";
  runtimeObject = "/tmp/.qlang-runtime-aarch64-O" + optLevel + "-" + runtimeContentHash(runtimeSource, root + "aot/toolchain/aarch64-android24.cfg") + ".o";
  let existing = std.Bytes.read(runtimeObject);
  let valid = false;
  if !isError(existing) && std.Bytes.length(existing) > 64 {
    valid = std.Bytes.byteAt(existing, 0) == 127 && std.Bytes.byteAt(existing, 1) == 69
      && std.Bytes.byteAt(existing, 2) == 76 && std.Bytes.byteAt(existing, 3) == 70;
  };
  if !valid {
    // 唯一临时名 + rename:并发链接不会读到写了一半的 .o。
    let tmp = runtimeObject + ".tmp" + std.Number.toString(std.Math.random());
    let built = std.process.run(["clang", "-O" + optLevel, "-c", runtimeSource, "-o", tmp]);
    if built.status != 0 { std.process.run(["rm", "-f", tmp]); fail("runtime.c compile failed:\n" + built.stderr); };
    let moved = std.process.run(["mv", tmp, runtimeObject]);
    if moved.status != 0 { fail("cannot publish " + runtimeObject + "\n" + moved.stderr); };
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
} else if debugMode {
// debug:让 llc **直接吃 IR**(llc 自己会做代码生成需要的规范化),跳过 opt 这一趟。
// 少一次进程启动,也少一遍 IR 级优化 —— 代价是运行期(没有内联/合并),产物语义不变。
// verify 仍然默认开着(它是"不发布错二进制"的门,和优化等级无关)。
let llcArgs = ["llc", "-O" + optLevel, "-filetype=obj", irPath, "-o", object];
if sharedMode { llcArgs = ["llc", "-O" + optLevel, "-relocation-model=pic", "-filetype=obj", irPath, "-o", object]; };
let compiled = std.process.run(llcArgs);
if compiled.status != 0 { fail("llc (debug) failed:\n" + compiled.stderr); };
} else {
let optimized = std.process.run(["opt", "-O" + optLevel, irPath, "-o", bitcode]);
if optimized.status != 0 { fail("opt failed:\n" + optimized.stderr); };
let llcArgs = ["llc", "-O" + optLevel, "-filetype=obj", bitcode, "-o", object];
if sharedMode { llcArgs = ["llc", "-O" + optLevel, "-relocation-model=pic", "-filetype=obj", bitcode, "-o", object]; };
let compiled = std.process.run(llcArgs);
if compiled.status != 0 { fail("llc failed:\n" + compiled.stderr); };
};

let cfgText = std.fs.readFileText(root + "aot/toolchain/aarch64-android24.cfg");
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
// 库字符串只认对象旁的 strings.tsv;没给就自动找,找不到就显式失败 —— 不能静默 0 条报绿。
let dirOf = (path) -> {
  let parts = std.String.split(path)("/");
  if parts.length <= 1 { return "."; };
  let out = ""; let i = 0;
  while i < parts.length - 1 {
    // Preserve the leading empty component of an absolute path ("/root/x").
    if i == 0 { out = parts[i]; } else { out = out + "/" + parts[i]; };
    i = i + 1;
  };
  out;
};
let explicitStdlibIr = stdlibIr != "";
let verifyStrings = stdlibIr;
if verifyStrings == "" && stdlibObject != "" {
  let candidate = dirOf(stdlibObject) + "/strings.tsv";
  let probe = std.Bytes.read(candidate);
  if !isError(probe) { verifyStrings = candidate; };
};
if endsWith(verifyStrings, ".ll") || endsWith(verifyStrings, ".bc") { verifyStrings = ""; };
// An explicit --stdlib-ir that is IR/bitcode cannot serve as the TSV string list;
// verify still checks the user IR, so do not hard-fail in that case. A bare
// object with no list at all is the silent-skip case and still fails.
if !skipVerify && !sharedMode && stdlibObject != "" && verifyStrings == "" && explicitStdlibIr {
  // Explicit IR/bitcode cannot serve as the TSV list; user IR is still verified.
  // Warn (best effort) instead of silently claiming library strings were checked.
  std.fs.writeText("/dev/stderr", "warning: --stdlib-ir is IR/bitcode; library string verification skipped\n");
};
if !skipVerify && !sharedMode && stdlibObject != "" && verifyStrings == "" && !explicitStdlibIr {
  fail("stdlib object has no strings.tsv; refusing to skip library string verification (use --no-verify to override)");
};
if !skipVerify && !sharedMode {
  let checkArgs = [verifyTool, staged, if verifyStrings == "" { "-"; } else { verifyStrings; }, irPath];
  if ltoMode { checkArgs[checkArgs.length] = "--lto"; };
  let checked = std.process.run(checkArgs);
  if checked.status != 0 {
    clean([bitcode, object, staged]);
    fail("verification failed:\n" + checked.stdout + checked.stderr);
  };
};

// `mv` moves a file *into* an existing directory and returns success, so an
// output path that is a directory would look like a successful link. Reject it.
let outIsDir = std.process.run(["test", "-d", output]);
if outIsDir.status == 0 { clean([bitcode, object, staged]); fail("output path is a directory: " + output); };
let published = std.process.run(["mv", staged, output]);
clean([bitcode, object]);
if published.status != 0 { fail("cannot publish " + output + "\n" + published.stderr); };
