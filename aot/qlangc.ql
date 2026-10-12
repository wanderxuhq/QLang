// aot/qlangc.ql — QLang-written LLVM compiler: bootstrap interpreter or native executable.
// Native: --emit-llvm|--emit-module <source-path> <runtime-path>. Bootstrap also accepts source text, source path, runtime text.
// 输出:纯 IR 文本到 stdout(本文件不 import main.ql,故无 banner)。
// R5:import 路径相对本文件 (aot/) 解析 → 必须指到 ../bootstrapped/*.ql。
import ../bootstrapped/lexer.ql;
import ../bootstrapped/ast.ql;
import ../bootstrapped/parser.ql;
import ../bootstrapped/modules.ql;
import ./lifetime.ql;
import ./types.ql;
import ./value_abi.ql;
import ../bootstrapped/library.ql;

// Static graph loading reads source only; module initialization stays in the ELF.
let moduleCache = {};
// Cache emitted module code, never module values or initialization state.
let moduleFactories = {};
let moduleExportsReg = null;
let runtimeScope = null;
let extensionMode = false;
let extensionABI = "";
// Builtins start in each module root scope with canonical values. Nested
// declarations shadow them; assignments resolve the nearest lexical binding.
// Library closures keep their defining runtime scope, isolated from callers.
let moduleGlobalNames = ["Number", "String", "Boolean", "Null", "AnyArray", "AnyObject", "Function", "Any", "Never", "Array", "Object", "Error", "print", "println", "isError", "args"];
let publicRuntimeNames = {std: true};
let globalNameIndex = 0;
while globalNameIndex < moduleGlobalNames.length {
  publicRuntimeNames[moduleGlobalNames[globalNameIndex]] = true;
  globalNameIndex = globalNameIndex + 1;
};
let reserveModuleGlobals = () -> {
  curScope.moduleRoot = true; defineSlot("$exports");
  defineSlot("std"); let i = 0;
  while i < moduleGlobalNames.length { defineSlot(moduleGlobalNames[i]); i = i + 1; };
};
// Resolve literal imports anywhere in the shared AST. Export names are a
// candidate set; only entries actually produced at runtime are imported.
let loadModuleNode = (node, path, depth, names) -> {
  if AnyArray.check(node) {
    let i = 0; while i < node.length { loadModuleNode(node[i], path, depth, names)?; i = i + 1; };
  } else if AnyObject.check(node) {
    if !isError(node.type) && node.type == "Import" {
      if !isError(node.pathExpression) {
        node.origin = path;
        loadModuleNode(node.pathExpression, path, depth, names)?;
        return null;
      };
      let resolved = modulePath(path, node.path);
      if isError(resolved) { return std.Error.raise("CompileError", compileDiagnostic(node, resolved.message), null); };
      let source = std.fs.readFileText(resolved);
      if isError(source) { return std.Error.raise("CompileError", compileDiagnostic(node, source.message), null); };
      node.module = loadModuleProgram(source, resolved, depth + 1)?;
      return null;
    };
    let keys = std.Object.keys(node); let i = 0;
    while i < keys.length { loadModuleNode(node[keys[i]], path, depth, names)?; i = i + 1; };
  };
  null;
};
// Collect the complete export candidate set before following dependencies.
// Partially discovered modules can then close a cyclic compile-time graph.
let collectModuleExports = (node, names) -> {
  if AnyArray.check(node) {
    let i = 0; while i < node.length { collectModuleExports(node[i], names); i = i + 1; };
  } else if AnyObject.check(node) {
    if !isError(node.type) && node.type == "Export" {
      if node.name != null { names[node.name] = true; }
      else if node.value.type == "Identifier" { names[node.value.name] = true; }
      else if node.value.type == "Object" {
        let i = 0; while i < node.value.fields.length { names[node.value.fields[i].name] = true; i = i + 1; };
      };
    };
    let keys = std.Object.keys(node); let i = 0;
    while i < keys.length { collectModuleExports(node[keys[i]], names); i = i + 1; };
  };
  null;
};
let loadModuleProgram = (source, path, depth) -> {
  if !isError(moduleCache[path]) { return moduleCache[path]; };
  if depth >= 128 { return std.Error.raise("CompileError", "module nesting limit exceeded", null); };
  let program = parseModule(source, path);
  if isError(program) { return std.Error.raise("CompileError", program.message, null); };
  let names = {}; collectModuleExports(program.statements, names);
  let module = { program: program, names: std.Object.keys(names), path: path };
  moduleCache[path] = module;
  loadModuleNode(program.statements, path, depth, names)?;
  module;
};
// Reserve imports in the scope where their expression executes. Function
// bodies and branch/loop bodies get separate frames; their annotations and
// conditions still execute in the enclosing scope.
let reserveModuleBindings = (node) -> {
  if AnyArray.check(node) {
    let i = 0; while i < node.length { reserveModuleBindings(node[i]); i = i + 1; };
  } else if AnyObject.check(node) {
    let kind = node.type;
    if !isError(kind) {
      if kind == "Block" { return null; };
      if kind == "Function" {
        let i = 0; while i < node.parameters.length { reserveModuleBindings(node.parameters[i].annotation); i = i + 1; };
        return null;
      };
      if kind == "Let" { defineSlot(node.name); };
      if kind == "Import" {
        if !isError(node.pathExpression) { reserveModuleBindings(node.pathExpression); return null; };
        if isError(curScope.optional) { curScope.optional = {}; };
        let i = 0; while i < node.module.names.length {
          let name = node.module.names[i]; defineSlot(name); curScope.optional[name] = true; i = i + 1;
        };
        return null;
      };
    };
    let keys = std.Object.keys(node); let i = 0;
    while i < keys.length { reserveModuleBindings(node[keys[i]]); i = i + 1; };
  };
  null;
};
let emitModuleExports = (node) -> {
  let scope = curScope; let depth = 0;
  while scope != null && (isError(scope.moduleRoot) || !scope.moduleRoot) { scope = scope.parent; depth = depth + 1; };
  if scope == null { addCompileError(node, "export outside a module"); return emitNull(); };
  let off = emitBindingPtr({depth: depth, slot: scope.slots["$exports"]});
  let value = temp(); line("  " + value + " = load %ql_value, ptr " + off); value;
};
let emitExport = (node) -> {
  let value = emitExpr(node.value);
  let exports = emitModuleExports(node);
  if node.name != null { emitCallRegs("__obj_set", [exports, internString(node.name), value]); }
  else if node.value.type == "Identifier" { emitCallRegs("__obj_set", [exports, internString(node.value.name), value]); }
  else if node.value.type == "Object" {
    let i = 0; while i < node.value.fields.length {
      let key = internString(node.value.fields[i].name);
      let field = emitCallRegs("__obj_get", [value, key]);
      emitCallRegs("__obj_set", [exports, key, field]); i = i + 1;
    };
  };
  null;
};
let emitModuleFlag = (path) -> {
  let scope = curScope; let depth = 0;
  while scope != runtimeScope { scope = scope.parent; depth = depth + 1; };
  emitBindingPtr({depth: depth, slot: runtimeScope.slots["$loading:" + path]});
};
let emitSetModuleLoading = (path, value) -> {
  let off = emitModuleFlag(path);
  line("  store %ql_value " + emitBoolean({value: value}) + ", ptr " + off);
};
// Computed imports return a namespace; unknown names never create lexical slots.
let emitImport = (node) -> {
  if !isError(node.pathExpression) {
    let pathValue = emitExpr(node.pathExpression);
    let env = curEnv; let scope = curScope;
    while scope != runtimeScope {
      let parent = temp(); line("  " + parent + " = load ptr, ptr " + env);
      env = parent; scope = scope.parent;
    };
    return emitCallRegs("__extension_import", [pathValue, internString(node.origin), emitPointerValue(env), emitPointerValue("@qlang_extension_abi_v1")]);
  };
  let savedScope = curScope; let savedEnv = curEnv;
  // Factories capture only the built-in runtime frame, never the importing file.
  while curScope != runtimeScope {
    let parent = temp(); line("  " + parent + " = load ptr, ptr " + curEnv);
    curEnv = parent; curScope = curScope.parent;
  };
  let fn = emitFunction({ type: "Function", parameters: [], body: { statements: node.module.program.statements }, moduleBody: true, modulePath: node.module.path }, "");
  curScope = savedScope; curEnv = savedEnv;
  let flag = emitModuleFlag(node.module.path); let loading = temp(); let busy = temp();
  line("  " + loading + " = load %ql_value, ptr " + flag);
  line("  " + busy + " = call i1 @ql_truthy(%ql_value " + loading + ")");
  let cycle = lbl(); let ready = lbl();
  line("  br i1 " + busy + ", label %" + cycle + ", label %" + ready);
  line(cycle + ":"); curLbl = cycle;
  let error = emitCallRegs("__err", [internString("ImportCycle"), internString("cyclic import: " + node.module.path)]);
  error = emitLocatedError(error, node, false);
  emitPropagateError(error); line("  br label %" + ready);
  line(ready + ":"); curLbl = ready;
  let result = emitInvoke(fn, "null", "0");
  let tag = temp(); let failed = temp(); let good = lbl(); let done = lbl();
  line("  " + tag + " = call i64 @ql_tag(%ql_value " + result + ")");
  line("  " + failed + " = icmp eq i64 " + tag + ", 8");
  line("  br i1 " + failed + ", label %" + done + ", label %" + good);
  line(good + ":"); curLbl = good;
  let i = 0;
  while i < node.module.names.length {
    let name = node.module.names[i]; let key = internString(name);
    let found = emitCallRegs("__obj_find", [result, key]); let index = emitFloat(found); let present = temp();
    line("  " + present + " = fcmp oge double " + index + ", 0.0");
    let store = lbl(); let next = lbl();
    line("  br i1 " + present + ", label %" + store + ", label %" + next);
    line(store + ":"); curLbl = store;
    let value = emitCallRegs("__obj_get", [result, key]);
    let off = emitBindingPtr({ depth: 0, slot: curScope.slots[name] });
    emitBindingStore(off, value, "null", "null"); curScope.active[name] = true;
    line("  br label %" + next); line(next + ":"); curLbl = next;
    i = i + 1;
  };
  line("  br label %" + done); line(done + ":"); curLbl = done;
  result;
};

// ---- emit 基础设施 ----
let out = [];
let compileErrors = [];
let compileDiagnostic = (node, message) -> {
  let point = node.location;
  if isError(point) { return message; };
  point.file + ":" + std.String.toString(point.line) + ":" + std.String.toString(point.col) + ": " + message;
};
let addCompileError = (node, message) -> {
  compileErrors[compileErrors.length] = compileDiagnostic(node, message);
};
let inRuntime = false;
let runtimeFunctions = {};
let tmpN = 0;
let lblN = 0;
// R10-c:每函数单独 sink。函数体 emit 期 line() 经 curSink 落到当前函数块(fnBlocks 元素),
// 函数定义收尾后恢复调用方 sink(闭包盒指令回调用方当前块);main 整体先 flush out、再按序
// flush 各 fnBlocks。QLang 数组是引用类型,curSink 保存数组对象即完成重定向。
let fnBlocks = [];
let curSink = out;
// Fixed entry-block storage: reused at each call/iteration, never an alloca
// inside a loop. Nested function emission has its own list.
let stackSlots = [];
let stackSlot = (bytes) -> {
  let reg = temp();
  let size = if bytes < 1 { 1 } else { bytes };
  stackSlots[stackSlots.length] = "  " + reg + " = alloca i8, i64 " + std.String.toString(size) + ", align 8";
  reg;
};
let stackEntry = () -> std.Array.join(stackSlots)("\n");
// Call-argument buffers are provably short-lived: the invocation ABI only
// borrows them (partial application copies), every argument is evaluated before
// the stores, and a lifetime.start/end pair brackets each use. Reuse one slot per
// size instead of one per call site, or a 3000-statement module hoists tens of
// thousands of allocas into the entry block.
let argSlotPool = {};
let argSlot = (bytes) -> {
  let size = if bytes < 1 { 1 } else { bytes };
  let key = std.String.toString(size);
  let hit = argSlotPool[key];
  if !isError(hit) { return hit; };
  let reg = temp();
  stackSlots[stackSlots.length] = "  " + reg + " = alloca i8, i64 " + key + ", align 8";
  argSlotPool[key] = reg;
  reg;
};
let line = (s) -> { curSink[curSink.length] = s; };
let temp = () -> { tmpN = tmpN + 1; "%t" + std.String.toString(tmpN); };
let lbl = () -> { lblN = lblN + 1; "bb" + std.String.toString(lblN); };
// LLVM decimal floating constants require a decimal point or exponent.
// Use exact JSON conversion for fractions; general display formatting may
// deliberately differ and must never round/truncate compiled constants.
let f64lit = (x) -> {
  if x % 1 == 0 && x >= -9007199254740991 && x <= 9007199254740991 { return std.String.toString(x) + ".0"; };
  if std.Number.isNaN(x) { return "0x7FF8000000000000"; };
  if !std.Number.isFinite(x) { if x < 0 { return "0xFFF0000000000000"; } else { return "0x7FF0000000000000"; }; };
  let text = std.JSON.stringify(x);
  if std.String.includes(text)(".") { return text; };
  if std.String.includes(text)("e") { return std.String.replace(text)("e")(".0e"); };
  text + ".0";
};
// ---- M2 字符串字面量(Task 2)----
// 全局 .rodata 字符串常量 + interned 全局 STRING 盒(tag=2)。strDecls 缓冲在 main 末尾 flush。
let strCounter = 0;             // 字符串盒序号
let strDecls = [];              // 缓冲的全局常量/盒定义(flush 在 main 末尾)
let stringIntern = {};          // 内容 → @.strboxN(跨 runtime.ql+用户源码整个编译单元)

// Encode Unicode scalar values as UTF-8, escaping every byte for LLVM. The
// declared array length and its initializer are derived from the same bytes.
let stringBytes = (s) -> {
  let bytes = [];
  let i = 0;
  let cpAt = std.String.codePointAt(s);
  while i < s.length {
    let cp = cpAt(i);
    if cp < 128 {
      bytes[bytes.length] = cp;
    } else if cp < 2048 {
      bytes[bytes.length] = 192 + (cp - cp % 64) / 64;
      bytes[bytes.length] = 128 + cp % 64;
    } else if cp < 65536 {
      bytes[bytes.length] = 224 + (cp - cp % 4096) / 4096;
      bytes[bytes.length] = 128 + ((cp - cp % 64) / 64) % 64;
      bytes[bytes.length] = 128 + cp % 64;
    } else {
      bytes[bytes.length] = 240 + (cp - cp % 262144) / 262144;
      bytes[bytes.length] = 128 + ((cp - cp % 4096) / 4096) % 64;
      bytes[bytes.length] = 128 + ((cp - cp % 64) / 64) % 64;
      bytes[bytes.length] = 128 + cp % 64;
    };
    i = i + 1;
  };
  bytes;
};
// Concatenate many pieces in O(n log n): growing a string with `a = a + b` in a
// loop copies the whole accumulator each step (quadratic). Pairwise reduction
// keeps the total copying linear per level.
let concatParts = (parts) -> {
  let level = parts;
  while level.length > 1 {
    let next = []; let i = 0;
    while i + 1 < level.length { next[next.length] = level[i] + level[i + 1]; i = i + 2; };
    if i < level.length { next[next.length] = level[i]; };
    level = next;
  };
  if level.length == 0 { return ""; };
  level[0];
};
let escapeBytes = (bytes) -> {
  let hex = "0123456789ABCDEF";
  // Small literals are cheaper with the direct loop (no per-piece array).
  if bytes.length <= 64 {
    let text = ""; let i = 0;
    while i < bytes.length {
      let b = bytes[i];
      text = text + "\\" + hex[(b - b % 16) / 16] + hex[b % 16];
      i = i + 1;
    };
    return text;
  };
  let parts = []; let i = 0;
  while i < bytes.length {
    let b = bytes[i];
    parts[parts.length] = "\\" + hex[(b - b % 16) / 16] + hex[b % 16];
    i = i + 1;
  };
  concatParts(parts);
};

