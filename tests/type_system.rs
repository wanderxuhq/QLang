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
    // 注:std.Type.check 与全局 Number 属 Task 3 产物,此处用现有 std.Type.of 验证运行时行为
    assert_eq!(run("let x: std.Type = std.Number; std.Type.of(x) == \"Object\";"), "true");
    assert_eq!(run("let f = (a: Number) -> a + 1; f(5);"), "6");
    // 标注语法错误仍是解析错误(Err,不 panic)
    assert!(Interpreter::new().run_source("let x: ;", "t".into()).is_err());
}
