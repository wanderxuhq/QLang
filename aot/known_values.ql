// 静态派发的事实层:分析期回答「这个调用点的被调者,是不是编译期可确定的一个 QLang 函数」。
//
// 规则是**充分条件**,不是必要条件 —— 下列条件全部成立才允许走静态,否则原样回落到
// `__call` 动态路径,语义不变:
//   1. 被调者是本程序里的不可变绑定,值是函数字面量;或
//   2. 被调者是「已知对象字面量绑定」的一个字段,字段值是函数字面量,并且
//      - 该绑定没有被赋值(written),
//      - 该绑定没有逃逸(只作为读取/调用的接收者出现),
//      - 该字段没有被写过(对象上的动态下标写也算整对象字段脏),
//   3. 实参个数等于形参个数(部分应用不走静态),
//   4. 被调者没有出现在值的位置(否则它可能被当成别的函数用)。
//
// 本切片只统计,不改发射:命中数与拒绝原因先报出来,由下一片决定怎么发。
// 开关 `--static-scan`,默认关 —— 关闭时编译产物与之前逐字节相同(便于 A/B)。

let staticScanEnabled = false;
let staticScanSet = (on) -> { staticScanEnabled = on; null; };

// 每个程序一份事实(knownScan 开头清空);计数按 label 累加,跨程序保留。
let knownBinds = {};
let knownFieldWrites = {};
let knownStats = {};
let knownLabel = "";
// 发射器要求「被调函数的定义先于调用点」(directFns 是按源码顺序建立的),这里用同一个
// 遍历序号给 Let 和 Call 编号,第二遍就能把 285 收敛成真正可发的数。
let knownSeq = 0;

let knownBindInfo = (bid) -> {
  let info = knownBinds[bid];
  if isError(info) {
    info = { kind: "", arity: 0, written: false, escaped: false, anyFieldWrite: false, fields: {}, fieldArity: {} };
    knownBinds[bid] = info;
  };
  info;
};
let knownMarkWritten = (bid) -> {
  if !isError(bid) && bid >= 0 { knownBindInfo(bid).written = true; };
  null;
};
let knownMarkEscape = (bid) -> {
  if !isError(bid) && bid >= 0 { knownBindInfo(bid).escaped = true; };
  null;
};

// 表达式遍历。pos:
//   "value"    这个表达式的结果会被当值用(传参/返回/导出/别名/算术)→ 标识符逃逸;
//   "callee"   它是调用的被调者(递归调用也是这个形状)→ 标识符不逃逸;
//   "receiver" 它是字段/下标的接收者(只是读)→ 标识符不逃逸。
let knownWalkExpr = (node, pos) -> {
  if node == null || isError(node) { return null; };
  if AnyArray.check(node) {
    let i = 0; while i < node.length { knownWalkExpr(node[i], pos); i = i + 1; };
    return null;
  };
  if !AnyObject.check(node) { return null; };
  let t = node.type;
  if isError(t) { return null; };
  if t == "Import" { return null; };
  if t == "Identifier" {
    if pos == "value" { knownMarkEscape(node.bindId); };
    return null;
  };
  if t == "Call" {
    knownSeq = knownSeq + 1;
    node.knownCallOrder = knownSeq;
    knownWalkExpr(node.callee, "callee");
    let ai = 0; while ai < node.arguments.length { knownWalkExpr(node.arguments[ai], "value"); ai = ai + 1; };
    return null;
  };
  if t == "MemberAccess" { knownWalkExpr(node.object, "receiver"); return null; };
  if t == "IndexAccess" {
    knownWalkExpr(node.object, "receiver");
    knownWalkExpr(node.index, "value");
    return null;
  };
  if t == "Function" {
    // 参数注解是值;函数体是语句(里面可能还有 Let/Assign)。
    let pi = 0;
    while pi < node.parameters.length {
      let p = node.parameters[pi];
      if p.annotation != null { knownWalkExpr(p.annotation, "value"); };
      pi = pi + 1;
    };
    knownWalk(node.body);
    return null;
  };
  let keys = std.Object.keys(node); let i = 0;
  while i < keys.length {
    let child = node[keys[i]];
    if child != null && AnyObject.check(child) { knownWalkExpr(child, "value"); }
    else if AnyArray.check(child) { let j = 0; while j < child.length { knownWalkExpr(child[j], "value"); j = j + 1; }; };
    i = i + 1;
  };
  null;
};