// internString:内容 → 恒同的全局 STRING 盒地址 @.strboxN(跨整个编译单元 intern)。
// STRING 盒布局 {tag@0=2, buf@8, len@16};[LEN x i8] 的 LEN = UTF-8 字节长度(无 NUL)。
let internString = (s) -> {
  let hit = stringIntern[s];
  if isError(hit) || hit == null {
    let n = strCounter;
    strCounter = strCounter + 1;
    let lbl = "@.strbox" + std.String.toString(n);
    let value = "{ i64 0, i64 ptrtoint (ptr " + lbl + " to i64) }";
    stringIntern[s] = value;
    let bufLbl = "@.str" + std.String.toString(n);
    let bytes = stringBytes(s);
    let len = bytes.length;
    strDecls[strDecls.length] = bufLbl + " = private unnamed_addr constant [" + std.String.toString(len) + " x i8] c\"" + escapeBytes(bytes) + "\"";
    strDecls[strDecls.length] = lbl + " = hidden global { i64, ptr, i64, i64, i64, i64 } { i64 2, ptr " + bufLbl + ", i64 " + std.String.toString(len) + ", i64 0, i64 0, i64 0 }";
    value;
  } else {
    hit;
  };
};

let emitStringLiteral = (node) -> {
  if isError(node.parts) { return internString(node.value); };
  let result = internString(""); let i = 0;
  while i < node.parts.length {
    let part = node.parts[i]; let text = null;
    if part.kind == "Literal" { text = internString(part.value); }
    else { text = emitCallRegs("__interpolate", [emitExpr(part.expression)]); };
    result = emitCallRegs("__op_add", [result, text]);
    i = i + 1;
  };
  result;
};
// R10-c:函数计数,生成 ql_fn<N> 名字。
let funcCounter = 0;

// A language value is {kind, bits}. Kind 0 carries a full-width heap/raw
// pointer; scalar kinds 1/3/4 carry Number/Boolean/Null directly. An all-zero
// value is internal uninitialized binding state, never a language value.
let emitPack = (kind, bits) -> {
  let first = temp(); let value = temp();
  line("  " + first + " = insertvalue %ql_value zeroinitializer, i64 " + kind + ", 0");
  line("  " + value + " = insertvalue %ql_value " + first + ", i64 " + bits + ", 1");
  value;
};
let emitBits = (value) -> {
  let bits = temp(); line("  " + bits + " = extractvalue %ql_value " + value + ", 1"); bits;
};
let emitPointer = (value) -> {
  let bits = emitBits(value); let pointer = temp();
  line("  " + pointer + " = inttoptr i64 " + bits + " to ptr"); pointer;
};
let emitPointerValue = (pointer) -> {
  let bits = temp(); line("  " + bits + " = ptrtoint ptr " + pointer + " to i64");
  emitPack("0", bits);
};
let emitFloat = (value) -> {
  let bits = emitBits(value); let number = temp();
  line("  " + number + " = bitcast i64 " + bits + " to double"); number;
};
let emitFloatValue = (number) -> {
  let bits = temp(); line("  " + bits + " = bitcast double " + number + " to i64");
  emitPack("1", bits);
};
let emitNumber = (node) -> "{ i64 1, i64 bitcast (double " + f64lit(node.value) + " to i64) }";
let emitBoolean = (node) -> if node.value { "{ i64 3, i64 1 }" } else { "{ i64 3, i64 0 }" };
let emitBoolResult = (condition) -> {
  let bits = temp(); line("  " + bits + " = zext i1 " + condition + " to i64");
  emitPack("3", bits);
};
let emitNull = () -> "{ i64 4, i64 0 }";

// && / || 短路 emit(controller 裁定语义 = host interpreter.rs eval_binary_op):
//   && :A 假 → 结果 = A 值(不 eval B);A 真 → 结果 = B 值
//   || :A 真 → 结果 = A 值(不 eval B);A 假 → 结果 = B 值
// 返回原值,不分配基础值;done 块 phi = [ A, A 所在块 ] + [ B, B 所在块 ] + [ errRes, err 块 ]。
// M3 R2:左操作数为 Error → 操作区截获(host:&&/|| 对错误不短路),结果 = TypeMismatch。
// @ql_truthy 直接接收 %ql_value。
let emitShortCircuit = (node) -> {
  let op = node.operator;
  let A = emitExpr(node.left);
  // M3 R2:左操作数为 Error → 操作区截获(host:&&/|| 对错误不短路),结果 = TypeMismatch
  let tA = temp(); let eA = temp();
  line("  " + tA + " = call i64 @ql_tag(%ql_value " + A + ")");
  line("  " + eA + " = icmp eq i64 " + tA + ", 8");
  let lErr = lbl(); let lNorm = lbl(); let lDone = lbl();
  line("  br i1 " + eA + ", label %" + lErr + ", label %" + lNorm);
  line(lErr + ":");
  curLbl = lErr;
  let errRes = emitCallRegs("__op_zone_error", [internString("logical operation"), A, emitNull()]);
  let errLbl = curLbl;
  line("  br label %" + lDone);
  line(lNorm + ":");
  curLbl = lNorm;
  let trA = temp();
  line("  " + trA + " = call i1 @ql_truthy(%ql_value " + A + ")");
  let predA = curLbl;                       // emit A + truthy 所在块 = br 的前驱
  let lEvalB = lbl();
  if op == "&&" {
    line("  br i1 " + trA + ", label %" + lEvalB + ", label %" + lDone);
  } else {
    line("  br i1 " + trA + ", label %" + lDone + ", label %" + lEvalB);
  };
  line(lEvalB + ":");
  curLbl = lEvalB;
  let B = emitExpr(node.right);
  // Critical fix (Fix Round 1):B 自身若是短路,emit 会再产 evalB/done 块并把 curLbl
  // 设为其 done 块 → 外层 br label %lDone 实际从 B 的 done 块发出,phi 前驱必须记
  // curLbl 而非硬编码 lEvalB(否则 "PHI node entries do not match predecessors!",clang 拒绝)。
  let predB = curLbl;
  line("  br label %" + lDone);
  line(lDone + ":");
  curLbl = lDone;
  let res = temp();
  line("  " + res + " = phi %ql_value [ " + A + ", %" + predA + " ], [ " + B + ", %" + predB + " ], [ " + errRes + ", %" + errLbl + " ]");
  res;
};

// 数值路径(内联):仅当调用方已确认左右 tag 均 == 1(NUMBER)。除零检查内联。
// 操作数用 {reg, raw} 传入 —— 已是裸 double 的直接用,别先装箱再解箱。
// 位运算:差异项 3 —— fptosi → and/or/xor → sitofp(与算术同构)。
let emitNumOp = (op, lv, rv) -> {
  let f1 = emitRawDouble(lv); let f2 = emitRawDouble(rv);
  if op == "+" || op == "-" || op == "*" {
    let rr = temp();
    let fop = if op == "+" { "fadd" } else if op == "-" { "fsub" } else { "fmul" };
    line("  " + rr + " = " + fop + " double " + f1 + ", " + f2);
    let b = emitFloatValue(rr);
    b;
  } else if op == "/" || op == "%" {
    // 除零检查:R == 0.0 → __op_div0(造 DivisionByZero 错误)
    let z = temp(); let l0 = lbl(); let lOk = lbl(); let lEnd = lbl();
    line("  " + z + " = fcmp oeq double " + f2 + ", 0.0");
    line("  br i1 " + z + ", label %" + l0 + ", label %" + lOk);
    line(lOk + ":");
    curLbl = lOk;
    let rr = temp();
    if op == "%" {
      let value = emitCallRegs("__num_rem", [emitBoxedV(lv), emitBoxedV(rv)]);
      let bits = emitBits(value);
      line("  " + rr + " = bitcast i64 " + bits + " to double");
    } else {
      line("  " + rr + " = fdiv double " + f1 + ", " + f2);
    };
    let b = emitFloatValue(rr);
    let okLbl = curLbl;
    line("  br label %" + lEnd);
    line(l0 + ":");
    curLbl = l0;
    let errV = emitCallRegs("__op_div0", []);
    let zeroLbl = curLbl;
    line("  br label %" + lEnd);
    line(lEnd + ":");
    curLbl = lEnd;
    let res = temp();
    line("  " + res + " = phi %ql_value [ " + b + ", %" + okLbl + " ], [ " + errV + ", %" + zeroLbl + " ]");
    res;
  } else if op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" || op == ">=" {
    let cmp = if op == "==" { "oeq" } else if op == "!=" { "une" } else if op == "<" { "olt" } else if op == "<=" { "ole" } else if op == ">" { "ogt" } else { "oge" };
    let c = temp();
    line("  " + c + " = fcmp " + cmp + " double " + f1 + ", " + f2);
    emitBoolResult(c);
  } else {
    // 位运算 & | ^(差异项 3):fptosi → and/or/xor → sitofp
    let op2 = if op == "&" { "and" } else if op == "|" { "or" } else { "xor" };
    let i1 = temp(); let i2 = temp(); let ir = temp();
    line("  " + i1 + " = call i64 @llvm.fptosi.sat.i64.f64(double " + f1 + ")");
    line("  " + i2 + " = call i64 @llvm.fptosi.sat.i64.f64(double " + f2 + ")");
    line("  " + ir + " = " + op2 + " i64 " + i1 + ", " + i2);
    let fr = temp();
    line("  " + fr + " = sitofp i64 " + ir + " to double");
    let b = emitFloatValue(fr);
    b;
  };
};

// 非数值派发路径:每 op 有至多一个合法非数值组合(+ STR 拼接;== / != tag 感知),其余 TypeMismatch。
let emitDispOp = (op, L, R) -> {
  if op == "+" {
    emitCallRegs("__op_add", [L, R]);
  } else if op == "==" {
    emitCallRegs("__op_eq", [L, R]);
  } else if op == "!=" {
    emitCallRegs("__op_ne", [L, R]);
  } else {
    let word = if op == "-" || op == "*" || op == "/" || op == "%" {
      "numeric operation"
    } else if op == "<" || op == "<=" || op == ">" || op == ">=" {
      "comparison"
    } else {
      "bitwise operation"
    };
    emitCallRegs("__op_zone_error", [internString(word), L, R]);
  };
};

// Error fallback: evaluate the right operand only if the left is an Error.
let emitCoalesce = (node) -> {
  let A = emitExpr(node.left);
  let tag = temp(); let err = temp();
  line("  " + tag + " = call i64 @ql_tag(%ql_value " + A + ")");
  line("  " + err + " = icmp eq i64 " + tag + ", 8");
  let predA = curLbl;
  let useB = lbl(); let done = lbl();
  line("  br i1 " + err + ", label %" + useB + ", label %" + done);
  line(useB + ":"); curLbl = useB;
  let B = emitExpr(node.right);
  let predB = curLbl;
  line("  br label %" + done);
  line(done + ":"); curLbl = done;
  let result = temp();
  line("  " + result + " = phi %ql_value [ " + A + ", %" + predA + " ], [ " + B + ", %" + predB + " ]");
  result;
};

// 二元运算:M3 R1 双路径 —— 静态两侧均为 Number 字面量 → 内联 emitNumOp;否则运行期
// tag 检查,双 NUMBER → 内联数值路径,否则按 op 派发 __op_add/__op_eq/__op_ne/__op_zone_error。
// && / || 不走这里 —— 先在顶部截获走 emitShortCircuit(短路,避免无条件先求值右操作数)。
let emitBinaryOp = (node) -> {
  if node.operator == "&&" || node.operator == "||" {
    emitShortCircuit(node);
  } else if node.operator == "??" {
    emitCoalesce(node);
  } else {
    let op = node.operator;
    // 类型信息来自生成代码之前的那一遍推导(节点上的 staticType)。
    let bothNum = isStaticNumber(node.left) && isStaticNumber(node.right);
    if bothNum {
      // 两侧静态已知是 Number ⇒ 派发的标签测试是死代码。除/模也走这里:emitNumOp 自带
      // 除零检查(那是运行期值的错误,与类型无关)。
      emitNumOp(op, emitValue(node.left), emitValue(node.right));
    } else {
      let L = emitExpr(node.left);
      let R = emitExpr(node.right);
      let t1 = temp(); let t2 = temp(); let c1 = temp(); let c2 = temp(); let c3 = temp();
      line("  " + t1 + " = call i64 @ql_tag(%ql_value " + L + ")");
      line("  " + t2 + " = call i64 @ql_tag(%ql_value " + R + ")");
      line("  " + c1 + " = icmp eq i64 " + t1 + ", 1");
      line("  " + c2 + " = icmp eq i64 " + t2 + ", 1");
      line("  " + c3 + " = and i1 " + c1 + ", " + c2);
      let lNum = lbl(); let lDisp = lbl(); let lMerge = lbl();
      line("  br i1 " + c3 + ", label %" + lNum + ", label %" + lDisp);
      line(lNum + ":");
      curLbl = lNum;
      let numRes = emitNumOp(op, { reg: L, raw: "" }, { reg: R, raw: "" });
      let numLbl = curLbl;
      line("  br label %" + lMerge);
      line(lDisp + ":");
      curLbl = lDisp;
      let dispRes = emitDispOp(op, L, R);
      let dispLbl = curLbl;
      line("  br label %" + lMerge);
      line(lMerge + ":");
      curLbl = lMerge;
      let res = temp();
      line("  " + res + " = phi %ql_value [ " + numRes + ", %" + numLbl + " ], [ " + dispRes + ", %" + dispLbl + " ]");
      res;
    };
  };
};

// Shared failure edge for postfix ? and failed aggregate assignments.
let emitPropagateError = (O) -> {
  // M3 T3 Propagate:operand 为 Error → 折回函数返回(或顶层 __exit_error);否则原值继续
  let tO = temp(); let eO = temp();
  line("  " + tO + " = call i64 @ql_tag(%ql_value " + O + ")");
  line("  " + eO + " = icmp eq i64 " + tO + ", 8");
  let lProp = lbl(); let lOk = lbl();
  line("  br i1 " + eO + ", label %" + lProp + ", label %" + lOk);
  line(lProp + ":");
  curLbl = lProp;
  if isTopLevel {
    emitCallRegs("__exit_error", [O]);
    line("  unreachable");
  } else {
    line("  store %ql_value " + O + ", ptr " + curRetv);
    line("  br label %" + curEpiLbl);
  };
  line(lOk + ":");
  curLbl = lOk;
  O;
};

