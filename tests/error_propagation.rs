use qlang::{Interpreter, value::Value};

fn run(source: &str) -> Value {
    Interpreter::new().run_source(source, "propagation regression".to_string()).unwrap()
}

#[test]
fn successful_propagation_evaluates_operand_once() {
    let result = run("let n = 0; let f = () -> { n = n + 1; n; }; let v = f()?; n * 10 + v;");
    assert_eq!(result.to_string(), "11");
}

#[test]
fn propagation_uses_first_error_without_retrying_operand() {
    let result = run(r#"
        let n = 0;
        let f = () -> { n = n + 1; if n == 1 { std.Error.raise("First", "failure", null); } else { 42; }; };
        let g = () -> { f()?; 99; };
        let error = g();
        isError(error) && error.type == "First" && n == 1;
    "#);
    assert!(matches!(result, Value::Boolean(true)), "{result:?}");
}

#[test]
fn nested_propagation_preserves_order_and_single_evaluation() {
    let result = run("let n = 0; let f = () -> { n = n + 1; n; }; let v = (f()? + f()?)?; n * 10 + v;");
    assert_eq!(result.to_string(), "23");
}
