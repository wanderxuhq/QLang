// aot/types.ql —— 编译期分析:生成代码之前,先在 AST 上收集类型信息。
//
// 这是独立阶段,不是发射器的一部分:它在任何代码生成之前跑完整个程序(含函数体、
// import 进来的模块、标准库源码),把结论标在 AST 节点上,并在这里报出静态类型错误。
// 发射器只读这些标注 —— 不再自己推断类型,也不再维护与发射顺序耦合的状态。
//
// 作用域用词法作用域栈解析名字:遮蔽由作用域本身处理。内建类型名(Number/String/
// Boolean/Null/Array/Object/AnyArray/AnyObject)只有在没有任何词法绑定遮蔽它时,
// 才算"就是那个内建类型" —— 否则一律当作未知,不做任何特化。
let typeBuiltins = { Number: true, String: true, Boolean: true, Null: true, Array: true, Object: true, AnyArray: true, AnyObject: true };
// 作用域栈用深度索引,不重赋值数组本身 —— 模块全局的重赋值要穿过闭包,代价与风险都高。
// typeScopes[i] 存名字的类型,typeFnResults[i] 存「已知返回类型的函数绑定」,同深同栈。
let typeScopes = [];
let typeFnResults = [];
let typeDepth = 0;
let typeErrors = [];
// 存在「右值静态类型未知」写入的名字:这些绑定的运行期注解检查必须保留。
let typeUnknownWrites = {};
// 被赋值过的名字:绑定不再稳定,函数返回类型这类推导结论不能落在它上面。
let typeAssignedNames = {};
// 正在分析的函数体所收集的 return 类型(嵌套函数各占一层)。
let typeReturnStack = [];
let typeReturnDepth = 0;

let typeReport = (node, message) -> {
  let point = node.location;
  if isError(point) { typeErrors[typeErrors.length] = message; return null; };
  typeErrors[typeErrors.length] = point.file + ":" + std.String.toString(point.line) + ":" + std.String.toString(point.col) + ": " + message;
  null;
};
let typeLookup = (name) -> {
  let i = typeDepth - 1;
  while i >= 0 {
    if !isError(typeScopes[i][name]) { return typeScopes[i][name]; };
    i = i - 1;
  };
  if isError(typeBuiltins[name]) { return ""; };
  name;
};
let typePush = () -> { typeScopes[typeDepth] = {}; typeFnResults[typeDepth] = {}; typeDepth = typeDepth + 1; null; };
let typePop = () -> { typeDepth = typeDepth - 1; null; };
// 词法查找:这个名字是不是「返回类型已知的函数绑定」。
let typeFnLookup = (name) -> {
  let i = typeDepth - 1;
  while i >= 0 {
    if !isError(typeFnResults[i][name]) { return typeFnResults[i][name]; };
    i = i - 1;
  };
  "";
};
let tagType = (node, name) -> { node.staticType = name; name; };

// 该名字是否真的被某个词法作用域绑定。注意不能用 typeLookup 判断:它对未绑定的
// 内建名会回退成"返回名字本身",无法区分"用户绑定"和"内建回退"。
let typeBound = (name) -> {
  let i = typeDepth - 1;
  while i >= 0 {
    if !isError(typeScopes[i][name]) { return true; };
    i = i - 1;
  };
  false;
};
// 注解所指的内建类型;不是内建(或被遮蔽、或是组合类型表达式)就是 ""。
let annotationBuiltinName = (annotation) -> {
  if isError(annotation) || annotation == null { return ""; };
  if isError(annotation.type) || annotation.type != "Identifier" { return ""; };
  if typeBound(annotation.name) { return ""; };
  if isError(typeBuiltins[annotation.name]) { return ""; };
  annotation.name;
};
let inferAnnotationType = (node) -> annotationBuiltinName(node.annotation);

// ---- std 成员类型(供 std.Math.sqrt(x) 之类的调用也在编译期定型) ----------------
// 标准库源码里,模块对象是普通的对象字面量(如 MathLibrary = { sqrt: squareRoot, PI: 3.14 }),
// 导出对象把它们挂到模块名上(Math: MathLibrary)。两者都在 AST 上,所以成员类型是纯
// 编译期信息:字段是函数就取它的返回类型,是字面量就取字面量类型。
let stdModuleBinds = {};   // 模块名(导出字段)-> 模块对象的绑定名
let stdFieldCall = {};     // 绑定名 -> { 字段 -> 该成员函数的返回类型 }
let stdFieldValue = {};    // 绑定名 -> { 字段 -> 该成员值的类型 }
let stdValueBinds = {};    // 库内顶层绑定名 -> 其值节点(用于识别函数成员)

