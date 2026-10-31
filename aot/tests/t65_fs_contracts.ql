// std.fs contracts: empty text, retained NUL, error kinds and ".." through a symlink.
// Text is read as UTF-8; an empty file is the empty string, not an error, and a
// String's embedded NUL must survive write/read unchanged.
let write = (path, text) -> {
  let result = std.fs.writeText(path, text);
  assert(!isError(result), "cannot write " + path);
  null;
};
let readType = (path) -> std.fs.readFileText(path).type;
let canonicalType = (path) -> std.fs.canonicalPath(path).type;

let empty = "/tmp/qlang-platform-q-t65-empty";
let nul = "/tmp/qlang-platform-q-t65-nul";
let value = "/tmp/qlang-platform-q-t65-value";
write(empty, "");
write(nul, "A\0Z");
write(value, "resolved");

println("empty: " + std.JSON.stringify(std.fs.readFileText(empty)));
println("nul: " + std.JSON.stringify(std.fs.readFileText(nul)));
println("missing: " + readType("/tmp/qlang-platform-q-t65-missing"));
println("directory: " + readType("."));
println("canonical-directory: " + std.String.toString(!isError(std.fs.canonicalPath("."))));
// /var/run is a symlink to /run on Linux: the kernel must follow it and the
// following ".." before canonicalPath reports the resolved path.
let cwd = std.fs.canonicalPath(".");
let through = "/var/run/.." + cwd + "/aot/runtime.ql";
let resolved = std.fs.canonicalPath(through);
let direct = std.fs.canonicalPath("aot/runtime.ql");
let throughText = std.fs.readFileText(through);
let directText = std.fs.readFileText("aot/runtime.ql");
println("symlink-canonical: " +
        std.String.toString(!isError(resolved) && !isError(direct) && resolved == direct));
println("symlink-read: " +
        std.String.toString(!isError(throughText) && !isError(directText) && throughText == directText));
println("null-read: " + readType(null));
println("number-read: " + readType(42));
println("null-canonical: " + canonicalType(null));
println("nul-path-read: " + readType("bad\0path"));
println("nul-path-canonical: " + canonicalType("bad\0path"));
