// QLang 构建驱动:一条命令完成 "编译 → 写 IR → 链接 → 校验"。全程 QLang,不调用 Python。
//
//   build <source> -o <out> [--compiler <path>] [--stdlib-object <obj>]
//                 [--symbols <tsv>] [--interface <txt>] [--stdlib-strings <tsv>]
//
// 默认:
//   --compiler        target/selfhost/stage2
//   --stdlib-object   不给就退回单模块构建(库随 runtime 一起发射,慢但自包含)
//   --symbols / --interface / --stdlib-strings 自动从 --stdlib-object 旁边的文件取
//
// 这是**顶层脚本**:命令行参数在全局 `args` 里。仓库相对路径按当前目录解析
// (与 aot/bootstrap.sh 一样,从仓库根运行)。

let fail = (message) -> { assert(false, "build: " + message); 1; };
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

let compiler = "target/selfhost/stage2";
let source = ""; let output = "";
let stdlibObject = ""; let symbols = ""; let interface = ""; let stdlibStrings = "";
let ai = 0;
while ai < args.length {
  let arg = args[ai];
  if arg == "-o" { ai = ai + 1; output = args[ai]; }
  else if arg == "--compiler" { ai = ai + 1; compiler = args[ai]; }
  else if arg == "--stdlib-object" { ai = ai + 1; stdlibObject = args[ai]; }
  else if arg == "--symbols" { ai = ai + 1; symbols = args[ai]; }
  else if arg == "--interface" { ai = ai + 1; interface = args[ai]; }
  else if arg == "--stdlib-strings" { ai = ai + 1; stdlibStrings = args[ai]; }
  else if source == "" { source = arg; };
  ai = ai + 1;
};
if source == "" || output == "" { fail("usage: build <source> -o <out> [--compiler path] [--stdlib-object obj]"); };

// 对象化构建:接口/符号/字符串都从对象旁边取,不要往 argv 里塞空串
// (空参数以前让 ql_spawn 直接 -1001,编译器根本没启动,只留下一条空诊断)。
if stdlibObject != "" {
  let dir = dirOf(stdlibObject);
  if symbols == "" { symbols = dir + "/symbols.tsv"; };
  if interface == "" { interface = dir + "/mod.ql"; };
  if stdlibStrings == "" { stdlibStrings = dir + "/strings.tsv"; };
};

// 0) 先删旧产物:任一步失败都不能让上一次的二进制留在 -o 位置冒充成功。
std.fs.remove(output);

// 1) 编译。
let emitArgs = [];
if stdlibObject != "" {
  emitArgs = [compiler, "--emit-llvm-split", source, "aot/runtime.ql", symbols, interface];
} else {
  // 单模块:仓库自带 runtime + 标准库,不需要对象。
  emitArgs = [compiler, "--emit-llvm", source, "aot/runtime.ql"];
};
let emitted = std.process.run(emitArgs);
if emitted.status != 0 { fail("emit failed for " + source + ":\n" + emitted.stderr); };

let irPath = output + ".ir.ll";
let written = std.fs.writeText(irPath, emitted.stdout);
if isError(written) { fail("cannot write " + irPath); };

// 2) 链接(+ 校验),由 QLang 链接器完成。
let linkArgs = ["target/tools/link", irPath, "-o", output];
if stdlibObject != "" { linkArgs[linkArgs.length] = "--stdlib-object"; linkArgs[linkArgs.length] = stdlibObject; };
if stdlibStrings != "" { linkArgs[linkArgs.length] = "--stdlib-ir"; linkArgs[linkArgs.length] = stdlibStrings; };
let linked = std.process.run(linkArgs);
std.fs.remove(irPath);
if linked.status != 0 { fail("link failed for " + source + ":\n" + linked.stdout + linked.stderr); };
0;