// Unary operations produce inline scalar results; ? propagates Errors.
let emitUnaryOp = (node) -> {
  let ov = emitValue(node.operand);
  if node.operator == "?" {
    let value = if ov.raw == "Number" { emitFloatValue(ov.reg); } else if ov.raw == "Boolean" { emitBoolResult(ov.reg); } else { ov.reg; };
    return emitPropagateError(value);
  };
  if node.operator == "-" || node.operator == "+" {
    // 操作数已是裸 double ⇒ 已经是 Number,标签测试与装箱都不需要。
    if ov.raw == "Number" {
      if node.operator == "-" { let neg = temp(); line("  " + neg + " = fneg double " + ov.reg); return emitFloatValue(neg); };
      return emitFloatValue(ov.reg);
    };
    let value = ov.reg;
    let tag = temp(); let numeric = temp();
    line("  " + tag + " = call i64 @ql_tag(%ql_value " + value + ")");
    line("  " + numeric + " = icmp eq i64 " + tag + ", 1");
    let good = lbl(); let bad = lbl(); let done = lbl();
    line("  br i1 " + numeric + ", label %" + good + ", label %" + bad);
    line(good + ":"); curLbl = good;
    let result = value;
    if node.operator == "-" {
      let number = emitFloat(value); let negated = temp();
      line("  " + negated + " = fneg double " + number);
      result = emitFloatValue(negated);
    };
    let goodEnd = curLbl;
    line("  br label %" + done);
    line(bad + ":"); curLbl = bad;
    let helper = if node.operator == "-" { "__neg_error"; } else { "__pos_error"; };
    let error = emitCallRegs(helper, [value]); let badEnd = curLbl;
    line("  br label %" + done);
    line(done + ":"); curLbl = done; let merged = temp();
    line("  " + merged + " = phi %ql_value [ " + result + ", %" + goodEnd + " ], [ " + error + ", %" + badEnd + " ]");
    return merged;
  };
  if node.operator == "!" {
    let bv = emitBoxedV(ov);
    let truth = temp(); let inverse = temp();
    line("  " + truth + " = call i1 @ql_truthy(%ql_value " + bv + ")");
    line("  " + inverse + " = xor i1 " + truth + ", true");
    return emitBoolResult(inverse);
  };
  emitBoxedV(ov);
};

// ---- 编译期作用域模型(Task 5)----
// Runtime frames: parent@0, count@8, then 64-byte bindings (value/type/text/presence).
// Compile-time scopes track reserved slots separately from active declarations.
let globalScope = { slots: {}, active: {}, parent: null, isFunction: false };
let curScope = globalScope;
// scopePush:进入新函数时挂到当前作用域下(Task 6+ 函数 emit 用;v1 顶层只有 globalScope)。
let scopePush = (parent) -> { curScope = { slots: {}, active: {}, parent: parent, isFunction: false }; };
// defineSlot:slots 现有键数即新 slot 索引(std.Object.keys 在 bootstrapped/stdlib.ql 可用,已实测)。
// R10-i/幂等:若名字已在本作用域定义则返回既有 slot(不重定义)—— 这修复 Task 5 Minor-5b
// (同作用域重复 let 的孤儿槽),也是「函数预扫(defineSlot)后函数体 emit 中再对同一名字按
// 已绑定处理(emitStoreByName)」能拿到同一槽号的前提。Task 7 顶层函数递归:`let F=<Function>`
// 必须 defineSlot(F) 先于 emitExpr(Function),否则函数体里的 F 按未绑定处理。
let defineSlot = (name) -> {
  let existing = curScope.slots[name];
  if !isError(existing) && existing != null {
    existing;
  } else {
    let n = std.Object.keys(curScope.slots).length;
    curScope.slots[name] = n;
    n;
  };
};
// lookupSlot:返回 {depth, slot} 或 null。R8 累加器形态 —— QLang 的 while 是语句,body 值不回流,
// brief 草图(while 内 if 表达式直接产 {depth, slot})命中后 s 不再更新,会无限循环。
let lookupSlotFrom = (name, scope, depth, deferred) -> {
  let d = depth;
  let s = scope;
  let hit = null;
  while s != null && hit == null {
    let v = s.slots[name];
    let visible = s != runtimeScope || inRuntime || !isError(publicRuntimeNames[name]);
    if visible && !isError(v) && v != null && (inRuntime || deferred || !isError(s.active[name])) { hit = { depth: d, slot: v, scope: s, deferred: deferred }; }
    else { if s.isFunction { deferred = true; }; s = s.parent; d = d + 1; };
  };
  hit;
};
let lookupSlot = (name) -> lookupSlotFrom(name, curScope, 0, false);
// R9/R1:当前函数入口 env 寄存器名(main = 全局帧寄存器);不硬编码 "env0" 字面量。
let curEnv = "";
// ---- 编译期类型信息 ---------------------------------------------------------------
// 生成代码之前先在 AST 上收集类型信息(aot/types.ql),发射器只读节点上的标注:
// staticType(表达式静态类型)、annotationType(Let 注解所指的内建类型)、
// declaredType(Assign 写入目标声明的内建类型)。
// 当前正在 emit 的基本块标签(短路 phi 需记录「emit A + truthy 所在块」作前驱;main 入口、
// if/while 各块、短路各块处都要更新 —— 否则短路出现在非 entry 块时 phi 前驱写错)。
let curLbl = "";
// M3 T3:`?` 的传播目标 = 当前函数 epilogue(%retv alloca + %epilogue label)。
// 顶层(isTopLevel)无 epilogue → `?` 走 __exit_error + unreachable。
let curRetv = "";       // 当前函数 %retv 寄存器名
let curEpiLbl = "";     // 当前函数 epilogue label 名
let isTopLevel = true;  // main 顶层 ? → __exit_error
// 当前函数声明的返回类型。与参数注解同一性质:只要写了注解就强制(不只内建类型),
// 运行期在返回边检查。curReturnType 只是内建类型名 —— 能证明整条路径都返回它时跳过检查。
let curReturnActive = false;
let curReturnType = "";
let curReturnTy = "null";
let curReturnText = "null";
// Set the first time a reader needs the located-error helper, and the position in
// `out` where its definition is spliced (just after the prelude, so it precedes
// every call site: this toolchain rejects a forward `declare`).
let needColdLocated = false;
let coldHelperAt = 0;
// 分析期已证明不可能是 Error、因而整块省掉定位测试的节点数(命中数,先于行数报)。
let locErrorElided = 0;
// Runtime functions whose body is already emitted, keyed by source name: a call
// after that point can be direct (this toolchain wants the definition first), and
// runtime bindings are private, so they cannot be rebound by user code.
let runtimeFnIr = {};
let assignedRuntime = {};
// Index in `out` where main's header begins, and a guard that keeps the cold
// helper's own __err_at call indirect (it is emitted ahead of the runtime blocks).
let mainAt = 0;
let inColdHelper = false;
// ②a 补充量测:发射序折扣 —— 用户调用点里「被调者符号已经先发出」的有多少(纯计数)。
let ordFnEmitted = {};
let ordFnRetNum = {};
let ordCallsTotal = 0;
let ordCallsEmitted = 0;
let ordCallsRetRaw = 0;
let ordCallsNotYet = 0;

// Frames reserve slots ahead of time, but declarations become visible in
// source order. An all-zero internal value is binding state, never QLang null.
let emitFrame = (parent, count, local) -> {
  let frame = null; let np = temp();
  if local {
    frame = stackSlot(16 + 64 * count);
    line("  call void @llvm.lifetime.start.p0(i64 " + std.String.toString(16 + 64 * count) + ", ptr " + frame + ")");
  }
  else { frame = temp(); line("  " + frame + " = call ptr @ql_alloc(i64 " + std.String.toString(16 + 64 * count) + ")"); };
  line("  call void @llvm.memset.p0.i64(ptr " + frame + ", i8 0, i64 " + std.String.toString(16 + 64 * count) + ", i1 false)");
  line("  store ptr " + parent + ", ptr " + frame);
  line("  " + np + " = getelementptr i8, ptr " + frame + ", i64 8");
  line("  store i64 " + std.String.toString(count) + ", ptr " + np);
  frame;
};
let emitBindingPtr = (hit) -> {
  let frame = curEnv;
  let d = 0;
  while d < hit.depth {
    let p = temp(); line("  " + p + " = load ptr, ptr " + frame);
    frame = p; d = d + 1;
  };
  let off = temp();
  line("  " + off + " = getelementptr i8, ptr " + frame + ", i64 " + std.String.toString(16 + 64 * hit.slot));
  off;
};
// Imports can omit conditional exports. An absent imported binding resolves
// outward; a declared but uninitialized binding still hides its parent.
let emitResolvedBindingPtr = (hit, name) -> {
  if hit == null { return "null"; };
  let off = emitBindingPtr(hit);
  if inRuntime || isError(hit.scope.optional) || isError(hit.scope.optional[name]) { return off; };
  let statep = temp(); let state = temp(); let present = temp();
  line("  " + statep + " = getelementptr i8, ptr " + off + ", i64 48");
  line("  " + state + " = load i64, ptr " + statep);
  line("  " + present + " = icmp ne i64 " + state + ", 0");
  let yes = lbl(); let no = lbl(); let done = lbl();
  line("  br i1 " + present + ", label %" + yes + ", label %" + no);
  line(yes + ":"); curLbl = yes; line("  br label %" + done);
  line(no + ":"); curLbl = no;
  let outer = lookupSlotFrom(name, hit.scope.parent, hit.depth + 1, hit.deferred || hit.scope.isFunction);
  let fallback = emitResolvedBindingPtr(outer, name); let noEnd = curLbl;
  line("  br label %" + done); line(done + ":"); curLbl = done;
  let result = temp();
  line("  " + result + " = phi ptr [ " + off + ", %" + yes + " ], [ " + fallback + ", %" + noEnd + " ]");
  result;
};
let emitIdentifier = (node) -> {
  let hit = lookupSlot(node.name);
  let internal = !isError(node.internal) && node.internal;
  if internal && runtimeScope != null {
    let scope = curScope; let depth = 0;
    while scope != runtimeScope { scope = scope.parent; depth = depth + 1; };
    let slot = runtimeScope.slots[node.name];
    if isError(slot) { addCompileError(node, "missing runtime binding: " + node.name); return emitNull(); };
    hit = { depth: depth, slot: slot };
  };
  if hit == null { addCompileError(node, "undeclared name: " + node.name); return emitNull(); };
  if inRuntime || internal {
    let off = emitBindingPtr(hit); let value = temp(); line("  " + value + " = load %ql_value, ptr " + off); return value;
  };
  let off = emitResolvedBindingPtr(hit, node.name);
  // A same-body read of a non-optional binding is guaranteed by the frontend's
  // definite-assignment check to exist and be initialized, so the null check and
  // the ql_empty check (with their cold diagnostic paths) are dead code.
  let sameBody = hit.depth == 0 && (isError(hit.scope.optional) || isError(hit.scope.optional[node.name]));
  if sameBody { let direct = temp(); line("  " + direct + " = load %ql_value, ptr " + off); return direct; };
  let absent = temp(); let missing = lbl(); let found = lbl(); let done = lbl();
  line("  " + absent + " = icmp eq ptr " + off + ", null");
  line("  br i1 " + absent + ", label %" + missing + ", label %" + found);
  line(missing + ":"); curLbl = missing;
  let missingError = emitCallRegs("__err", [internString("UndefinedVariable"), internString("Undefined variable: " + node.name)]);
  let missingEnd = curLbl; line("  br label %" + done);
  line(found + ":"); curLbl = found;
  let value = temp(); line("  " + value + " = load %ql_value, ptr " + off);
  let empty = temp(); let bad = lbl(); let good = lbl();
  line("  " + empty + " = call i1 @ql_empty(%ql_value " + value + ")");
  line("  br i1 " + empty + ", label %" + bad + ", label %" + good);
  line(bad + ":"); curLbl = bad;
  let error = emitCallRegs("__err", [internString("Uninitialized"), internString("variable \"" + node.name + "\" is declared but not initialized")]);
  let badEnd = curLbl; line("  br label %" + done);
  line(good + ":"); curLbl = good; line("  br label %" + done);
  line(done + ":"); curLbl = done; let result = temp();
  line("  " + result + " = phi %ql_value [ " + missingError + ", %" + missingEnd + " ], [ " + error + ", %" + badEnd + " ], [ " + value + ", %" + good + " ]");
  result;
};
let annotationText = (node) -> {
  if !isError(node.annotationText) { return node.annotationText; };
  if node.type == "Identifier" { return node.name; };
  "?";
};
let emitBindingStore = (off, value, ty, text) -> {
  if value == "null" { value = "zeroinitializer"; };
  if ty == "null" { ty = "zeroinitializer"; };
  if text == "null" { text = "zeroinitializer"; };
  line("  store %ql_value " + value + ", ptr " + off);
  let ap = temp(); let tp = temp();
  line("  " + ap + " = getelementptr i8, ptr " + off + ", i64 16");
  line("  store %ql_value " + ty + ", ptr " + ap);
  line("  " + tp + " = getelementptr i8, ptr " + off + ", i64 32");
  line("  store %ql_value " + text + ", ptr " + tp);
  let present = temp(); line("  " + present + " = getelementptr i8, ptr " + off + ", i64 48");
  line("  store i64 1, ptr " + present);
};
let emitLetStmt = (node) -> {
  let ty = "null"; let text = "null";
  let annotated = !isError(node.annotation) && node.annotation != null;
  // 没被编译期分析标注过的节点(例如受信任的运行时源码)不做任何猜测。
  if isError(node.annotationType) { node.annotationType = ""; };
  // 编译期类型信息:
  //  · runtimeTypeFree —— 该绑定的每一次写入右值类型都已知,所以运行期检查永不失败;
  //    类型/文本槽与检查都可以不生成(闭包读取该槽的路径也不再需要它)。
  //  · 否则类型/文本槽必须照写(非同体写入会读它决定要不要检查),只是本次写入若右值
  //    类型已等于注解,这一次检查是死代码。
  let typeFree = annotated && !inRuntime && !isError(node.runtimeTypeFree) && node.runtimeTypeFree == true;
  let deadCheck = !inRuntime && (typeFree || checkIsDead(node.value, node.annotationType));
  if annotated && !typeFree { ty = emitExpr(node.annotation); text = internString(annotationText(node.annotation)); };
  let value = "null";
  if node.value != null {
    if node.value.type == "Function" { value = emitFunction(node.value, node.name); }
    else { value = emitExpr(node.value); };
    // A typed binding holds only its type. The check's value still goes through
    // __err_at first, so a failing check carries the declaration's source position,
    // and only then propagates out of the current function (or exits at top level).
    if annotated && !deadCheck {
      value = emitLocatedError(emitCallRegs("__check_binding", [value, ty, text]), node, false);
      emitPropagateError(value);
    };
  };
  let slot = defineSlot(node.name);
  curScope.active[node.name] = true;
  // 裸槽:分析期判定这个绑定是裸 double(unboxType)。槽里 payload 就是 double 的位
  // (写成 Number 盒时如此),所以裸写只需写位(tag 早已是 NUMBER,槽仍是合法盒)。
  if !isError(node.unboxType) && node.unboxType == "Number" {
    if isError(curScope.unbox) { curScope.unbox = {}; };
    curScope.unbox[node.name] = true;
  };
  // Remember which bindings carry a runtime annotation: an unannotated slot's
  // type/text are zero, so a later plain store is equivalent to the
  // __check_binding diamond and the diamond can be dropped.
  if annotated {
    if isError(curScope.annotated) { curScope.annotated = {}; };
    curScope.annotated[node.name] = true;
    if typeFree {
      if isError(curScope.typeFree) { curScope.typeFree = {}; };
      curScope.typeFree[node.name] = true;
    };
  };
  let off = emitBindingPtr({ depth: 0, slot: slot });
  if annotated && !typeFree && node.value == null {
    // A declaration validates its annotation but does not check an absent value.
    let ok = emitCallRegs("__is_type_value", [ty]);
    let flag = temp(); let valid = temp();
    line("  " + flag + " = extractvalue %ql_value " + ok + ", 1");
    line("  " + valid + " = icmp ne i64 " + flag + ", 0");
    let good = lbl(); let bad = lbl(); let done = lbl();
    line("  br i1 " + valid + ", label %" + good + ", label %" + bad);
    line(good + ":"); curLbl = good; emitBindingStore(off, "null", ty, text);
    line("  br label %" + done);
    line(bad + ":"); curLbl = bad;
    let error = emitCallRegs("__err", [internString("TypeCheck"), internString("type annotation is not a type value")]);
    error = emitLocatedError(error, node, false);
    emitBindingStore(off, error, "null", "null"); line("  br label %" + done);
    line(done + ":"); curLbl = done;
  } else {
    // 未初始化声明的裸槽也要写成一个合法的 NUMBER 盒(tag=1),否则后续只写 payload
    // 的裸写会留下 tag=0,任何按 %ql_value 读它的路径都会把它当成指针。
    if value == "null" && !isError(node.unboxType) && node.unboxType == "Number" { value = "{ i64 1, i64 0 }"; };
    emitBindingStore(off, value, ty, text);
  };
  slot;
};
let emitStoreByName = (name, expression, target, declaredType) -> {
  let hit = lookupSlot(name);
  if hit == null { addCompileError(target, "assignment to undeclared name: " + name); return null; };
  let rv = emitValue(expression);
  // 裸槽的写入:只写 payload 位(标签早已是 NUMBER,槽仍是合法 Number 盒),不必先装箱。
  if !inRuntime && !isError(hit.scope.unbox) && !isError(hit.scope.unbox[name]) && rv.raw == "Number" {
    let off0 = emitResolvedBindingPtr(hit, name);
    let bits0 = temp(); let pp0 = temp();
    line("  " + bits0 + " = bitcast double " + rv.reg + " to i64");
    line("  " + pp0 + " = getelementptr i8, ptr " + off0 + ", i64 8");
    line("  store i64 " + bits0 + ", ptr " + pp0);
    return null;
  };
  let value = if rv.raw == "Number" { emitFloatValue(rv.reg); } else if rv.raw == "Boolean" { emitBoolResult(rv.reg); } else { rv.reg; };
  let off = emitResolvedBindingPtr(hit, name);
  // A same-body write target is a direct slot pointer: the frontend guarantees
  // the binding exists, so the absent-pointer check is dead.
  let sameBody = hit.depth == 0 && (isError(hit.scope.optional) || isError(hit.scope.optional[name]));
  let unannotated = sameBody && (isError(hit.scope.annotated) || isError(hit.scope.annotated[name]));
  if !inRuntime && !sameBody {
    let absent = temp(); let bad = lbl(); let good = lbl();
    line("  " + absent + " = icmp eq ptr " + off + ", null");
    line("  br i1 " + absent + ", label %" + bad + ", label %" + good);
    line(bad + ":"); curLbl = bad;
    let error = emitCallRegs("__err", [internString("UndefinedVariable"), internString("Undefined variable: " + name)]);
    error = emitLocatedError(error, target, false);
    emitPropagateError(error); line("  br label %" + good);
    line(good + ":"); curLbl = good;
  };
  // Unannotated same-body target: the slot's type/text are zero, so the plain
  // store is exactly what the diamond's `plain` branch would do.
  if inRuntime || unannotated { line("  store %ql_value " + value + ", ptr " + off); return null; };
  // 编译期类型信息(来自 Assign 节点的标注):右值静态类型已等于声明的内建类型
  // ⇒ 重检查不可能失败,走 plain;整条绑定类型已知时同理(其类型槽也不再生成)。
  if !isError(hit.scope.typeFree) && !isError(hit.scope.typeFree[name]) { line("  store %ql_value " + value + ", ptr " + off); return null; };
  if checkIsDead(expression, declaredType) { line("  store %ql_value " + value + ", ptr " + off); return null; };
  let ap = temp(); let ty = temp(); let has = temp();
  line("  " + ap + " = getelementptr i8, ptr " + off + ", i64 16");
  line("  " + ty + " = load %ql_value, ptr " + ap);
  let absent = temp();
  line("  " + absent + " = call i1 @ql_empty(%ql_value " + ty + ")");
  line("  " + has + " = xor i1 " + absent + ", true");
  let check = lbl(); let plain = lbl(); let done = lbl();
  line("  br i1 " + has + ", label %" + check + ", label %" + plain);
  line(check + ":"); curLbl = check;
  let tp = temp(); let text = temp();
  line("  " + tp + " = getelementptr i8, ptr " + off + ", i64 32");
  line("  " + text + " = load %ql_value, ptr " + tp);
  // Reassigning to a typed binding re-checks it; the value still gets its source
  // position attached, then a failure propagates rather than being stored, so the
  // binding keeps holding only its declared type. The diamond is also emitted for
  // writes whose target the compiler cannot see, so the propagation is emitted only
  // when the declaring scope marks the name annotated.
  let checked = emitLocatedError(emitCallRegs("__check_binding", [value, ty, text]), target, false);
  // Guard the lookup: indexing an object with a missing key yields an Error, and
  // that Error would propagate through the comparison and make the condition an
  // Error value rather than a boolean.
  let annotatedHere = false;
  let declaringScope = hit.scope;
  if !isError(declaringScope.annotated) {
    let flag = declaringScope.annotated[name];
    if !isError(flag) && flag == true { annotatedHere = true; };
  };
  if annotatedHere { emitPropagateError(checked); };
  line("  store %ql_value " + checked + ", ptr " + off); line("  br label %" + done);
  line(plain + ":"); curLbl = plain;
  line("  store %ql_value " + value + ", ptr " + off); line("  br label %" + done);
  line(done + ":"); curLbl = done;
};

