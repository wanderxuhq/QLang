// QLang bundle 测试驱动(不依赖 Python):移植 aot/run_bundle_tests.py。
//
//   run_bundle [--root <repo>] [--compiler <c>]
//
// 覆盖:空模块、CRLF/CR/LF 混排、Unicode 行分隔符、无末尾换行、JSON 字符串分块解码、
// Unicode-scalar 偏移、import/export 行改写、--check 通过、源变更后 BundleError,
// 以及仓库 stdlib/bundle.ql 的 --check 门。
let repoRoot = ".";
let compiler = "target/selfhost/stage2";
let linkTool = "target/tools/link";
let base = "/tmp/qlang-bundle-q";

let argIndex = 0;
while argIndex < args.length {
  if args[argIndex] == "--root" { argIndex = argIndex + 1; repoRoot = args[argIndex]; }
  else if args[argIndex] == "--compiler" { argIndex = argIndex + 1; compiler = args[argIndex]; }
  argIndex = argIndex + 1;
};
let canonical = std.fs.canonicalPath(repoRoot);
if !isError(canonical) { repoRoot = canonical; };

let pass = 0; let fail = 0; let failed = "";
let record = (ok, label) -> {
  if ok { pass = pass + 1; } else { fail = fail + 1; failed = failed + " " + label; };
  null;
};
let num = (n) -> std.Number.toString(n);
let contains = (text, needle) -> std.String.includes(text)(needle);
let startsWith = (text, prefix) -> std.String.startsWith(text)(prefix);
let endsWith = (text, suffix) -> std.String.endsWith(text)(suffix);
let replaceAll = (text, from, to) -> std.String.replace(text)(from)(to);
let slice = (s, start, end) -> {
  let out = ""; let k = start;
  while k < end { out = out + s[k]; k = k + 1; };
  out;
};
let find = (s, needle) -> {
  let k = 0; let size = s.length; let width = needle.length;
  while k + width <= size {
    if slice(s, k, k + width) == needle { return k; };
    k = k + 1;
  };
  -1;
};
let sq = (v) -> "'" + std.String.replace(v)("'")("'\\''") + "'";
let sh = (cmd) -> std.process.run(["sh", "-c", cmd]);
let writeFile = (path, text) -> {
  let r = std.fs.writeText(path, text);
  if isError(r) { assert(false, "cannot write " + path); 1; };
  null;
};

// ---- JSON 解码 ------------------------------------------------------------
// Stdlib 在 JSON 字符串字面量里把 "${" 写成 "\${" 以免被上游当成插值;
// 解码前按 Python 套件的方式逐字反转义回来。
let parseError = "";
let failParse = (message) -> {
  if parseError == "" { parseError = message; };
  null;
};
let jsonStringEnd = (s) -> {
  // s[0] 必须是开引号;返回闭引号之后的下标。
  let k = 1; let size = s.length;
  while k < size {
    let c = s[k];
    if c == "\\" { k = k + 2; }
    else if c == "\"" { return k + 1; }
    else { k = k + 1; };
  };
  -1;
};
let decodeChunks = (expression) -> {
  let escapedInterpolation = "\\" + "$" + "{";
  let plainInterpolation = "$" + "{";
  let rest = replaceAll(expression, escapedInterpolation, plainInterpolation);
  let out = "";
  while rest.length > 0 {
    if rest[0] != "\"" { failParse("chunk does not start with a JSON string literal"); return ""; };
    let stop = jsonStringEnd(rest);
    if stop < 0 { failParse("unterminated JSON string chunk"); return ""; };
    let value = std.JSON.parse(slice(rest, 0, stop));
    if isError(value) { failParse("cannot decode JSON string chunk"); return ""; };
    if !std.String.check(value) { failParse("chunk is not a JSON string"); return ""; };
    out = out + value;
    rest = slice(rest, stop, rest.length);
    if rest.length > 0 {
      if !startsWith(rest, " + ") { failParse("chunk separator is not ' + '"); return ""; };
      rest = slice(rest, 3, rest.length);
    };
  };
  out;
};
// origins 是 QLang 对象字面量:只给 build_bundle.ql 生成的五个键补引号。
let parseOrigins = (text) -> {
  let t = text;
  t = replaceAll(t, "{path: ", "{\"path\": ");
  t = replaceAll(t, ", startLine: ", ", \"startLine\": ");
  t = replaceAll(t, ", endLine: ", ", \"endLine\": ");
  t = replaceAll(t, ", sourceLineStarts: ", ", \"sourceLineStarts\": ");
  t = replaceAll(t, ", sourceLength: ", ", \"sourceLength\": ");
  let body = t;
  if !endsWith(body, "]") { body = t + "]"; };
  let parsed = std.JSON.parse(body);
  if isError(parsed) { failParse("cannot decode origins JSON"); return []; };
  parsed;
};

