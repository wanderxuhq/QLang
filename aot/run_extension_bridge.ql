// Native-core extension bridge driver (QLang port of run_extension_bridge_tests.py).
//   run_extension_bridge <work-dir> --root <repo> [--compiler <c>] [--interpreter <i>]
//
// work-dir must be a dlopen-visible directory (e.g. <repo>/target/ext-bridge-tmp);
// /tmp is rejected by the Android linker namespace.  The interpreter is copied
// into that tree before use because the linker grants a binary only the namespace
// of its own location: /tmp/interp cannot dlopen /root even though a host binary
// built there can.
let endsWith = (text, suffix) -> {
  if text.length < suffix.length { return false; }
  std.Bytes.slice(text, std.Bytes.length(text) - std.Bytes.length(suffix), std.Bytes.length(suffix)) == suffix;
};
let compiler = "target/selfhost/stage2";
let interpreter = "/tmp/interp";
let interp = "";
let root = "";
let workArg = "";
let rest = [];
let i = 0;
while i < args.length {
  let a = args[i];
  if a == "--compiler" { i = i + 1; compiler = args[i]; }
  else if a == "--interpreter" { i = i + 1; interpreter = args[i]; }
  else if a == "--root" { i = i + 1; root = args[i]; }
  else { rest[rest.length] = a; };
  i = i + 1;
};
if rest.length > 0 { workArg = rest[0]; };
if workArg == "" || root == "" {
  assert(false, "usage: run_extension_bridge <work-dir> --root <repo> [--compiler <c>] [--interpreter <i>]"); 1;
};
let sh = (cmd) -> std.process.run(["sh", "-c", cmd]);
let sq = (v) -> "'" + std.String.replace(v)("'")("'\\''") + "'";
let die = (what, detail) -> {
  println("FAIL: " + what + (if detail == "" { ""; } else { "\n" + detail; }));
  assert(false, what);
  1;
};
let runArgs = (argv, what) -> {
  let r = std.process.run(argv);
  if isError(r) { die("spawn " + what, r.message); };
  r;
};
let shRun = (cmd, what) -> {
  let r = std.process.run(["sh", "-c", cmd]);
  if isError(r) { die("spawn " + what, r.message); };
  r;
};
let readText = (path) -> {
  let text = std.fs.readFileText(path);
  if isError(text) { die("read " + path, text.message); };
  text;
};
let writeText = (path, text) -> {
  let e = std.fs.writeText(path, text);
  if isError(e) { die("write " + path, e.message); };
  null;
};
let rootCanon = std.fs.canonicalPath(root);
if isError(rootCanon) { die("repository root not found: " + root, rootCanon.message); };
root = rootCanon;
let compilerCanon = std.fs.canonicalPath(compiler);
if isError(compilerCanon) { die("compiler not found: " + compiler, compilerCanon.message); };
compiler = compilerCanon;
let interpCanon = std.fs.canonicalPath(interpreter);
if isError(interpCanon) { die("interpreter not found: " + interpreter, interpCanon.message); };
interpreter = interpCanon;
let mk = sh("mkdir -p " + sq(workArg));
if mk.status != 0 { die("create work dir " + workArg, mk.stderr); };
let workCanon = std.fs.canonicalPath(workArg);
if isError(workCanon) { die("canonicalize work dir " + workArg, workCanon.message); };
let work = workCanon;
if work == root || work == "/" { die("work dir must be a dedicated directory: " + work, ""); };
let runtime = root + "/aot/runtime.ql";
let linkTool = root + "/target/tools/link";
let verifyTool = root + "/target/tools/verify";
// Byte-level substring helpers.  QLang strings are byte strings for std.Bytes,
// but `.length` counts scalars, so all offsets here use std.Bytes.length.
let findFrom = (text, needle, from) -> {
  let size = std.Bytes.length(text); let width = std.Bytes.length(needle);
  let i = from;
  while i + width <= size {
    if std.Bytes.slice(text, i, width) == needle { return i; };
    i = i + 1;
  };
  -1;
};
let clamp = (text, limit) -> {
  let size = std.Bytes.length(text);
  if size <= limit { text; } else { std.Bytes.slice(text, 0, limit) + "...<truncated>"; };
};
let quoted = (argv) -> {
  let out = ""; let i = 0;
  while i < argv.length {
    if i > 0 { out = out + " "; };
    out = out + sq(argv[i]);
    i = i + 1;
  };
  out;
};
let checks = 0;
let failures = 0;
let check = (ok, label) -> {
  checks = checks + 1;
  if ok { null; } else { failures = failures + 1; println("FAIL " + label); };
  ok;
};
let checkResult = (label, r, wantStatus, wantOut, wantErrEmpty) -> {
  let ok = r.status == wantStatus;
  if ok { ok = r.stdout == wantOut; };
  if ok && wantErrEmpty { ok = r.stderr == ""; };
  if !ok {
    println("  status=" + std.Number.toString(r.status));
    println("  stdout=[" + clamp(r.stdout, 240) + "]");
    println("  stderr=[" + clamp(r.stderr, 240) + "]");
  };
  check(ok, label);
  ok;
};
let sameStrings = (a, b) -> {
  if a.length != b.length { return false; };
  let i = 0;
  while i < a.length {
    if a[i] != b[i] { return false; };
    i = i + 1;
  };
  true;
};
let showStrings = (a) -> {
  let out = "["; let i = 0;
  while i < a.length {
    if i > 0 { out = out + ", "; };
    out = out + a[i];
    i = i + 1;
  };
  out + "]";
};
// Interpreter stdout is "Interpreting...\n" + program body + "Execution complete.\n".
// On an unhandled error the CLI appends its Error.toString summary after the
// completion marker; that summary is not part of the program body.
let interpreterBody = (r) -> {
  let start = "Interpreting...\n";
  let done = "Execution complete.\n";
  let startAt = findFrom(r.stdout, start, 0);
  if startAt < 0 { return null; };
  let size = std.Bytes.length(r.stdout);
  let body = std.Bytes.slice(r.stdout, startAt + std.Bytes.length(start), size - startAt - std.Bytes.length(start));
  if r.status == 0 {
    if !endsWith(body, done) { return null; };
    return std.Bytes.slice(body, 0, std.Bytes.length(body) - std.Bytes.length(done));
  };
  let doneAt = findFrom(body, done, 0);
  if doneAt >= 0 {
    let summary = std.Bytes.slice(body, doneAt + std.Bytes.length(done), std.Bytes.length(body) - doneAt - std.Bytes.length(done));
    if std.String.trim(summary) == "" { return null; };
    return std.Bytes.slice(body, 0, doneAt);
  };
  body;
};
// Interpreter legs compare the program body between the two markers, never the
// CLI banner, and require an empty stderr (no linker namespace warnings).
let checkInterp = (label, r, wantStatus, wantOut) -> {
  let body = interpreterBody(r);
  let ok = r.status == wantStatus;
  if ok && body == null { ok = false; };
  if ok { ok = body == wantOut; };
  if ok { ok = r.stderr == ""; };
  if !ok {
    println("  status=" + std.Number.toString(r.status));
    println("  body=[" + (if body == null { "<no Interpreting/Execution marker>"; } else { clamp(body, 240); }) + "]");
    println("  stderr=[" + clamp(r.stderr, 240) + "]");
  };
  check(ok, label);
  ok;
};
let atFrames = (text) -> {
  let lines = std.String.split(text)("\n");
  let out = [];
  let i = 0;
  while i < lines.length {
    let line = lines[i];
    if std.String.startsWith(line)("  at ") {
      out[out.length] = std.Bytes.slice(line, 5, std.Bytes.length(line) - 5);
    };
    i = i + 1;
  };
  out;
};
let emit = (src, mode, out) -> {
  let r = runArgs([compiler, mode, src, runtime], "emit " + src);
  if r.status != 0 { die("emit " + src, r.stderr); };
  writeText(out, r.stdout);
};
let linkTo = (ir, out, opt, shared) -> {
  let argv = [linkTool, ir, "-o", out, "--opt", opt, "--root", root];
  if shared { argv[argv.length] = "--shared"; };
  let r = runArgs(argv, "link " + out);
  if r.status != 0 { die("link " + out, r.stderr); };
};
let verifyElf = (elf, ir, what) -> {
  let r = runArgs([verifyTool, elf, "-", ir], "verify " + what);
  if r.status != 0 { die("verify " + what, r.stderr); };
};
let runHost = (exe, extra) -> {
  let argv = [exe];
  let i = 0;
  while i < extra.length { argv[argv.length] = extra[i]; i = i + 1; };
  shRun("cd /tmp && exec " + quoted(argv), exe);
};
let runInterp = (script, extra) -> {
  let argv = [interp, script];
  let i = 0;
  while i < extra.length { argv[argv.length] = extra[i]; i = i + 1; };
  shRun("cd /tmp && exec " + quoted(argv), script);
};
// 1) t37 baseline: hosts linked before any extension exists, then four DSOs.
let base = work + "/baseline";
let bsrc = base + "/source";
let src = work + "/source";
let prep = sh("rm -rf " + sq(work) + " && mkdir -p " + sq(bsrc) + " " + sq(src) +
              " && cp " + sq(root + "/aot/tests/extensions") + "/*.ql " + sq(bsrc + "/") +
              " && cp " + sq(root + "/aot/tests/t37_extensions.ql") + " " + sq(bsrc + "/host.ql"));
