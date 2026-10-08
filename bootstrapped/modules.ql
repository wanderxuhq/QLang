// File loading shared by the boot interpreter and compile-time module graph.
import ./stdlib.ql;
import ./lexer.ql;
import ./parser.ql;
let modulePath = (origin, path) -> {
  if path[0] == "/" { return std.fs.canonicalPath(path); };
  let chars = std.String.toChars(origin); let last = -1; let i = 0;
  while i < chars.length { if chars[i] == "/" { last = i; }; i = i + 1; };
  let directory = ""; i = 0;
  while i <= last { directory = directory + chars[i]; i = i + 1; };
  std.fs.canonicalPath(directory + path);
};
let parseModule = (source, path) -> {
  let parser = Parser(Lexer(source).tokenize()); parser.setSource(source); parser.setSourcePath(path);
  let program = parser.parse();
  if program.errors.length > 0 { return std.Error.raise("ParseError", program.errors[0], null); };
  program;
};
export { modulePath, parseModule };
