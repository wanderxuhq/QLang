// QLang type gymnastics demo.
// Exercises the runtime type system ("types as data") as hard as QLang can
// take it: combinators, dependent types, deep recursive constructors,
// function signature types, type-of-type, nested schema validation, and
// error-value integration. Verified by running this file through BOTH the
// host interpreter and the bootstrapped interpreter and diffing the output:
//
//   cargo run -- demo/type_gymnastics.ql            > /tmp/tg_host.out
//   cargo run -- bootstrapped/run_file.ql demo/type_gymnastics.ql > /tmp/tg_boot.out
//   diff /tmp/tg_host.out /tmp/tg_boot.out   # must be empty
//
// If any construct cannot run on either interpreter, that is a QLang bug:
// the fix goes into the host src/ or bootstrapped/*.ql, not a cut to the
// gymnastics. Each chapter ends with a PASS count; the final line is a
// summary.

// ---------- harness ----------
let cnt = 0;      // total asserts run in the current chapter
let passed = 0;   // asserts that passed in the current chapter
let gtotal = 0;   // cumulative asserts across all chapters (for the final line)
let gpassed = 0;
let assert = (name, cond) -> {
  if cond { passed = passed + 1; gpassed = gpassed + 1; } else { println("  FAIL " + name); };
  cnt = cnt + 1;
  gtotal = gtotal + 1;
};
let chapterStart = (n, name) -> {
  cnt = 0;
  passed = 0;
  println("=== Chapter " + std.Number.toString(n) + ": " + name + " ===");
};
let chapterEnd = (n) -> {
  println("  " + std.Number.toString(passed) + "/" + std.Number.toString(cnt) + " PASS");
};
let show = (label, v) -> println(label + std.Number.toString(v));

// ---------- Chapter 1: combinator library ----------
chapterStart(1, "Combinator library");

// --- predicate combinators (operate directly on type values) ---
let Union = (A, B) -> std.Type.make((v) -> A.check(v) || B.check(v));
let Intersection = (A, B) -> std.Type.make((v) -> A.check(v) && B.check(v));
let Nullable = (T) -> Union(T, Null);
let Optional = (T) -> Union(T, Null); // accepts null or T (undefined is an uninitialized error value, out of scope)

// --- structural combinators (operate on schema descriptors) ---
let Record = (schema) -> Object(schema);
let Pick = (desc, keys) -> {
  let out = {};
  let i = 0;
  while i < keys.length {
    let k = keys[i];
    out[k] = desc[k];
    i = i + 1;
  };
  Object(out);
};
let Partial = (desc) -> {
  let ks = std.Object.keys(desc);
  // key-predicate form: every PRESENT field must pass its type; missing
  // fields are allowed (that is what makes it partial). A shape form would
  // require all fields, so this must use Object((obj) -> bool).
  Object((obj) -> {
    let ok = true;
    let i = 0;
    while i < ks.length && ok {
      let k = ks[i];
      let v = obj[k];
      if !isError(v) {
        let r = desc[k].check(v);
        if r == null || r == false || isError(r) { ok = false; };
      };
      i = i + 1;
    };
    ok;
  });
};
let NamedArray = (desc) -> Array({ length: desc.length, element: desc.element });

// --- key-dependent type (Object((obj) -> bool), spec §3) ---
let has = (o, k) -> !isError(o[k]);
let KeyDependent = (rule) -> Object(rule); // rule is (obj) -> bool
// Example rule: if `a` is present then `b` must be; otherwise `c` must be.
let aNeedsBElseC = (o) -> {
  if has(o, "a") {
    if has(o, "b") { true; } else { false; };
  } else {
    has(o, "c");
  };
};
let AorBC = KeyDependent(aNeedsBElseC);

// --- verify ---
assert("union num-or-str: 42", Union(Number, String).check(42));
assert("union num-or-str: 'hi'", Union(Number, String).check("hi"));
assert("union num-or-str: false", !Union(Number, String).check(false));
assert("intersect num+positive", Intersection(Number, std.Type.make((v) -> v > 0)).check(5));
assert("intersect num+positive: neg", !Intersection(Number, std.Type.make((v) -> v > 0)).check(-1));
assert("nullable null", Nullable(Number).check(null));
assert("nullable num", Nullable(Number).check(3));
assert("nullable str: false", !Nullable(Number).check("s"));
assert("optional null", Optional(String).check(null));
assert("optional str", Optional(String).check("x"));

