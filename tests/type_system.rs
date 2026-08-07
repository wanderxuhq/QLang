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
    // Annotations are full expressions: constructor calls, member access, object literals
    assert_eq!(run("let x: std.Type = Number; std.Type.check(x);"), "true");
    assert_eq!(run("let f = (a: Number) -> a + 1; f(5);"), "6");
    // Annotation syntax errors are still parse errors (Err, not panic)
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
    assert_eq!(run("std.Type.of(std.Type) == std.Type;"), "true"); // self-reference
    assert_eq!(run("std.Type.check(Number);"), "true");
    assert_eq!(run("std.Type.check(42);"), "false");
    assert_eq!(run("std.Type.make((v) -> v > 0).check(5);"), "true");
    assert_eq!(run("let e = Error.raise(\"boom\"); std.Type.of(e) == Error;"), "true");
}

#[test]
fn protected_members_are_read_only() {
    // Overriding a core member → runtime error (assignment is a statement; errors go
    // through the exception channel, consistent with set_field's NotAnObject; `x = v` cannot be used as an expression)
    assert!(Interpreter::new().run_source("Number.check = 42;", "t".into()).is_err());
    assert!(Interpreter::new().run_source("Error.raise = 1;", "t".into()).is_err());
    assert!(Interpreter::new().run_source("std.Type.of = 1;", "t".into()).is_err());
    // Freely mounting new members works as before
    assert_eq!(run("Number.myHelper = 1; Number.myHelper;"), "1");
    // User types are not protected
    assert_eq!(run("let T = std.Type.make((v) -> true); T.check = 42; std.Type.check(T);"), "false");
    // Marker fields do not leak
    assert_eq!(run("std.Object.keys(Number).length;"), "1");  // only check
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
    // cause chain: the value being checked is itself an error value
    assert_eq!(run("let x: Number = Error.raise(\"boom\"); x.cause.type;"), "Error");
    // The annotation is not a type value
    assert_eq!(run("let T = 42; let x: T = 5; isError(x);"), "true");
    // User-defined types
    assert_eq!(run("let Positive = std.Type.make((v) -> v > 0); let x: Positive = 5; x;"), "5");
    assert_eq!(run("let Positive = std.Type.make((v) -> v > 0); let x: Positive = -5; isError(x);"), "true");
    // check itself erroring → failure
    assert_eq!(run("let Bad = std.Type.make((v) -> 1 / 0); let x: Bad = 5; isError(x);"), "true");
    // No annotation = fully dynamic
    assert_eq!(run("let x = \"a\"; x;"), "a");
}

#[test]
fn param_annotations_checked_at_call() {
    assert_eq!(run("let f = (a: Number) -> a + 1; f(5);"), "6");
    assert_eq!(run("let f = (a: Number) -> a + 1; let r = f(\"x\"); isError(r);"), "true");
    assert_eq!(run("let f = (a: Number) -> a + 1; let r = f(\"x\"); r.type;"), "TypeCheck");
    // Check failure → the function body does not run
    assert_eq!(run("let f = (a: Number) -> { 1 / 0; }; let r = f(\"x\"); isError(r);"), "true");
    // Multiple params (QLang has no automatic Number+String concatenation; use std.Number.toString for explicit conversion)
    assert_eq!(run("let f = (a: Number, b: String) -> std.Number.toString(a) + b; f(1, \"x\");"), "1x");
    assert_eq!(run("let f = (a: Number, b: String) -> a + b; let r = f(\"x\", \"y\"); isError(r);"), "true");
    // Annotations are evaluated at definition time (they may reference outer variables)
    assert_eq!(run("let T = Number; let f = (a: T) -> a; f(1);"), "1");
    // After shadowing, the annotation evaluates to the shadowing value
    assert_eq!(run("let Number = 42; let f = (a: Number) -> a; let r = f(1); isError(r);"), "true");
}

