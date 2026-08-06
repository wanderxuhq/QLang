// tests/type_system.rs
use qlang::Interpreter;

fn run(src: &str) -> String {
    let mut interp = Interpreter::new();
    interp.run_source(src, "test".to_string())
        .expect("run failed")
        .to_string()
}

#[test]
fn smoke_baseline() {
    assert_eq!(run("1 + 2;"), "3");
    assert_eq!(run("let s = \"a\" + \"b\"; s;"), "ab");
}

#[test]
fn annotation_parses_as_expression() {
    // 标注是完整表达式:构造器调用、成员访问、对象字面量
    assert_eq!(run("let x: std.Type = Number; std.Type.check(x);"), "true");
    assert_eq!(run("let f = (a: Number) -> a + 1; f(5);"), "6");
    // 标注语法错误仍是解析错误(Err,不 panic)
    assert!(Interpreter::new().run_source("let x: ;", "t".into()).is_err());
}

#[test]
fn builtin_types_registered() {
    assert_eq!(run("Number.check(42);"), "true");
    assert_eq!(run("Number.check(\"a\");"), "false");
    assert_eq!(run("std.Type.of(42) == Number;"), "true");
    assert_eq!(run("std.Type.of(null) == Null;"), "true");
    assert_eq!(run("std.Type.of([1]) == AnyArray;"), "true");
    assert_eq!(run("std.Type.of({a: 1}) == AnyObject;"), "true");
    assert_eq!(run("std.Type.of(Number) == std.Type;"), "true");   // Type : Type
    assert_eq!(run("std.Type.of(std.Type) == std.Type;"), "true"); // 自指
    assert_eq!(run("std.Type.check(Number);"), "true");
    assert_eq!(run("std.Type.check(42);"), "false");
    assert_eq!(run("std.Type.make((v) -> v > 0).check(5);"), "true");
    assert_eq!(run("let e = Error.raise(\"boom\"); std.Type.of(e) == Error;"), "true");
}
