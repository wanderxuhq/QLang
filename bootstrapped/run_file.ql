// Run QLang code using the bootstrapped interpreter
// Usage: cargo run --quiet -- bootstrapped/run_file.ql <file.ql>
import ./main.ql;

let runFile = (path) -> {
  println("================================================");
  println("Bootstrapped QLang Interpreter - Running: " + path);
  println("================================================");
  println("");

  // Read the file content using Rust stdlib
  let source = std.fs.readFileText(path);

  // Run it through the bootstrapped interpreter
  runSource(source, path);
};

// The path comes from the command-line argument args[0] (passed from the Rust side), resolved relative to the working directory
let filePath = if args != null && args.length > 0 { args[0]; } else { null; };
if filePath != null {
  runFile(filePath);
} else {
  println("Usage: qlang run_file.ql <file.ql>");
};