// Assignment evaluates the RHS first, then the receiver and index once.
// Errors in the destination or setter leave the current function/module.
let emitAssignStmt = (node) -> {
  if node.target.type == "IndexAccess" || node.target.type == "MemberAccess" {
    let V = emitExpr(node.value);
    let O = emitExpr(node.target.object);
    if !inRuntime { emitPropagateError(O); };
    let result = null;
    if node.target.type == "IndexAccess" {
      let I = emitExpr(node.target.index);
      if !inRuntime { emitPropagateError(I); };
      result = emitCallRegs("__set_index", [O, I, V]);
    } else {
      result = emitCallRegs("__set_field", [O, internString(node.target.field), V]);
    };
    if !inRuntime { emitPropagateError(emitLocatedError(result, node.target, false)); };
  } else {
    emitStoreByName(node.target.name, node.value, node.target, if isError(node.declaredType) { ""; } else { node.declaredType });
  };
};

// ---- 函数/闭包 emit(Task 7,R10-a/b/c/i) ----
// Closure: tag@0, code@8, env@16, arity@24, policy@32, name@40, annotations@56 (72 bytes).
// ABI: %ql_value @ql_fn<N>(ptr env, ptr args, i64 argc, %ql_value annotations).
// The environment is captured by reference; args points to 16-byte values.
// Function frame: 16-byte header followed by 64-byte value/type/text/presence slots.
// R10-c:函数体写独立 fnBlocks 元素;闭包盒指令写回调用方当前块。R10-i:调用方必须先
// defineSlot(name)(emitLetStmt 的 Function 分支负责),函数体里同名标识符沿 parent 链
// depth 1 命中全局帧 → 递归成立。
let emitFunction = (node, name) -> {
  let isModule = !isError(node.moduleBody) && node.moduleBody;
  if isModule && !isError(moduleFactories[node.modulePath]) {
    return emitClosure(moduleFactories[node.modulePath], curEnv, 0, emitNull());
  };
  let captured = []; let hasAnnotations = false; let ai = 0;
  while ai < node.parameters.length {
    let ann = node.parameters[ai].annotation;
    if ann != null {
      let ty = emitExpr(ann);
      captured[captured.length] = emitArrayRegs([ty, internString(annotationText(ann))]);
      hasAnnotations = true;
    } else { captured[captured.length] = emitNull(); };
    ai = ai + 1;
  };
  let annotations = emitNull();
  if hasAnnotations { annotations = emitArrayRegs(captured); };
  if name != "" { curScope.active[name] = true; };
  let fname = "ql_fn" + std.String.toString(funcCounter);
  funcCounter = funcCounter + 1;
  if isModule { moduleFactories[node.modulePath] = fname; };
  let savedScope = curScope;
  let savedEnv = curEnv;
  let savedLbl = curLbl;
  let savedSink = curSink;
  let savedExports = moduleExportsReg;
  let savedStackSlots = stackSlots; stackSlots = [];
  let savedArgSlots = argSlotPool; argSlotPool = {};
  // 函数体作用域 = 新空作用域,parent = 定义处作用域(闭包环境链的编译期镜像)。
  curScope = { slots: {}, active: {}, parent: savedScope, isFunction: false };
  curScope.isFunction = true;
  // 预扫:参数槽 0..k-1,函数体顶层 let 槽 k..n-1(幂等 defineSlot → 函数体 emit 对同一
  // 名字按已绑定走 emitStoreByName,槽号一致)。
  let k = node.parameters.length;
  let p = 0;
  while p < k {
    defineSlot(node.parameters[p].name);
    curScope.active[node.parameters[p].name] = true;
    p = p + 1;
  };
  reserveModuleBindings(node.body.statements);
  if isModule { reserveModuleGlobals(); };
  let n = std.Object.keys(curScope.slots).length;
  let blk = [];
  curSink = blk;
  line("define internal %ql_value @" + fname + "(ptr %env, ptr %args, i64 %argc, %ql_value %annotations) {");
  line("entry:");
  line(""); // Filled after emission with fixed entry-block stack slots.
  curLbl = "entry";
  let localFrame = !lifetimeMayCapture(node.body.statements);
  let f = emitFrame("%env", n, localFrame);
  curEnv = f;
  let a = 0;
  while a < k {
    let ro = temp(); let rv = temp();
    line("  " + ro + " = getelementptr %ql_value, ptr %args, i64 " + std.String.toString(a));
    line("  " + rv + " = load %ql_value, ptr " + ro);
    let off = temp();
    let slot = curScope.slots[node.parameters[a].name];
    line("  " + off + " = getelementptr i8, ptr " + f + ", i64 " + std.String.toString(16 + 64 * slot));
    let ty = "null"; let text = "null";
    if node.parameters[a].annotation != null {
      let entry = emitCallRegs("__get_index", ["%annotations", emitNumber({ value: a })]);
      ty = emitCallRegs("__get_index", [entry, emitNumber({value: 0})]);
      text = emitCallRegs("__get_index", [entry, emitNumber({value: 1})]);
    };
    emitBindingStore(off, rv, ty, text);
    if !isError(node.parameters[a].unboxType) && node.parameters[a].unboxType == "Number" {
      if isError(curScope.unbox) { curScope.unbox = {}; };
      curScope.unbox[node.parameters[a].name] = true;
    };
    a = a + 1;
  };
  // M3 T3:epilogue —— %retv alloca 在 entry 分配;body 末 store + br;? 的 prop 分支同样 store 后 br。
  let rv = temp();
  line("  " + rv + " = alloca %ql_value");
  let lEpi = lbl();
  let savedRetv = curRetv; let savedEpi = curEpiLbl; let savedTop = isTopLevel;
  let savedRetType = curReturnType; let savedRetTy = curReturnTy; let savedRetText = curReturnText;
  let savedRetActive = curReturnActive;
  curRetv = rv; curEpiLbl = lEpi; isTopLevel = false;
  // 作者声明的返回类型:在入口块求一次类型值,返回边的检查才支配所有返回点。若推导交集
  // 与声明的内建类型一致(每条路径都返回它),整条函数不需要任何检查。
  curReturnActive = false; curReturnType = ""; curReturnTy = "null"; curReturnText = "null";
  if !inRuntime && !isError(node.returnTypeAnnotation) && node.returnTypeAnnotation != null {
    let proven = false;
    if !isError(node.declaredReturnType) && node.declaredReturnType != ""
       && !isError(node.derivedReturnType) && node.declaredReturnType == node.derivedReturnType { proven = true; };
    if !proven {
      curReturnActive = true;
      curReturnType = if isError(node.declaredReturnType) { ""; } else { node.declaredReturnType; };
      curReturnTy = emitExpr(node.returnTypeAnnotation);
      curReturnText = internString(annotationText(node.returnTypeAnnotation));
    };
  };
  // 函数体:R10-a 语句级 last-value 语义 —— emitBlockStmts 返回最后值寄存器;函数结果 =
  // 函数体最后值(恒有值,默认 null 值)。
  if isModule {
    emitSetModuleLoading(node.modulePath, true);
    emitModuleStd();
    moduleExportsReg = emitObjectExpr({ fields: [] });
    let exportsOff = emitBindingPtr({depth: 0, slot: curScope.slots["$exports"]});
    emitBindingStore(exportsOff, moduleExportsReg, "null", "null");
  };
  let bodyLast = emitBlockStmts(node.body.statements);
  let bl = bodyLast;
  if bl == null {
    bl = emitNull();
  };
  if isModule {
    let tag = temp(); let failed = temp(); let result = temp();
    line("  " + tag + " = call i64 @ql_tag(%ql_value " + bl + ")");
    line("  " + failed + " = icmp eq i64 " + tag + ", 8");
    line("  " + result + " = select i1 " + failed + ", %ql_value " + bl + ", %ql_value " + moduleExportsReg);
    bl = result;
  };
  bl = emitReturnCheck(bl, node);
  line("  store %ql_value " + bl + ", ptr " + rv);
  line("  br label %" + lEpi);
  line(lEpi + ":");
  let rv2 = temp();
  line("  " + rv2 + " = load %ql_value, ptr " + rv);
  if isModule { emitSetModuleLoading(node.modulePath, false); };
  if localFrame { line("  call void @llvm.lifetime.end.p0(i64 " + std.String.toString(16 + 64 * n) + ", ptr " + f + ")"); };
  line("  ret %ql_value " + rv2);
  line("}");
  curRetv = savedRetv; curEpiLbl = savedEpi; isTopLevel = savedTop;
  curReturnType = savedRetType; curReturnTy = savedRetTy; curReturnText = savedRetText; curReturnActive = savedRetActive;
  blk[2] = stackEntry();
  stackSlots = savedStackSlots;
  argSlotPool = savedArgSlots;
  fnBlocks[fnBlocks.length] = blk;
  // Its body is defined from here on: later calls to it may be direct.
  if name != "" && !isError(runtimeFunctions[name]) { runtimeFnIr[name] = fname; };
  // ②a 补充量测:登记用户函数「已发出」与「声明返回 Number」,供发射序折扣统计。
  if name != "" && isError(runtimeFunctions[name]) {
    ordFnEmitted[name] = true;
    ordFnRetNum[name] = !isError(node.declaredReturnType) && node.declaredReturnType == "Number";
  };
  // 恢复调用方上下文;闭包盒指令写回调用方当前块/当前 sink。
  moduleExportsReg = savedExports;
  curSink = savedSink;
  curScope = savedScope;
  curEnv = savedEnv;
  curLbl = savedLbl;
  if isModule { moduleFactories[node.modulePath] = fname; };
  emitClosure(fname, savedEnv, k, annotations);
};

