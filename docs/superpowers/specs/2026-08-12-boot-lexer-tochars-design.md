# Boot 词法器 `__toChars` O(n²) → O(n) 重写(纯 QLang,零新 native)

- **日期**:2026-08-12
- **状态**:已批准
- **范围**:仅 `bootstrapped/stdlib.ql`(一个文件,~12 行)
- **目标**:消除 boot 词法器 `__toChars` 的 host 侧 O(n²) 逐字符索引,将词法分析 ~150s → 个位数秒,整体 boot 运行 ~300s → ~145s
- **硬性约束**:host/boot 字节级一致、`demo/type_gymnastics.ql` 419/419 asserts、`difftest.py` 三端差分全绿、`verify_bootstrap` 34/34 PASS / 0 FAIL

## 背景

`demo/type_gymnastics.ql` 在 boot 解释器上运行耗时 ~300s,其中词法分析 ~150s(基线 146.6s)。已通过探针(临时 `probe_lexing.ql`,用后删除)精确隔离根因:

| 探针标记 | 耗时 | 含义 |
|---|---|---|
| A before-toChars | 0.3s | 源码读取 |
| B after-toChars | 143.7s | `std.String.toChars`(即 `__toChars`)遍历 68KB 源码 |
| C after-Lexer(...) | 281.3s | 新 `Lexer(source)` 里第二次 `toChars` |
| D after-tokenize | 285.9s | `tokenize()` 本身:4.65s |

### 根因

`bootstrapped/stdlib.ql` 的 `__toChars` 用 `s2[i]` 逐字符访问 host 字符串:

```ql
let __toChars = (s) -> {
  let s2 = ...;          // 解包得到 raw host String
  let parts = [];
  let i = 0;
  while i < s2.length {
    parts[parts.length] = s2[i];   // s2[i] → host get_index
    i = i + 1;
  }
  parts;
};
```

host 的 `get_index` String 分支(`src/interpreter.rs:1170`)对**每一次**单字符访问都执行 `s.chars().collect()`——O(n) per access × 68K 次访问 = O(n²) ≈ 46 亿次 char 收集 ≈ 143s。这是 **host 机制层的 O(n²)**,运行于 host 解释器之下,与已提交的 boot `.length` 优化(commit `5e4fc8a`)相互独立。`tokenize()` 本身很快(4.65s),一旦字符数组就绪。

## 设计

### 核心变更(仅 `bootstrapped/stdlib.ql` 的 `__toChars` 函数体)

`std.String.split` 是 **host 已有的原生方法**,O(n) 单次遍历产出数组。空分隔符 `split(s)("")` 恰好按字符边界切分,产出 `["", c1, ..., cn, ""]`(首尾各一个空串)。用纯 QLang 过滤掉空串,即得与旧逐字符索引**字节级一致**的单字符数组:

```ql
let __toChars = (s) -> {
  let s2 = if s != null && !isError(s.type) && s.type == "String" { s.value; } else { s; };
  let splitParts = std.String.split(s2)("");
  let result = [];
  let i = 0;
  while i < splitParts.length {
    if splitParts[i] != "" {
      result[result.length] = splitParts[i];
    }
    i = i + 1;
  }
  result;
};
```

**复杂度**:`split` 一次 O(n) 遍历 + 过滤循环 O(n)(数组索引/追加在 `5e4fc8a` 后均为 O(1),逐元素仅比较小字符串)。总 O(n),消除 O(n²)。

### 为什么这个方案(而非 host 原生 `toChars` 或改 `Value::String`)

用户的架构原则:**编译器/运行时机制可以用 Rust(host),但 QLang 的数据与语言层函数必须由 QLang 自己实现**——否则将来 QLang 脱离 Rust 摇篮时,语言层面会留下只有 Rust 才有的依赖。

三个候选方案的对比:

| 方案 | 新增 native? | 改数据层? | 自举友好? |
|---|---|---|---|
| A. host 原生 `std.String.toChars` | 是 | 否 | ✗——`toChars` 是纯数据转换(字符串→单字符数组),本该由 QLang 自己写;换成 native 就断了自举 |
| B. `Value::String` 挂字符缓存(Arc) | 否 | 是 | ✗——把 Rust 引用计数语义灌进 QLang 数据表示(83 处匹配点),脱离 Rust 时数据层残留 Rust 痕迹 |
| **C. 纯 QLang 重写 `__toChars`,组合现有 native `split`(本方案)** | **否** | **否** | ✓——`split` 是既有运行时机制(可被新运行时原生重实现),`__toChars` 是纯 QLang 组合逻辑,原样带走 |

