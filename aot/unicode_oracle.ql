// Unicode 参照实现(全平面):独立比对简单/完整大小写映射、字符串级 casing 与 trim。
//   unicode_oracle [<dataset-dir>]                     正常比对,末尾打印 `N 处不一致`
//   unicode_oracle --emit-interpreter-fixture          只输出解释器夹具源码(期望值来自本文件)
// 数据来自 `third_party/ucd/15.1.0/`,全部由 UCD 15.1.0 原文用 awk 派生(见该目录 README):
//   case-full.txt        UnicodeData.txt 里所有有简单大写/小写映射的码点(格式 `码点;大写;小写`)
//   case-special.txt     SpecialCasing.txt 里无条件的完整映射行(格式 `码点;大写;小写`)
//   cased.txt            DerivedCoreProperties.txt 的 Cased 区间
//   case-ignorable.txt   DerivedCoreProperties.txt 的 Case_Ignorable 区间
//   whitespace.txt       PropList.txt 的 White_Space 码点
// **不读 stdlib/unicode_data.ql**:那正是被测物。这里的期望值全部由 UCD 派生数据独立算出。
let dir = "third_party/ucd/15.1.0";
let emitFixture = false;
if args.length > 0 {
  if args[0] == "--emit-interpreter-fixture" { emitFixture = true; }
  else { dir = args[0]; };
};
let num = (n) -> std.Number.toString(n);
let bad = 0; let firstBad = "";
let mismatch = (label) -> {
  bad = bad + 1;
  if firstBad == "" { firstBad = label; };
  null;
};
let readData = (path) -> {
  let text = std.fs.readFileText(path);
  if isError(text) {
    // Missing dataset used to leave counters at 0 and still report success.
    mismatch("缺少 " + path);
    return "";
  };
  text;
};
let digits = "0123456789ABCDEF";
let dv = (c) -> {
  let k = 0; let r = -1;
  while k < 16 { if std.String.at(digits, k) == c { r = k; }; k = k + 1; };
  r;
};
let hex = (s) -> {
  let v = 0; let i = 0;
  while i < s.length { v = v * 16 + dv(std.String.at(s, i)); i = i + 1; };
  v;
};
// `std.String.split` 在解释器里对每个字符调用一次 matches;解析几十 KB 数据会慢到
// 不可用。这里只按单个字符切分,内层不调用函数(数据文件只用到 "\n" ";" " " ".")。
let splitFast = (s, sep) -> {
  let parts = []; let part = ""; let i = 0;
  while i < s.length {
    if s[i] == sep { parts[parts.length] = part; part = ""; }
    else { part = part + s[i]; };
    i = i + 1;
  };
  parts[parts.length] = part;
  parts;
};
let decodeSeq = (text) -> {
  let parts = splitFast(text, " ");
  let out = ""; let k = 0;
  while k < parts.length {
    if parts[k] != "" { out = out + std.String.fromCodePoint(hex(parts[k])); };
    k = k + 1;
  };
  out;
};
let parseRows = (text) -> {
  let rows = [];
  let lines = splitFast(text, "\n");
  let i = 0;
  while i < lines.length {
    let line = lines[i];
    if line != "" {
      let f = splitFast(line, ";");
      if f.length >= 3 {
        rows[rows.length] = { cp: hex(f[0]), up: f[1], lo: f[2] };
      };
    };
    i = i + 1;
  };
  rows;
};
// Cased / Case_Ignorable:区间(格式 `XXXX` 或 `XXXX..YYYY`)按文件顺序保存。
// 展开成逐字符集合在解释器里太慢(7000+ fromCodePoint);这里用二分查找。
let loadRanges = (text) -> {
  let rows = []; let count = 0;
  let lines = splitFast(text, "\n");
  let i = 0;
  while i < lines.length {
    let line = lines[i];
    if line != "" {
      let ends = splitFast(line, ".");
      let lo = hex(ends[0]);
      let hi = if ends.length > 1 { hex(ends[ends.length - 1]); } else { lo; };
      rows[rows.length] = [lo, hi];
      count = count + (hi - lo + 1);
    };
    i = i + 1;
  };
  { rows: rows, count: count };
};
let inRanges = (rows, cp): Boolean -> {
  let lo = 0; let hi = rows.length - 1; let found = false;
  while lo <= hi {
    let mid = (lo + hi - (lo + hi) % 2) / 2;
    if cp < rows[mid][0] { hi = mid - 1; }
    else if cp > rows[mid][1] { lo = mid + 1; }
    else { found = true; lo = hi + 1; };
  };
  found;
};