if prep.status != 0 { die("prepare work dir", prep.stderr); };
let cpInterp = sh("cp " + sq(interpreter) + " " + sq(work + "/interp") + " && chmod +x " + sq(work + "/interp"));
if cpInterp.status != 0 { die("copy interpreter", cpInterp.stderr); };
interp = work + "/interp";
emit(bsrc + "/host.ql", "--emit-llvm", base + "/host.ll");
let hostOpts = ["0", "2"];
let h = 0;
while h < 2 {
  linkTo(base + "/host.ll", base + "/host-O" + hostOpts[h], hostOpts[h], false);
  verifyElf(base + "/host-O" + hostOpts[h], base + "/host.ll", "host-O" + hostOpts[h]);
  h = h + 1;
};
println("PASS t37: hosts compiled and linked before extensions existed");
let names = ["plugin", "second", "failure", "cycle"];
let n = 0;
while n < names.length {
  let name = names[n];
  emit(bsrc + "/" + name + ".ql", "--emit-module", base + "/" + name + ".ll");
  let ir = readText(base + "/" + name + ".ll");
  if std.String.includes(ir)("define i32 @main") { die(name + ": emitted a second main", ""); };
  if std.String.includes(ir)("define ptr @ql_alloc") { die(name + ": emitted a second runtime", ""); };
  h = 0;
  while h < 2 {
    let soOut = base + "/" + name + "-O" + hostOpts[h] + ".so";
    linkTo(base + "/" + name + ".ll", soOut, hostOpts[h], true);
    verifyElf(soOut, base + "/" + name + ".ll", name + "-O" + hostOpts[h]);
    h = h + 1;
  };
  n = n + 1;
};
println("PASS t37: four independent extensions (O0/O2)");
let secondIr = readText(base + "/second.ll");
let abiGood = "\\71\\6C\\61\\6E\\67\\2D\\6E\\61\\74\\69\\76\\65\\2D\\76\\31";
let abiBad = "\\71\\6C\\61\\6E\\67\\2D\\6E\\61\\74\\69\\76\\65\\2D\\76\\39";
let wrongAbi = std.String.replace(secondIr)(abiGood)(abiBad);
if wrongAbi == secondIr { die("ABI marker not found in second.ll", ""); };
writeText(base + "/wrong-abi.ll", wrongAbi);
linkTo(base + "/wrong-abi.ll", base + "/wrong-abi.so", "0", true);
let noEntry = std.String.replace(secondIr)("@qlang_extension_init_v1(")("@not_the_entry(");
if noEntry == secondIr { die("extension entry symbol not found in second.ll", ""); };
writeText(base + "/no-entry.ll", noEntry);
linkTo(base + "/no-entry.ll", base + "/no-entry.so", "0", true);
writeText(base + "/not-native.so", "println(\"must not execute source\");");
println("PASS t37: negative extensions wrong-abi / no-entry / not-native");
// Delete all QLang module sources, then restore only the interpreter entry host.
let rmSources = sh("rm -f " + sq(bsrc) + "/*.ql");
if rmSources.status != 0 { die("delete t37 sources", rmSources.stderr); };
writeText(bsrc + "/host.ql", readText(root + "/aot/tests/t37_extensions.ql"));
let t37Expected = readText(root + "/aot/tests/t37_extensions.expected");
let t37Ok = 0;
let t37Bad = 0;
let e = 0;
while e < 2 {
  let extOpt = hostOpts[e];
  let cpCycle = sh("cp " + sq(base + "/cycle-O" + extOpt + ".so") + " " + sq(bsrc + "/cycle.so"));
  if cpCycle.status != 0 { die("copy cycle", cpCycle.stderr); };
  let soPaths = [base + "/plugin-O" + extOpt + ".so", base + "/second-O" + extOpt + ".so",
                 base + "/failure-O" + extOpt + ".so", bsrc + "/cycle.so",
                 base + "/wrong-abi.so", base + "/not-native.so", base + "/no-entry.so"];
  h = 0;
  while h < 2 {
    let r = runHost(base + "/host-O" + hostOpts[h], soPaths);
    if checkResult("t37 native host O" + hostOpts[h] + " / extensions O" + extOpt, r, 0, t37Expected, true) {
      t37Ok = t37Ok + 1;
      println("PASS t37 native: host O" + hostOpts[h] + " x extensions O" + extOpt + " (28 contracts, sources absent)");
    } else {
      t37Bad = t37Bad + 1;
    };
    h = h + 1;
  };
  let ir = runInterp(bsrc + "/host.ql", soPaths);
  if checkInterp("t37 interpreter / extensions O" + extOpt, ir, 0, t37Expected) {
    t37Ok = t37Ok + 1;
    println("PASS t37 interpreter: extensions O" + extOpt + " (28 contracts, module sources absent)");
  } else {
    t37Bad = t37Bad + 1;
  };
  e = e + 1;
};
// 2) bridge host/plugin plus diagnostics fixtures.  Hosts compile first.
let bridgeFiles = ["bridge_host", "bridge_plugin", "bridge_diagnostics_host", "bridge_diagnostics_plugin"];
n = 0;
while n < bridgeFiles.length {
  let cp = sh("cp " + sq(root + "/aot/tests/extensions/" + bridgeFiles[n] + ".ql") + " " + sq(src + "/"));
  if cp.status != 0 { die("copy " + bridgeFiles[n], cp.stderr); };
  n = n + 1;
};
emit(src + "/bridge_host.ql", "--emit-llvm", work + "/bridge_host.ll");
emit(src + "/bridge_diagnostics_host.ql", "--emit-llvm", work + "/bridge_diagnostics_host.ll");
let hosts = ["bridge_host", "bridge_diagnostics_host"];
n = 0;
while n < hosts.length {
  h = 0;
  while h < 2 {
    linkTo(work + "/" + hosts[n] + ".ll", work + "/" + hosts[n] + "-O" + hostOpts[h], hostOpts[h], false);
    verifyElf(work + "/" + hosts[n] + "-O" + hostOpts[h], work + "/" + hosts[n] + ".ll", hosts[n] + "-O" + hostOpts[h]);
    h = h + 1;
  };
  n = n + 1;
};
let plugins = ["bridge_plugin", "bridge_diagnostics_plugin"];
n = 0;
while n < plugins.length {
  emit(src + "/" + plugins[n] + ".ql", "--emit-module", work + "/" + plugins[n] + ".ll");
  h = 0;
  while h < 2 {
    let soOut = work + "/" + plugins[n] + "-O" + hostOpts[h] + ".so";
    linkTo(work + "/" + plugins[n] + ".ll", soOut, hostOpts[h], true);
    verifyElf(soOut, work + "/" + plugins[n] + ".ll", plugins[n] + "-O" + hostOpts[h]);
    h = h + 1;
  };
  n = n + 1;
};
println("PASS bridge: hosts linked before plugins existed");
let bridgeExpected = readText(root + "/aot/tests/extensions/bridge_host.expected");
let bridgeHostBase = work + "/bridge_host";
// Derive diagnostic positions exactly like the Python point(): 1-based column of
// the first occurrence of a token on a fixture line.
let pluginPath = src + "/bridge_diagnostics_plugin.ql";
let diagHostPath = src + "/bridge_diagnostics_host.ql";
let pluginLines = std.String.split(readText(pluginPath))("\n");
let diagHostLines = std.String.split(readText(diagHostPath))("\n");
let point = (path, lines, line, token) -> {
  let at = findFrom(lines[line - 1], token, 0);
  if at < 0 { die("token '" + token + "' not found on " + path + ":" + std.Number.toString(line), ""); };
  path + ":" + std.Number.toString(line) + ":" + std.Number.toString(at + 1);
};
let origins = {
  native: point(pluginPath, pluginLines, 1, "1 / zero"),
  callback: point(diagHostPath, diagHostLines, 3, "1 / zero"),
  reused: point(pluginPath, pluginLines, 3, "Error.raise"),
  after: point(diagHostPath, diagHostLines, 11, "1 / zero")
};
let frames = {
  native: [point(diagHostPath, diagHostLines, 5, "module.fail")],
  callback: [point(pluginPath, pluginLines, 2, "callback()"),
             point(diagHostPath, diagHostLines, 7, "module.apply")],
  reused: [point(diagHostPath, diagHostLines, 9, "module.reuse")],
  after: []
};
let modes = ["native", "callback", "reused", "after"];
// Diagnostics need only the interpreted host entry; plugin sources stay absent.
let rmPlugins = sh("rm -f " + sq(src + "/bridge_plugin.ql") + " " + sq(src + "/bridge_diagnostics_plugin.ql"));
if rmPlugins.status != 0 { die("delete bridge plugin sources", rmPlugins.stderr); };
let bridgeOk = 0;
let bridgeBad = 0;
e = 0;
while e < 2 {
  let extOpt = hostOpts[e];
  let dso = work + "/bridge_plugin-O" + extOpt + ".so";
  let extOK = true;
  h = 0;
  while h < 2 {
    let r = runHost(bridgeHostBase + "-O" + hostOpts[h], [dso]);
    if !checkResult("bridge host O" + hostOpts[h] + " / extensions O" + extOpt, r, 0, bridgeExpected, true) { extOK = false; };
    h = h + 1;
  };
  let ir = runInterp(src + "/bridge_host.ql", [dso]);
  if !checkInterp("bridge interpreter / extensions O" + extOpt, ir, 0, bridgeExpected) { extOK = false; };
  if extOK {
    bridgeOk = bridgeOk + 1;
    println("PASS bridge identity/callback/type contracts: extensions O" + extOpt);
  } else {
    bridgeBad = bridgeBad + 1;
  };
  // Exact source origins, frames and failure shape for all four modes.
  let diagDso = work + "/bridge_diagnostics_plugin-O" + extOpt + ".so";
  let labels = ["native-O0", "native-O2", "core"];
  let li = 0;
  while li < labels.length {
    let label = labels[li];
    let interpreted = label == "core";
    let exe = work + "/bridge_diagnostics_host-" + (if label == "native-O0" { "O0"; } else { "O2"; });
    let labelOK = true;
    let mi = 0;
    while mi < modes.length {
      let mode = modes[mi];
      let r = if interpreted {
        runInterp(diagHostPath, [diagDso, mode]);
      } else {
        runHost(exe, [diagDso, mode]);
      };
      let body = if interpreted { interpreterBody(r); } else { r.stdout; };
      let origin = origins[mode];
      let expectedFrames = frames[mode];
      let actualFrames = atFrames(r.stderr);
      let where = label + " / extension O" + extOpt + " / " + mode;
      if !check(r.status == 1, "diagnostics rc=1: " + where) { labelOK = false; };
      if !check(body == "", "diagnostics body empty: " + where) { labelOK = false; };
      if !check(std.String.startsWith(r.stderr)(origin + ":"), "diagnostics origin " + origin + ": " + where) {
        labelOK = false;
        println("  stderr=[" + clamp(r.stderr, 320) + "]");
      };
      if !check(sameStrings(actualFrames, expectedFrames), "diagnostics frames: " + where) {
        labelOK = false;
        println("  expected=" + showStrings(expectedFrames));
        println("  actual  =" + showStrings(actualFrames));
      };
      if !check(!std.String.includes(r.stderr)("/bootstrapped/"), "diagnostics no bootstrapped frames: " + where) {
        labelOK = false;
      };
      mi = mi + 1;
    };
    if labelOK {
      println("PASS diagnostics origins/frames: " + label + " / extension O" + extOpt);
    };
    li = li + 1;
  };
  e = e + 1;
};
// 3) Escaped closure resolves a relative computed import at its defining module.
let scope = src + "/plugin-scope";
let mkScope = sh("mkdir -p " + sq(scope) + " && cp " + sq(work + "/bridge_diagnostics_plugin-O2.so") + " " + sq(scope + "/extension.so"));
if mkScope.status != 0 { die("prepare plugin-scope", mkScope.stderr); };
writeText(scope + "/factory.ql", "export let factory = () -> { () -> import (\"./\" + \"extension.so\"); };\n");
writeText(src + "/relative.ql", "import ./plugin-scope/factory.ql;\nlet load = factory();\nlet module = load();\nprintln(module.apply(() -> 17));\n");
let rel = runInterp(src + "/relative.ql", []);
if checkInterp("escaped closure import", rel, 0, "17\n") {
  println("PASS escaped import resolves at defining source module");
};
// 4) The private native bridge must stay absent from interpreted std.
writeText(src + "/private-bridge.ql", "println(std.Object.hasOwn(std)(\"__extensions\"));\n");
let priv = runInterp(src + "/private-bridge.ql", []);
if checkInterp("internal bridge absent from interpreted std", priv, 0, "false\n") {
  println("PASS internal bridge absent from interpreted std");
};
println("Bridge extension suite: " + std.Number.toString(checks) + " checks, " +
        std.Number.toString(failures) + " failures, " +
        std.Number.toString(t37Ok) + "/" + std.Number.toString(t37Ok + t37Bad) + " t37 runs, " +
        std.Number.toString(bridgeOk) + "/" + std.Number.toString(bridgeOk + bridgeBad) + " bridge runs");
if failures > 0 { assert(false, "bridge extension suite failed"); };
0;
