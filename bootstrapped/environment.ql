// Environment for QLang - Manages variable scope
// Bootstrapped QLang implementation - Standalone version (no std dependency)

let Environment = (parent) -> {
  let values = {};
  // Task 11: annotation map (name → { ty: type value, text: annotation text }). _assign keeps the
  // annotation (anns persists by name; assignment only writes values) — consistent with the host
  // Binding.annotation's "reassignment keeps the annotation" semantics.
  let anns = {};

  // Task: three-state bindings — values holds bound values (a key's existence means "has a value",
  // including explicit null); uninit records uninitialized declarations (key exists = uninitialized). Undefined = in neither set and absent from the parent chain.
  let uninit = {};
  let doDefine = (name, value) -> { values[name] = value; };
  let doDefineUninit = (name, ann) -> {
    uninit[name] = true;
    if ann != null { anns[name] = ann; };
  };

  // Simple object access without std
  let doDefine = (name, value) -> { values[name] = value; };
  // Task 11: annotated binding (corresponds to the host's define_annotated). ann has the shape { ty, text }.
  let doDefineAnnotated = (name, value, ann) -> {
    values[name] = value;
    anns[name] = ann;
  };
  // Task 11: look up the annotation along the parent chain (corresponds to the host's get_annotation); none → null.
  let doGetAnnotation = (name) -> {
    // Probing a missing key yields an error value (error-as-value); the isError guard is required (same as doGet)
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
    // Key exists (including explicit null) → return that value, do not fall through (fix: the old
    // v != null condition made `let x = null` fall through to the outer scope).
    let v = values[name];
    if !isError(v) { v; }
    // Note: probing a missing key yields an error value (error-as-value); must guard with isError before comparing to null
    // (unguarded, `uninit[name] != null` hands the error value to != → delegates to the host to construct a new error).
    else if !isError(uninit[name]) && uninit[name] != null {
      // Declared but not initialized
      { type: "Error", value: std.Error.raise("Uninitialized", "variable \"" + name + "\" is declared but not initialized", null), propagate: false };
    }
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
    else {
      // Undefined: error value (no longer falls back to null — aligned with the host's
      // UndefinedVariable). Use std.Error.raise (3 args: kind/message/cause); the bare Error.raise
      // is the type object's 1-2-arg constructor (kind hardcoded to "Error"), which would drop kind/message.
      { type: "Error", value: std.Error.raise("UndefinedVariable", "Undefined variable: " + name, null), propagate: false };
    }
  };
  let doAssign = (name, value) -> {
    let v = values[name];
    if !isError(v) {
      values[name] = value;
      true;
    } else if !isError(uninit[name]) && uninit[name] != null {
      // First assignment = initialization: set the value and clear the uninitialized marker
      values[name] = value;
      uninit[name] = null;
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

  { _define: doDefine, _get: doGet, _assign: doAssign, _defineAnnotated: doDefineAnnotated, _getAnnotation: doGetAnnotation, _defineUninit: doDefineUninit, _values: values };
};

let GlobalEnvironment = (stdObj) -> {
  let parentEnv = {
    // ⑧ boundary fix: unknown name → UndefinedVariable error value (no longer falls back to null);
    // std is returned as-is.
    get: (name) -> if name == "std" { stdObj } else { { type: "Error", value: std.Error.raise("UndefinedVariable", "Undefined variable: " + name, null), propagate: false } },
    define: (name, value) -> null,
    assign: (name, value) -> null
  };
  Environment(parentEnv);
};

export { Environment, GlobalEnvironment };
