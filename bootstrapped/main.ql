// QLang Bootstrapped Interpreter - Main Entry Point
// This is QLang written in QLang!

import ./stdlib.ql;
import ./tokens.ql;
import ./lexer.ql;
import ./ast.ql;
import ./parser.ql;
import ./interpreter.ql;

let runSource = (source, path) -> {
  println("Bootstrapped QLang interpreter v0.2.0");
  println("======================================");
  if path != null {
    println("Running: " + path);
  }

  println("Lexing...");
  let lexer = Lexer(source);
  let tokens = lexer.tokenize();
  println("Generated " + std.String.toString(tokens.length) + " tokens");

  println("Parsing...");
  let parser = Parser(tokens);
  let program = parser.parse();
  println("Parsed " + std.String.toString(program.statements.length) + " statements");

  println("Interpreting...");
  let interpreter = Interpreter();
  let result = interpreter.runProgram(program);

  println("Execution complete.");
  if result.flow == "Propagate" || (std.Type.of(result.value) == "Object" && result.value != null && std.Type.of(result.value.type) == "String" && result.value.type == "Error") {
    // Top-level error value — raised by `?`, or a bare error value left by the
    // last expression (e.g. a program ending in `1 / 0;`): errors must never
    // vanish silently. Print the diagnostic (kind + message + cause chain, no
    // positions — std.Error.toString) and surface the error result (the host
    // prints the diagnostic and exits 1; boot has no exit primitive).
    println(std.Error.toString(result.value.value));
    return { flow: "Error", value: result.value };
  }
  result;
};

// When run as main script with command line arguments
let main = (args) -> {
  if args.length > 0 {
    let source = args[0];
    let path = if args.length > 1 { args[1]; } else { null; };
    runSource(source, path);
  } else {
    println("Usage: qlang <file.ql>");
    null;
  }
};

export runSource;
export main;
