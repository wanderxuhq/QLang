// QLang Standard Library - Ultra simplified version
//
// Task 10: this module carries the boot's OWN type library (type constants,
// the merged Type module with check/of/make, the Array/Object constructors and
// the Error type object) as plain QLang objects/functions. The old stub
// modules (Array/String/Object/Number/Boolean) are replaced by the constants/
// constructors: the boot's real std access goes through the host's `std`
// object, whose only missing piece is std.Object.entries (added below).
//
// Cross-interpreter identity (host run_import creates a fresh Interpreter per
// imported file): comparing std.Type.of(x) against a constant defined in
// ANOTHER module is always false (type-value Rcs are per-interpreter). All
// comparisons inside this module therefore use either boot-wrapper fields
// (v.type == "..."), the host isError() native, or the HOST type values
// captured below (__host* — same source as std.Type.of's results at capture
// time, i.e. the host std.Type before it is replaced).

let Math = {
  sqrt: (n) -> { if n < 0 { 0; } else { n; }; },
  abs: (n) -> { if n < 0 { 0 - n; } else { n; }; },
  pow: (base) -> (exp) -> {
    let result = 1;
    let i = 0;
    while i < exp {
      result = result * base;
      i = i + 1;
    }
    result;
  },
  PI: 3.14159,
};

let JSON = {
  stringify: (v) -> std.String.toString(v),
  parse: (s) -> s,
};

// ---- Task 10: boot type library ----

// Host type machinery captured BEFORE the boot constants shadow the names and
// BEFORE std.Type is replaced below: the host std.Type.of native and the host
// type values it returns. Same-source comparisons (t == __hostX) are safe.
let __hostTypeOf = std.Type.of;
let __hostNumber = Number;
let __hostString = String;
let __hostBoolean = Boolean;
let __hostNull = Null;
let __hostAnyArray = AnyArray;
let __hostAnyObject = AnyObject;
let __hostFunction = Function;
let __hostError = Error;
let __hostType = __hostTypeOf(Number);

// 类型值判定:对象且带可调用 check 成员。boot 的类型常量是 {check: <函数>}
// 对象(std.Type.make 产物同理);boot 用户函数是 {type: "Function", ...} 记录,
// 作为 check 成员时其 .type 探测为 "Function"。普通对象(check 非函数)判否。
// 第三项:调用路径(interpreter.ql)把宿主 QLang 函数(Type.make/Array/Object/
// std.Type.of)的返回值包成 {type:"Object"|"Type", value: <类型值>} 包装——
// 该包装形态同样是类型值(解包判定内层)。注意:表达式不得跨行(host 解析器
// 以换行结束语句);裸值的 .check/.type 探测是错误值,error == "X" 也是错误值
// (truthy),比较前必须先 !isError 守卫(与构造器分发的守卫同理)。
let isTypeValue = (v) -> v != null && (__hostTypeOf(v.check) == __hostFunction || (!isError(v.check) && !isError(v.check.type) && v.check.type == "Function") || (!isError(v.type) && (v.type == "Object" || v.type == "Type") && isTypeValue(v.value)));

// 类型值解包:调用产物包装({type:"Object"|"Type", value: <类型值>})取内层
// 类型值;其余值(裸类型值常量/普通包装/原始值)原样返回。只解包装形态——内层
// 不是类型值(如普通对象字面量)时保持原样,由调用方继续按原判定处理。
let unwrapTypeValue = (v) -> {
  if v != null && !isError(v.type) && (v.type == "Object" || v.type == "Type") && isTypeValue(v.value) {
    v.value;
  } else {
    v;
  };
};

// 调用类型检查函数(宿主 QLang 函数或 boot 用户函数记录)。宿主函数直接调用
// (现有 t10/t11 路径);boot 记录只能经 boot 调用路径执行——经 std.__bootCall
// 桥接(interpreter.ql 注入,闭包捕获本进程的 callFunctionInner),并把 boot
// 包装结果还原为裸值(Boolean/Null/Error 解包,其余形态原样返回)。
let callCheck = (check, v) -> {
  if __hostTypeOf(check) == __hostFunction {
    check(v);
  } else {
    let r = std.__bootCall(check, v);
    if r != null && !isError(r.type) && r.type == "Boolean" { r.value; }
    else if r != null && !isError(r.type) && r.type == "Null" { null; }
    else if r != null && !isError(r.type) && r.type == "Error" { r.value; }
    else { r; };
  };
};

