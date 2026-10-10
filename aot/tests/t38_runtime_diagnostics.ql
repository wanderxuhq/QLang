let checks = 0; let zero = 0; let three = 3;
let check = (ok, label) -> { checks = checks + 1; if !ok { println("FAIL " + label); }; };
let direct = 1 / zero;
check(direct.line == 3 && direct.col == 14, "division coordinates");
check(isError(direct.file) && direct.file.type == "UndefinedField", "no public file field");
check(isError(direct.trace) && direct.trace.type == "UndefinedField", "no public trace field");
let cached = Error.raise("cached");
let pass = () -> cached;
let first = pass();
let second = pass();
check(cached.line == 7 && cached.col == 14, "cached Error unchanged");
check(first.line == 7 && first.col == 14, "call retains error origin");
check(first.line == 7 && first.col == 14, "first call retains origin");
check(second.line == 7 && second.col == 14, "second call retains origin");
let trace = first.trace;
check(trace.type == "UndefinedField" && first.line == 7, "trace unavailable without changing Error");
let recur = (n) -> { if n == 0 { return cached; }; recur(n - 1); };
let recursive = recur(3);
check(recursive.line == 7 && recursive.col == 14, "recursive error retains origin");
let chained = direct + 1;
check(chained.line == 20 && chained.col == 15 && chained.cause.line == 3, "cause keeps its own origin");
let badDeclaration = () -> { let bad: Number = "x"; }; let bad = badDeclaration();
check(bad.type == "TypeCheck" && bad.line == 22 && bad.col == 30, "declaration annotation source");
let reassigned: Number = 1; let reassignBad = () -> { reassigned = "x"; };
let reassignError = reassignBad(); check(reassignError.type == "TypeCheck" && reassignError.line == 24, "assignment annotation source");
//
// An uninitialized read is now a frontend error, not a runtime value; the
// frontend diagnostic fixture covers it. Lines kept so later source positions
// below stay stable.
let index = [1][three];
check(index.type == "IndexOutOfBounds" && index.line == 30 && index.col == 13, "index source");
let field = ({}).missing;
check(field.type == "UndefinedField" && field.line == 32 && field.col == 14, "field source");
let libError = std.String.repeat("x")(-1);
check(isError(libError) && libError.line > 0 && libError.col > 0, "portable library error coordinates");
check(std.Error.toString(cached) == "Error: cached", "data error formatting preserved");
let i = 0; while i < 30000 { let garbage = [i, {n: i}]; i = i + 1; };
check(first.line == 7 && chained.cause.line == 3, "provenance survives allocations");
println("runtime source checks: " + std.String.toString(checks));
if args.length > 0 && args[0] == "fail" { chained?; };
if args.length > 0 && args[0] == "old-abi" { let old = import (args[1]); println(old.type); };
if args.length > 0 && args[0] == "cached" { cached?; };
if args.length > 0 && args[0] == "first" { first?; };
if args.length > 0 && args[0] == "second" { second?; };
if args.length > 0 && args[0] == "recursive" { recursive?; };
if args.length > 0 && args[0] == "library" { libError?; };
