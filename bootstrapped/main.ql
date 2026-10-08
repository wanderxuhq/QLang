// QLang Bootstrapped Interpreter - Main Entry Point
// This is QLang written in QLang!

import ./stdlib.ql;
import ./tokens.ql;
import ./lexer.ql;
import ./ast.ql;
import ./parser.ql;
import ./interpreter.ql;

let runSourceWithArgs = (source, path, arguments) -> {
  println("Bootstrapped QLang interpreter v0.2.0");
  println("======================================");
  if path != null {
    println("Running: " + path);
  }

  println("Lexing...");
  let lexer = Lexer(source);
  let tokens = lexer.tokenize();
  println("Generated " + std.String.toString(tokens.length) + " tokens");

  let origin = path;
  if origin == null { origin = ""; };
  let canonical = std.fs.canonicalPath(origin);
  if !isError(canonical) { origin = canonical; };

  println("Parsing...");
  let parser = Parser(tokens);
  parser.setSource(source); parser.setSourcePath(origin);
  let program = parser.parse();
  println("Parsed " + std.String.toString(program.statements.length) + " statements");

  if program.errors.length > 0 {
    let error = std.Error.raise("ParseError", program.errors[0], null);
    return {flow: "Error", value: {type: "Error", value: error, propagate: true}};
  };

  println("Interpreting...");
  let interpreter = Interpreter();
  let configured = interpreter.setArguments(arguments);
  if isError(configured) { return {flow: "Error", value: {type: "Error", value: configured, propagate: true}}; };
  interpreter.setModuleContext(origin, {});
  let result = interpreter.runProgram(program);

  println("Execution complete.");
  if result.flow == "Propagate" || (result.value != null && !isError(result.value.type) && result.value.type == "Error") {
    // Top-level error value — raised by `?`, or a bare error value left by the
    // last expression (e.g. a program ending in `1 / 0;`): errors must never
    // vanish silently. Print the diagnostic (kind + message + cause chain, no
    // positions — std.Error.toString) and return the error result record.
    // run_file.ql unwraps it into the hosting runtime's process error channel.
    println(std.Error.toString(result.value.value));
    return { flow: "Error", value: result.value };
  }
  result;
};

// Existing embedding calls keep their two-argument interface and empty argv.
let runSource = (source, path) -> runSourceWithArgs(source, path, []);

// When run as main script with command line arguments
let main = (args) -> {
  if args.length > 0 {
    let source = args[0];
    let path = if args.length > 1 { args[1]; } else { null; };
    let arguments = []; let i = 2;
    while i < args.length { arguments[arguments.length] = args[i]; i = i + 1; };
    runSourceWithArgs(source, path, arguments);
  } else {
    println("Usage: qlang <file.ql>");
    null;
  }
};

export runSource;
export runSourceWithArgs;
export main;
