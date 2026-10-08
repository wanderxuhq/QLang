// Strict regression fixture for raw host Object/Type computed indexing.
// Expected values follow aot/runtime.ql::__get_index and __obj_get.
let checks = 0;
let check = (ok, label) -> {
  checks = checks + 1;
  if !ok { return std.Error.raise("AssertionFailed", label, null); };
  null;
};

let typeKey = "check";
check(Number["check"](7), "raw Type supports literal computed field access")?;
check(Number[typeKey](9), "raw Type supports dynamic computed field access")?;
let readField = (receiver, key) -> receiver[key];
let numberCheck = readField(Number, typeKey);
check(numberCheck(11), "raw Type field survives ordinary function argument passing")?;

let objectKeys = std.Object["keys"];
check(objectKeys({ item: 1 }).length == 1,
      "raw namespace computed field returns a callable native")?;
let missing = std.Object["__raw_index_missing__"];
check(isError(missing) && missing.type == "UndefinedField" &&
      missing.message == "Undefined field",
      "raw namespace missing field follows native __get_index error")?;

let invalidIndexes = [null, true, [], {}, (value) -> value];
let i = 0;
while i < invalidIndexes.length {
  let error = std.Object[invalidIndexes[i]];
  check(isError(error) && error.type == "CannotIndex" &&
        error.message == "object key must be a String or Number",
        "raw namespace rejects non-String/non-Number index")?;
  i = i + 1;
};

let namespace = std.Object;
namespace[740219] = "numeric key";
check(namespace[740219] == "numeric key" &&
      namespace["740219"] == "numeric key",
      "raw Object numeric key is normalized to decimal String")?;

let errorKey = "__raw_index_error_value";
let storedError = std.Error.raise("StoredValue", "raw namespace error", null);
namespace[errorKey] = storedError;
let errorRead = namespace[errorKey];
check(isError(errorRead) && errorRead.type == "StoredValue" &&
      errorRead.message == "raw namespace error",
      "raw namespace preserves a stored Error value")?;
let indexedByError = std.Object[storedError];
check(isError(indexedByError) && indexedByError.type == "StoredValue" &&
      indexedByError.message == "raw namespace error",
      "raw native indexing returns an Error index unchanged")?;

let nullKey = "__raw_index_null_value";
namespace[nullKey] = null;
check(namespace[nullKey] == null && std.Object.hasOwn(namespace)(nullKey),
      "raw namespace preserves stored null and field presence")?;

let objectKey = "__raw_index_object_value";
let objectValue = { nested: 1 };
namespace[objectKey] = objectValue;
let objectRead = namespace[objectKey];
objectRead.nested = 2;
check(objectRead == objectValue && objectValue.nested == 2 &&
      namespace[objectKey].nested == 2,
      "raw namespace preserves object identity and aliasing")?;

let arrayKey = "__raw_index_array_value";
let arrayValue = [3];
namespace[arrayKey] = arrayValue;
let arrayRead = namespace[arrayKey];
arrayRead[0] = 4;
check(arrayRead == arrayValue && arrayValue[0] == 4 &&
      namespace[arrayKey][0] == 4,
      "raw namespace preserves Array identity and aliasing")?;

let functionKey = "__raw_index_function_value";
let functionValue = (value) -> value + 1;
namespace[functionKey] = functionValue;
let functionRead = namespace[functionKey];
check(functionRead == functionValue && functionRead(5) == 6,
      "raw namespace preserves callable identity")?;

let verifyCount = (actual) -> {
  if actual != 17 {
    return std.Error.raise("AssertionFailed", "expected 17 raw Object index checks, got " + std.String.toString(actual), null);
  };
  null;
};
verifyCount(checks)?;
println("raw Object index checks: " + std.String.toString(checks));
