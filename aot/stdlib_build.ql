// QLang 标准库对象构建器(取代 aot/stdlib_split.py 的 build_stdlib)。
//
//   stdlib_build [--compiler <path>] [--cache-root <dir>]
//
// 做的事情和 Python 版完全一致:
//   1. 用编译器为"空程序"发一份单模块 IR(含 runtime+库),写到 <cache>/full.ll;
//   2. 纯文本切分:preamble / 每个函数体 / 每个全局;
//   3. value-ABI 叶子(internal + alwaysinline)两个模块各留一份,其余 `define internal`
//      改成 `define hidden`(跨模块可见);`@qlang_extension_abi_v1` 由用户模块定义,
//      对象里改成 external 引用;
//   4. 写 stdlib.ll / symbols.tsv / strings.tsv,跑编译器拿 interface.txt,再落 mod.ql
//      (QLang 对象字面量形式的接口),llc 出 stdlib.o;
//   5. 缓存键 = sha256(SPLIT_VERSION + 编译器 + runtime.ql + bundle.ql)。
//
// 输出最后一行的对象路径给调用方(和 Python 版一致)。

let splitVersion = "8";
let fail = (message) -> { assert(false, "stdlib_build: " + message); 1; };
let startsWith = (text, prefix) -> std.String.startsWith(text)(prefix);
let endsWith = (text, suffix) -> {
  if text.length < suffix.length { return false; }
  std.Bytes.slice(text, text.length - suffix.length, suffix.length) == suffix;
};
let findFrom = (text, needle, start) -> {
  let n = needle.length; let i = start;
  while i + n <= text.length {
    if std.Bytes.slice(text, i, n) == needle { return i; };
    i = i + 1;
  };
  -1;
};
let dropPrefix = (text, prefix) -> {
  if startsWith(text, prefix) { return std.Bytes.slice(text, prefix.length, text.length - prefix.length); };
  text;
};
let withoutSuffix = (text, suffix) -> {
  if endsWith(text, suffix) { return std.Bytes.slice(text, 0, text.length - suffix.length); };
  text;
};

// ---- 解析单模块 IR -----------------------------------------------------------
// 返回 {preamble: [...], functions: [{name, body}], globals: [{name, text}]}
let parseModule = (text) -> {
  let lines = std.String.split(text)("\n");
  let preamble = []; let functions = []; let globals = [];
  let i = 0;
  while i < lines.length {
    let line = lines[i];
    if startsWith(line, "define ") {
      let at = findFrom(line, "@", 0);
      let name = "";
      if at >= 0 {
        let p = at + 1; let stop = false;
        while p < line.length && !stop {
          let c = std.Bytes.slice(line, p, 1);
          if c == "(" || c == " " { stop = true; } else { name = name + c; p = p + 1; };
        };
      };
      let body = [line]; i = i + 1; let closed = false;
      while i < lines.length && !closed {
        body[body.length] = lines[i];
        if lines[i] == "}" { closed = true; };
        i = i + 1;
      };
      functions[functions.length] = { name: name, body: std.String.join(body)("\n") };
    } else if startsWith(line, "@") && findFrom(line, " = ", 0) > 0 {
      let at = 1; let name = "";
      while at < line.length && std.Bytes.slice(line, at, 1) != " " { name = name + std.Bytes.slice(line, at, 1); at = at + 1; };
      globals[globals.length] = { name: name, text: line };
      i = i + 1;
    } else {
      preamble[preamble.length] = line; i = i + 1;
    };
  };
  { preamble: preamble, functions: functions, globals: globals };
};

let isPinned = (body) -> {
  let header = std.String.split(body)("\n")[0];
  startsWith(header, "define internal ") && findFrom(header, "alwaysinline", 0) >= 0;
};

