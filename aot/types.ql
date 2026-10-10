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
let typeScopes = [];
let typeDepth = 0;
let typeErrors = [];

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
let typePush = () -> { typeScopes[typeDepth] = {}; typeDepth = typeDepth + 1; null; };
let typePop = () -> { typeDepth = typeDepth - 1; null; };
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
    inferStmts(node.body.statements);
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
  tagType(node, "");
};

let inferStmts = (stmts) -> {
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
      typeScopes[typeScopes.length - 1][s.name] = if declared != "" { declared; } else { value; };
    } else if t == "Assign" {
      if !isError(s.target.type) && s.target.type == "Identifier" {
        let value = inferExpr(s.value);
        let declared = typeLookup(s.target.name);
        // 写入目标声明的内建类型(供发射器判定重检查是否为死代码)。
        s.declaredType = if isError(typeBuiltins[declared]) { ""; } else { declared; };
        // 有注解的绑定写入时会重新检查,所以它保持自己的类型;推导出来的类型一旦
        // 与某个赋值的类型不一致就作废。
        typeScopes[typeScopes.length - 1][s.target.name] =
          if isError(typeBuiltins[declared]) { declared; }
          else if value == declared { declared; }
          else { ""; };
      } else {
        inferExpr(s.target.object);
        if !isError(s.target.index) { inferExpr(s.target.index); };
        inferExpr(s.value);
      };
    } else if t == "If" {
      let b = 0;
      while b < s.branches.length {
        inferExpr(s.branches[b].condition);
        typePush(); inferStmts(s.branches[b].body.statements); typePop();
        b = b + 1;
      };
      if s.elseBody != null { typePush(); inferStmts(s.elseBody.statements); typePop(); };
    } else if t == "While" {
      inferExpr(s.condition);
      typePush(); inferStmts(s.body.statements); typePop();
    } else if t == "Return" { if s.value != null { inferExpr(s.value); }; }
    else if t == "Export" { inferExpr(s.value); }
    else if t == "Import" { };
    i = i + 1;
  };
  null;
};

// 对一个程序(入口 / import 的模块 / 标准库)跑一遍;错误跨程序累积,并以返回值
// 交回调用方 —— 不依赖「调用方读到的模块全局」与「模块自己写的」是同一个引用。
let inferTypes = (stmts) -> {
  typeScopes[0] = {};
  typeDepth = 1;
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
export isStaticNumber;
export checkIsDead;
export typeErrors;