// 第一遍:收绑定事实(初始化形状、被写、逃逸),以及对象字段的写。
let knownWalk = (node) -> {
  if node == null || isError(node) { return null; };
  if AnyArray.check(node) {
    let i = 0; while i < node.length { knownWalk(node[i]); i = i + 1; };
    return null;
  };
  if !AnyObject.check(node) { return null; };
  let t = node.type;
  if isError(t) { return null; };
  if t == "Import" { return null; };
  if t == "Let" {
    let bid = node.bindId;
    if !isError(bid) && bid >= 0 {
      let info = knownBindInfo(bid);
      let v = node.value;
      if v != null && !isError(v) && !isError(v.type) {
        if v.type == "Function" {
          info.kind = "fn";
          info.arity = v.parameters.length;
        } else if v.type == "Object" {
          info.kind = "obj";
          let fi = 0;
          while fi < v.fields.length {
            let f = v.fields[fi];
            info.fields[f.name] = true;
            if f.value != null && !isError(f.value) && !isError(f.value.type) && f.value.type == "Function" {
              info.fieldArity[f.name] = f.value.parameters.length;
            };
            fi = fi + 1;
          };
        };
      };
      knownSeq = knownSeq + 1;
      info.order = knownSeq;
      if v != null { knownWalkExpr(v, "value"); };
      return null;
    };
    if node.value != null { knownWalkExpr(node.value, "value"); };
    return null;
  };
  if t == "Assign" {
    let target = node.target;
    if target != null && !isError(target) && !isError(target.type) {
      if target.type == "Identifier" { knownMarkWritten(target.bindId); }
      else if target.type == "MemberAccess" {
        let base = target.object;
        if base != null && !isError(base) && !isError(base.type) && base.type == "Identifier"
           && !isError(base.bindId) && base.bindId >= 0 {
          let info = knownBindInfo(base.bindId);
          info.anyFieldWrite = true;
          knownFieldWrites[std.String.toString(base.bindId) + "|" + target.field] = true;
        } else if base != null { knownWalkExpr(base, "value"); };
      } else if target.type == "IndexAccess" {
        let base = target.object;
        if base != null && !isError(base) && !isError(base.type) && base.type == "Identifier"
           && !isError(base.bindId) && base.bindId >= 0 {
          // 动态下标的写:不知道写的是哪个字段,整对象字段脏。
          knownBindInfo(base.bindId).anyFieldWrite = true;
        } else if base != null { knownWalkExpr(base, "value"); };
        knownWalkExpr(target.index, "value");
      } else { knownWalkExpr(target, "value"); };
    };
    if node.value != null { knownWalkExpr(node.value, "value"); };
    return null;
  };
  if t == "Function" {
    let pi = 0;
    while pi < node.parameters.length {
      let p = node.parameters[pi];
      if p.annotation != null { knownWalkExpr(p.annotation, "value"); };
      pi = pi + 1;
    };
    knownWalk(node.body);
    return null;
  };
  if t == "Block" { knownWalk(node.statements); return null; };
  if t == "If" {
    let bi = 0;
    while bi < node.branches.length {
      let b = node.branches[bi];
      knownWalkExpr(b.condition, "value");
      knownWalk(b.body);
      bi = bi + 1;
    };
    if node.elseBody != null { knownWalk(node.elseBody); };
    return null;
  };
  if t == "While" { knownWalkExpr(node.condition, "value"); knownWalk(node.body); return null; };
  if t == "Return" { if node.value != null { knownWalkExpr(node.value, "value"); }; return null; };
  if t == "Export" { if node.value != null { knownWalkExpr(node.value, "value"); }; return null; };
  knownWalkExpr(node, "value");
  null;
};

