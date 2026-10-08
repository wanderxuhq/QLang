use qlang::{Interpreter, value::Value};

#[test]
fn shared_object_contract() {
    let source = concat!(include_str!("../aot/tests/t28_objects.ql"),
                         "\nchecks == 98;");
    let value = Interpreter::new().run_source(source, "Object contracts".to_string()).unwrap();
    assert!(matches!(value, Value::Boolean(true)), "{value:?}");
}
