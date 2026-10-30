// Unicode 参照实现(主流子集):比对简单大小写映射。
//   unicode_oracle [<dataset>]
// 数据是 `third_party/ucd/15.1.0/case-common.txt`:从 UCD 原文 `UnicodeData.txt` 用 awk 抽出
// U+0020..U+2FFF 里有大小写映射的行(格式 `码点;大写;小写`,空字段表示无映射)。
// 权威性追溯到 UCD 原文;运行时只解析这个几十 KB 的子集 —— 现读完整 1.9 MB 太慢(probes §118.1)。
// **不读 stdlib/unicode_data.ql**:那正是被测物。
let path = "third_party/ucd/15.1.0/case-common.txt";
if args.length > 0 { path = args[0]; };
// 注意:`std.String.codePointAt(s, i)` 在这条路径上返回 ?Error(签名/语义与预期不符),
// 所以按字符查表解析十六进制 —— 只用 `std.String.at`。
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
let dirOf = (p) -> {
  let parts = std.String.split(p)("/");
  let out = ""; let i = 0;
  while i < parts.length - 1 { out = if out == "" { parts[i]; } else { out + "/" + parts[i]; }; i = i + 1; };
  out;
};
let lines = std.String.split(std.fs.readFileText(path)?)("\n");
let up = 0; let lo = 0; let bad = 0; let firstBad = "";
let i = 0;
while i < lines.length {
  let line = lines[i];
  if line != "" {
    let f = std.String.split(line)(";");
    if f.length >= 3 {
      let cp = hex(f[0]);
      let ch = std.String.fromCodePoint(cp);
      if f[1] != "" {
        let want = std.String.fromCodePoint(hex(f[1]));
        let got = std.String.toUpperCase(ch);
        if got != want && bad < 5 { bad = bad + 1; if firstBad == "" { firstBad = "upper U+" + f[0] + " got [" + got + "] want [" + want + "]"; }; }
        else if got != want { bad = bad + 1; };
        up = up + 1;
      };
      if f[2] != "" {
        let want = std.String.fromCodePoint(hex(f[2]));
        let got = std.String.toLowerCase(ch);
        if got != want && firstBad == "" { firstBad = "lower U+" + f[0] + " got [" + got + "] want [" + want + "]"; };
        if got != want { bad = bad + 1; };
        lo = lo + 1;
      };
    };
  };
  i = i + 1;
};
// White_Space:每个成员都必须被 trim 去掉;夹在字母中间也要去掉;并留一个反向对照("a" 不被 trim)。
let wsPath = dirOf(path) + "/whitespace.txt";
let wsText = std.fs.readFileText(wsPath);
let ws = 0;
if !isError(wsText) {
  let wl = std.String.split(wsText)("\n");
  let wi = 0;
  while wi < wl.length {
    let h = std.String.trim(wl[wi]);
    if h != "" {
      let ch = std.String.fromCodePoint(hex(h));
      if std.String.trim(ch) != "" {
        bad = bad + 1;
        if firstBad == "" { firstBad = "trim U+" + h + " 未去掉"; };
      };
      // 中间(两侧有字母)的空白**不该**被去掉;只有首尾才去。
      if std.String.trim("a" + ch + "a") != "a" + ch + "a" {
        bad = bad + 1;
        if firstBad == "" { firstBad = "trim 误删中间 U+" + h; };
      };
      if std.String.trim(ch + "a") != "a" || std.String.trim("a" + ch) != "a" {
        bad = bad + 1;
        if firstBad == "" { firstBad = "trim 首尾 U+" + h; };
      };
      ws = ws + 1;
    };
    wi = wi + 1;
  };
  if std.String.trim("a") != "a" { bad = bad + 1; if firstBad == "" { firstBad = "trim 误删字母"; }; };
};
println("Unicode 参照(主流子集,U+0020..U+2FFF):upper " + std.Number.toString(up) + " / lower " + std.Number.toString(lo) + " / White_Space " + std.Number.toString(ws) + " → " + std.Number.toString(bad) + " 处不一致");
if bad > 0 { println("首个不一致:" + firstBad); assert(false, "unicode mismatch"); 1; };
0;
