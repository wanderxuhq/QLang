// AST 级常量折叠:把一个「已证明是纯函数」的调用点,直接替换成编译期算出来的字面量。
//
// 这是**分析之后的 AST→AST 变换**,不是 codegen 的一部分:
//   - 发射器完全不知道它存在,照旧只发 `Number/String/Boolean/Null` 字面量;
//   - 开关独立(`--fold`),默认关闭;折叠开/关的产物必须跑出同样结果(验收口径)。
//
// 为什么能保证与运行期一致:执行折叠的就是编译器自己(QLang 程序),用的就是同一套
// 数值/字符串语义,不存在「两套实现要对齐」的问题。
//
// 证明义务(缺一不可):
//   1. 被调者是本程序里不可变的 `let f = (参数) -> 单表达式`(未被赋值/导出/import/重声明);
//   2. 参数**没有注解**(有注解意味着运行期要做检查,折叠就绕过了它);
//   3. 函数体只由参数、字面量、一元/二元运算符组成(没有调用、成员访问、索引、块语句);
//   4. 全部实参都是字面量,且实参个数等于形参个数(无部分应用);
//   5. 结果只可能是 Number/String/Boolean/Null —— Array/Object/Function 有身份语义,折不了;
//   6. 求值有燃料上限,算不尽就放弃折叠(绝不把编译挂住,也不假装算出了结果)。
//
// 任何一条不满足,就保持原样,由正常路径发射。

let foldFuel = 0;
let foldStatLets = 0;
let foldStatCalls = 0;
let foldStatReject = "";
let foldFolded = 0;
let foldBailed = 0;

let foldNumOps = 0;
let foldStrOps = 0;

let isLiteralScalar = (node) -> {
  if node == null || isError(node) || isError(node.type) { return false; };
  let t = node.type;
  if t == "Number" || t == "String" || t == "Boolean" || t == "Null" { return true; };
  if t == "UnaryOp" && (node.operator == "-" || node.operator == "+" || node.operator == "!") {
    return isLiteralScalar(node.operand);
  };
  false;
};

// 求值结果:{ok, kind, value};kind 是 "Number"/"String"/"Boolean"/"Null"。
let foldFail = () -> { { ok: false, kind: "", value: null }; };

let foldTruthy = (kind, value) -> {
  if kind == "Null" { return false; };
  if kind == "Boolean" { return value; };
  if kind == "Number" { return value != 0; };
  if kind == "String" { return value != ""; };
  true;
};

// 参数绑定:名字 → 已折叠的字面量记录。
let foldEval = (node, params) -> {
  if node == null || isError(node) || isError(node.type) { return foldFail(); };
  foldFuel = foldFuel - 1;
  if foldFuel < 0 { return foldFail(); };
  let t = node.type;
  if t == "Number" { return { ok: true, kind: "Number", value: node.value }; };
  if t == "String" { return { ok: true, kind: "String", value: node.value }; };
  if t == "Boolean" { return { ok: true, kind: "Boolean", value: node.value }; };
  if t == "Null" { return { ok: true, kind: "Null", value: null }; };
  if t == "Identifier" {
    let bound = params[node.name];
    if isError(bound) || bound == null { return foldFail(); };
    return bound;
  };
  if t == "UnaryOp" {
    let inner = foldEval(node.operand, params);
    if !inner.ok { return inner; };
    if node.operator == "!" { return { ok: true, kind: "Boolean", value: !foldTruthy(inner.kind, inner.value) }; };
    if inner.kind != "Number" { return foldFail(); };
    foldNumOps = foldNumOps + 1;
    if node.operator == "-" { return { ok: true, kind: "Number", value: -inner.value }; };
    return inner;
  };
  if t == "BinaryOp" {
    let left = foldEval(node.left, params);
    if !left.ok { return left; };
    // && / || 返回**操作数**,不是 Boolean:需要保留这个语义。
    if node.operator == "&&" {
      if !foldTruthy(left.kind, left.value) { return left; };
      return foldEval(node.right, params);
    };
    if node.operator == "||" {
      if foldTruthy(left.kind, left.value) { return left; };
      return foldEval(node.right, params);
    };
    let right = foldEval(node.right, params);
    if !right.ok { return right; };
    let op = node.operator;
    // `%` 不折:剩余数的精确语义(截断/被零除)不值得在这里复制一份。
    if op == "+" || op == "-" || op == "*" || op == "/" {
      if left.kind == "String" && right.kind == "String" && op == "+" {
        foldStrOps = foldStrOps + 1;
        return { ok: true, kind: "String", value: left.value + right.value };
      };
      if left.kind != "Number" || right.kind != "Number" { return foldFail(); };
      if op == "/" && right.value == 0 { return foldFail(); };
      foldNumOps = foldNumOps + 1;
      if op == "+" { return { ok: true, kind: "Number", value: left.value + right.value }; };
      if op == "-" { return { ok: true, kind: "Number", value: left.value - right.value }; };
      if op == "*" { return { ok: true, kind: "Number", value: left.value * right.value }; };
      return { ok: true, kind: "Number", value: left.value / right.value };
    };
    if op == "==" || op == "!=" {
      // 类型严格:不同 kind ⇒ false/true;同一 kind 按值比。Null/Boolean 同理。
      if left.kind != right.kind { return { ok: true, kind: "Boolean", value: op == "!=" }; };
      if left.kind == "Null" { return { ok: true, kind: "Boolean", value: op == "==" }; };
      let eq = left.value == right.value;
      if op == "==" { return { ok: true, kind: "Boolean", value: eq }; };
      return { ok: true, kind: "Boolean", value: !eq };
    };
    // 排序只对 Number 有定义;字符串/布尔比较在 QLang 里会产出 TypeMismatch,不折。
    if op == "<" || op == "<=" || op == ">" || op == ">=" {
      if left.kind != "Number" || right.kind != "Number" { return foldFail(); };
      let a = left.value; let b = right.value;
      let r = false;
      if op == "<" { r = a < b; }
      else if op == "<=" { r = a <= b; }
      else if op == ">" { r = a > b; }
      else { r = a >= b; };
      return { ok: true, kind: "Boolean", value: r };
    };
    return foldFail();
  };
  foldFail();
};

