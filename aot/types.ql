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
// 类型名归属的「族」:对象/数组的**基构造器名**与**具体名**同族。
// 族内不做静态比较(两个 AnyObject 不可互换,`Object(schema)` 比它更窄 ⇒ 更窄的判断留给运行期
// check);只有族与族之间(以及标量之间)的不一致才是编译期可判的。详见 docs/object-array-type-names.md。
let typeNameFamily = (name) -> {
  if isError(name) || name == "" { return ""; };
  if name == "Array" || name == "AnyArray" { return "Array"; };
  if name == "Object" || name == "AnyObject" { return "Object"; };
  name;
};
let typeMismatch = (declared, value) -> {
  let fd = typeNameFamily(declared); let fv = typeNameFamily(value);
  fd != "" && fv != "" && fd != fv;
};
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
// 「该值能否是 Error」的编译期结论(传染安全):一个绑定安全,当且仅当每次写入它都不可能
// 把 Error 存进槽里(除以变量零、调用、成员/索引都可能产出 Error,即使静态类型是标量)。
// 与表示一样只在分析期算,生成端只读结果 —— 据此省掉 emitLocatedError 的定位测试。
// 绑定图放在编译器内部表里、节点上只留数字 id:发射器的 reserveModuleBindings 等会遍历
// 节点的每个属性,若把绑定节点引用挂上去就会走进环(实测会卡死)。
let typeBindScopes = [];
let typeBindTable = {};
let typeBindCount = {};
let typeCollectWrites = false;
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
let typePush = () -> { typeScopes[typeDepth] = {}; typeFnResults[typeDepth] = {}; typeRepScopes[typeDepth] = {}; typeBindScopes[typeDepth] = {}; typeNarrowScopes[typeDepth] = {}; typeDepth = typeDepth + 1; null; };
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

// ---- 收窄(「守卫之后的落到点」)----------------------------------------------------------
// 事实栈与 typeScopes 同深同栈:名字 → 该作用域内是否已知「不是 Error」。由守卫
// (if !X.check(v) { …必然退出… } / if isError(v) { …必然退出… })在落到点上建立,被赋值作废。
// 它不产生新语义,只让发射端能把本已死掉的检查判为死代码。
let typeNarrowScopes = {};
let typeNarrowed = (name) -> {
  let i = typeDepth - 1;
  while i >= 0 {
    if !isError(typeNarrowScopes[i][name]) && typeNarrowScopes[i][name] == true { return true; };
    i = i - 1;
  };
  false;
};
// 语句序列是否「必然退出」(末句 return)。
let branchAlwaysExits = (stmts) -> {
  if isError(stmts) || stmts.length == 0 { return false; };
  let last = stmts[stmts.length - 1];
  !isError(last.type) && last.type == "Return";
};
// 守卫取反后的事实:if <cond> { …必然退出… } ⇒ 落到点知道 <cond> 为假。
// !X.check(v) 为假 ⇒ v 是 X;isError(v) 为假 ⇒ v 不是 Error。其余(如 X.check(v) 为假 ⇒
// 「不是 X」)无法用现有类型表达,忽略。写入的是**当前(外层)**作用域,即落到点所在者。
let narrowAfterGuard = (cond, exits) -> {
  if !exits { return null; };
  if cond == null || isError(cond) || isError(cond.type) { return null; };
  let inner = cond;
  let negated = false;
  if cond.type == "UnaryOp" && (cond.operator == "!" || cond.operator == "not") {
    inner = cond.operand; negated = true;
  };
  if inner == null || isError(inner) || isError(inner.type) || inner.type != "Call" { return null; };
  let callee = inner.callee;
  if isError(callee) || isError(callee.type) { return null; };
  if isError(inner.arguments) || inner.arguments.length != 1 { return null; };
  let av = inner.arguments[0];
  if isError(av) || isError(av.type) || av.type != "Identifier" { return null; };
  if callee.type == "Identifier" && callee.name == "isError" && !negated {
    typeNarrowScopes[typeDepth - 1][av.name] = true;
    return null;
  };
  if callee.type != "MemberAccess" { return null; };
  let base = callee.object;
  if isError(base) || isError(base.type) || base.type != "Identifier" { return null; };
  if callee.field != "check" { return null; };
  if typeBound(base.name) || isError(typeBuiltins[base.name]) { return null; };
  if negated {
    typeScopes[typeDepth - 1][av.name] = base.name;
    typeNarrowScopes[typeDepth - 1][av.name] = true;
  };
  null;
};

// 裸构造器不是类型值(`Array`/`Object` 是 `__arr_ctor`/`__obj_ctor`,没有 `check`),当注解写是错的:
// 具体类型写 `AnyArray`/`AnyObject`,或用构造式 `Array(T)`/`Object(...)`。这一条把「注解名写错」
// 从「运行期才炸」变成「编译期报错」—— 它正是 §5⑥a 那个错误的成因。
let annotationRejectConstructor = (annNode) -> {
  if annNode == null || isError(annNode) { return null; };
  if isError(annNode.type) || annNode.type != "Identifier" { return null; };
  if annNode.name != "Array" && annNode.name != "Object" { return null; };
  if typeLookup(annNode.name) != annNode.name { return null; };
  typeReport(annNode, annNode.name + " is a constructor, not a type: use Any" + annNode.name + " for any " + annNode.name + ", or a constructed form like " + annNode.name + "(Number)");
  null;
};