let knownReject = (reason) -> {
  let stat = knownStats[knownLabel];
  if !isError(stat) { stat[reason] = stat[reason] + 1; };
  null;
};
// 第二遍:用收齐的事实给每个调用点定性。
let knownClassify = (node) -> {
  let stat = knownStats[knownLabel];
  if isError(stat) { return null; };
  stat.sites = stat.sites + 1;
  let callee = node.callee;
  if callee == null || isError(callee) || isError(callee.type) { knownReject("shape"); return null; };
  if callee.type == "Identifier" {
    let bid = callee.bindId;
    if isError(bid) || bid < 0 { knownReject("shape"); return null; };
    let info = knownBinds[bid];
    if isError(info) { knownReject("notfn"); return null; };
    if info.written == true { knownReject("written"); return null; };
    // 绑定是函数值时,「被拿去当值用」不影响直调(同一个函数值),只有重新赋值才破坏证明。
    if info.kind != "fn" { knownReject("notfn"); return null; };
    if node.arguments.length != info.arity { knownReject("partial"); return null; };
    stat.bind = stat.bind + 1;
    if !isError(info.order) && info.order < node.knownCallOrder { stat.early = stat.early + 1; } else { stat.late = stat.late + 1; };
    return null;
  };
  if callee.type == "MemberAccess" {
    let base = callee.object;
    if base == null || isError(base) || isError(base.type) { knownReject("shape"); return null; };
    if base.type != "Identifier" {
      // `std.Math.sqrt(...)` 这类链:本切片还不解析命名空间,单独记一笔。
      if base.type == "MemberAccess" { knownReject("chain"); } else { knownReject("shape"); };
      return null;
    };
    let bid = base.bindId;
    if isError(bid) || bid < 0 { knownReject("shape"); return null; };
    let info = knownBinds[bid];
    if isError(info) { knownReject("notobj"); return null; };
    if info.kind != "obj" { knownReject("notobj"); return null; };
    if info.written == true { knownReject("written"); return null; };
    if info.escaped == true { knownReject("escaped"); return null; };
    if info.anyFieldWrite == true { knownReject("fieldwritten"); return null; };
    if !isError(knownFieldWrites[std.String.toString(bid) + "|" + callee.field]) { knownReject("fieldwritten"); return null; };
    let arity = info.fieldArity[callee.field];
    if isError(arity) { knownReject("fieldnotfn"); return null; };
    if node.arguments.length != arity { knownReject("partial"); return null; };
    stat.field = stat.field + 1;
    return null;
  };
  knownReject("shape");
  null;
};
let knownVisitCalls = (node) -> {
  if node == null || isError(node) { return null; };
  if AnyArray.check(node) {
    let i = 0; while i < node.length { knownVisitCalls(node[i]); i = i + 1; };
    return null;
  };
  if !AnyObject.check(node) { return null; };
  let t = node.type;
  if isError(t) { return null; };
  if t == "Import" { return null; };
  if t == "Call" { knownClassify(node); };
  let keys = std.Object.keys(node); let i = 0;
  while i < keys.length {
    let child = node[keys[i]];
    if child != null && AnyObject.check(child) { knownVisitCalls(child); }
    else if AnyArray.check(child) { let j = 0; while j < child.length { knownVisitCalls(child[j]); j = j + 1; }; };
    i = i + 1;
  };
  null;
};

let knownScan = (stmts, label) -> {
  if !staticScanEnabled { return null; };
  if stmts == null || isError(stmts) || stmts.length == 0 { return null; };
  knownBinds = {};
  knownFieldWrites = {};
  knownSeq = 0;
  knownLabel = label;
  let stat = knownStats[label];
  if isError(stat) {
    stat = { sites: 0, bind: 0, field: 0, early: 0, late: 0, escaped: 0, written: 0, notfn: 0, notobj: 0, partial: 0, fieldwritten: 0, fieldnotfn: 0, chain: 0, shape: 0 };
    knownStats[label] = stat;
  };
  knownWalk(stmts);
  knownVisitCalls(stmts);
  null;
};

let knownOneReport = (label) -> {
  let stat = knownStats[label];
  if isError(stat) { return ""; };
  label + " sites=" + std.String.toString(stat.sites)
    + " bind=" + std.String.toString(stat.bind)
    + " early=" + std.String.toString(stat.early)
    + " late=" + std.String.toString(stat.late)
    + " field=" + std.String.toString(stat.field)
    + " reject: escaped=" + std.String.toString(stat.escaped)
    + " written=" + std.String.toString(stat.written)
    + " notfn=" + std.String.toString(stat.notfn)
    + " notobj=" + std.String.toString(stat.notobj)
    + " partial=" + std.String.toString(stat.partial)
    + " fieldwritten=" + std.String.toString(stat.fieldwritten)
    + " fieldnotfn=" + std.String.toString(stat.fieldnotfn)
    + " chain=" + std.String.toString(stat.chain)
    + " shape=" + std.String.toString(stat.shape);
};
let knownReportLine = () -> {
  if !staticScanEnabled { return ""; };
  let user = knownOneReport("user");
  let library = knownOneReport("library");
  if library == "" { return user; };
  user + " || " + library;
};

export staticScanSet;
export knownScan;
export knownReportLine;
