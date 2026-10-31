# Python 移除记录(2026-10-31)

本仓库的工具链、测试驱动与数据生成器已全部改用 QLang / shell / clang。
仓库中不再有 `.py` 文件;`rust-error-model` 分支上的这一笔是删除点。

## 1. 为什么现在可以删

- 编译器、链接器、标准库对象、bundle 重建、原生/解释器/自举/差分/扩展/基准驱动
  都已经是 QLang 程序,经 `target/selfhost/stage2` + `target/tools/link` 构建。
- 原 Python 套件的独有断言已逐条移植;不是"删测试换绿"。
- 冻结数据:difftest 的 291 个源、fuzzexpr 的 390 个用例、数值 792 行、
  Unicode 15.1 表都由 QLang 驱动消费;数据文件在 `aot/tests/data/` 与 `third_party/ucd/`。

## 2. 替换矩阵

| 原 Python | 现 QLang | 覆盖/验收 |
|---|---|---|
| `aot/run_selfhost_tests.py` | `aot/run_selfhost.ql` + `aot/run_compiler.ql` | 57 split 用例、stage2/3 固定点、新 stage2 跑 t16;CLI 拒绝 7、return 作用域 4、assert 致命、6 前端 fixture |
| `aot/run_interpreter_tests.py` | `aot/run_tests.ql --interpreter` + `aot/run_interpreter_contracts.ql` | 42 夹具;assert 致命、type_gymnastics 419/419、函数 import、13 负例、2 正例、cwd 隔离、参数 CLI 15 行 |
| `aot/run_debug_diff_tests.py` | `aot/run_diff.ql` | 57 用例 debug/release 输出+退出码一致 |
| `aot/run_assignment_tests.py` | `aot/run_diagnostics.ql` | 15 个顶层失败面、failed module 不发布 export、t21 双引擎 |
| `aot/run_semantic_diagnostic_tests.py` | 同上 | 11 个编译错误的精确 `file:line:col` 与消息 |
| `aot/run_diagnostic_tests.py` | 同上 | 12 解析 + 19 数字字面量 + 5 return 作用域,compiler+core |
| `aot/run_runtime_diagnostic_tests.py` | 同上 | t38/t39 的 argv 模式、精确 `  at ` 帧、解释器面 |
| `aot/run_source_context_tests.py` | 同上 | t40 / native_source_bridge 的 12+6 上下文模式 |
| `aot/run_module_tests.py` | `aot/run_modules.ql` | t15 boot/native、删源码、6 拒绝、2 循环、未处理初始化错误 |
| `aot/run_scoped_module_tests.py` | 同上 | t35 O0/O2 + 解释器 + 删源码 + 3 作用域拒绝 |
| `aot/run_lazy_module_tests.py` | 同上 | t36 O0/O2 + active/inactive root |
| `aot/run_extension_tests.py` | `aot/run_extension.ql` | host×ext 4 组合、28 契约、DSO IR/ELF 校验、stderr、cwd |
| `aot/run_extension_bridge_tests.py` | `aot/run_extension_bridge.ql` | t37/bridge 共 6 组 native + 4 组解释器、24 个诊断模式、134 项 |
| `aot/run_gc_tests.py` | `aot/run_gc.ql` | allocator O0/O2、t18 O0/O2、stderr 空 |
| `aot/run_lifetime_tests.py` | `aot/run_lifetime.ql` | entry-only alloca、100000 次 1 MiB 栈、ql_alloc 计数相等 |
| `aot/run_link_tests.py` | `aot/run_link.ql` + 严格 `aot/verify.ql` | 3 字符串 O0/O2、6 种坏 ELF、原子发布、无临时残留 |
| `aot/run_bundle_tests.py` | `aot/run_bundle.ql` | 混合换行/Unicode 分隔符/空模块/无末尾换行/分块 JSON/--check |
| `aot/run_platform_tests.py` | `aot/run_platform.ql` + `aot/tests/t65_fs_contracts.ql` | argv、UTF-8、规范路径、fd 清理 |
| `aot/run_array_tests.py` | `aot/run_value_contracts.ql` | t29 O0/O2、8 错误探针、可移植 Array 重写 |
| `aot/run_object_tests.py` | 同上 | t28 O0/O2、8 错误探针 |
| `aot/run_call_tests.py` | 同上 | t27/t24 O0/O2、20000 次压力、entry alloca、分配计数、legacy runtime |
| `aot/run_numeric_tests.py` | `aot/run_numeric.ql` + `aot/tests/data/numeric_oracle.ql` | 792 行、O0/O2、ULP、libm 符号、熵故障 |
| `aot/run_json_numeric_tests.py` | `aot/run_value_contracts.ql` | 30 个十进制边界 host/native 逐字节 |
| `aot/run_argument_tests.py` | `aot/run_interpreter_contracts.ql` | 3 场景 15 行参数契约 |
| `bench/run_bench.py` | `aot/run_bench.ql` | insns、front/clang、min wall、child CPU、输出一致 |
| `stdlib/run_string_tests.py` | `aot/run_string.ql` + `aot/unicode_oracle.ql` | t30 O0/O2/解释器、全平面 UCD oracle、4 错误、静态边界 |
| `difftest.py` | `aot/run_semantics_diff.ql` + `aot/tests/data/semantics_corpus.ql` | 291 源冻结;228 native-vs-interp 通过,63 个已知不可裁决/引擎差异显式跳过 |
| `fuzzexpr.py` | `aot/run_fuzz.ql` + `aot/tests/data/fuzz_corpus.ql` | 390 例冻结期望,native O0/O2 + 解释器 |
| `aot/native_link.py` | `aot/link.ql` / `aot/verify.ql` | 严格 ELF 头/PT_DYNAMIC/重定位/symtab;`--shared` 显式校验 |
| `aot/stdlib_split.py` | `aot/stdlib_build.ql` / `aot/link.ql` | 对象构建;单模块 IR + 对象直接失败 |
| `aot/generate_math_constants.py` | `aot/generate_math_constants.ql` | 76 limbs,--check |
| `stdlib/generate_unicode_tables.py` | `aot/generate_unicode_tables.ql` | 4 份 UCD 原文 --check 逐字节 |

