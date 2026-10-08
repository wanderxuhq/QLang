# QLang → LLVM AOT — M2:字符串 / 数组 / 对象(纯 QLang 内存实现)设计

- **日期**:2026-08-14
- **状态**:已冻结(2026-08-14,分节设计逐节获批)
- **父文档**:`2026-08-14-qlang-llvm-aot-compiler-design.md`(M0+M1 主设计,本文件只覆盖 M2 增量,不重复全局约束)
- **范围**:在 M1(qlangc v1:数值+控制流+函数/闭包/递归)之上,为编译产物补上**字符串 / 数组 / 对象**三种复合值;实现方案、盒布局、测试策略在本文件冻结
- **目标**:中量级程序(操作面 = medium)在 HOST / BOOT / NATIVE 三端输出逐字节一致;difftest 升级为四端(加 NATIVE 列)

## 已定决策(2026-08-14,全部经用户确认)

1. **字符串插值 `${}` → M3**,不在 M2。
2. **对象 = 纯 QLang 自建哈希表**(写在 `ql_alloc` 原始内存上,遵守"QLang 的数据必须用 QLang 的")。
3. **STRING 盒 = 内联 `{buf, len}`**(tag 2);`buf` 是字节缓冲,`len` 是字节数。
4. **测试 = difftest 升级为四端**,新增 NATIVE 列(每个 case → 独立 `.ql` → `--compile` → 跑 ELF);`NATIVE_CASES` 白名单限定在 M2-surface,白名单外的 NATIVE 走 SKIP,不破坏现有 host/boot/node 全量。
5. **操作面 = medium**:字符串/数组/对象字面量、`arr[i]`/`obj.k` 读写、`.length`、`.add`/`.remove`、`s[i]` 索引、`+` 拼接。
6. **对象盒 = 运行时自包含哈希桶**(独立分配的桶表由盒内 `table` 指针指向,翻倍再哈希时原地换指针 → 盒地址不变,别名安全);修复 M1 `objFieldSlots` 编译期全局槽位映射的缺陷。
7. **实现方案 = 方案 A(runtime 语义层全分派)+ 保留数字 `+` 内联 fadd**。

## 硬性约束(M2 增量,其余沿用父文档)

1. **零新 native(仅两个性能原语例外)**:`--compile` 驱动、qlangc、runtime.ql 均不新增;唯一例外是 runtime.c 加一对 8 字节槽原语(见 §5),定位为**性能原语**,有免费回退(全局替换成 `readU64`/`writeU64`,语义逐字节相同)。
2. **boot 零改动**:host/boot 的字符串/数组/对象语义已 419/419 绿,且 boot 的 `print` 是 host native(渲染逐字节委托 host Rust `to_string`,BOOT=HOST 由构造保证)→ M2 只动 NATIVE 侧,boot 一个字不改。
3. **验证纪律不变**:HOST / BOOT / NATIVE 三端输出逐字节一致;difftest 四端全绿;M1 的 v1 测试集保持三端一致。
4. **M2 只做整数域渲染**:NATIVE 白名单只放整数结果 case;`10/4`、`0.1+0.2` 等非整数 NATIVE case 走 SKIP(host/boot/node 三端照常全量)。完整 f64 Display(近似 Ryu)是独立小项目,推迟 M3。

## 盒布局(M1 R9 盒模型扩展)

| 盒 | 布局 | 大小 | 说明 |
|---|---|---|---|
| STRING (tag 2) | `{tag@0, buf@8, len@16}` | 24 B | `buf` = 字节缓冲(ql_alloc);`len` = 字节数;M2 字符串 = ASCII 字节串(Unicode 长度/多字节索引推迟) |
| ARRAY (tag 5) | `{tag@0, elements@8, length@16}` | 24 B | `elements` = `ql_alloc(8n)` 原始 ptr 数组(与 M1 emitCall 实参数组同构) |
| OBJECT (tag 6) | `{tag@0, table@8, cap@16, count@24}` | 32 B | `table` 指向独立分配的桶表,见下 |

**OBJECT 哈希桶**(运行时自包含,线性探测开放寻址):

- 桶表 = `ql_alloc(16*cap)` = 2*cap 个 ptr 槽 `[k0,v0,k1,v1,...]`,独立于盒分配。
- 探测 `i = (h+i) % cap`;**空槽 = key 为原始 NULL(0)** —— 真实盒由 brk 分配且地址非零,无歧义。**实现红线:qlangc emit `null` 必须产生 tag 4 的非零盒,绝不能退化成 0 指针**(否则会被误判为空槽)。
- `count` ≥ 70%·cap 时翻倍再哈希(原地换 `table` 指针 → 盒地址不变,别名安全:`let p=o; o.a=1; p.a` 与 host 一致)。
- **M2 无对象键删除 → 不需要墓碑**。
- 负载因子 70% 是吞吐/空间折中:线性探测在 70% 下平均探测 ~1.5,足够小。

## 哈希函数(QLang 可精确表达)

