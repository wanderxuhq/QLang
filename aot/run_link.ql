// 链接器测试(QLang 版,port of aot/run_link_tests.py)。
//
//   run_link <tmp-dir> --root <repo> [--historical-dir <dir>] [--stdlib-object <obj>]
//
// 覆盖:
//   1) 手写 IR 的三个静态字符串(ASCII+换行、中文+NUL+emoji+换行、空串),
//      -O0/-O2 链接后运行,stdout 字节必须逐个相等,stderr 必须为空;
//   2) 6 种损坏 ELF:截断、错误架构、错误 tag、错误长度、错误 buffer 字节、
//      清空 PT_DYNAMIC 的 DT_RELASZ —— verify 必须退出 1 并给出对应关键词;
//   3) 原子发布:PATH 里的 llc/ld.lld shim 写坏文件却退出 0、以及链接器非零退出,
//      都不能替换已有的好产物,且输出目录不留临时文件。
//
// stdout 用重定向到文件 + std.Bytes.read 比较(process capture 会做 UTF-8 校验)。
// 这是顶层脚本:命令行参数在全局 `args` 里。

let endsWith = (text, suffix) -> {
  if text.length < suffix.length { return false; }
  std.Bytes.slice(text, text.length - suffix.length, suffix.length) == suffix;
};
let sq = (v) -> "'" + std.String.replace(v)("'")("'\\''") + "'";
let sh = (cmd) -> std.process.run(["sh", "-c", cmd]);
let failNow = (message) -> { println("FAIL: " + message); assert(false, message); 1; };
let readBytes = (path) -> {
  let b = std.Bytes.read(path);
  if isError(b) { failNow("cannot read " + path); };
  b;
};
let sameBytes = (a, b) -> {
  if isError(a) || isError(b) { return false; };
  let la = std.Bytes.length(a); let lb = std.Bytes.length(b);
  if isError(la) || isError(lb) || la != lb { return false; };
  let i = 0; let ok = true;
  while i < la && ok {
    let x = std.Bytes.byteAt(a, i); let y = std.Bytes.byteAt(b, i);
    if isError(x) || isError(y) || x != y { ok = false; };
    i = i + 1;
  };
  ok;
};
// 小端 8 字节值;只用于 <128 的测试值(>=128 的码点会被 UTF-8 编码成两字节)。
let le8 = (n) -> {
  let out = ""; let i = 0; let value = n;
  while i < 8 {
    let c = value % 256;
    value = (value - c) / 256;
    out = out + std.String.fromCodePoint(c);
    i = i + 1;
  };
  out;
};