let stdScanLet = (node) -> {
  if isError(node) || node == null { return null; };
  if isError(node.type) || node.type != "Let" || node.value == null { return null; };
  if !isError(node.value.type) && node.value.type == "Object" {
    let callMap = {}; let valueMap = {}; let fieldIndex = 0;
    while fieldIndex < node.value.fields.length {
      let field = node.value.fields[fieldIndex];
      let fv = field.value;
      if !isError(fv.type) && fv.type == "Identifier" {
        let target = stdValueBinds[fv.name];
        if !isError(target) && !isError(target.type) && target.type == "Function" {
          if !isError(target.returnType) && target.returnType != "" { callMap[field.name] = target.returnType; };
        } else if !isError(target) { valueMap[field.name] = target.staticType; };
      } else if !isError(fv.staticType) && fv.staticType != "" {
        valueMap[field.name] = fv.staticType;
      };
      fieldIndex = fieldIndex + 1;
    };
    stdFieldCall[node.name] = callMap;
    stdFieldValue[node.name] = valueMap;
  } else if !isError(node.value.type) && node.value.type == "Function" {
    stdValueBinds[node.name] = node.value;
  };
  // 库里可能有嵌套的 let(例如模块工厂内部),一并收集。
  if !isError(node.value.type) && node.value.type == "Function" && node.value.body != null {
    let i = 0;
    while i < node.value.body.statements.length { stdScanLet(node.value.body.statements[i]); i = i + 1; };
  };
  null;
};
// 导出对象:字段值都是「指向对象字面量的标识符」的那个对象字面量。
let stdScanExports = (node) -> {
  if isError(node) || node == null { return null; };
  if isError(node.type) || node.type != "Let" || node.value == null { return null; };
  if !isError(node.value.type) && node.value.type == "Object" {
    let fields = node.value.fields; let j = 0; let looksLikeExports = fields.length > 0;
    while j < fields.length {
      let fv = fields[j].value;
      if isError(fv.type) || fv.type != "Identifier" || isError(stdFieldCall[fv.name]) { looksLikeExports = false; };
      j = j + 1;
    };
    if looksLikeExports {
      j = 0;
      while j < fields.length { stdModuleBinds[fields[j].name] = fields[j].value.name; j = j + 1; };
    };
  };
  if !isError(node.value.type) && node.value.type == "Function" && node.value.body != null {
    let i = 0;
    while i < node.value.body.statements.length { stdScanExports(node.value.body.statements[i]); i = i + 1; };
  };
  null;
};
let buildStdTypes = (stmts) -> {
  let i = 0;
  while i < stmts.length { stdScanLet(stmts[i]); i = i + 1; };
  i = 0;
  while i < stmts.length { stdScanExports(stmts[i]); i = i + 1; };
  null;
};