## 3. 现在的全量基线

构建一次标准库对象与驱动:

```sh
aot/bootstrap.sh --self --compiler target/selfhost/stage2
target/tools/stdlib --compiler target/selfhost/stage2          # -> target/stdlib/<key>
S=target/stdlib/<key>

build() { target/tools/build "$1" -o "$2" --stdlib-object "$S/stdlib.o"; }

build aot/run_tests.ql                 /tmp/run_tests
build aot/run_selfhost.ql              /tmp/run_selfhost
build aot/run_diff.ql                  /tmp/run_diff
build aot/run_compiler.ql              /tmp/run_compiler
build aot/run_diagnostics.ql           /tmp/run_diagnostics
build aot/run_modules.ql               /tmp/run_modules
build aot/run_value_contracts.ql       /tmp/run_values
build aot/run_numeric.ql               /tmp/run_numeric
build aot/run_gc.ql                    /tmp/run_gc
build aot/run_lifetime.ql              /tmp/run_lifetime
build aot/run_bundle.ql                /tmp/run_bundle
build aot/run_platform.ql              /tmp/run_platform
build aot/run_link.ql                  /tmp/run_link
build aot/run_string.ql                /tmp/run_string
build aot/run_extension.ql             /tmp/run_extension
build aot/run_extension_bridge.ql      /tmp/run_bridge
build aot/run_interpreter_contracts.ql /tmp/run_interp_contracts
build aot/run_fuzz.ql                  /tmp/run_fuzz
build aot/run_semantics_diff.ql        /tmp/run_semantics
build aot/run_bench.ql                 /tmp/run_bench
```

跑基线(需要 native 解释器 `/tmp/interp`:stage2 编 `bootstrapped/run_file.ql` + `tools/link`):

```sh
/tmp/run_tests "$S" --compiler target/selfhost/stage2
/tmp/run_tests "$S" --compiler target/selfhost/stage2 --interpreter
/tmp/run_selfhost "$S" --compiler target/selfhost/stage2 --jobs 6
/tmp/run_diff "$S" --compiler target/selfhost/stage2 --jobs 6
/tmp/run_compiler "$S" --compiler target/selfhost/stage2
/tmp/run_diagnostics "$S" --compiler target/selfhost/stage2 --interpreter /tmp/interp
/tmp/run_modules "$S" --compiler target/selfhost/stage2 --interpreter /tmp/interp
/tmp/run_values "$S" --compiler target/selfhost/stage2
/tmp/run_numeric "$S" --compiler target/selfhost/stage2
/tmp/run_gc "$S" --compiler target/selfhost/stage2
/tmp/run_lifetime "$S" --compiler target/selfhost/stage2
/tmp/run_bundle --root .
/tmp/run_platform "$S" --compiler target/selfhost/stage2
/tmp/run_link /tmp/qlang-link-check --root . --stdlib-object "$S/stdlib.o"
/tmp/run_string "$S" --compiler target/selfhost/stage2 --interpreter /tmp/interp
/tmp/run_extension target/ext-tmp --root . --compiler target/selfhost/stage2
/tmp/run_bridge target/ext-bridge-tmp --root . --compiler target/selfhost/stage2 --interpreter /tmp/interp
/tmp/run_interp_contracts --interpreter /tmp/interp
/tmp/run_fuzz "$S" --compiler target/selfhost/stage2 --interp /tmp/interp
/tmp/run_semantics "$S" --compiler target/selfhost/stage2 --interp /tmp/interp
/tmp/run_bench "$S" --compiler target/selfhost/stage2 --runs 2
/tmp/gen_math --check
/tmp/gen_unicode --check
cargo test --offline
```