let emitClosure = (fname, env, arity, annotations) -> {
  // 闭包盒:tag 7 @0、code @8、env @16(定义时刻环境帧)。
  let c = temp();
  line("  " + c + " = call ptr @ql_alloc(i64 72)");
  line("  store i64 7, ptr " + c);
  let cp = temp();
  line("  " + cp + " = getelementptr i8, ptr " + c + ", i64 8");
  line("  store ptr @" + fname + ", ptr " + cp);
  let ep = temp();
  line("  " + ep + " = getelementptr i8, ptr " + c + ", i64 16");
  line("  store ptr " + env + ", ptr " + ep);
  let ap = temp(); let mp = temp(); let np = temp();
  line("  " + ap + " = getelementptr i8, ptr " + c + ", i64 24");
  line("  store i64 " + std.String.toString(arity) + ", ptr " + ap);
  line("  " + mp + " = getelementptr i8, ptr " + c + ", i64 32");
  let mode = if inRuntime { "1"; } else { "0"; };
  line("  store i64 " + mode + ", ptr " + mp);
  line("  " + np + " = getelementptr i8, ptr " + c + ", i64 40");
  line("  store %ql_value " + internString("") + ", ptr " + np);
  let annp = temp();
  line("  " + annp + " = getelementptr i8, ptr " + c + ", i64 56");
  line("  store %ql_value " + annotations + ", ptr " + annp);
  emitPointerValue(c);
};

// ---- 控制流语句 emit(Task 6 + Task 7 语句级 last-value)----
// 语句分派(Let 之外的所有语句类型):顶层与分支块共用;返回该语句产生的「最后值」寄存器
// (R10-a):Assign/While → null(不改 last);If → 所走分支体最后值的 phi(见 emitIfStmt);
// 裸表达式语句/Call → emitExpr 结果。prevLast = 本块此前语句的最后值寄存器(或 null),
// 传给 emitIfStmt 用于「无 else 且条件假 → 不改 last」的 phi 路径。
// R10-e:print/println 特例已删 —— 走 emitCall 通用用户函数调用(runtime.ql 顶层函数)。
let emitStmtDispatch = (node, prevLast) -> {
  if node.type == "Return" {
    let value = emitExpr(node.value);
    if isTopLevel {
      addCompileError(node, "top-level return is not supported");
    } else {
      value = emitReturnCheck(value, node.value);
      line("  store %ql_value " + value + ", ptr " + curRetv);
      line("  br label %" + curEpiLbl);
      // Continue emitting into an unreachable block so enclosing CFG builders
      // still have a valid insertion point and phi predecessor.
      let next = lbl();
      line(next + ":"); curLbl = next;
    };
    null;
  } else if node.type == "Export" {
    emitExport(node);
    null;
  } else if node.type == "Assign" {
    emitAssignStmt(node);
    null;
  } else if node.type == "If" {
    emitIfStmt(node, prevLast);
  } else if node.type == "While" {
    emitWhileStmt(node);
    null;
  } else {
    // 表达式语句(Call/BinaryOp/Identifier 等):求值,返回值作为本块 last。
    emitExpr(node);
  };
};

// Branches and loop iterations have their own lexical environment. Allocate
// at block entry so escaping closures retain the correct iteration's bindings.
let emitScopedBlock = (stmts) -> {
  let savedScope = curScope;
  let savedEnv = curEnv;
  curScope = { slots: {}, active: {}, parent: savedScope, isFunction: false };
  reserveModuleBindings(stmts);
  let n = std.Object.keys(curScope.slots).length;
  let result = null;
  if n == 0 {
    // An empty lexical frame cannot shadow a name; elide it entirely.
    curScope = savedScope;
    result = emitBlockStmts(stmts);
  } else {
    let localFrame = !lifetimeMayCapture(stmts);
    let frame = emitFrame(savedEnv, n, localFrame);
    curEnv = frame;
    result = emitBlockStmts(stmts);
    if localFrame { line("  call void @llvm.lifetime.end.p0(i64 " + std.String.toString(16 + 64 * n) + ", ptr " + frame + ")"); };
  };
  curScope = savedScope;
  curEnv = savedEnv;
  result;
};

// Statements within an already allocated environment.
let emitBlockStmts = (stmts) -> {
  let last = null;
  let i = 0;
  while i < stmts.length {
    let s = stmts[i];
    if s.type == "Let" {
      emitLetStmt(s);
    } else {
      let v = emitStmtDispatch(s, last);
      if v != null { last = v; };
    };
    i = i + 1;
  };
  last;
};

// If:实测形状 {type:"If", branches:[IfBranch], elseBody};IfBranch = {condition, body:Block}。
// Remaining else-if branches are lowered recursively. Each body owns a lexical frame.
// Executed empty branches return Void (represented by the null value). Only a
// false condition without an else preserves the preceding statement value.
// phi 前驱用 curLbl(emit 分支体后 br label %lEnd 的实际发出块)而非硬编码 lThen/lElse:
// 分支体内嵌套 if/while 会再产块,硬编码前驱将得 "PHI node entries do not match predecessors!"
// (Task 6 Fix Round 1 同类问题的推广)。
let emitIfStmt = (node, prevLast) -> {
  let br = node.branches[0];
  // 条件若是裸 i1(分析期已判定),直接 br —— 省掉 zext+pack+ql_truthy。
  let cv = emitValue(br.condition);
  let tr = temp();
  if cv.raw == "Boolean" { tr = cv.reg; }
  else { line("  " + tr + " = call i1 @ql_truthy(%ql_value " + cv.reg + ")"); };
  let lThen = lbl(); let lElse = lbl(); let lEnd = lbl();
  line("  br i1 " + tr + ", label %" + lThen + ", label %" + lElse);
  line(lThen + ":");
  curLbl = lThen;
  let tv = emitScopedBlock(br.body.statements);
  let thenIn = tv;
  if thenIn == null { thenIn = emitNull(); };
  let thenLbl = curLbl;
  line("  br label %" + lEnd);
  line(lElse + ":");
  curLbl = lElse;
  let ev = null;
  if node.branches.length > 1 {
    let rest = [];
    let j = 1;
    while j < node.branches.length {
      rest[rest.length] = node.branches[j];
      j = j + 1;
    };
    ev = emitIfStmt({ type: "If", branches: rest, elseBody: node.elseBody }, prevLast);
  } else {
    if node.elseBody != null {
      ev = emitScopedBlock(node.elseBody.statements);
    };
  };
  let elseIn = ev;
  if elseIn == null {
    if node.elseBody == null && prevLast != null { elseIn = prevLast; }
    else { elseIn = emitNull(); };
  };
  let elseLbl = curLbl;
  line("  br label %" + lEnd);
  line(lEnd + ":");
  curLbl = lEnd;
  let res = temp();
  line("  " + res + " = phi %ql_value [ " + thenIn + ", %" + thenLbl + " ], [ " + elseIn + ", %" + elseLbl + " ]");
  res;
};

// While:实测形状 {type:"While", condition, body:Block}。
let emitWhileStmt = (node) -> {
  let lCond = lbl(); let lBody = lbl(); let lExit = lbl();
  line("  br label %" + lCond);
  line(lCond + ":");
  curLbl = lCond;
  let cv = emitValue(node.condition);
  let tr = temp();
  if cv.raw == "Boolean" { tr = cv.reg; }
  else { line("  " + tr + " = call i1 @ql_truthy(%ql_value " + cv.reg + ")"); };
  line("  br i1 " + tr + ", label %" + lBody + ", label %" + lExit);
  line(lBody + ":");
  curLbl = lBody;
  emitScopedBlock(node.body.statements);
  line("  br label %" + lCond);
  line(lExit + ":");
  curLbl = lExit;
};

// 盒值 → iN 整数(解盒 f64 → fptosi i64 → 可选 trunc)。叶子参数的位置型强转(R10-g):
// runtime.ql 纪律 —— 数字位(size/off/len/byte)传盒值,指针位(p/buf)传 raw ptr,故按位置强制。
let emitInt = (value, width) -> {
  let number = emitFloat(value); let integer = temp();
  line("  " + integer + " = fptosi double " + number + " to i64");
  if width == "i64" { return integer; };
  let result = temp(); line("  " + result + " = trunc i64 " + integer + " to " + width);
  result;
};

// Calls from user code always dispatch through __call. Trusted runtime code
// may call known internal functions directly, and alone may use raw leaf or
// __invoke/__same_ptr intrinsics. User-selected names do not grant exemptions.
// emitCallRegs(fname, argRegs):给定 callee 名与已计算的参数寄存器,构造 args 数组并调用。
// runtime.ql 函数是顶层 let → 全局帧槽 → emitIdentifier(fname) 解析成功。
// A direct call to an already-defined runtime function: same frame/closure as the
// boxed form, but the code address is known, so no pointer load and no indirect
// branch. Arguments still go through the ordinary buffer.
let emitDirectCall = (irName, name, argRegs) -> {
  let FN = emitIdentifier({ type: "Identifier", name: name, internal: true });
  let pointer = emitPointer(FN);
  let ep = temp(); let env = temp(); let ap = temp(); let annotations = temp();
  line("  " + ep + " = getelementptr i8, ptr " + pointer + ", i64 16");
  line("  " + env + " = load ptr, ptr " + ep);
  line("  " + ap + " = getelementptr i8, ptr " + pointer + ", i64 56");
  line("  " + annotations + " = load %ql_value, ptr " + ap);
  let narg = argRegs.length;
  let bytes = if narg == 0 { 1 } else { 16 * narg };
  let arr = argSlot(bytes);
  line("  call void @llvm.lifetime.start.p0(i64 " + std.String.toString(bytes) + ", ptr " + arr + ")");
  let i = 0;
  while i < narg {
    let aoff = temp();
    line("  " + aoff + " = getelementptr %ql_value, ptr " + arr + ", i64 " + std.String.toString(i));
    line("  store %ql_value " + argRegs[i] + ", ptr " + aoff);
    i = i + 1;
  };
  let r = temp();
  line("  " + r + " = call %ql_value @" + irName + "(ptr " + env + ", ptr " + arr + ", i64 " + std.String.toString(narg) + ", %ql_value " + annotations + ")");
  line("  call void @llvm.lifetime.end.p0(i64 " + std.String.toString(bytes) + ", ptr " + arr + ")");
  r;
};
let emitCallRegs = (fname, argRegs) -> {
  // NOTE(deviation from brief): emitIdentifier 现签名取 Identifier 节点(读 node.name),
  // 直接传字符串会访问 "str".name → host Error → lookupSlot miss → null 值(运行期 call null 崩溃)。
  // 构造节点保持 brief 其余部分逐字不变。Task 7/8 复用同一 emitCallRegs(fname 字符串)调用形式。
  let ir = runtimeFnIr[fname];
  let rebound = assignedRuntime[fname];
  if !isError(ir) && isError(rebound) && !inColdHelper { return emitDirectCall(ir, fname, argRegs); };
  let FN = emitIdentifier({ type: "Identifier", name: fname, internal: true });
  emitInvokeRegs(FN, argRegs);
};

// Raw arguments are copied into callee bindings; their buffer never escapes.
let emitInvokeRegs = (FN, argRegs) -> {
  let narg = argRegs.length;
  // The invocation ABI copies argument values, never retains this raw buffer.
  let bytes = if narg == 0 { 1 } else { 16 * narg };
  let arr = argSlot(bytes);
  line("  call void @llvm.lifetime.start.p0(i64 " + std.String.toString(bytes) + ", ptr " + arr + ")");
  let i = 0;
  while i < narg {
    let aoff = temp();
    line("  " + aoff + " = getelementptr %ql_value, ptr " + arr + ", i64 " + std.String.toString(i));
    line("  store %ql_value " + argRegs[i] + ", ptr " + aoff);
    i = i + 1;
  };
  let result = emitInvoke(FN, arr, std.String.toString(narg));
  line("  call void @llvm.lifetime.end.p0(i64 " + std.String.toString(bytes) + ", ptr " + arr + ")");
  result;
};

// Only __call_borrowed may borrow this Array descriptor. It never exposes the descriptor
// to a user function; __partial copies arguments before capturing them.
let emitBorrowedCall = (fn, values, exempt) -> {
  let bytes = 32 + 16 * values.length;
  let storage = stackSlot(bytes); let data = temp();
  line("  call void @llvm.lifetime.start.p0(i64 " + std.String.toString(bytes) + ", ptr " + storage + ")");
  line("  store i64 5, ptr " + storage);
  line("  " + data + " = getelementptr i8, ptr " + storage + ", i64 32");
  let bp = temp(); let np = temp(); let cp = temp();
  line("  " + bp + " = getelementptr i8, ptr " + storage + ", i64 8");
  line("  store ptr " + data + ", ptr " + bp);
  line("  " + np + " = getelementptr i8, ptr " + storage + ", i64 16");
  line("  store i64 " + std.String.toString(values.length) + ", ptr " + np);
  line("  " + cp + " = getelementptr i8, ptr " + storage + ", i64 24");
  line("  store i64 " + std.String.toString(values.length) + ", ptr " + cp);
  let i = 0;
  while i < values.length {
    let off = temp();
    line("  " + off + " = getelementptr %ql_value, ptr " + data + ", i64 " + std.String.toString(i));
    line("  store %ql_value " + values[i] + ", ptr " + off);
    i = i + 1;
  };
  let result = emitCallRegs("__call_borrowed", [fn, emitPointerValue(storage), exempt]);
  line("  call void @llvm.lifetime.end.p0(i64 " + std.String.toString(bytes) + ", ptr " + storage + ")");
  result;
};

