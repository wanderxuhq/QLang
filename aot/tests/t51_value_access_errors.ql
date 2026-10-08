// Strict isolated regression candidate for MemberAccess/IndexAccess behavior.
let checks = 0;
let check = (ok, label) -> {
  checks = checks + 1;
  if !ok { return std.Error.raise("AssertionFailed", label, null); };
  null;
};

let scalar = 42;
let error = scalar.type;
check(isError(error) && error.type == "NotAnObject" && error.message == "Not an object",
      "Number scalar type field is private")?;
error = scalar.missing;
check(isError(error) && error.type == "NotAnObject" && error.message == "Not an object",
      "Number scalar missing field is NotAnObject")?;
let boolean = true;
error = boolean.type;
check(isError(error) && error.type == "NotAnObject" && error.message == "Not an object",
      "Boolean scalar type field is private")?;
error = boolean.missing;
check(isError(error) && error.type == "NotAnObject" && error.message == "Not an object",
      "Boolean scalar missing field is NotAnObject")?;
let nullValue = null;
error = nullValue.member;
check(isError(error) && error.type == "NotAnObject" && error.message == "Not an object",
      "null member receiver is NotAnObject")?;

let array = [10, 20];
error = array.type;
check(isError(error) && error.type == "UndefinedField" && error.message == "Undefined field",
      "Array type representation is private")?;
error = array.value;
check(isError(error) && error.type == "UndefinedField" && error.message == "Undefined field",
      "Array backing storage is private")?;
error = array.missing;
check(isError(error) && error.type == "UndefinedField" && error.message == "Undefined field",
      "Array unknown field uses UndefinedField")?;
check(array.length == 2, "Array length remains available")?;
array.add(30);
check(array.length == 3, "Array add remains available")?;
array.remove(2);
check(array.length == 2, "Array remove remains available")?;

let string = "a😀b";
check(string.length == 3, "String scalar length remains available")?;
error = string.type;
check(isError(error) && error.type == "NotAnObject", "String type representation is private")?;
error = string.missing;
check(isError(error) && error.type == "NotAnObject", "String unknown field is NotAnObject")?;
check(string[1] == "😀" && string[-1] == "b", "String scalar and negative indexing remain available")?;
check(array[0] == 10 && array[-1] == 20, "Array positive and negative indexing remain available")?;

let storedError = std.Error.raise("Stored", "object Error value", null);
let child = { count: 1 };
let fn = (value) -> value + 1;
let object = { normal: 7, storedNull: null, storedError: storedError,
               child: child, fn: fn, "7": "numeric key", "dynamic": 19 };
check(object.normal == 7, "ordinary object field remains available")?;
check(object.storedNull == null && !isError(object.storedNull), "object field preserves stored Null")?;
error = object.storedError;
check(isError(error) && error.type == "Stored" && error.message == "object Error value",
      "object field preserves stored Error")?;
let readChild = object.child;
readChild.count = 2;
check(readChild == child && child.count == 2 && object.child.count == 2,
      "object field preserves object identity")?;
let readFunction = object.fn;
check(readFunction == fn && readFunction(8) == 9, "object field preserves callable identity")?;
error = object.absent;
check(isError(error) && error.type == "UndefinedField" && error.message == "Undefined field",
      "object missing field uses native UndefinedField")?;
check(object["normal"] == 7, "Object String index reads field")?;
check(object[7] == "numeric key", "Object numeric index normalizes through host key conversion")?;
let dynamicKey = std.Object.keys({ dynamic: 1 })[0];
check(object[dynamicKey] == 19, "Object index accepts raw String key")?;
check(object["storedNull"] == null && !isError(object["storedNull"]),
      "Object index preserves stored Null")?;
error = object["storedError"];
check(isError(error) && error.type == "Stored" && error.message == "object Error value",
      "Object index preserves stored Error")?;
error = object[storedError];
check(isError(error) && error.type == "Stored" && error.message == "object Error value",
      "Object Error key returns the original Error")?;
error = object[true];
check(isError(error) && error.type == "CannotIndex" &&
      error.message == "object key must be a String or Number",
      "Object rejects Boolean key with native CannotIndex")?;
let arrayError = [storedError];
error = arrayError[0];
check(isError(error) && error.type == "Stored" && error.message == "object Error value",
      "Array element preserves stored Error")?;

error = Number[0];
check(isError(error) && error.type == "UndefinedField" && error.message == "Undefined field",
      "Number type namespace numeric lookup")?;
error = Boolean[0];
check(isError(error) && error.type == "UndefinedField" && error.message == "Undefined field",
      "Boolean type namespace numeric lookup")?;
error = scalar[0];
check(isError(error) && error.type == "CannotIndex" && error.message == "Cannot index",
      "Number scalar index receiver is rejected")?;
error = boolean[0];
check(isError(error) && error.type == "CannotIndex" && error.message == "Cannot index",
      "Boolean scalar index receiver is rejected")?;
error = fn[0];
check(isError(error) && error.type == "CannotIndex" && error.message == "Cannot index",
      "Function index receiver is rejected")?;
error = nullValue[0];
check(isError(error) && error.type == "CannotIndex" && error.message == "Cannot index",
      "null index receiver is rejected")?;

let probeError = std.Error.raise("Probe", "error read zone", null);
check(probeError["message"] == "error read zone", "Error String index reads message")?;
let dynamicErrorKey = std.Object.keys({ message: 1 })[0];
check(probeError[dynamicErrorKey] == "error read zone", "Error index accepts raw String key")?;
check(probeError.cause == null, "Error member preserves null cause")?;
error = probeError["absent"];
check(isError(error) && error.type == "UndefinedField" && error.message == "Undefined field: absent",
      "Error missing String field uses native error")?;
error = probeError[1];
check(isError(error) && error.type == "CannotIndex" && error.message == "Cannot index",
      "Error rejects Number key")?;
error = probeError[true];
check(isError(error) && error.type == "CannotIndex" && error.message == "Cannot index",
      "Error rejects Boolean key")?;
error = probeError[null];
check(isError(error) && error.type == "CannotIndex" && error.message == "Cannot index",
      "Error rejects Null key")?;
error = probeError[storedError];
check(isError(error) && error.type == "CannotIndex" && error.message == "Cannot index",
      "Error rejects Error key")?;

let numberCheck = Number["check"];
check(numberCheck(5), "Type namespace String index preserves callable member")?;
let userType = std.Type.make((value) -> value == 1);
let userCheck = userType["check"];
check(userCheck(1), "Type-valued Object index preserves callable member")?;

let verifyCount = () -> {
  if checks != 46 { return std.Error.raise("AssertionFailed", "wrong fixture check count", null); };
  null;
};
verifyCount()?;
println("value access error checks: " + std.String.toString(checks));
