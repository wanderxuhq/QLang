// Both engines parse the same embedded QLang source. No algorithm lives here.
import ../stdlib/bundle.ql;
import ./lexer.ql;
import ./parser.ql;
import ./source_origins.ql;
let parseStandardLibrary = () -> {
  let parser = Parser(Lexer(standardLibrarySource).tokenize());
  parser.setSource(standardLibrarySource); parser.setSourcePath("<standard-library>");
  let program = remapSourceLocations(parser.parse(), "<standard-library>", standardLibraryOrigins);
  if program.errors.length > 0 {
    return std.Error.raise("ParseError", "standard library: " + program.errors[0], null);
  };
  program;
};
export { parseStandardLibrary, standardLibraryOrigins };