// `define internal ... @f(...) alwaysinline {` -> `declare ... @f(...)`
let declareFor = (body) -> {
  let header = std.String.split(body)("\n")[0];
  let text = dropPrefix(header, "define ");
  text = "declare " + text;
  if startsWith(text, "declare internal ") { text = "declare " + dropPrefix(text, "declare internal "); }
  else if startsWith(text, "declare hidden ") { text = "declare " + dropPrefix(text, "declare hidden "); }
  else if startsWith(text, "declare private ") { text = "declare " + dropPrefix(text, "declare private "); };
  let at = findFrom(text, " alwaysinline", 0);
  if at >= 0 { text = std.Bytes.slice(text, 0, at) + std.Bytes.slice(text, at + 13, text.length - at - 13); };
  withoutSuffix(text, " {");
};

// `@x = hidden global TYPE {init}` -> `@x = external global TYPE`
let externalFor = (definition) -> {
  let eq = findFrom(definition, " = ", 0);
  let name = std.Bytes.slice(definition, 0, eq);
  let head = std.Bytes.slice(definition, eq + 3, definition.length - eq - 3);
  let globalAt = findFrom(head, "global ", 0);
  let constantAt = findFrom(head, "constant ", 0);
  let kind = "global"; let rest = "";
  if globalAt >= 0 { rest = std.Bytes.slice(head, globalAt + 7, head.length - globalAt - 7); }
  else if constantAt >= 0 { kind = "constant"; rest = std.Bytes.slice(head, constantAt + 9, head.length - constantAt - 9); };
  let typeText = rest;
  if rest.length > 0 && (std.Bytes.slice(rest, 0, 1) == "[" || std.Bytes.slice(rest, 0, 1) == "{") {
    let depth = 0; let i = 0; let done = false;
    while i < rest.length && !done {
      let c = std.Bytes.slice(rest, i, 1);
      if c == "[" || c == "{" { depth = depth + 1; }
      else if c == "]" || c == "}" {
        depth = depth - 1;
        if depth == 0 { typeText = std.Bytes.slice(rest, 0, i + 1); done = true; };
      };
      i = i + 1;
    };
  } else if rest.length > 0 {
    let space = findFrom(rest, " ", 0);
    typeText = if space >= 0 { std.Bytes.slice(rest, 0, space); } else { rest; };
  };
  name + " = external " + kind + " " + typeText;
};

// ---- 主流程 -----------------------------------------------------------------
let compiler = "target/selfhost/stage2";
let cacheRoot = "target/stdlib";
let ai = 0;
while ai < args.length {
  let arg = args[ai];
  if arg == "--compiler" { ai = ai + 1; compiler = args[ai]; }
  else if arg == "--cache-root" { ai = ai + 1; cacheRoot = args[ai]; };
  ai = ai + 1;
};

