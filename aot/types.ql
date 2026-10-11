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
// 内建「标量」类型:可解箱(一个机器字即可表示);Array/Object 是引用,另算。
let typeScalar = { Number: true, String: true, Boolean: true, Null: true };
let typeUnboxList = [];   // 标量全局在导入方只是拷贝,列表才共享引用
// 按程序(库/入口/各模块)分开命名空间:同名绑定分布在不同程序里,不能互相污染。
let typeProgram = 0;
// 作用域栈用深度索引,不重赋值数组本身 —— 模块全局的重赋值要穿过闭包,代价与风险都高。
// typeScopes[i] 存名字的类型,typeFnResults[i] 存「已知返回类型的函数绑定」,同深同栈。
let typeScopes = [];
let typeFnResults = [];
let typeDepth = 0;
let typeErrors = [];
// 「表示」栈,与 typeScopes 同深同栈:名字 -> "Number"(裸 double)。缺失即装箱。
// 表示是「值」的属性(编译期算好、标在节点 staticRep 上),不是发射时才决定的。
let typeRepScopes = [];
// 诊断口径:每个程序里各表示各出现多少个节点(只用于量测,不参与生成)。
let typeRepCounts = {};
// 「补类型」的工作清单(按程序分开):推导不出类型的绑定、没有注解的参数。
// 这两样正是 std 类型信息的主要来源 —— 参数写注解,函数体才能按注解定型。
let typeUnknownBinds = {};
let typeUnknownParams = {};
// 记录时截断,免得探针把整棵库都倒出来。
let typeUnknownPush = (sink, name) -> {
  if isError(sink) { return null; };
  if sink.length >= 40 { return null; };
  sink[sink.length] = name;
  null;
};
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
let typePush = () -> { typeScopes[typeDepth] = {}; typeFnResults[typeDepth] = {}; typeRepScopes[typeDepth] = {}; typeDepth = typeDepth + 1; null; };
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