// 9 个类型常量 + Error 类型对象。判定基于 boot 值包装 {type, value}(null 无
// 包装):调用路径(interpreter.ql)对宿主 QLang 函数传包装值,对宿主原生传裸值,
// null 一律裸传。check 对错误值参数与宿主一致(宿主谓词 accepts_errors: true,
// 返回 false/true 而非报错):裸值/错误值的 .type 探测是错误值,比较前
// !isError 守卫。
let Number   = { check: (v) -> v != null && !isError(v.type) && v.type == "Number" };
let String   = { check: (v) -> v != null && !isError(v.type) && v.type == "String" };
let Boolean  = { check: (v) -> v != null && !isError(v.type) && v.type == "Boolean" };
let Null     = { check: (v) -> v == null };
let AnyArray = { check: (v) -> v != null && !isError(v.type) && v.type == "Array" };
let AnyObject= { check: (v) -> v != null && !isError(v.type) && v.type == "Object" && !isTypeValue(v) };
// boot 函数记录的包装标签是大写 "Function"(brief 的 "function"/"native" 一并
// 兼容);裸原生函数在宿主探测下无 type 字段(brief 注明的变体)——补宿主探测
// 分支:裸宿主函数(原生与 QLang 函数,如 print)在宿主 Type.of 下即 Function。
let Function = { check: (v) -> v != null && ((!isError(v.type) && (v.type == "Function" || v.type == "function" || v.type == "native")) || __hostTypeOf(v) == __hostFunction) };
let Any      = { check: (v) -> true };
let Never    = { check: (v) -> false };
// Error 类型对象:raise 复用宿主 Error 类型对象的原生构造器(arity 不定,
// (msg) / (msg, cause) 均可用;boot 的 QLang 函数无法表达可选参数,且部分应用
// 会把 1 参调用变成柯里化函数,故直接挂原生)。
let Error    = { check: (v) -> v != null && !isError(v.type) && v.type == "Error",
                 raise: Error.raise };

// 合并的 Type 模块(模块兼类型值):check / of / make。of 返回本模块内同源
// 常量(互比安全)。分发链同样需要 !isError(v.type) 守卫;裸宿主值(无 type
// 字段,如 std 模块/JSON.parse 结果)按捕获的宿主 Type.of 判定,与宿主一致。
let Type = {
  check: (v) -> isTypeValue(v),
  of: (v) -> {
    if v == null { Null; }
    else if isTypeValue(v) { Type; }
    else if !isError(v.type) && v.type == "Number" { Number; }
    else if !isError(v.type) && v.type == "String" { String; }
    else if !isError(v.type) && v.type == "Boolean" { Boolean; }
    else if !isError(v.type) && v.type == "Array" { AnyArray; }
    else if !isError(v.type) && v.type == "Object" { AnyObject; }
    else if !isError(v.type) && (v.type == "Function" || v.type == "function" || v.type == "native") { Function; }
    else if !isError(v.type) && v.type == "Error" { Error; }
    else if !isError(v.type) && v.type == "Type" { Type; }
    else if __hostTypeOf(v) == __hostNumber { Number; }
    else if __hostTypeOf(v) == __hostString { String; }
    else if __hostTypeOf(v) == __hostBoolean { Boolean; }
    else if __hostTypeOf(v) == __hostNull { Null; }
    else if __hostTypeOf(v) == __hostAnyArray { AnyArray; }
    else if __hostTypeOf(v) == __hostAnyObject { AnyObject; }
    else if __hostTypeOf(v) == __hostFunction { Function; }
    else if __hostTypeOf(v) == __hostError { Error; }
    else if __hostTypeOf(v) == __hostType { Type; }
    else { Type; };
  },
  // 与宿主对齐:make 参数必须是函数(宿主 QLang 函数/原生/boot 函数记录),
  // 否则 TypeMismatch 错误值(host 消息 "Type.make: expected a function")。
  make: (f) -> {
    if f != null && (__hostTypeOf(f) == __hostFunction || (!isError(f.type) && f.type == "Function")) { return { check: f }; }
    else { std.Error.raise("TypeMismatch", "Type.make: expected a function", null); };
  },
};

