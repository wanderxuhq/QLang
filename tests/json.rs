use qlang::{Interpreter, value::Value};

fn run(source: &str) -> Value {
    Interpreter::new().run_source(source, "json regression".to_string()).unwrap()
}

#[test]
fn unicode_json_strings_and_object_fields() {
    assert_eq!(run(r#"std.JSON.parse('\"中文é😀\"');"#).to_string(), "中文é😀");
    assert_eq!(run(r#"std.JSON.parse('{\"键\":\"中文😀\"}')["键"];"#).to_string(), "中文😀");
    assert_eq!(run(r#"std.JSON.parse('\"\\u4e2d\\u6587\\ud83d\\ude00\"');"#).to_string(), "中文😀");
}

#[test]
fn json_arrays_preserve_string_boundaries_and_nested_values() {
    let value = run(r#"let a = std.JSON.parse('["a,b", "", {"x": [true, null, -1.25e2]}, "a\\\"b"]');
        a[0] == "a,b" && a[1] == "" && a[2].x[0] == true && a[2].x[1] == null && a[2].x[2] == -125 && a[3] == 'a"b';"#);
    assert!(matches!(value, Value::Boolean(true)), "{value:?}");
}

#[test]
fn invalid_json_returns_error_instead_of_panicking_or_partial_success() {
    // Feed inputs through a variable so the QLang lexer cannot mask malformed JSON.
    let inputs = ["", "{", "[", "\"", "{中", "[中", "\"中文", "[1,]", "{\"x\":}",
        "{\"x\":1,}", "[1 2]", "true false", "01", "1.", "+1", "NaN", "1e", "null x",
        "\"\\q\"", "\"\\u中123\"", "\"\\ud800\"", "\"\\udc00\"", "\"\\ud800\\u0041\"", "\"a\nb\""];
    for input in inputs {
        let quoted = input.replace('\\', "\\\\").replace('\'', "\\'").replace('\n', "\\n");
        let result = run(&format!("isError(std.JSON.parse('{quoted}'));"));
        assert!(matches!(result, Value::Boolean(true)), "accepted {input:?}: {result:?}");
    }
}

#[test]
fn json_stringify_round_trips_control_characters() {
    let result = run(r#"let s = "中文\u0000\b\f\n\r\t\\\""; std.JSON.parse(std.JSON.stringify(s)) == s;"#);
    assert!(matches!(result, Value::Boolean(true)), "{result:?}");
    assert_eq!(run("std.JSON.stringify(std.Number.parseFloat(\"bad\"));").to_string(), "null");
}

#[test]
fn excessive_json_nesting_is_an_error() {
    let input = format!("{}0{}", "[".repeat(256), "]".repeat(256));
    assert!(matches!(run(&format!("std.JSON.parse('{input}');")), Value::Error(_)));
}

#[test]
fn json_stringify_rejects_cycles_without_stack_overflow() {
    for source in ["let a = []; a[0] = a; isError(std.JSON.stringify(a));",
                   "let o = {}; o.self = o; isError(std.JSON.stringify(o));"] {
        assert!(matches!(run(source), Value::Boolean(true)));
    }
}
