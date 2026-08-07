// tests/uninitialized.rs
use qlang::Interpreter;

fn run(src: &str) -> String {
    let mut interp = Interpreter::new();
    interp.run_source(src, "test".to_string())
        .expect("run failed")
        .to_string()
}

#[test]
fn let_without_value_parses() {
    let out = run("let x;");
    assert!(!out.contains("ParseError"), "let x; should parse, got: {}", out);
}

#[test]
fn lookup_distinguishes_three_states() {
    use qlang::environment::{Environment, Lookup};
    use qlang::value::Value;
    let mut env = Environment::new();
    env.define("a".to_string(), Value::Number(1.0));
    env.define("b".to_string(), Value::Void); // null
    env.define_uninitialized("c".to_string(), None);
    assert!(matches!(env.lookup("a"), Lookup::Value(_)));
    assert!(matches!(env.lookup("b"), Lookup::Value(Value::Void)));
    assert!(matches!(env.lookup("c"), Lookup::Uninitialized));
    assert!(matches!(env.lookup("z"), Lookup::Undefined));
}

#[test]
fn assign_initializes_uninitialized_binding() {
    use qlang::environment::{Environment, Lookup};
    use qlang::value::Value;
    let mut env = Environment::new();
    env.define_uninitialized("x".to_string(), None);
    env.assign("x", Value::Number(5.0)).unwrap();
    assert!(matches!(env.lookup("x"), Lookup::Value(Value::Number(5.0))));
}

// --- Task 3: reading an uninitialized variable → Uninitialized error value; let x; full declaration semantics ---

#[test]
fn reading_uninitialized_is_error_value() {
    let out = run("let x; isError(x);");
    assert_eq!(out.trim(), "true");
}

#[test]
fn reading_uninitialized_kind_is_uninitialized() {
    let out = run("let x; let e = x; e.type;"); // the error value's kind field is accessed via .type (consistent with type_system.rs style)
    assert_eq!(out.trim(), "Uninitialized");
}

#[test]
fn assignment_initializes_and_checks_annotation() {
    let out = run("let x: Number; x = 5; x;");
    assert_eq!(out.trim(), "5");
    let out = run("let x: Number; x = \"str\"; isError(x);");
    assert_eq!(out.trim(), "true");
}

#[test]
fn unannotated_let_no_check_on_assign() {
    let out = run("let x; x = \"str\"; x;");
    assert_eq!(out.trim(), "str");
}

#[test]
fn bad_annotation_errors_at_declaration() {
    let out = run("let x: 42; isError(x);");
    assert_eq!(out.trim(), "true");
}

#[test]
fn undefined_still_errors() {
    let out = run("foo; isError(foo);");
    assert_eq!(out.trim(), "true");
}
