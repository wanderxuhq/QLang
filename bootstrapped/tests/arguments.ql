// The documented script args binding belongs to each interpreter instance.
import ../interpreter.ql;
let check = (ok, label) -> {
  if !ok { return std.Error.raise("AssertionFailed", label, null); };
  null;
};
let engine = Interpreter();
let initial = engine.globalEnv._get("args");
check(initial.type == "Array" && initial.value.length == 0, "default empty arguments")?;
let supplied = ["first", "", "中文"];
engine.setArguments(supplied)?;
let bound = engine.globalEnv._get("args");
check(bound.type == "Array" && bound.value.length == 3, "argument array")?;
check(bound.value[0].type == "String" && bound.value[0].value == "first", "wrapped string")?;
check(bound.value[1].value == "" && bound.value[2].value == "中文", "empty and Unicode strings")?;
supplied[0] = "host changed";
check(bound.value[0].value == "first", "input copied")?;
check(isError(engine.setArguments(12)), "reject non-array")?;
check(engine.globalEnv._get("args").value[0].value == "first", "invalid array preserves binding")?;
check(isError(engine.setArguments(["valid", 12])), "reject non-string element")?;
check(engine.globalEnv._get("args").value.length == 3, "validation is atomic")?;
let other = Interpreter();
check(other.globalEnv._get("args").value.length == 0, "independent interpreter arguments")?;
println("PASS interpreter argument API: 10 checks");
