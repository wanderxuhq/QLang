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

#[test]
fn protected_members_are_read_only() {
    // 覆盖核心成员 → 运行时错误(赋值是语句,错误经异常通道,与 set_field 的
    // NotAnObject 一致;`x = v` 不能作为表达式)
    assert!(Interpreter::new().run_source("Number.check = 42;", "t".into()).is_err());
    assert!(Interpreter::new().run_source("Error.raise = 1;", "t".into()).is_err());
    assert!(Interpreter::new().run_source("std.Type.of = 1;", "t".into()).is_err());
    // 自由挂载新成员照旧
    assert_eq!(run("Number.myHelper = 1; Number.myHelper;"), "1");
    // 用户类型不受保护
    assert_eq!(run("let T = std.Type.make((v) -> true); T.check = 42; std.Type.check(T);"), "false");
    // 标记字段不泄漏
    assert_eq!(run("std.Object.keys(Number).length;"), "1");  // 只有 check
}

#[test]
fn type_of_returns_type_values() {
    assert_eq!(run("std.Type.of(42) == Number;"), "true");
    assert_eq!(run("std.Type.of(\"a\") == String;"), "true");
    assert_eq!(run("std.Type.of(true) == Boolean;"), "true");
    assert_eq!(run("std.Type.of(null) == Null;"), "true");
    assert_eq!(run("std.Type.of([1]) == AnyArray;"), "true");
    assert_eq!(run("std.Type.of({}) == AnyObject;"), "true");
    assert_eq!(run("std.Type.of(() -> 1) == Function;"), "true");
    assert_eq!(run("std.Type.of(Error.raise(\"x\")) == Error;"), "true");
    assert_eq!(run("std.Type.of(Number) == std.Type;"), "true");
}

#[test]
fn let_annotation_checks() {
    assert_eq!(run("let x: Number = 42; x;"), "42");
    assert_eq!(run("let x: Number = \"a\"; isError(x);"), "true");
    assert_eq!(run("let x: Number = \"a\"; x.type;"), "TypeCheck");
    assert_eq!(run("let x: Error = Error.raise(\"boom\"); x.message;"), "boom");
    assert_eq!(run("let x: Number = Error.raise(\"boom\"); isError(x);"), "true");
    // cause 链:被检查值本身是错误值
    assert_eq!(run("let x: Number = Error.raise(\"boom\"); x.cause.type;"), "Error");
    // 标注不是类型值
    assert_eq!(run("let T = 42; let x: T = 5; isError(x);"), "true");
    // 用户自定义类型
    assert_eq!(run("let Positive = std.Type.make((v) -> v > 0); let x: Positive = 5; x;"), "5");
    assert_eq!(run("let Positive = std.Type.make((v) -> v > 0); let x: Positive = -5; isError(x);"), "true");
    // check 自身出错 → 失败
    assert_eq!(run("let Bad = std.Type.make((v) -> 1 / 0); let x: Bad = 5; isError(x);"), "true");
    // 无标注 = 完全动态
    assert_eq!(run("let x = \"a\"; x;"), "a");
}

#[test]
fn param_annotations_checked_at_call() {
    assert_eq!(run("let f = (a: Number) -> a + 1; f(5);"), "6");
    assert_eq!(run("let f = (a: Number) -> a + 1; let r = f(\"x\"); isError(r);"), "true");
    assert_eq!(run("let f = (a: Number) -> a + 1; let r = f(\"x\"); r.type;"), "TypeCheck");
    // 检查失败 → 函数体不执行
    assert_eq!(run("let f = (a: Number) -> { 1 / 0; }; let r = f(\"x\"); isError(r);"), "true");
    // 多参数(QLang 无 Number+String 自动拼接,用 std.Number.toString 显式转换)
    assert_eq!(run("let f = (a: Number, b: String) -> std.Number.toString(a) + b; f(1, \"x\");"), "1x");
    assert_eq!(run("let f = (a: Number, b: String) -> a + b; let r = f(\"x\", \"y\"); isError(r);"), "true");
    // 标注在定义时求值(引用外层变量)
    assert_eq!(run("let T = Number; let f = (a: T) -> a; f(1);"), "1");
    // 遮蔽后标注求值指向遮蔽值
    assert_eq!(run("let Number = 42; let f = (a: Number) -> a; let r = f(1); isError(r);"), "true");
}

#[test]
fn reassignment_rechecks_annotation() {
    assert_eq!(run("let x: Number = 42; x = 100; x;"), "100");
    assert_eq!(run("let x: Number = 42; x = \"a\"; isError(x);"), "true");
    assert_eq!(run("let x: Number = 42; x = \"a\"; x.type;"), "TypeCheck");
    // 无标注的变量照常
    assert_eq!(run("let x = 42; x = \"a\"; x;"), "a");
    // 函数参数带标注,体内重赋值再查
    assert_eq!(run("let f = (a: Number) -> { a = \"x\"; return a; }; let r = f(1); isError(r);"), "true");
}
