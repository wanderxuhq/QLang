// QLang 构建驱动:一条命令完成 "编译 → 写 IR → 链接 → 校验"。全程 QLang,不调用 Python。
//
//   build <source> -o <out> [--compiler <path>] [--stdlib-object <obj>]
//                 [--symbols <tsv>] [--interface <txt>] [--stdlib-strings <tsv>]
//
// 默认:
//   --compiler        target/selfhost/stage2
//   --stdlib-object   target/stdlib/<最新>/stdlib.o(由 aot/stdlib_build.ql 产出)
//   --symbols / --interface / --stdlib-strings 自动从对象旁边取
//
// 这是**顶层脚本**:命令行参数在全局 `args` 里。

let fail = (message) -> { assert(false, "build: " + message); 1; };

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

// 1) 编译:只发用户模块(--emit-llvm-split),标准库来自对象。
let emitArgs = [compiler, "--emit-llvm-split", source, "aot/runtime.ql", symbols, interface];
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
