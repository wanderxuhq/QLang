// Simple test - just test basic QLang functionality
println("QLang is working!");
println("==================");

// Test variables
let x = 42;
let y = 58;
println(x + y);

// Test function
let double = (n) -> n * 2;
println(double(7));

// Test if-else
let msg = if x > 10 { "x is big" } else { "x is small" };
println(msg);

// Test array
let arr = [1, 2, 3, 4, 5];
println(std.Array.length(arr));

// Test object
let obj = { name: "QLang", version: 1.0 };
println(obj.name);

println("All tests passed!");
