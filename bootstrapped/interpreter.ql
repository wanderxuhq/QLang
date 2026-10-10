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
import ./modules.ql;
import ./library.ql;
import ./native_values.ql;

// Immutable library AST/closures are shared. Every user module receives fresh
// public namespace tables; library closures capture a private bootstrap scope.
let libraryProgram = null;
let libraryExports = null;

let Interpreter = () -> {
  // Retained bootstrap hosts without this capability keep their existing Error
  // representation. Native QLang hosts provide scoped diagnostic provenance.
  let diagnostics = std.__diagnostics;
  let hasDiagnostics = !isError(diagnostics);
  let nativeHost = std.__extensions;
  let nativeBridge = null;
  let sourcePoint = (node) -> { if isError(node.location) { null; } else { node.location; }; };
  // User modules own their namespace tables. Keep the interpreter's std
  // private so user augmentation cannot rewrite its formatting or file APIs.
  // Type is a protected canonical type value; retain its identity.
  let userStd = {}; let moduleKeys = std.Object.keys(std); let mi = 0;
  while mi < moduleKeys.length {
    let key = moduleKeys[mi]; let value = std[key];
    if key != "Type" && typeTag(value) == "Object" {
      let copy = {}; let keys = std.Object.keys(value); let i = 0;
      while i < keys.length { copy[keys[i]] = value[keys[i]]; i = i + 1; };
      value = copy;
    };
    // The embedding source context is not a user diagnostic-control API.
    if key != "__diagnostics" && key != "__extensions" { userStd[key] = value; }; mi = mi + 1;
  };
  let globalEnv = GlobalEnvironment(userStd);
  // Each module has a lexical args binding backed by the shared process array.
  // Rebinding/shadowing args does not replace the process arguments for imports.
  let processArguments = {type: "Array", value: []};
  let shareArguments = (values) -> {
    processArguments = values; globalEnv._define("args", values); null;
  };
  let setArguments = (values) -> {
    if typeTag(values) != "Array" { return std.Error.raise("TypeMismatch", "interpreter arguments must be an Array of Strings", null); };
    let wrapped = []; let i = 0;
    while i < values.length {
      if typeTag(values[i]) != "String" { return std.Error.raise("TypeMismatch", "interpreter arguments must be Strings", null); };
      wrapped[wrapped.length] = {type: "String", value: values[i]}; i = i + 1;
    };
    shareArguments({type: "Array", value: wrapped});
  };
  shareArguments(processArguments);
  let currentPath = "";
  let libraryInitError = null;
  let loadingModules = {};
  let moduleExports = {};
  let setModuleContext = (path, loading) -> { currentPath = path; loadingModules = loading; };
  let importModule = (node, env) -> {
    if !isError(node.pathExpression) {
      let path = evaluate(node.pathExpression, env);
      if isExiting(path) { return path; };
      if nativeBridge == null {
        return {type: "Error", value: std.Error.raise("NativeExtensionUnavailable", "this interpreter has no native extension bridge", null), propagate: false};
      };
      let origin = if isError(node.origin) { currentPath; } else { node.origin; };
      return nativeBridge.load(path, origin, processArguments);
    };
    let path = modulePath(currentPath, node.path);
    if isError(path) { return { type: "Error", value: path, propagate: true }; };
    if !isError(loadingModules[path]) && loadingModules[path] == true {
      return { type: "Error", value: std.Error.raise("ImportCycle", "cyclic import: " + path, null), propagate: true };
    };
    let source = std.fs.readFileText(path);
    if isError(source) { return { type: "Error", value: source, propagate: true }; };
    let program = parseModule(source, path);
    if isError(program) { return { type: "Error", value: program, propagate: true }; };
    let module = Interpreter(); module.setModuleContext(path, loadingModules); module._shareArguments(processArguments); module._shareNativeBridge(nativeBridge);
    let result = module.runProgram(program);
    if isErrorVal(result.value) { return { type: "Error", value: result.value.value, propagate: false }; };
    let values = module.getExports(); let keys = std.Object.keys(values); let i = 0;
    while i < keys.length { env._define(keys[i], values[keys[i]]); i = i + 1; };
    { type: "Object", value: values };
  };

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
  // Task 12: NO bare `Type` global — the spec has no global Type alias (§3.5,
  // annotation form is `std.Type`), and the host does not define one; removing
  // the seeding aligns both sides (difftest r35 asserts both error on `Type`).
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
    else if value.type == "Array" { value.value.length != 0 }
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

  let wrapJSON = (raw) -> {
    let tag = typeTag(raw);
    if tag == "Array" {
      let a = [];
      let i = 0;
      while i < raw.length {
        a[a.length] = wrapJSON(raw[i]);
        i = i + 1;
      };
      return { type: "Array", value: a, length: a.length };
    };
    if tag == "Object" {
      let o = {};
      let keys = std.Object.keys(raw);
      let i = 0;
      while i < keys.length {
        o[keys[i]] = wrapJSON(raw[keys[i]]);
        i = i + 1;
      };
      return { type: "Object", value: o };
    };
    { type: tag, value: raw };
  };

  let isErrorVal = (v) -> {
    isWrapped(v) && v.type == "Error";
  };

  let isPropagating = (v) -> {
    // Step B: inlined isErrorVal(isWrapped(v)) && propagate — one boot-closure
    // dispatch instead of three (isPropagating → isErrorVal → isWrapped). Pure
    // textual expansion: same probe sequence (v.type ×2, v.propagate ×1), same
    // left-to-right short-circuit, predicates capture nothing — truth-table
    // identical for every input, only host dispatches drop (2/call × 54,107).
    v != null && !isError(v.type) && v.type == "Error" && v.propagate == true;
  };

  // An If expression can execute a Return statement in the enclosing function.
  // Carry that completion through parent expressions without touching its value.
  let returnMarker = {};
  let isReturning = (v) -> {
    v != null && !isError(v.type) && v.type == "Return" && !isError(v.marker) && v.marker == returnMarker;
  };
  let isExiting = (v) -> {
    isReturning(v) || isPropagating(v);
  };
  let expressionExit = (v) -> {
    if isReturning(v) { { flow: "Return", value: v.value }; }
    else { { flow: "Propagate", value: v }; };
  };

  // ---- Task 11: annotation-checking semantics ----
  //
  // Protected built-in type objects (bare constants, corresponding to the host's TYPE_MARKER
  // objects); user types (Type.make products) are not in the list, consistent with the host's
  // user_type being unprotected. The Array/Object constructors are functions and do not participate in field writes.
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
    // Host side: RuntimeError::Custom (program abort); the boot has no exit primitive, so it propagates
    // via the error channel (propagate: true → top level prints the diagnostic and returns flow "Error"). The message matches the host.
    { type: "Error", value: std.Error.raise("Custom", "cannot overwrite protected member '" + field + "' of built-in type", null), propagate: true };
  };

  // Annotation normalization: constructor products (Array(Number)/Type.make/Object(...)) are wrapped by the call path into
  // {type:"Object", value: {check: f}} wrappers — the checking path takes the inner type object;
  // everything else (bare constants/error values/plain objects) is returned as-is.
  let normalizeAnnotation = (a) -> {
    if a != null && !isError(a.type) && (a.type == "Object" || a.type == "Type") && isTypeValue(a.value) {
      a.value;
    } else {
      a;
    };
  };

  // TypeCheck messages retain the annotation source captured by the parser. Note: the error construction must be inlined in the host-layer code
  // (Let/Assign branches) calling std.Error.raise directly — cause is a bare error value; passing
  // it through a boot user-function argument would be rejected by the call path's error-value-argument check (observed: makeTypeCheckError produces TypeMismatch).
  let typeCheckMsg = (typeName, text) -> "value of type \"" + typeName + "\" does not match the annotated type \"" + text + "\"";

  // Internal check path: calls the type value's check function, exempting error-value arguments
  // (corresponds to the host's exempt_error_args in call_function_inner; user calls are not exempt).
  // Returns {type:"Boolean", value: bool}, or an error wrapper (annotation not a type value / check raised an error).
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
    if libraryInitError != null { return { flow: "Propagate", value: libraryInitError }; };
    if !isError(program.errors) && program.errors.length > 0 {
      return { flow: "Propagate", value: { type: "Error", value: std.Error.raise("ParseError", program.errors[0], null), propagate: true } };
    };
    let env = globalEnv;
    loadingModules[currentPath] = true;
    let result = runStatements(program.statements, env);
    loadingModules[currentPath] = false;
    result;
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
      // Declarations, assignments, loops and untaken ifs do not produce a value.
      if result.flow == "Value" { lastValue = result.value; };
      i = i + 1;
    }
    return { flow: "None", value: lastValue };
  };

  let runStatement = (stmt, env) -> {
    let previous = null;
    if hasDiagnostics { previous = diagnostics.enter(sourcePoint(stmt)); };
    let result = runStatementInner(stmt, env);
    if hasDiagnostics { diagnostics.leave(previous); };
    result;
  };
  let runStatementInner = (stmt, env) -> {
    if stmt.type == "Let" {
      let annVal = null;
      let annText = "?";
      if stmt.annotation != null {
        annVal = evaluate(stmt.annotation, env);
        if isExiting(annVal) { return expressionExit(annVal); };
        annVal = normalizeAnnotation(annVal);
        if !isError(stmt.annotation.annotationText) { annText = stmt.annotation.annotationText; };
      };
      if stmt.value != null {
        let val = evaluate(stmt.value, env);
        if isExiting(val) {
          return expressionExit(val);
        }
        if stmt.annotation != null {
          let ck = checkValue(annVal, val, env);
          if isErrorVal(ck) {
            // The check itself errored (annotation not a type value / check raised an error).
            // A failed annotation check propagates out of the current function, matching the
            // compiler: the binding is never created holding an Error.
            return { type: "Error", value: ck.value, propagate: true };
          } else if isTruthy(ck) {
            env._defineAnnotated(stmt.name, val, { ty: annVal, text: annText });
          } else {
            // Check failed → TypeCheck error value (cause = the original value if it is an error),
            // propagated rather than bound (the error construction is inlined at the host layer:
            // cause is a bare error value; a boot function argument would be rejected)
            let typeName = if val == null { "Null"; } else if !isError(val.type) { val.type; } else { typeTag(val); };
            if typeName == "Type" { typeName = "Object"; };
            let cause = if isErrorVal(val) { val.value; } else { null; };
            return { type: "Error", value: std.Error.raise("TypeCheck", typeCheckMsg(typeName, annText), cause), propagate: true };
          };
        } else {
          env._define(stmt.name, val);
        };
        return { flow: "None", value: { type: "Null", value: null } };
      } else {
        // Declaration without initializer: let x; / let x: T;
        if stmt.annotation != null {
          if !isTypeValue(annVal) {
            // Annotation invalid → bind a TypeCheck error value (consistent with the host's None branch,
            // interpreter.rs:254-258: define binding, annotation not kept)
            env._define(stmt.name, { type: "Error", value: std.Error.raise("TypeCheck", "type annotation is not a type value", null), propagate: false });
          } else {
            env._defineUninit(stmt.name, { ty: annVal, text: annText });
          };
        } else {
          env._defineUninit(stmt.name, null);
        };
        return { flow: "None", value: { type: "Null", value: null } };
      };
    } else if stmt.type == "Assign" {
      let val = evaluate(stmt.value, env);
      if isExiting(val) {
        return expressionExit(val);
      }
      let res = assignValue(stmt.target, val, env);
      if isReturning(res) { return expressionExit(res); };
      if res != null && isErrorVal(res) {
        // Failed assignments propagate through the interpreter error channel.
        return { flow: "Propagate", value: res };
      }
      return { flow: "None", value: { type: "Null", value: null } };
    } else if stmt.type == "If" {
      return runIfStatement(stmt, env);
    } else if stmt.type == "While" {
      return runWhileStatement(stmt, env);
    } else if stmt.type == "Return" {
      let val = evaluate(stmt.value, env);
      if isExiting(val) {
        return expressionExit(val);
      }
      return { flow: "Return", value: val };
    } else if stmt.type == "Export" {
      let val = evaluate(stmt.value, env);
      if isExiting(val) { return expressionExit(val); };
      if stmt.name != null { moduleExports[stmt.name] = val; }
      else if stmt.value.type == "Identifier" { moduleExports[stmt.value.name] = val; }
      else if stmt.value.type == "Object" {
        let keys = std.Object.keys(val.value); let i = 0;
        while i < keys.length { moduleExports[keys[i]] = val.value[keys[i]]; i = i + 1; };
      };
      return { flow: "None", value: { type: "Null", value: null } };
    } else {
      let val = evaluate(stmt, env);
      if isExiting(val) {
        return expressionExit(val);
      }
      return { flow: "Value", value: val };
    };
  };

  let runIfStatement = (stmt, env) -> {
    let i = 0;
    while i < stmt.branches.length {
      let branch = stmt.branches[i];
      let condition = evaluate(branch.condition, env);
      if isExiting(condition) {
        return expressionExit(condition);
      }
      if isTruthy(condition) {
        let result = runStatements(branch.body.statements, Environment(env));
        if result.flow == "None" { result.flow = "Value"; };
        return result;
      }
      i = i + 1;
    }

    if stmt.elseBody != null {
      let result = runStatements(stmt.elseBody.statements, Environment(env));
      if result.flow == "None" { result.flow = "Value"; };
      return result;
    }

    return { flow: "None", value: { type: "Null", value: null } };
  };

  let runWhileStatement = (stmt, env) -> {
    let done = false;
    while !done {
      let condition = evaluate(stmt.condition, env);
      if isExiting(condition) {
        return expressionExit(condition);
      }
      if !isTruthy(condition) {
        done = true;
      } else {
        let result = runStatements(stmt.body.statements, Environment(env));
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

  // Returns null (success) or an error wrapper (protected-member write → propagate: true,
  // propagated to the top level through the Assign branch's error channel).
  let assignValue = (target, value, env) -> {
    let previous = null;
    if hasDiagnostics { previous = diagnostics.enter(sourcePoint(target)); };
    let result = assignValueInner(target, value, env);
    if hasDiagnostics { diagnostics.leave(previous); };
    result;
  };
  let assignValueInner = (target, value, env) -> {
    if target.type == "Identifier" {
      // Task 11: reassignment check — when the binding has an annotation, check again before assigning (getAnnotation walks the chain)
      let ann = env._getAnnotation(target.name);
      let assigned = false;
      if ann != null {
        let ck = checkValue(ann.ty, value, env);
        if isErrorVal(ck) {
          // A failed reassignment check propagates out of the current function, matching
          // the compiler: the binding keeps holding only its declared type.
          return { type: "Error", value: ck.value, propagate: true };
        } else if isTruthy(ck) {
          assigned = env._assign(target.name, value);
        } else {
          let typeName = if value == null { "Null"; } else if !isError(value.type) { value.type; } else { typeTag(value); };
            if typeName == "Type" { typeName = "Object"; };
          let cause = if isErrorVal(value) { value.value; } else { null; };
          return { type: "Error", value: std.Error.raise("TypeCheck", typeCheckMsg(typeName, ann.text), cause), propagate: true };
        };
      } else {
        assigned = env._assign(target.name, value);
      };
      if assigned != true {
        return { type: "Error", value: std.Error.raise("UndefinedVariable", "Undefined variable: " + target.name, null), propagate: true };
      };
      null;
    } else if target.type == "MemberAccess" || target.type == "IndexAccess" {
      let obj = evaluate(target.object, env);
      if isReturning(obj) || isErrorVal(obj) { return obj; };
      let tag = typeTag(obj);
      let receiver = obj;
      if isWrapped(obj) { tag = obj.type; receiver = obj.value; };
      let key = null;
      if target.type == "MemberAccess" {
        key = target.field;
        if tag != "Object" && tag != "Type" {
          return { type: "Error", value: std.Error.raise("NotAnObject", "Not an object", null), propagate: true };
        };
      } else {
        let index = evaluate(target.index, env);
        if isReturning(index) || isErrorVal(index) { return index; };
        let indexTag = typeTag(index);
        key = index;
        if isWrapped(index) { indexTag = index.type; key = index.value; };
        if tag == "Array" && indexTag == "Number" {
          let len = receiver.length;
          if !std.Number.isFinite(key) || key < -len || key > len || key % 1 != 0 {
            return { type: "Error", value: std.Error.raise("IndexOutOfBounds", "Index out of bounds", null), propagate: true };
          };
          if key < 0 { key = len + key; };
          receiver[key] = value;
          return null;
        };
        if (tag != "Object" && tag != "Type") || (indexTag != "String" && indexTag != "Number") {
          return { type: "Error", value: std.Error.raise("CannotIndex", "Cannot index", null), propagate: true };
        };
        if indexTag == "Number" { key = std.Number.toString(key); };
      };
      if isProtectedType(receiver) && isProtectedField(key) { return protectedWriteError(key); };
      receiver[key] = value;
      null;
    }
  };

  let interpolationText = (v) -> {
    if v == null { return "null"; };
    if !isWrapped(v) { return std.String.toString(v); };
    if v.type == "Function" {
      if !isError(v.extensionFunction) { return "${v.extensionFunction}"; };
      if !isError(v.boundArgs) { return "<native fn <curried>>"; };
      return "<function>";
    };
    if v.type == "Error" { return std.Error.toString(v.value); };
    if v.type == "Array" {
      let text = "["; let i = 0;
      while i < v.value.length {
        if i > 0 { text = text + ", "; };
        text = text + interpolationText(v.value[i]); i = i + 1;
      };
      return text + "]";
    };
    if v.type == "Object" || v.type == "Type" {
      let text = "{"; let keys = std.Object.keys(v.value); let i = 0;
      while i < keys.length {
        if i > 0 { text = text + ", "; };
        let key = keys[i]; text = text + key + ": " + interpolationText(v.value[key]); i = i + 1;
      };
      return text + "}";
    };
    std.String.toString(v.value);
  };

  let evaluate = (expr, env) -> {
    let point = sourcePoint(expr); let previous = null;
    if hasDiagnostics { previous = diagnostics.enter(point); };
    let result = evaluateInner(expr, env);
    // Native container elements and namespace fields may contain raw values.
    // Normalize scalar/Array expression results before ordinary language use,
    // so indexing, length, truthiness and type checks share literal semantics.
    // Keep raw host callables and canonical type/namespace tables unchanged.
    if result != null && !isWrapped(result) {
      let tag = typeTag(result);
      if tag == "Number" || tag == "String" || tag == "Boolean" || tag == "Array" {
        result = {type: tag, value: result};
      };
    };
    if hasDiagnostics {
      if isErrorVal(result) {
        let traced = diagnostics.error(result.value, point, expr.type == "Call" || expr.type == "Import");
        result = {type: "Error", value: traced, propagate: result.propagate};
      };
      diagnostics.leave(previous);
    };
    result;
  };
  let evaluateInner = (expr, env) -> {
    if expr.type == "Number" {
      { type: "Number", value: expr.value };
    } else if expr.type == "String" {
      if isError(expr.parts) { return { type: "String", value: expr.value }; };
      let text = ""; let i = 0;
      while i < expr.parts.length {
        let part = expr.parts[i];
        if part.kind == "Literal" { text = text + part.value; }
        else {
          let value = evaluate(part.expression, env);
          if isExiting(value) { return value; };
          text = text + interpolationText(value);
        };
        i = i + 1;
      };
      { type: "String", value: text };
    } else if expr.type == "Boolean" {
      { type: "Boolean", value: expr.value };
    } else if expr.type == "Null" {
      { type: "Null", value: null };
    } else if expr.type == "Import" {
      importModule(expr, env);
    } else if expr.type == "Identifier" {
      env._get(expr.name);
    } else if expr.type == "Array" {
      let elements = [];
      let i = 0;
      while i < expr.elements.length {
        let v = evaluate(expr.elements[i], env);
        if isExiting(v) { return v; }
        pushArray(elements, v);
        i = i + 1;
      }
      { type: "Array", value: elements, length: elements.length };
    } else if expr.type == "Object" {
      let fields = {};
      let i = 0;
      while i < expr.fields.length {
        let field = expr.fields[i];
        let v = evaluate(field.value, env);
        if isExiting(v) { return v; }
        fields[field.name] = v;
        i = i + 1;
      }
      { type: "Object", value: fields };
    } else if expr.type == "If" {
      let result = runIfStatement(expr, env);
      if result.flow == "Return" { { type: "Return", marker: returnMarker, value: result.value }; }
      else { result.value; };
    } else if expr.type == "Function" {
      let capturedEnv = env;
      let p = expr.parameters;
      let b = expr.body;
      // Task 11: parameter annotations are evaluated at definition time (same as the host — references
      // the defining environment, including shadowing semantics), recording paramTypes[i] = { ty, text } or null.
      let paramTypes = [];
      let i = 0;
      while i < expr.parameters.length {
        let pa = expr.parameters[i].annotation;
        if pa != null {
          let annVal = evaluate(pa, env);
          if isExiting(annVal) { return annVal; }
          let text = if isError(pa.annotationText) { "?"; } else { pa.annotationText; };
          paramTypes[paramTypes.length] = { ty: normalizeAnnotation(annVal), text: text };
        } else {
          paramTypes[paramTypes.length] = null;
        }
        i = i + 1;
      }
      { type: "Function", params: p, body: b, env: capturedEnv, path: currentPath, moduleExports: moduleExports, paramTypes: paramTypes };
    } else if expr.type == "Call" {
      let func = evaluate(expr.callee, env);
      if isExiting(func) { return func; }
      let args = [];
      let i = 0;
      while i < expr.arguments.length {
        let a = evaluate(expr.arguments[i], env);
        if isExiting(a) { return a; }
        pushArray(args, a);
        i = i + 1;
      }
      // callFunction never returns a propagate-marked wrapper (all its error
      // return paths carry propagate: false), so no re-propagation check here
      callFunction(func, args, env);
    } else if expr.type == "BinaryOp" {
      let left = evaluate(expr.left, env);
      if isExiting(left) { return left; }
      if expr.operator == "??" {
        // ?? fallback: an Error left operand is replaced by the right operand
        if isErrorVal(left) {
          let right = evaluate(expr.right, env);
          if isExiting(right) { return right; }
          right;
        } else {
          left;
        };
      } else if expr.operator == "&&" || expr.operator == "||" {
        // True short-circuit (matches the host): when the left operand decides
        // the result, the right operand is NOT evaluated (so a `?` inside it
        // cannot escape the short-circuit position).
        if left != null && !isError(left.type) && left.type == "Error" {
          // Error left operand: the host's operation zone poisons BEFORE the
          // short-circuit, without evaluating the right operand. Delegate with
          // a dummy right value — the host never touches it (message:
          // "cannot apply logical operation to Error and unknown", with cause).
          evalBinaryOp(expr.operator, left, { type: "Null", value: null });
        } else if expr.operator == "&&" {
          if isTruthy(left) {
            let right = evaluate(expr.right, env);
            if isExiting(right) { return right; }
            right;
          } else {
            left;
          };
        } else {
          if isTruthy(left) {
            left;
          } else {
            let right = evaluate(expr.right, env);
            if isExiting(right) { return right; }
            right;
          };
        };
      } else {
        let right = evaluate(expr.right, env);
        if isExiting(right) { return right; }
        evalBinaryOp(expr.operator, left, right);
      };
    } else if expr.type == "UnaryOp" {
      let val = evaluate(expr.operand, env);
      if isExiting(val) { return val; };
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
      if isExiting(obj) { return obj; }
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
          if isError(fieldValue) {
            { type: "Error", value: fieldValue, propagate: false };
          } else if fieldValue == null {
            { type: "Null", value: null };
          } else {
            fieldValue;
          };
        } else if t == "Array" {
          if fieldName == "length" {
            { type: "Number", value: obj.value.length };
          } else if fieldName == "add" || fieldName == "remove" {
            { type: "Function", boundArray: obj.value, boundMethod: fieldName };
          } else {
            { type: "Error", value: std.Error.raise("UndefinedField", "Undefined field", null), propagate: false };
          }
        } else if t == "String" {
          if fieldName == "length" {
            // Char count (host "str".length counts chars, Unicode-safe)
            { type: "Number", value: obj.value.length };
          } else {
            { type: "Error", value: std.Error.raise("NotAnObject", "Not an object", null), propagate: false };
          }
        } else if t == "Number" || t == "Boolean" || t == "Null" {
          { type: "Error", value: std.Error.raise("NotAnObject", "Not an object", null), propagate: false };
        } else if t == "Function" {
          if fieldName == "name" && !isError(obj.extensionFunction) {
            let name = obj.extensionFunction.name;
            if isError(name) { {type: "Error", value: name, propagate: false}; }
            else { {type: "String", value: name}; };
          } else if fieldName == "name" && !isError(obj.boundArray) {
            let name = "Array." + obj.boundMethod;
            { type: "String", value: name };
          } else if fieldName == "name" && !isError(obj.boundArgs) {
            { type: "String", value: "<curried>" };
          } else {
            // Function records are an implementation detail, not user objects.
            { type: "Error", value: std.Error.raise("NotAnObject", "Not an object", null), propagate: false };
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
        } else if typeTag(obj) == "Function" {
          // Native functions are not Objects. The host's dotted .name access
          // exposes their existing metadata; computed object indexing does not.
          let member = if fieldName == "name" { obj.name; }
            else { std.Error.raise("NotAnObject", "Not an object", null); };
          if isError(member) {
            { type: "Error", value: member, propagate: false };
          } else {
            { type: "String", value: member };
          };
        } else {
          // Raw host object (std modules, etc.): fetch the field directly
          let fieldValue = obj[fieldName];
          if isError(fieldValue) {
            { type: "Error", value: fieldValue, propagate: false };
          } else if fieldValue == null {
            { type: "Null", value: null };
          } else {
            fieldValue;
          };
        }
      } else {
        { type: "Error", value: std.Error.raise("NotAnObject", "Not an object", null), propagate: false };
      }
    } else if expr.type == "IndexAccess" {
      let arr = evaluate(expr.object, env);
      if isExiting(arr) { return arr; }
      let index = evaluate(expr.index, env);
      if isExiting(index) { return index; }
      if arr != null {
        let t = arr["type"];
        if isError(t) { t = null; }
        if t == "Array" || t == "String" {
          let key = index; let keyType = typeTag(index);
          if isWrapped(index) { key = index.value; keyType = index.type; };
          if t == "Array" && keyType == "Error" { return index; };
          if keyType != "Number" {
            let kind = if t == "Array" { "CannotIndex"; } else { "TypeMismatch"; };
            return { type: "Error", value: std.Error.raise(kind, t + " index must be a Number", null), propagate: false };
          };
          let size = arr.value.length;
          if key != key || key - key != 0 || key < -size || key >= size || key % 1 != 0 {
            return { type: "Error", value: std.Error.raise("IndexOutOfBounds", "Index out of bounds", null), propagate: false };
          };
          if key < 0 { key = size + key; };
          let value = arr.value[key];
          if isError(value) {
            { type: "Error", value: value, propagate: false };
          } else if t == "String" {
            { type: "String", value: value };
          } else {
            // Array elements already carry the interpreter's value wrappers.
            value;
          };
        } else if t == "Object" || t == "Type" {
          let key = index; let keyType = typeTag(index);
          if isWrapped(index) { key = index.value; keyType = index.type; };
          if keyType == "Error" { return index; };
          if keyType != "String" && keyType != "Number" {
            return { type: "Error", value: std.Error.raise("CannotIndex", "object key must be a String or Number", null), propagate: false };
          };
          // The host index operation owns numeric-key conversion. Preserve
          // stored Error/Null values without passing them through a helper.
          let value = arr.value[key];
          if isError(value) {
            { type: "Error", value: value, propagate: false };
          } else if value == null {
            { type: "Null", value: null };
          } else {
            value;
          };
        } else if t == "Error" {
          // Error read zone via index access too (err["message"] works like err.message)
          let key = index; let keyType = typeTag(index);
          if isWrapped(index) { key = index.value; keyType = index.type; };
          if keyType != "String" {
            return { type: "Error", value: std.Error.raise("CannotIndex", "Cannot index", null), propagate: false };
          };
          let rv = arr.value[key];
          if isError(rv) {
            { type: "Error", value: rv, propagate: false };
          } else if rv == null {
            { type: "Null", value: null };
          } else {
            { type: typeTag(rv), value: rv };
          };
        } else if t == null && (typeTag(arr) == "Object" || typeTag(arr) == "Type") {
          // Canonical type values and standard-library namespaces are raw host
          // tables, unlike interpreted object literals. Computed field access
          // must reach the same table as dotted access without exposing the
          // internal fields of Function or scalar wrapper records.
          let key = index; let keyType = typeTag(index);
          if isWrapped(index) { key = index.value; keyType = index.type; };
          if keyType == "Error" { return index; };
          if keyType != "String" && keyType != "Number" {
            return { type: "Error", value: std.Error.raise("CannotIndex", "object key must be a String or Number", null), propagate: false };
          };
          // The host's ordinary index operation owns numeric-key conversion.
          // Do not pass a stored Error through an ordinary helper call.
          let value = arr[key];
          if isError(value) {
            { type: "Error", value: value, propagate: false };
          } else if value == null {
            { type: "Null", value: null };
          } else {
            // Existing wrappers and raw host callables retain their identity.
            value;
          };
        } else {
          { type: "Error", value: std.Error.raise("CannotIndex", "Cannot index", null), propagate: false };
        }
      } else {
        { type: "Error", value: std.Error.raise("CannotIndex", "Cannot index", null), propagate: false };
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
    // propagate short-circuit: a `?`-marked error passes straight through (no operation, no new error constructed)
    if isExiting(left) { return left; }
    if isExiting(right) { return right; }
    // The operation itself errors: error operand → delegate to the host to construct a new error (with cause), message matches the host
    // Step B: isErrorVal inlined (isWrapped body inlined too) — same probes, -2 dispatches per check
    if left != null && !isError(left.type) && left.type == "Error" { return evalDelegated(op, left, right); }
    if right != null && !isError(right.type) && right.type == "Error" { return evalDelegated(op, left, right); }
    // && / ||: matches the host — returns the first falsy / truthy operand itself
    if op == "&&" {
      if isTruthy(left) { right; } else { left; };
    } else if op == "||" {
      if isTruthy(left) { left; } else { right; };
    } else {
      // Note: ?? is not handled here — the evaluate layer already intercepts it (short-circuit evaluation of the right operand requires this)
      evalDelegated(op, left, right);
    };
  };

  let evalUnaryOp = (op, value) -> {
    if isExiting(value) { return value; }
    if op == "+" {
      if value != null && !isError(value.type) && value.type == "Number" { return value; };
      let wrapped = isWrapped(value);
      let name = if wrapped { value.type; }
        else if isTypeValue(value) { "Type"; } else { typeTag(value); };
      let cause = null; if wrapped && name == "Error" { cause = value.value; };
      { type: "Error", value: std.Error.raise("TypeMismatch", "cannot apply unary plus to " + name + " and Number", cause), propagate: false };
    } else if op == "-" {
      if value != null && !isError(value.type) && value.type == "Number" {
        { type: "Number", value: -getNumberValue(value) };
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

  // Internal check path exemption: with exemptErrorArgs = true, the error-value-argument check is
  // skipped (corresponds to the host's exempt_error_args in call_function_inner; used only by
  // checkValue's type check — user calls always pass false; neither user functions nor natives are exempt).
  let callFunctionInner = (func, args, env, exemptErrorArgs) -> {
    if func != null {
      // Normalize the probe: raw host values (natives, boot functions, std
      // modules) probe as error values; unify them to null → native branch.
      let ft = func["type"];
      if isError(ft) { ft = null; }
      if ft == "Error" {
        // Calling an error value: NotCallable (matches the host)
        { type: "Error", value: std.Error.raise("NotCallable", "Not callable: Error", null), propagate: false };
      } else if ft == "Function" && !isError(func.extensionFunction) {
        nativeBridge.call(func.extensionFunction, args, exemptErrorArgs);
      } else if ft == "Function" && !isError(func.boundArray) {
        let methodName = "Array." + func.boundMethod;
        let j = 0;
        while j < args.length {
          if args[j] != null && isErrorVal(args[j]) {
            return { type: "Error", value: std.Error.raise("TypeMismatch", "attempt to pass error value as argument to " + methodName, args[j].value), propagate: false };
          };
          j = j + 1;
        };
        if args.length != 1 {
          return { type: "Error", value: std.Error.raise("ArityMismatch", "Arity mismatch: expected 1 arguments, got " + std.Number.toString(args.length), null), propagate: false };
        };
        let method = func.boundMethod;
        if method == "add" { func.boundArray[func.boundArray.length] = args[0]; return { type: "Null", value: null }; };
        let index = args[0];
        if isWrapped(index) { index = index.value; };
        func.boundArray.remove(index);
        { type: "Null", value: null };
      } else if ft == "Function" {
        // ---- user function ----
        // Unified parameter view: the curried record carries allParams/boundArgs (the full parameter
        // list and already-bound arguments captured at partial-application time); the final application
        // checks all arguments — consistent with the host's curried native re-entering the call path
        // with the full arguments when the application completes.
        // Note: plain records lack allParams/boundArgs; probing yields an error value (not null) — must normalize with isError first, or the error value would participate in comparisons (truthy) and loop forever.
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
            if argErr == null && allArgs[i] != null && isErrorVal(allArgs[i]) { argErr = allArgs[i]; }
            i = i + 1;
          }
          if argErr != null {
            let message = "attempt to pass error value as argument";
            if prevBound != null { message = message + " to <curried>"; };
            return { type: "Error", value: std.Error.raise("TypeMismatch", message, argErr.value), propagate: false };
          }
        }
        // Host partials are native functions with exact remaining arity.
        if prevBound != null && args.length != func.params.length {
          return { type: "Error", value: std.Error.raise("ArityMismatch", "Arity mismatch: expected " + std.Number.toString(func.params.length) + " arguments, got " + std.Number.toString(args.length), null), propagate: false };
        };
        if allArgs.length < allParams.length {
          // Partial application: matches the host — insufficient args return
          // a curried function. The host does not check annotations at partial-application time (all are checked at completion);
          // the record carries allParams/boundArgs/paramTypes for a unified check at the final application.
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
          { type: "Function", params: remaining, body: func.body, env: partialEnv, path: func.path, moduleExports: func.moduleExports, allParams: allParams, boundArgs: allArgs, paramTypes: func.paramTypes };
        } else if allArgs.length != allParams.length {
          // Too many arguments: host ArityMismatch error value (the boot's old behavior silently dropped excess arguments)
          { type: "Error", value: std.Error.raise("ArityMismatch", "Arity mismatch: expected " + std.Number.toString(allParams.length) + " arguments, got " + std.Number.toString(allArgs.length), null), propagate: false };
        } else {
          // Parameter annotation check (host order: after currying/arity, before the depth guard): on
          // failure → TypeCheck error value, the function body does not run.
          let p = 0;
          while p < allParams.length {
            let ann = func.paramTypes[p];
            if ann != null {
              let ck = checkValue(ann.ty, allArgs[p], env);
              if isErrorVal(ck) {
                // check itself errored → that error value is the call result (host Err(e) → Ok(e))
                return ck;
              }
              if !isTruthy(ck) {
                return { type: "Error", value: std.Error.raise("TypeCheck", "argument " + std.Number.toString(p + 1) + " does not match the annotated type \"" + ann.text + "\"", null), propagate: false };
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
            // Annotated binding (host define_annotated): parameters reassigned inside the function body are re-checked too
            let ann2 = func.paramTypes[i];
            if ann2 != null {
              localEnv._defineAnnotated(allParams[i].name, allArgs[i], { ty: ann2.ty, text: ann2.text });
            } else {
              localEnv._define(allParams[i].name, allArgs[i]);
            }
            i = i + 1;
          }
          depth = depth + 1;
          let callerPath = currentPath; currentPath = func.path;
          let callerExports = moduleExports; moduleExports = func.moduleExports;
          let result = runStatements(func.body.statements, localEnv);
          moduleExports = callerExports; currentPath = callerPath;
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
        // ---- hosting-runtime native or QLang function (stdlib.ql) ----
        // Distinguish by func.name: natives expose a name string, QLang
        // functions probe as an error value.
        // Host natives receive UNWRAPPED raw args (the native std expects raw
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
        if !isDiag && (isNative || !exemptErrorArgs) {
          let j = 0;
          while j < args.length {
            if args[j] != null && isErrorVal(args[j]) {
              let nativeName = if func.name == null || isError(func.name) { "?" } else { func.name };
              return { type: "Error", value: std.Error.raise("TypeMismatch", "attempt to pass error value as argument to " + nativeName, args[j].value), propagate: false };
            }
            j = j + 1;
          }
        }
        // The host QLang functions exposed by the boot stdlib are unary
        // native bridges (type predicates/constructors and helper methods),
        // not user functions eligible for implicit partial application.
        if !isNative && Function.check(func) && args.length != 1 {
          return { type: "Error", value: std.Error.raise("ArityMismatch", "Arity mismatch: expected 1 arguments, got " + std.Number.toString(args.length), null), propagate: false };
        };
        // Interpreted functions are Object-shaped records in the host. They
        // must not pass Object API validation merely because of that encoding.
        // Preserve dispatch order: check this only at the target's exact arity.
        if isNative {
          let name = func.name;
          let objectUnary = name == "Object.keys" || name == "Object.values" || name == "Object.merge" || name == "Object.merge<curried>" || name == "Object.hasOwn" || name == "Object.get";
          if (objectUnary && args.length == 1) || (name == "Object.field" && args.length == 2) {
            if isWrapped(args[0]) && args[0].type == "Function" {
              return { type: "Error", value: std.Error.raise("TypeMismatch", name + " expects Object", null), propagate: false };
            };
          };
        };
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
          } else if tag == null {
            // Raw host value (probe of .type errored — a real wrapper always
            // yields a tag string): pass it through UNCHANGED. It is already
            // raw, so a.value would error (no accessible .value on a raw host
            // value). This happens when a host-native result reaches the args,
            // e.g. Object.keys({a:1,b:2})[0] (the boot's array indexing returns
            // the raw host element) fed to std.String.toString.
            rawArgs[rawArgs.length] = a;
          } else if isNative && tag != "Object" && tag != "Function" && tag != "Type" {
            rawArgs[rawArgs.length] = a.value;
          } else if isNative && tag == "Object" {
            // Host natives expect raw field tables, never the boot's Object
            // wrapper ({type:"Object", value: fields}). Unwrap regardless of
            // which native it is: restricting to a name family missed curried
            // natives (their names carry a "<curried>" suffix, e.g.
            // "Object.merge<curried>"), so the second application of a curried
            // merge received the envelope and merged its {type, value} keys.
            // Boot object literals evaluate to the wrapper view {type:"Object", value: fields}
            // (interpreter.ql:468); without this unwrap, host Object natives receive the ENVELOPE
            // (itself a host Value::Object with exactly {type, value}) and return ["type","value"].
            // Boot QLang functions (stdlib.ql) probe func.name as an error, so isNative is false
            // for them and they still receive the wrapper (e.g. __objectEntries).
            rawArgs[rawArgs.length] = a.value;
          } else {
            rawArgs[rawArgs.length] = a;
          }
          i = i + 1;
        }
        // Keep arguments positional at every arity. The hosting runtime's
        // ordinary dispatcher owns arity, Error policy and partial metadata.
        // QLang type-library helpers have already passed the unary bridge check.
        let raw = std.__callNative(func, rawArgs);
        // These projections return a value already stored inside an interpreted
        // Object. Preserve its wrapper (and function/Error identity) exactly.
        if isNative && (func.name == "Object.get<curried>" || func == std.Object.field) && !isError(raw) && isWrapped(raw) {
          return raw;
        };
        // Note: the isError check must come BEFORE `raw == null` — comparing
        // an error operand with == yields an error value, which is truthy and
        // would wrongly take the null branch.
        if isError(raw) {
          // Error results get the dedicated wrapper
          { type: "Error", value: raw, propagate: false };
        } else if raw == null {
          { type: "Null", value: null };
        } else if isNative && func.name == "JSON.parse" {
          wrapJSON(raw);
        } else {
          // Wrapper tag is the STRING type name from typeTag (stdlib.ql);
          // std.Type.of now returns type VALUES, which cannot serve as tags
          let tag = typeTag(raw);
          if tag == "Function" {
            // Host function result (e.g. Object.merge(x) returns a curried
            // native): return it RAW so a later call re-enters the native
            // branch. Wrapping it as {type:"Function", value: native} would
            // mis-dispatch the next call into the user-function record branch
            // (which probes params/body on the raw native and hangs).
            raw;
          } else {
            { type: tag, value: raw };
          };
        };
      } else {
        // Other wrapped types are not callable
        { type: "Error", value: std.Error.raise("NotCallable", "Not callable: " + ft, null), propagate: false };
      }
    } else {
      { type: "Null", value: null };
    }
  };

  // std.__bootCall: lets the stdlib.ql type-library closures (arrayCheck/Object check closures) call
  // boot user-function records — records can only execute through this call path (a host closure
  // calling a record directly gets NotCallable); the element/field checks of composite type checks
  // (Array(Positive)/Object({n: Positive})) are bridged here. Mounted on the host std object like
  // std.Object.entries; re-injected on every Interpreter() call (the last interpreter wins, consistent with the running checks).
  std.__bootCall = (f, v) -> callFunctionInner(f, [v], globalEnv, true);

  if !isError(nativeHost) {
    nativeBridge = NativeValues(nativeHost, nativeTypes, (func, args, exempt) -> callFunctionInner(func, args, globalEnv, exempt));
  };

  if libraryProgram == null { libraryProgram = parseStandardLibrary(); };
  if isError(libraryProgram) {
    libraryInitError = { type: "Error", value: libraryProgram, propagate: true };
  } else {
    if libraryExports == null {
      let privateEnv = Environment(null);
      privateEnv._define("Number", Number); privateEnv._define("String", String);
      privateEnv._define("Boolean", Boolean); privateEnv._define("Null", Null);
      privateEnv._define("AnyArray", AnyArray); privateEnv._define("AnyObject", AnyObject); privateEnv._define("isError", isError);
      // Separate tables from userStd: user writes cannot replace library helpers.
      let base = {}; let names = std.Object.keys(std); let i = 0;
      while i < names.length {
        let name = names[i]; let value = std[name];
        if name != "Type" && typeTag(value) == "Object" {
          let copy = {}; let keys = std.Object.keys(value); let j = 0;
          while j < keys.length { copy[keys[j]] = value[keys[j]]; j = j + 1; };
          value = copy;
        };
        base[name] = value; i = i + 1;
      };
      let savedPath = currentPath; currentPath = "<standard-library>";
      let factory = evaluate(libraryProgram.statements[0].value, privateEnv);
      let result = callFunction(factory, [base], privateEnv);
      currentPath = savedPath;
      if isErrorVal(result) { libraryInitError = result; }
      else { libraryExports = result; };
    };
    if libraryExports != null {
      let modules = libraryExports.value; let names = std.Object.keys(modules); let i = 0;
      while i < names.length {
        let name = names[i]; let fields = modules[name].value;
        let target = userStd[name];
        if isError(target) { target = {}; userStd[name] = target; };
        let keys = std.Object.keys(fields); let j = 0;
        while j < keys.length { target[keys[j]] = fields[keys[j]]; j = j + 1; };
        i = i + 1;
      };
    };
  };

  { runProgram: runProgram, evaluate: evaluate, globalEnv: globalEnv, setModuleContext: setModuleContext, setArguments: setArguments, _shareArguments: shareArguments, _shareNativeBridge: (bridge) -> { nativeBridge = bridge; }, getExports: () -> moduleExports };
};

export Interpreter;
