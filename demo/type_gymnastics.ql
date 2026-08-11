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
