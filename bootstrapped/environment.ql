// Environment for QLang - Manages variable scope
// Bootstrapped QLang implementation - Standalone version (no std dependency)

let Environment = (parent) -> {
  let values = {};
  // Task 11: annotation map (name → { ty: 类型值, text: 标注文本 })。_assign 保留
  // 标注(anns 按 name 持久,赋值只写 values)——与宿主 Binding.annotation 的
  // "重赋值保留标注" 语义一致。
  let anns = {};

  // Simple object access without std
  let doDefine = (name, value) -> { values[name] = value; };
  // Task 11: 带标注绑定(宿主 define_annotated 对应)。ann 形如 { ty, text }。
  let doDefineAnnotated = (name, value, ann) -> {
    values[name] = value;
    anns[name] = ann;
  };
  // Task 11: 沿父链查标注(宿主 get_annotation 对应);无 → null。
  let doGetAnnotation = (name) -> {
    // 缺失键探测是错误值(error-as-value),须 isError 守卫(同 doGet)
    let a = anns[name];
    if !isError(a) && a != null { a; }
    else if parent != null {
      let g1 = parent["_getAnnotation"];
      if !isError(g1) && g1 != null {
        g1(name);
      } else {
        null;
      };
    }
    else { null; }
  };
  let doGet = (name) -> {
    // Note: probing a missing key on a raw object now yields an UndefinedField
    // error VALUE (host error-as-value), never null; detect via isError (the
    // host native — cross-interpreter safe, unlike std.Type.of(x) == "Error"
    // which compares type values from different interpreter instances).
    let v = values[name];
    if !isError(v) && v != null { v }
    else if parent != null {
      // parent can be:
      // 1. A QL Environment object with _get method
      // 2. A QL Object with .get method (like parentEnv from GlobalEnvironment)
      // 3. A Rust NativeFunction (callable directly)
      let g1 = parent["_get"];
      if !isError(g1) && g1 != null {
        g1(name);
      } else {
        let g2 = parent["get"];
        if !isError(g2) && g2 != null {
          g2(name);
        } else {
          parent(name);
        };
      };
    }
    else { null }
  };
  let doAssign = (name, value) -> {
    if !isError(values[name]) && values[name] != null {
      values[name] = value;
      true;
    } else if parent != null {
      // Assignment to captured variables in closures: walk up the parent chain
      // (found by differential testing: the old local-only assign did not propagate,
      // closure counters stayed 0; the lexer worked only because it runs in the host)
      let a1 = parent["_assign"];
      if !isError(a1) && a1 != null {
        a1(name, value);
      } else {
        let a2 = parent["assign"];
        if !isError(a2) && a2 != null {
          a2(name, value);
        } else {
          false;
        };
      };
    } else {
      false;
    }
  };

  { _define: doDefine, _get: doGet, _assign: doAssign, _defineAnnotated: doDefineAnnotated, _getAnnotation: doGetAnnotation, _values: values };
};

let GlobalEnvironment = (stdObj) -> {
  let parentEnv = {
    get: (name) -> if name == "std" { stdObj } else { null },
    define: (name, value) -> null,
    assign: (name, value) -> null
  };
  Environment(parentEnv);
};

export { Environment, GlobalEnvironment };
