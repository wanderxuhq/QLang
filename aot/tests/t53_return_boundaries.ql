// Isolated boundary cases for return signals produced by if expressions.
// Error results are inspected only after isError; Error values never enter
// equality or the ordinary assertion helper.
let checks = 0;
let check = (ok, label) -> {
  checks = checks + 1;
  if !ok { return std.Error.raise("AssertionFailed", label, null); };
  null;
};

let falseCase = () -> {
  let value = if true { return false; } else { true; };
  99;
};
check(falseCase() == false, "return preserves false")?;

let nullCase = () -> {
  let value = if false { 1; } else { return null; };
  99;
};
check(nullCase() == null, "return preserves null")?;

let sharedObject = { value: 1 };
let objectCase = () -> {
  let value = if true { return sharedObject; } else { null; };
  99;
};
let objectResult = objectCase();
check(objectResult == sharedObject, "return preserves object identity")?;
objectResult.value = 7;
check(sharedObject.value == 7, "returned object remains aliased")?;

let sharedFunction = (value) -> value + 4;
let functionCase = () -> {
  let value = if true { return sharedFunction; } else { null; };
  99;
};
let functionResult = functionCase();
check(functionResult == sharedFunction, "return preserves function identity")?;
check(functionResult(3) == 7, "returned function remains callable")?;

let storedError = std.Error.raise("Stored", "preserve me", null);
let errorCase = () -> {
  let value = if true { return storedError; } else { null; };
  99;
};
let errorResult = errorCase();
check(isError(errorResult), "return stores Error as a value")?;
if isError(errorResult) {
  check(errorResult.type == "Stored", "returned Error public type")?;
  check(errorResult.message == "preserve me", "returned Error public message")?;
};

let returnKindError = std.Error.raise("Return", "ordinary Return error", null);
let returnKindCase = () -> {
  let value = if true { return returnKindError; } else { null; };
  99;
};
let returnKindResult = returnKindCase();
check(isError(returnKindResult), "Error kind Return remains an Error value")?;
if isError(returnKindResult) {
  check(returnKindResult.type == "Return", "Return-kind Error public type")?;
  check(returnKindResult.message == "ordinary Return error", "Return-kind Error public message")?;
};

let returnLookalike = { type: "Return", marker: { tag: "data" }, value: 17 };
let returnLookalikeCase = () -> {
  let value = if true { return returnLookalike; } else { null; };
  99;
};
let returnLookalikeResult = returnLookalikeCase();
check(returnLookalikeResult == returnLookalike, "Return-shaped object remains ordinary data")?;
check(returnLookalikeResult.type == "Return" && returnLookalikeResult.marker.tag == "data" &&
      returnLookalikeResult.value == 17, "Return-shaped object fields are preserved")?;

let nestedCount = 0;
let nestedCase = () -> {
  let child = () -> {
    if true { return 11; } else { 0; };
    90;
  };
  let childResult = child();
  nestedCount = nestedCount + 1;
  22;
};
check(nestedCase() == 22, "nested return does not exit caller")?;
check(nestedCount == 1, "caller continues after nested return")?;

let coalesceHits = 0;
let coalesceCase = () -> {
  let value = (if true { return storedError; } else { null; }) ?? 9;
  coalesceHits = coalesceHits + 1;
  99;
};
let coalesceResult = coalesceCase();
check(isError(coalesceResult) && coalesceResult.type == "Stored" &&
      coalesceResult.message == "preserve me", "coalesce does not consume returning Error")?;
check(coalesceHits == 0, "coalesce fallback is skipped by return")?;

let andHits = 0;
let andCase = () -> {
  let value = false && (if true { andHits = andHits + 1; return 31; } else { 31; });
  32;
};
check(andCase() == 32, "short-circuited and does not return")?;
check(andHits == 0, "short-circuited and branch is not evaluated")?;

let orHits = 0;
let orCase = () -> {
  let value = true || (if true { orHits = orHits + 1; return 41; } else { 41; });
  42;
};
check(orCase() == 42, "short-circuited or does not return")?;
check(orHits == 0, "short-circuited or branch is not evaluated")?;

let unaryCase = () -> {
  let value = (if true { return null; } else { null; })?;
  99;
};
let unaryResult = unaryCase();
check(!isError(unaryResult), "unary question does not convert return to Error")?;
if !isError(unaryResult) {
  check(unaryResult == null, "unary question preserves returned null")?;
};

let variableAnnotationCase = () -> {
  let value: if true { return Number; } else { Number; } = 1;
  99;
};
check(variableAnnotationCase() == Number, "variable annotation propagates return before normalization")?;

let objectSlotCase = () -> {
  let value = { selected: if true { return sharedObject; } else { null; } };
  99;
};
check(objectSlotCase() == sharedObject, "object field slot propagates return")?;

let arraySlotCase = () -> {
  let value = [if true { return sharedObject; } else { null; }];
  99;
};
let arrayResult = arraySlotCase();
check(arrayResult == sharedObject, "array element slot propagates return")?;

let calleeSlotCase = () -> {
  let value = (if true { return sharedFunction; } else { sharedFunction; })(3);
  99;
};
let calleeResult = calleeSlotCase();
check(calleeResult == sharedFunction, "callee slot propagates return before call")?;
check(calleeResult(5) == 9, "callee-slot function value remains callable")?;

let interpolationCase = () -> {
  let value = "selected=${if true { return "text"; } else { "skipped"; }}";
  99;
};
check(interpolationCase() == "text", "interpolation slot propagates return")?;

let annotationCase = () -> {
  let identity = (value: if true { return Number; } else { Number; }) -> value;
  99;
};
check(annotationCase() == Number, "annotation slot propagates return")?;

println("if-expression return boundary checks: " + std.String.toString(checks));
