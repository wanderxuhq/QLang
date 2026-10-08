#!/usr/bin/env bash
# Validate QLang BOOT / NATIVE output, fixed expectations, and optional Rust compatibility.
# QLANG=./target/release/qlang bash aot/run_v1_tests.sh [test.ql ...]
set -u -o pipefail
cd "$(dirname "$0")/.."
QLANG=${QLANG:-./target/debug/qlang}
TEST_TIMEOUT=${TEST_TIMEOUT:-180}
QLANG_CHECK_RUST=${QLANG_CHECK_RUST:-0}
work=$(mktemp -d "${TMPDIR:-/tmp}/qlang-aot-tests.XXXXXX")
trap 'rm -rf "$work"' EXIT
fail=0

check3() {
  local t="$1" name
  name=$(basename "$t" .ql)
  if ! timeout "$TEST_TIMEOUT" "$QLANG" bootstrapped/run_file.ql "$t" > "$work/boot_raw" 2> "$work/boot.err"; then
    echo "FAIL $name (BOOT)"
    cat "$work/boot.err"
    fail=1
    return
  fi
  awk '/^Interpreting\.\.\.$/ { body=1; next } body && !/^Execution complete\.$/ { print }' "$work/boot_raw" > "$work/boot"
  # Never execute a stale artifact after a failed compilation.
  rm -f "$work/native.bin"
  if ! timeout "$TEST_TIMEOUT" "$QLANG" --compile "$t" -o "$work/native.bin" > "$work/compile" 2>&1; then
    echo "FAIL $name (COMPILE)"
    cat "$work/compile"
    fail=1
    return
  fi
  if ! timeout "$TEST_TIMEOUT" "$work/native.bin" > "$work/native" 2> "$work/native.err"; then
    echo "FAIL $name (NATIVE)"
    cat "$work/native.err"
    fail=1
    return
  fi
  if [ -f "${t%.ql}.expected" ] && ! diff -u "${t%.ql}.expected" "$work/boot"; then
    echo "FAIL $name (BOOT CONTRACT)"
    fail=1
    return
  fi
  if [ "$QLANG_CHECK_RUST" = 1 ]; then
    if ! timeout "$TEST_TIMEOUT" "$QLANG" "$t" > "$work/host" 2> "$work/host.err"; then
      echo "FAIL $name (RUST COMPATIBILITY execution)"
      cat "$work/host.err"
      fail=1
      return
    fi
    if ! diff -u "$work/boot" "$work/host"; then
      echo "FAIL $name (RUST COMPATIBILITY output)"
      fail=1
      return
    fi
  fi
  if diff -u "$work/boot" "$work/native"; then
    echo "PASS $name"
  else
    echo "FAIL $name (OUTPUT)"
    fail=1
  fi
}

check_exits() {
  local source expected kind status engine
  while IFS='|' read -r expected kind source; do
    printf '%s\n' "$source" > "$work/exit.ql"
    rm -f "$work/exit.bin"
    if ! timeout "$TEST_TIMEOUT" "$QLANG" --compile "$work/exit.ql" -o "$work/exit.bin" > "$work/compile" 2>&1; then
      echo "FAIL exit (COMPILE $source)"
      cat "$work/compile"
      fail=1
      continue
    fi
    for engine in NATIVE HOST; do
      if [ "$engine" = HOST ] && [ "$QLANG_CHECK_RUST" != 1 ]; then continue; fi
      if [ "$engine" = HOST ]; then
        timeout "$TEST_TIMEOUT" "$QLANG" "$work/exit.ql" > "$work/exit.out" 2> "$work/exit.err"
      else
        timeout "$TEST_TIMEOUT" "$work/exit.bin" > "$work/exit.out" 2> "$work/exit.err"
      fi
      status=$?
      if [ "$status" -ne "$expected" ] || { [ "$expected" -eq 1 ] && ! grep -q "$kind" "$work/exit.err"; }; then
        echo "FAIL exit ($engine status=$status expected=$expected $source)"
        cat "$work/exit.err"
        fail=1
      else
        echo "PASS exit ($engine $source)"
      fi
    done
  done <<'CASES'
1|Uninitialized|let x; x;
1|Uninitialized|let x: Null; x?;
1|TypeCheck|let x: Number = null; x;
1|Uninitialized|let x; x; if false { 1; }; let y = 2;
0||let x; x = null; x;
0||let x; x ?? null;
0||let x; x; if true { let y = 2; };
0||let x; x; if false { 1; } else {};
CASES
}

if [ "${1:-}" = "--exit-checks" ]; then
  check_exits
elif [ "$#" -gt 0 ]; then
  for t in "$@"; do check3 "$t"; done
else
  for t in aot/tests/v1_*.ql aot/tests/hello.ql \
           aot/tests/t4_arith.ql aot/tests/t5_let.ql \
           aot/tests/t6_control.ql aot/tests/t6_nested_shortcircuit.ql \
           aot/tests/t7_factorial.ql aot/tests/t7_fib.ql \
           aot/tests/t10_control.ql aot/tests/t10_objects.ql aot/tests/t11_json.ql aot/tests/t12_calls.ql aot/tests/t13_bindings.ql aot/tests/t14_interpolation.ql aot/tests/t15_modules.ql aot/tests/t16_functions.ql aot/tests/t17_bootstrap.ql aot/tests/t19_literals.ql aot/tests/t20_native_bridge.ql aot/tests/t21_assignments.ql aot/tests/t22_lifetimes.ql aot/tests/t23_inline_values.ql aot/tests/t24_call_buffers.ql aot/tests/t25_numeric.ql aot/tests/t26_extrema.ql aot/tests/t27_native_calls.ql aot/tests/t28_objects.ql aot/tests/t29_arrays.ql aot/tests/t30_strings.ql aot/tests/t31_library_loading.ql aot/tests/t32_value_access.ql aot/tests/t33_builtin_bindings.ql aot/tests/t34_numeric_syntax.ql aot/tests/t35_scoped_modules.ql aot/tests/t36_lazy_modules.ql; do
    check3 "$t"
  done
  # Unsupported features must fail before invoking LLVM, with no executable.
  for source in 'import ./missing.ql;' 'println(missing);' 'missing = 1;' 'println(later); let later = 1;' 'if true { let local = 1; }; println(local);' 'println("${}");' 'println("${1 2}");' 'println("${1; 2}");' 'println(`unterminated);' 'println("${1");' 'println("${missing}");' 'println("${(1}");' 'println("${[1}");'; do
    printf '%s\n' "$source" > "$work/rejected.ql"
    rm -f "$work/rejected.bin"
    if timeout "$TEST_TIMEOUT" "$QLANG" --compile "$work/rejected.ql" -o "$work/rejected.bin" > "$work/rejected.log" 2>&1; then
      echo "FAIL diagnostic (accepted $source)"
      fail=1
    elif [ -e "$work/rejected.bin" ] || ! grep -q 'CompileError' "$work/rejected.log"; then
      echo "FAIL diagnostic ($source)"
      cat "$work/rejected.log"
      fail=1
    else
      echo "PASS diagnostic ($source)"
    fi
  done
  check_exits
fi
if [ "$fail" -eq 0 ]; then echo "AOT suite: ALL PASS"; else echo "AOT suite: FAILURES"; fi
exit "$fail"
