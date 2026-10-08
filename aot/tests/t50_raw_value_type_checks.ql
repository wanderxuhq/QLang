// Strict regression for raw host values accepted by the boot type predicates.
// Integrated coverage includes default library loading and raw host values.
// Exercise the default Object library installed from the shared bundle.

let checks = 0;
let check = (ok, label) -> {
  checks = checks + 1;
  if !ok { return std.Error.raise("AssertionFailed", label, null); };
  null;
};

check(AnyObject.check(std.Object), "raw std.Object is AnyObject")?;
check(std.Type.of(std.Object) == AnyObject, "Type.of agrees on raw std.Object")?;

let rawObjectKey = std.Object.keys({ keys: 1 })[0];
check(String.check(rawObjectKey), "raw Object.keys string passes String.check")?;
check(std.Type.of(rawObjectKey) == String, "Type.of agrees on raw Object.keys string")?;
let convertedKey = std.String.toString(rawObjectKey);
check(String.check(convertedKey) && convertedKey == "keys", "ordinary String native accepts raw key")?;
let trimmedKey = std.String.trim(rawObjectKey);
check(trimmedKey == "keys", "ordinary QLang String.trim accepts raw key")?;
let annotatedString = (value: String) -> true;
let annotationResult = annotatedString(rawObjectKey);
let annotationError = isError(annotationResult) ||
  (annotationResult != null && !isError(annotationResult.type) && annotationResult.type == "Error");
check(!annotationError, "String annotation accepts raw Object.keys string")?;
if !annotationError { check(annotationResult == true, "String annotated function returns true")?; };

let savedTypeModule = std.Type;
std.Type = { check: savedTypeModule.check, of: (value) -> Never, make: savedTypeModule.make };
check(std.Type.of(std.Object) == Never, "std.Type.of was temporarily rebound")?;
check(AnyObject.check(std.Object), "AnyObject predicate ignores rebound std.Type.of")?;
check(String.check(rawObjectKey), "String predicate ignores rebound std.Type.of")?;
std.Type = savedTypeModule;
check(std.Type.of(std.Object) == AnyObject, "std.Type.of restored")?;

let algorithms = std.Object;
let objectProjection = algorithms.hasOwn(std.Object);
let projectionError = isError(objectProjection) ||
  (objectProjection != null && !isError(objectProjection.type) && objectProjection.type == "Error");
check(!projectionError, "Object algorithms accept raw std.Object")?;
if !projectionError {
  let rawStdKey = std.Object.keys({ keys: 1 })[0];
  check(objectProjection(rawStdKey) == true, "hasOwn accepts a dynamic raw String key")?;
};
let regularProjection = algorithms.hasOwn({ keys: 1 });
let regularProjectionError = isError(regularProjection) ||
  (regularProjection != null && !isError(regularProjection.type) && regularProjection.type == "Error");
check(!regularProjectionError, "Object algorithms retain wrapped object support")?;
if !regularProjectionError {
  check(regularProjection(rawObjectKey) == true, "hasOwn accepts raw key on wrapped object")?;
};

let ordinaryObject = { field: 1 };
let fn = (value) -> value;
let numberLike = { type: "Number", value: 123 };
let objectLike = { type: "Object", value: { field: 2 } };
let storedError = Error.raise("stored");
let objectType = std.Type.of(ordinaryObject);
check(Number.check(12), "wrapped Number classification retained")?;
check(String.check("text"), "wrapped String classification retained")?;
check(Boolean.check(true), "wrapped Boolean classification retained")?;
check(AnyArray.check([1]), "wrapped Array classification retained")?;
check(AnyObject.check(ordinaryObject), "wrapped Object classification retained")?;
check(Function.check(fn) && !AnyObject.check(fn), "Function remains distinct from Object")?;
check(!AnyObject.check([]), "Array remains distinct from Object")?;
check(!AnyObject.check(Number) && std.Type.check(Number), "type values remain distinct from Object")?;
check(!AnyObject.check(objectType) && std.Type.check(objectType), "Type.of result remains a type value")?;
check(Error.check(storedError) && std.Type.of(storedError) == Error,
      "Error classification retained")?;
check(!AnyObject.check(storedError), "Error remains distinct from Object")?;
check(!Number.check(numberLike) && AnyObject.check(numberLike),
      "user Number-lookalike object keeps Object classification")?;
check(objectLike.type == "Object" && AnyObject.check(objectLike),
      "Object wrapper-lookalike remains Object")?;
check(!AnyObject.check(null) && Null.check(null) && !Null.check(""),
      "Null classification remains unchanged")?;
check(Any.check(storedError) && !Never.check(storedError),
      "Any and Never classification remains unchanged")?;

let verifyCount = (actual) -> {
  if actual != 31 {
    return std.Error.raise("AssertionFailed", "expected 31 raw type checks, got " + std.String.toString(actual), null);
  };
  null;
};
verifyCount(checks)?;
println("raw value type predicate checks: " + std.String.toString(checks));