let fullRows = parseRows(readData(dir + "/case-full.txt"));
let specialRows = parseRows(readData(dir + "/case-special.txt"));
let simpleUpper = {}; let simpleLower = {};
let fullUpper = {}; let fullLower = {}; let special = {};
// Merge the two code-point-sorted files: one changed scalar per union member.
// 2927 scalars = exactly the set with a nonidentity upper/lower mapping in 15.1.0.
let changed = [];
let fi = 0; let si = 0;
while fi < fullRows.length || si < specialRows.length {
  let fcp = if fi < fullRows.length { fullRows[fi].cp; } else { 1114112; };
  let scp = if si < specialRows.length { specialRows[si].cp; } else { 1114112; };
  let cp = if fcp < scp { fcp; } else { scp; };
  if fcp == cp {
    let r = fullRows[fi]; let ch = std.String.fromCodePoint(cp);
    if r.up != "" { simpleUpper[ch] = std.String.fromCodePoint(hex(r.up)); };
    if r.lo != "" { simpleLower[ch] = std.String.fromCodePoint(hex(r.lo)); };
    fi = fi + 1;
  };
  if scp == cp {
    let r = specialRows[si]; let ch = std.String.fromCodePoint(cp);
    special[ch] = true;
    if r.up != "" { fullUpper[ch] = decodeSeq(r.up); };
    if r.lo != "" { fullLower[ch] = decodeSeq(r.lo); };
    si = si + 1;
  };
  changed[changed.length] = cp;
};
let has = (table, c): Boolean -> !isError(table[c]);
let casedRanges = loadRanges(readData(dir + "/cased.txt"));
let ignorableRanges = loadRanges(readData(dir + "/case-ignorable.txt"));
let casedCount = casedRanges.count;
let ignorableCount = ignorableRanges.count;
let expectUpper = (s) -> {
  let out = ""; let i = 0;
  while i < s.length {
    let c = s[i];
    let mapped = fullUpper[c];
    if isError(mapped) { mapped = simpleUpper[c]; };
    if isError(mapped) { out = out + c; } else { out = out + mapped; };
    i = i + 1;
  };
  out;
};
// Final_Sigma 与 Python str.lower 一致:前一个有意义的字符是 Cased,且后面
// (跳过 Case_Ignorable)不再出现 Cased,则 03A3 映射为 03C2(ς),否则 03C3(σ)。
let expectLower = (s) -> {
  let out = ""; let i = 0; let previousCased = false; let length = s.length;
  while i < length {
    let c = s[i]; let mapped = "";
    if c == "\u03A3" {
      let next = i + 1;
      while next < length && inRanges(ignorableRanges.rows, std.String.codePointAt(s)(next)) { next = next + 1; };
      let followingCased = next < length && inRanges(casedRanges.rows, std.String.codePointAt(s)(next));
      mapped = if previousCased && !followingCased { "\u03C2"; } else { "\u03C3"; };
    } else {
      mapped = fullLower[c];
      if isError(mapped) { mapped = simpleLower[c]; };
      if isError(mapped) { mapped = c; };
    };
    out = out + mapped;
    let cp = std.String.codePointAt(s)(i);
    if !inRanges(ignorableRanges.rows, cp) { previousCased = inRanges(casedRanges.rows, cp); };
    i = i + 1;
  };
  out;
};

