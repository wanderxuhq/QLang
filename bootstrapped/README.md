# QLang core

This directory contains the core language implementation in QLang. The name
`bootstrapped` describes its origin, not a secondary status relative to Rust.

- `lexer.ql`, `parser.ql`, `ast.ql`: shared frontend and AST contract.
- `interpreter.ql`, `environment.ql`, `stdlib.ql`: interpreted execution.
- `modules.ql`: shared module parsing and path handling.
- `../aot/qlangc.ql`, `../aot/runtime.ql`: LLVM emission and native runtime in QLang.

Syntax sugar belongs in the frontend. For example, `x -> x + 1` and
`(x) -> x + 1` produce the same Function node with a Parameter and Block body.
Both the interpreter and LLVM backend consume that AST.

Language contracts are explicit tests and intended semantics. Rust and Node
comparisons help find discrepancies; neither implementation automatically wins.
A declaration without an initializer creates a binding only. Reading it before
assignment produces `Uninitialized`; undeclared names fail AOT compilation.
`null` is an initialized value of type `Null`. There is no `undefined` value.

The Rust executable can run these QLang sources and supply bootstrap APIs.
It is retained for bootstrap, compatibility and future library embedding.
The native compiler now rebuilds itself without the Rust runner after the
initial bootstrap. Stage 2/3 compiler IR is verified byte-identical; Clang still
performs the LLVM-to-machine-code and link steps.

Run frontend contracts and native execution checks from the repository root:

```sh
./target/release/qlang bootstrapped/tests/function_ast.ql
QLANG=./target/release/qlang bash aot/run_v1_tests.sh
QLANG=./target/release/qlang python3 aot/run_module_tests.py
# Optional retained-Rust compatibility checks:
QLANG=./target/release/qlang QLANG_CHECK_RUST=1 bash aot/run_v1_tests.sh
```

The AST test executes the QLang parser with concrete expected ASTs; it does not
compare against the Rust parser. Native fixtures with `.expected` files check
fixed results as well as agreement between the two QLang execution paths.

Native bootstrap progress and reproducible stage checks are documented in
[the AOT guide](../aot/README.md#native-bootstrap-checks). The core frontend's
AST contracts now also run as a native executable. Standard-library namespace
tables are private to each interpreted module; user mutations cannot rewrite
the interpreter's own formatting and file APIs.

The interpreter can now be built as a native executable too. See the
[native interpreter gate](../aot/README.md#native-core-interpreter) for the
command. It runs QLang files and evaluates their literal source imports without
the Rust runner. Computed `import (path)` loads separately compiled native
extensions through the native host's private value bridge. Functions, callbacks,
canonical types and shared mutable objects retain their language behavior across
that boundary. Hosts without this bridge, including the retained Rust bootstrap
host, return `NativeExtensionUnavailable`. Unhandled errors, including
uninitialized reads, return exit status 1;
explicit `null` and handled errors remain successful executions.

Field and index writes validate the receiver and index, preserve right-side-first
evaluation, and propagate failed writes out of the current function/module.
The same fixed [assignment contracts](../aot/tests/t21_assignments.ql) run on
the interpreter and LLVM paths; valid writes may store Error values as data.


Native calls use an internal argument-list bridge to the hosting runtime's
ordinary dispatcher. There is no four-argument limit or implicit conversion of
extra arguments into an Array. Arity, Error policy and native partial metadata
remain attached to the target function. The [native-call contract](../aot/tests/t27_native_calls.ql)
covers both the native and Rust-hosted core. This internal bootstrap ABI does
not introduce source-level argument spreading or change user-function calls.

The script argument contract is the same as in the main README: run
`native-interpreter script.ql first second` (or the retained host followed by
`bootstrapped/run_file.ql script.ql first second`) and the script sees
`args` containing the two strings `"first"` and `"second"`. No arguments gives an empty Array.
Imports have their own lexical `args` binding backed by the process argument
Array; shadowing or rebinding affects that binding, and element mutations are
shared. `aot/run_argument_tests.py --interpreter /path/to/native-interpreter`
checks the CLI, nested imports, local scopes, empty strings and Unicode.