// ---- 源文本的物理行扫描(与 build_bundle.ql 同规则) ----------------------
let scanLines = (text) -> {
  let size = text.length; let starts = [0]; let lines = []; let endings = [];
  let cursor = 0; let lineText = "";
  while cursor < size {
    let c = text[cursor];
    if c == "\r" || c == "\n" {
      lines[lines.length] = lineText; lineText = "";
      let ending = c;
      if c == "\r" && cursor + 1 < size && text[cursor + 1] == "\n" { ending = "\r\n"; cursor = cursor + 1; };
      endings[endings.length] = ending;
      starts[starts.length] = cursor + 1;
    } else { lineText = lineText + c; };
    cursor = cursor + 1;
  };
  if starts[starts.length - 1] < size { lines[lines.length] = lineText; endings[endings.length] = "\n"; };
  { starts: starts, lines: lines, endings: endings };
};

// ---- 1. 构建 bundler(monolithic --emit-llvm + tools/link) -----------------
let compilerPath = repoRoot + "/" + compiler;
let linkPath = repoRoot + "/" + linkTool;
let bundlerPath = base + "/build_bundle";
let irPath = base + "/build_bundle.ll";
if !startsWith(base, "/tmp/qlang-bundle-") { assert(false, "unsafe temp base: " + base); 1; };
sh("rm -rf " + sq(base) + " && mkdir -p " + sq(base));
let emitted = sh(sq(compilerPath) + " --emit-llvm " +
                 sq(repoRoot + "/stdlib/build_bundle.ql") + " " + sq(repoRoot + "/aot/runtime.ql") +
                 " > " + sq(irPath));
record(emitted.status == 0, "bundler:emit");
let linked = std.process.run([linkPath, irPath, "-o", bundlerPath, "--root", repoRoot]);
record(linked.status == 0, "bundler:link");
if emitted.status != 0 || linked.status != 0 {
  println("QLang bundle 驱动: bundler 构建失败");
  assert(false, "bundler build failed");
  1;
};
// cwd 隔离:不传 cwd 参数,用 sh -c 'cd <dir> && exec <abs-bin>'。
let runIn = (dir, extra) -> sh("cd " + sq(dir) + " && exec " + sq(bundlerPath) + extra);

// ---- 2. 夹具目录 -----------------------------------------------------------
let work = base + "/work";
let modules = [
  { name: "empty.ql", text: "" },
  { name: "first.ql", text: "let first = \"中😀\";\r\nexport first;\r" },
  { name: "second.ql", text: "import ./first.ql;\r\nlet text = `x\${first}`;\rlet separator = \"\u2028\u2029\";\nexport text;" },
  { name: "trivia.ql", text: "\r\n\r\n" },
  { name: "last.ql", text: "let last = \"no final newline\";" }
];
let manifest = "{\"modules\": [\"empty.ql\", \"first.ql\", \"second.ql\", \"trivia.ql\", \"last.ql\"], " +
               "\"exports\": [{\"name\": \"First\", \"value\": \"first\"}]}";
sh("mkdir -p " + sq(work + "/stdlib"));
writeFile(work + "/stdlib/manifest.json", manifest);
let mi = 0;
while mi < modules.length {
  writeFile(work + "/stdlib/" + modules[mi].name, modules[mi].text);
  mi = mi + 1;
};