let emitCall = (node) -> {
  let calleeIsId = node.callee.type == "Identifier";
  let cname = if calleeIsId { node.callee.name } else { "" };
  let leaf = inRuntime && calleeIsId && (cname == "ql_alloc" || cname == "ql_write" || cname == "ql_mem_get" || cname == "ql_mem_store" || cname == "ql_mem_get_ptr" || cname == "ql_mem_store_ptr" || cname == "ql_value_get" || cname == "ql_value_store" || cname == "ql_integer_rem" || cname == "ql_number_bits" || cname == "ql_exit" || cname == "ql_openat" || cname == "ql_read" || cname == "ql_close" || cname == "ql_readlinkat" || cname == "ql_getrandom" || cname == "ql_extension_open");
  if inRuntime && (cname == "readU64" || cname == "writeU64") && lookupSlot(cname).scope == runtimeScope {
    let value = emitExpr(node.arguments[0]);
    let offset = emitInt(emitExpr(node.arguments[1]), "i64");
    if cname == "readU64" {
      let word = temp(); let number = temp();
      line("  " + word + " = call i64 @ql_word(%ql_value " + value + ", i64 " + offset + ")");
      line("  " + number + " = uitofp i64 " + word + " to double");
      return emitFloatValue(number);
    };
    let v = emitFloat(emitExpr(node.arguments[2])); let word = temp();
    let pointer = emitPointer(value); let address = temp();
    line("  " + word + " = fptoui double " + v + " to i64");
    line("  " + address + " = getelementptr i8, ptr " + pointer + ", i64 " + offset);
    line("  store i64 " + word + ", ptr " + address + ", align 1");
    return emitNull();
  };
  if inRuntime && cname == "__extension_enter" {
    let entry = emitPointer(emitExpr(node.arguments[0]));
    let env = emitPointer(emitExpr(node.arguments[1])); let result = temp();
    line("  " + result + " = call %ql_value " + entry + "(ptr " + env + ")");
    return result;
  };
  if inRuntime && cname == "__invoke" {
    let fn = emitExpr(node.arguments[0]);
    if node.arguments[1].type == "Array" {
      let values = []; let i = 0;
      while i < node.arguments[1].elements.length { values.add(emitExpr(node.arguments[1].elements[i])); i = i + 1; };
      return emitInvokeRegs(fn, values);
    };
    let args = emitExpr(node.arguments[1]);
    let pointer = emitPointer(args); let bp = temp(); let buf = temp(); let np = temp(); let n = temp();
    line("  " + bp + " = getelementptr i8, ptr " + pointer + ", i64 8");
    line("  " + buf + " = load ptr, ptr " + bp);
    line("  " + np + " = getelementptr i8, ptr " + pointer + ", i64 16");
    line("  " + n + " = load i64, ptr " + np);
    return emitInvoke(fn, buf, n);
  };
  if inRuntime && cname == "__same_ptr" {
    let a = emitBits(emitExpr(node.arguments[0])); let b = emitBits(emitExpr(node.arguments[1])); let eq = temp();
    line("  " + eq + " = icmp eq i64 " + a + ", " + b);
    return emitBoolResult(eq);
  };
  // Literal argument lists in the trusted dispatcher (e.g. annotation checks)
  // have the same borrowing contract as a compiler-generated user call.
  if inRuntime && cname == "__call_borrowed" && lookupSlot(cname).scope == runtimeScope && node.arguments[1].type == "Array" {
    let fn = emitExpr(node.arguments[0]); let values = []; let i = 0;
    while i < node.arguments[1].elements.length { values.add(emitExpr(node.arguments[1].elements[i])); i = i + 1; };
    let exempt = emitExpr(node.arguments[2]);
    return emitBorrowedCall(fn, values, exempt);
  };
  if leaf {
    // Evaluate all expressions once, before lowering raw ABI arguments.
    let values = []; let i = 0;
    while i < node.arguments.length { values.add(emitExpr(node.arguments[i])); i = i + 1; };
    if cname == "ql_integer_rem" {
      let a = emitInt(values[0], "i64"); let b = emitInt(values[1], "i64"); let r = temp(); let number = temp();
      line("  " + r + " = urem i64 " + a + ", " + b);
      line("  " + number + " = uitofp i64 " + r + " to double");
      return emitFloatValue(number);
    };
    if cname == "ql_number_bits" {
      let mantissa = emitInt(values[0], "i64"); let exponent = emitInt(values[1], "i64");
      let sign = temp(); let wide = temp(); let hi = temp(); let low = temp(); let bits = temp(); let shifted = temp();
      line("  " + sign + " = call i1 @ql_truthy(%ql_value " + values[2] + ")");
      line("  " + wide + " = zext i1 " + sign + " to i64");
      line("  " + hi + " = shl i64 " + wide + ", 63");
      line("  " + shifted + " = shl i64 " + exponent + ", 52");
      line("  " + low + " = or i64 " + mantissa + ", " + shifted);
      line("  " + bits + " = or i64 " + hi + ", " + low);
      return emitPack("1", bits);
    };
    if cname == "ql_mem_get" {
      let offset = emitInt(values[1], "i64"); let byte = temp(); let number = temp();
      line("  " + byte + " = call i8 @ql_byte(%ql_value " + values[0] + ", i64 " + offset + ")");
      line("  " + number + " = uitofp i8 " + byte + " to double");
      return emitFloatValue(number);
    };
    if cname == "ql_value_get" || cname == "ql_value_store" {
      let pointer = emitPointer(values[0]); let offset = emitInt(values[1], "i64"); let address = temp();
      line("  " + address + " = getelementptr i8, ptr " + pointer + ", i64 " + offset);
      if cname == "ql_value_get" {
        let result = temp(); line("  " + result + " = load %ql_value, ptr " + address + ", align 8"); return result;
      };
      line("  store %ql_value " + values[2] + ", ptr " + address + ", align 8"); return emitNull();
    };
    let signature = []; let resultType = "void";
    if cname == "ql_alloc" { signature = ["i64"]; resultType = "ptr"; }
    else if cname == "ql_write" { signature = ["i32", "ptr", "i64"]; }
    else if cname == "ql_mem_store" { signature = ["ptr", "i64", "i8"]; }
    else if cname == "ql_mem_get_ptr" { signature = ["ptr", "i64"]; resultType = "ptr"; }
    else if cname == "ql_mem_store_ptr" { signature = ["ptr", "i64", "ptr"]; }
    else if cname == "ql_exit" { signature = ["i32"]; }
    else if cname == "ql_openat" { signature = ["i64", "ptr", "i64"]; resultType = "i64"; }
    else if cname == "ql_read" { signature = ["i64", "ptr", "i64"]; resultType = "i64"; }
    else if cname == "ql_getrandom" { signature = ["ptr", "i64"]; resultType = "i64"; }
    else if cname == "ql_extension_open" { signature = ["ptr", "ptr", "ptr"]; resultType = "ptr"; }
    else if cname == "ql_close" { signature = ["i64"]; resultType = "i64"; }
    else if cname == "ql_readlinkat" { signature = ["i64", "ptr", "ptr", "i64"]; resultType = "i64"; };
    let arguments = ""; i = 0;
    while i < signature.length {
      let value = if signature[i] == "ptr" { emitPointer(values[i]) } else { emitInt(values[i], signature[i]) };
      if i > 0 { arguments = arguments + ", "; };
      arguments = arguments + signature[i] + " " + value; i = i + 1;
    };
    if resultType == "void" { line("  call void @" + cname + "(" + arguments + ")"); return emitNull(); };
    let result = temp(); line("  " + result + " = call " + resultType + " @" + cname + "(" + arguments + ")");
    if resultType == "ptr" { return emitPointerValue(result); };
    let number = temp(); line("  " + number + " = sitofp i64 " + result + " to double");
    return emitFloatValue(number);
  };
  let FN = emitExpr(node.callee); let values = []; let i = 0;
  while i < node.arguments.length { values.add(emitExpr(node.arguments[i])); i = i + 1; };
  // ②a 补充量测:这个用户调用点能不能在发射序上变成直接调用(⇒ 才能吃裸签名)。
  if calleeIsId && isError(runtimeFunctions[cname]) {
    ordCallsTotal = ordCallsTotal + 1;
    if !isError(ordFnEmitted[cname]) {
      ordCallsEmitted = ordCallsEmitted + 1;
      if ordFnRetNum[cname] == true { ordCallsRetRaw = ordCallsRetRaw + 1; };
    } else { ordCallsNotYet = ordCallsNotYet + 1; };
  };
  let trusted = false;
  if inRuntime && calleeIsId && !isError(runtimeFunctions[cname]) {
    let hit = lookupSlot(cname); trusted = hit != null && hit.scope == globalScope;
  };
  if trusted { emitCallRegs(cname, values); }
  else { emitBorrowedCall(FN, values, emitBoolean({value: false})); };
};

// Only compiler-generated calls and runtime intrinsics bypass __call.
let emitInvoke = (FN, arr, argc) -> {
  let pointer = emitPointer(FN);
  let cp = temp(); let code = temp(); let ep = temp(); let env = temp(); let r = temp();
  line("  " + cp + " = getelementptr i8, ptr " + pointer + ", i64 8");
  line("  " + code + " = load ptr, ptr " + cp);
  line("  " + ep + " = getelementptr i8, ptr " + pointer + ", i64 16");
  line("  " + env + " = load ptr, ptr " + ep);
  let ap = temp(); let annotations = temp();
  line("  " + ap + " = getelementptr i8, ptr " + pointer + ", i64 56");
  line("  " + annotations + " = load %ql_value, ptr " + ap);
  line("  " + r + " = call %ql_value " + code + "(ptr " + env + ", ptr " + arr + ", i64 " + argc + ", %ql_value " + annotations + ")");
  r;
};
let emitArrayRegs = (values) -> {
  let box = temp(); let data = temp(); let bp = temp(); let np = temp();
  line("  " + box + " = call ptr @ql_alloc(i64 32)");
  line("  store i64 5, ptr " + box);
  line("  " + data + " = call ptr @ql_alloc(i64 " + std.String.toString(values.length * 16) + ")");
  let i = 0;
  while i < values.length {
    let off = temp();
    line("  " + off + " = getelementptr %ql_value, ptr " + data + ", i64 " + std.String.toString(i));
    line("  store %ql_value " + values[i] + ", ptr " + off);
    i = i + 1;
  };
  line("  " + bp + " = getelementptr i8, ptr " + box + ", i64 8");
  line("  store ptr " + data + ", ptr " + bp);
  line("  " + np + " = getelementptr i8, ptr " + box + ", i64 16");
  line("  store i64 " + std.String.toString(values.length) + ", ptr " + np);
  let capacity = temp();
  line("  " + capacity + " = getelementptr i8, ptr " + box + ", i64 24");
  line("  store i64 " + std.String.toString(values.length) + ", ptr " + capacity);
  emitPointerValue(box);
};

// 数组字面量(tag 5 盒,R10-e):@0 tag=5,@8 元素数组 ptr,@16 长度 i64,@24 容量 i64。
// 元素数组 = call ptr @ql_alloc(i64 8*n),每元素 GEP+store(盒/raw ptr 一律 ptr 型)。
let emitArrayExpr = (node) -> {
  let b = temp();
  line("  " + b + " = call ptr @ql_alloc(i64 32)");
  line("  store i64 5, ptr " + b);                    // tag ARRAY
  let n = node.elements.length;
  let els = temp();
  line("  " + els + " = call ptr @ql_alloc(i64 " + std.String.toString(16 * n) + ")");
  let eoff = temp();
  line("  " + eoff + " = getelementptr i8, ptr " + b + ", i64 8");
  line("  store ptr " + els + ", ptr " + eoff);
  let i = 0;
  while i < n {
    let v = emitExpr(node.elements[i]);
    let aoff = temp();
    line("  " + aoff + " = getelementptr %ql_value, ptr " + els + ", i64 " + std.String.toString(i));
    line("  store %ql_value " + v + ", ptr " + aoff);
    i = i + 1;
  };
  let loff = temp();
  line("  " + loff + " = getelementptr i8, ptr " + b + ", i64 16");
  line("  store i64 " + std.String.toString(n) + ", ptr " + loff);
  let capacity = temp();
  line("  " + capacity + " = getelementptr i8, ptr " + b + ", i64 24");
  line("  store i64 " + std.String.toString(n) + ", ptr " + capacity);
  emitPointerValue(b);
};

let emitObjectExpr = (node) -> {
  let o = emitCallRegs("__obj_new", []);
  let i = 0;
  while i < node.fields.length {
    let f = node.fields[i];
    let V = emitExpr(f.value);
    let key = internString(f.name);
    emitCallRegs("__obj_set", [o, key, V]);
    i = i + 1;
  };
  o;
};

let emitMemberAccess = (node) -> {
  let O = emitExpr(node.object);
  if node.field == "length" {
    let k = internString("length");
    emitCallRegs("__get_length", [O, k]);
  } else {
    let k = internString(node.field);
    emitCallRegs("__get_field", [O, k]);
  };
};