// boot 对象包装的 entries(host 的 std.Object 无 entries):obj 是
// {type:"Object", value: 字段表},返回 [[key, value], ...](value 为字段值)。
let __objectEntries = (obj) -> {
  let fields = obj.value;
  let keys = std.Object.keys(fields);
  let out = [];
  let i = 0;
  while i < keys.length {
    out[out.length] = [keys[i], fields[keys[i]]];
    i = i + 1;
  };
  out;
};
std.Object.entries = __objectEntries;

// 逐元素检查骨架(注意:boot 的 stdlib 没有 forEach,用 while)。元素检查经
// callCheck 调用:宿主函数直接调,用户类型(check 为 boot 记录)经 __bootCall。
let allMatch = (arr, check) -> {
  let ok = true;
  let i = 0;
  while i < arr.length && ok {
    let r = callCheck(check, arr[i]);
    if r == null || r == false || isError(r) { ok = false; };
    i = i + 1;
  };
  ok;
};

// Array 构造器:union 参数(Number | Type | [Type] | {length, element})
// mode: { length: Number|null, element: check|null, tuple: [check]|null }
let arrayCheck = (mode) -> (v) -> {
  if v == null || v.type != "Array" { false; }
  else if mode.length != null {
    if v.value.length != mode.length { false; }
    else if mode.element != null { allMatch(v.value, mode.element); }
    else { true; };
  }
  else if mode.tuple != null {
    if v.value.length != mode.tuple.length { false; }
    else {
      let ok = true;
      let i = 0;
      while i < mode.tuple.length && ok {
        let r = callCheck(mode.tuple[i], v.value[i]);
        if r == null || r == false || isError(r) { ok = false; };
        i = i + 1;
      };
      ok;
    };
  }
  else if mode.element != null { allMatch(v.value, mode.element); }
  else { true; };
};

let Array = (x) -> {
  // 注意:裸值(如类型常量)的 x.type 探测是错误值,error == "X" 也是错误值
  // (truthy)——必须先 !isError(x.type) 再比较标签,否则裸常量会误入定长分支。
  if x != null && !isError(x.type) && x.type == "Number" {
    if x.value >= 0 && x.value % 1 == 0 {
      Type.make(arrayCheck({ length: x.value, element: null, tuple: null }));
    }
    else {
      // 与宿主对齐:负数/非整数长度报专属消息(host "Array: length must be a
      // non-negative integer"),而非落入通用 else。
      std.Error.raise("TypeMismatch", "Array: length must be a non-negative integer", null);
    };
  }
  else if isTypeValue(x) {
    // Type 成员:元素类型。x 可能是调用产物包装({type:"Object"|"Type", value:
    // 类型值},如 std.Type.make/std.Type.of/嵌套构造器调用的返回值)——解包后
    // 取 check(包装的 check 探测是错误值)。
    Type.make(arrayCheck({ length: null, element: unwrapTypeValue(x).check, tuple: null }));
  }
  else if x != null && !isError(x.type) && x.type == "Array" {
    // [Type] 成员:逐位类型(构造时验证每个元素都是类型;元素同样可能是调用
    // 产物包装,先解包再判定/取 check)
    let checks = [];
    let i = 0;
    while i < x.value.length {
      let t = unwrapTypeValue(x.value[i]);
      if !isTypeValue(t) {
        return std.Error.raise("TypeMismatch", "Array: tuple elements must all be type values", null);
      };
      checks[checks.length] = t.check;
      i = i + 1;
    };
    Type.make(arrayCheck({ length: null, element: null, tuple: checks }));
  }
  else if x != null && !isError(x.type) && x.type == "Object" && !isTypeValue(x) {
    // {length, element} 元数据成员(element 可能是调用产物包装)
    let length = x.value["length"];
    let element = x.value["element"];
    if length == null || length.type != "Number" || length.value < 0 || length.value % 1 != 0 {
      std.Error.raise("TypeMismatch", "Array: metadata must have a non-negative integer 'length'", null);
    }
    else {
      let et = unwrapTypeValue(element);
      if et == null || !isTypeValue(et) {
        std.Error.raise("TypeMismatch", "Array: metadata must have a type 'element'", null);
      }
      else {
        Type.make(arrayCheck({ length: length.value, element: et.check, tuple: null }));
      };
    };
  }
  else {
    std.Error.raise("TypeMismatch", "Array: argument must be a length, a type, a list of types, or {length, element}", null);
  };
};