let Rec = Record({ a: Number, b: String });
assert("record good", Rec.check({ a: 1, b: "x" }));
assert("record missing b", !Rec.check({ a: 1 }));
assert("record extra ok", Rec.check({ a: 1, b: "x", c: true }));
let Picked = Pick({ a: Number, b: String, c: Boolean }, ["a", "c"]);
assert("pick a,c good", Picked.check({ a: 1, c: true }));
assert("pick a,c missing c", !Picked.check({ a: 1 }));
let Part = Partial({ a: Number, b: String });
assert("partial all present", Part.check({ a: 1, b: "x" }));
assert("partial a only", Part.check({ a: 1 }));
assert("partial empty", Part.check({}));
assert("partial bad type", !Part.check({ a: "s", b: "x" }));
let NA = NamedArray({ length: 3, element: Number });
assert("named-array good", NA.check([1, 2, 3]));
assert("named-array short", !NA.check([1, 2]));
assert("named-array bad elem", !NA.check([1, "a", 3]));

assert("key-dependent {a,b}", AorBC.check({ a: 1, b: 2 }));
assert("key-dependent {c}", AorBC.check({ c: 9 }));
assert("key-dependent {a} only", !AorBC.check({ a: 1 }));
assert("key-dependent empty", !AorBC.check({}));
chapterEnd(1);
chapterStart(2, "Dependent types");

// type constructors are functions: the type depends on runtime values
let Vect = (n, T) -> std.Type.make((v) -> {
  if std.Type.of(v) != AnyArray { false; } else {
    if v.length != n { false; } else {
      let ok = true;
      let i = 0;
      while i < v.length {
        if !T.check(v[i]) { ok = false; };
        i = i + 1;
      };
      ok;
    };
  };
});
let Matrix = (r, c, T) -> Vect(r, Vect(c, T));
let TupleOf = (ts) -> Array(ts);
let Shape = (v) -> {
  let tv = std.Type.of(v);
  if tv == Number || tv == String || tv == Boolean {
    tv;
  } else {
    if tv == Null {
      Null;
    } else {
      if tv == AnyArray {
        if v.length == 0 { AnyArray; } else { Array({ length: v.length, element: Shape(v[0]) }); };
      } else {
        if tv == AnyObject {
          let out = {};
          let ks = std.Object.keys(v);
          let i = 0;
          while i < ks.length {
            let k = ks[i];
            out[k] = Shape(v[k]);
            i = i + 1;
          };
          out;
        } else {
          Any;
        };
      };
    };
  };
};

assert("vect 3 num good", Vect(3, Number).check([1, 2, 3]));
assert("vect 3 num short", !Vect(3, Number).check([1, 2]));
assert("vect 3 num bad elem", !Vect(3, Number).check([1, "a", 3]));
let M = Matrix(2, 3, Number);
assert("matrix 2x3 good", M.check([[1, 2, 3], [4, 5, 6]]));
assert("matrix 2x3 bad row", !M.check([[1, 2, 3], [4, 5]]));
assert("tuple good", TupleOf([Number, String]).check([1, "a"]));
assert("tuple wrong len", !TupleOf([Number, String]).check([1, "a", true]));
let sh = Shape([1, 2, 3]);
assert("shape of [1,2,3] is vect3num", sh.check([1, 2, 3]));
assert("shape of [1,2,3] rejects [1,2]", !sh.check([1, 2]));
let sho = Shape({ x: 1, y: "s" });
let ShoType = Record(sho);
assert("shape obj good", ShoType.check({ x: 1, y: "s" }));
assert("shape obj bad y", !ShoType.check({ x: 1, y: 2 }));

chapterEnd(2);

chapterStart(3, "Complex nested schema validation");

// schema: a descriptor mixing scalars, dependent types, and nesting
let ServerConfig = Record({
  port: Number,
  host: String,
  vector: Vect(3, Number),
  matrix: Matrix(2, 2, Number),
  routes: Array(Record({ path: String, method: String })),
  middleware: Optional(String)
});

let goodCfg = {
  port: 8080, host: "localhost",
  vector: [1, 2, 3], matrix: [[1, 2], [3, 4]],
  routes: [{ path: "/api", method: "GET" }],
  middleware: "auth"
};
let badPort = { port: "x", host: "localhost", vector: [1, 2, 3], matrix: [[1, 2], [3, 4]], routes: [], middleware: "auth" };
let badVect = { port: 8080, host: "localhost", vector: [1, 2], matrix: [[1, 2], [3, 4]], routes: [], middleware: "auth" };
let badRoute = { port: 8080, host: "localhost", vector: [1, 2, 3], matrix: [[1, 2], [3, 4]], routes: [{ path: "/api", method: 42 }], middleware: "auth" };
let badMissing = { port: 8080, vector: [1, 2, 3], matrix: [[1, 2], [3, 4]], routes: [] };