// ---- 安全读取(仅用于确定有效的 ELF,越界仍返回 -1) ----------------------
let lengthOf = (b) -> { let n = std.Bytes.length(b); if isError(n) { -1; } else { n; }; };
let byteOr = (b, off) -> {
  let n = lengthOf(b);
  if off < 0 || off >= n { return -1; };
  let v = std.Bytes.byteAt(b, off);
  if isError(v) { -1; } else { v; };
};
let u16Or = (b, off) -> {
  let a = byteOr(b, off); let c = byteOr(b, off + 1);
  if a < 0 || c < 0 { return -1; };
  a + c * 256;
};
let u32Or = (b, off) -> {
  let a = byteOr(b, off); let c = byteOr(b, off + 1);
  let d = byteOr(b, off + 2); let e = byteOr(b, off + 3);
  if a < 0 || c < 0 || d < 0 || e < 0 { return -1; };
  a + c * 256 + d * 65536 + e * 16777216;
};
let u64Or = (b, off) -> {
  let n = lengthOf(b);
  if off < 0 || off + 8 > n { return -1; };
  let v = std.Bytes.u64(b, off);
  if isError(v) { -1; } else { v; };
};
let addrOf = (segments, address, count) -> {
  let i = 0;
  while i < segments.length {
    let seg = segments[i];
    if seg.type == 1 && address >= seg.vaddr {
      let delta = address - seg.vaddr;
      if delta <= seg.filesz && count >= 0 && delta + count <= seg.filesz {
        return seg.offset + delta;
      };
    };
    i = i + 1;
  };
  -1;
};
// 从 good ELF 里取出损坏测试需要的三个偏移:.strbox9000000 头、buffer 首字节、
// DT_RELASZ 的值字段。(用户 id 用 9000000+ 以免和 stdlib 对象的 .strbox0.. 撞名。)
let probeElf = (b) -> {
  let phoff = u64Or(b, 32); let phentsize = u16Or(b, 54); let phnum = u16Or(b, 56);
  let segments = [];
  let i = 0;
  while i < phnum {
    let at = phoff + i * phentsize;
    segments[segments.length] = {
      type: u32Or(b, at), offset: u64Or(b, at + 8),
      vaddr: u64Or(b, at + 16), filesz: u64Or(b, at + 32)
    };
    i = i + 1;
  };
  let shoff = u64Or(b, 40); let shentsize = u16Or(b, 58); let shnum = u16Or(b, 60);
  let symOff = -1; let symSize = 0; let symLink = 0;
  i = 0;
  while i < shnum {
    let at = shoff + i * shentsize;
    if u32Or(b, at + 4) == 2 {
      symOff = u64Or(b, at + 24); symSize = u64Or(b, at + 32); symLink = u32Or(b, at + 40);
    };
    i = i + 1;
  };
  if symOff < 0 { failNow("good ELF has no symbol table"); };
  let namesOff = u64Or(b, shoff + symLink * shentsize + 24);
  let address = -1;
  i = 0;
  while i < symSize / 24 {
    let at = symOff + i * 24;
    let nameAt = namesOff + u32Or(b, at);
    let nameHex = std.Bytes.hex(b, nameAt, 15);
    if !isError(nameHex) && nameHex == "2e737472626f783930303030303000" {   // ".strbox9000000\0"
      address = u64Or(b, at + 8);
    };
    i = i + 1;
  };
  if address < 0 { failNow("good ELF has no .strbox9000000 symbol"); };
  let relaAddr = -1; let relaSize = 0; let relaszAt = -1;
  i = 0;
  while i < segments.length {
    if segments[i].type == 2 {
      let at = segments[i].offset; let end = at + segments[i].filesz;
      while at + 16 <= end {
        let tag = u64Or(b, at); let value = u64Or(b, at + 8);
        if tag == 0 { at = end; }
        else {
          if tag == 7 { relaAddr = value; }
          else if tag == 8 { relaSize = value; relaszAt = at + 8; };
          at = at + 16;
        };
      };
    };
    i = i + 1;
  };
  if relaAddr < 0 || relaSize <= 0 || relaszAt < 0 { failNow("good ELF has no dynamic RELA table"); };
  let start = addrOf(segments, relaAddr, relaSize);
  if start < 0 { failNow("good ELF RELA table is not file-backed"); };
  let target = -1;
  i = 0;
  while i < relaSize / 24 {
    let at = start + i * 24;
    if u64Or(b, at) == address + 8 { target = u64Or(b, at + 16); };
    i = i + 1;
  };
  if target < 0 { failNow(".strbox9000000 has no loader relocation"); };
  let headerAt = addrOf(segments, address, 24);
  let targetAt = addrOf(segments, target, 1);
  if headerAt < 0 || targetAt < 0 { failNow("good ELF strbox data is not file-backed"); };
  { headerAt: headerAt, targetAt: targetAt, relaszAt: relaszAt };
};
let spliceBytes = (data, at, replacement) -> {
  let size = lengthOf(data);
  let count = lengthOf(replacement);
  if at < 0 || count < 0 || at + count > size { failNow("splice out of range"); };
  let left = std.Bytes.slice(data, 0, at);
  let right = std.Bytes.slice(data, at + count, size - at - count);
  if isError(left) || isError(right) { failNow("splice slice failed"); };
  left + replacement + right;
};