扩展/桥接需要 dlopen 允许的 tmp 目录(本机 `target/ext-tmp`、`target/ext-bridge-tmp`);
Android 上 `/tmp` 不可用。`run_link` 需要先构建 `target/tools/run_link` 或直接
`target/tools/build aot/run_link.ql -o target/tools/run_link --stdlib-object "$S/stdlib.o"`。

## 4. 已知缺口(记录,不静默)

1. **冷启动**:所有 QLang 驱动都需要一个已存在的 `target/selfhost/stage2` 作为
   stage1;`aot/bootstrap.sh --self` 也从它重建工具。没有 Python 后,全新 clone
   需要外部提供 stage2(或先修 Rust 宿主的行首 `&&` 解析)。
2. **difftest**:291 个源中 63 个在 native-vs-interp 下不可裁决(static reject /
   TypeCheck vs UndefinedField 等),在 `aot/run_semantics_diff.ql` 的 `skipped`
   表中显式列出;Rust/V8 腿已退役。
3. **release 直调的注解检查(已修)**:`qlangc` 只把内建 Identifier 注解登记为
   "可证明";`(v: p.positive)` 现在记成哨兵并回落 `__call`,内联/裸 ABI 也只接受
   字面内建 `Number` 注解。回归用例在 `aot/run_value_contracts.ql`
   (`annotation-direct`),bridge 不再需要 `--debug` 回退。
4. **`--shared --opt 2`(已修)**:`aot/link.ql` 现在对 `--shared` 也执行
   静态字符串/ELF 校验;4 个扩展 × O0/O2 与 bridge 的 DSO 均在发布档通过,
   不再需要 `--debug` 重试。
5. **冻结数据不可在仓库内重生成**:difftest/fuzz/数值语料由一次性脚本从旧
   Python 版导出;仓库只保留数据。数学/Unicode 生成器已 QLang 化,可重生成。
6. **Unicode 表生成头**已从 `.py` 改为 `aot/generate_unicode_tables.ql`,并重建
   `stdlib/unicode_data.ql` 与 bundle;`--check` 通过。

## 5. 2026-10-31 删除后实测(同一份源码/编译器/对象)

| 驱动 | 结果 |
|---|---|
| `run_tests` native / interpreter | 60 / 0、42 / 0 |
| `run_selfhost`(含固定点) | 59 / 0 |
| `run_diff` | 57 / 0 |
| `run_compiler` | 69 / 0 |
| `run_diagnostics` | 855 / 0 |
| `run_modules` | 78 / 0 |
| `run_value_contracts` | 111 / 0 |
| `run_numeric` | 12 / 0(792 行) |
| `run_gc` / `run_lifetime` | 5 / 0、12 / 0 |
| `run_bundle` / `run_platform` | 23 / 0、15 / 0 |
| `run_link` | ALL CHECKS PASS |
| `run_string` | 26 / 0 |
| `run_extension` | 4 / 4 组合 |
| `run_extension_bridge` | 134 checks / 0 |
| `run_interpreter_contracts` | 23 / 0 |
| `run_fuzz` | 390 / 0 |
| `run_semantics_diff` | 228 / 0,63 跳过 |
| `run_bench` | 6 bench,insns/clang/CPU 列 |
| `generate_math_constants --check` | 76 limbs 匹配 |
| `generate_unicode_tables --check` | byte-identical |
| `cargo test --offline` | 14 passed |

扩展/桥接在 `target/ext-base-tmp`、`target/ext-bridge-base-tmp` 下跑
(dlopen 允许的路径);语义差分在 63 个隔离用例之外全绿。