`__hash(key)`:确定性内容哈希,扫 key 盒前 24 字节。`h0=7`;`h = (h*31 + b) % 1000003`,对每个字节。

**为什么 31/1000003**:真 FNV-1a 的乘法常数 16777619 会乘到 2^56,超过 f64 精确整数上限 2^53 → 低位丢失;31/1000003 全程 < 2^25,完全精确。QLang 无移位符 → 用乘法取模即可,无需移位。

## 键 = 指针同一(编译期名字识别)

**QLang 对每个不同的字段名字面量发一个全局 STRING 盒,同名恒同盒** → `__obj_get` 只需指针相等比较(`k == key`),哈希桶内零字符串内容比较。`.length` 折叠成专用 `__get_length`(编译期识别);其余字段名只作为盒指针传递。runtime.ql 沿 M1 约束不写字符串字面量(但见 §4 第一批字符串字面量的说明)。

## runtime.ql 原语层(方案 A 的分派层)

### 新增原语函数表

| 函数 | 语义(host 镜像) | 实现注记 |
|---|---|---|
| `__hash(key)` | 内容哈希 | 上节;扫 key 盒前 24 字节 |
| `__obj_new()` | `{}` | 32B 盒 + cap=4 桶表 |
| `__obj_get(o,key)` | `o.k` 读 | 线性探测;空槽 = 原始 NULL |
| `__obj_set(o,key,v)` | `o.k=v` 写 | 命中覆盖 / 空槽插入;count+1 > 70%·cap → 翻倍再哈希(原地换 `table`) |
| `__get_length(o,klen)` | `.length` | 按 tag:STRING/ARRAY → 长度 NUMBER 盒;OBJECT → `__obj_get(o,klen)` |
| `__get_field(o,key)` | 一般字段读 | 按 tag:OBJECT → `__obj_get`;ARRAY(非 length)→ UndefinedField;STRING/其他 → NotAnObject |
| `__get_index(c,i)` | `arr[i]` / `s[i]` | ARRAY:normalize_index(负下标、非整数 → 越界错误盒);STRING:`s[i]` → 单字符盒 |
| `__set_index(c,i,v)` | `arr[i]=v` | `arr[arr.length]=v` append(c37 镜像);越界/STRING 写入 → 错误盒 |
| `__arr_add(a,v)` | `arr.add(x)` | append = 重分配+复制(盒保持 24B,无 capacity 字段);返回 Void |
| `__arr_remove(a,i)` | `arr.remove(i)` | 平移左移;坏下标静默 no-op(host 镜像);Void |
| `__add(a,b)` | `a+b` | 双 STRING → 字节拼接(经 `__str` 取 buf/len);**无双 NUMBER 路径**(见 §4 决策 1);其他 → TypeMismatch 错误盒 |
| `__err(kind,msg)` | 错误盒构造 | tag 8 盒 |
| `__type_of(v)` | 类型标签 | tag 探测 → 标签(供 native_disp 用) |

`__str` 扩展:tag 2 → 原样返回 `{buf,len}`;tag 5/6/8 → `"?Array"`/`"?Object"`/`"?Error"`。

### 四个关键设计决策

1. **键 = 指针同一,名字识别留在编译期** —— 见上节;数字 `+` 不进 `__add`,编译期静态双 NUMBER 仍走内联 fadd(已冻结)。
2. **runtime.ql 自身的 `{buf,len}` 字面量零改动** —— 它们现在只是编译降级为 `__obj_new`+`__obj_set`,语义不变、源码不动。
3. **`.add`/`.remove` 不做成真函数值** —— host 返回 curried NativeFunction;NATIVE 由 qlangc 把 `arr.add(x)` 调用形状直接降级为 `__arr_add(arr,x)`。M2 surface 外单独取 `.add` 值 → 错误盒。
4. **越界/类型错统一为错误盒**(tag 8),经 `?Error` 渲染进 ERROR_TOKEN。host 里 `set_index` 越界是硬错误而 `get_index` 是错误值 —— 这个区分在 M2 的 difftest 归一化下不可见,记为已知近似。

### 第一批字符串字面量(必要的自指)

`__type_of`/`__str` 需要返回 `"?Array"`/`"?Object"`/`"?Error"` 等标签 → **runtime.ql 出现第一批字符串字面量**,依赖 qlangc 先支持 String literal。无循环:qlangc 编译器自身不依赖 runtime.ql 的字符串。runtime.ql 现有 `{buf,len}` 字面量与字符串字面量共存。

## qlangc.ql emit 改动(方案 A 落点)