assert("cfg good", ServerConfig.check(goodCfg));
assert("cfg bad port", !ServerConfig.check(badPort));
assert("cfg bad vector", !ServerConfig.check(badVect));
assert("cfg bad route", !ServerConfig.check(badRoute));
assert("cfg missing host", !ServerConfig.check(badMissing));

// describe: render a descriptor to a readable string (recursive, stable order)
let describe = (d) -> {
  let tv = std.Type.of(d);
  if tv == Number || tv == String || tv == Boolean { "scalar"; }
  else if tv == Null { "null"; }
  else if tv == AnyArray {
    if d.length == 0 { "[]"; } else {
      "[" + describe(d[0]) + " x" + std.Number.toString(d.length) + "]";
    };
  } else if tv == AnyObject {
    let ks = std.Object.keys(d);
    let parts = [];
    let i = 0;
    while i < ks.length {
      let fv = d[ks[i]];
      if isError(fv) {
        parts[parts.length] = ks[i] + ":?";
      } else {
        parts[parts.length] = ks[i] + ":" + describe(fv);
      };
      i = i + 1;
    };
    let s = "{";
    i = 0;
    while i < parts.length { if i > 0 { s = s + ", "; }; s = s + parts[i]; i = i + 1; };
    s + "}";
  } else { "?"; };
};

// showcase describe on concrete values (recursive, stable order)
println("  goodCfg -> " + describe(goodCfg));
println("  vector  -> " + describe(goodCfg["vector"]));
println("  routes  -> " + describe(goodCfg["routes"]));
println("  []      -> " + describe([]));
println("  null    -> " + describe(null));
println("  text    -> " + describe("text"));

// Shape: derive a per-field schema from a concrete value
let cfgShape = Shape(goodCfg);
println("  cfgShape.routes is error value: " + std.Number.toString(isError(cfgShape["routes"])));
assert("shape.port accepts int", cfgShape["port"].check(8080));
assert("shape.port rejects str", !cfgShape["port"].check("x"));
assert("shape.host accepts str", cfgShape["host"].check("localhost"));
assert("shape.vector matches [1,2,3]", cfgShape["vector"].check([1, 2, 3]));
assert("shape.vector rejects [1,2]", !cfgShape["vector"].check([1, 2]));
assert("shape.matrix matches 2x2", cfgShape["matrix"].check([[1, 2], [3, 4]]));
assert("shape.matrix rejects [[1],[2]]", !cfgShape["matrix"].check([[1], [2]]));
assert("shape.middleware accepts str", cfgShape["middleware"].check("auth"));
assert("shape.middleware rejects num", !cfgShape["middleware"].check(42));

// object arrays: Shape(goodCfg) cannot fold a plain object descriptor into
// an Array element (Array requires a compiled element type), so cfgShape's
// routes field is an error value (seen above). Derive the element schema
// from the first concrete element instead, then build the array type.
let route0 = goodCfg["routes"][0];            // {path:"/api", method:"GET"}
let routeElemDesc = Shape(route0);            // {path: String, method: String}
let RouteType = Record(routeElemDesc);
let RouteArray = Array(RouteType);
assert("route array good", RouteArray.check([{ path: "/a", method: "GET" }]));
assert("route array empty ok", RouteArray.check([]));
assert("route array bad method", !RouteArray.check([{ path: "/a", method: 42 }]));
assert("route array missing path", !RouteArray.check([{ method: "GET" }]));

chapterEnd(3);

chapterStart(4, "Error-value integration");

// validate: a failed check becomes an error value naming the failing field
let validateField = (T, field, v) -> {
  if T.check(v) { v; } else { std.Error.raise("TypeMismatch", "field '" + field + "' failed its check", null); };
};

let ok = validateField(Record({ a: Number }), "a", { a: 1 });
assert("validated good is not error", !isError(ok));
let bad = validateField(Record({ a: Number }), "a", { a: "s" });
assert("validated bad is error", isError(bad));
assert("error kind is TypeMismatch", bad.type == "TypeMismatch");
assert("error names the field", bad.message == "field 'a' failed its check");

// ? propagation: an error produced INSIDE a function aborts it and is returned
let needsNum = (x) -> {
  let v = validateField(Number, "x", x) ?;
  "unreached";
};
let r = needsNum("nope");
assert("? propagates error", isError(r));
assert("? preserved kind", r.type == "TypeMismatch");
assert("? preserved message", r.message == "field 'x' failed its check");
let r2 = needsNum(7);
assert("? lets good values through", r2 == "unreached");

chapterEnd(4);

chapterStart(5, "Combination storm (deep water)");

