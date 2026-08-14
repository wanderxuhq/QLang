//! QLang interpreter CLI

use std::env;
use std::io::Write;
use std::path::Path;
use qlang::Interpreter;
use qlang::interpreter::error_diag;
use qlang::value::{RuntimeError, Value};

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

    // AOT compile: qlang --compile <src.ql> -o <out>
    if file_path == "--compile" {
        // Guard `args.len() < 5` (not 4): with `-o` as the last arg the brief's
        // `args[4]` below would index out of bounds.
        if args.len() < 5 || args[3] != "-o" {
            eprintln!("Usage: {} --compile <src.ql> -o <out>", args[0]);
            std::process::exit(1);
        }
        let src_path = &args[2];
        let out_path = &args[4];
        let src = std::fs::read_to_string(src_path).unwrap_or_else(|e| {
            eprintln!("Error reading {}: {}", src_path, e);
            std::process::exit(1);
        });
        // The stdout redirect must wrap run_file (the pipe is drained only after
        // stdout is restored), so capture_stdout takes a closure that runs qlangc
        // on a fresh interpreter with args[0] = source text, args[1] = source path.
        // R10-h: the compiled artifact embeds runtime.ql as the runtime semantics
        // layer (qlangc emits it as the first top-level statements). Concatenate it
        // ahead of the user source; args[1] stays the user source path.
        let runtime_src = std::fs::read_to_string("aot/runtime.ql").unwrap_or_else(|e| {
            eprintln!("Error reading aot/runtime.ql: {}", e);
            std::process::exit(1);
        });
        let mut run_error: Option<RuntimeError> = None;
        let combined = format!("{}\n{}", runtime_src, src);
        let src_path_str = src_path.to_string();
        let ir = capture_stdout(|interp| {
            interp.set_args(&[combined, src_path_str]);
            if let Err(e) = interp.run_file(Path::new("aot/qlangc.ql")) {
                run_error = Some(e);
            }
        });
        if let Some(e) = run_error {
            eprintln!("Error running qlangc: {}", e);
            std::process::exit(1);
        }
        let tmp_ll = std::env::temp_dir().join(format!("qlangc_{}.ll", std::process::id()));
        std::fs::write(&tmp_ll, &ir).unwrap_or_else(|e| {
            eprintln!("Error writing {}: {}", tmp_ll.display(), e);
            std::process::exit(1);
        });
        let st = std::process::Command::new("clang")
            .args(["-fuse-ld=lld", tmp_ll.to_str().unwrap(), "aot/runtime.c", "-o", out_path])
            .status();
        std::fs::remove_file(&tmp_ll).ok();
        match st {
            Ok(s) if s.success() => {
                println!("compiled: {}", out_path);
            }
            Ok(s) => {
                eprintln!("clang failed with {}", s);
                std::process::exit(1);
            }
            Err(e) => {
                eprintln!("clang spawn error: {}", e);
                std::process::exit(1);
            }
        }
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
    println!("  --compile <src.ql> -o <out>   AOT compile to a native ELF via clang/lld");
    println!("  --help, -h   Show this help message");
    println!();
    println!("Examples:");
    println!("  {} hello.ql", program);
    println!("  {} demo/fib.ql", program);
}

/// Run `f` while capturing all writes to stdout (dup2 to a pipe), then restore stdout
/// and return the captured bytes. qlangc's IR text is captured through this pipe; the
/// redirect MUST wrap `f` (i.e. the `interp.run_file(...)` call), otherwise stdout is
/// already restored and the pipe is empty on read-back.
///
/// Minor-3d: the pipe buffer is ~64KB; qlangc's IR output (runtime.ql compiled into
/// every artifact) now exceeds that, so a write() to the full pipe would block forever
/// with no concurrent reader. Drain the read end from a dedicated thread while `f`
/// runs; after `f` returns and stdout is restored (last write-end reference closed,
/// see Minor-3c), the reader sees EOF and we join it.
fn capture_stdout<F>(f: F) -> Vec<u8>
where
    F: FnOnce(&mut Interpreter),
{
    let saved = unsafe { libc::dup(1) };
    if saved < 0 {
        eprintln!("capture_stdout: dup(1) failed");
        std::process::exit(1);
    }
    let mut fds = [0 as libc::c_int; 2];
    unsafe {
        libc::pipe(fds.as_mut_ptr());
        libc::dup2(fds[1], 1);
        libc::close(fds[1]);
    }
    // Reader thread owns the read fd (move); loops until EOF (n <= 0), closes it, returns bytes.
    let read_fd = fds[0];
    let reader = std::thread::spawn(move || {
        let mut buf = Vec::new();
        let mut tmp = [0u8; 4096];
        loop {
            let n = unsafe { libc::read(read_fd, tmp.as_mut_ptr() as *mut libc::c_void, 4096) };
            if n <= 0 {
                break;
            }
            buf.extend_from_slice(&tmp[..n as usize]);
        }
        unsafe { libc::close(read_fd) };
        buf
    });
    let mut interp = Interpreter::new();
    f(&mut interp);
    // Restore stdout before joining the reader: after dup2(saved, 1) the pipe's write
    // end has no remaining references, so the reader sees EOF once buffered data is
    // drained. Flush explicitly first — a `print` without a trailing newline would
    // otherwise lose buffered bytes across the dup2 (Minor-3c).
    let _ = std::io::stdout().flush();
    unsafe {
        libc::dup2(saved, 1);
        libc::close(saved);
    }
    reader.join().expect("capture_stdout reader thread panicked")
}