// Object 构造器:union 参数(Type | 形状对象)
let Object = (x) -> {
  if isTypeValue(x) {
    // Type 成员:keys 全为 T(Object(String) ≡ AnyObject)。x 可能是调用产物
    // 包装——解包后取 check,key 检查经 callCheck 调用(用户类型的 check 是
    // boot 记录,宿主闭包不能直接调用)。
    let t = unwrapTypeValue(x);
    Type.make((v) -> {
      if v == null || v.type != "Object" || isTypeValue(v) { false; }
      else {
        // boot 包装的对象:字段在 v.value;keys 为裸字符串,先包成
        // {type:"String", value: key} 再喂给 key 检查(检查接收包装值)。
        let keys = std.Object.keys(v.value);
        let ok = true;
        let i = 0;
        while i < keys.length && ok {
          let r = callCheck(t.check, { type: "String", value: keys[i] });
          if r == null || r == false || isError(r) { ok = false; };
          i = i + 1;
        };
        ok;
      };
    });
  }
  else if x != null && !isError(x.type) && x.type == "Object" && !isTypeValue(x) {
    // 形状对象成员:schema(构造时验证值都是类型;缺字段/字段不符 → false)。
    // 字段值可能是调用产物包装,先解包再校验/使用(归一化后的 schema 供检查
    // 闭包读取;检查经 callCheck 调用)。
    let entries = std.Object.entries(x);
    let schema = [];
    let i = 0;
    while i < entries.length {
      let t = unwrapTypeValue(entries[i][1]);
      if !isTypeValue(t) {
        return std.Error.raise("TypeMismatch", "Object: schema field '" + entries[i][0] + "' is not a type value", null);
      };
      schema[schema.length] = [entries[i][0], t];
      i = i + 1;
    };
    Type.make((v) -> {
      if v == null || v.type != "Object" || isTypeValue(v) { false; }
      else {
        let ok = true;
        let j = 0;
        while j < schema.length && ok {
          let key = schema[j][0];
          let fv = v.value[key];
          if fv == null {
            ok = false; // 缺字段
          }
          else {
            let r = callCheck(schema[j][1].check, fv);
            if r == null || r == false || isError(r) { ok = false; };
          };
          j = j + 1;
        };
        ok;
      };
    });
  }
  else {
    std.Error.raise("TypeMismatch", "Object: argument must be a type (keys) or a shape object (schema)", null);
  };
};

// std.String.toChars:宿主 std.String 没有该方法,但 boot 的 lexer 依赖它
// (把源码转成字符数组)。保持旧 stdlib 的附加方式(仅补宿主缺失的方法)。
let __toChars = (s) -> {
  let parts = [];
  let i = 0;
  while i < s.length {
    parts[parts.length] = s[i];
    i = i + 1;
  }
  parts;
};
std.String.toChars = __toChars;

// 裸宿主值 -> 包装类型名(字符串)。host 的 std.Type.of 现在返回类型值(对象),
// 不能直接用作包装标签;interpreter.ql 的包装点经此函数取字符串标签。
// 只处理裸值(包装值按对象处理);与 __host* 常量同源互比。
let typeTag = (raw) -> {
  let t = __hostTypeOf(raw);
  if t == __hostNumber { "Number"; }
  else if t == __hostString { "String"; }
  else if t == __hostBoolean { "Boolean"; }
  else if t == __hostNull { "Null"; }
  else if t == __hostAnyArray { "Array"; }
  else if t == __hostAnyObject { "Object"; }
  else if t == __hostFunction { "Function"; }
  else if t == __hostError { "Error"; }
  else if t == __hostType { "Type"; }
  else { "Unknown"; };
};

// 替换宿主 std.Type:用户代码的 std.Type 必须是本模块的合并 Type(其 of 返回
// 本模块同源常量,boot 内互比安全)。宿主原生 Type.of 已在上方捕获为
// __hostTypeOf。
std.Type = Type;

let fs = {
  readFileText: (path) -> "",
};

// 导出类型库:interpreter.ql 用它填充 boot 全局环境(Number/String/.../
// Array/Object/Type)与包装点(typeTag);宿主 std 对象经 std.Type 替换后由
// 用户代码经 std.Type.* 访问。
export { std, isTypeValue, Number, String, Boolean, Null, AnyArray, AnyObject, Function, Any, Never, Error, Array, Object, Type, typeTag };
