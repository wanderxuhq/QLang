// Environment for QLang - Manages variable scope
// Bootstrapped QLang implementation - Standalone version (no std dependency)

let Environment = (parent) -> {
  let values = {};

  // Simple object access without std
  let doDefine = (name, value) -> { values[name] = value; };
  let doGet = (name) -> {
    // Note: probing a missing key on a raw object now yields an UndefinedField
    // error VALUE (host error-as-value), never null; detect via std.Type.of
    let v = values[name];
    if std.Type.of(v) != "Error" && v != null { v }
    else if parent != null {
      // parent can be:
      // 1. A QL Environment object with _get method
      // 2. A QL Object with .get method (like parentEnv from GlobalEnvironment)
      // 3. A Rust NativeFunction (callable directly)
      let g1 = parent["_get"];
      if std.Type.of(g1) != "Error" && g1 != null {
        g1(name);
      } else {
        let g2 = parent["get"];
        if std.Type.of(g2) != "Error" && g2 != null {
          g2(name);
        } else {
          parent(name);
        };
      };
    }
    else { null }
  };
  let doAssign = (name, value) -> {
    if std.Type.of(values[name]) != "Error" && values[name] != null {
      values[name] = value;
      true;
    } else if parent != null {
      // Assignment to captured variables in closures: walk up the parent chain
      // (found by differential testing: the old local-only assign did not propagate,
      // closure counters stayed 0; the lexer worked only because it runs in the host)
      let a1 = parent["_assign"];
      if std.Type.of(a1) != "Error" && a1 != null {
        a1(name, value);
      } else {
        let a2 = parent["assign"];
        if std.Type.of(a2) != "Error" && a2 != null {
          a2(name, value);
        } else {
          false;
        };
      };
    } else {
      false;
    }
  };

  { _define: doDefine, _get: doGet, _assign: doAssign, _values: values };
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
