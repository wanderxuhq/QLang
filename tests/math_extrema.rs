use qlang::{Interpreter, value::Value};

#[test]
fn shared_variadic_extrema_contract() {
    let source = concat!(include_str!("../aot/tests/t26_extrema.ql"),
                         "\nfailures == 0 && checks == 51;");
    let path = std::path::Path::new(env!("CARGO_MANIFEST_DIR"))
        .join("aot/tests/t26_extrema.ql");
    let value = Interpreter::new().run_source(source, path.to_string_lossy().into_owned()).unwrap();
    assert!(matches!(value, Value::Boolean(true)), "{value:?}");
}
