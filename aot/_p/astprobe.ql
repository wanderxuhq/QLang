import ../../bootstrapped/lexer.ql;
import ../../bootstrapped/modules.ql;
let text = std.fs.readFileText("aot/tests/t53_return_boundaries.ql")?;
let program = parseModule(text, "t53")?;
let walk = (node) -> {
  if AnyArray.check(node) { let i = 0; while i < node.length { walk(node[i]); i = i + 1; }; }
  else if AnyObject.check(node) {
    let t = node.type;
    if !isError(t) && t == "Let" && node.name == "identity" {
      let fn = node.value;
      println("let identity: value.type=" + (if isError(fn.type) { "ERR" } else { fn.type }));
      let params = fn.parameters;
      println("  parameters isError=" + std.String.toString(isError(params)));
      if !isError(params) {
        println("  params.length=" + std.Number.toString(params.length));
        let ann = params[0].annotation;
        println("  ann isError=" + std.String.toString(isError(ann)) + " null=" + std.String.toString(ann == null));
        if !isError(ann) && ann != null { println("  ann.type=" + (if isError(ann.type) { "ERR" } else { ann.type })); };
      };
    };
    let keys = std.Object.keys(node); let i = 0;
    while i < keys.length { walk(node[keys[i]]); i = i + 1; };
  };
};
walk(program.statements);