// ---- 参数 ---------------------------------------------------------------
let work = "";
let root = "";
let stdlibObject = "";
let historical = "";
let rest = [];
let i = 0;
while i < args.length {
  let a = args[i];
  if a == "--root" { i = i + 1; root = args[i]; }
  else if a == "--stdlib-object" { i = i + 1; stdlibObject = args[i]; }
  else if a == "--historical-dir" { i = i + 1; historical = args[i]; }
  else { rest[rest.length] = a; };
  i = i + 1;
};
if work == "" && rest.length > 0 { work = rest[0]; };
if work == "" || root == "" {
  assert(false, "usage: run_link <tmp-dir> --root <repo> [--historical-dir <dir>] [--stdlib-object <obj>]"); 1;
};
if !endsWith(root, "/") { root = root + "/"; };
let linkTool = root + "target/tools/link";
let verifyTool = root + "target/tools/verify";
let prepared = sh("rm -rf " + sq(work) + " && mkdir -p " + sq(work) + " " + sq(work + "/bin") + " " + sq(work + "/atomic"));
if prepared.status != 0 { failNow("prepare work dir: " + prepared.stderr); };

// ---- 1) 手写 IR:三个字符串 ---------------------------------------------
let escaped = ["\\41\\53\\43\\49\\49\\0A",                          // ASCII\n
               "\\E4\\B8\\AD\\E6\\96\\87\\00\\F0\\9F\\98\\80\\0A", // 中文\0😀\n
               ""];                                               // empty
let lengths = [6, 12, 0];
let lines = [];
lines[lines.length] = "declare void @ql_write(i32, ptr, i64)";
lines[lines.length] = "define i32 @main() {";
let n = 0;
while n < 3 {
  let t = std.Number.toString(n);
  let box = std.Number.toString(9000000 + n);
  lines[lines.length] = "  %p" + t + " = getelementptr i8, ptr @.strbox" + box + ", i64 8";
  lines[lines.length] = "  %v" + t + " = load ptr, ptr %p" + t;
  lines[lines.length] = "  call void @ql_write(i32 1, ptr %v" + t + ", i64 " + std.Number.toString(lengths[n]) + ")";
  n = n + 1;
};
lines[lines.length] = "  ret i32 0";
lines[lines.length] = "}";
n = 0;
while n < 3 {
  let t = std.Number.toString(9000000 + n);
  let lenText = std.Number.toString(lengths[n]);
  lines[lines.length] = "@.str" + t + " = private unnamed_addr constant [" + lenText + " x i8] c\"" + escaped[n] + "\"";
  lines[lines.length] = "@.strbox" + t + " = global { i64, ptr, i64 } { i64 2, ptr @.str" + t + ", i64 " + lenText + " }";
  n = n + 1;
};
// 标准库对象引用编译器发射的扩展 ABI 串;手写 IR 只需提供一个定义让链接闭合
// (本夹具不调用 __stdlib_init,所以内容无关)。
lines[lines.length] = "@qlang_extension_abi_v1 = constant [1 x i8] c\"x\"";
let irPath = work + "/strings.ll";
let irWritten = std.fs.writeText(irPath, std.String.join(lines)("\n") + "\n");
if isError(irWritten) { failNow("cannot write IR"); };
let expectedPath = work + "/expected.bin";
let expectedWritten = std.fs.writeText(expectedPath, "ASCII\n中文\0😀\n");
if isError(expectedWritten) { failNow("cannot write expected bytes"); };
let expected = readBytes(expectedPath);