方案 C 零新 native、零数据层改动、只碰一个文件。`__toChars` 仍是纯 QLang 的「数组 of 单字符字符串」数据形状;host 的 `split` 只是被复用的运行时机制,与词法器已经在用的 `std.String.includes(CLASS)(c)` 柯里化 native 同款。

### 与既有优化(commit `5e4fc8a`)的关系

`5e4fc8a` 把包装数组 `.length` 改为 O(1) 直读 raw 数组,移除了 `__toChars` 里 `parts[parts.length]` 追加的 boot 侧 O(n²)(68K 字符 → 约 23 亿次 boot 循环迭代)。本方案再移除 host 侧 `s2[i]` 的 O(n²)(约 46 亿次 char 收集)。两者独立、互补,叠加后 lexing 才真正落到个位数秒。

## 语义等价性验证

已用 host 探针(临时 `/tmp/probe_newchars.ql`)对 8 组输入对比新旧 `__toChars` 输出:**全部 IDENTICAL**。

| 输入 | 旧长度 | 新长度 |
|---|---|---|
| `"hello"` | 5 | 5 |
| `""`(空串) | 0 | 0 |
| `"a😀b"`(emoji) | 3 | 3 |
| `" "`(空格) | 1 | 1 |
| `"  leading and trailing  "` | 24 | 24 |
| `"the quick brown fox..."` | 43 | 43 |
| `"\t\n"` | 2 | 2 |
| `"{}[]();,+-*/"` | 12 | 12 |

空分隔符 split 的 Rust 语义:按字符边界切分(emoji 作为单字符),空串输入产出 `["", ""]`,过滤后 `[]`。字符本身永不为空串,过滤无副作用。

## 影响面分析(为什么安全)

- **唯一改动点**:`bootstrapped/stdlib.ql` 的 `__toChars` 函数体(第 400-410 行),`std.String.toChars = __toChars` 覆盖语句不变。
- **调用面**:全项目仅 `bootstrapped/lexer.ql:8`(`let chars = std.String.toChars(source);`)一处调用,且 `__toChars` 裸名字未被 `export`(stdlib.ql:441 导出列表无它),外部不可达。词法器零改动。
- **公开接口不变**:`std.String.toChars` 方法仍在,只是实现从慢的纯 QLang 逐字符变成快的纯 QLang split+过滤——语义(字符串→单字符数组)不变。
- **不动的部分**:host `src/`、`Value` 数据层、demo、parser、interpreter.ql。

## 验证策略

1. `difftest.py` — host/boot/node 三端差分全绿
2. `demo/type_gymnastics.ql` — host 与 boot 字节级一致 + 419/419 asserts
3. `verify_bootstrap` 34/34 PASS / 0 FAIL(含新增 toChars 形状回归用例)
4. 计时 boot demo — lexing ~150s → 个位数秒;总 ~300s → ~145s(附计时表)
5. toChars 形状回归用例放 `verify_bootstrap.ql`(第 27 项,r28,期望 8111)——difftest 的 SAFE_CASES 跑在纯 host 上,而 `String.toChars` 是 boot-only 增强,纯 host 无此函数,故 difftest 无法承载该用例

## 实测结果(2026-08-12,应用补丁后)

| 阶段 | 基线 | 应用后 | 变化 |
|---|---|---|---|
| Lexing(`Generated 17172 tokens`) | 150.4s | **5.058s** | ~30× |
| Lexing 窗口(`Lexer(...)`+`tokenize()`) | 150.4s | 5.411s | ~28× |
| Parsing | 6.4s | 5.465s | — |
| Interpreting(Ch.1-15) | ~142s | ~134s | — |
| **Total** | **299.7s** | **144.975s** | ~2× |

difftest `All identical ✔`;verify_bootstrap 34/34 PASS / 0 FAIL;demo `RESULT: 419/419 asserts passed`;host/boot 字节级一致(`BYTE-IDENTICAL`,对照 `/tmp/tg_host.out`)。

## 不做的事(YAGNI)

- 不加 host 原生 `String.toChars`(违反自举原则,见上)
- 不改 `Value::String` 数据表示(侵入大、无处兑现)
- 不优化执行期 `.check` 桥接热点(Ch.8/9/7/4,~142s)——独立议题,另行立项
