println(std.JSON.stringify(null));
println(std.JSON.stringify(true));
println(std.JSON.stringify(42));
println(std.JSON.stringify(-2.5));
println(std.JSON.stringify("中文é😀"));
println(std.JSON.stringify([1, "a,b", true, null, []]));
println(std.JSON.stringify({ a: [1, "x"] }));
println(std.JSON.parse('"中文é😀"'));
println(std.JSON.parse('"\\u4e2d\\u6587\\u00e9\\ud83d\\ude00"'));
let o = std.JSON.parse('{"a,b": [true, null, -1.25e2], "": "empty", "a": 1, "a": 2}');
println(o["a,b"][0]);
println(o["a,b"][1]);
println(o["a,b"][2]);
println(o[""]);
println(o.a);
println(std.JSON.parse('1.25e2'));
println(std.JSON.parse('12.5e-1'));
println(std.JSON.parse('"a\\\"b"'));
println(std.JSON.stringify(std.JSON.parse('"\\u0000\\b\\f\\n\\r\\t\\\\\\\""')));
println(std.JSON.stringify(std.JSON.parse('["", ",", [1, 2], {"a":3}]')));
println(std.String.codePointAt("aé中😀")(0));
println(std.String.codePointAt("aé中😀")(1));
println(std.String.codePointAt("aé中😀")(2));
println(std.String.codePointAt("aé中😀")(-1));
let invalid = ["", "{", "[", '"', "{中", "[中", '"中文', "[1,]", '{"x":}', '{"x":1,}', "[1 2]", "true false", "01", "1.", "+1", "NaN", "1e", "null x", '"\\q"', '"\\u中123"', '"\\ud800"', '"\\udc00"', '"\\ud800\\u0041"', '"a\nb"'];
let i = 0;
while i < invalid.length {
  println(isError(std.JSON.parse(invalid[i])));
  i = i + 1;
};
println(isError(std.JSON.parse(1)));
println(isError(std.String.codePointAt(1)));
println(isError(std.String.codePointAt("x")(2)));
println(isError(std.String.codePointAt("x")(-2)));
// Decimal conversion must round once, retain negative zero, and never truncate.
let numbers = ["3.14", "0.1", "0.30000000000000004", "1.2345678901234567", "-0", "0.0000001", "9007199254740993", "999999999999999999999999", "1e20", "1e309", "-1e309", "1e-9999", "0e9999"];
i = 0;
while i < numbers.length {
  println(std.JSON.stringify(std.JSON.parse(numbers[i])));
  i = i + 1;
};
// Keep ordinary object fields called type/value distinct from interpreter wrappers.
let tagged = std.JSON.parse('{"type":"Number","value":[{"type":"String","value":"data"}]}');
println(tagged.type);
println(tagged.value[0].value);
let roundTrip = std.JSON.parse(std.JSON.stringify(tagged));
println(roundTrip.type);
println(roundTrip.value[0].value);
// Nesting guard is checked before recursing, and parser state is per call.
let deep = "0";
i = 0;
while i < 129 { deep = "[" + deep + "]"; i = i + 1; };
println(isError(std.JSON.parse(deep)));
println(std.JSON.parse("42"));
println(std.JSON.stringify(std.JSON.parse('"\\u0000"')));

let unicode = std.JSON.parse('"aé中\\ud83d\\ude00"');
println(unicode.length);
println(std.String.length(unicode));
println(unicode[1]);
println(unicode[-1]);
println(std.String.at(unicode, 2));
println(isError(unicode[4]));
println(isError(unicode[0.5]));

let error = std.Error.raise("K", "message", null);
println(isError(std.JSON.stringify(error)));
println(std.JSON.stringify([error]));
println(std.JSON.parse("[1,]") ?? "invalid");
let cycle = [];
cycle[0] = cycle;
println(isError(std.JSON.stringify(cycle)));
println(std.JSON.stringify([1, 2]));

// Empty separators must terminate and preserve whole Unicode scalars.
println(std.JSON.stringify(std.String.split("aé中😀")("")));
println(std.JSON.stringify(std.String.split("")("")));
println(std.JSON.stringify(std.String.split("a,,b,")(",")));
println(std.JSON.stringify(std.String.split("a😀b😀")("😀")));
println(std.JSON.stringify(std.String.split("abc")(1)));
println(isError(std.String.split(1)));