// The frame that holds the runtime bindings, as seen from the current position:
// walk the environment's parent chain once per compile-time scope level between
// curScope and runtimeScope. This is the base the private helper indexes into.
let emitRuntimeBase = () -> {
  let scope = curScope; let depth = 0;
  while scope != runtimeScope { scope = scope.parent; depth = depth + 1; };
  let base = curEnv;
  let i = 0;
  while i < depth { let p = temp(); line("  " + p + " = load ptr, ptr " + base); base = p; i = i + 1; };
  base;
};
// The cold half of emitLocatedError, as a private function with an ordinary ABI
// (values in registers, no frame buffer). Returns its lines; the caller splices
// them in ahead of every use site. Its environment argument is the runtime frame,
// so the lookup inside is depth 0 against runtimeScope.
let emitColdLocatedHelper = () -> {
  let savedStackSlots = stackSlots; stackSlots = [];
  let savedArgSlots = argSlotPool; argSlotPool = {};
  let savedScope = curScope; let savedEnv = curEnv; let savedLbl = curLbl;
  let savedTop = isTopLevel; let savedRetv = curRetv; let savedEpi = curEpiLbl;
  let savedRetType = curReturnType; let savedRetTy = curReturnTy; let savedRetText = curReturnText;
  let savedRetActive = curReturnActive;
  curReturnType = ""; curReturnTy = "null"; curReturnText = "null"; curReturnActive = false;
  let blk = [];
  curSink = blk;
  line("define %ql_value @__cold_located_error(ptr %env, %ql_value %v, %ql_value %file, %ql_value %line, %ql_value %col, %ql_value %cf) {");
  line("entry:");
  let slotAt = blk.length; line("");
  curLbl = "entry";
  curEnv = "%env";
  curScope = runtimeScope;
  inColdHelper = true;
  isTopLevel = false; curRetv = "%retv"; curEpiLbl = "epilogue";
  let located = emitCallRegs("__err_at", ["%v", "%file", "%line", "%col", "%cf"]);
  line("  ret %ql_value " + located);
  line("}");
  blk[slotAt] = stackEntry();
  inColdHelper = false;
  stackSlots = savedStackSlots; argSlotPool = savedArgSlots;
  curScope = savedScope; curEnv = savedEnv; curLbl = savedLbl;
  isTopLevel = savedTop; curRetv = savedRetv; curEpiLbl = savedEpi;
  curReturnType = savedRetType; curReturnTy = savedRetTy; curReturnText = savedRetText; curReturnActive = savedRetActive;
  blk;
};
// Attach provenance only on an Error edge. Synthetic/runtime nodes have no
// user position. Calls/imports extend a persistent trace; ordinary reads do not.
let emitLocatedError = (value, node, callFrame) -> {
  if inRuntime || isError(node.location) { return value; };
  let point = node.location;
  needColdLocated = true;
  let siteEnv = emitRuntimeBase();
  let tag = temp(); let error = temp(); let bad = lbl(); let good = lbl(); let done = lbl();
  line("  " + tag + " = call i64 @ql_tag(%ql_value " + value + ")");
  line("  " + error + " = icmp eq i64 " + tag + ", 8");
  line("  br i1 " + error + ", label %" + bad + ", label %" + good);
  line(bad + ":"); curLbl = bad;
  let located = temp();
  line("  " + located + " = call %ql_value @__cold_located_error(ptr " + siteEnv + ", %ql_value " + value + ", %ql_value " + internString(point.file) + ", %ql_value " + emitNumber({value: point.line}) + ", %ql_value " + emitNumber({value: point.col}) + ", %ql_value " + emitBoolean({value: callFrame}) + ")");
  let failedEnd = curLbl; line("  br label %" + done);
  line(good + ":"); curLbl = good; line("  br label %" + done);
  line(done + ":"); curLbl = done; let result = temp();
  line("  " + result + " = phi %ql_value [ " + located + ", %" + failedEnd + " ], [ " + value + ", %" + good + " ]");
  result;
};
// 声明了返回类型的函数:在返回边检查值确实是该类型。能证明相等时不发 —— 编译期那半已覆盖。
// 检查失败得到的是 TypeCheck 错误,它就是这次调用的返回值,所以调用方看得到。
let emitReturnCheck = (value, valueNode) -> {
  if !curReturnActive { return value; };
  if curReturnType != "" && valueNode != null && !isError(valueNode) && !isError(valueNode.staticType) && valueNode.staticType == curReturnType { return value; };
  emitLocatedError(emitCallRegs("__check_binding", [value, curReturnTy, curReturnText]), valueNode, false);
};
// emitExpr(node) returns an LLVM %ql_value operand (constant or register).
// emitValue 返回 {reg, raw}:raw="" 时 reg 是 %ql_value(既有路径);raw="Number" 时
// reg 是裸 double —— 只出现在编译期已证明类型的绑定上。emitExpr 是它的装箱化薄
// 包装,所以除少数决策点(NodeAnd/unboxing 相关)外,其余调用点无需改动。
// 当前节点分析期算出的自然表示:"" 装箱 / "Number" 裸 double / "Boolean" 裸 i1。
let emitNaturalRep = (node) -> if isError(node.staticRep) { ""; } else { node.staticRep };
let emitRepCmpOp = (op) -> op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" || op == ">=";
// 裸 double 操作数:裸的直接用,装箱的解箱;字面量直接给 LLVM double 常量(零指令)。
let emitRawDouble = (v) -> if v.raw == "Number" { v.reg; } else { emitFloat(v.reg); };
let emitBoxedV = (v) -> if v.raw == "Number" { emitFloatValue(v.reg); } else if v.raw == "Boolean" { emitBoolResult(v.reg); } else { v.reg; };
let emitRawArith = (node) -> {
  let kind = node.type;
  if kind == "Number" { return f64lit(node.value); };
  if kind == "UnaryOp" {
    let d = emitRawDouble(emitValue(node.operand));
    if node.operator == "-" { let n = temp(); line("  " + n + " = fneg double " + d); return n; };
    return d;
  };
  let l = emitRawDouble(emitValue(node.left));
  let r = emitRawDouble(emitValue(node.right));
  let op = node.operator;
  if op == "+" || op == "-" || op == "*" {
    let fop = if op == "+" { "fadd" } else if op == "-" { "fsub" } else { "fmul" };
    let rr = temp(); line("  " + rr + " = " + fop + " double " + l + ", " + r);
    return rr;
  };
  let i1 = temp(); let i2 = temp(); let ir = temp(); let fr = temp();
  line("  " + i1 + " = call i64 @llvm.fptosi.sat.i64.f64(double " + l + ")");
  line("  " + i2 + " = call i64 @llvm.fptosi.sat.i64.f64(double " + r + ")");
  let bitop = if op == "&" { "and" } else if op == "|" { "or" } else { "xor" };
  line("  " + ir + " = " + bitop + " i64 " + i1 + ", " + i2);
  line("  " + fr + " = sitofp i64 " + ir + " to double");
  fr;
};
// 裸 i1:比较与 `!`。条件处可以直接 br i1,省掉 zext+pack+ql_truthy。
let emitRawBoolean = (node) -> {
  if node.type == "UnaryOp" {
    let cv = emitValue(node.operand);
    let b = if cv.raw == "Boolean" { cv.reg; } else { let t = temp(); line("  " + t + " = call i1 @ql_truthy(%ql_value " + cv.reg + ")"); t; };
    let inv = temp(); line("  " + inv + " = xor i1 " + b + ", true");
    return inv;
  };
  let l = emitRawDouble(emitValue(node.left));
  let r = emitRawDouble(emitValue(node.right));
  let op = node.operator;
  let cmp = if op == "==" { "oeq" } else if op == "!=" { "une" } else if op == "<" { "olt" } else if op == "<=" { "ole" } else if op == ">" { "ogt" } else { "oge" };
  let c = temp(); line("  " + c + " = fcmp " + cmp + " double " + l + ", " + r);
  c;
};
let emitValue = (node) -> {
  // 分析期已经算出这个值的自然表示;生成端只消费结论,不猜。裸值在边界处才装箱。
  let sr = emitNaturalRep(node);
  let kind = node.type;
  // 只对**算出来的**节点保持裸表示:字面量本来就是零指令常量盒,标识符的普通读只有 1 条,
  // 把它们改成裸值再在装箱使用点补回来是净亏。裸表示的价值在于让中间结果不再装箱/解箱往返。
  if !inRuntime && (kind == "BinaryOp" || kind == "UnaryOp") {
    if sr == "Number" && (kind == "UnaryOp" || node.operator == "+" || node.operator == "-" || node.operator == "*" || node.operator == "&" || node.operator == "|" || node.operator == "^") {
      return { reg: emitRawArith(node), raw: "Number" };
    };
    if sr == "Boolean" && (kind == "UnaryOp" || emitRepCmpOp(node.operator)) {
      return { reg: emitRawBoolean(node), raw: "Boolean" };
    };
  };
  let value = emitExprInner(node);
  // Contagion is off: only an expression that can *create* an error attaches a
  // source position. A plain read can only carry one, so an Identifier is not
  // checked — reading a binding that holds an Error yields that Error as an
  // ordinary value and it propagates only through `?` or another operation.
  if kind == "BinaryOp" || kind == "UnaryOp" || kind == "Call" || kind == "Import" || kind == "MemberAccess" || kind == "IndexAccess" {
    // 分析期已证明这个值不可能是 Error(操作数/绑定都不携带 Error)⇒ 定位测试连同它的
    // 冷路径与 phi 全是死代码,整块不发射。只读结论,不做发散猜测。
    if !inRuntime && !isError(node.location) && !isError(node.cannotBeError) && node.cannotBeError == true {
      locErrorElided = locErrorElided + 1;
    } else {
      value = emitLocatedError(value, node, kind == "Call" || kind == "Import");
    };
  };
  { reg: value, raw: "" };
};
// 薄包装:取装箱后的寄存器(裸值在使用点这里装箱,且只在这里)。
let emitExpr = (node) -> emitBoxedV(emitValue(node));
let emitExprInner = (node) -> {
  let t = node.type;
  if t == "Number" {
    emitNumber(node);
  } else if t == "Boolean" {
    emitBoolean(node);
  } else if t == "Null" {
    emitNull();
  } else if t == "If" {
    emitIfStmt(node, null);
  } else if t == "BinaryOp" {
    emitBinaryOp(node);
  } else if t == "UnaryOp" {
    emitUnaryOp(node);
  } else if t == "Call" {
    emitCall(node);
  } else if t == "Import" {
    emitImport(node);
  } else if t == "Identifier" {
    emitIdentifier(node);
  } else if t == "Object" {
    emitObjectExpr(node);
  } else if t == "MemberAccess" {
    emitMemberAccess(node);
  } else if t == "Function" {
    // R10-c/i:函数值 → 闭包盒 emit。name 参数仅作未来诊断用(v1 emitFunction 按 funcCounter
    // 生成 ql_fn<N>,不依赖 name)。调用方(emitLetStmt)已先 defineSlot(name),递归成立。
    emitFunction(node, "");
  } else if t == "String" {
    // M2 Task 2:字符串字面量 → interned 全局 STRING 地址包装的 %ql_value。
    emitStringLiteral(node);
  } else if node.type == "Array" {
    emitArrayExpr(node);
  } else if node.type == "IndexAccess" {
    let C = emitExpr(node.object);
    let I = emitExpr(node.index);
    emitCallRegs("__get_index", [C, I]);
  } else {
    addCompileError(node, "unsupported expression: " + t);
    emitNull();
  };
};

// ---- 产物头部注入(每产物一份) ----
let emitPrelude = () -> {
  line("%ql_value = type { i64, i64 }");
  line("declare i64 @llvm.fptosi.sat.i64.f64(double)");
  line("declare void @llvm.memcpy.p0.p0.i64(ptr, ptr, i64, i1)");
  line("declare ptr @ql_extension_open(ptr, ptr, ptr)");
  line("declare void @llvm.memset.p0.i64(ptr, i8, i64, i1)");
  line("declare void @llvm.lifetime.start.p0(i64 immarg, ptr nocapture)");
  line("declare void @llvm.lifetime.end.p0(i64 immarg, ptr nocapture)");
  line("; qlangc v1 prelude");
  line("@ql_stack_top = external global ptr");
  line("declare ptr  @ql_alloc(i64)");
  line("declare void @ql_write(i32, ptr, i64)");
  line("declare i8   @ql_mem_get(ptr, i64)");
  line("declare void @ql_mem_store(ptr, i64, i8)");
  line("declare ptr  @ql_mem_get_ptr(ptr, i64)");
  line("declare void @ql_mem_store_ptr(ptr, i64, ptr)");
  line("declare void @ql_exit(i32)");
  line("declare i64 @ql_openat(i64, ptr, i64)");
  line("declare i64 @ql_read(i64, ptr, i64)");
  line("declare i64 @ql_close(i64)");
  line("declare i64 @ql_getrandom(ptr, i64)");
  line("declare i64 @ql_readlinkat(i64, ptr, ptr, i64)");

  line(valueABI);
};

// 顶层语句:Let 真实 emit;其余(Assign/If/While/表达式语句)走 emitStmtDispatch(node, null)
// (boot parser 无 ExprStmt 包装 —— 裸表达式节点直接出现在 program.statements)。
// Seed the module root lexical scope with its own standard-library bindings.
// Nested scopes use ordinary shadowing, assignment and closure capture rules.
// Imports may replace these bindings without mutating private library bindings.
let emitModuleStd = () -> {
  let value = emitCallRegs("__fresh_std", []);
  let off = emitBindingPtr({ depth: 0, slot: curScope.slots["std"] });
  emitBindingStore(off, value, "null", "null");
  curScope.active["std"] = true;
  let i = 0;
  while i < moduleGlobalNames.length {
    let name = moduleGlobalNames[i];
    // Bypass module shadows while copying the private canonical runtime value.
    let initial = emitIdentifier({name: name, internal: true});
    let target = emitBindingPtr({depth: 0, slot: curScope.slots[name]});
    emitBindingStore(target, initial, "null", "null");
    curScope.active[name] = true; i = i + 1;
  };
};

let emitTopLevelStmt = (node) -> {
  if node.type == "Let" {
    emitLetStmt(node);
  } else {
    emitStmtDispatch(node, null);
  };
};

