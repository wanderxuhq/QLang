// Test library for export forms
export let exported_value = 42;
export let add = (a, b) -> a + b;
// export { f } is an immediately evaluated object literal; bindings must be defined first
let multiply = (a, b) -> a * b;
export { multiply };
println("lib_a fully loaded");
