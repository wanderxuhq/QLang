use qlang::{Interpreter, value::Value};

fn run(source: &str) -> Value {
    Interpreter::new().run_source(source, "unicode regression".to_string()).unwrap()
}

#[test]
fn code_point_at_uses_unicode_scalar_indices() {
    let result = run(r#"let at = std.String.codePointAt("aé中😀");
        at(0) == 97 && at(1) == 233 && at(2) == 20013 && at(-1) == 128512;"#);
    assert!(matches!(result, Value::Boolean(true)));
}

#[test]
fn code_point_at_rejects_invalid_indices_and_arguments() {
    for source in [r#"std.String.codePointAt("x")(1)"#, r#"std.String.codePointAt("x")(-2)"#,
        r#"std.String.codePointAt("x")(0.5)"#, r#"std.String.codePointAt(42)"#,
        r#"std.String.codePointAt("x")("0")"#, r#"std.String.codePointAt("")(0)"#] {
        assert!(matches!(run(source), Value::Error(_)), "{source}");
    }
}
