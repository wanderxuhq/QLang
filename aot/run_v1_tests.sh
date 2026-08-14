#!/usr/bin/env bash
# v1 测试集 HOST/BOOT/NATIVE 三端逐字节一致
# 用法:bash aot/run_v1_tests.sh
set -u
QLANG=${QLANG:-./target/debug/qlang}
cd "$(dirname "$0")/.."
fail=0

check3() {
  t="$1"
  name=$(basename "$t" .ql)
  # HOST
  $QLANG "$t" > /tmp/v1_${name}.host 2>&1
  # BOOT(剥离 12 行 banner + Execution complete.)
  $QLANG bootstrapped/run_file.ql "$t" > /tmp/v1_${name}.boot_raw 2>&1
  tail -n +13 /tmp/v1_${name}.boot_raw | grep -v '^Execution complete\.' > /tmp/v1_${name}.boot
  # NATIVE
  $QLANG --compile "$t" -o /tmp/v1_${name}.bin >/dev/null 2>&1
  /tmp/v1_${name}.bin > /tmp/v1_${name}.native
  if diff -q /tmp/v1_${name}.host /tmp/v1_${name}.native >/dev/null \
     && diff -q /tmp/v1_${name}.host /tmp/v1_${name}.boot >/dev/null; then
    echo "PASS $name"
  else
    echo "FAIL $name"
    diff /tmp/v1_${name}.host /tmp/v1_${name}.native
    diff /tmp/v1_${name}.host /tmp/v1_${name}.boot
    fail=1
  fi
}

echo "== v1 suite =="
for t in aot/tests/v1_*.ql; do
  check3 "$t"
done

echo "== regression (t-series) =="
for t in aot/tests/hello.ql aot/tests/t4_arith.ql aot/tests/t5_let.ql \
         aot/tests/t6_control.ql aot/tests/t6_nested_shortcircuit.ql \
         aot/tests/t7_factorial.ql aot/tests/t7_fib.ql; do
  check3 "$t"
done

echo "---"
if [ $fail -eq 0 ]; then echo "v1 suite: ALL PASS"; else echo "v1 suite: FAILURES"; exit 1; fi
