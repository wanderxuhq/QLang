// Interpreter for QLang - Executes AST
// Bootstrapped QLang implementation
//
// Error-as-value semantics (Task 8): host operations (l + r, 1 / 0, native
// calls) now return error VALUES instead of terminating; the boot detects and
// wraps them as { type: "Error", value: <host ErrorValue>, propagate: <bool> }.
// The `?` operator sets propagate: true; the propagate marker flows through
// evaluate, becomes flow: "Propagate" at statement boundaries, is stopped at
// user-function boundaries (the error becomes the function's return value,
// matching the host), and is reported at the top level by main.ql.

import ./ast.ql;
import ./environment.ql;
import ./stdlib.ql;

let Interpreter = () -> {
  let globalEnv = GlobalEnvironment(std);

  // Expose the host's diagnostic natives to user code (the error channel needs
  // Error()/isError(); the isDiag exemption list covers print/println/Error/
  // isError/raise/Type.of).
  globalEnv._define("print", print);
  globalEnv._define("println", println);
  globalEnv._define("Error", Error);
  globalEnv._define("isError", isError);

  // Task 10: seed the boot global environment with the boot's OWN type library
  // (stdlib.ql constants — same module as std.Type.of's results, so user-code
  // comparisons like `std.Type.of(42) == Number` hold inside the boot; the
  // host's globals would be cross-interpreter identities and never compare
  // equal). Error is already defined above (stdlib.ql's Error constant).
  globalEnv._define("Number", Number);
  globalEnv._define("String", String);
  globalEnv._define("Boolean", Boolean);
  globalEnv._define("Null", Null);
  globalEnv._define("AnyArray", AnyArray);
  globalEnv._define("AnyObject", AnyObject);
  globalEnv._define("Function", Function);
  globalEnv._define("Any", Any);
  globalEnv._define("Never", Never);
  globalEnv._define("Array", Array);
  globalEnv._define("Object", Object);
  globalEnv._define("Type", Type);

  // User-function call depth guard: each boot level costs several host frames,
  // so the boot's own limit must stay well below the host stack's capacity
  // (the host's own 300-call guard fires too late for the boot — measured: it
  // is reached at ~37-39 boot levels, past the crash point). Task 11 added the
  // param-annotation check frames (~0.5-1 host frame per boot level): the host
  // stack now overflows at ~36-37 boot levels (probed: f(36) crashes with the
  // guard disabled; Task 10 measured ~39). 35 left only ~1.5 levels of margin;
  // 33 keeps ~3 levels below the crash boundary while covering the deepest
  // legitimate difftest recursion (x14/x21/x22 shapes all guard before it).
  let depth = 0;
  let maxDepth = 33;

  // Helper functions that don't use std
  let getArrayLength = (arr) -> {
    let count = 0;
    let i = 0;
    while i < arr.length {
      count = count + 1;
      i = i + 1;
    }
    count;
  };

  let getArrayElement = (arr, index) -> {
    let i = 0;
    let result = null;
    while i < arr.length {
      if i == index {
        result = arr[i];
      }
      i = i + 1;
    }
    result;
  };

  let pushArray = (arr, element) -> {
    arr[arr.length] = element;
    arr;
  };

  let isTruthy = (value) -> {
    // Note: value is a wrapped value { type, value }; unwrap before checking truthiness
    if value == null { false }
    else if value.type == "Null" { false }
    else if value.type == "Boolean" { value.value == true }
    else if value.type == "Number" { value.value != 0 }
    else if value.type == "String" { value.value != "" }
    else { true };
  };

  // Wrapped value check: probing .type on a raw host value (natives, std
  // modules) yields an error value (host error-as-value), never a string, so
  // `!isError(v.type)` cleanly separates boot wrappers {type, value} from raw
  // values (a raw Error probes its kind — still a string, treated as wrapped,
  // which keeps leaked raw errors flowing like wrappers).
  let isWrapped = (v) -> {
    v != null && !isError(v.type);
  };

  let isErrorVal = (v) -> {
    isWrapped(v) && v.type == "Error";
  };

  let isPropagating = (v) -> {
    isErrorVal(v) && v.propagate == true;
  };

  // ---- Task 11: 标注检查语义 ----
  //
  // 受保护的内置类型对象(裸常量,与宿主 TYPE_MARKER 对象对应);用户类型
  // (Type.make 产物)不在列,与宿主 user_type 不受保护一致。Array/Object 构造
  // 器是函数,不参与字段写入。
  let __protectedTypes = [Number, String, Boolean, Null, AnyArray, AnyObject, Function, Any, Never, Error, Type];

  let isProtectedType = (o) -> {
    let i = 0;
    let found = false;
    while i < __protectedTypes.length && !found {
      if o == __protectedTypes[i] { found = true; }
      i = i + 1;
    }
    found;
  };

  let isProtectedField = (f) -> f == "check" || f == "raise" || f == "of" || f == "make";

  let protectedWriteError = (field) -> {
    // 宿主侧为 RuntimeError::Custom(程序中止);boot 无退出原语,经错误通道
    // 传播(propagate: true → 顶层打印诊断并返回 flow "Error")。消息与宿主一致。
    { type: "Error", value: std.Error.raise("Custom", "cannot overwrite protected member '" + field + "' of built-in type", null), propagate: true };
  };

  // 标注归一:构造器产物(Array(Number)/Type.make/Object(...))经调用路径被
  // 包成 {type:"Object", value: {check: f}} 包装——检查路径取内层类型对象;
  // 其余(裸常量/错误值/普通对象)原样返回。
  let normalizeAnnotation = (a) -> {
    if a != null && !isError(a.type) && (a.type == "Object" || a.type == "Type") && isTypeValue(a.value) {
      a.value;
    } else {
      a;
    };
  };

  // TypeCheck 消息(宿主 check_annotation 同款;boot 无源码 span,标注文本用
  // "?")。注意:错误构造必须内联在宿主层代码(Let/Assign 分支)直接调用
  // std.Error.raise——cause 是裸错误值,若经 boot 用户函数参数传递会被调用
  // 路径的错误值参数检查拒收(实测 makeTypeCheckError 产出 TypeMismatch)。
  let typeCheckMsg = (typeName) -> "value of type \"" + typeName + "\" does not match the annotated type \"?\"";

  // 内部检查路径:调用类型值的 check 函数,豁免错误值参数(宿主
  // call_function_inner 的 exempt_error_args 对应;用户调用不豁免)。
  // 返回 {type:"Boolean", value: bool},或错误包装(标注非类型值 / check 报错)。
  let checkValue = (typeVal, v, env) -> {
    if !isTypeValue(typeVal) {
      { type: "Error", value: std.Error.raise("TypeCheck", "type annotation is not a type value", null), propagate: false };
    } else {
      let checkFn = typeVal.check;
      let r = callFunctionInner(checkFn, [v], env, true);
      if isErrorVal(r) {
        r;
      } else {
        { type: "Boolean", value: isTruthy(r) };
      };
    };
  };

  let runProgram = (program) -> {
    let env = globalEnv;
    return runStatements(program.statements, env);
  };

  let runStatements = (statements, env) -> {
    let i = 0;
    let lastValue = { type: "Null", value: null };
    while i < statements.length {
      let result = runStatement(statements[i], env);
      if result.flow == "Return" {
        return result;
      }
      if result.flow == "Propagate" {
        return result;
      }
      lastValue = result.value;
      i = i + 1;
    }
    return { flow: "None", value: lastValue };
  };

  let runStatement = (stmt, env) -> {
    if stmt.type == "Let" {
      let val = evaluate(stmt.value, env);
      if isPropagating(val) {
        return { flow: "Propagate", value: val };
      }
      if stmt.annotation != null {
        // 宿主顺序:先求值 value,再求值标注,然后检查;通过 → 带标注绑定
        let annVal = normalizeAnnotation(evaluate(stmt.annotation, env));
        if isPropagating(annVal) {
          return { flow: "Propagate", value: annVal };
        }
        let ck = checkValue(annVal, val, env);
        if isErrorVal(ck) {
          // 检查自身出错(标注非类型值/check 报错):绑定该错误值(宿主同)
          env._defineAnnotated(stmt.name, ck, { ty: annVal, text: "?" });
        } else if isTruthy(ck) {
          env._defineAnnotated(stmt.name, val, { ty: annVal, text: "?" });
        } else {
          // 检查失败 → TypeCheck 错误值(cause = 原值若为错误),带标注绑定
          // (错误构造内联在宿主层:cause 是裸错误值,经 boot 函数参数会被拒收)
          let typeName = if val != null && !isError(val.type) { val.type; } else { "?"; };
          let cause = if isErrorVal(val) { val.value; } else { null; };
          env._defineAnnotated(stmt.name, { type: "Error", value: std.Error.raise("TypeCheck", typeCheckMsg(typeName), cause), propagate: false }, { ty: annVal, text: "?" });
        };
      } else {
        env._define(stmt.name, val);
      };
      return { flow: "None", value: { type: "Null", value: null } };
    } else if stmt.type == "Assign" {
      let val = evaluate(stmt.value, env);
      if isPropagating(val) {
        return { flow: "Propagate", value: val };
      }
      let res = assignValue(stmt.target, val, env);
      if res != null && isErrorVal(res) {
        // 受保护成员写入:经 boot 错误通道传播(顶层报错,宿主侧为 Custom 异常)
        return { flow: "Propagate", value: res };
      }
      return { flow: "None", value: { type: "Null", value: null } };
    } else if stmt.type == "If" {
      return runIfStatement(stmt, env);
    } else if stmt.type == "While" {
      return runWhileStatement(stmt, env);
    } else if stmt.type == "Return" {
      let val = evaluate(stmt.value, env);
      if isPropagating(val) {
        return { flow: "Propagate", value: val };
      }
      return { flow: "Return", value: val };
    } else if stmt.type == "Export" {
      let val = evaluate(stmt.value, env);
      if isPropagating(val) {
        return { flow: "Propagate", value: val };
      }
      return { flow: "None", value: val };
    } else if stmt.type == "Import" {
      // The bootstrapped interpreter cannot load modules: nested-code imports
      // used to be silently ignored, leaving imported names undefined — calls
      // then returned Null/Void results with no diagnostic (self-hosting gap:
      // the boot parser cannot even parse its own sources). Fail loudly so the
      // boundary is explicit instead of corrupting results.
      { flow: "Propagate", value: { type: "Error", value: std.Error.raise("NotImplemented", "import is not supported by the bootstrapped interpreter: " + stmt.path, null), propagate: true } };
    } else {
      let val = evaluate(stmt, env);
      if isPropagating(val) {
        return { flow: "Propagate", value: val };
      }
      return { flow: "None", value: val };
    };
  };

  let runIfStatement = (stmt, env) -> {
    let i = 0;
    while i < stmt.branches.length {
      let branch = stmt.branches[i];
      let condition = evaluate(branch.condition, env);
      if isPropagating(condition) {
        return { flow: "Propagate", value: condition };
      }
      if isTruthy(condition) {
        return runStatements(branch.body.statements, env);
      }
      i = i + 1;
    }

    if stmt.elseBody != null {
      return runStatements(stmt.elseBody.statements, env);
    }

    return { flow: "None", value: { type: "Null", value: null } };
  };

  let runWhileStatement = (stmt, env) -> {
    let done = false;
    while !done {
      let condition = evaluate(stmt.condition, env);
      if isPropagating(condition) {
        return { flow: "Propagate", value: condition };
      }
      if !isTruthy(condition) {
        done = true;
      } else {
        let result = runStatements(stmt.body.statements, env);
        if result.flow == "Return" {
          return result;
        }
        if result.flow == "Propagate" {
          return result;
        }
      }
    }
    { flow: "None", value: { type: "Null", value: null } };
  };

  // 返回 null(成功)或错误包装(受保护成员写入 → propagate: true,经 Assign
  // 分支的错误通道传播到顶层)。
  let assignValue = (target, value, env) -> {
    if target.type == "Identifier" {
      // Task 11: 重赋值检查——绑定带标注时,赋值前再查(getAnnotation 沿链)
      let ann = env._getAnnotation(target.name);
      if ann != null {
        let ck = checkValue(ann.ty, value, env);
        if isErrorVal(ck) {
          env._assign(target.name, ck);
        } else if isTruthy(ck) {
          env._assign(target.name, value);
        } else {
          let typeName = if value != null && !isError(value.type) { value.type; } else { "?"; };
          let cause = if isErrorVal(value) { value.value; } else { null; };
          env._assign(target.name, { type: "Error", value: std.Error.raise("TypeCheck", typeCheckMsg(typeName), cause), propagate: false });
        };
      } else {
        env._assign(target.name, value);
      };
      null;
    } else if target.type == "MemberAccess" {
      let obj = evaluate(target.object, env);
      if obj != null {
        let t = obj["type"];
        if isError(t) { t = null; }
        if t == "Object" || t == "Type" {
          // AST field name is target.field (MemberAccessExpr(object, field))
          // 包装对象写入:内层可能是受保护的内置常量——经调用路径的 typeTag
          // 包装(如 std.Type.of(42) 产物 {type:"Type", value: Number}),obj.value
          // 即共享的裸常量,直接写会绕过保护(宿主对常量对象写入中止)。
          if isProtectedType(obj.value) && isProtectedField(target.field) {
            protectedWriteError(target.field);
          } else {
            obj.value[target.field] = value;
            null;
          };
        } else if t == null && isProtectedType(obj) && isProtectedField(target.field) {
          // 受保护成员写入:内置类型对象(裸常量)的 check/raise/of/make
          protectedWriteError(target.field);
        } else {
          null;
        };
      };
    } else if target.type == "IndexAccess" {
      let arr = evaluate(target.object, env);
      let index = evaluate(target.index, env);
      if arr != null {
        let t = arr["type"];
        if isError(t) { t = null; }
        if t == "Array" {
          if index != null {
            if index.type == "Number" {
              let idx = getNumberValue(index);
              if idx < 0 {
                idx = arr.value.length + idx;
              }
              if idx >= 0 {
                if idx <= arr.value.length {
                  // idx == length appends via the host interpreter (arr[arr.length] = x semantics)
                  arr.value[idx] = value;
                }
              }
            }
          }
          null;
        } else if t == "Object" || t == "Type" {
          // JS semantics: obj[key] = value;"Type" 标签并入(包装的内置常量,
          // 如 std.Type.of(42) 产物)——同 MemberAccess:写入前按内层复查
          // 受保护成员,避免绕过;宿主对常量对象写入中止,不能静默丢弃。
          if index != null && index.type == "String" {
            if isProtectedType(arr.value) && isProtectedField(index.value) {
              protectedWriteError(index.value);
            } else {
              arr.value[index.value] = value;
              null;
            };
          } else {
            null;
          };
        } else if t == null && arr != null && index != null && index.type == "String" && isProtectedType(arr) && isProtectedField(index.value) {
          // obj["check"] = x 形式的受保护写入(与字段写法同规则)
          protectedWriteError(index.value);
        } else {
          null;
        };
      };
    }
  };

  let evaluate = (expr, env) -> {
    if expr.type == "Number" {
      { type: "Number", value: expr.value };
    } else if expr.type == "String" {
      { type: "String", value: expr.value };
    } else if expr.type == "Boolean" {
      { type: "Boolean", value: expr.value };
    } else if expr.type == "Null" {
      { type: "Null", value: null };
    } else if expr.type == "Identifier" {
      env._get(expr.name);
    } else if expr.type == "Array" {
      let elements = [];
      let i = 0;
      while i < expr.elements.length {
        let v = evaluate(expr.elements[i], env);
        if isPropagating(v) { return v; }
        pushArray(elements, v);
        i = i + 1;
      }
      { type: "Array", value: elements, length: getArrayLength(elements) };
    } else if expr.type == "Object" {
      let fields = {};
      let i = 0;
      while i < expr.fields.length {
        let field = expr.fields[i];
        let v = evaluate(field.value, env);
        if isPropagating(v) { return v; }
        fields[field.name] = v;
        i = i + 1;
      }
      { type: "Object", value: fields };
    } else if expr.type == "Function" {
      let capturedEnv = env;
      let p = expr.parameters;
      let b = expr.body;
      // Task 11: 参数标注在定义时求值(宿主同——引用定义处环境,含遮蔽语义),
      // 记录 paramTypes[i] = { ty, text } 或 null。
      let paramTypes = [];
      let i = 0;
      while i < expr.parameters.length {
        let pa = expr.parameters[i].annotation;
        if pa != null {
          let annVal = evaluate(pa, env);
          if isPropagating(annVal) { return annVal; }
          paramTypes[paramTypes.length] = { ty: normalizeAnnotation(annVal), text: "?" };
        } else {
          paramTypes[paramTypes.length] = null;
        }
        i = i + 1;
      }
      { type: "Function", params: p, body: b, env: capturedEnv, paramTypes: paramTypes };
    } else if expr.type == "Call" {
      let func = evaluate(expr.callee, env);
      if isPropagating(func) { return func; }
      let args = [];
      let i = 0;
      while i < expr.arguments.length {
        let a = evaluate(expr.arguments[i], env);
        if isPropagating(a) { return a; }
        pushArray(args, a);
        i = i + 1;
      }
      // callFunction never returns a propagate-marked wrapper (all its error
      // return paths carry propagate: false), so no re-propagation check here
      callFunction(func, args, env);
    } else if expr.type == "BinaryOp" {
      let left = evaluate(expr.left, env);
      if isPropagating(left) { return left; }
      if expr.operator == "??" {
        // ?? fallback: an Error left operand is replaced by the right operand
        if isErrorVal(left) {
          let right = evaluate(expr.right, env);
          if isPropagating(right) { return right; }
          right;
        } else {
          left;
        };
      } else if expr.operator == "&&" || expr.operator == "||" {
        // True short-circuit (matches the host): when the left operand decides
        // the result, the right operand is NOT evaluated (so a `?` inside it
        // cannot escape the short-circuit position).
        if isErrorVal(left) {
          // Error left operand: the host's operation zone poisons BEFORE the
          // short-circuit, without evaluating the right operand. Delegate with
          // a dummy right value — the host never touches it (message:
          // "cannot apply logical operation to Error and unknown", with cause).
          evalBinaryOp(expr.operator, left, { type: "Null", value: null });
        } else if expr.operator == "&&" {
          if isTruthy(left) {
            let right = evaluate(expr.right, env);
            if isPropagating(right) { return right; }
            right;
          } else {
            left;
          };
        } else {
          if isTruthy(left) {
            left;
          } else {
            let right = evaluate(expr.right, env);
            if isPropagating(right) { return right; }
            right;
          };
        };
      } else {
        let right = evaluate(expr.right, env);
        if isPropagating(right) { return right; }
        evalBinaryOp(expr.operator, left, right);
      };
    } else if expr.type == "UnaryOp" {
      let val = evaluate(expr.operand, env);
      if expr.operator == "?" {
        // ? propagation: an Error operand becomes a propagate-marked wrapper
        if isErrorVal(val) {
          return { type: "Error", value: val.value, propagate: true };
        } else {
          val;
        };
      } else {
        evalUnaryOp(expr.operator, val);
      };
    } else if expr.type == "MemberAccess" {
      let obj = evaluate(expr.object, env);
      if isPropagating(obj) { return obj; }
      let fieldName = expr.field;
      if obj != null {
        // Normalize the probe: raw host values probe as error values, which
        // would poison the == comparisons below; treat them as null instead
        // (isError: host native, cross-interpreter safe).
        let t = obj["type"];
        if isError(t) { t = null; }
        if t == "Object" || t == "Type" {
          // A wrapped object's value is a plain object { name: wrapper } (a
          // "Type"-tagged wrapper is the same shape holding a boot type
          // value); missing fields yield UndefinedField error values (host
          // semantics), wrapped here so the error keeps flowing as a value.
          let fieldValue = obj.value[fieldName];
          if !isError(fieldValue) && fieldValue != null {
            fieldValue;
          } else {
            { type: "Error", value: std.Object.field(obj.value, fieldName), propagate: false };
          };
        } else if t == "Array" {
          if fieldName == "length" {
            { type: "Number", value: getArrayLength(obj.value) };
          } else if fieldName == "type" {
            "Array";
          } else if fieldName == "value" {
            obj.value;
          } else {
            { type: "Null", value: null };
          }
        } else if t == "String" {
          if fieldName == "length" {
            // Char count (host "str".length counts chars, Unicode-safe)
            { type: "Number", value: obj.value.length };
          } else if fieldName == "type" {
            "String";
          } else {
            { type: "Null", value: null };
          }
        } else if t == "Number" {
          if fieldName == "type" {
            "Number";
          } else {
            { type: "Null", value: null };
          }
        } else if t == "Boolean" {
          if fieldName == "type" {
            "Boolean";
          } else {
            { type: "Null", value: null };
          }
        } else if t == "Function" {
          if fieldName == "type" {
            "Function";
          } else if fieldName == "params" {
            obj.params;
          } else if fieldName == "body" {
            obj.body;
          } else if fieldName == "env" {
            obj.env;
          } else {
            { type: "Null", value: null };
          }
        } else if t == "Error" {
          // Error read zone (matches host error_read_zone): err.type → kind,
          // err.message → message, err.cause → error/null, err.line/err.col → numbers
          let rv = obj.value[fieldName];
          if isError(rv) {
            { type: "Error", value: rv, propagate: false };
          } else if rv == null {
            { type: "Null", value: null };
          } else {
            // Raw read-zone value (kind/message string, line/col number):
            // wrap with the string tag via typeTag (stdlib.ql helper)
            { type: typeTag(rv), value: rv };
          };
        } else {
          // Raw host object (std modules, etc.): fetch the field directly
          let fieldValue = obj[fieldName];
          if !isError(fieldValue) && fieldValue != null {
            fieldValue;
          } else {
            { type: "Error", value: std.Object.field(obj, fieldName), propagate: false };
          };
        }
      } else {
        { type: "Null", value: null };
      }
    } else if expr.type == "IndexAccess" {
      let arr = evaluate(expr.object, env);
      if isPropagating(arr) { return arr; }
      let index = evaluate(expr.index, env);
      if isPropagating(index) { return index; }
      if arr != null {
        let t = arr["type"];
        if isError(t) { t = null; }
        if t == "Array" {
          if index != null {
            if index.type == "Number" {
              let idx = getNumberValue(index);
              if idx < 0 {
                idx = arr.value.length + idx;
              }
              if idx >= 0 {
                if idx < arr.value.length {
                  arr.value[idx];
                } else {
                  // Out-of-bounds: std.Array.at now returns an error VALUE
                  // (host error-as-value), which we wrap and propagate
                  { type: "Error", value: std.Array.at(arr.value, idx), propagate: false };
                }
              } else {
                // Negative out-of-range (idx < 0 after wrapping): pass an
                // equivalent out-of-range positive index (len) so Array.at
                // reports the same index as the host's get_index
                { type: "Error", value: std.Array.at(arr.value, arr.value.length), propagate: false };
              }
            }
          }
        } else if t == "String" {
          // String indexing: matches the host (Unicode-safe, out of bounds → error value)
          if index != null {
            if index.type == "Number" {
              let idx = getNumberValue(index);
              let s = arr.value;
              let len = s.length;   // host char count (this file runs in the host interpreter)
              if idx < 0 {
                idx = len + idx;
              }
              if idx >= 0 && idx < len {
                { type: "String", value: s[idx] };
              } else {
                // Out-of-bounds (incl. negative OOB): std.String.at returns an
                // error value; pass len so the reported index matches the host
                { type: "Error", value: std.String.at(s, if idx < 0 { len } else { idx }), propagate: false };
              }
            }
          }
        } else if t == "Object" || t == "Type" {
          // JS semantics: obj[key] missing → UndefinedField error value (host)
          if index != null {
            if index.type == "String" {
              let v = arr.value[index.value];
              if !isError(v) && v != null {
                v;
              } else {
                { type: "Error", value: std.Object.field(arr.value, index.value), propagate: false };
              };
            }
          }
        } else if t == "Error" {
          // Error read zone via index access too (err["message"] works like err.message)
          if index != null {
            let rv = arr.value[index.value];
            if isError(rv) {
              { type: "Error", value: rv, propagate: false };
            } else if rv == null {
              { type: "Null", value: null };
            } else {
              { type: typeTag(rv), value: rv };
            };
          };
        } else {
          { type: "Null", value: null };
        }
      } else {
        { type: "Null", value: null };
      }
    } else {
      { type: "Null", value: null };
    }
  };

  let getNumberValue = (num) -> {
    if num != null && num.type == "Number" { num.value; } else { 0; }
  };

  // Unwrap wrapped operands to raw values and delegate the operation to the
  // host. Type mismatches and error operands make the host produce an error
  // VALUE with the exact host message (and cause chain for error operands);
  // The wrapping is done inline (error results must not flow through a boot
  // function argument — the host rejects error values as user-function
  // arguments). This replaces the old raiseTypeMismatch helper.
  let evalDelegated = (op, l, r) -> {
    // Unwrap boot wrappers by their type tag (a "Type"-tagged wrapper holds a
    // boot type value and unwraps like any other; raw values probe as error
    // values and pass through untouched).
    let lv = if l != null && !isError(l.type) && l.type == "Number" { getNumberValue(l); }
      else if l != null && !isError(l.type) && l.type == "String" { l.value; }
      else if l != null && !isError(l.type) && l.type == "Boolean" { l.value; }
      else if l != null && !isError(l.type) && l.type == "Null" { null; }
      else if l != null && !isError(l.type) && l.type == "Error" { l.value; }
      else if l != null && !isError(l.type) && l.type == "Type" { l.value; }
      else { l; };
    let rv = if r != null && !isError(r.type) && r.type == "Number" { getNumberValue(r); }
      else if r != null && !isError(r.type) && r.type == "String" { r.value; }
      else if r != null && !isError(r.type) && r.type == "Boolean" { r.value; }
      else if r != null && !isError(r.type) && r.type == "Null" { null; }
      else if r != null && !isError(r.type) && r.type == "Error" { r.value; }
      else if r != null && !isError(r.type) && r.type == "Type" { r.value; }
      else { r; };
    let rawRes = if op == "+" { lv + rv }
      else if op == "-" { lv - rv }
      else if op == "*" { lv * rv }
      else if op == "/" { lv / rv }
      else if op == "%" { lv % rv }
      else if op == "<" { lv < rv }
      else if op == "<=" { lv <= rv }
      else if op == ">" { lv > rv }
      else if op == ">=" { lv >= rv }
      else if op == "&" { lv & rv }
      else if op == "|" { lv | rv }
      else if op == "^" { lv ^ rv }
      else if op == "&&" { lv && rv }
      else if op == "||" { lv || rv }
      else if op == "==" { lv == rv }
      else if op == "!=" { lv != rv }
      else { lv + rv };
    // Wrap inline: error results must not flow through a boot function argument
    // (the host rejects error values as user-function arguments). The wrapper
    // tag is the STRING type name from typeTag (std.Type.of now returns type
    // VALUES, which cannot serve as wrapper tags).
    if isError(rawRes) {
      { type: "Error", value: rawRes, propagate: false };
    } else if rawRes == null {
      { type: "Null", value: null };
    } else {
      { type: typeTag(rawRes), value: rawRes };
    };
  };

  let evalBinaryOp = (op, left, right) -> {
    // propagate 短路:? 的错误直接穿行(不运算、不构造新错误)
    if isPropagating(left) { return left; }
    if isPropagating(right) { return right; }
    // 运算即报错:错误操作数 → 委托宿主构造新错误(带 cause),消息与 host 一致
    if isErrorVal(left) { return evalDelegated(op, left, right); }
    if isErrorVal(right) { return evalDelegated(op, left, right); }
    // && / ||: matches the host — returns the first falsy / truthy operand itself
    if op == "&&" {
      if isTruthy(left) { right; } else { left; };
    } else if op == "||" {
      if isTruthy(left) { left; } else { right; };
    } else {
      // 注意:?? 不在此处理——evaluate 层已拦截(短路求值 right 需要)
      evalDelegated(op, left, right);
    };
  };

  let evalUnaryOp = (op, value) -> {
    if isPropagating(value) { return value; }
    if op == "-" {
      if value != null && !isError(value.type) && value.type == "Number" {
        { type: "Number", value: 0 - getNumberValue(value) };
      } else {
        // Non-Number (or Error): the host's unary negation produces the same
        // TypeMismatch error value (with cause for error operands)
        let raw = if value != null && !isError(value.type) { value.value; } else { value; };
        let rawRes = -(raw);
        if isError(rawRes) {
          { type: "Error", value: rawRes, propagate: false };
        } else if rawRes == null {
          { type: "Null", value: null };
        } else {
          { type: typeTag(rawRes), value: rawRes };
        };
      }
    } else if op == "!" {
      { type: "Boolean", value: !isTruthy(value) };
    } else {
      { type: "Null", value: null };
    }
  };

  let callFunction = (func, args, env) -> {
    callFunctionInner(func, args, env, false);
  };

  // 内部检查路径豁免:exemptErrorArgs = true 时跳过错误值参数检查(宿主
  // call_function_inner 的 exempt_error_args 对应;仅 checkValue 的类型检查
  // 用,用户调用一律 false——用户函数/原生均不豁免)。
  let callFunctionInner = (func, args, env, exemptErrorArgs) -> {
    if func != null {
      // Normalize the probe: raw host values (natives, boot functions, std
      // modules) probe as error values; unify them to null → native branch.
      let ft = func["type"];
      if isError(ft) { ft = null; }
      if ft == "Error" {
        // Calling an error value: NotCallable (matches the host)
        { type: "Error", value: std.Error.raise("NotCallable", "Not callable: Error", null), propagate: false };
      } else if ft == "Function" {
        // ---- user function ----
        // 统一参数视图:柯里化记录携带 allParams/boundArgs(部分应用时捕获的
        // 完整参数表与已绑定参数),最终应用时对全部参数做检查——与宿主
        // curried native 完成应用时带完整参数重走调用路径一致。
        // 注意:普通记录的 allParams/boundArgs 字段缺失,探测得错误值(不是
        // null)——必须先 isError 归一,否则错误值参与比较(truthy)会死循环。
        let allParams = func.allParams;
        if isError(allParams) { allParams = null; }
        if allParams == null { allParams = func.params; }
        let prevBound = func.boundArgs;
        if isError(prevBound) { prevBound = null; }
        let allArgs = [];
        let k = 0;
        let boundLen = if prevBound != null { prevBound.length; } else { 0; };
        while k < boundLen {
          pushArray(allArgs, prevBound[k]);
          k = k + 1;
        }
        let j = 0;
        while j < args.length {
          pushArray(allArgs, args[j]);
          j = j + 1;
        }
        // Argument check: user functions reject error values as arguments
        // (only the diagnostic natives are exempt; user functions never are;
        // the internal check path is exempted too — check functions must
        // receive error values, e.g. Number.check(1/0) → false)
        let argErr = null;
        if !exemptErrorArgs {
          let i = 0;
          while i < allArgs.length {
            if allArgs[i] != null && isErrorVal(allArgs[i]) { argErr = allArgs[i]; }
            i = i + 1;
          }
          if argErr != null {
            return { type: "Error", value: std.Error.raise("TypeMismatch", "attempt to pass error value as argument", argErr.value), propagate: false };
          }
        }
        if allArgs.length < allParams.length {
          // Partial application: matches the host — insufficient args return
          // a curried function. 宿主在部分应用时不检查标注(完成应用时全查);
          // 记录携带 allParams/boundArgs/paramTypes 供最终应用统一检查。
          let partialEnv = Environment(func.env);
          let q = 0;
          while q < allArgs.length {
            partialEnv._define(allParams[q].name, allArgs[q]);
            q = q + 1;
          }
          // Keep the remaining params as full Parameter records: the curried
          // function's later calls bind via .name, and the records carry the
          // annotation metadata the host preserves through partial application
          let remaining = [];
          let r = allArgs.length;
          while r < allParams.length {
            remaining[remaining.length] = allParams[r];
            r = r + 1;
          }
          { type: "Function", params: remaining, body: func.body, env: partialEnv, allParams: allParams, boundArgs: allArgs, paramTypes: func.paramTypes };
        } else if allArgs.length != allParams.length {
          // 参数过多:宿主 ArityMismatch 错误值(boot 旧行为静默丢弃多余参数)
          { type: "Error", value: std.Error.raise("ArityMismatch", "Arity mismatch: expected " + std.Number.toString(allParams.length) + " arguments, got " + std.Number.toString(allArgs.length), null), propagate: false };
        } else {
          // 参数标注检查(宿主顺序:柯里化/arity 之后、深度守卫之前):失败 →
          // TypeCheck 错误值,函数体不执行。
          let p = 0;
          while p < allParams.length {
            let ann = func.paramTypes[p];
            if ann != null {
              let ck = checkValue(ann.ty, allArgs[p], env);
              if isErrorVal(ck) {
                // check 自身出错 → 该错误值即调用结果(宿主 Err(e) → Ok(e))
                return ck;
              }
              if !isTruthy(ck) {
                return { type: "Error", value: std.Error.raise("TypeCheck", "argument " + std.Number.toString(p + 1) + " does not match the annotated type \"?\"", null), propagate: false };
              }
            }
            p = p + 1;
          }
          // Recursion depth guard: deep user recursion becomes a recoverable
          // StackOverflow error value instead of blowing the host stack
          if depth >= maxDepth {
            return { type: "Error", value: std.Error.raise("StackOverflow", "maximum recursion depth exceeded", null), propagate: false };
          }
          let localEnv = Environment(func.env);
          let i = 0;
          while i < allParams.length {
            // 带标注绑定(宿主 define_annotated):函数体内重赋值参数同样复查
            let ann2 = func.paramTypes[i];
            if ann2 != null {
              localEnv._defineAnnotated(allParams[i].name, allArgs[i], { ty: ann2.ty, text: "?" });
            } else {
              localEnv._define(allParams[i].name, allArgs[i]);
            }
            i = i + 1;
          }
          depth = depth + 1;
          let result = runStatements(func.body.statements, localEnv);
          depth = depth - 1;
          // `?` inside the function body: the error becomes the function's
          // return value (propagation STOPS at the boundary, matching the host)
          if result.flow == "Propagate" {
            return { type: "Error", value: result.value.value, propagate: false };
          }
          // Return the block value regardless of Return or None flow
          result.value;
        };
      } else if ft == null {
        // ---- host native (Rust stdlib) or host QLang function (stdlib.ql) ----
        // Distinguish by func.name: natives expose a name string, QLang
        // functions probe as an error value.
        // Host natives receive UNWRAPPED raw args (the Rust std expects raw
        // values); host QLang functions (the boot's type library: the
        // constants' checks, std.Type.of/check/make, Array/Object constructors,
        // Error.raise) receive boot WRAPPERS — their bodies test v.type on the
        // wrapper shape, so unwrapping would destroy the type predicates.
        // Diagnostic natives are exempt from the error-argument check:
        // print / println / Error / isError / raise / std.Type.of / Error.raise
        // The type predicates (the 9 constants' checks and Type.check) are
        // exempt too: the host's predicates are accepts_errors: true natives
        // that return false/true for error arguments (Number.check(1/0) →
        // false, Any.check(1/0) → true); the boot's QLang checks receive the
        // error WRAPPER and decide via v.type == "Error" the same way.
        let isNative = func != null && !isError(func.name);
        let isDiag = func == println || func == print || func == Error || func == isError || func == std.Error.raise || func == std.Error.toString || func == std.Type.of || func == Error.raise || func == Number.check || func == String.check || func == Boolean.check || func == Null.check || func == AnyArray.check || func == AnyObject.check || func == Function.check || func == Any.check || func == Never.check || func == Error.check || func == Type.check;
        if !isDiag && !exemptErrorArgs {
          let j = 0;
          while j < args.length {
            if args[j] != null && isErrorVal(args[j]) {
              let nativeName = if func.name == null || isError(func.name) { "?" } else { func.name };
              return { type: "Error", value: std.Error.raise("TypeMismatch", "attempt to pass error value as argument to " + nativeName, args[j].value), propagate: false };
            }
            j = j + 1;
          }
        }
        // Unwrap args: Null-tagged wrappers always become raw null (null
        // travels unwrapped in the boot); host natives additionally unwrap the
        // other scalar/array/error tags. Wrapped objects, functions and type
        // values stay wrapped (their members are boot values, not raw ones).
        let rawArgs = [];
        let i = 0;
        while i < args.length {
          let a = args[i];
          // Probe the wrapper tag; raw host values probe as an error VALUE
          // (never null), which must keep them intact.
          let tag = a["type"];
          if isError(tag) { tag = null; }
          if tag == "Null" {
            rawArgs[rawArgs.length] = null;
          } else if isNative && tag != "Object" && tag != "Function" && tag != "Type" {
            rawArgs[rawArgs.length] = a.value;
          } else {
            rawArgs[rawArgs.length] = a;
          }
          i = i + 1;
        }
        // Args are spread positionally (func(a) / func(a, b)); never pass the array as a whole
        let raw = if rawArgs.length == 1 { func(rawArgs[0]); }
        else if rawArgs.length == 2 { func(rawArgs[0], rawArgs[1]); }
        else if rawArgs.length == 3 { func(rawArgs[0], rawArgs[1], rawArgs[2]); }
        else if rawArgs.length == 4 { func(rawArgs[0], rawArgs[1], rawArgs[2], rawArgs[3]); }
        else { func(rawArgs); };
        // Note: the isError check must come BEFORE `raw == null` — comparing
        // an error operand with == yields an error value, which is truthy and
        // would wrongly take the null branch.
        if isError(raw) {
          // Error results get the dedicated wrapper
          { type: "Error", value: raw, propagate: false };
        } else if raw == null {
          { type: "Null", value: null };
        } else {
          // Wrapper tag is the STRING type name from typeTag (stdlib.ql);
          // std.Type.of now returns type VALUES, which cannot serve as tags
          { type: typeTag(raw), value: raw };
        };
      } else {
        // Other wrapped types are not callable
        { type: "Error", value: std.Error.raise("NotCallable", "Not callable: " + ft, null), propagate: false };
      }
    } else {
      { type: "Null", value: null };
    }
  };

  { runProgram: runProgram, evaluate: evaluate, globalEnv: globalEnv };
};

export Interpreter;