// 逐码点调用 toUpperCase/toLowerCase 在解释器里太慢;把期望值相同的映射
// 按 64 个标量一批比对,仍然覆盖每一个码点。仅 03A3 的大小写与上下文有关,
// 它不在无条件 SpecialCasing 里,单独验证(孤立 Σ ⇒ σ)。
let checkBatch = (label, text, want, n, up) -> {
  if n > 0 {
    let got = if up { std.String.toUpperCase(text); } else { std.String.toLowerCase(text); };
    if got != want { mismatch(label + " batch of " + num(n)); };
  };
  null;
};
// ---- 简单映射:所有平面,跳过有完整(String)映射的码点 ---------------------
let simpleUpperCount = 0; let simpleLowerCount = 0;
let suText = ""; let suWant = ""; let suN = 0;
let slText = ""; let slWant = ""; let slN = 0;
let i = 0;
while i < fullRows.length {
  let r = fullRows[i]; let ch = std.String.fromCodePoint(r.cp);
  if !has(special, ch) {
    if r.up != "" {
      suText = suText + ch;
      suWant = suWant + std.String.fromCodePoint(hex(r.up));
      suN = suN + 1; simpleUpperCount = simpleUpperCount + 1;
      if suN == 64 { checkBatch("simple upper", suText, suWant, suN, true); suText = ""; suWant = ""; suN = 0; };
    };
    if r.lo != "" {
      if ch == "\u03A3" {
        let got = std.String.toLowerCase(ch);
        simpleLowerCount = simpleLowerCount + 1;
        if got != "\u03C3" { mismatch("simple lower U+03A3 got [" + got + "]"); };
      } else {
        slText = slText + ch;
        slWant = slWant + std.String.fromCodePoint(hex(r.lo));
        slN = slN + 1; simpleLowerCount = simpleLowerCount + 1;
        if slN == 64 { checkBatch("simple lower", slText, slWant, slN, false); slText = ""; slWant = ""; slN = 0; };
      };
    };
  };
  i = i + 1;
};
checkBatch("simple upper", suText, suWant, suN, true);
checkBatch("simple lower", slText, slWant, slN, false);
// ---- 完整映射:SpecialCasing 的无条件行(ß→SS、İ→i+组合点 等) -----------
let specialUpperCount = 0; let specialLowerCount = 0;
let fuText = ""; let fuWant = ""; let fuN = 0;
let flText = ""; let flWant = ""; let flN = 0;
i = 0;
while i < specialRows.length {
  let r = specialRows[i]; let ch = std.String.fromCodePoint(r.cp);
  if r.up != "" {
    fuText = fuText + ch; fuWant = fuWant + decodeSeq(r.up);
    fuN = fuN + 1; specialUpperCount = specialUpperCount + 1;
  };
  if r.lo != "" {
    flText = flText + ch; flWant = flWant + decodeSeq(r.lo);
    flN = flN + 1; specialLowerCount = specialLowerCount + 1;
  };
  i = i + 1;
};
checkBatch("full upper", fuText, fuWant, fuN, true);
checkBatch("full lower", flText, flWant, flN, false);
// ---- 字符串级 casing:46 组 × 64 个标量(与 Python 腿同一分批) ------------
let stringCases = [];
let chunkCount = 0;
i = 0;
while i < changed.length {
  let end = i + 64;
  if end > changed.length { end = changed.length; };
  let chunk = ""; let k = i;
  while k < end { chunk = chunk + std.String.fromCodePoint(changed[k]); k = k + 1; };
  stringCases[stringCases.length] = [chunk, expectUpper(chunk), expectLower(chunk), "chunk at " + num(i)];
  chunkCount = chunkCount + 1;
  i = end;
};
// ---- 120 条确定性伪随机串(与 Python 腿同字母表 / 同长度分布) -------------
// Python 用 random.Random(3015);输入不必逐字节相同,覆盖类别必须相同。
let alphabet = ["A", "\u03A3", "\u03C3", "\u0345", "\u0301", "'", ".", " ", "\u4E2D", "\u0130", "\u00DF", "\u200D"];
let rngState = 3015;
let nextRandom = () -> {
  rngState = (rngState * 48271) % 2147483647;
  rngState;
};
let randomCount = 0;
i = 0;
while i < 120 {
  let s = ""; let j = 0;
  while j < 12 { s = s + alphabet[nextRandom() % alphabet.length]; j = j + 1; };
  stringCases[stringCases.length] = [s, expectUpper(s), expectLower(s), "random #" + num(i)];
  randomCount = randomCount + 1;
  i = i + 1;
};
// ---- 6 条手写 Final_Sigma 序列 ---------------------------------------------
let sigmaInputs = ["A\u03A3\u0345", "\u0345\u03A3", "A'\u03A3'A", "\u0391\u03A3\u0301", "A\u03A3\u200D", "A\u03A3\u200DA"];
let sigmaCount = 0;
i = 0;
while i < sigmaInputs.length {
  let s = sigmaInputs[i];
  stringCases[stringCases.length] = [s, expectUpper(s), expectLower(s), "sigma #" + num(i)];
  sigmaCount = sigmaCount + 1;
  i = i + 1;
};
// ---- trim:25 个 White_Space 标量 × 3 + 中间不删 + 4 个边界串 -------------
let trimCases = [];
let addTrim = (text, want, label) -> {
  trimCases[trimCases.length] = [text, want];
  if !emitFixture { if std.String.trim(text) != want { mismatch(label); }; };
  null;
};
let wsText = readData(dir + "/whitespace.txt");
let wsCount = 0; let wsAll = "";
if wsText != "" {
  let lines = splitFast(wsText, "\n");
  i = 0;
  while i < lines.length {
    let h = lines[i];
    if h != "" {
      let ch = std.String.fromCodePoint(hex(h));
      // 只有首尾去掉。
      addTrim(ch, "", "trim U+" + h + " 未去掉");
      addTrim("a" + ch, "a", "trim 右侧 U+" + h);
      addTrim(ch + "a", "a", "trim 左侧 U+" + h);
      // 中间(两侧有字母)的空白**不该**被去掉。
      addTrim("a" + ch + "a", "a" + ch + "a", "trim 误删中间 U+" + h);
      // 两端各一个空白、中间是 "中 " 时,右侧空白会把空格也一起清掉 ⇒ 只剩 "中"。
      addTrim(ch + "\u4E2D " + ch, "\u4E2D", "trim 两端 U+" + h);
      wsAll = wsAll + ch;
      wsCount = wsCount + 1;
    };
    i = i + 1;
  };
  addTrim(wsAll, "", "trim 全空白串未清空");
  addTrim("\u200Bx\uFEFF", "\u200Bx\uFEFF", "trim 误删 ZWSP/BOM");
  addTrim("", "", "trim 空串");
  addTrim(" a \t b ", "a \t b", "trim 混合空白");
};
// ---- 正常模式:用运行时实现逐条比对收集到的字符串级用例 --------------------
if !emitFixture {
  i = 0;
  while i < stringCases.length {
    let c = stringCases[i];
    if std.String.toUpperCase(c[0]) != c[1] { mismatch(c[3] + " upper"); };
    if std.String.toLowerCase(c[0]) != c[2] { mismatch(c[3] + " lower"); };
    i = i + 1;
  };
};
// ---- 覆盖率下界:空数据/缺文件时 0 条比对也会得出"0 处不一致" --------------
if simpleUpperCount < 1423 { mismatch("simple upper 覆盖不足:" + num(simpleUpperCount)); };
if simpleLowerCount < 1405 { mismatch("simple lower 覆盖不足:" + num(simpleLowerCount)); };
if specialUpperCount < 103 { mismatch("full upper 覆盖不足:" + num(specialUpperCount)); };
if specialLowerCount < 103 { mismatch("full lower 覆盖不足:" + num(specialLowerCount)); };
if changed.length < 2927 { mismatch("changed 覆盖不足:" + num(changed.length)); };
if chunkCount < 46 { mismatch("chunk 覆盖不足:" + num(chunkCount)); };
if randomCount < 120 { mismatch("random 覆盖不足:" + num(randomCount)); };
if sigmaCount < 6 { mismatch("sigma 覆盖不足:" + num(sigmaCount)); };
if wsCount < 25 { mismatch("White_Space 覆盖不足:" + num(wsCount)); };
if casedCount < 4526 { mismatch("Cased 覆盖不足:" + num(casedCount)); };
if ignorableCount < 2707 { mismatch("Case_Ignorable 覆盖不足:" + num(ignorableCount)); };
// ---- 解释器夹具:把独立算出的输入/期望值生成成纯 QLang 源码 ----------------
// 解释器解析 50 KB UCD 派生表太慢(逐字符循环分钟级),所以由原生 oracle 生成
// 一个小夹具;解释器只需要执行 casing/trim,期望值仍来自 UCD 派生数据。
let hx = (n, width) -> {
  let out = ""; let k = 0;
  while k < width { let d = n % 16; out = digits[d] + out; n = (n - d) / 16; k = k + 1; };
  out;
};
let hxAny = (n) -> {
  let out = ""; let v = n;
  if v == 0 { return "0"; };
  while v > 0 { let d = v % 16; out = digits[d] + out; v = (v - d) / 16; };
  out;
};
let quote = (s) -> {
  let out = "\""; let k = 0;
  while k < s.length {
    let cp = std.String.codePointAt(s)(k);
    if cp <= 65535 { out = out + "\\u" + hx(cp, 4); }
    else { out = out + "\\u{" + hxAny(cp) + "}"; };
    k = k + 1;
  };
  out + "\"";
};
if emitFixture {
  print("let cases = [\n");
  i = 0;
  while i < stringCases.length {
    let c = stringCases[i];
    if i > 0 { print(",\n"); };
    print("[" + quote(c[0]) + "," + quote(c[1]) + "," + quote(c[2]) + "]");
    i = i + 1;
  };
  print("\n];\nlet trims = [\n");
  i = 0;
  while i < trimCases.length {
    let c = trimCases[i];
    if i > 0 { print(",\n"); };
    print("[" + quote(c[0]) + "," + quote(c[1]) + "]");
    i = i + 1;
  };
  print("\n];\nlet bad = 0;\nlet i = 0;\nwhile i < cases.length {\n  let c = cases[i];\n");
  print("  if std.String.toUpperCase(c[0]) != c[1] { bad = bad + 1; };\n");
  print("  if std.String.toLowerCase(c[0]) != c[2] { bad = bad + 1; };\n  i = i + 1;\n};\n");
  print("i = 0;\nwhile i < trims.length {\n  let c = trims[i];\n");
  print("  if std.String.trim(c[0]) != c[1] { bad = bad + 1; };\n  i = i + 1;\n};\n");
  print("println(\"interpreter fixture: \" + std.Number.toString(cases.length) + \" casing / \" + std.Number.toString(trims.length) + \" trim → \" + std.Number.toString(bad) + \" 处不一致\");\n");
  print("if bad > 0 { assert(false, \"fixture mismatch\"); 1; };\n0;\n");
  if bad > 0 { println("夹具生成时数据不一致:" + firstBad); assert(false, "unicode data mismatch"); 1; };
} else {
  println("Unicode 参照(UCD 15.1.0 全平面):upper " + num(simpleUpperCount) + " / lower " + num(simpleLowerCount) +
          " / full " + num(specialUpperCount + specialLowerCount) + " / changed " + num(changed.length) +
          " / chunks " + num(chunkCount) + " / random " + num(randomCount) + " / sigma " + num(sigmaCount) +
          " / White_Space " + num(wsCount) + " → " + num(bad) + " 处不一致");
  if bad > 0 { println("首个不一致:" + firstBad); assert(false, "unicode mismatch"); 1; };
};
0;
