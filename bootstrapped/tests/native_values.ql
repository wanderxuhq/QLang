import ../native_values.ql;
let checks = 0;
let check = (ok, label) -> {
  checks = checks + 1;
  if !ok { return std.Error.raise("AssertionFailed", label, null); }; null;
};
let number = (n) -> { {type: "Number", value: n}; };
let coreType = {check: (v) -> true};
let callbackBody = null;
let host = {
  callback: (body, name) -> { callbackBody = body; (x) -> body([x], false); },
  call: (fn, arguments, exempt) -> std.__callNative(fn, arguments),
  load: (path, origin, arguments) -> { {path: path, origin: origin, arguments: arguments}; }
};
let callbackAction = null;
let bridge = NativeValues(host, [{core: coreType, host: Number}], (f, a, exempt) -> callbackAction(a, exempt));
check(bridge.toHost({value: number(7)}) == 7, "number outbound")?;
check(bridge.toCore({value: null}).type == "Null", "null inbound")?;
check(bridge.toCore({value: Number}) == coreType, "canonical type inbound")?;
check(bridge.toHost({value: {type: "Type", value: coreType}}) == Number, "canonical type through wrapper")?;
let object = {type: "Object", value: {n: number(1)}};
object.value.self = object;
let array = {type: "Array", value: [object, object]};
let native = bridge.toHost({value: array});
check(native[0] == native[1] && native[0].self == native[0], "aliases and cycle outbound")?;
check(bridge.toCore({value: native}) == array, "return preserves original identity")?;
native[0].n = 9; native[2] = native[0];
bridge.pull();
check(object.value.n.value == 9 && array.value[2] == object, "native mutations and append")?;
native.remove(2); native.remove(1); bridge.pull();
check(array.value.length == 1, "native array shrink")?;
array.value[1] = object; object.value.n = number(12); bridge.push();
check(native.length == 2 && native[1] == native[0] && native[0].n == 12, "interpreted mutations")?;
let fresh = {value: 5, type: "Object"}; fresh.self = fresh;
let view = bridge.toCore({value: fresh});
check(view.value.type.value == "Object" && view.value.value.value == 5 && view.value.self == view, "user representation-like fields and inbound cycle")?;
fresh.late = 19; bridge.pull();
check(view.value.late.value == 19, "late export visible")?;
let error = Error.raise("stored");
let wrappedError = bridge.toCore({value: error});
check(wrappedError.type == "Error" && wrappedError.value.message == "stored", "Error inbound")?;
let errorOut = bridge.toHost({value: wrappedError});
check(isError(errorOut) && errorOut.message == "stored", "Error outbound")?;
let coreFunction = {type: "Function", params: []};
callbackAction = (arguments, exempt) -> {
  check(arguments[0] == object && object.value.n.value == 20, "callback sees native identity and write")?;
  object.value.n = number(21); object;
};
let callback = bridge.toHost({value: coreFunction});
native[0].n = 20;
let returned = callback(native[0]);
check(returned == native[0] && native[0].n == 21, "callback writes and returned identity")?;
check(bridge.toCore({value: callback}) == coreFunction, "callback round trip identity")?;
let nativeFunction = (a, b) -> a + b;
let func = bridge.toCore({value: nativeFunction});
check(bridge.call(func.extensionFunction, [number(3), number(4)], false).value == 7, "multiargument native call")?;
let partial = bridge.call(func.extensionFunction, [number(3)], false);
check(bridge.call(partial.extensionFunction, [number(5)], false).value == 8, "native partial application")?;
let failure = bridge.call(func.extensionFunction, [wrappedError, number(4)], false);
check(failure.type == "Error" && failure.value.type == "TypeMismatch", "native Error argument rule")?;
let loaded = bridge.load({type: "String", value: "plugin.so"}, "/source/main.ql", array);
check(loaded.value.path.value == "plugin.so" && loaded.value.origin.value == "/source/main.ql" && loaded.value.arguments == array, "loader arguments and namespace wrapping")?;
check(bridge.toHost({value: println}) == println, "native function identity outbound")?;
println("PASS native value bridge: " + std.String.toString(checks) + " checks");
