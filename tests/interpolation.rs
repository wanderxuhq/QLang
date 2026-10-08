use qlang::{Interpreter, lexer::Lexer, parser::Parser};

fn eval(source: &str) -> String {
    Interpreter::new().run_source(source, "interpolation regression".into()).unwrap().to_string()
}

#[test]
fn interpolation_uses_complete_expression_lexer() {
    assert_eq!(eval(r#"`a=${ {"key": "}"}.key } b=${ ((x) -> { x + 1; })(2) } c=${ 1 /* } */ + 2 }`;"#), "a=} b=3 c=3");
    assert_eq!(eval("`value=${\n if true { 4; } else { 5; }\n}`;"), "value=4");
}

#[test]
fn nested_templates_and_same_quote_strings() {
    assert_eq!(eval(r#""${"same quote"} ${`inner ${'nested'}`}";"#), "same quote inner nested");
    assert_eq!(eval(r#"'${"double"} ${'single'}';"#), "double single");
    assert_eq!(eval(r#"`escaped \` and \${literal}`;"#), "escaped ` and ${literal}");
}

#[test]
fn interpolations_run_once_in_order_and_propagate() {
    assert_eq!(eval(r#"let n = 0; let next = () -> { n = n + 1; n; }; let s = "${next()}${next()?}${next()}"; "${s}:${n}";"#), "123:3");
    assert_eq!(eval(r#"let n = 0; let next = () -> { n = n + 1; n; }; let f = () -> "${next()}${(1 / 0)?}${next()}"; let e = f(); isError(e) && n == 1;"#), "true");
}

#[test]
fn interpolation_retains_value_rendering() {
    assert_eq!(eval(r#""${[1, true, null, {a: "x"}]} ${() -> 1}";"#), "[1, true, null, {a: x}] <function>");
}

#[test]
fn malformed_interpolations_and_templates_are_rejected() {
    for source in ["`unterminated", "`trailing\\", r#""${1 2}""#, r#""${}""#, r#""${1; 2}""#, "`${1", "`${{a: 1}", r#""${(1}""#, r#""${[1}""#] {
        let parsed = Lexer::new(source).tokenize().map(|tokens| Parser::new(tokens, source.into()).parse().is_err());
        assert!(parsed.unwrap_or(true), "accepted {source:?}");
    }
}

#[test]
fn nested_string_tokens_preserve_outer_span() {
    let source = r#""中${"文"}末";"#;
    let tokens = Lexer::new(source).tokenize().unwrap();
    assert_eq!(tokens[0].span.start, 0);
    assert_eq!(tokens[0].span.end, source.len() - 1);
}
