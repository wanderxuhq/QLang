use qlang::{Interpreter, value::Value};
use std::{fs, path::PathBuf, sync::atomic::{AtomicUsize, Ordering}};

static NEXT: AtomicUsize = AtomicUsize::new(0);
struct Files(PathBuf);
impl Files {
    fn new() -> Self {
        let p = std::env::temp_dir().join(format!("qlang-modules-{}-{}", std::process::id(), NEXT.fetch_add(1, Ordering::Relaxed)));
        fs::create_dir_all(p.join("lib")).unwrap(); Self(p)
    }
    fn put(&self, name: &str, source: &str) { fs::write(self.0.join(name), source).unwrap(); }
    fn run(&self) -> Value { Interpreter::new().run_file(&self.0.join("main.ql")).unwrap() }
}
impl Drop for Files { fn drop(&mut self) { let _ = fs::remove_dir_all(&self.0); } }

#[test]
fn repeated_imports_reexecute_and_keep_separate_closures() {
    let f = Files::new();
    f.put("lib/count.ql", "let n = 0; let next = () -> { n = n + 1; n; }; export { next };");
    f.put("main.ql", r#"let a = import "./lib/count.ql"; let b = import "./lib/count.ql"; a.next() == 1 && a.next() == 2 && b.next() == 1 && next() == 2 && a.next != b.next;"#);
    assert!(matches!(f.run(), Value::Boolean(true)));
}

#[test]
fn function_imports_resolve_relative_to_definition_file() {
    let f = Files::new();
    f.put("lib/value.ql", "export let value = 42;");
    f.put("lib/loader.ql", r#"let load = () -> { let m = import "./value.ql"; m.value; }; export load;"#);
    f.put("main.ql", "import ./lib/loader.ql\nload();");
    assert_eq!(f.run().to_string(), "42");
}

#[test]
fn failed_module_returns_error_and_does_not_inject_exports() {
    for tail in ["1 / 0;", "(1 / 0)?;"] {
        let f = Files::new();
        f.put("lib/bad.ql", &format!("export let leaked = 1; {tail}"));
        f.put("main.ql", r#"import "./lib/bad.ql";"#);
        let mut interpreter = Interpreter::new();
        let result = interpreter.run_file(&f.0.join("main.ql")).unwrap();
        assert!(matches!(result, Value::Error(_)));
        assert!(interpreter.global_env.borrow().get("leaked").is_none());
    }
}

#[test]
fn canonical_cycles_fail_and_loading_state_is_restored() {
    let f = Files::new(); f.put("main.ql", "import ./lib/../main.ql;");
    let mut interpreter = Interpreter::new();
    assert!(interpreter.run_file(&f.0.join("main.ql")).unwrap_err().to_string().contains("cyclic import"));
    f.put("main.ql", "42;");
    assert_eq!(interpreter.run_file(&f.0.join("main.ql")).unwrap().to_string(), "42");
}

#[test]
fn imported_function_errors_use_definition_source_positions() {
    let f = Files::new();
    f.put("lib/error.ql", "let boom = () -> {\n  let ignored = 1;\n  1 / 0;\n};\nexport boom;\n");
    f.put("main.ql", r#"import "./lib/error.ql"; boom();"#);
    match f.run() { Value::Error(e) => assert_eq!(e.line, 3), value => panic!("{value:?}") }
}

#[test]
fn file_read_failures_are_errors_not_source_text() {
    let f = Files::new();
    f.put("main.ql", r#"isError(std.fs.readFileText(42)) && isError(std.fs.readFileText("/qlang/nonexistent/file"));"#);
    assert!(matches!(f.run(), Value::Boolean(true)));
}