let inferExpr = (node) -> {
  let t = node.type;
  if t == "Number" { return tagType(node, "Number"); };
  if t == "Boolean" { return tagType(node, "Boolean"); };
  if t == "Null" { return tagType(node, "Null"); };
  if t == "String" { return tagType(node, "String"); };
  if t == "Identifier" { return tagType(node, typeLookup(node.name)); };
  if t == "Function" {
    // 函数体同样在编译期分析。参数：注解会在调用点被注解检查强制执行（带注解的实参
    // 类型不符时调用返回错误），所以函数体内可以按注解声明的内建类型来用它。
    typePush();
    let p = 0;
    while p < node.parameters.length {
      let param = node.parameters[p];
      let ptype = annotationBuiltinName(param.annotation);
      if ptype != "" { typeScopes[typeDepth - 1][param.name] = ptype; };
      p = p + 1;
    };
    typeReturnStack[typeReturnDepth] = [];
    typeReturnDepth = typeReturnDepth + 1;
    let tail = inferStmts(node.body.statements);
    let returns = typeReturnStack[typeReturnDepth - 1];
    typeReturnDepth = typeReturnDepth - 1;
    // 返回类型 = 尾表达式类型 与 所有 return 的类型 的交集:只要有一处未知或彼此
    // 不一致,就记未知(宁可不特化,也不猜)。
    let result = if isError(tail) { ""; } else { tail; };
    let r = 0;
    while r < returns.length {
      let one = returns[r];
      if one == "" { result = ""; }
      else if result == "" { result = one; }
      else if result != one { result = ""; };
      r = r + 1;
    };
    node.returnType = result;
    typePop();
    return tagType(node, "Function");
  };
  if t == "Object" { return tagType(node, "Object"); };
  if t == "Array" { return tagType(node, "Array"); };
  if t == "UnaryOp" {
    let inner = inferExpr(node.operand);
    if node.operator == "!" { return tagType(node, "Boolean"); };
    return tagType(node, inner);
  };
  if t == "BinaryOp" {
    let op = node.operator;
    let left = inferExpr(node.left);
    let right = inferExpr(node.right);
    if op == "&&" || op == "||" { return tagType(node, "Boolean"); };
    if op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" || op == ">=" { return tagType(node, "Boolean"); };
    if left == "Number" && right == "Number" { return tagType(node, "Number"); };
    if op == "+" && (left == "String" || right == "String") { return tagType(node, "String"); };
    return tagType(node, "");
  };
  if t == "MemberAccess" {
    // 先分析对象,std.<模块> 才会带上模块名。
    inferExpr(node.object);
    let obj = node.object;
    if !isError(obj.type) && obj.type == "Identifier" && obj.name == "std" && !typeBound("std") {
      if !isError(stdModuleBinds[node.field]) { node.moduleName = stdModuleBinds[node.field]; return tagType(node, "Object"); };
      return tagType(node, "");
    };
    if !isError(obj.type) && obj.type == "MemberAccess" && !isError(obj.moduleName) {
      let calls = stdFieldCall[obj.moduleName];
      let values = stdFieldValue[obj.moduleName];
      if !isError(calls) && !isError(calls[node.field]) { node.memberReturn = calls[node.field]; return tagType(node, "Function"); };
      if !isError(values) && !isError(values[node.field]) && values[node.field] != "" { return tagType(node, values[node.field]); };
    };
    return tagType(node, "");
  };
  if t == "Call" {
    // 调用结果的类型:callee 是「返回类型已知、绑定稳定」的函数绑定,或是 std 的成员函数。
    if !isError(node.callee.type) && node.callee.type == "Identifier" {
      let rt = typeFnLookup(node.callee.name);
      if rt != "" { return tagType(node, rt); };
    };
    if !isError(node.callee.type) && node.callee.type == "MemberAccess"
        && !isError(node.callee.memberReturn) && node.callee.memberReturn != "" {
      return tagType(node, node.callee.memberReturn);
    };
    return tagType(node, "");
  };
  tagType(node, "");
};