let main = (args) -> {
  if args.length != 3 { return std.Error.raise("CompileError", "usage: qlangc --emit-llvm|--emit-module source.ql runtime.ql", null); };
  let source = args[0]; let sourcePath = args[1]; let runtimeSource = args[2];
  extensionMode = args[0] == "--emit-module";
  if args[0] == "--emit-llvm" || extensionMode {
    source = std.fs.readFileText(sourcePath)?;
    runtimeSource = std.fs.readFileText(args[2])?;
  };
  let path = std.fs.canonicalPath(sourcePath);
  if isError(path) { std.Error.raise("CompileError", path.message, null)?; };
  let root = loadModuleProgram(source, path, 0)?;
  let userProgram = root.program;
  // 类型信息在生成代码之前算好。顺序:运行期在先(它的成员签名要用来建模块索引),再分析
  // 标准库(它自己的推导结论同时补齐索引),最后是用户程序与已加载的 import 模块。
  let runtimeParser = Parser(Lexer(runtimeSource).tokenize());
  runtimeParser.setSource(runtimeSource);
  runtimeParser.setSourcePath(if args[0] == "--emit-llvm" || extensionMode { args[2]; } else { "<runtime>"; });
  let program = runtimeParser.parse();
  if program.errors.length > 0 { return std.Error.raise("CompileError", "runtime: " + program.errors[0], null); };
  // 运行期程序也走一遍分析:它的绑定与成员签名要能推导出来,库/用户才用得上。
  // 它自己的静态类型错误不计入面向用户的诊断(底层代码 + 分析不认识宿主原语,现在多半
  // 是误报),但条数要报出来,不悄悄丢掉 —— 那是「让运行期干净通过分析」的工作清单。
  let runtimeErrBase = typeErrors.length;
  typeSetStdNamespace(true);
  typeSetDefinesBuiltins(true);
  inferTypes(program.statements);
  typeSetDefinesBuiltins(false);
  typeSetStdNamespace(false);
  let runtimeErrCount = typeErrors.length - runtimeErrBase;
  while typeErrors.length > runtimeErrBase { typeErrors.remove(typeErrors.length - 1); };
  // 运行期的导出表(std = {...})先进索引,库自己的 std.<模块>.<成员> 才解析得出。
  buildStdTypes(program.statements);
  let libraryProgram = parseStandardLibrary()?;
  typeSetStdNamespace(true);
  inferTypes(libraryProgram.statements);
  typeSetStdNamespace(false);
  buildStdTypes(libraryProgram.statements);
  let typeErrs = inferTypes(userProgram.statements);
  let typePaths = std.Object.keys(moduleCache); let typeIndex = 0;
  while typeIndex < typePaths.length { inferTypes(moduleCache[typePaths[typeIndex]].program.statements); typeIndex = typeIndex + 1; };
  let r = 0;
  while r < program.statements.length {
    let stmt = program.statements[r];
    if stmt.type == "Let" && stmt.value != null && stmt.value.type == "Function" { runtimeFunctions[stmt.name] = true; };
    if stmt.type == "Assign" && stmt.target.type == "Identifier" { assignedRuntime[stmt.target.name] = true; };
    r = r + 1;
  };
  emitPrelude();
  line("; unboxable bindings: " + std.String.toString(typeUnboxList.length));
  // 诊断:编译期算出的表示各有多少(节点种类/静态类型/表示)。燃料 = 裸读,命中 = 裸比较;
  // 装箱的一侧按静态类型分层,才能分清「根本不是 Number」和「是 Number 但操作数不裸」。
  // 只进注释,不进代码。
  let repAll = typeRepReport();
  let uBinds = typeBindsUnknown();
  let uParams = typeParamsUnknown();
  let repCount = typeRepPrograms();
  // 逐程序分开报:程序 1 = 运行期,2 = 标准库,3 = 入口,之后按加载顺序是各 import 模块。
  let repPaths = std.Object.keys(moduleCache);
  let repIdx = 1;
  let rLit = 0; let rRead = 0; let rArith = 0; let rCmp = 0; let rNot = 0;
  let rReadNum = 0; let rReadStr = 0; let rReadUnk = 0;
  let rArithNum = 0; let rCmpNum = 0; let rStr = 0; let rBinUnk = 0;
  let uB = 0; let uP = 0; let uB1 = ""; let uP1 = "";
  while repIdx <= repCount {
    let bucket = repAll[repIdx];
    let vLit = 0; let vRead = 0; let vArith = 0; let vCmp = 0; let vNot = 0;
    let vReadNum = 0; let vReadStr = 0; let vReadUnk = 0;
    let vArithNum = 0; let vCmpNum = 0; let vStr = 0; let vBinUnk = 0;
    if !isError(bucket) {
      let b1 = bucket["Number/Number/Number"]; if !isError(b1) { vLit = b1; };
      let b2 = bucket["Identifier/Number/Number"]; if !isError(b2) { vRead = b2; };
      let b3 = bucket["BinaryOp/Number/Number"]; if !isError(b3) { vArith = b3; };
      let b4 = bucket["BinaryOp/Boolean/Boolean"]; if !isError(b4) { vCmp = b4; };
      let b5 = bucket["UnaryOp/Boolean/Boolean"]; if !isError(b5) { vNot = b5; };
      let b6 = bucket["Identifier/Number/boxed"]; if !isError(b6) { vReadNum = b6; };
      let b7 = bucket["Identifier/String/boxed"]; if !isError(b7) { vReadStr = b7; };
      let b8 = bucket["Identifier//boxed"]; if !isError(b8) { vReadUnk = b8; };
      let b9 = bucket["BinaryOp/Number/boxed"]; if !isError(b9) { vArithNum = b9; };
      let b10 = bucket["BinaryOp/Boolean/boxed"]; if !isError(b10) { vCmpNum = b10; };
      let b11 = bucket["BinaryOp/String/boxed"]; if !isError(b11) { vStr = b11; };
      let b12 = bucket["BinaryOp//boxed"]; if !isError(b12) { vBinUnk = b12; };
    };
    rLit = rLit + vLit; rRead = rRead + vRead; rArith = rArith + vArith; rCmp = rCmp + vCmp; rNot = rNot + vNot;
    rReadNum = rReadNum + vReadNum; rReadStr = rReadStr + vReadStr; rReadUnk = rReadUnk + vReadUnk;
    rArithNum = rArithNum + vArithNum; rCmpNum = rCmpNum + vCmpNum; rStr = rStr + vStr; rBinUnk = rBinUnk + vBinUnk;
    let vB = 0; let vP = 0;
    let lb = uBinds[repIdx];
    if !isError(lb) {
      vB = lb.length; uB = uB + vB;
      if repIdx == 2 { let uJ = 0; while uJ < lb.length { uB1 = uB1 + lb[uJ] + " "; uJ = uJ + 1; }; };
    };
    let lp = uParams[repIdx];
    if !isError(lp) {
      vP = lp.length; uP = uP + vP;
      if repIdx == 2 { let uK = 0; while uK < lp.length { uP1 = uP1 + lp[uK] + " "; uK = uK + 1; }; };
    };
    let pName = "";
    if repIdx == 1 { pName = "runtime"; }
    else if repIdx == 2 { pName = "library"; }
    else if repIdx == 3 { pName = "entry"; }
    else {
      let mi = repIdx - 4;
      if mi >= 0 && mi < repPaths.length { pName = "module:" + repPaths[mi]; }
      else { pName = "program" + std.String.toString(repIdx); };
    };
    line("; typeRep p" + std.String.toString(repIdx) + "[" + pName + "] raw lit=" + std.String.toString(vLit) + " read=" + std.String.toString(vRead) + " arith=" + std.String.toString(vArith) + " cmp=" + std.String.toString(vCmp) + " not=" + std.String.toString(vNot) + " | boxed reads num=" + std.String.toString(vReadNum) + " str=" + std.String.toString(vReadStr) + " unk=" + std.String.toString(vReadUnk) + " | boxed binops num=" + std.String.toString(vArithNum) + " cmp=" + std.String.toString(vCmpNum) + " str=" + std.String.toString(vStr) + " unk=" + std.String.toString(vBinUnk) + " | unknown binds=" + std.String.toString(vB) + " params=" + std.String.toString(vP));
    repIdx = repIdx + 1;
  };
  line("; typeRep raw: lit=" + std.String.toString(rLit) + " read=" + std.String.toString(rRead) + " arith=" + std.String.toString(rArith) + " cmp=" + std.String.toString(rCmp) + " not=" + std.String.toString(rNot));
  line("; typeRep boxed reads: num=" + std.String.toString(rReadNum) + " str=" + std.String.toString(rReadStr) + " unk=" + std.String.toString(rReadUnk));
  line("; typeRep boxed binops: num=" + std.String.toString(rArithNum) + " cmp=" + std.String.toString(rCmpNum) + " str=" + std.String.toString(rStr) + " unk=" + std.String.toString(rBinUnk));
  line("; typeRep unknown: binds=" + std.String.toString(uB) + " params=" + std.String.toString(uP));
  // 模块索引命中数:std.<模块>.<成员> 能解析成已知类型的有多少、解析不出的有多少。
  let nsRep = typeNsReport();
  line("; ns-resolve: resolved=" + std.String.toString(nsRep[0][2] + nsRep[0][3]) + " unresolved=" + std.String.toString(nsRep[1][2] + nsRep[1][3]) + " (library+entry)");
  line("; ns-unresolved: " + std.Array.join(typeNsUnknownNames())(" "));
  line("; typeRep unknown binds[lib]: " + uB1);
  line("; typeRep unknown params[lib]: " + uP1);
  // 运行期那一遍分析报出的静态错误条数(已从用户诊断中移除,这里只报数)。
  line("; typeRep runtime: analysisErrors=" + std.String.toString(runtimeErrCount));
  // ②a:裸 ABI 的覆盖面(纯量测,不影响生成)。
  let ra = rawAbiReport();
  line("; rawABI: funcs total=" + std.String.toString(ra[0]) + " allparams=" + std.String.toString(ra[1]) + " allraw=" + std.String.toString(ra[2]) + " anyparam=" + std.String.toString(ra[8]) + " rawparams=" + std.String.toString(ra[9]) + " retnum=" + std.String.toString(ra[7]) + " | calls total=" + std.String.toString(ra[3]) + " known=" + std.String.toString(ra[4]) + " arity=" + std.String.toString(ra[5]) + " rawable=" + std.String.toString(ra[6]) + " retfuel=" + std.String.toString(ra[10]) + " | numparams=" + std.String.toString(ra[11]) + " writable=" + std.String.toString(ra[12]));
  // ②a 补充:发射序折扣在主线末尾补发(见下文),因为函数体是在 main 发射过程中才发出的。
  coldHelperAt = out.length;
  if extensionMode { mainAt = out.length; line("define %ql_value @qlang_extension_init_v1(ptr %host_env) {"); }
  else { mainAt = out.length; line("define i32 @main(i32 %argc, ptr %argv) {"); };
  line("entry:");
  let mainStackAt = out.length; line("");
  if !extensionMode { line("  store ptr %argv, ptr @ql_stack_top"); };
  curLbl = "entry";
  reserveModuleBindings(program.statements);
  reserveModuleBindings(libraryProgram.statements);
  // Stable ABI descriptor: representation version plus the actual slot order.
  let baseNames = std.Object.keys(curScope.slots); let ordered = []; let bi = 0;
  // Object key order is not slot order. Allocate all array entries before
  // indexed writes; QLang permits append at length, never sparse assignment.
  while bi < baseNames.length { ordered[ordered.length] = ""; bi = bi + 1; };
  bi = 0;
  while bi < baseNames.length { let name = baseNames[bi]; ordered[curScope.slots[name]] = name; bi = bi + 1; };
  extensionABI = "qlang-native-v1;value=16;binding=64;closure=72;error=120;string=48;diagnostic-output=1;interpreter-callback=1;" + std.Array.join(ordered)(";");
  let abiBytes = stringBytes(extensionABI); abiBytes[abiBytes.length] = 0;
  strDecls[strDecls.length] = "@qlang_extension_abi_v1 = constant [" + std.String.toString(abiBytes.length) + " x i8] c\"" + escapeBytes(abiBytes) + "\"";
  let modulePaths = std.Object.keys(moduleCache); let moduleIndex = 0;
  while moduleIndex < modulePaths.length { defineSlot("$loading:" + modulePaths[moduleIndex]); moduleIndex = moduleIndex + 1; };
  runtimeScope = curScope;
  curEnv = emitFrame("null", std.Object.keys(curScope.slots).length, false);
  inRuntime = true;
  moduleIndex = 0;
  while moduleIndex < modulePaths.length { emitSetModuleLoading(modulePaths[moduleIndex], false); moduleIndex = moduleIndex + 1; };
  if extensionMode {
    let dest = temp(); let src = temp();
    line("  " + dest + " = getelementptr i8, ptr " + curEnv + ", i64 16");
    line("  " + src + " = getelementptr i8, ptr %host_env, i64 16");
    line("  call void @llvm.memcpy.p0.p0.i64(ptr " + dest + ", ptr " + src + ", i64 " + std.String.toString(baseNames.length * 64) + ", i1 false)");
    bi = 0; while bi < baseNames.length { curScope.active[baseNames[bi]] = true; bi = bi + 1; };
    inRuntime = false;
    let factory = emitFunction({ type: "Function", parameters: [], body: {statements: userProgram.statements}, moduleBody: true, modulePath: path }, "");
    let result = emitInvoke(factory, "null", "0");
    line("  ret %ql_value " + result);
  } else {
  let i = 0;
  while i < program.statements.length { emitTopLevelStmt(program.statements[i]); i = i + 1; };
  // Give the AST interpreter the same host runtime/ABI used by direct imports.
  emitCallRegs("__extension_bind_host", [emitPointerValue(curEnv), emitPointerValue("@qlang_extension_abi_v1"), emitNumber({value: curScope.slots["args"]})]);
  // Both process arguments cross the language ABI as values.
  let argcValue = temp();
  line("  " + argcValue + " = sitofp i32 %argc to double");
  let processArgs = emitCallRegs("__process_args", [emitFloatValue(argcValue), emitPointerValue("%argv")]);
  let argsSlot = emitBindingPtr({ depth: 0, slot: curScope.slots["args"] });
  emitBindingStore(argsSlot, processArgs, "null", "null");
  inRuntime = false;
  // Library bodies use the ordinary AST/code path: no runtime privilege.
  let li = 0;
  while li < libraryProgram.statements.length { emitTopLevelStmt(libraryProgram.statements[li]); li = li + 1; };
  let libraryBase = emitCallRegs("__fresh_std", []);
  let library = emitCallRegs("__build_standard_library", [libraryBase]);
  emitCallRegs("__install_library", [library]);
  let parent = curEnv;
  scopePush(runtimeScope);
  reserveModuleBindings(userProgram.statements);
  reserveModuleGlobals();
  curEnv = emitFrame(parent, std.Object.keys(curScope.slots).length, false);
  emitModuleStd();
  moduleExportsReg = emitObjectExpr({ fields: [] });
  let exportsOff = emitBindingPtr({depth: 0, slot: curScope.slots["$exports"]});
  emitBindingStore(exportsOff, moduleExportsReg, "null", "null");
  emitSetModuleLoading(path, true);
  let last = emitBlockStmts(userProgram.statements);
  emitSetModuleLoading(path, false);
  // The CLI reports an unhandled final Error, just as the host interpreter does.
  if last != null {
    let tag = temp(); let error = temp(); let bad = lbl(); let good = lbl();
    line("  " + tag + " = call i64 @ql_tag(%ql_value " + last + ")");
    line("  " + error + " = icmp eq i64 " + tag + ", 8");
    line("  br i1 " + error + ", label %" + bad + ", label %" + good);
    line(bad + ":"); curLbl = bad;
    emitCallRegs("__exit_error", [last]); line("  unreachable");
    line(good + ":"); curLbl = good;
  };
  line("  ret i32 0");
  };
  line("}");
  out[mainStackAt] = stackEntry();
  // Splice the located-error helper in right after the prelude: the scope is fully
  // populated here, and the definition must precede every call site.
  if needColdLocated {
    let helper = emitColdLocatedHelper();
    let merged = [];
    let m = 0;
    while m < coldHelperAt { merged[merged.length] = out[m]; m = m + 1; };
    let hh = 0;
    while hh < helper.length { merged[merged.length] = helper[hh]; hh = hh + 1; };
    while m < out.length { merged[merged.length] = out[m]; m = m + 1; };
    out = merged;
    mainAt = mainAt + helper.length;
  };
  // Never turn unsupported syntax into a successful, silently incorrect binary.
  // 编译期分析报出的静态类型错误与其他编译错误一并让编译失败。
  if !isError(typeErrs) {
    let typeErrIndex = 0;
    while typeErrIndex < typeErrs.length { compileErrors[compileErrors.length] = typeErrs[typeErrIndex]; typeErrIndex = typeErrIndex + 1; };
  };
  if compileErrors.length > 0 {
    std.Error.raise("CompileError", compileErrors[0], null)?;
  };
  // 命中数:分析期证明不可能出错、因而整块省掉定位测试的节点数(主函数体发完之后才知道)。
  out[out.length] = "; located-error elided: " + std.String.toString(locErrorElided);
  // ②a 补充:发射序折扣(同样要等主函数体发完 —— 函数体是在 main 发射过程中才发现并发出的)。
  out[out.length] = "; rawABI order: usercalls=" + std.String.toString(ordCallsTotal) + " emitted=" + std.String.toString(ordCallsEmitted) + " notyet=" + std.String.toString(ordCallsNotYet) + " retraw=" + std.String.toString(ordCallsRetRaw);
  // R10-c: out[0..mainAt) = prelude plus the cold helper, then every function body,
  // then main. Function bodies come before their direct callers because this
  // toolchain has no forward declarations; the closure boxes keep the order
  // irrelevant for every indirect call, and top-level globals are unordered.
  let i2 = 0;
  while i2 < mainAt {
    println(out[i2]);
    i2 = i2 + 1;
  };
  let b = 0;
  while b < fnBlocks.length {
    let blk = fnBlocks[b];
    let j = 0;
    while j < blk.length {
      println(blk[j]);
      j = j + 1;
    };
    b = b + 1;
  };
  while i2 < out.length {
    println(out[i2]);
    i2 = i2 + 1;
  };
  // M2 Task 2:flush 全局字符串常量/盒(LLVM 顶层实体无序,放函数定义之后合法)。
  // 注意:必须 println 直接落 IR —— line() 会追加到已 flush 过的 out(死数据,永不出现在 IR)。
  let si = 0;
  while si < strDecls.length {
    println(strDecls[si]);
    si = si + 1;
  };
};

// The compiler CLI reports input-source diagnostics already carried by its
// errors. Its own implementation frames are outside that user call stack.
let compilerDiagnostics = std.__diagnostics;
if !isError(compilerDiagnostics) { compilerDiagnostics.enter(null); };
main(args)?;
