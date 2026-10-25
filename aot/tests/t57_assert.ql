// assert(condition, message): the condition is the checkable form (R1).
// Passing returns null; failing is a contract violation on the panic channel.
assert(true, "literal true");
assert(1 + 2 == 3, 42);
assert("non-empty", "truthy string");
assert([1], "truthy array");
println(assert(true, {why: "object message"}));
println(assert([1], "result is null"));
