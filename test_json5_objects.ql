// JSON5 object literals
let obj = { name: "Alice", age: 30 };
if obj.name == "Alice" && obj["age"] == 30 {
    println("PASS: basic object");
} else {
    println("FAIL: basic object");
}

// Four key kinds + trailing comma
let o2 = { if: 1, true: 2, null: 3, "a b": 4, 0: 5, };
if o2["if"] == 1 && o2["true"] == 2 && o2["null"] == 3 && o2["a b"] == 4 && o2["0"] == 5 {
    println("PASS: keyword/string/number keys + trailing comma");
} else {
    println("FAIL: keys");
}

// Shorthand preserved (relied upon by export)
let greet = () -> "hi";
let o3 = { greet };
if o3.greet() == "hi" {
    println("PASS: shorthand");
} else {
    println("FAIL: shorthand");
}

// Nested values + array trailing comma
let o4 = { arr: [1, 2, 3,], nested: { x: 1 } };
if o4.arr[2] == 3 && o4.nested.x == 1 {
    println("PASS: nested values + array trailing comma");
} else {
    println("FAIL: nested");
}
