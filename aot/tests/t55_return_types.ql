// Declared return types: `(params): Type -> body`. Callers trust the declaration; the
// callee enforces it at its return edges (compile error where provable, runtime check
// otherwise). The `?` propagation path is exempt, like the native emitter's return edges.
let checks = 0;
let check = (ok, label) -> { checks = checks + 1; if !ok { println("FAIL " + label); }; };

// Every path provably returns the declared type -> no runtime check, value unchanged.
let addOne = (x: Number): Number -> x + 1;
check(addOne(1) == 2, "declared type matches");
let same = (x: String): String -> x;
check(same("a") == "a", "declared String");

// Underivable body type (unannotated parameter) -> runtime check at the return edge.
let identity = (x): Number -> x;
check(identity(3) == 3, "runtime check passes a Number");
let bad = identity("s");
check(bad.type == "TypeCheck", "runtime check rejects a String");
check(bad.message == "value of type \"String\" does not match the annotated type \"Number\"", "message");
// An Error argument is rejected at the call site before the body runs (Error-argument policy).
check(identity(Error.raise("x")).type == "TypeMismatch", "Error argument policy");

// Explicit returns that all agree with the declaration -> no runtime check.
let pick = (c: Boolean): Number -> { if c { return 1; }; return 2; };
check(pick(true) == 1, "explicit return 1");
check(pick(false) == 2, "explicit return 2");

// One return is underivable, so both edges are checked.
let underivable = (x): Number -> { if x { return x; }; 0; };
check(underivable(7) == 7, "underivable return passes");
check(underivable("s").type == "TypeCheck", "underivable return rejects");

println("return type checks: " + std.Number.toString(checks));