// 返回本块的「尾值类型」。尾值的判定与发射器一致:表达式语句产生值,If 产生值但类型
// 这里不推导(记未知),Let/Assign/While/Return/Export/Import 不产生值(尾值保持不变)。
let inferStmts = (stmts) -> {
  let tail = "";
  let i = 0;
  while i < stmts.length {
    let s = stmts[i];
    let t = s.type;
    if t == "Let" {
      let declared = inferAnnotationType(s);
      s.annotationType = declared;
      let value = if s.value == null { ""; } else { inferExpr(s.value); };
      // 两边在编译期都有确定类型却对不上 —— 这就是编译期错误,不必留到运行期。
      if declared != "" && value != "" && value != declared {
        typeReport(s, "type mismatch: value of type " + value + " does not match the annotated type " + declared);
      };
      typeScopes[typeDepth - 1][s.name] = if declared != "" { declared; } else { value; };
      // 该绑定是否需要运行期的类型槽与检查:只有当存在「右值静态类型未知」的写入时
      // 才需要兜底。否则每一次写入都在编译期可判定,检查不可能失败。
      if declared != "" {
        s.runtimeTypeFree = isError(typeUnknownWrites[s.name]);
      } else {
        s.runtimeTypeFree = false;
      };
      // 返回类型已知、且绑定稳定(从未被赋值)的函数:登记它,调用点才能拿到类型。
      if s.value != null && !isError(s.value.returnType) && s.value.returnType != "" && isError(typeAssignedNames[s.name]) {
        typeFnResults[typeDepth - 1][s.name] = s.value.returnType;
      };
    } else if t == "Assign" {
      if !isError(s.target.type) && s.target.type == "Identifier" {
        typeAssignedNames[s.target.name] = true;
        let value = inferExpr(s.value);
        let declared = typeLookup(s.target.name);
        // 只有「右值类型已知且与声明一致」才可能省掉运行期检查。类型未知,或已知
        // 但不一致(此时运行期必须报 TypeCheck),都保留检查。
        if value == "" || isError(value) { typeUnknownWrites[s.target.name] = true; }
        else if declared != "" && value != declared { typeUnknownWrites[s.target.name] = true; };
        // 写入目标声明的内建类型(供发射器判定重检查是否为死代码)。
        s.declaredType = if isError(typeBuiltins[declared]) { ""; } else { declared; };
        // 有注解的绑定写入时会重新检查,所以它保持自己的类型;推导出来的类型一旦
        // 与某个赋值的类型不一致就作废。
        typeScopes[typeDepth - 1][s.target.name] =
          if isError(typeBuiltins[declared]) { declared; }
          else if value == declared { declared; }
          else { ""; };
      } else {
        inferExpr(s.target.object);
        if !isError(s.target.index) { inferExpr(s.target.index); };
        inferExpr(s.value);
      };
    } else if t == "If" {
      // if 作为尾值时,取各分支尾值的公共类型:全一致就用它,否则未知。没有 else 的
      // if 在条件为假时其值来自更早的语句,这里不做拼接,直接记未知(保守)。
      let joined = ""; let first = true; let mixed = false;
      let b = 0;
      while b < s.branches.length {
        inferExpr(s.branches[b].condition);
        typePush();
        let branchTail = inferStmts(s.branches[b].body.statements);
        typePop();
        if first { joined = branchTail; first = false; }
        else if branchTail != joined { mixed = true; };
        b = b + 1;
      };
      if s.elseBody != null {
        typePush();
        let elseTail = inferStmts(s.elseBody.statements);
        typePop();
        if first { joined = elseTail; first = false; }
        else if elseTail != joined { mixed = true; };
      } else {
        mixed = true;
      };
      tail = if mixed { ""; } else { joined; };
    } else if t == "While" {
      inferExpr(s.condition);
      typePush(); inferStmts(s.body.statements); typePop();
    } else if t == "Return" {
      let rt = "";
      if s.value != null { rt = inferExpr(s.value); if isError(rt) { rt = ""; }; };
      if typeReturnDepth > 0 {
        let sink = typeReturnStack[typeReturnDepth - 1];
        sink[sink.length] = rt;
      };
    } else if t == "Export" { inferExpr(s.value); }
    else if t == "Import" { }
    else {
      tail = inferExpr(s);
      if isError(tail) { tail = ""; };
    };
    i = i + 1;
  };
  tail;
};

// 对一个程序(入口 / import 的模块 / 标准库)跑两遍:第一遍得出每个写入右值的静态
// 类型,第二遍据此判定哪些绑定可以完全不要运行期的类型槽与检查。错误跨程序累积,
// 并以返回值交回调用方 —— 不依赖「调用方读到的模块全局」与「模块自己写的」是同一个引用。
let inferTypes = (stmts) -> {
  typeScopes[0] = {};
  typeFnResults[0] = {};
  typeDepth = 1;
  typeReturnDepth = 0;
  inferStmts(stmts);
  typeScopes[0] = {};
  typeFnResults[0] = {};
  typeDepth = 1;
  typeReturnDepth = 0;
  inferStmts(stmts);
  typeErrors;
};

let isStaticNumber = (node) -> !isError(node.staticType) && node.staticType == "Number";
// 右值静态类型已等于目标声明的内建类型 ⇒ 写入时的注解检查不可能失败(死代码)。
let checkIsDead = (valueNode, declaredName) -> {
  if declaredName == "" { return false; };
  if isError(valueNode.staticType) { return false; };
  valueNode.staticType == declaredName;
};

export inferTypes;
export buildStdTypes;
export isStaticNumber;
export checkIsDead;
export typeErrors;
