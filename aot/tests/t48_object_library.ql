// Default installation, ordinary calls, dependencies, and type receivers.
let partialCases = () -> {
let originalKeys = std.Object.keys;
let algorithms = std.Object;
let checks = 0;
let check = (ok, label) -> {
  checks = checks + 1;
  if !ok { return std.Error.raise("AssertionFailed", label, null); };
  null;
};

let valuesPartial = algorithms.values();
check(valuesPartial({ item: 4 })[0] == 4, "values follows ordinary partial calls")?;
let mergePartial = algorithms.merge();
check(mergePartial({ left: 1 })({ right: 2 }).right == 2, "merge follows ordinary partial calls")?;
let hasOwnPartial = algorithms.hasOwn();
check(hasOwnPartial({ item: 3 })("item"), "hasOwn follows ordinary partial calls")?;
let getPartial = algorithms.get();
check(getPartial({ item: 5 })("item") == 5, "get follows ordinary partial calls")?;
let fieldPartial = algorithms.field();
check(fieldPartial({ item: 6 }, "item") == 6, "field follows ordinary partial calls")?;

// Rebinding the public namespace must not replace the injected enumerator.
std.Object.keys = (object) -> [];
check(algorithms.hasOwn({ captured: 1 })("captured"), "library retains its private enumerator")?;
std.Object.keys = originalKeys;

let changing = { before: 1 };
let projectedGet = algorithms.get(changing);
changing.after = 2;
check(projectedGet("after") == 2,
      "get sees fields added after creating its closure")?;
let projectedHasOwn = algorithms.hasOwn(changing);
changing.latest = 3;
check(projectedHasOwn("latest"),
      "hasOwn sees fields added after creating its closure")?;

let verifyCount = (actual) -> {
  if actual != 8 {
    return std.Error.raise("AssertionFailed", "expected 8 partial checks, got " + std.String.toString(actual), null);
  };
  null;
};
verifyCount(checks)?;
println("object algorithm partial checks: " + std.String.toString(checks));
};
partialCases()?;
let typeCases = () -> {
let algorithms = std.Object;
let checks = 0;
let check = (ok, label) -> {
  checks = checks + 1;
  if !ok { return std.Error.raise("AssertionFailed", label, null); };
  null;
};

check(algorithms.values(Number).length == 1, "accepts built-in type values")?;
let madeType = std.Type.make((value) -> value != null);
check(std.Type.check(madeType) && algorithms.values(madeType).length == 1,
      "accepts std.Type.make values")?;
let callableCheck = { check: (value) -> value != null };
check(std.Type.check(callableCheck) && algorithms.values(callableCheck).length == 1,
      "accepts literal objects with callable check fields")?;
check(algorithms.hasOwn(Number)("check"), "hasOwn sees built-in type fields")?;
let gotCheck = algorithms.get(Number)("check");
check(gotCheck(9), "get returns a callable built-in type field")?;
let strictCheck = algorithms.field(Number, "check");
check(strictCheck(9), "field returns a callable built-in type field")?;

let originalNumberCheck = Number.check;
let merged = algorithms.merge(Number)(std.Type.make((value) -> true));
merged.check = 42;
check(merged.check == 42 && algorithms.hasOwn(merged)("check") &&
      Number.check(9) && originalNumberCheck(9),
      "merge copies type values and mutation leaves Number.check unchanged")?;
check(algorithms.values((value) -> value).type == "TypeMismatch",
      "rejects function receivers")?;
check(algorithms.values([]).type == "TypeMismatch", "rejects Array receivers")?;

let verifyCount = (actual) -> {
  if actual != 9 {
    return std.Error.raise("AssertionFailed", "expected 9 type receiver checks, got " + std.String.toString(actual), null);
  };
  null;
};
verifyCount(checks)?;
println("object algorithm type receiver checks: " + std.String.toString(checks));
};
typeCases()?;
