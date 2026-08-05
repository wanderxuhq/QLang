//! QLang interpreter CLI

use std::env;
use std::path::Path;
use qlang::Interpreter;
use qlang::interpreter::error_diag;
use qlang::value::Value;

fn main() {
    let args: Vec<String> = env::args().collect();

    if args.len() < 2 {
        print_usage(&args[0]);
        return;
    }

    let file_path = &args[1];

    // Check for common options
    if file_path == "--help" || file_path == "-h" {
        print_usage(&args[0]);
        return;
    }

    let path = Path::new(file_path);
    if !path.exists() {
        eprintln!("Error: File not found: {}", file_path);
        std::process::exit(1);
    }

    if !path.is_file() {
        eprintln!("Error: Path is not a file: {}", file_path);
        std::process::exit(1);
    }

    let mut interpreter = Interpreter::new();

    // Pass extra command-line arguments to the script (starting from args[0], i.e. args[2..]; an empty array when no arguments)
    interpreter.set_args(&args[2..]);

    match interpreter.run_file(path) {
        // Top-level `?` on an error value: print the full diagnostic and exit non-zero
        Ok(Value::Error(err)) => {
            eprintln!("{}", error_diag(&err));
            std::process::exit(1);
        }
        Ok(_) => {
            // Program executed successfully
        }
        Err(e) => {
            eprintln!("Error: {}", e);
            std::process::exit(1);
        }
    }
}

fn print_usage(program: &str) {
    println!("QLang Interpreter v0.1.0");
    println!();
    println!("Usage: {} <file.ql>", program);
    println!();
    println!("Options:");
    println!("  <file.ql>    QLang source file to execute");
    println!("  --help, -h   Show this help message");
    println!();
    println!("Examples:");
    println!("  {} hello.ql", program);
    println!("  {} demo/fib.ql", program);
}
