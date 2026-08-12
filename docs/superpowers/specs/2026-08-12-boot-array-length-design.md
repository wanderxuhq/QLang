# Boot 解释器包装数组 `.length` O(n) 重算优化

- **日期**:2026-08-12
- **状态**:已批准
- **范围**:仅 `bootstrapped/interpreter.ql`
- **目标**:消除 boot 解释器包装数组 `.length` 访问的 O(n) 循环重算,将词法分析 146s → 个位数秒,整体 boot 运行 294.5s → ~60s 上下
- **硬性约束**:host/boot 字节级一致、`demo/type_gymnastics.ql` 419/419 asserts、`difftest.py` 三端差分全绿、`verify_bootstrap` 全量通过

## 背景

`demo/type_gymnastics.ql` 在 boot 解释器上运行耗时 294.5s,其中:

| 阶段 | 耗时 | 占比 |
|---|---|---|
| Lexing | 146.6s | ~50% |
| Parsing | 6.4s | ~2% |
| 执行(Ch.8/9/7/4 为热点) | ~141s | ~48% |

### 根因

boot 的包装数组是 `{type:"Array", value: rawArray, length: n}`。包装数组上访问 `.length` 走 `MemberAccess` 的 Array 分支,当前实现为:

```ql
// interpreter.ql:603-605
{ type: "Number", value: getArrayLength(obj.value) };
```

其中 `getArrayLength`(interpreter.ql:60-68)是一个 **boot 层 O(n) 计数循环**:

```ql
let getArrayLength = (arr) -> {
  let count=0; let i=0;
  while i < arr.length { count=count+1; i=i+1; }
  count;
};
```

它做的事情等于 `arr.value.length`(raw JS 数组的 O(1) 属性访问),却要为每个元素跑一遍完整解释器循环。

于是以下常见模式全部变成 O(n²):

- 词法分析逐 token 追加:`tokens[tokens.length] = token`(lexer.ql:261)— 每次追加重扫整个数组
- `__toChars` 逐字符追加:`parts[parts.length] = ...`(stdlib.ql:400-410)
- 任意 QLang 用户代码的 `while i < arr.length` 遍历与 `arr[arr.length] = x` 追加

17172 个 token 的词法分析因此烧掉约 1.47 亿次解释器循环迭代。

## 设计

### 核心变更(全部在 `bootstrapped/interpreter.ql`)

**变更 1 — MemberAccess Array `.length` 直读真相源**(第 603-605 行):

```ql
// before
{ type: "Number", value: getArrayLength(obj.value) };
// after
{ type: "Number", value: obj.value.length };
```

**变更 2 — 删除死代码**:

- `getArrayLength`(第 60-68 行)— 变更 1 后无调用
- `getArrayElement`(第 70-80 行)— 原本就无调用(O(n) 线性扫描,死代码)

无其他文件改动。**不引入缓存字段、不写回、不加状态。**

### 为什么用「直读真相源」而非「缓存」

初版方案是缓存 `.length` 到 field table 并在每次写入时同步。但缓存有两个失效口:

1. **native 可变操作不可见**:`std.Array.push(a.value)(x)` / `pop` / `remove` 是 host native,直接改 raw 数组,boot 字节码层不可见;缓存会悄悄过期。
2. **`arr.length = x` 成员写入**(interpreter.ql:366)直接写 field table 的 `length` 键,读改共用一处,用户写错值就让缓存说谎。

直读 `obj.value.length` 则:
- **O(1)**:一次 host 属性读,不再有 boot 循环
- **永远新鲜**:raw 数组是唯一真相源,`std.Array.push(a.value)(x)` 后 `a.length` 依然正确——与今天的行为完全一致(今天靠重算所以也对,只是 O(n))
- **零写回**:不引入状态,就没有失效口,上述两个场景在数学上不可能发生

### 模式复用

这个直读模式代码库已有先例,非新套路:

- String 分支第 616 行:`obj.value.length` 直读 raw string
- stdlib.ql:260:`while i < x.value.length` 直读 raw array

## 影响面分析(为什么安全)

- **读路径**:所有 `.length` 读路径值不变,复杂度从 O(n) 变 O(1)。覆盖 `runStatements`/`runWhileStatement` 的循环、lexer 的 `tokens.length`、`__toChars` 的 `parts[parts.length]`、以及任意用户代码的数组遍历/追加。
- **写路径未触碰**:`arr.length = x` 走 MemberAccess 的 Object/Type 分支(第 366 行),不走 Array 分支;IndexAssign 数组分支(第 389-404 行)不写 `length` 键。故零失效口。
- **不动的部分**:包装结构、host `src/`、demo、parser。

## 验证策略

1. `difftest.py` — host/boot/node 三端差分全绿
2. `demo/type_gymnastics.ql` — host 与 boot 字节级一致 + 419/419 asserts
3. `verify_bootstrap` 全量套件
4. 重新计时 boot — 确认 lexing 146s → 个位数秒、整体 294s → ~60s 上下(附计时表)

## 不做的事(YAGNI)

- 不做每字符桥接削减(每字符 `std.String.includes(CLASS)(c)` 的闭包重造)——留给后续,除非实测残余仍不满意
- 不做 `getArrayLength` 的替代实现——直接删
- 不优化执行期 `.check` 桥接热点(Ch.8/9/7/4)——本设计范围外,单独议题
