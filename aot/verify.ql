// ELF 静态字符串校验(工具入口)。真正的解析在 runtime 里(`std.Bytes.verifyStrings`),
// 这样只有一次跨边界调用,而不是逐字段调用 —— 后者每次约 2.9 微秒。
//
//   verify <elf> <strings.tsv>
//
// strings.tsv 由标准库对象构建器产出(每行 `.strboxN<TAB>hex`)。失败退出 1。
let fail = (message) -> { assert(false, "verify: " + message); 1; };

if args.length < 2 { fail("usage: verify <elf> <strings.tsv> [ir]"); };
let ir = if args.length > 2 { args[2]; } else { ""; };
let stringsPath = if args[1] == "-" { ""; } else { args[1]; };
let relaxed = if args.length > 3 && args[3] == "--lto" { 1; } else { 0; };
if stringsPath == "" && ir == "" { fail("nothing to verify: pass strings.tsv and/or the IR"); };
let report = std.Bytes.verifyStrings(args[0], stringsPath, ir, relaxed);
if isError(report) { fail("verification failed"); };
if !report.ok { fail(report.message); };
// A non-empty strings.tsv always has entries; 0 means it was not read as expected
// (wrong file kind or missing tabs) — reporting success would hide that.
if report.count == 0 && stringsPath != "" { fail("no static strings verified from " + stringsPath); };
println("verify: " + std.String.toString(report.count) + " static strings ok");