// ---- ②a 量测:裸 ABI(参数与返回都是 Number)的覆盖面 ------------------------------
// 只计数,不改变任何生成决策 —— 目的是先拿到「有多少调用点吃得到裸签名」这个数,
// 再决定要不要动调用约定。函数体保持盒约定时这些计数完全不影响输出。
let rawAbiFuncTotal = 0;
let rawAbiFuncParams = 0;
let rawAbiFuncAll = 0;
let rawAbiFuncRet = 0;
let rawAbiFuncAny = 0;
let rawAbiParamCount = 0;
let rawAbiCallTotal = 0;
let rawAbiCallKnown = 0;
let rawAbiCallArity = 0;
let rawAbiCallRaw = 0;
let rawAbiCallRet = 0;
let rawAbiAnnotParams = 0;
let rawAbiNoWriteParams = 0;
let rawAbiCallRetAny = 0;
let rawAbiCallNumArgs = 0;
let rawAbiSigCount = {};
let rawAbiSigAll = {};
let rawAbiSigRet = {};
let rawAbiKey = (name) -> std.String.toString(typeProgram) + ":" + name;
let rawAbiReport = () -> [rawAbiFuncTotal, rawAbiFuncParams, rawAbiFuncAll, rawAbiCallTotal, rawAbiCallKnown, rawAbiCallArity, rawAbiCallRaw, rawAbiFuncRet, rawAbiFuncAny, rawAbiParamCount, rawAbiCallRet, rawAbiAnnotParams, rawAbiNoWriteParams, rawAbiCallRetAny, rawAbiCallNumArgs, typeSafeMarked];
export rawAbiReport;

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
// 词法查找:名字 -> 绑定 id。缺失返回 -1(未知一律当「可能是 Error」,保守)。
let typeBindLookup = (name) -> {
  let i = typeDepth - 1;
  while i >= 0 {
    if !isError(typeBindScopes[i][name]) { return typeBindScopes[i][name]; };
    i = i - 1;
  };
  -1;
};
// 两侧静态类型已知时,这个二元运算「本身」会不会造出 Error(不含操作数携带的 Error)。
// 照生成端实际走的路判定:两侧都是 Number 走内联 fadd/fcmp/位运算,不会;两侧都是 String
// 的 + 走拼接,不会;==/!= 是标签感知的全函数;其余(混合类型、除/模、短路)都可能报错。
let typeOpCreatesError = (op, lt, rt) -> {
  if isError(lt) || isError(rt) { return true; };
  if isError(typeScalar[lt]) || isError(typeScalar[rt]) { return true; };
  if op == "==" || op == "!=" { return false; };
  if op == "+" { return !((lt == "Number" && rt == "Number") || (lt == "String" && rt == "String")); };
  if op == "-" || op == "*" || op == "&" || op == "|" || op == "^"
     || op == "<" || op == "<=" || op == ">" || op == ">=" { return !(lt == "Number" && rt == "Number"); };
  true;
};
// 结构上「可能产出 Error」:字面量与 ! 不会;一元 +/- 仅在操作数是 Number 时随操作数;二元
// 运算在两侧类型已知且该运算本身不会报错时随操作数;其余一律会。Identifier 随其绑定。
// 这是「能否是 Error」的唯一判据。
let typeProneOf = (node) -> {
  if node == null || isError(node) { return true; };
  let t = node.type;
  if t == "Number" || t == "Boolean" || t == "Null" || t == "String" || t == "Function" { return false; };
  if t == "Identifier" {
    if isError(node.bindId) || node.bindId < 0 { return true; };
    let st = typeBindTable[typeProgram][node.bindId];
    if isError(st) { return true; };
    return typeBindingProne(st);
  };
  if t == "UnaryOp" {
    if node.operator == "!" { return false; };
    if node.operator == "-" || node.operator == "+" {
      if node.operand.staticType == "Number" { return typeProneOf(node.operand); };
      return true;
    };
    return true;
  };
  if t == "BinaryOp" {
    if node.operator == "&&" || node.operator == "||" { return true; };
    if typeOpCreatesError(node.operator, node.left.staticType, node.right.staticType) { return true; };
    return typeProneOf(node.left) || typeProneOf(node.right);
  };
  true;
};
// 绑定安全性:带记忆的深度优先 + 环内乐观。QLang 的确定赋值保证环里没有未初始化读,所以
// 环内没有 Error 来源 —— 乐观假设可靠,且整体是 O(节点数)(全量迭代曾是 O(n²),太慢)。
let typeBindingProne = (st) -> {
  if st == null || isError(st) { return true; };
  if st.done == true { return st.prone; };
  if st.busy == true { return false; };
  st.busy = true;
  let prone = st.base;
  let j = 0;
  while j < st.writes.length {
    if typeProneOf(st.writes[j]) { prone = true; };
    j = j + 1;
  };
  st.busy = false;
  st.done = true;
  st.prone = prone;
  prone;
};
// 第一遍收齐写入集后,把每个绑定解到不动点(每个只解一次)。
let typeSolveWrites = (list) -> {
  let i = 0;
  while i < list.length { typeBindingProne(list[i]); i = i + 1; };
  null;
};
// runtimeTypeFree was decided during collection from "no unknown-type writes".
// A known static type can still be an Error (division by a variable zero, a
// call whose result is not proven), so refine it after the prone fixpoint:
// only bindings whose every write is provably Error-free may drop the runtime
// type slot and check.
let typeRefreshRuntimeChecks = (list) -> {
  let i = 0;
  while i < list.length {
    let st = list[i];
    if !isError(st) && !isError(st.decl) && st.decl != null && st.decl.runtimeTypeFree == true {
      if st.prone == true || st.unk == true { st.decl.runtimeTypeFree = false; };
    };
    i = i + 1;
  };
  null;
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
// 运行期程序自己定义了类型单例(`let Number = {check: __pred_number}` 等),在那里面
// `Number` 是被绑定的 —— 但它就是那个内建类型本身,所以该程序里放行(typeDefinesBuiltins)。
let typeDefinesBuiltins = false;
let typeSetDefinesBuiltins = (v) -> { typeDefinesBuiltins = v; null; };
export typeSetDefinesBuiltins;
let annotationBuiltinName = (annotation) -> {
  if isError(annotation) || annotation == null { return ""; };
  if isError(annotation.type) || annotation.type != "Identifier" { return ""; };
  if typeBound(annotation.name) {
    if !typeDefinesBuiltins { return ""; };
    if isError(typeBuiltins[annotation.name]) { return ""; };
    return annotation.name;
  };
  if isError(typeBuiltins[annotation.name]) { return ""; };
  annotation.name;
};
let inferAnnotationType = (node) -> annotationBuiltinName(node.annotation);

// ---- 运行期成员的语言侧声明(缺口2 的第一批) ------------------------------------
// 只收「全的」成员:任何输入都返回同一类型、绝不返回 Error。内建类型上的 check 谓词
// 正是如此(不是该类型 -> false),所以这条声明可靠,不依赖调用点检查。
// 其余运行期成员(ldexp/frexp/codePointAt…)在参数不对时会返回 Error,声明其返回类型
// 只有在调用点能被强制检查时才可靠;运行期成员没有可强制的参数注解,故暂不声明。
let typeRuntimePredicates = {
  "Number.check": "Boolean", "String.check": "Boolean", "Boolean.check": "Boolean",
  "Array.check": "Boolean", "Object.check": "Boolean",
  "AnyArray.check": "Boolean", "AnyObject.check": "Boolean", "Type.check": "Boolean",
};

// ---- std 成员类型(供 std.Math.sqrt(x) 之类的调用也在编译期定型) ----------------
// 标准库源码里,模块对象是普通的对象字面量(如 MathLibrary = { sqrt: squareRoot, PI: 3.14 }),
// 导出对象把它们挂到模块名上(Math: MathLibrary)。两者都在 AST 上,所以成员类型是纯
// 编译期信息:字段是函数就取它的返回类型,是字面量就取字面量类型。
// 一般模块索引:导出表的字段名就是模块名,与值是什么种类无关(对象、工厂调用、函数都算)。
// 导出表 = 字段值全为标识符的对象字面量 —— 标准库包装函数的尾对象、运行期的 std 字面量,
// 将来也包括用户模块的导出。成员类型只在该模块值静态可见(对象字面量)时才有,所以工厂
// 产出的模块其成员仍是未知 —— 这是可知性限制,不是特权。
let stdLetValues = {};     // 绑定名 -> 其值节点(判断模块值的种类)
let stdFieldCall = {};     // 绑定名 -> { 成员 -> 成员函数返回类型 }(静态可见的对象字面量)
let stdFieldValue = {};    // 绑定名 -> { 成员 -> 成员值类型 }
let stdModuleType = {};    // 模块名 -> 导出值的类型(Object/Function/"")
let stdModuleCalls = {};   // 模块名 -> { 成员 -> 成员函数返回类型 }
let stdModuleValues = {};  // 模块名 -> { 成员 -> 成员值类型 }
let stdValueBinds = {};    // 库内顶层绑定名 -> 其值节点(用于识别函数成员)
// 命中数:能解析成已知类型的 std.<模块>.<成员> 有多少,解析不出的有多少(按程序)。
let typeNsResolved = {};
let typeNsUnresolved = {};
// 解析不出的 std.<模块>.<成员> 名字(补签名的工作清单,截断以免刷屏)。
let typeNsUnresolvedNames = [];
let typeNsPushName = (s) -> { if typeNsUnresolvedNames.length >= 60 { return null; }; typeNsUnresolvedNames[typeNsUnresolvedNames.length] = s; null; };
// 标准库包装函数把 std 当参数收(`(std) -> …`),运行期则 `let std = {…}`;这两个程序里
// 被绑定的 `std` 就是命名空间本身,允许解析。用户程序里 `std` 未被绑定,照常解析;若用户
// 遮蔽了 `std`,仍按未知处理(不开特化)。
let typeStdNamespaceProgram = false;
let typeSetStdNamespace = (v) -> { typeStdNamespaceProgram = v; null; };
export typeSetStdNamespace;
let typeDbgModules = () -> [std.Object.keys(stdModuleType), std.Object.keys(stdModuleCalls), std.Object.keys(stdLetValues)];
export typeDbgModules;

let stdModuleValueType = (bindingName) -> {
  let v = stdLetValues[bindingName];
  if isError(v) || v == null { return ""; };
  if !isError(v.type) && v.type == "Object" { return "Object"; };
  if !isError(v.type) && v.type == "Function" { return "Function"; };
  "";
};
let stdScanLet = (node) -> {
  if isError(node) || node == null { return null; };
  if isError(node.type) || node.type != "Let" || node.value == null { return null; };
  stdLetValues[node.name] = node.value;
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
// 一个对象字面量若字段值全是标识符,就是导出表:字段名 = 模块名,字段值的绑定 = 该模块的值。
// 值的种类不限(对象 / 工厂调用 / 函数),成员表按「静态可见」并入(同名多来源取并集)。
let stdScanExportMap = (obj) -> {
  if isError(obj) || obj == null { return null; };
  if isError(obj.type) || obj.type != "Object" { return null; };
  let fields = obj.fields;
  if fields.length == 0 { return null; };
  let j = 0; let allIdents = true;
  while j < fields.length {
    let fv = fields[j].value;
    if isError(fv.type) || fv.type != "Identifier" { allIdents = false; };
    j = j + 1;
  };
  if !allIdents { return null; };
  j = 0;
  while j < fields.length {
    let moduleName = fields[j].name;
    let bindingName = fields[j].value.name;
    let mtype = stdModuleValueType(bindingName);
    if isError(stdModuleType[moduleName]) { stdModuleType[moduleName] = mtype; }
    else if stdModuleType[moduleName] == "" && mtype != "" { stdModuleType[moduleName] = mtype; };
    let calls = stdFieldCall[bindingName];
    if !isError(calls) {
      if isError(stdModuleCalls[moduleName]) { stdModuleCalls[moduleName] = {}; };
      let keys = std.Object.keys(calls); let k = 0;
      while k < keys.length { stdModuleCalls[moduleName][keys[k]] = calls[keys[k]]; k = k + 1; };
    };
    let values = stdFieldValue[bindingName];
    if !isError(values) {
      if isError(stdModuleValues[moduleName]) { stdModuleValues[moduleName] = {}; };
      let vk = std.Object.keys(values); let v = 0;
      while v < vk.length { stdModuleValues[moduleName][vk[v]] = values[vk[v]]; v = v + 1; };
    };
    j = j + 1;
  };
  null;
};
// 导出表只认两个结构位置,免得把普通的对象字面量误判成模块表:
//   · 函数体的**尾语句**对象字面量(标准库包装函数 `(std) -> { …; {String: StringLibrary, …}; }`),
//   · 绑定名恰好是 `std` 的对象字面量(运行期 `let std = {Object: stdObject, …}`)。
let stdScanExports = (node, isTail) -> {
  if isError(node) || node == null { return null; };
  if isError(node.type) { return null; };
  if node.type == "Object" && isTail { stdScanExportMap(node); };
  if node.type == "Let" && node.value != null {
    if node.name == "std" { stdScanExportMap(node.value); };
    if !isError(node.value.type) && node.value.type == "Function" && node.value.body != null {
      let stmts = node.value.body.statements;
      let i = 0;
      while i < stmts.length { stdScanExports(stmts[i], i == stmts.length - 1); i = i + 1; };
    };
  };
  null;
};
let buildStdTypes = (stmts) -> {
  let i = 0;
  while i < stmts.length { stdScanLet(stmts[i]); i = i + 1; };
  i = 0;
  while i < stmts.length { stdScanExports(stmts[i], false); i = i + 1; };
  null;
};

// ---- 返回安全性证明(known-safe) --------------------------------------------
// 两种强度:
//  · returnsNumberPure:与绑定 prone 无关,只证明「参数是注解 Number 且从未被写,
//    所有退出边只由参数/字面量的算术构成」。第一遍即可成立,供 safe-call 不动点。
//  · returnsNumberSafe:允许读全局,使用第二遍的 cannotBeError 事实,供裸返回。
// 证明失败一律保守为 false;它只影响优化,不改变语义。
let typeValuePurelyNumber = (node, pids) -> {
  if node == null || isError(node) { return false; };
  let t = node.type;
  if isError(t) { return false; };
  if t == "Number" { return true; };
  if t == "Identifier" {
    if isError(node.bindId) || node.bindId < 0 { return false; };
    let i = 0;
    while i < pids.length { if pids[i] == node.bindId { return true; }; i = i + 1; };
    return false;
  };
  if t == "UnaryOp" {
    if node.operator == "-" || node.operator == "+" { return typeValuePurelyNumber(node.operand, pids); };
    return false;
  };
  if t == "BinaryOp" {
    let op = node.operator;
    if op == "+" || op == "-" || op == "*" || op == "&" || op == "|" || op == "^" {
      return typeValuePurelyNumber(node.left, pids) && typeValuePurelyNumber(node.right, pids);
    };
  };
  false;
};
let typeIfValuePure = (node, prevSafe, pids) -> {
  let all = true;
  let b = 0;
  while b < node.branches.length {
    if !typeBlockValuePure(node.branches[b].body.statements, pids) { all = false; };
    b = b + 1;
  };
  if node.elseBody != null && !isError(node.elseBody) {
    if !typeBlockValuePure(node.elseBody.statements, pids) { all = false; };
  } else if !prevSafe { all = false; };
  all;
};
let typeBlockValuePure = (stmts, pids) -> {
  let has = false; let lastSafe = false;
  let i = 0;
  while i < stmts.length {
    let s = stmts[i];
    let t = s.type;
    if !isError(t) && t == "If" {
      let prevSafe = if has { lastSafe; } else { false; };
      lastSafe = typeIfValuePure(s, prevSafe, pids);
      has = true;
    } else if !isError(t) && (t == "Let" || t == "Assign" || t == "While" || t == "Return" || t == "Export") {
      // 不改变块值。
    } else {
      lastSafe = typeValuePurelyNumber(s, pids);
      has = true;
    };
    i = i + 1;
  };
  has && lastSafe;
};
let typeReturnsPure = (node, pids) -> {
  if node == null || isError(node) { return true; };
  if AnyArray.check(node) {
    let i = 0; while i < node.length { if !typeReturnsPure(node[i], pids) { return false; }; i = i + 1; };
  } else if AnyObject.check(node) {
    let t = node.type;
    if !isError(t) && t == "Function" { return true; };
    if !isError(t) && t == "Return" {
      if !typeValuePurelyNumber(node.value, pids) { return false; };
    };
    let keys = std.Object.keys(node); let i = 0;
    while i < keys.length { if !typeReturnsPure(node[keys[i]], pids) { return false; }; i = i + 1; };
  };
  true;
};
// 函数体不能有:调用(leaf)、import、`?` 传播、带注解的 Let/Assign(注解检查可提前返回)。
let typeBodyIsClean = (node) -> {
  if node == null || isError(node) { return true; };
  if AnyArray.check(node) {
    let i = 0; while i < node.length { if !typeBodyIsClean(node[i]) { return false; }; i = i + 1; };
  } else if AnyObject.check(node) {
    let t = node.type;
    if !isError(t) {
      if t == "Function" { return true; };
      if t == "Import" || t == "Call" { return false; };
      if t == "UnaryOp" && (node.operator == "?" || node.operator == "?Option") { return false; };
      if (t == "Let" || t == "Assign") && node.annotation != null && !isError(node.annotation) { return false; };
    };
    let keys = std.Object.keys(node); let i = 0;
    while i < keys.length { if !typeBodyIsClean(node[keys[i]]) { return false; }; i = i + 1; };
  };
  true;
};
let typeFunctionReturnsPure = (node, pids) -> {
  if !typeBodyIsClean(node.body) { return false; };
  if !typeBlockValuePure(node.body.statements, pids) { return false; };
  typeReturnsPure(node.body, pids);
};
// 完整证明:退出边使用第二遍的 cannotBeError(可以读全局/安全调用)。
let typeValueIsSafeNumber = (node) -> {
  node != null && !isError(node)
    && !isError(node.staticType) && node.staticType == "Number"
    && !isError(node.cannotBeError) && node.cannotBeError == true;
};
let typeIfValueSafe = (node, prevSafe) -> {
  let all = true;
  let b = 0;
  while b < node.branches.length {
    if !typeBlockValueSafe(node.branches[b].body.statements) { all = false; };
    b = b + 1;
  };
  if node.elseBody != null && !isError(node.elseBody) {
    if !typeBlockValueSafe(node.elseBody.statements) { all = false; };
  } else if !prevSafe { all = false; };
  all;
};
let typeBlockValueSafe = (stmts) -> {
  let has = false; let lastSafe = false;
  let i = 0;
  while i < stmts.length {
    let s = stmts[i];
    let t = s.type;
    if !isError(t) && t == "If" {
      let prevSafe = if has { lastSafe; } else { false; };
      lastSafe = typeIfValueSafe(s, prevSafe);
      has = true;
    } else if !isError(t) && (t == "Let" || t == "Assign" || t == "While" || t == "Return" || t == "Export") {
    } else {
      lastSafe = typeValueIsSafeNumber(s);
      has = true;
    };
    i = i + 1;
  };
  has && lastSafe;
};
let typeReturnsAreSafe = (node) -> {
  if node == null || isError(node) { return true; };
  if AnyArray.check(node) {
    let i = 0; while i < node.length { if !typeReturnsAreSafe(node[i]) { return false; }; i = i + 1; };
  } else if AnyObject.check(node) {
    let t = node.type;
    if !isError(t) && t == "Function" { return true; };
    if !isError(t) && t == "Return" {
      if !typeValueIsSafeNumber(node.value) { return false; };
    };
    let keys = std.Object.keys(node); let i = 0;
    while i < keys.length { if !typeReturnsAreSafe(node[keys[i]]) { return false; }; i = i + 1; };
  };
  true;
};
let typeFunctionReturnsNumberSafe = (node) -> {
  if !typeBlockValueSafe(node.body.statements) { return false; };
  if !typeBodyIsClean(node.body) { return false; };
  typeReturnsAreSafe(node.body);
};
let typeSafeReturnCount = 0;
let typeSafeReturnReport = () -> typeSafeReturnCount;

// ---- 引用事实与 safe-call 不动点 ---------------------------------------------
let typeRefFacts = {};
// 只对用户程序启用:库/运行期/模块没有 inline/raw 候选表。
let typeCallSafetyEnabled = false;
let typeSetCallSafety = (v) -> { typeCallSafetyEnabled = v; null; };
let typeScanRefs = (node, facts) -> {
  if node == null || isError(node) { return null; };
  if AnyArray.check(node) {
    let i = 0; while i < node.length { typeScanRefs(node[i], facts); i = i + 1; };
  } else if AnyObject.check(node) {
    let t = node.type;
    if !isError(t) {
      if t == "Import" {
        if isError(node.pathExpression) && !isError(node.module) && !isError(node.module.names) {
          let i = 0; while i < node.module.names.length { facts.imports[node.module.names[i]] = true; i = i + 1; };
        };
        return null;
      };
      if t == "Export" {
        if node.name != null { facts.exports[node.name] = true; }
        else if !isError(node.value.type) && node.value.type == "Identifier" { facts.exports[node.value.name] = true; }
        else if !isError(node.value.type) && node.value.type == "Object" {
          let i = 0; while i < node.value.fields.length { facts.exports[node.value.fields[i].name] = true; i = i + 1; };
        };
      };
      if t == "Let" && !isError(node.name) {
        let n = facts.lets[node.name];
        if isError(n) { n = 0; };
        facts.lets[node.name] = n + 1;
      };
      if t == "Call" {
        let callee = node.callee;
        if !isError(callee.type) && callee.type == "Identifier" {
          let bid = callee.bindId;
          if !isError(bid) && bid >= 0 {
            let n = facts.calls[bid];
            if isError(n) { n = 0; };
            facts.calls[bid] = n + 1;
          };
        } else {
          typeScanRefs(callee, facts);
        };
        let ai = 0;
        while ai < node.arguments.length { typeScanRefs(node.arguments[ai], facts); ai = ai + 1; };
        return null;
      };
      if t == "Identifier" {
        let bid = node.bindId;
        if !isError(bid) && bid >= 0 {
          let n = facts.uses[bid];
          if isError(n) { n = 0; };
          facts.uses[bid] = n + 1;
        };
      };
    };
    let keys = std.Object.keys(node); let i = 0;
    while i < keys.length { typeScanRefs(node[keys[i]], facts); i = i + 1; };
  };
  null;
};
let typeSafeMap = {};
let typeSafeMarked = 0;
let typeExprSafeNumber = (node, safe) -> {
  if node == null || isError(node) { return false; };
  if isError(node.staticType) || node.staticType != "Number" { return false; };
  let t = node.type;
  if t == "Number" { return true; };
  if t == "Identifier" {
    let bid = node.bindId;
    if isError(bid) || bid < 0 { return false; };
    let state = safe[bid];
    return !isError(state) && (state == 1 || state == 2);
  };
  if t == "UnaryOp" {
    if node.operator == "-" || node.operator == "+" { return typeExprSafeNumber(node.operand, safe); };
    return false;
  };
  if t == "BinaryOp" {
    let op = node.operator;
    if op == "+" || op == "-" || op == "*" || op == "&" || op == "|" || op == "^" {
      return typeExprSafeNumber(node.left, safe) && typeExprSafeNumber(node.right, safe);
    };
    return false;
  };
  if t == "Call" { return typeCallSafe(node, safe); };
  false;
};
let typeCallSafe = (node, safe) -> {
  let callee = node.callee;
  if isError(callee.type) || callee.type != "Identifier" { return false; };
  let bid = callee.bindId;
  if isError(bid) || bid < 0 { return false; };
  let st = typeBindTable[typeProgram][bid];
  if isError(st) || isError(st.writes) || st.writes.length != 1 { return false; };
  let decl = st.decl;
  if isError(decl) || decl == null { return false; };
  if decl.annotation != null && !isError(decl.annotation) { return false; };
  let fn = decl.value;
  if isError(fn) || fn == null { return false; };
  if isError(fn.type) || fn.type != "Function" { return false; };
  if isError(fn.returnsNumberPure) || fn.returnsNumberPure != true { return false; };
  if isError(fn.parameters) || fn.parameters.length == 0 { return false; };
  if node.arguments.length != fn.parameters.length { return false; };
  let facts = typeRefFacts[typeProgram];
  if isError(facts) || facts == null { return false; };
  if isError(facts.calls[bid]) || facts.calls[bid] != 1 { return false; };
  if !isError(facts.uses[bid]) && facts.uses[bid] != 0 { return false; };
  if !isError(facts.exports[decl.name]) { return false; };
  if !isError(facts.imports[decl.name]) { return false; };
  if !isError(facts.lets[decl.name]) && facts.lets[decl.name] > 1 { return false; };
  if !isError(typeAssignedNames[typeProgram][decl.name]) { return false; };
  let ai = 0;
  while ai < node.arguments.length {
    if !typeExprSafeNumber(node.arguments[ai], safe) { return false; };
    ai = ai + 1;
  };
  true;
};
// 1=visiting(环内乐观)、2=safe、3=unsafe。带记忆的 DFS 是 O(绑定数 + 写入数);
// 环内的乐观假设成立,因为环里的每一跳都必须通过纯调用/纯算术。
let typeBindingSafe = (bid, safe) -> {
  let state = safe[bid];
  if !isError(state) {
    if state == 1 || state == 2 { return true; };
    return false;
  };
  safe[bid] = 1;
  let st = typeBindTable[typeProgram][bid];
  if isError(st) || isError(st.writes) || st.decl == null || isError(st.decl) || st.writes.length == 0 {
    safe[bid] = 3; return false;
  };
  let i = 0;
  while i < st.writes.length {
    if !typeExprSafeNumber(st.writes[i], safe) { safe[bid] = 3; return false; };
    i = i + 1;
  };
  safe[bid] = 2;
  true;
};
let typeComputeSafeBindings = () -> {
  let table = typeBindTable[typeProgram];
  let safe = {};
  let i = 0;
  while i < table.length { typeBindingSafe(i, safe); i = i + 1; };
  typeSafeMap = safe;
};
let typeApplySafeCalls = (node) -> {
  if node == null || isError(node) { return null; };
  if AnyArray.check(node) {
    let i = 0; while i < node.length { typeApplySafeCalls(node[i]); i = i + 1; };
  } else if AnyObject.check(node) {
    let t = node.type;
    if !isError(t) && t == "Import" { return null; };
    let keys = std.Object.keys(node); let i = 0;
    while i < keys.length { typeApplySafeCalls(node[keys[i]]); i = i + 1; };
    if !isError(t) && t == "Identifier" {
      let bid = node.bindId;
      let state = typeSafeMap[bid];
      if !isError(bid) && bid >= 0 && !isError(state) && (state == 1 || state == 2) {
        node.cannotBeError = true; typeSafeMarked = typeSafeMarked + 1;
      };
    };
    if !isError(t) && t == "Call" {
      if typeCallSafe(node, typeSafeMap) { node.cannotBeError = true; };
    };
  };
  null;
};

let inferExpr = (node) -> {
  let t = node.type;
  // 默认:可能产出 Error(定位测试必须保留)。只有下面能证明的地方才翻成 true。
  node.cannotBeError = false;
  if t == "Number" { tagType(node, "Number"); node.cannotBeError = true; return tagRep(node, "Number"); };
  if t == "Boolean" { tagType(node, "Boolean"); node.cannotBeError = true; return tagRep(node, ""); };
  if t == "Null" { tagType(node, "Null"); node.cannotBeError = true; return tagRep(node, ""); };
  if t == "String" {
    tagType(node, "String"); node.cannotBeError = true;
    // 插值里的表达式同样要定型(`"a${f(x)}b"` 的 f(x))。
    if !isError(node.parts) && node.parts != null {
      let si = 0;
      while si < node.parts.length {
        let part = node.parts[si];
        if !isError(part.kind) && part.kind == "Interpolation" { inferExpr(part.expression); };
        si = si + 1;
      };
    };
    return tagRep(node, "");
  };
  // 标识符的自然表示 = 它解析到的那个绑定的表示(作用域栈上问,遮蔽与捕获自然正确)。
  // 读的安全性同样来自绑定:它的每次写入都不可能产出 Error 时才安全。
  if t == "Identifier" {
    tagType(node, typeLookup(node.name));
    let bind = typeBindLookup(node.name);
    node.bindId = bind;
    if bind >= 0 {
      let st = typeBindTable[typeProgram][bind];
      if !isError(st) && st.prone == false { node.cannotBeError = true; };
    };
    if typeNarrowed(node.name) { node.cannotBeError = true; };
    return tagRep(node, typeRepLookup(node.name));
  };
  if t == "Function" {
    // 函数体同样在编译期分析。参数：注解会在调用点被注解检查强制执行（带注解的实参
    // 类型不符时调用返回错误），所以函数体内可以按注解声明的内建类型来用它。
    // 作者声明的返回类型:像参数注解一样在定义处的外层上下文里求值,并且是权威结论。
    let declaredReturn = annotationBuiltinName(node.returnTypeAnnotation);
    annotationRejectConstructor(node.returnTypeAnnotation);
    typePush();
    let p = 0;
    while p < node.parameters.length {
      let param = node.parameters[p];
      let ptype = annotationBuiltinName(param.annotation);
      annotationRejectConstructor(param.annotation);
      // 参数也登记「绑定」:解箱判断必须问「这一个绑定自己有没有写入」,不能问「同一程序里
      // 是否出现过同名赋值」—— 后者会让一个毫不相干的同名绑定把已有注解全部作废(实测:
      // stdlib/math.ql 的 (a/b/n: Number) 因为 stdlib 里别处写过 a/n/b 而收益变成 0)。
      let pbind = -1;
      if typeCollectWrites {
        pbind = typeBindCount[typeProgram];
        typeBindCount[typeProgram] = pbind + 1;
        typeBindTable[typeProgram][pbind] = { base: isError(typeScalar[ptype]), prone: false, busy: false, done: false, writes: [], unk: false };
      } else {
        pbind = param.bindId;
        if isError(pbind) { pbind = -1; };
      };
      param.bindId = pbind;
      if pbind >= 0 { typeBindScopes[typeDepth - 1][param.name] = pbind; };
      if ptype != "" {
        typeScopes[typeDepth - 1][param.name] = ptype;
        // 参数与注解绑定同一前提:调用点的注解检查保证它只持有该类型,所以同样可解箱。
        // 目前只做 Number(裸 double);String 的裸 ptr 还牵扯生命周期,按既定顺序排在后面。
        // 判定只在第二遍做 —— 第一遍的写入集还没收齐。
        param.unboxType = "";
        if !typeCollectWrites && ptype == "Number" {
          rawAbiAnnotParams = rawAbiAnnotParams + 1;
          let pst = typeBindTable[typeProgram][pbind];
          if !isError(pst) && pst.writes.length == 0 {
            rawAbiNoWriteParams = rawAbiNoWriteParams + 1;
            param.unboxType = ptype;
            typeUnboxList[typeUnboxList.length] = param.name;
            typeRepScopes[typeDepth - 1][param.name] = "Number";
          };
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
    // 声明了返回类型就以它为准(调用点直接信任);只有能证明「所有返回路径都给出另一个
    // 类型」才是编译错误 —— 交集非空正说明每条路径都是那个类型,不会把不可达分支里的
    // return 误判成错误。
    if declaredReturn != "" {
      if result != "" && typeMismatch(declaredReturn, result) {
        typeReport(node, "return type mismatch: function declares " + declaredReturn + " but returns " + result);
      };
      node.returnType = declaredReturn;
    } else {
      node.returnType = result;
    };
    // 给生成端区分「作者声明的类型」(权威、要强制)与「推导出的类型」(只是近似)。
    node.declaredReturnType = declaredReturn;
    node.derivedReturnType = result;
    // 这些证明只服务用户程序的 raw/known-safe;库/运行期/模块不参与,省掉
    // 每个函数的 body 扫描。
    node.returnsNumberSafe = false;
    if typeCallSafetyEnabled {
      // 纯参数证明只在第一遍做:safe-call 不动点在第一遍后就要用,第二遍不必重算。
      if typeCollectWrites {
        node.returnsNumberPure = false;
        let purePids = [];
        let pureParams = node.parameters.length > 0;
        let pp = 0;
        while pp < node.parameters.length {
          let param = node.parameters[pp];
          if annotationBuiltinName(param.annotation) != "Number" { pureParams = false; };
          let pb = param.bindId;
          if isError(pb) || pb < 0 { pureParams = false; }
          else {
            purePids[purePids.length] = pb;
            let pst = typeBindTable[typeProgram][pb];
            if isError(pst) || isError(pst.writes) || pst.writes.length != 0 { pureParams = false; };
          };
          pp = pp + 1;
        };
        let pureAnnOk = !(node.returnTypeAnnotation != null && !isError(node.returnTypeAnnotation))
          || (declaredReturn == "Number" && result == "Number");
        node.returnsNumberPure = pureAnnOk && pureParams && typeFunctionReturnsPure(node, purePids);
      };
      // 完整证明(权威遍):所有退出边都是已证的 Number,且返回注解检查是死代码。
      if !typeCollectWrites {
        let hasAnn = node.returnTypeAnnotation != null && !isError(node.returnTypeAnnotation);
        let annOk = !hasAnn || (declaredReturn == "Number" && result == "Number");
        if annOk && !isError(result) && result == "Number" && typeFunctionReturnsNumberSafe(node) {
          node.returnsNumberSafe = true;
          typeSafeReturnCount = typeSafeReturnCount + 1;
        };
      };
    };
    // ②a:裸 ABI 候选 —— 参数全部「可裸」(注解 Number 且函数体内未被重赋值)。
    let rawAllParams = node.parameters.length > 0;
    let rpi = 0;
    while rpi < node.parameters.length {
      if isError(node.parameters[rpi].unboxType) || node.parameters[rpi].unboxType != "Number" { rawAllParams = false; };
      rpi = rpi + 1;
    };
    node.rawAbiAll = rawAllParams;
    node.rawAbiRet = declaredReturn == "Number";
    // ②a:也数「至少一个可裸参数」与「声明返回 Number」—— 分别对应 ②c(裸参数)与 ②b(裸返回)。
    let rawAnyParam = false;
    let rawPc = 0;
    let rpj = 0;
    while rpj < node.parameters.length {
      if !isError(node.parameters[rpj].unboxType) && node.parameters[rpj].unboxType == "Number" { rawAnyParam = true; rawPc = rawPc + 1; };
      rpj = rpj + 1;
    };
    rawAbiParamCount = rawAbiParamCount + rawPc;
    // 只数第二遍(权威口径):第一遍参数还不会解箱,两遍都数会重复。
    if !typeCollectWrites {
      rawAbiFuncTotal = rawAbiFuncTotal + 1;
      if rawAllParams { rawAbiFuncParams = rawAbiFuncParams + 1; };
      if rawAllParams && node.rawAbiRet { rawAbiFuncAll = rawAbiFuncAll + 1; };
      if rawAnyParam { rawAbiFuncAny = rawAbiFuncAny + 1; };
      if node.rawAbiRet { rawAbiFuncRet = rawAbiFuncRet + 1; };
    };
    typePop();
    tagType(node, "Function");
    node.cannotBeError = true;
    return tagRep(node, "");
  };
  if t == "Object" {
    let ofi = 0;
    while ofi < node.fields.length { inferExpr(node.fields[ofi].value); ofi = ofi + 1; };
    tagType(node, "Object");
    return tagRep(node, "");
  };
  if t == "Array" {
    let aei = 0;
    while aei < node.elements.length { inferExpr(node.elements[aei]); aei = aei + 1; };
    tagType(node, "Array");
    return tagRep(node, "");
  };
  if t == "UnaryOp" {
    let inner = inferExpr(node.operand);
    if node.operator == "!" {
      tagType(node, "Boolean");
      node.cannotBeError = true;
      return tagRep(node, if repOf(node.operand) == "Boolean" { "Boolean"; } else { ""; });
    };
    tagType(node, inner);
    // 一元 +/- 只在操作数静态类型是 Number 且本身安全时安全(否则 __neg_error/__pos_error)。
    if (node.operator == "-" || node.operator == "+") && node.operand.staticType == "Number" && !isError(node.operand.cannotBeError) && node.operand.cannotBeError == true { node.cannotBeError = true; };
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
    // 该运算本身不会报错(两侧类型已知且走的是无错路径),且两个操作数都安全 ⇒ 结果不可能
    // 是 Error。(除/模/混合类型/短路由 typeOpCreatesError 排除。)
    if !typeOpCreatesError(op, node.left.staticType, node.right.staticType)
       && !isError(node.left.cannotBeError) && node.left.cannotBeError == true
       && !isError(node.right.cannotBeError) && node.right.cannotBeError == true {
      node.cannotBeError = true;
    };
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
    // 接收者静态类型是 Array/String 时,length 是全的 Number 成员:任何输入都返回一个
    // 长度数字,绝不返回 Error。所以这条声明可靠(与 check 谓词同一性质),不依赖调用点
    // 检查。Object 上的 length 可能是用户字段(任意值),故不声明。
    let recvType = obj.staticType;
    if !isError(recvType) && node.field == "length" && (typeNameFamily(recvType) == "Array" || recvType == "String") {
      tagType(node, "Number");
      return tagRep(node, "");
    };
    // 内建类型名上的运行期谓词:Number.check / String.check …… 返回 Boolean。
    if !isError(obj.type) && obj.type == "Identifier" && !typeBound(obj.name) && !isError(typeBuiltins[obj.name]) {
      let pred = typeRuntimePredicates[obj.name + "." + node.field];
      if !isError(pred) { node.memberReturn = pred; tagType(node, "Function"); return tagRep(node, ""); };
    };
    if !isError(obj.type) && obj.type == "Identifier" && obj.name == "std" && (!typeBound("std") || typeStdNamespaceProgram) {
      if !isError(stdModuleType[node.field]) {
        node.moduleName = node.field;
        tagType(node, stdModuleType[node.field]);
        return tagRep(node, "");
      };
      tagType(node, "");
      return tagRep(node, "");
    };
    if !isError(obj.type) && obj.type == "MemberAccess" && !isError(obj.moduleName) {
      let calls = stdModuleCalls[obj.moduleName];
      let values = stdModuleValues[obj.moduleName];
      if !isError(calls) && !isError(calls[node.field]) {
        node.memberReturn = calls[node.field]; tagType(node, "Function");
        if isError(typeNsResolved[typeProgram]) { typeNsResolved[typeProgram] = 0; };
        typeNsResolved[typeProgram] = typeNsResolved[typeProgram] + 1;
        return tagRep(node, "");
      };
      if !isError(values) && !isError(values[node.field]) && values[node.field] != "" {
        tagType(node, values[node.field]);
        if isError(typeNsResolved[typeProgram]) { typeNsResolved[typeProgram] = 0; };
        typeNsResolved[typeProgram] = typeNsResolved[typeProgram] + 1;
        return tagRep(node, "");
      };
      if isError(typeNsUnresolved[typeProgram]) { typeNsUnresolved[typeProgram] = 0; };
      typeNsUnresolved[typeProgram] = typeNsUnresolved[typeProgram] + 1;
      typeNsPushName(obj.moduleName + "." + node.field);
    };
    tagType(node, "");
    return tagRep(node, "");
  };
  if t == "Call" {
    // 先把 callee 分析一遍(成员函数名要在这时定型:std.<模块>.<成员> 的 memberReturn 靠它)。
    inferExpr(node.callee);
    // 实参也要分析 —— 否则嵌在调用实参里的表达式永远不会被定型。
    let argIdx = 0;
    while argIdx < node.arguments.length { inferExpr(node.arguments[argIdx]); argIdx = argIdx + 1; };
    // ②a:这个调用点能不能发裸调用 —— 被调者是静态已知函数绑定、实参数与形参数相等
    // (无部分应用)、签名全裸、且每个实参静态都是 Number(⇒ 注解检查与 Error 实参策略是死代码)。
    rawAbiCallTotal = rawAbiCallTotal + 1;
    // 只数第二遍(权威口径),免得两遍都记成两份。
    if !typeCollectWrites && !isError(node.callee.type) && node.callee.type == "Identifier" && typeFnLookup(node.callee.name) != "" {
      let rawKey = rawAbiKey(node.callee.name);
      // ②b 的真实口径:被调者登记的类型是 Number(声明优先,否则用推导)就算燃料。
      if typeFnLookup(node.callee.name) == "Number" { rawAbiCallRetAny = rawAbiCallRetAny + 1; };
      if !isError(rawAbiSigCount[rawKey]) {
        rawAbiCallKnown = rawAbiCallKnown + 1;
        // ②c 的上限:元数相符时,静态已知是 Number 的实参位置数(若这些形参标注 Number 即可裸传)。
        if rawAbiSigCount[rawKey] == node.arguments.length {
          let na = 0;
          while na < node.arguments.length {
            if node.arguments[na].staticType == "Number" { rawAbiCallNumArgs = rawAbiCallNumArgs + 1; };
            na = na + 1;
          };
        };
        // ②b 的燃料:被调者声明返回 Number ⇒ 裸返回可以在不改实参缓冲的前提下先做。
        if rawAbiSigRet[rawKey] == true { rawAbiCallRet = rawAbiCallRet + 1; };
        if rawAbiSigCount[rawKey] == node.arguments.length {
          rawAbiCallArity = rawAbiCallArity + 1;
          if rawAbiSigAll[rawKey] == true && rawAbiSigRet[rawKey] == true {
            let rawAllNum = true; let rawA = 0;
            while rawA < node.arguments.length {
              if node.arguments[rawA].staticType != "Number" { rawAllNum = false; };
              rawA = rawA + 1;
            };
            if rawAllNum { rawAbiCallRaw = rawAbiCallRaw + 1; };
          };
        };
      };
    };
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
  if t == "IndexAccess" {
    inferExpr(node.object);
    if node.index != null && !isError(node.index) { inferExpr(node.index); };
    tagType(node, "");
    return tagRep(node, "");
  };
  if t == "If" {
    // 表达式位置的 if(语句位置的走 inferStmts 自己的分支):子表达式也要定型。
    let ibi = 0;
    while ibi < node.branches.length {
      inferExpr(node.branches[ibi].condition);
      typePush(); inferStmts(node.branches[ibi].body.statements); typePop();
      ibi = ibi + 1;
    };
    if node.elseBody != null { typePush(); inferStmts(node.elseBody.statements); typePop(); };
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
      annotationRejectConstructor(s.annotation);
      s.annotationType = declared;
      let value = if s.value == null { ""; } else { inferExpr(s.value); };
      // 两边在编译期都有确定类型却对不上 —— 这就是编译期错误,不必留到运行期。
      if declared != "" && value != "" && typeMismatch(declared, value) {
        typeReport(s, "type mismatch: value of type " + value + " does not match the annotated type " + declared);
      };
      typeScopes[typeDepth - 1][s.name] = if declared != "" { declared; } else { value; };
      // 安全性的底 + 写入集:类型不是内建标量 → 可能是 Error;否则由写入集在 fixpoint 里定。
      let bindingType = if declared != "" { declared; } else { value; };
      let bindId = -1;
      if typeCollectWrites {
        bindId = typeBindCount[typeProgram];
        typeBindCount[typeProgram] = bindId + 1;
        let st = { base: isError(typeScalar[bindingType]), prone: false, busy: false, done: false, writes: [], unk: (value == "" || isError(value)), decl: s };
        if s.value != null { st.writes[0] = s.value; };
        typeBindTable[typeProgram][bindId] = st;
      } else {
        bindId = s.bindId;
      };
      s.bindId = bindId;
      typeBindScopes[typeDepth - 1][s.name] = bindId;
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
      // 按绑定判断「每次写入的类型都已知」(原来是按「程序+名字」,同名绑定会互相毒化)。
      let lub = false;
      if s.bindId >= 0 {
        let lst = typeBindTable[typeProgram][s.bindId];
        lub = !isError(lst) && lst.unk != true;
      } else {
        lub = isError(typeUnknownWrites[typeProgram][s.name]);
      };
      if typeDepth > 1 && effective == "Number" && lub {
        s.unboxType = "Number";
        typeUnboxList[typeUnboxList.length] = s.name;
        // 此绑定之后的引用都能在表示栈上问出它是裸 double。
        typeRepScopes[typeDepth - 1][s.name] = "Number";
      };
      // 返回类型已知、且绑定稳定(从未被赋值)的函数:登记它,调用点才能拿到类型。
      if s.value != null && !isError(s.value.returnType) && s.value.returnType != "" && isError(typeAssignedNames[typeProgram][s.name]) {
        typeFnResults[typeDepth - 1][s.name] = s.value.returnType;
        // ②a:连同签名一起登记,调用点才能判断能否发裸调用(只记第二遍的权威判定)。
        if !typeCollectWrites {
          rawAbiSigCount[rawAbiKey(s.name)] = s.value.parameters.length;
          rawAbiSigAll[rawAbiKey(s.name)] = s.value.rawAbiAll;
          rawAbiSigRet[rawAbiKey(s.name)] = s.value.rawAbiRet;
        };
      };
    } else if t == "Assign" {
      if !isError(s.target.type) && s.target.type == "Identifier" {
        typeAssignedNames[typeProgram][s.target.name] = true;
        let value = inferExpr(s.value);
        let targetBind = typeBindLookup(s.target.name);
        if typeCollectWrites && targetBind >= 0 {
          let st = typeBindTable[typeProgram][targetBind];
          if !isError(st) { st.writes[st.writes.length] = s.value; };
        };
        // 这次写入的右值类型未知(或与声明不符)⇒ 这个**绑定**不能解箱(与名字无关)。
        if typeCollectWrites && targetBind >= 0 {
          let st2 = typeBindTable[typeProgram][targetBind];
          if !isError(st2) && (value == "" || isError(value)) { st2.unk = true; };
        };
        let declared = typeLookup(s.target.name);
        // 只有「右值类型已知且与声明一致」才可能省掉运行期检查。类型未知,或已知
        // 但不一致(此时运行期必须报 TypeCheck),都保留检查。
        if value == "" || isError(value) { typeUnknownWrites[typeProgram][s.target.name] = true; }
        else if declared != "" && value != declared { typeUnknownWrites[typeProgram][s.target.name] = true; };
        // 写入会作废此前的收窄事实(该名字可能又被赋成别的类型)。
        typeNarrowScopes[typeDepth - 1][s.target.name] = false;
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
        let guardCond = s.branches[b].condition;
        inferExpr(guardCond);
        typePush();
        let branchTail = inferStmts(s.branches[b].body.statements);
        typePop();
        // 守卫的落到点收窄:该分支必然退出时,后续代码继承「条件为假」的事实。
        narrowAfterGuard(guardCond, branchAlwaysExits(s.branches[b].body.statements));
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
  typeBindTable[typeProgram] = [];
  typeBindCount[typeProgram] = 0;
  typeScopes[0] = {};
  typeFnResults[0] = {};
  typeRepScopes[0] = {};
  typeBindScopes[0] = {};
  typeDepth = 1;
  typeReturnDepth = 0;
  typeCollectWrites = true;
  inferStmts(stmts);
  typeCollectWrites = false;
  // 第一遍已给节点 bindId;扫引用事实,供 safe-call 不动点判定稳定性。
  // 只有用户程序需要(其他程序不会发射 raw/inline 候选)。
  if typeCallSafetyEnabled {
    typeRefFacts[typeProgram] = { calls: {}, uses: {}, exports: {}, lets: {}, imports: {} };
    typeScanRefs(stmts, typeRefFacts[typeProgram]);
  };
  // 第一遍收齐每次写入的右值后,解「谁可能是 Error」;第二遍据此给每个节点标注。
  typeSolveWrites(typeBindTable[typeProgram]);
  // 第二遍才是权威口径:第一遍只负责把每次写入的右值类型收齐,第二遍据此判定可解箱性;
  // 计数与两张工作清单也在第二遍重来,免得把两遍的遍历算成两份。
  typeScopes[0] = {};
  typeFnResults[0] = {};
  typeRepScopes[0] = {};
  typeBindScopes[0] = {};
  typeRepCounts[typeProgram] = {};
  typeNsResolved[typeProgram] = 0;
  typeNsUnresolved[typeProgram] = 0;
  typeUnknownBinds[typeProgram] = [];
  typeUnknownParams[typeProgram] = [];
  typeDepth = 1;
  typeReturnDepth = 0;
  inferStmts(stmts);
  // 只对用户程序补 safe-call 事实;库/运行期/模块没有 inline/raw 候选表。
  if typeCallSafetyEnabled {
    typeComputeSafeBindings();
    typeApplySafeCalls(stmts);
  };
  // The second pass rewrites runtimeTypeFree from the unknown-write set; refine
  // it now with the prone fixpoint so a known-but-fallible write keeps its check.
  typeRefreshRuntimeChecks(typeBindTable[typeProgram]);
  typeErrors;
};

let isStaticNumber = (node) -> !isError(node.staticType) && node.staticType == "Number";
// 右值静态类型已等于目标声明的内建类型 ⇒ 写入时的注解检查不可能失败(死代码)。
let checkIsDead = (valueNode, declaredName) -> {
  if declaredName == "" { return false; };
  if isError(valueNode.staticType) { return false; };
  // staticType is not enough: a Number-typed expression can still be an Error
  // (division by a variable zero, a call whose annotation is only a promise).
  // Only an expression proven not to produce an Error may skip the runtime check.
  if isError(valueNode.cannotBeError) || valueNode.cannotBeError != true { return false; };
  valueNode.staticType == declaredName;
};

// 计数与程序数都要经函数交回调用方:模块全局在导入方读到的是拷贝,函数里读的才是模块
// 自己那份(与 inferTypes 交回 typeErrors 同一个道理)。
let typeRepReport = () -> typeRepCounts;
let typeNsReport = () -> [typeNsResolved, typeNsUnresolved];
export typeNsReport;
let typeNsUnknownNames = () -> typeNsUnresolvedNames;
export typeNsUnknownNames;
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
export typeSetCallSafety;
export typeSafeReturnReport;
export typeRepPrograms;
export typeBindsUnknown;
export typeParamsUnknown;
