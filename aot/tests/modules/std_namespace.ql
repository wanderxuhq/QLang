let original = std.String.toString;
std.String.toString = (value) -> "module";
std.extra = 1;
export { original, std };
