// Run QLang code using the bootstrapped interpreter
// Usage: native-interpreter <file.ql> [args...], or qlang bootstrapped/run_file.ql <file.ql> [args...]
import ./main.ql;

let runFile = (path) -> {
  println("================================================");
  println("Bootstrapped QLang Interpreter - Running: " + path);
  println("================================================");
  println("");

  // File access is provided by the hosting runtime (native or bootstrap).
  let source = std.fs.readFileText(path)?;

  // Run it through the bootstrapped interpreter
  let arguments = []; let i = 1;
  while i < args.length { arguments[arguments.length] = args[i]; i = i + 1; };
  let result = runSourceWithArgs(source, path, arguments);
  // Unwrap the interpreter result at the process boundary so the runtime
  // reports an unhandled error and returns a failing exit status.
  if result.flow == "Error" { result.value.value; } else { null; };
};

// The path is args[0], resolved relative to the working directory.
let filePath = if args != null && args.length > 0 { args[0]; } else { null; };
if filePath != null {
  // The CLI adapter is outside the interpreted call stack. Suppress its own
  // native frames until process exit; evaluator scopes supply the user positions.
  let diagnostics = std.__diagnostics;
  if !isError(diagnostics) { diagnostics.enter(null); };
  runFile(filePath);
} else {
  println("Usage: qlang run_file.ql <file.ql> [args...]");
};
