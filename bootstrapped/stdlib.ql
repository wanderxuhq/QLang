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

// Type-value predicate: an object with a callable check member. Boot type constants are {check: <function>}
// objects (same for std.Type.make results); a boot user function is a {type: "Function", ...} record,
// whose .type probes as "Function" when used as a check member. Plain objects (check not a function) are rejected.
// Third item: the call path (interpreter.ql) wraps the return values of host QLang functions (Type.make/Array/Object/
// std.Type.of) in a {type:"Object"|"Type", value: <type value>} wrapper — that wrapper form
// is likewise a type value (unwrap to test the inner value). Note: expressions must not span lines (the host parser
// ends statements at newlines); .check/.type probes on bare values are error values, and error == "X" is also an error value
// (truthy), so a !isError guard is required before any comparison (same as the constructor dispatch guards).
let isTypeValue = (v) -> v != null && (__hostTypeOf(v.check) == __hostFunction || (!isError(v.check) && !isError(v.check.type) && v.check.type == "Function") || (!isError(v.type) && (v.type == "Object" || v.type == "Type") && isTypeValue(v.value)));

// Type-value unwrap: call-product wrappers ({type:"Object"|"Type", value: <type value>}) yield the inner
// type value; all other values (bare type-value constants/plain wrappers/raw values) return as-is. Only the wrapper form is unwrapped — when the inner
// value is not a type value (e.g. a plain object literal), it is left as-is and the caller continues handling it per the original predicate.
let unwrapTypeValue = (v) -> {
  if v != null && !isError(v.type) && (v.type == "Object" || v.type == "Type") && isTypeValue(v.value) {
    v.value;
  } else {
    v;
  };
};

// Invoke a type check function (a host QLang function or a boot user function record). Host functions are called
// directly (the existing t10/t11 path); boot records can only execute via the boot call path — bridged through std.__bootCall
// (injected by interpreter.ql, the closure captures this process's callFunctionInner), and the boot
// wrapper result is reduced back to a bare value (Boolean/Null/Error unwrapped, other forms returned as-is).
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

// 9 type constants + the Error type object. Predicates are based on the boot value wrapper {type, value} (null has no
// wrapper): the call path (interpreter.ql) passes wrapped values to host QLang functions and bare values to host natives,
// and null is always passed bare. check handles error-value arguments the same as the host (host predicates accepts_errors: true,
// returning false/true rather than erroring): .type probes on bare values/error values are error values, so guard
// with !isError before comparing.
let Number   = { check: (v) -> v != null && !isError(v.type) && v.type == "Number" };
let String   = { check: (v) -> v != null && !isError(v.type) && v.type == "String" };
let Boolean  = { check: (v) -> v != null && !isError(v.type) && v.type == "Boolean" };
let Null     = { check: (v) -> v == null };
let AnyArray = { check: (v) -> v != null && !isError(v.type) && v.type == "Array" };
let AnyObject= { check: (v) -> v != null && !isError(v.type) && v.type == "Object" && !isTypeValue(v) };
// Boot function records carry the wrapper tag "Function" (uppercase; brief's "function"/"native" are also
// tolerated); bare native functions have no type field under host probing (the variant noted in the brief) — hence the host-probe
// branch: bare host functions (native and QLang, e.g. print) are Function under the host Type.of.
let Function = { check: (v) -> v != null && ((!isError(v.type) && (v.type == "Function" || v.type == "function" || v.type == "native")) || __hostTypeOf(v) == __hostFunction) };
let Any      = { check: (v) -> true };
let Never    = { check: (v) -> false };
// Error type object: raise reuses the host Error type object's native constructor (arity is variable,
// both (msg) and (msg, cause) work; boot QLang functions cannot express optional parameters, and partial application
// would turn a 1-arg call into a curried function, so the native is attached directly).
let Error    = { check: (v) -> v != null && !isError(v.type) && v.type == "Error",
                 raise: Error.raise };

// The merged Type module (module and type value in one): check / of / make. of returns this module's same-source
// constants (safe to compare among themselves). The dispatch chain likewise needs the !isError(v.type) guard; bare host values (no type
// field, e.g. the std module/JSON.parse results) are classified by the captured host Type.of, matching the host.
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
  // Aligned with the host: make's argument must be a function (host QLang function/native/boot function record),
  // otherwise a TypeMismatch error value (host message "Type.make: expected a function").
  make: (f) -> {
    if f != null && (__hostTypeOf(f) == __hostFunction || (!isError(f.type) && f.type == "Function")) { return { check: f }; }
    else { std.Error.raise("TypeMismatch", "Type.make: expected a function", null); };
  },
};

// entries for boot object wrappers (the host's std.Object has no entries): obj is
// {type:"Object", value: field table}, returns [[key, value], ...] (value is the field value).
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

// Element-wise checking skeleton (note: boot's stdlib has no forEach, so while is used). Element checks go through
// callCheck: host functions are called directly, user types (whose check is a boot record) go through __bootCall.
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

