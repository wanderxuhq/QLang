let saved = std.String.trim;
let defaultTrim = std.String.trim("\u{3000}module\u{3000}");
std.String.trim = (s) -> "changed";
let arrayGet = std.Array.get([42]);
let arrayNamespace = std.Array;
std.Array.get = (a) -> (i) -> "changed";
export { saved, defaultTrim, namespace: std.String, arrayGet, arrayNamespace };