let optIndex = 0;
while optIndex < 2 {
  let opt = if optIndex == 0 { "0"; } else { "2"; };
  let binary = work + "/strings-O" + opt;
  let linked = std.process.run([linkTool, irPath, "-o", binary, "--opt", opt, "--root", root]);
  if linked.status != 0 { failNow("link -O" + opt + ":\n" + linked.stdout + linked.stderr); };
  let outPath = work + "/out-O" + opt + ".bin";
  let errPath = work + "/err-O" + opt + ".txt";
  let run = sh(sq(binary) + " > " + sq(outPath) + " 2> " + sq(errPath));
  if run.status != 0 { failNow("run -O" + opt + ": status " + std.Number.toString(run.status) + "\n" + run.stderr); };
  let actual = readBytes(outPath);
  if !sameBytes(actual, expected) {
    failNow("stdout bytes mismatch at -O" + opt + ": got " + std.Bytes.hex(actual, 0, std.Bytes.length(actual)));
  };
  let errBytes = readBytes(errPath);
  if std.Bytes.length(errBytes) != 0 { failNow("stderr is not empty at -O" + opt); };
  println("PASS static strings, UTF-8, NUL and empty buffer at -O" + opt);
  optIndex = optIndex + 1;
};

// 可选的库对象路径:同一 IR 叠加 stdlib.o(库字符串由 strings.tsv 校验)。
if stdlibObject != "" {
  let libBinary = work + "/strings-lib";
  let libLink = std.process.run([linkTool, irPath, "-o", libBinary, "--opt", "0", "--root", root, "--stdlib-object", stdlibObject]);
  if libLink.status != 0 { failNow("link with --stdlib-object:\n" + libLink.stdout + libLink.stderr); };
  let libOut = work + "/out-lib.bin";
  let libErr = work + "/err-lib.txt";
  let libRun = sh(sq(libBinary) + " > " + sq(libOut) + " 2> " + sq(libErr));
  if libRun.status != 0 { failNow("run --stdlib-object: status " + std.Number.toString(libRun.status)); };
  if !sameBytes(readBytes(libOut), expected) { failNow("stdout bytes mismatch with --stdlib-object"); };
  if std.Bytes.length(readBytes(libErr)) != 0 { failNow("stderr with --stdlib-object is not empty"); };
  println("PASS static strings with --stdlib-object");
};

// ---- 2) 六种损坏 ELF ----------------------------------------------------
let good = readBytes(work + "/strings-O0");
let probe = probeElf(good);
let badPath = work + "/bad";
let bad = [{ name: "truncated ELF", keyword: "beyond", data: std.Bytes.slice(good, 0, 24) },
           { name: "wrong architecture", keyword: "machine",
             data: spliceBytes(good, 18, ">" + "\0") },
           { name: "wrong string tag", keyword: "tag",
             data: spliceBytes(good, probe.headerAt, le8(4)) },
           { name: "wrong string length", keyword: "size",
             data: spliceBytes(good, probe.headerAt + 16, le8(127)) },
           { name: "missing loader relocations", keyword: "relocation",
             data: spliceBytes(good, probe.relaszAt, le8(0)) }];
let targetByte = byteOr(good, probe.targetAt);
let replacementByte = if targetByte == 66 { 67; } else { 66; };
bad[bad.length] = { name: "wrong string bytes", keyword: "bytes",
                    data: spliceBytes(good, probe.targetAt, std.String.fromCodePoint(replacementByte)) };
let bi = 0;
while bi < bad.length {
  let case = bad[bi];
  let written = std.fs.writeText(badPath, case.data);
  if isError(written) { failNow("cannot write corrupt ELF " + case.name); };
  let checked = std.process.run([verifyTool, badPath, "-", irPath]);
  if checked.status == 0 { failNow("accepted " + case.name); };
  let text = checked.stdout + checked.stderr;
  if !std.String.includes(text)(case.keyword) {
    failNow("rejected " + case.name + " without keyword '" + case.keyword + "': " + text);
  };
  println("PASS reject: " + case.name);
  bi = bi + 1;
};