// Array constructor: union argument (Number | Type | [Type] | {length, element})
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
  // Note: .type probes on bare values (e.g. type constants) are error values, and error == "X" is also an error value
  // (truthy) — !isError(x.type) must come first, then compare the tag, otherwise bare constants wrongly enter the fixed-length branch.
  if x != null && !isError(x.type) && x.type == "Number" {
    if x.value >= 0 && x.value % 1 == 0 {
      Type.make(arrayCheck({ length: x.value, element: null, tuple: null }));
    }
    else {
      // Aligned with the host: negative/non-integer lengths raise a dedicated message (host "Array: length must be a
      // non-negative integer") rather than falling into the generic else.
      std.Error.raise("TypeMismatch", "Array: length must be a non-negative integer", null);
    };
  }
  else if isTypeValue(x) {
    // Type member: element type. x may be a call-product wrapper ({type:"Object"|"Type", value:
    // type value}, e.g. return values of std.Type.make/std.Type.of/nested constructor calls) — unwrap first, then
    // take check (a wrapper's check probe is an error value).
    Type.make(arrayCheck({ length: null, element: unwrapTypeValue(x).check, tuple: null }));
  }
  else if x != null && !isError(x.type) && x.type == "Array" {
    // [Type] member: per-position types (at construction, verify each element is a type; elements may likewise be call
    // product wrappers, so unwrap before judging/taking check)
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
    // {length, element} metadata member (element may be a call-product wrapper)
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

// Object constructor: union argument (Type | shape object)
let Object = (x) -> {
  if isTypeValue(x) {
    // Type member: all keys are T (Object(String) ≡ AnyObject). x may be a call-product
    // wrapper — unwrap, then take check; key checks go through callCheck (a user type's check is
    // a boot record, which host closures cannot call directly).
    let t = unwrapTypeValue(x);
    Type.make((v) -> {
      if v == null || v.type != "Object" || isTypeValue(v) { false; }
      else {
        // boot-wrapped objects: fields live in v.value; keys are bare strings, so wrap each as
        // {type:"String", value: key} before feeding it to the key check (checks receive wrapped values).
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
  else if Function.check(x) {
    // Predicate member: x is a function (o) -> bool — key-DEPENDENT object types
    // ("if a present then b must be present"). The check receives the boot wrapper
    // view v (field reads v.a and existence !isError(v.a) already work on the
    // wrapper; Object.keys(v) works after the interpreter's object-native unwrap).
    // Bound functions are RAW host values — .type probes as an error value (see
    // Function.check) — so Function.check(x) (not a .type probe) recognizes them;
    // callCheck bridges both raw host functions (called directly) and boot function
    // records (via std.__bootCall), mirroring the shape member's field checks.
    Type.make((v) -> v != null && v.type == "Object" && !isTypeValue(v) && callCheck(x, v) == true);
  }
  else if x != null && !isError(x.type) && x.type == "Object" && !isTypeValue(x) {
    // Shape object member: schema (at construction, verify all values are types; missing field/mismatched field → false).
    // Field values may be call-product wrappers, so unwrap before validating/using (the normalized schema is read by the check
    // closure; checks go through callCheck).
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
            ok = false; // missing field
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

// std.String.toChars: the host std.String lacks this method, but boot's lexer depends on it
// (turning source code into a character array). Keeps the old stdlib's augmentation approach (only fills in methods the host lacks).
// The body runs under HOST semantics, so it expects a RAW host String. The boot's own lexer
// passes a raw source string (host QLang, direct call) — but USER code calls it through
// callFunctionInner, which hands host QLang functions the boot WRAPPER {type:"String", value: raw}.
// Unwrap that wrapper first: raw strings probe as an error value on .type (guard keeps them), while
// the wrapper probes as "String" and yields its raw value. Without this, s.length on the wrapper is an
// error value (truthy), so the loop never terminates and the boot hangs.
let __toChars = (s) -> {
  let s2 = if s != null && !isError(s.type) && s.type == "String" { s.value; } else { s; };
  let parts = [];
  let i = 0;
  while i < s2.length {
    parts[parts.length] = s2[i];
    i = i + 1;
  }
  parts;
};
std.String.toChars = __toChars;

// Bare host value -> wrapped type name (string). host's std.Type.of now returns type values (objects),
// which cannot be used directly as wrapper tags; interpreter.ql's wrapping points use this function to get the string tag.
// Only bare values are handled (wrapped values are treated as objects); compared against the same-source __host* constants.
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

// Replace the host std.Type: user code's std.Type must be this module's merged Type (its of returns
// this module's same-source constants, safe for comparison within boot). The host native Type.of was captured above as
// __hostTypeOf.
std.Type = Type;

let fs = {
  readFileText: (path) -> "",
};

// Export the type library: interpreter.ql uses it to populate the boot global environment (Number/String/.../
// Array/Object/Type) and the wrapping points (typeTag); the host std object, after std.Type is replaced, is
// accessed by user code via std.Type.*.
export { std, isTypeValue, Number, String, Boolean, Null, AnyArray, AnyObject, Function, Any, Never, Error, Array, Object, Type, typeTag };