let go = () -> {
// 缓存键:sha256(版本 + 编译器 + runtime.ql + bundle.ql)
let runtimePath = "aot/runtime.ql";
let bundlePath = "stdlib/bundle.ql";
// 和 Python 版完全同源:sha256(版本字节 + 编译器字节 + runtime 字节 + bundle 字节),取前 16。
std.process.run(["mkdir", "-p", cacheRoot]);
let keyTemp = cacheRoot + "/.key";
let digestResult = std.process.run(["sh", "-c",
  "printf '%s' " + splitVersion + " > " + keyTemp + "; cat " + compiler + " " + runtimePath + " " + bundlePath + " >> " + keyTemp + "; sha256sum " + keyTemp]);
if digestResult.status != 0 { fail("sha256sum failed:\n" + digestResult.stderr); };
let digest = std.Bytes.slice(digestResult.stdout, 0, 16);
std.fs.remove(keyTemp);
let outDir = cacheRoot + "/" + digest;

let objectPath = outDir + "/stdlib.o";
let existing = std.Bytes.read(objectPath);
// 缓存命中要求 mod.ql 也在:接口是产物的一部分,缺了就得重建(否则 split 路径读不到白名单)。
let cachedMod = std.Bytes.read(outDir + "/mod.ql");
let modReady = !isError(cachedMod) && std.Bytes.length(cachedMod) > 64;
if !isError(existing) && std.Bytes.length(existing) > 1024 && modReady {
  // 缓存命中也要保证 bitcode 在(--lto 链接要用);缺了就补一份。
  let bcPath = outDir + "/stdlib.bc";
  let bc = std.Bytes.read(bcPath);
  if isError(bc) || std.Bytes.length(bc) < 1024 {
    let made = std.process.run(["clang", "-O1", "-emit-llvm", "-c", outDir + "/stdlib.ll", "-o", bcPath]);
    if made.status != 0 { fail("bitcode failed:\n" + made.stderr); };
  };
  println(objectPath);
  return 0;
};

// 1) 空程序的全量 IR
let emptyPath = outDir + "/empty.ql";
let fullPath = outDir + "/full.ll";
let stdlibPath = outDir + "/stdlib.ll";
std.process.run(["mkdir", "-p", outDir]);
std.fs.writeText(emptyPath, "");
// 顺便导出「模块 -> 成员 -> 符号/元数」表(内联 lambda 的符号只在发射时存在)。
let membersPath = outDir + "/members.txt";
let emitted = std.process.run([compiler, "--emit-llvm", "--members-out", membersPath, emptyPath, runtimePath]);
if emitted.status != 0 { fail("emit failed:\n" + emitted.stderr); };
let wrote = std.fs.writeText(fullPath, emitted.stdout);
if isError(wrote) { fail("cannot write " + fullPath); };

let parsed = parseModule(emitted.stdout);

// 2) 函数:剥掉 main;value-ABI 叶子保持 internal,其余 hidden
let functions = []; let named = [];
let fi = 0;
while fi < parsed.functions.length {
  let entry = parsed.functions[fi];
  if entry.name != "main" {
    let body = entry.body;
    // 只把 `define internal` 改成 `define hidden`(跨模块可见);
    // 编译器自己发的冷助手(@__panic_exit/@__cold_located_error/@__stdlib_init)
    // 没有 internal,保持默认可见性 —— 改成 hidden 会让用户模块的引用链接不上。
    if !isPinned(body) && startsWith(body, "define internal ") {
      body = "define hidden " + dropPrefix(body, "define internal ");
    };
    functions[functions.length] = { name: entry.name, body: body };
  };
  fi = fi + 1;
};

// 3) 全局:ABI 描述符由用户模块定义,对象里只声明
let globals = []; let abiDecl = "";
let gi = 0;
while gi < parsed.globals.length {
  let entry = parsed.globals[gi];
  if entry.name == "qlang_extension_abi_v1" { abiDecl = externalFor(entry.text); }
  else { globals[globals.length] = entry.text; };
  gi = gi + 1;
};

// 4) 符号表(编译器按名字直调库函数时要用)
let scanSymbols = (line) -> {
  let marker = "; ql-symbol ";
  let at = findFrom(line, marker, 0);
  if at < 0 { return null; };
  let rest = std.Bytes.slice(line, at + marker.length, line.length - at - marker.length);
  let parts = std.String.split(rest)(" ");
  // 同一个名字可能被多处 ; ql-symbol 提到,按名字去重(Python 版用的是 dict)。
  // 同一个名字可能被多处提到:以**最后**一次为准(Python 版是 dict 覆盖)。
  let entry = null;
  if parts.length >= 3 { entry = { name: parts[0], symbol: parts[1], fast: parts[2] }; }
  else if parts.length == 2 { entry = { name: parts[0], symbol: parts[1], fast: "-1" }; };
  if entry != null {
    let replaced = false; let ni = 0;
    while ni < named.length {
      if named[ni].name == entry.name { named[ni] = entry; replaced = true; ni = named.length; } else { ni = ni + 1; };
    };
    if !replaced { named[named.length] = entry; };
  };
  null;
};
let pi = 0;
while pi < parsed.preamble.length { scanSymbols(parsed.preamble[pi]); pi = pi + 1; };
let fbi = 0;
while fbi < parsed.functions.length {
  if parsed.functions[fbi].name == "main" { fbi = fbi + 1; } else {
  let lines = std.String.split(parsed.functions[fbi].body)("\n");
  let li = 0; while li < lines.length { scanSymbols(lines[li]); li = li + 1; };
  fbi = fbi + 1;
  };
};

// 5) 拼 stdlib.ll
let stdlibText = std.String.join(parsed.preamble)("\n");
if !endsWith(stdlibText, "\n") { stdlibText = stdlibText + "\n"; };
if abiDecl != "" { stdlibText = stdlibText + abiDecl + "\n"; };
let bodyChunks = [];
let fci = 0;
while fci < functions.length { bodyChunks[bodyChunks.length] = functions[fci].body; fci = fci + 1; };
let gci = 0;
while gci < globals.length { bodyChunks[bodyChunks.length] = globals[gci]; gci = gci + 1; };
stdlibText = stdlibText + std.String.join(bodyChunks)("\n") + "\n";
std.fs.writeText(stdlibPath, stdlibText);

// 6) symbols.tsv / strings.tsv
let symbolLines = [];
let si = 0;
while si < named.length { symbolLines[symbolLines.length] = named[si].name; si = si + 1; };
// 字节序比较:和 Python 的 sorted() 一致(QLang 的字符串 `<` 不是我们想要的顺序)。
let lessBytes = (a, b) -> {
  let n = if a.length < b.length { a.length; } else { b.length; };
  let i = 0; let verdict = -1;
  while i < n && verdict < 0 {
    let ca = std.Bytes.byteAt(a, i); let cb = std.Bytes.byteAt(b, i);
    if ca < cb { verdict = 1; } else if ca > cb { verdict = 0; } else { i = i + 1; };
  };
  if verdict >= 0 { return verdict == 1; };
  a.length < b.length;
};
// 选择排序(qlang 没有 std.Array.sort;直接用它会拿到 Error 并死循环)。
let sortedNames = [];
let remainingNames = symbolLines;
while remainingNames.length > 0 {
  let best = 0; let bi2 = 1;
  while bi2 < remainingNames.length {
    if lessBytes(remainingNames[bi2], remainingNames[best]) { best = bi2; };
    bi2 = bi2 + 1;
  };
  sortedNames[sortedNames.length] = remainingNames[best];
  let kept = []; let ki = 0;
  while ki < remainingNames.length { if ki != best { kept[kept.length] = remainingNames[ki]; }; ki = ki + 1; };
  remainingNames = kept;
};
symbolLines = sortedNames;
let sorted = [];
let xi = 0;
while xi < symbolLines.length {
  let name = symbolLines[xi]; let yi = 0;
  while yi < named.length {
    if named[yi].name == name { sorted[sorted.length] = name + "\t" + named[yi].symbol + "\t" + named[yi].fast; yi = named.length; } else { yi = yi + 1; };
  };
  xi = xi + 1;
};
std.fs.writeText(outDir + "/symbols.tsv", std.String.join(sorted)("\n") + "\n");

// symbols.json:给 Python 侧的 split_file 回落路径用(declare/external 文本)。
let jsonLines = ["{"];
let fnNames = [];
let fi2 = 0;
while fi2 < functions.length { if !isPinned(functions[fi2].body) { fnNames[fnNames.length] = functions[fi2].name; }; fi2 = fi2 + 1; };
// 名字排序(字节序),和 Python 的 sort_keys 对齐
let sortedFns = [];
let remainingFns = fnNames;
while remainingFns.length > 0 {
  let bestIndex = 0; let bi3 = 1;
  while bi3 < remainingFns.length { if lessBytes(remainingFns[bi3], remainingFns[bestIndex]) { bestIndex = bi3; }; bi3 = bi3 + 1; };
  sortedFns[sortedFns.length] = remainingFns[bestIndex];
  let keptFns = []; let ki2 = 0;
  while ki2 < remainingFns.length { if ki2 != bestIndex { keptFns[keptFns.length] = remainingFns[ki2]; }; ki2 = ki2 + 1; };
  remainingFns = keptFns;
};
let jsonChunks = ["{"];
jsonChunks[jsonChunks.length] = " \"functions\": {";
let jf = 0;
while jf < sortedFns.length {
  let name = sortedFns[jf]; let body = ""; let bi4 = 0;
  while bi4 < functions.length { if functions[bi4].name == name { body = functions[bi4].body; bi4 = functions.length; } else { bi4 = bi4 + 1; }; };
  let decl = declareFor(body);
  let comma = if jf + 1 < sortedFns.length { ","; } else { ""; };
  jsonChunks[jsonChunks.length] = "  \"" + name + "\": \"" + decl + "\"" + comma;
  jf = jf + 1;
};
jsonChunks[jsonChunks.length] = " },";
jsonChunks[jsonChunks.length] = " \"globals\": {";
let jg = 0;
while jg < globals.length {
  let line2 = globals[jg];
  let space = findFrom(line2, " ", 0);
  // JSON 的键**不带 @**(Python 的 GLOBAL 正则捕获不含 @),split_file 按这个键查找。
  let name = dropPrefix(std.Bytes.slice(line2, 0, space), "@");
  let decl2 = externalFor(line2);
  let comma2 = if jg + 1 < globals.length { ","; } else { ""; };
  jsonChunks[jsonChunks.length] = "  \"" + name + "\": \"" + decl2 + "\"" + comma2;
  jg = jg + 1;
};
jsonChunks[jsonChunks.length] = " }";
jsonChunks[jsonChunks.length] = "}";
std.fs.writeText(outDir + "/symbols.json", std.String.join(jsonChunks)("\n") + "\n");

let stringLines = [];
let slines = std.String.split(stdlibText)("\n");
let buffers = {}; let li2 = 0;
while li2 < slines.length {
  let line = slines[li2];
  if startsWith(line, "@.str") && !startsWith(line, "@.strbox") {
    let at = findFrom(line, "c\"", 0);
    if at >= 0 {
      let stopAt = findFrom(line, "\"", at + 2);
      if stopAt > at {
        let region = std.Bytes.slice(line, at + 2, stopAt - at - 2);
        let idEnd = findFrom(line, " ", 0);
        buffers[std.Bytes.slice(line, 0, idEnd)] = std.String.replace(region)("\\")("");
      };
    };
  };
  li2 = li2 + 1;
};
let bj = 0;
while bj < slines.length {
  let line = slines[bj];
  if startsWith(line, "@.strbox") {
    let space = findFrom(line, " ", 0);
    let name = std.Bytes.slice(line, 0, space);
    let refAt = findFrom(line, "@.str", 7);
    if refAt >= 0 {
      let refEnd = findFrom(line, ",", refAt);
      let ref = std.Bytes.slice(line, refAt, refEnd - refAt);
      let payload = buffers[ref];
      if !isError(payload) && payload != null {
        stringLines[stringLines.length] = dropPrefix(name, "@") + "\t" + std.String.toLowerCase(payload);
      };
    };
  };
  bj = bj + 1;
};
std.fs.writeText(outDir + "/strings.tsv", std.String.join(stringLines)("\n") + "\n");

// 7) interface.txt(分析接口)+ 发射那一趟导出的成员符号(members.txt)
let iface = std.process.run([compiler, "--emit-stdlib-interface", runtimePath]);
if iface.status != 0 { fail("interface dump failed:\n" + iface.stderr); };
let membersText0 = std.fs.readFileText(membersPath);
if isError(membersText0) { membersText0 = ""; };
// 末尾记一条 MAX:库函数编号的最大值(**包括未导出的**)。用户模块必须从它之上开始编号,
// 否则用户函数会和库内部函数撞号 —— 合并/内联模块时就是「重复定义」。
let maxFn = 0;
let mfi = 0;
while mfi < parsed.functions.length {
  let fname = parsed.functions[mfi].name;
  if startsWith(fname, "ql_fn") {
    let digits = std.String.replace(fname)("ql_fn")("");
    let v = std.Number.parseFloat(digits);
    if !isError(v) && v > maxFn { maxFn = v; };
  };
  mfi = mfi + 1;
};
std.fs.writeText(outDir + "/interface.txt", iface.stdout + membersText0 + "MAX " + std.Number.toString(maxFn) + "\n");

// 7b) mod.ql:接口配置。它是 **QLang 对象字面量**(`let mod = {...};`),编译器用共享前端
// 把它当 QLang 值读 —— 不引入第二套 JSON 读取器,也不解析行式文本。
// 字段是 interface.txt 的无损映射,只写事实:
//   slots     绑定槽顺序                       (SLOT)
//   functions 直接调用目标:名字 -> 符号+元数    (DFN)
//   runtime   运行期函数名                     (RFN)
//   modules   模块 -> 成员 -> {symbol, arity [, bind]}  (MEM 的 bind 是源绑定名,SYM 没有)
//   mt        模块的静态类型                   (MT)
//   values    模块 -> 成员 -> 静态类型          (MV)
//   calls     模块 -> 成员 -> 返回类型          (MC)
//   maxFn     库函数最大编号(含未导出的)      (MAX)
let symOf = (name) -> {
  let k = 0;
  while k < named.length { if named[k].name == name { return named[k].symbol; }; k = k + 1; };
  "";
};
let fastOf = (name) -> {
  let k = 0;
  while k < named.length { if named[k].name == name { return named[k].fast; }; k = k + 1; };
  "-1";
};
let jq = (v) -> {
  let escaped = std.String.replace(v)("\\")("\\\\");
  escaped = std.String.replace(escaped)("\"")("\\\"");
  "\"" + escaped + "\"";
};
let joinArr = (items) -> {
  let out = "";
  let k = 0;
  while k < items.length { if k > 0 { out = out + ","; }; out = out + items[k]; k = k + 1; };
  out;
};
let sep = "\u0001";
let iLines = std.String.split(iface.stdout + membersText0)("\n");
let slotItems = []; let fnItems = []; let mtItems = []; let memItems = []; let rfnItems = [];
let mvMods = []; let mvFrag = {}; let mcMods = []; let mcFrag = {};
let dfnArity = {};
let li2 = 0;
while li2 < iLines.length {
  let row = iLines[li2];
  if row != "" {
    let cells = std.String.split(row)(" ");
    if cells[0] == "SLOT" { slotItems[slotItems.length] = jq(cells[1]); }
    else if cells[0] == "DFN" { dfnArity[cells[1]] = cells[2]; }
    else if cells[0] == "RFN" { rfnItems[rfnItems.length] = jq(cells[1]); }
    else if cells[0] == "MT" { mtItems[mtItems.length] = jq(cells[1]) + ":" + jq(cells[2]); }
    else if cells[0] == "MV" {
      let mvm = cells[1];
      if isError(mvFrag[mvm]) { mvFrag[mvm] = []; mvMods[mvMods.length] = mvm; };
      let frag = mvFrag[mvm];
      frag[frag.length] = jq(cells[2]) + ":" + jq(cells[3]);
    }
    else if cells[0] == "MC" {
      let mcm = cells[1];
      if isError(mcFrag[mcm]) { mcFrag[mcm] = []; mcMods[mcMods.length] = mcm; };
      let frag = mcFrag[mcm];
      frag[frag.length] = jq(cells[2]) + ":" + jq(cells[3]);
    }
    else if cells[0] == "MEM" {
      // 成员的身份是源绑定名;符号必须能在符号表里查到 —— 否则生成的直调会指向没声明的
      // 符号(上一次 selfhost 的 numeric.ll 就是这么红的)。
      let memSym = symOf(cells[3]);
      if memSym == "" { fail("mod.ql: binding " + cells[3] + " (" + cells[1] + "." + cells[2] + ") is not a symbol"); };
      // 元数取 MEM 行带过来的**源绑定参数个数**(不是 fast 寄存器元数):直调用它判。
      let memArity = if cells.length > 4 { cells[4]; } else { fastOf(cells[3]); };
      memItems[memItems.length] = jq(cells[1]) + sep + jq(cells[2]) + sep + jq(memSym) + sep + memArity + sep + jq(cells[3]);
    }
    else if cells[0] == "SYM" {
      memItems[memItems.length] = jq(cells[1]) + sep + jq(cells[2]) + sep + jq(cells[3]) + sep + cells[4] + sep + "-";
    };
  };
  li2 = li2 + 1;
};
// modules:按模块分组
let modNames = []; let mi4 = 0;
while mi4 < memItems.length {
  let parts = std.String.split(memItems[mi4])("\u0001");
  let seen = 0; let k4 = 0;
  while k4 < modNames.length { if modNames[k4] == parts[0] { seen = 1; }; k4 = k4 + 1; };
  if seen == 0 { modNames[modNames.length] = parts[0]; };
  mi4 = mi4 + 1;
};
let modItems = []; let mi5 = 0;
while mi5 < modNames.length {
  let memberItems = []; let mj5 = 0;
  while mj5 < memItems.length {
    let parts5 = std.String.split(memItems[mj5])(sep);
    if parts5[0] == modNames[mi5] {
      let entry5 = parts5[1] + ":{\"symbol\":" + parts5[2] + ",\"arity\":" + parts5[3];
      if parts5.length > 4 && parts5[4] != "-" { entry5 = entry5 + ",\"bind\":" + parts5[4]; };
      memberItems[memberItems.length] = entry5 + "}";
    };
    mj5 = mj5 + 1;
  };
  modItems[modItems.length] = modNames[mi5] + ":{" + joinArr(memberItems) + "}";
  mi5 = mi5 + 1;
};
// functions 只放**直接调用目标**(DFN):顶层函数的符号与参数个数;模块成员的符号走 modules。
// 顺序按 symbols.tsv,保证产物可复现。
let ni = 0;
while ni < named.length {
  let nm = named[ni].name;
  let ar = dfnArity[nm];
  if !isError(ar) && ar != null {
    fnItems[fnItems.length] = jq(nm) + ":{\"symbol\":" + jq(named[ni].symbol) + ",\"arity\":" + ar + "}";
  };
  ni = ni + 1;
};
// 模块 -> 成员 -> 类型名 这类嵌套表按模块分组拼(顺序 = 出现顺序,产物可复现)。
let groupTable = (modsIn, fragOf) -> {
  let items = []; let k = 0;
  while k < modsIn.length { items[items.length] = jq(modsIn[k]) + ":{" + joinArr(fragOf[modsIn[k]]) + "}"; k = k + 1; };
  joinArr(items);
};
let modText3 = "let mod = {\"version\":1,\"slots\":[" + joinArr(slotItems) + "],\"functions\":{" + joinArr(fnItems) + "},\"runtime\":[" + joinArr(rfnItems) + "],\"modules\":{" + joinArr(modItems) + "},\"mt\":{" + joinArr(mtItems) + "},\"values\":{" + groupTable(mvMods, mvFrag) + "},\"calls\":{" + groupTable(mcMods, mcFrag) + "},\"maxFn\":" + std.Number.toString(maxFn) + "};\n";
std.fs.writeText(outDir + "/mod.ql", modText3);
// 完整性:三张表都不能空。符号表里还有一批「库内部函数」的符号(function 与 member 都
// 不直接引用),它们在 split 模式里只是被声明,不需要归属。
if fnItems.length == 0 { fail("mod.ql: empty functions"); };
if slotItems.length == 0 { fail("mod.ql: empty slots"); };
if modItems.length == 0 { fail("mod.ql: empty modules"); };
if rfnItems.length == 0 { fail("mod.ql: empty runtime"); };

// 8) 目标文件
let compiled = std.process.run(["llc", "-O2", "-filetype=obj", stdlibPath, "-o", objectPath]);
if compiled.status != 0 { fail("llc failed:\n" + compiled.stderr); };
// 同一份 IR 再产一份 bitcode:发布构建用 --lto 做跨模块内联(库仍然只编一次)。
let bitcodeMade = std.process.run(["clang", "-O1", "-emit-llvm", "-c", stdlibPath, "-o", outDir + "/stdlib.bc"]);
if bitcodeMade.status != 0 { fail("bitcode failed:\n" + bitcodeMade.stderr); };
std.fs.remove(emptyPath);
println(objectPath);
};

go();