// ---- 3) 原子发布 -------------------------------------------------------
let atomicDir = work + "/atomic";
let atomicBin = atomicDir + "/prog";
let goodLink = std.process.run([linkTool, irPath, "-o", atomicBin, "--opt", "0", "--root", root]);
if goodLink.status != 0 { failNow("atomic baseline link:\n" + goodLink.stdout + goodLink.stderr); };
let goodAtomic = readBytes(atomicBin);
let shim = work + "/bin/ld.lld";
let pathPrefix = "PATH=" + sq(work + "/bin") + ":\"$PATH\" ";
let corruptShim = "#!/bin/sh\n"
  + "out=\"\"\n"
  + "while [ $# -gt 0 ]; do\n"
  + "  if [ \"$1\" = \"-o\" ]; then out=\"$2\"; shift 2; else shift; fi\n"
  + "done\n"
  + "cp " + sq(badPath) + " \"$out\"\n"
  + "exit 0\n";
let shimWritten = std.fs.writeText(shim, corruptShim);
if isError(shimWritten) { failNow("cannot write ld.lld shim"); };
let chmod = sh("chmod +x " + sq(shim));
if chmod.status != 0 { failNow("chmod shim"); };
let fake = sh(pathPrefix + sq(linkTool) + " " + sq(irPath) + " -o " + sq(atomicBin) + " --opt 0 --root " + sq(root));
if fake.status == 0 { failNow("published a malformed linker result"); };
if !sameBytes(readBytes(atomicBin), goodAtomic) { failNow("malformed linker result replaced the good executable"); };
println("PASS malformed linker result preserved the previous executable");

let failShim = "#!/bin/sh\nexit 7\n";
if isError(std.fs.writeText(shim, failShim)) { failNow("cannot write failing shim"); };
let failing = sh(pathPrefix + sq(linkTool) + " " + sq(irPath) + " -o " + sq(atomicBin) + " --opt 0 --root " + sq(root));
if failing.status == 0 { failNow("ignored linker failure"); };
if !sameBytes(readBytes(atomicBin), goodAtomic) { failNow("failed linker replaced the good executable"); };
println("PASS linker failure preserved the previous executable");

let listing = sh("ls -A " + sq(atomicDir));
if listing.status != 0 { failNow("cannot list atomic output dir"); };
let names = std.String.split(listing.stdout)("\n");
let leftovers = [];
let ni = 0;
while ni < names.length {
  if names[ni] != "" && names[ni] != "prog" { leftovers[leftovers.length] = names[ni]; };
  ni = ni + 1;
};
if leftovers.length != 0 { failNow("temporary files left in output dir: " + std.String.join(leftovers)(", ")); };
println("PASS link failures preserve the previous executable");

// ---- 4) 历史产物(可选) -------------------------------------------------
if historical == "" {
  println("SKIP historical artifact (no --historical-dir)");
} else {
  let histIr = historical + "/core/interpreter.ll";
  let histGood = historical + "/core/interpreter";
  let histBad = historical + "/diagnostics/interpreter-missing-relocations";
  let present = sh("test -f " + sq(histIr) + " && test -f " + sq(histGood) + " && test -f " + sq(histBad));
  if present.status != 0 {
    println("SKIP historical artifact (missing files under " + historical + ")");
  } else {
    let goodCheck = std.process.run([verifyTool, histGood, "-", histIr]);
    if goodCheck.status != 0 { failNow("historical interpreter rejected:\n" + goodCheck.stdout + goodCheck.stderr); };
    let badCheck = std.process.run([verifyTool, histBad, "-", histIr]);
    if badCheck.status == 0 { failNow("accepted the historical malformed executable"); };
    let badText = badCheck.stdout + badCheck.stderr;
    if !std.String.includes(badText)("relocation") {
      failNow("historical rejection lacks 'relocation': " + badText);
    };
    println("PASS historical interpreter: good accepted, malformed rejected");
  };
};

println("Link suite: ALL CHECKS PASS");
0;
