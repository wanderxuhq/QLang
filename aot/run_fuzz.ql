// QLang fuzz-expression driver — the frozen fuzzexpr corpus, no Python.
//
//   run_fuzz <stdlib-dir> [--compiler <c>] [--interp <path>] [--jobs <n>] [--tmp <dir>]
//
// The corpus lives in aot/tests/data/fuzz_corpus.ql: 390 rows generated once by
// fuzzexpr.py (seed 1, 300 expression trees + 30 precedence chains x3) with the
// Python f64 oracle's expected values frozen. No Python runs at test time.
//
// Execution model:
//   - every case's source is written to <tmp>/<cid>.ql as an inspectable,
//     runnable program (disp + `v?` + println);
//   - value cases are pure expressions with no cross-case state, so they are
//     emitted/linked/run in chunks (default 64) under --opt 0 and --opt 2 and
//     through /tmp/interp. This is the same batching fuzzexpr.py itself uses
//     and avoids 384 interpreter startups (each costs ~14s here);
//   - a runtime-error case runs in its own process: exit 1 and the frozen kind
//     (DivisionByZero) must appear in the stderr cause chain on all three legs;
//   - a row with reject:"division by zero" is a case the frontend statically
//     rejects (literal zero divisor). Both the compiler and the interpreter
//     must fail with that diagnostic; it is counted, never silently dropped.
//
// Corpus-value deviations from fuzzexpr.fmt are explicit in the data file
// (only ge0275: -0 vs fmt's normalization to 0).
import ./tests/data/fuzz_corpus.ql;

let compiler = "target/selfhost/stage2.new";
let linkTool = "target/tools/link";
let runtime = "aot/runtime.ql";
let interp = "/tmp/interp";
let stdlibDir = "";
let base = "/tmp/qlang-fuzz-q";
let jobs = 3;
let chunkSize = 64;

let rest = [];
let ai = 0;
while ai < args.length {
  let a = args[ai];
  if a == "--compiler" { ai = ai + 1; compiler = args[ai]; }
  else if a == "--interp" { ai = ai + 1; interp = args[ai]; }
  else if a == "--jobs" { ai = ai + 1; jobs = std.Number.parseFloat(args[ai]); }
  else if a == "--tmp" { ai = ai + 1; base = args[ai]; }
  else if a == "--stdlib" { ai = ai + 1; stdlibDir = args[ai]; }
  else { rest[rest.length] = a; };
  ai = ai + 1;
};
if rest.length > 0 { stdlibDir = rest[0]; };
if stdlibDir == "" {
  assert(false, "usage: run_fuzz <stdlib-dir> [--compiler <c>] [--interp <path>] [--jobs <n>] [--tmp <dir>]");
  1;
};
if base == "" || base == "/" || base == "." { assert(false, "run_fuzz: refusing unsafe tmp dir"); 1; };
if !(jobs >= 1) { jobs = 1; };
if !(chunkSize >= 1) { chunkSize = 1; };

let symbols = stdlibDir + "/symbols.tsv";
let interfaceFile = stdlibDir + "/mod.ql";
let stdlibObject = stdlibDir + "/stdlib.o";

let num = (n) -> std.Number.toString(n);
let sq = (v) -> "'" + std.String.replace(v)("'")("'\\''") + "'";
let contains = (text, needle) -> std.String.includes(text)(needle);
let startsWith = (text, prefix) -> std.String.startsWith(text)(prefix);
let fail = (message) -> { assert(false, "run_fuzz: " + message); 1; };

let writeFile = (path, text) -> {
  let r = std.fs.writeText(path, text);
  if isError(r) { fail("cannot write " + path); };
  null;
};
let readFile = (path) -> {
  let r = std.fs.readFileText(path);
  if isError(r) { fail("cannot read " + path); };
  r;
};
let readOpt = (path) -> {
  let r = std.fs.readFileText(path);
  if isError(r) { ""; } else { r; };
};
let firstLine = (text) -> {
  let lines = std.String.split(text)("\n");
  if lines.length > 0 { lines[0]; } else { ""; };
};
let splitLines = (text) -> {
  let lines = std.String.split(text)("\n");
  if lines.length > 0 && lines[lines.length - 1] == "" { lines.remove(lines.length - 1); };
  lines;
};
let interpBody = (text) -> {
  let marker = "Interpreting...\n";
  if !contains(text, marker) { return ""; };
  let after = std.String.split(text)(marker);
  if after.length < 2 { return ""; };
  let body = std.String.split(after[1])("Execution complete.");
  if body.length < 1 { return ""; };
  body[0];
};

// Same display contract as fuzzexpr's fmt(): null, Number.toString, String,
// Boolean, "?Array". The wrapper propagates an error result at top level so
// error cases exit 1 with the diagnostic on stderr.
let dispText = "let disp = (v) -> {\n" +
  "  if v == null { \"null\"; }\n" +
  "  else if std.Type.of(v) == Number { std.Number.toString(v); }\n" +
  "  else if std.Type.of(v) == String { v; }\n" +
  "  else if std.Type.of(v) == Boolean { if v { \"true\"; } else { \"false\"; }; }\n" +
  "  else if std.Type.of(v) == AnyArray { \"?Array\"; }\n" +
  "  else { \"?Other\"; };\n" +
  "};\n";