// --- deep water 1: recursive type constructors ---
let DeepArray = (depth, T) -> {
  if depth == 0 { T; } else { Array(DeepArray(depth - 1, T)); };
};
let buildDeep = (depth, v) -> {
  if depth == 0 { v; } else { [buildDeep(depth - 1, v)]; };
};
let D6 = DeepArray(6, Number);
assert("deep6 good", D6.check(buildDeep(6, 1)));
assert("deep6 too shallow", !D6.check(buildDeep(5, 1)));
assert("deep6 bad leaf", !D6.check(buildDeep(6, "s")));

// --- deep water 2: function signature types (probe-call the function) ---
let fnProbe = (T) -> {
  if T == Number { 0; } else {
    if T == String { ""; } else {
      if T == Boolean { false; } else { null; };
    };
  };
};
let Fn = (ArgT, RetT) -> std.Type.make((f) -> {
  if std.Type.of(f) != Function { false; } else {
    let r = f(fnProbe(ArgT));
    if isError(r) { false; } else { std.Type.of(r) == RetT; };
  };
});
let Fn2 = (A1, A2, RetT) -> std.Type.make((f) -> {
  if std.Type.of(f) != Function { false; } else {
    let r = f(fnProbe(A1), fnProbe(A2));
    if isError(r) { false; } else { std.Type.of(r) == RetT; };
  };
});
let NumToNum = Fn(Number, Number);
assert("n2n good", NumToNum.check((x) -> x * 2));
assert("n2n bad ret", !NumToNum.check((x) -> "s"));
let StrToNum = Fn(String, Number);
assert("s2n good", StrToNum.check((s) -> s.length));
let Add2 = Fn2(Number, Number, Number);
assert("add2 good", Add2.check((a, b) -> a + b));

// --- deep water 3: type-of-type + exactType ---
let typeSelf = std.Type.of(std.Type) == std.Type;
assert("Type:Type", typeSelf);
let anyTypeVal = std.Type.of(Number) == std.Type;
assert("Number's type is Type", anyTypeVal);
let exactType = (T) -> std.Type.make((v) -> v == T);
let NumOnly = exactType(Number);
assert("exactType(Number) rejects 42", !NumOnly.check(42));
assert("exactType(Number) accepts Number", NumOnly.check(Number));
assert("exactType(Number) rejects String", !NumOnly.check(String));

// --- deep water 4: type values as data ---
let types = [Number, String, Null];
let i = 0;
while i < types.length {
  assert("type-as-data elem " + std.Number.toString(i), std.Type.of(types[i]) == std.Type);
  i = i + 1;
};

// --- the combination storm ---
let UserDesc = Shape({ id: 1, name: "a", tags: ["x", "y"] });
let UpdateUser = Partial(UserDesc);
let UserSummary = Pick(UserDesc, ["id", "name"]);
assert("updateUser good", UpdateUser.check({ id: 1 }));
assert("updateUser empty ok", UpdateUser.check({}));
assert("userSummary good", UserSummary.check({ id: 1, name: "a" }));
assert("userSummary extra ok", UserSummary.check({ id: 1, name: "a", tags: ["x"] }));
assert("userSummary missing name", !UserSummary.check({ id: 1 }));

let AuditLog = Record({ user: UpdateUser, ts: Number, meta: NamedArray({ length: 2, element: UserSummary }) });
let goodLog = { user: { id: 1 }, ts: 123, meta: [{ id: 1, name: "a" }, { id: 2, name: "b" }] };
assert("audit good", AuditLog.check(goodLog));
let badLog = { user: { id: 1 }, ts: 123, meta: [{ id: 1, name: "a" }] };
assert("audit short meta", !AuditLog.check(badLog));

let OptVect = Optional(Vect(3, Number));
assert("optVect null", OptVect.check(null));
assert("optVect array", OptVect.check([1, 2, 3]));
assert("optVect bad", !OptVect.check([1, 2]));
assert("optVect bad type", !OptVect.check("x"));

let validatedLog = validateField(AuditLog, "log", goodLog);
assert("validated log good", !isError(validatedLog));
let chainErr = () -> {
  let v = validateField(AuditLog, "log", badLog) ?;
  "unreached";
};
let r2 = chainErr();
assert("chain error", isError(r2));
assert("chain error kind", r2.type == "TypeMismatch");
assert("chain error names field", r2.message == "field 'log' failed its check");

let DeepOpt = Optional(DeepArray(4, Number));
assert("deepOpt null", DeepOpt.check(null));
assert("deepOpt good", DeepOpt.check(buildDeep(4, 1)));
assert("deepOpt bad", !DeepOpt.check(buildDeep(3, 1)));

chapterEnd(5);


// final summary (cumulative across all chapters)
println("RESULT: " + std.Number.toString(gpassed) + "/" + std.Number.toString(gtotal) + " asserts passed");