// 把调用点就地改写成字面量节点;返回是否折叠。
let foldIntoLiteral = (node, result) -> {
  node.type = result.kind;
  node.value = result.value;
  node.staticType = result.kind;
  node.staticRep = "";
  node.cannotBeError = true;
  true;
};

let foldBodyExpr = (fn) -> {
  if fn.body == null || isError(fn.body) { return null; };
  if !isError(fn.body.type) && fn.body.type == "Block" {
    if fn.body.statements.length != 1 { return null; };
    return fn.body.statements[0];
  };
  fn.body;
};

let foldWalk = (node, lets) -> {
  if node == null || isError(node) { return null; };
  if AnyArray.check(node) {
    let i = 0; while i < node.length { foldWalk(node[i], lets); i = i + 1; };
    return null;
  };
  if AnyObject.check(node) {
    let t = node.type;
    if !isError(t) && t == "Import" { return null; };
    if !isError(t) && t == "Call" && !isError(node.callee.type) && node.callee.type == "Identifier" {
      foldStatCalls = foldStatCalls + 1;
      let decl = lets[node.callee.name];
      if !isError(decl) && decl != null {
        let fn = decl.value;
        let expr = foldBodyExpr(fn);
        if expr == null { if foldStatReject == "" { foldStatReject = "body-shape"; }; };
        if expr != null && fn.parameters.length != node.arguments.length { if foldStatReject == "" { foldStatReject = "arity"; }; };
        if expr != null && fn.parameters.length == node.arguments.length {
          // 先给这次尝试一个新鲜预算:实参与函数体共用同一份燃料,否则第一次求值
          // 就会因为「模块初始化时 fuel=0」而全部失败(踩过)。
          foldFuel = 4096;
          let params = {};
          let ok = true;
          let ai = 0;
          while ok && ai < node.arguments.length {
            let arg = node.arguments[ai];
            // 缺省注解在 AST 里可能是 Error(字段不存在),不能当成「有注解」。
            if !isError(fn.parameters[ai].annotation) && fn.parameters[ai].annotation != null { ok = false; }
            else if !isLiteralScalar(arg) { ok = false; }
            else {
              let folded = foldEval(arg, {});
              if !folded.ok { ok = false; }
              else { params[fn.parameters[ai].name] = folded; };
            };
            ai = ai + 1;
          };
          if !ok { if foldStatReject == "" { foldStatReject = "args"; }; };
          if ok {
            foldFuel = 4096;
            let result = foldEval(expr, params);
            if result.ok && (result.kind == "Number" || result.kind == "String" || result.kind == "Boolean" || result.kind == "Null") {
              foldIntoLiteral(node, result);
              foldFolded = foldFolded + 1;
              return null;
            };
            foldBailed = foldBailed + 1;
          };
        };
      };
    };
    let keys = std.Object.keys(node); let i = 0;
    while i < keys.length { foldWalk(node[keys[i]], lets); i = i + 1; };
  };
  null;
};

let foldProgram = (stmts, lets) -> {
  foldFolded = 0; foldBailed = 0; foldStatCalls = 0; foldStatReject = "";
  foldStatLets = std.Object.keys(lets).length;
  foldWalk(stmts, lets);
  { folded: foldFolded, bailed: foldBailed, lets: foldStatLets, calls: foldStatCalls, reject: foldStatReject };
};
export foldProgram;