let valueCases = [];
let errorCases = [];
let rejectCases = [];
let ci = 0;
while ci < cases.length {
  let c = cases[ci];
  if !isError(c.reject) { rejectCases[rejectCases.length] = c; }
  else if startsWith(c.expected, "ERR:") { errorCases[errorCases.length] = c; }
  else { valueCases[valueCases.length] = c; };
  ci = ci + 1;
};

// Guard the frozen shape: adding/removing rows or changing classification must
// be explicit, not a silent coverage change.
assert(cases.length == 390, "fuzz corpus changed: expected 390 rows, got " + num(cases.length));
assert(valueCases.length == 385, "fuzz corpus: expected 385 value rows, got " + num(valueCases.length));
assert(errorCases.length == 1, "fuzz corpus: expected 1 runtime-error row, got " + num(errorCases.length));
assert(rejectCases.length == 4, "fuzz corpus: expected 4 frontend-rejected rows, got " + num(rejectCases.length));

std.process.run(["rm", "-rf", base]);
std.process.run(["mkdir", "-p", base]);

let pass = 0; let failCount = 0; let failed = "";
let record = (ok, label) -> {
  if ok { pass = pass + 1; }
  else {
    failCount = failCount + 1;
    if failCount <= 24 { failed = failed + " " + label; };
  };
  null;
};

// 1) Per-case files: readable, directly runnable reproductions.
let caseText = (source) -> dispText + "let v = " + source + ";\nv?;\nprintln(disp(v));\n";
let wi = 0;
while wi < cases.length {
  let c = cases[wi];
  writeFile(base + "/" + c.cid + ".ql", caseText(c.source));
  wi = wi + 1;
};

// 2) Value chunks: one program per chunk, cid=value lines in corpus order.
let chunkProgram = (rows) -> {
  let parts = [dispText];
  let i = 0;
  while i < rows.length {
    let n = num(i);
    parts[parts.length] = "let v" + n + " = " + rows[i].source + ";";
    parts[parts.length] = "v" + n + "?;";
    parts[parts.length] = "println(\"" + rows[i].cid + "=\" + disp(v" + n + "));";
    i = i + 1;
  };
  std.String.join(parts)("\n") + "\n";
};

let chunks = [];
let start = 0;
while start < valueCases.length {
  let stop = start + chunkSize;
  if stop > valueCases.length { stop = valueCases.length; };
  let rows = [];
  let j = start;
  while j < stop { rows[rows.length] = valueCases[j]; j = j + 1; };
  chunks[chunks.length] = rows;
  start = stop;
};
let chunkIndex = 0;
while chunkIndex < chunks.length {
  writeFile(base + "/chunk_" + num(chunkIndex) + ".ql", chunkProgram(chunks[chunkIndex]));
  chunkIndex = chunkIndex + 1;
};

// Emit once; link the same IR at --opt 0 and --opt 2; run all three legs.
let runScript = (src, tag) -> {
  "set -e; " +
  sq(compiler) + " --emit-llvm-split " + sq(src) + " " + sq(runtime) + " " + sq(symbols) + " " + sq(interfaceFile) +
    " > " + sq(tag + ".ll") + " 2> " + sq(tag + ".emit.err") + "; " +
  sq(linkTool) + " " + sq(tag + ".ll") + " -o " + sq(tag + ".o0") + " --opt 0 --stdlib-object " + sq(stdlibObject) +
    " > " + sq(tag + ".link0.log") + " 2>&1; " +
  sq(linkTool) + " " + sq(tag + ".ll") + " -o " + sq(tag + ".o2") + " --opt 2 --stdlib-object " + sq(stdlibObject) +
    " > " + sq(tag + ".link2.log") + " 2>&1; " +
  "set +e; " +
  sq(tag + ".o0") + " > " + sq(tag + ".out0") + " 2> " + sq(tag + ".err0") + "; echo $? > " + sq(tag + ".st0") + "; " +
  sq(tag + ".o2") + " > " + sq(tag + ".out2") + " 2> " + sq(tag + ".err2") + "; echo $? > " + sq(tag + ".st2") + "; " +
  sq(interp) + " " + sq(src) + " > " + sq(tag + ".iout") + " 2> " + sq(tag + ".ierr") + "; echo $? > " + sq(tag + ".ist") + "; true";
};

