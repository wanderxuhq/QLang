use qlang::{Interpreter, value::Value};

#[test]
fn keyword_properties_support_reads_writes_and_calls() {
    let result = Interpreter::new().run_source(r#"
        let o = { if: 1, null: 2, return: (n) -> n + 1 };
        o.if = 4;
        o.if == 4 && o.null == 2 && o.return(5) == 6;
    "#, "member test".to_string()).unwrap();
    assert!(matches!(result, Value::Boolean(true)));
}

#[test]
fn keywords_remain_reserved_as_variable_names() {
    assert!(Interpreter::new().run_source("let if = 1;", "member test".to_string()).is_err());
}