// ---- 3. 跑 bundler,校验信封并逐字节重建 ----------------------------------
let bundleRun = runIn(work, "");
record(bundleRun.status == 0, "bundle:status");
record(bundleRun.stderr == "", "bundle:stderr");
let stdout = bundleRun.stdout;
let header = "// Generated by stdlib/build_bundle.ql; do not edit.\nlet standardLibrarySource = ";
let middle = ";\nlet standardLibraryOrigins = ";
let footer = "];\nexport { standardLibrarySource, standardLibraryOrigins };\n";
let envelope = startsWith(stdout, header) && endsWith(stdout, footer);
record(envelope, "bundle:envelope");
let body = ""; let middleAt = -1;
if envelope {
  body = slice(stdout, header.length, stdout.length - footer.length);
  middleAt = find(body, middle);
};
record(middleAt >= 0, "bundle:origins-marker");
let decoded = ""; let origins = [];
if middleAt >= 0 {
  decoded = decodeChunks(slice(body, 0, middleAt));
  origins = parseOrigins(slice(body, middleAt + middle.length, body.length));
};
record(parseError == "", "bundle:decode");
let originCount = origins.length;
if isError(originCount) { originCount = -1; };
record(originCount == modules.length, "bundle:origin-count");
let sameOrigin = (o, path, startLine, endLine, starts, sourceLength) -> {
  let value = o.path;
  if isError(value) || value != path { return false; };
  value = o.startLine;
  if isError(value) || value != startLine { return false; };
  value = o.endLine;
  if isError(value) || value != endLine { return false; };
  value = o.sourceLength;
  if isError(value) || value != sourceLength { return false; };
  let list = o.sourceLineStarts;
  if isError(list) { return false; };
  let count = list.length;
  if isError(count) || count != starts.length { return false; };
  let k = 0;
  while k < count {
    if list[k] != starts[k] { return false; };
    k = k + 1;
  };
  true;
};
let expected = "let __build_standard_library = (std) -> {\n";
let nextLine = 2;
mi = 0;
while mi < modules.length {
  let mod = modules[mi];
  let scan = scanLines(mod.text);
  let originIndex = mi;
  if originIndex < originCount {
    record(sameOrigin(origins[originIndex], "stdlib/" + mod.name, nextLine,
                      nextLine + scan.lines.length - 1, scan.starts, mod.text.length),
           "bundle:origin:" + mod.name);
  } else {
    record(false, "bundle:origin:" + mod.name);
  };
  let li = 0;
  while li < scan.lines.length {
    let line = scan.lines[li]; let ending = scan.endings[li];
    if startsWith(line, "import ") { expected = expected + "// bundled import" + ending; }
    else if startsWith(line, "export ") { expected = expected + "// bundled export" + ending; }
    else { expected = expected + line + ending; };
    li = li + 1;
  };
  nextLine = nextLine + scan.lines.length;
  mi = mi + 1;
};
expected = expected + "{First: first};\n};\n";
record(decoded == expected, "bundle:source-exact");
if envelope { writeFile(work + "/stdlib/bundle.ql", stdout); };

// ---- 4. 生成的 bundle 通过 --check ---------------------------------------
let check = runIn(work, " --check");
record(check.status == 0, "check:status");
record(check.stdout == "Standard library source bundle verified\n", "check:stdout");
record(check.stderr == "", "check:stderr");

// ---- 5. 改 last.ql 之后 --check 必须报 BundleError ------------------------
writeFile(work + "/stdlib/last.ql", "let last = 1;");
let stale = runIn(work, " --check");
record(stale.status == 1, "stale:status");
record(stale.stdout == "", "stale:stdout-empty");
record(contains(stale.stderr, "BundleError"), "stale:BundleError");

// ---- 6. 仓库 stdlib/bundle.ql 的 --check 门(cwd 隔离) --------------------
let repoCheck = sh("cd " + sq(repoRoot) + " && exec " + sq(bundlerPath) + " --check");
record(repoCheck.status == 0, "repo:status");
record(repoCheck.stdout == "Standard library source bundle verified\n", "repo:stdout");
record(repoCheck.stderr == "", "repo:stderr");

println("QLang bundle 驱动: " + num(pass) + " 通过 / " + num(fail) + " 失败");
if failed != "" { println("失败:" + failed); };
if fail > 0 { assert(false, "bundle failed"); 1; };
0;