let chunkTag = (idx) -> base + "/chunk_" + num(idx);
let evaluateChunk = (idx, result) -> {
  let rows = chunks[idx];
  let tag = chunkTag(idx);
  if result.status != 0 {
    let detail = firstLine(readOpt(tag + ".emit.err"));
    if detail == "" { detail = firstLine(readOpt(tag + ".link0.log")); };
    if detail == "" { detail = firstLine(readOpt(tag + ".link2.log")); };
    let i = 0;
    while i < rows.length { record(false, rows[i].cid); i = i + 1; };
    if failed.length < 2000 { failed = failed + " [chunk" + num(idx) + ":" + detail + "]"; };
    return null;
  };
  let st0 = readFile(tag + ".st0");
  let st2 = readFile(tag + ".st2");
  let ist = readFile(tag + ".ist");
  let err0 = readFile(tag + ".err0");
  let err2 = readFile(tag + ".err2");
  let ierr = readFile(tag + ".ierr");
  let out0 = splitLines(readFile(tag + ".out0"));
  let out2 = splitLines(readFile(tag + ".out2"));
  let ib = splitLines(interpBody(readFile(tag + ".iout")));
  let shapeOk = out0.length == rows.length && out2.length == rows.length && ib.length == rows.length;
  let legsOk = st0 == "0\n" && st2 == "0\n" && ist == "0\n" && err0 == "" && err2 == "" && ierr == "";
  let i = 0;
  while i < rows.length {
    let want = rows[i].cid + "=" + rows[i].expected;
    let ok = shapeOk && legsOk && out0[i] == want && out2[i] == want && ib[i] == want;
    record(ok, rows[i].cid);
    i = i + 1;
  };
  null;
};

let running = [];
let runningIndex = [];
let nextChunk = 0;
while nextChunk < chunks.length || running.length > 0 {
  while running.length < jobs && nextChunk < chunks.length {
    running[running.length] = std.process.spawn(["sh", "-c", runScript(base + "/chunk_" + num(nextChunk) + ".ql", chunkTag(nextChunk))]);
    runningIndex[runningIndex.length] = nextChunk;
    nextChunk = nextChunk + 1;
  };
  let handle = running[0];
  let idx = runningIndex[0];
  let result = std.process.wait(handle);
  let kept = []; let keptIndex = []; let k = 1;
  while k < running.length { kept[kept.length] = running[k]; keptIndex[keptIndex.length] = runningIndex[k]; k = k + 1; };
  running = kept; runningIndex = keptIndex;
  evaluateChunk(idx, result);
};

// 3) Runtime-error cases: one process per case, exit 1 + frozen stderr kind.
let runError = (c) -> {
  let src = base + "/" + c.cid + ".ql";
  let tag = base + "/" + c.cid;
  let result = std.process.run(["sh", "-c", runScript(src, tag)]);
  if result.status != 0 {
    record(false, c.cid);
    return null;
  };
  let kind = std.String.split(c.expected)("ERR:")[1];
  let out0 = readFile(tag + ".out0");
  let out2 = readFile(tag + ".out2");
  let body = interpBody(readFile(tag + ".iout"));
  let ok = readFile(tag + ".st0") == "1\n" && readFile(tag + ".st2") == "1\n" && readFile(tag + ".ist") == "1\n" &&
    out0 == "" && out2 == "" && body == "" &&
    contains(readFile(tag + ".err0"), kind) && contains(readFile(tag + ".err2"), kind) &&
    contains(readFile(tag + ".ierr"), kind);
  record(ok, c.cid);
  null;
};
let ei = 0;
while ei < errorCases.length { runError(errorCases[ei]); ei = ei + 1; };

// 4) Frontend-rejected cases: both frontends must reject with the frozen kind.
let runReject = (c) -> {
  let src = base + "/" + c.cid + ".ql";
  let tag = base + "/" + c.cid;
  let script = "set +e; " +
    sq(compiler) + " --emit-llvm-split " + sq(src) + " " + sq(runtime) + " " + sq(symbols) + " " + sq(interfaceFile) +
      " > " + sq(tag + ".rej.ll") + " 2> " + sq(tag + ".rej.emit.err") + "; echo $? > " + sq(tag + ".rej.emit.st") + "; " +
    sq(interp) + " " + sq(src) + " > " + sq(tag + ".rej.iout") + " 2> " + sq(tag + ".rej.ierr") + "; echo $? > " + sq(tag + ".rej.ist") + "; true";
  let result = std.process.run(["sh", "-c", script]);
  if result.status != 0 {
    record(false, c.cid);
    return null;
  };
  let emitStatus = readFile(tag + ".rej.emit.st");
  let interpStatus = readFile(tag + ".rej.ist");
  let ok = emitStatus != "0\n" && interpStatus != "0\n" &&
    contains(readFile(tag + ".rej.emit.err"), c.reject) &&
    contains(readFile(tag + ".rej.ierr"), c.reject);
  record(ok, c.cid);
  null;
};
let ri = 0;
while ri < rejectCases.length { runReject(rejectCases[ri]); ri = ri + 1; };

println("fuzz corpus: " + num(pass) + " pass / " + num(failCount) + " fail (" +
  num(cases.length) + " cases = " + num(valueCases.length) + " value + " +
  num(errorCases.length) + " runtime-error + " + num(rejectCases.length) + " frontend-rejected)");
if failed != "" { println("failed:" + failed); };
if failCount > 0 { assert(false, "fuzz failed"); 1; };
0;
