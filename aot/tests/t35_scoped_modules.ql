let checks = 0;
let check = (ok, label) -> { checks = checks + 1; if !ok { println("FAIL " + label); }; };
let preserved: Number = 9;
let ns = import ./modules/scoped/exports.ql;
check(ns.chosen == 7 && chosen == 7, "conditional export");
check(!std.Object.hasOwn(ns)("absent") && !std.Object.hasOwn(ns)("preserved"), "skipped exports absent");
check(preserved == 9, "missing export preserves existing binding");
preserved = "bad";
check(preserved.type == "TypeCheck", "missing export preserves annotation");
preserved = 9;
check(absent.type == "UndefinedVariable", "missing export does not declare binding");
check(later == 5 && ns.later == 5, "export from called local function");
ns.publish(8);
check(ns.later == 8 && later == 5, "escaped function exports to defining module");
let part = ns.publishPartial(3); part(4);
check(ns.summed == 7 && summed.type == "UndefinedVariable", "partial export preserves module and import snapshot");
let loaded = load();
check(loaded.value == 42 && loaded.local == 42, "function import and definition-site path");
check(loaded.next() == 1 && loaded.next() == 2 && load().next() == 1, "fresh module frames from function imports");
check(branch(true) == 42 && branch(false) == 0, "conditional import");
if false { import ./modules/scoped/skip.ql; };
let use = () -> {
  let preserved = 11;
  if true {
    import ./modules/scoped/exports.ql;
    check(preserved == 11, "absent inner import falls back to outer binding");
    preserved = 12;
    check(preserved == 12, "assignment follows missing inner import outward");
  };
  preserved;
};
check(use() == 12, "outer owner receives assignment");
if true {
  let preserved;
  import ./modules/scoped/exports.ql;
  check(preserved.type == "Uninitialized", "missing export preserves explicit uninitialized declaration");
  preserved = 10; check(preserved == 10, "assignment initializes local declared binding");
};
check(preserved == 9, "block binding does not leak");
let factory = () -> { import ./modules/scoped/value.ql; () -> answer; };
check(factory()() == 42, "nested closure captures imported local");
let values = [import ./modules/scoped/value.ql, import ./modules/scoped/value.ql];
check(values[0].answer == 42 && answer == 42 && values[0].bump != values[1].bump, "imports inside array expressions");
let closures = []; let i = 0;
while i < 2 {
  import ./modules/scoped/value.ql;
  closures[i] = () -> bump();
  i = i + 1;
};
check(closures[0]() == 1 && closures[0]() == 2 && closures[1]() == 1, "iteration import frames stay separate");
let failed = () -> {
  import ./modules/scoped/exports.ql;
  absent = 1;
  println("FAIL assignment after absent import continued");
};
check(failed().type == "UndefinedVariable", "assignment cannot create absent imported binding");
if true {
  import ./modules/scoped/error_export.ql;
  check(isError(storedError) && storedError.message == "stored data", "exported Error is data, not an absent field");
};
println("scoped module checks: " + std.String.toString(checks));
