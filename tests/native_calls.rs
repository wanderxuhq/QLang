use qlang::{Interpreter, value::Value};

#[test]
fn shared_native_call_contract() {
    let source = concat!(include_str!("../aot/tests/t27_native_calls.ql"),
                         "\nfailures == 0 && checks == 33;");
    let value = Interpreter::new().run_source(source, "native calls".to_string()).unwrap();
    assert!(matches!(value, Value::Boolean(true)), "{value:?}");
}