// ---- 表示(裸值 / 装箱)的编译期结论 --------------------------------------------
// 不变式:表示属于「值」,装箱属于「使用点」。这里只算「自然表示」,不看谁消费它;
// 使用点需要装箱时,由生成端在那一个使用点补一次转换,绝不回头改写本结论。
//   "Number" 裸 double      "Boolean" 裸 i1      "" 装箱 %ql_value
let typeRepLookup = (name) -> {
  let i = typeDepth - 1;
  while i >= 0 {
    if !isError(typeRepScopes[i][name]) { return typeRepScopes[i][name]; };
    i = i - 1;
  };
  "";
};
// 空串不适合当对象的键,诊断桶里记作 "boxed"。
let repKey = (rep) -> { if rep == "" { return "boxed"; }; rep; };
let tagRep = (node, rep) -> {
  node.staticRep = rep;
  if isError(typeRepCounts[typeProgram]) { typeRepCounts[typeProgram] = {}; };
  let bucket = typeRepCounts[typeProgram];
  // 键记成「节点种类/静态类型/表示」:这样才能把三件事分开 ——
  // ① 根本不是 Number(String/Object/未知),② 是 Number 但操作数不裸(燃料不够),
  // ③ 真的走了裸路。只看「种类/表示」会把 ① 和 ② 混成一个"装箱"。
  let st = node.staticType;
  if isError(st) { st = "?"; };
  let key = node.type + "/" + st + "/" + repKey(rep);
  if isError(bucket[key]) { bucket[key] = 0; };
  bucket[key] = bucket[key] + 1;
  // 交回「静态类型」而不是「表示」:调用点一律紧跟 tagType,所以 tagRep 可以直接当
  // inferExpr 的返回值用。表示只是标注的附带结论,不能顶替静态类型。
  node.staticType;
};
// 读子节点的表示:没分析过或未知一律当装箱。
let repOf = (n) -> { if isError(n.staticRep) { return ""; }; n.staticRep; };
// 可裸的算术:与语言语义一致 —— / 与 % 会报错,&& || 短路,都不是纯机器运算。
let repRawArith = (op) -> op == "+" || op == "-" || op == "*" || op == "&" || op == "|" || op == "^";
let repCmpOp = (op) -> op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" || op == ">=";

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
  if t == "Number" { tagType(node, "Number"); return tagRep(node, "Number"); };
  if t == "Boolean" { tagType(node, "Boolean"); return tagRep(node, ""); };
  if t == "Null" { tagType(node, "Null"); return tagRep(node, ""); };
  if t == "String" { tagType(node, "String"); return tagRep(node, ""); };
  // 标识符的自然表示 = 它解析到的那个绑定的表示(作用域栈上问,遮蔽与捕获自然正确)。
  if t == "Identifier" { tagType(node, typeLookup(node.name)); return tagRep(node, typeRepLookup(node.name)); };
  if t == "Function" {
    // 函数体同样在编译期分析。参数：注解会在调用点被注解检查强制执行（带注解的实参
    // 类型不符时调用返回错误），所以函数体内可以按注解声明的内建类型来用它。
    typePush();
    let p = 0;
    while p < node.parameters.length {
      let param = node.parameters[p];
      let ptype = annotationBuiltinName(param.annotation);
      if ptype != "" {
        typeScopes[typeDepth - 1][param.name] = ptype;
        // 参数与注解绑定同一前提:调用点的注解检查保证它只持有该类型,所以同样可解箱。
        // 目前只做 Number(裸 double);String 的裸 ptr 还牵扯生命周期,按既定顺序排在后面。
        if ptype == "Number" && isError(typeAssignedNames[typeProgram][param.name]) {
          param.unboxType = ptype;
          typeUnboxList[typeUnboxList.length] = param.name;
          typeRepScopes[typeDepth - 1][param.name] = "Number";
        } else {
          param.unboxType = "";
        };
      } else {
        // 没注解(或注解不是内建类型)的参数:函数体里只能当未知,补类型时优先看这里。
        typeUnknownPush(typeUnknownParams[typeProgram], param.name);
      };
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
    tagType(node, "Function");
    return tagRep(node, "");
  };
  if t == "Object" { tagType(node, "Object"); return tagRep(node, ""); };
  if t == "Array" { tagType(node, "Array"); return tagRep(node, ""); };
  if t == "UnaryOp" {
    let inner = inferExpr(node.operand);
    if node.operator == "!" {
      tagType(node, "Boolean");
      return tagRep(node, if repOf(node.operand) == "Boolean" { "Boolean"; } else { ""; });
    };
    tagType(node, inner);
    return tagRep(node, "");
  };
  if t == "BinaryOp" {
    let op = node.operator;
    let left = inferExpr(node.left);
    let right = inferExpr(node.right);
    // 子节点的表示在分析完它们之后才可读:表示自底向上,一次算定。
    let lrep = repOf(node.left);
    let rrep = repOf(node.right);
    if op == "&&" || op == "||" { tagType(node, "Boolean"); return tagRep(node, ""); };
    if repCmpOp(op) {
      tagType(node, "Boolean");
      return tagRep(node, if lrep == "Number" && rrep == "Number" { "Boolean"; } else { ""; });
    };
    if left == "Number" && right == "Number" {
      tagType(node, "Number");
      return tagRep(node, if repRawArith(op) && lrep == "Number" && rrep == "Number" { "Number"; } else { ""; });
    };
    if op == "+" && (left == "String" || right == "String") { tagType(node, "String"); return tagRep(node, ""); };
    tagType(node, "");
    return tagRep(node, "");
  };
  if t == "MemberAccess" {
    // 先分析对象,std.<模块> 才会带上模块名。
    inferExpr(node.object);
    let obj = node.object;
    if !isError(obj.type) && obj.type == "Identifier" && obj.name == "std" && !typeBound("std") {
      if !isError(stdModuleBinds[node.field]) { node.moduleName = stdModuleBinds[node.field]; tagType(node, "Object"); return tagRep(node, ""); };
      tagType(node, "");
      return tagRep(node, "");
    };
    if !isError(obj.type) && obj.type == "MemberAccess" && !isError(obj.moduleName) {
      let calls = stdFieldCall[obj.moduleName];
      let values = stdFieldValue[obj.moduleName];
      if !isError(calls) && !isError(calls[node.field]) { node.memberReturn = calls[node.field]; tagType(node, "Function"); return tagRep(node, ""); };
      if !isError(values) && !isError(values[node.field]) && values[node.field] != "" { tagType(node, values[node.field]); return tagRep(node, ""); };
    };
    tagType(node, "");
    return tagRep(node, "");
  };
  if t == "Call" {
    // 调用结果的类型:callee 是「返回类型已知、绑定稳定」的函数绑定,或是 std 的成员函数。
    if !isError(node.callee.type) && node.callee.type == "Identifier" {
      let rt = typeFnLookup(node.callee.name);
      if rt != "" { tagType(node, rt); return tagRep(node, ""); };
    };
    if !isError(node.callee.type) && node.callee.type == "MemberAccess"
        && !isError(node.callee.memberReturn) && node.callee.memberReturn != "" {
      tagType(node, node.callee.memberReturn);
      return tagRep(node, "");
    };
    tagType(node, "");
    return tagRep(node, "");
  };
  tagType(node, "");
  return tagRep(node, "");
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
        s.runtimeTypeFree = isError(typeUnknownWrites[typeProgram][s.name]);
      } else {
        s.runtimeTypeFree = false;
      };
      // 可解箱:类型是 Number,且每次写入右值静态类型都已知(与 runtimeTypeFree 同一前提)。
      // 不再要求「写了注解」:推导出 Number 的绑定同样能用 —— 只要每次写入的类型都已知,
      // 槽里就一直是 double。模块根(深度 1)一律不解箱:扩展桥会把帧 memcpy 给解释器。
      // 目前只做 Number;String 的裸 ptr 还牵扯生命周期,按既定顺序排在后面。
      let effective = if declared != "" { declared; } else { value; };
      // 类型推不出来的绑定(常来自「返回类型未知的调用」):补类型清单的头一批。
      if effective == "" { typeUnknownPush(typeUnknownBinds[typeProgram], s.name); };
      s.unboxType = "";
      if typeDepth > 1 && effective == "Number" && isError(typeUnknownWrites[typeProgram][s.name]) {
        s.unboxType = "Number";
        typeUnboxList[typeUnboxList.length] = s.name;
        // 此绑定之后的引用都能在表示栈上问出它是裸 double。
        typeRepScopes[typeDepth - 1][s.name] = "Number";
      };
      // 返回类型已知、且绑定稳定(从未被赋值)的函数:登记它,调用点才能拿到类型。
      if s.value != null && !isError(s.value.returnType) && s.value.returnType != "" && isError(typeAssignedNames[typeProgram][s.name]) {
        typeFnResults[typeDepth - 1][s.name] = s.value.returnType;
      };
    } else if t == "Assign" {
      if !isError(s.target.type) && s.target.type == "Identifier" {
        typeAssignedNames[typeProgram][s.target.name] = true;
        let value = inferExpr(s.value);
        let declared = typeLookup(s.target.name);
        // 只有「右值类型已知且与声明一致」才可能省掉运行期检查。类型未知,或已知
        // 但不一致(此时运行期必须报 TypeCheck),都保留检查。
        if value == "" || isError(value) { typeUnknownWrites[typeProgram][s.target.name] = true; }
        else if declared != "" && value != declared { typeUnknownWrites[typeProgram][s.target.name] = true; };
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
  typeProgram = typeProgram + 1;
  typeUnknownWrites[typeProgram] = {};
  typeAssignedNames[typeProgram] = {};
  typeScopes[0] = {};
  typeFnResults[0] = {};
  typeRepScopes[0] = {};
  typeDepth = 1;
  typeReturnDepth = 0;
  inferStmts(stmts);
  // 第二遍才是权威口径:第一遍只负责把每次写入的右值类型收齐,第二遍据此判定可解箱性;
  // 计数与两张工作清单也在第二遍重来,免得把两遍的遍历算成两份。
  typeScopes[0] = {};
  typeFnResults[0] = {};
  typeRepScopes[0] = {};
  typeRepCounts[typeProgram] = {};
  typeUnknownBinds[typeProgram] = [];
  typeUnknownParams[typeProgram] = [];
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

// 计数与程序数都要经函数交回调用方:模块全局在导入方读到的是拷贝,函数里读的才是模块
// 自己那份(与 inferTypes 交回 typeErrors 同一个道理)。
let typeRepReport = () -> typeRepCounts;
let typeRepPrograms = () -> typeProgram;
// 补类型的两张工作清单:推导不出类型的绑定、没有注解的参数(每程序最多记 40 条)。
let typeBindsUnknown = () -> typeUnknownBinds;
let typeParamsUnknown = () -> typeUnknownParams;

export inferTypes;
export buildStdTypes;
export isStaticNumber;
export checkIsDead;
export typeErrors;
export typeUnboxList;
export typeRepReport;
export typeRepPrograms;
export typeBindsUnknown;
export typeParamsUnknown;