#[test]
fn reassignment_rechecks_annotation() {
    assert_eq!(run("let x: Number = 42; x = 100; x;"), "100");
    assert_eq!(run("let x: Number = 42; x = \"a\"; isError(x);"), "true");
    assert_eq!(run("let x: Number = 42; x = \"a\"; x.type;"), "TypeCheck");
    // Unannotated variables work as usual
    assert_eq!(run("let x = 42; x = \"a\"; x;"), "a");
    // Annotated function params are re-checked on reassignment inside the body
    assert_eq!(run("let f = (a: Number) -> { a = \"x\"; return a; }; let r = f(1); isError(r);"), "true");
}

#[test]
fn array_constructor_union_params() {
    // Type member: element type
    assert_eq!(run("let x: Array(Number) = [1, 2]; x;"), "[1, 2]");
    assert_eq!(run("let x: Array(Number) = [1, \"a\"]; isError(x);"), "true");
    // Number member: fixed length
    assert_eq!(run("let x: Array(3) = [1, 2, 3]; x;"), "[1, 2, 3]");
    assert_eq!(run("let x: Array(3) = [1, 2]; isError(x);"), "true");
    // [Type] member: per-position types (tuple)
    assert_eq!(run("let x: Array([Number, String]) = [1, \"a\"]; x;"), "[1, a]");
    assert_eq!(run("let x: Array([Number, String]) = [1, 2]; isError(x);"), "true");
    // Metadata member: {length, element}
    assert_eq!(run("let x: Array({length: 2, element: Number}) = [1, 2]; x;"), "[1, 2]");
    assert_eq!(run("let x: Array({length: 2, element: Number}) = [1]; isError(x);"), "true");
    // Invalid shape → error value from the constructor
    assert_eq!(run("let x = Array(3.5); isError(x);"), "true");
    assert_eq!(run("let x = Array([1, 2]); isError(x);"), "true"); // non-type inside [Type]
    // Nesting + user types
    assert_eq!(run("let Positive = std.Type.make((v) -> v > 0); let x: Array(Positive) = [1, 2]; x;"), "[1, 2]");
}

#[test]
fn object_constructor_union_params() {
    // Type member: all keys are T (Object(String) ≡ AnyObject)
    // Note: the host renders objects in HashMap hash order (not insertion order), so whole-value render assertions for a 2-field object accept only the two orderings
    let r = run("let x: Object(String) = {a: 1, b: \"s\"}; x;");
    assert!(r == "{a: 1, b: s}" || r == "{b: s, a: 1}", "unexpected render: {}", r);
    assert_eq!(run("let x: Object(String) = Number; isError(x);"), "true"); // a type object is not an Object
    // schema member: required fields are a subset, extra fields allowed
    let r = run("let x: Object({name: String}) = {name: \"a\", age: 1}; x;");
    assert!(r == "{name: a, age: 1}" || r == "{age: 1, name: a}", "unexpected render: {}", r);
    assert_eq!(run("let x: Object({name: String}) = {age: 1}; isError(x);"), "true"); // missing field
    assert_eq!(run("let x: Object({name: String}) = {name: 1}; isError(x);"), "true"); // field type mismatch
    // schema constructor validation
    assert_eq!(run("let x = Object({bad: 42}); isError(x);"), "true");
    // Nested schema
    assert_eq!(run("let x: Object({user: Object({name: String})}) = {user: {name: \"a\"}}; x;"), "{user: {name: a}}");
}

#[test]
fn object_merge_does_not_copy_type_marker() {
    // Merging into a type object does not carry TYPE_MARKER: the result is not a protected object, so check is overridable (recorded in Task 7; fixed incidentally in this task)
    assert_eq!(run("let m = std.Object.merge(Number)({x: 1}); m.check = 42; m.check;"), "42");
    assert_eq!(run("let m = std.Object.merge({x: 1})(Number); m.check = 42; m.check;"), "42");
}