| 构造 | M1 现状 | M2 改为 |
|---|---|---|
| String literal | 缺失(emitExpr 无 String) | `.rodata` 全局字节 + STRING 盒{tag:2, buf, len}(**新 IR 发射模式:全局常量**) |
| Array literal `[a,b]` | 缺失 | ql_alloc(24) ARRAY 盒 + ql_alloc(8n) 元素表 + n 次 store;`[]` → 空盒 |
| Object literal `{k:v}` | 编译期 objFieldSlots 槽映射 | `__obj_new()` + n×`__obj_set(o, keyBox, v)`;**删除 objFieldSlots** |
| GetIndex `c[i]` | 缺失 | `__get_index(c, i)` |
| SetIndex `c[i]=v` | 缺失 | `__set_index(c, i, v)` |
| `.length` | 编译期槽 | `__get_length(o)`(编译期识别,不查哈希) |
| `.field` / `.field=v` | 编译期槽;未知→NULL | `__get_field(o, keyBox)` / `__set_field(o, keyBox, v)`;`.add(x)`→`__arr_add`,`.remove(i)`→`__arr_remove` |
| `+` | 双 NUMBER 内联 fadd | 保留内联 fadd(已冻结);动态 → `__add(a,b)` |

## leaf 扩展(runtime.c,两个性能原语)

方案 A 把 tag 分派和哈希探测搬进 runtime.ql 后,runtime.ql 需要在**动态偏移**处读写指针槽。纯 QLang 可经 `readU64`/`writeU64`(8 次字节读写 + 除/模合成)实现,但哈希热路径每条槽访问用它慢 ~8×。加一对 8 字节对齐槽原语:

```c
void*  ql_mem_get_ptr(const void* p, size_t off);       /* 8 字节 load */
void   ql_mem_store_ptr(void* p, size_t off, void* v);  /* 8 字节 store */
```

- **定位:性能原语,不是功能必需**。回退免费:runtime.ql 里把 `ql_mem_get_ptr`/`ql_mem_store_ptr` 全局替换成 `readU64`/`writeU64`,语义逐字节相同。
- 这是 M2 唯一的 leaf 新增,解锁 runtime.ql 全部数组/字符串/对象/哈希实现;非功能专用,是「读/写一个盒值槽」的最小原语。

## 渲染模型(为什么不需要整体容器渲染)

difftest 的 `disp()` 对数组/对象返回类型标签:Array→`"?Array"`、Object→`"?Object"`(difftest.py:571-572)。所有 case 的 last_expr 都是标量,或经 disp 折叠成标签。**推论:M2 不需要实现 `[1,2,3]`/`{a:1}` 的整体渲染。** runtime.ql 的 `__str` 只需给 tag 5/6/8 发标签。

但 NATIVE 列不能直接复用现有 disp 包装器(它用了 `std.Type.of`/`std.Number.toString`,qlangc 不编译 stdlib)→ 需要 **native_disp()** 变体:只用 qlangc+runtime.ql 能编译的构造,类型探测交给 `__type_of`。

## 验证策略:四端 difftest

1. **difftest.py 增加 NATIVE 列**:每个 case → 独立 `.ql` → `qlang --compile` → 跑 ELF。
2. **NATIVE_CASES 白名单**:约 20-25 个整数域 case,覆盖字符串(拼接/索引/长度)、数组(字面量/读写/append/负下标/`.add`/`.remove`/`.length`)、对象(读写/嵌套/别名同一)、短路复合。**只测 M2-surface,不进 COMPLEX/RISKY**。
3. **白名单外的 NATIVE 走 SKIP**,不破坏现有 host/boot/node 全量。
4. **boot 零改动**;host/boot/node 三端全量必须保持绿。
5. **M1 v1 测试集三端一致必须保持**(回归纪律)。

## M2 出口标准(gate)

1. NATIVE 白名单在 HOST / BOOT / NATIVE 三端输出逐字节一致。
2. 全量 difftest host/boot/node 仍全绿。
3. M1 v1 测试集三端一致不回归。
4. `qlang --compile` 零新 native(仅 runtime.c 的 2 个槽原语,定位为性能原语,回退免费)。

## 性能预期与诚实标注

方案 A 的每次 op 调用机制成本 = 实参数组 ql_alloc + 函数帧 ql_alloc(以及嵌套 `__str` 调用的更多)= 每 op ~0.5-2µs,对比 M1 内联 fadd ~3-10ns。**对 M2 无关紧要(测试程序小);M4 bootstrapping 才会暴露,那时再优化。** 间接调用本身(blr vs bl)是 ~1-2 cycles,非瓶颈;瓶颈是调用机制的 brk syscall(ql_alloc 是 aarch64 svc #0,每分配 ~100-400ns)。

## 不做的事(YAGNI,M2 范围外)

- **字符串插值 `${}` → M3**。
- **Unicode 长度 / 多字节索引**:M2 字符串 = ASCII 字节串;`"héllo".length` 等留在 host/boot/node 三端全量测。
- **对象键删除**:M2 无删除,哈希表无墓碑。
- **整体容器渲染** `[1,2,3]`/`{a:1}`:M2 只发标签(渲染模型一节)。
- **完整 f64 Display**(非整数/|n|≥1e15):NATIVE 白名单限整数域,推迟 M3。
- **柯里化**:`.add`/`.remove` 不做真函数值,只做调用形状降级。
- **RC/GC、类型特化、尾调用优化**:沿用父文档,后置。
- **M1 遗留 carryover**(branch-level let 支持、argsBox 复用、boot recursion 深度上限):与 M2 无交集,继续推迟。
