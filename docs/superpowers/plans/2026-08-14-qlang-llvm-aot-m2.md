# QLang → LLVM AOT — M2(字符串/数组/对象)实现计划

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** 在 M1(qlangc v1:数值+控制流+函数/闭包/递归)之上,为编译产物补上字符串/数组/对象三种复合值,使中量级程序在 HOST / BOOT / NATIVE 三端输出逐字节一致,difftest 升级为四端。

**Architecture:** 方案 A(runtime.ql 语义层全分派)。qlangc 把 String literal 发成 `.rodata` 全局字节 + 全局 STRING 盒;Array literal 内联构造(ql_alloc 盒 + 元素表);Object literal 降级为 `__obj_new()` + N×`__obj_set`(纯 QLang 自建哈希表,线性探测开放寻址,70% 负载翻倍再哈希);`.length`/`.field`/`c[i]`/`.add(x)`/`.remove(i)` 全部编译期降级为 runtime.ql 原语调用。数字 `+` 保留 M1 内联 fadd;静态双字符串字面量 `+` 降级 `__add`。runtime.ql 新增两个 8 字节槽 leaf 原语(性能原语,回退免费)。

**Tech Stack:** QLang(boot 解释器运行 qlangc)、LLVM 文本 IR、`clang -fuse-ld=lld` 工具链、Python 3(difftest)。

**Spec:**
- `docs/superpowers/specs/2026-08-14-qlang-llvm-aot-compiler-design.md`(父文档,M0+M1 全局约束)
- `docs/superpowers/specs/2026-08-14-qlang-llvm-aot-m2-design.md`(本里程碑设计,已冻结)

## Global Constraints

从两份 spec 冻结的硬约束,每个任务的隐含需求都包含本节:

1. **零新 native(仅 2 个性能原语例外)**:M2 唯一 leaf 新增 = `ql_mem_get_ptr(p, off)` / `ql_mem_store_ptr(p, off, v)`(8 字节对齐槽读写)。定位性能原语,回退免费(全局替换成 `readU64`/`writeU64` 语义逐字节相同)。`--compile` 驱动、qlangc、runtime.ql 均零新增 native。
2. **boot 零改动**:host/boot 的字符串/数组/对象语义已 419/419 绿;M2 只动 NATIVE 侧,boot 一个字不改。
3. **验证纪律不变**:HOST/BOOT/NATIVE 三端输出逐字节一致;difftest 四端全绿;M1 的 v1 测试集保持三端一致。
4. **M2 只做整数域渲染**:NATIVE 白名单只放整数结果 case;`10/4`、`0.1+0.2` 等非整数 NATIVE case 走 SKIP(host/boot/node 三端照常全量)。
5. **对象 = 纯 QLang 自建哈希表**(写在 `ql_alloc` 原始内存上,"QLang 的数据必须用 QLang 的")。STRING 盒 = 内联 `{buf, len}`(tag 2)。ARRAY 盒 = `{tag, elements@8, length@16}`(24B)。OBJECT 盒 = `{tag, table@8, cap@16, count@24}`(32B)。
6. **键 = 指针同一**:qlangc 对每个不同的字段名字面量发一个全局 STRING 盒,同名恒同盒 → `__obj_get` 只需比较两盒 payload f64(oeq)。`null` 盒必须是非零 tag-4 盒(红线上:绝不能退化成 0 指针,否则被误判为空槽)。
7. **hash 函数**:`h0=7`;`h = (h*31 + b) % 1000003`,扫 key 盒前 24 字节。31/1000003 全程 < 2^25,f64 精确。
8. **qlangc emit 只调用 runtime.ql 暴露的 QLang 层接口**,不直接 emit 对 leaf 的裸调用。
9. **qlangc 无 return 支持**:runtime.ql 与测试程序只用表达式 if / while / 尾表达式,不用 `return`。
10. **多路分支必须用嵌套 if/else**:boot parser 把 `else if` 拍平成 branches[],qlangc 的 `emitIfStmt` 只处理 `branches[0]`。runtime.ql / native_disp / 测试程序的所有 ≥2 分支分派都写成 `if c {} else { if c {} else { ... } }` 嵌套形式。
11. **分支/循环体内不允许 `let`**:qlangc 只支持函数顶层 let;if 分支体与 while 循环体内的 `let` 会经 `defineSlot` 分配到函数帧之外 → 越界写/段错误(已实证)。规则:**所有 `let` 声明放函数顶层,分支/循环体内只能赋值既有绑定**(先 `let x = 0;` 于函数顶层,循环内 `x = ...`)。既有先例:现 runtime.ql `__itoa` 的 `let d = 0;`(函数顶层,注释"d 必须函数顶层声明(分支内 let 不受支持)")。本计划 Task 3/4/5 的所有原语已按此规则写死(所有循环/分支临时量都预声明在函数顶层)。
12. **只用 LLVM 自带工具链**:`clang -fuse-ld=lld <tmp.ll> aot/runtime.c -o <out>`;不碰 gcc/系统 ld。
13. **测试文件**:任务测试放 `aot/tests/t8_*.ql`(遵循 t4–t7 命名);runtime.ql 内部原语的测试是 **NATIVE-only**(host/boot 无法解释 runtime.ql 的 leaf 调用),期望输出人工核算;端到端三端验证在 Task 9 的 NATIVE 白名单 + Task 10 的 gate。

---

## 文件结构

| 文件 | 责任 | M2 改动 |
|---|---|---|
| `aot/runtime.c` | leaf 垫底 | +`ql_mem_get_ptr`/`ql_mem_store_ptr` |
| `aot/runtime.ql` | 编译产物的运行时语义层 | 重排(哈希/复合原语移到 `__itoa` 前)+ `__str` 全分派 + `__type_of`/`__nullstr`/`__mknum` + 第一批字符串字面量 + 哈希表/数组/对象/拼接原语 + `__print` 双路径 |
| `aot/qlangc.ql` | 编译器(QLang 写) | +String literal 发射(intern + strDecls)+ Array/Object/IndexAccess emit + member access 降级 + assign 目标分派 + `.add/.remove` 调用降级 + `emitCallRegs` 辅助 + 双字符串 `+`→`__add` |
| `difftest.py` | 四端验证 | +NATIVE 列 + `NATIVE_CASES` 白名单 + `native_disp()` + m 系列 SAFE_CASES + NODE_CASES 补充 |
| `aot/run_v1_tests.sh` | v1 回归门 | 零改动(保持绿) |
| `aot/tests/t8_*.ql` | M2 任务测试(NATIVE-only + 三端) | 新增 |

---

### Task 1: leaf 8 字节槽原语

**Files:**
- Modify: `aot/runtime.c`
- Modify: `aot/qlangc.ql`(`isLeaf` 链 + `emitCall` 分支 + `emitPrelude` 声明)
- Create: `aot/tests/t8_leaf.ql`(NATIVE-only)

**Interfaces:**
- Consumes: 现有 `ql_alloc` leaf 分支、`boxToInt`、`temp()`。
- Produces: leaf 名字 `ql_mem_get_ptr(ptr, i64) → ptr`、`ql_mem_store_ptr(ptr, i64, ptr) → void`;qlangc 把它们当作 isLeaf,arg0 原始 ptr 直通、arg1 经 boxToInt、arg2 原始 ptr 直通。

- [ ] **Step 1: runtime.c 加两个原语**

在 `ql_mem_get`/`ql_mem_store` 旁追加(与现有一致用 `memcpy` 布局,8 字节 load/store):

```c
void*  ql_mem_get_ptr(const void* p, size_t off) {
    void* v;
    memcpy(&v, (const char*)p + off, sizeof(void*));
    return v;
}
void ql_mem_store_ptr(void* p, size_t off, void* v) {
    memcpy((char*)p + off, &v, sizeof(void*));
}
```

- [ ] **Step 2: qlangc 把新 leaf 加入 isLeaf 链**

`aot/qlangc.ql` 的 `emitCall` isLeaf 判断(约 513 行)追加两个名字:

```ql
let isLeaf = (cname) -> {
  cname == "ql_alloc" || cname == "ql_write" || cname == "ql_mem_get" ||
  cname == "ql_mem_store" || cname == "ql_mem_get_ptr" || cname == "ql_mem_store_ptr";
};
```

- [ ] **Step 3: emitCall 加两个分支**

在现有 `ql_mem_store` 分支后追加(模式完全镜像 `ql_mem_get`/`ql_mem_store`,arg0/arg2 原始直通,arg1 boxToInt):

```ql
} else if cname == "ql_mem_get_ptr" {
  let p = emitExpr(node.arguments[0]);
  let off = boxToInt(node.arguments[1], "i64");
  let r = temp();
  line("  " + r + " = call ptr @ql_mem_get_ptr(ptr " + p + ", i64 " + off + ")");
  r;
} else if cname == "ql_mem_store_ptr" {
  let p = emitExpr(node.arguments[0]);
  let off = boxToInt(node.arguments[1], "i64");
  let v = emitExpr(node.arguments[2]);
  line("  call void @ql_mem_store_ptr(ptr " + p + ", i64 " + off + ", ptr " + v + ")");
  emitNull();
}
```

- [ ] **Step 4: emitPrelude 加两个 declare**

`emitPrelude` 的 4 个 declare 之后追加:

```ql
line("declare ptr @ql_mem_get_ptr(ptr, i64)");
line("declare void @ql_mem_store_ptr(ptr, i64, ptr)");
```

- [ ] **Step 5: 写失败测试(NATIVE-only,期望输出人工核算)**

`aot/tests/t8_leaf.ql`:

```ql
let x = 5;
let b = ql_alloc(24);
ql_mem_store_ptr(b, 0, x);
let y = ql_mem_get_ptr(b, 0);
println(y);
```

期望输出:`5`(y 是 x 的同一个 NUMBER 盒,`__str` tag 1 → `__itoa` 渲染 5)。

- [ ] **Step 6: 编译运行确认失败/成功**

```bash
./target/debug/qlang --compile aot/tests/t8_leaf.ql -o /tmp/t8_leaf.bin
/tmp/t8_leaf.bin   # 期望输出 5;若为 0/段错误说明原语缺失
```
先跑一次确认当前失败(缺原语 → clang 链接错误),实现后输出 `5`。

- [ ] **Step 7: 验证 v1 回归**

```bash
bash aot/run_v1_tests.sh
```
期望:全部 PASS。

- [ ] **Step 8: Commit**

```bash
git add aot/runtime.c aot/qlangc.ql aot/tests/t8_leaf.ql
git commit -m "feat(aot): ql_mem_get_ptr/ql_mem_store_ptr 8-byte slot leaf primitives (M2 leaf)"
```

---

### Task 2: qlangc String literal 发射(全局常量 + intern 盒)

**Files:**
- Modify: `aot/qlangc.ql`
- Create: `aot/tests/t8_strlit.ql`(IR-grep 验证 + 编译通过)

**Interfaces:**
- Consumes: 现有 `line`/`out`/`emitPrelude`/`emitExpr` dispatch;字符串字面量节点 `{type:"String", value}`(`value` 为 lexer 解码后的字符串)。
- Produces: `emitStringLiteral(node) → "@.strboxN"`(全局 STRING 盒地址,可直接作 ptr 操作数);`internString(s) → "@.strboxN"`(同名恒同盒);`strDecls` 缓冲 + 在 `main` 末尾 flush;`escapeC(s)` 字节→LLVM 常量串。

- [ ] **Step 1: 加状态与辅助**

在 `qlangc.ql` 模块顶层(紧邻 `objFieldSlots` 处)加:

```ql
let strCounter = 0;             // 字符串盒序号
let strDecls = [];              // 缓冲的全局常量/盒定义(flush 在 main 末尾)
let stringIntern = {};          // 内容 → @.strboxN(跨 runtime.ql+用户源码整个编译单元)
```

`escapeC`(把解码后的字节重编码为 LLVM IR 字符串常量转义;格式见 `aot/tests/m0_hello.ll` 的 `[3 x i8] c"hi\0A"`,`\0A` = `\`+大写两位十六进制,**无 NUL 终止**):

```ql
let escapeC = (s) -> {
  let n = s.length;
  let out = "";
  let i = 0;
  while i < n {
    let c = s[i];
    if c == "\n" { out = out + "\\0A"; }
    else {
      if c == "\t" { out = out + "\\09"; }
      else {
        if c == "\r" { out = out + "\\0D"; }
        else {
          if c == "\"" { out = out + "\\22"; }
          else {
            if c == "\\" { out = out + "\\5C"; }
            else {
              out = out + c;
            };
          };
        };
      };
    };
    i = i + 1;
  };
  out;
};
```

> 注:`out = out + c` 在 qlangc 内是双字符串字面量之外的动态拼接——qlangc 本身跑在 boot 解释器上,`+` 走 boot 的动态字符串拼接语义(与 M2 产物无关;qlangc 是工具,可吃 host/boot 机制)。此处 `+` 两侧均为运行期字符串值,boot 正常拼接。

- [ ] **Step 2: internString + emitStringLiteral**

```ql
let internString = (s) -> {
  let hit = stringIntern[s];
  if isError(hit) || hit == null {
    let n = strCounter;
    strCounter = strCounter + 1;
    let lbl = "@.strbox" + std.String.toString(n);
    stringIntern[s] = lbl;
    let bufLbl = "@.str" + std.String.toString(n);
    let len = s.length;
    strDecls[strDecls.length] = bufLbl + " = private unnamed_addr constant [" +
      std.String.toString(len) + " x i8] c\"" + escapeC(s) + "\"";
    strDecls[strDecls.length] = lbl + " = global { i64, ptr, i64 } { i64 2, ptr " +
      bufLbl + ", i64 " + std.String.toString(len) + " }";
    lbl;
  } else {
    hit;
  };
};

let emitStringLiteral = (node) -> {
  internString(node.value);
};
```

> STRING 盒布局 `{tag@0=2, buf@8, len@16}`;`[LEN x i8]` 的 LEN = 解码字节长度(无 NUL)。

- [ ] **Step 3: main 末尾 flush strDecls**

`main` 在 flush `fnBlocks` 之后(函数定义之后)追加:

```ql
let si = 0;
while si < strDecls.length {
  line(strDecls[si]);
  si = si + 1;
};
```

> LLVM 顶层实体无序,全局常量/盒放在函数定义之后合法。`@.strboxN` 引用 `@.strN` 均为全局,顺序无关。

- [ ] **Step 4: null 盒 intern(修复 c22/c23 三端发散)**

`emitNull` 目前每次 `allocBox("4")` 分配一个 **fresh 8B 盒**;`==` 对 `[box+8]` 做 `fcmp oeq` → fresh null 盒的 `+8` 读**相邻内存**(下一个盒的 tag 字节 / 零页),`null == null`(c22)得 false、`null != null`(c23)得 true → 与 host(`true`/`false`)发散。修复:intern 一个**全局 16B null 盒** `{tag@0=4, payload@8=0}`,`emitNull` 返回其地址 —— `null == null` 两操作数是同一盒,`[box+8]` 自读显式初始化的 0.0 → oeq 恒真;地址非零(真全局)→ 满足红线(空槽哨兵判别);host 的 null 本就是单例(`Value::Void`),singleton 语义更对。

`emitPrelude` 的 declares 之后追加:

```ql
line("@.nullbox = global { i64, i64 } { i64 4, i64 0 }");
```

改 `emitNull`(顶部,现 55 行):

```ql
// null 字面量:tag=4(NULL)。返回 interned 全局 16B 盒 {tag=4, payload=0} 地址:
//   [box+8] 恒读 0.0 → null == null(同一盒)fcmp oeq 恒真、null != null 恒假,
//   host 镜像(c22/c23)。地址非零 → 满足红线(空槽哨兵不能是 0 指针)。
let emitNull = () -> {
  "@.nullbox";
};
```

> `emitNull` 的返回值是多处 IR 操作的 ptr 操作数(`ret ptr`、`phi ptr`、`store ptr`、call 实参)—— `@.nullbox` 是合法 ptr 操作数,处处可用;void 调用后的 `emitNull()` 也免去每处一次分配(性能红利)。**payload 是盒内显式 0,不依赖链接器在 `[box+8]` 放什么。** `null == 0`(payload 0.0 == 数字 0.0)仍发散 —— 预存 M1 payload-比较设计局限,白名单无此 case,记 ledger 不作 M2 门。

- [ ] **Step 5: emitExpr dispatch 加 String 分支**

`emitExpr` 的 dispatch 加:

```ql
} else if node.type == "String" {
  emitStringLiteral(node);
}
```

- [ ] **Step 6: 写失败测试(IR-grep)**

`aot/tests/t8_strlit.ql`:

```ql
let s = "hi";
let t = "a\nb";
println(42);
```

- [ ] **Step 7: 编译 + IR 检查**

```bash
./target/debug/qlang --compile aot/tests/t8_strlit.ql -o /tmp/t8_strlit.bin >/dev/null 2>&1
QLANG_IR=$(mktemp)  # 无法直接拿 IR;改为:先 dump IR
```
实际检查方法:临时改 `--compile` 前把 IR 落地——直接复用 host 的 `--compile`,再手动跑一次 qlangc 捕获 stdout:

```bash
./target/debug/qlang bootstrapped/run_file.ql aot/qlangc.ql aot/runtime.ql > /tmp/t8_strlit.ir 2>/dev/null
grep -n 'str0 = private unnamed_addr constant \[2 x i8\] c"hi"' /tmp/t8_strlit.ir
grep -n 'str0 = global { i64, ptr, i64 } { i64 2, ptr @.str0, i64 2 }' /tmp/t8_strlit.ir
grep -n 'str1 = private unnamed_addr constant \[3 x i8\] c"a\0Ab"' /tmp/t8_strlit.ir
grep -n '@.nullbox = global { i64, i64 } { i64 4, i64 0 }' /tmp/t8_strlit.ir
```
> 注:run_file.ql 传参方式与 `--compile` 一致(args[0]=combined 源码,args[1]=路径)。若 boot run_file 参数约定不同,按 v1 测试脚本的用法调整。期望四行 grep 命中(第三行 `str1` 验证转义,第四行验证 null 盒 intern)。`t8_strlit.bin` 运行输出 `42`(字符串字面量尚未参与渲染,Task 3 补)。

- [ ] **Step 8: Commit**

```bash
git add aot/qlangc.ql aot/tests/t8_strlit.ql
git commit -m "feat(aot): qlangc String literal emit — .rodata const + global STRING box, interned per content (M2 strlit)"
```

---

### Task 3: runtime.ql 重排 + `__str` 全分派 + `__type_of`/`__nullstr`/`__mknum`/`__print` 双路径 + 第一批字符串字面量

**Files:**
- Modify: `aot/runtime.ql`
- Create: `aot/tests/t8_str.ql`(三端:host/boot/native)

**Interfaces:**
- Consumes: Task 1 leaf 原语;Task 2 字符串字面量发射。
- Produces: `__type_of(v) → 字符串盒`(返回 interned 盒:`"Number"`/`"String"`/`"Boolean"`/`"Null"`/`"?Array"`/`"?Object"`/`"?Error"`/`"?Function"`);`__str(v) → {buf,len} 对象`(全 tag 分派);`__nullstr()`;`__mknum(x) → 新 NUMBER 盒`(bit 拷贝 payload);`__print(s)` 同时接受 {buf,len} 对象(tag 6)与 STRING 盒(tag 2);顶层标签盒 `__LABEL_ARR`/`__LABEL_OBJ`/`__LABEL_ERR`/`__LABEL_FN`/`__LABEL_NULL` 与键盒 `__K_BUF`/`__K_LEN`。

- [ ] **Step 1: runtime.ql 顶层标签/键盒(放在最前面)**

在 `writeU64` 之前(所有字符串字面量在文件顶部):

```ql
let __LABEL_ARR = "?Array";
let __LABEL_OBJ = "?Object";
let __LABEL_ERR = "?Error";
let __LABEL_FN = "?Function";
let __LABEL_NULL = "null";
let __K_BUF = "buf";
let __K_LEN = "len";
```

> 这批字符串字面量被 qlangc intern,`{buf: b, len: l}` 对象字面量的字段名 `"buf"`/`"len"` 与 `__K_BUF`/`__K_LEN` 内容相同 → 同一盒。这就是"键 = 指针同一"的落点。

- [ ] **Step 2: 重排:哈希/复合原语移到 `__itoa` 前**

现状顺序:`writeU64 → readU64 → allocBox → __itoa → __boolstr → __str → __print → print → println`。M2 后顺序为:

```
writeU64 → readU64 → allocBox → __mknum → __err →
__hash → __obj_new → __obj_get → __obj_set → __rehash →
__norm_idx → __get_length → __get_field → __set_field →
__get_index → __set_index → __arr_add → __arr_remove → __add →
__type_of → __itoa → __boolstr → __nullstr → __str → __print → print → println
```

> 原因:复合原语是纯函数,相互引用(Task 4/5 内容),必须定义在调用者之前;`__str`/`__print`/`__type_of` 在尾部引用 `__LABEL_*`/`__K_*`(顶层 let,顺序无关)。此步先做纯搬移,占位函数体在 Task 4/5 填;`__mknum`/`__err`/`__type_of`/`__nullstr`/`__str` 全分派/`__print` 双路径在本任务完成。**搬移后 `__itoa`/`__boolstr` 不得调用尚未定义的复合原语**(它们不调用,保持纯 M1)。

- [ ] **Step 3: `__mknum` 与 `__err`**

```ql
let __mknum = (x) -> {
  let b = allocBox(1, 16);
  writeU64(b, 8, readU64(x, 8));
  b;
};

let __err = (kind, msg) -> {
  let b = allocBox(8, 32);
  ql_mem_store_ptr(b, 8, kind);
  ql_mem_store_ptr(b, 16, msg);
  b;
};
```

> `__mknum` 用 `readU64` 读出 f64 的原始 8 字节(位模式),`writeU64` 写回新盒 → 位保持,任意 double 精确拷贝。`__err` 的 kind/msg 是字符串盒(M3 的 error read zone 再读)。

- [ ] **Step 4: `__type_of`(嵌套 if/else,返回 interned 标签盒)**

```ql
let __type_of = (v) -> {
  let tag = readU64(v, 0);
  if tag == 1 {
    "Number";
  } else {
    if tag == 2 {
      "String";
    } else {
      if tag == 3 {
        "Boolean";
      } else {
        if tag == 4 {
          "Null";
        } else {
          if tag == 5 {
            __LABEL_ARR;
          } else {
            if tag == 6 {
              __LABEL_OBJ;
            } else {
              if tag == 8 {
                __LABEL_ERR;
              } else {
                __LABEL_FN;
              };
            };
          };
        };
      };
    };
  };
};
```

- [ ] **Step 5: `__nullstr` + `__str` 全分派**

```ql
let __nullstr = () -> {
  { buf: ql_mem_get_ptr(__LABEL_NULL, 8), len: readU64(__LABEL_NULL, 16) };
};

let __str = (v) -> {
  let tag = readU64(v, 0);
  let b = null;       // 分支内临时量,顶层声明(tag 2 分支用)
  let l = 0;
  if tag == 1 {
    __itoa(v);
  } else {
    if tag == 2 {
      b = ql_mem_get_ptr(v, 8);
      l = readU64(v, 16);
      { buf: b, len: l };
    } else {
      if tag == 3 {
        __boolstr(v);
      } else {
        if tag == 4 {
          __nullstr();
        } else {
          if tag == 5 {
            { buf: ql_mem_get_ptr(__LABEL_ARR, 8), len: readU64(__LABEL_ARR, 16) };
          } else {
            if tag == 6 {
              { buf: ql_mem_get_ptr(__LABEL_OBJ, 8), len: readU64(__LABEL_OBJ, 16) };
            } else {
              if tag == 8 {
                { buf: ql_mem_get_ptr(__LABEL_ERR, 8), len: readU64(__LABEL_ERR, 16) };
              } else {
                { buf: ql_mem_get_ptr(__LABEL_FN, 8), len: readU64(__LABEL_FN, 16) };
              };
            };
          };
        };
      };
    };
  };
};
```

- [ ] **Step 6: `__print` 双路径**

替换现有 `__print`(同时处理 {buf,len} 对象 tag 6 与 STRING 盒 tag 2):

```ql
let __print = (s) -> {
  let tag = readU64(s, 0);
  let b = null;       // 分支内临时量,顶层声明(tag 2 分支用)
  let l = 0;
  if tag == 2 {
    b = ql_mem_get_ptr(s, 8);
    l = readU64(s, 16);
    ql_write(1, b, l);
  } else {
    ql_write(1, s.buf, s.len);
  };
  null;
};
```

> tag 2 分支内联读 STRING 盒 `buf@8`/`len@16`;tag 6 分支走 **M1 成员访问** `s.buf`/`s.len`(现 objFieldSlots 槽发射;Task 7 删除 objFieldSlots 后该成员访问自动降级为 `__get_field(s, bufKey)`/`__get_field(s, lenKey)`)。**本任务不依赖 Task 5**,`__print` 双路径在 Task 3 即完整可用。`println` 的换行 `{ buf: nl, len: 1 }` 走 tag 6 路径,继续可用。对 STRING 盒(经由 `__print` 直接传入的场景)`s.buf`/`s.len` 分支不会进入(tag==2 已提前内联)。

- [ ] **Step 7: 写失败测试(三端)**

`aot/tests/t8_str.ql`:

```ql
println("hi");
println("a\nb");
println(42);
println(true);
println(null);
```

期望输出(6 行,`"a\nb"` 含真实换行):

```
hi
a
b
42
true
null
```

三端核对:

```bash
./target/debug/qlang aot/tests/t8_str.ql
./target/debug/qlang bootstrapped/run_file.ql aot/tests/t8_str.ql | tail -n +13 | grep -v '^Execution complete\.'
./target/debug/qlang --compile aot/tests/t8_str.ql -o /tmp/t8_str.bin && /tmp/t8_str.bin
```
三端输出逐字节一致即 PASS。

- [ ] **Step 8: 回归 + Commit**

```bash
bash aot/run_v1_tests.sh   # 全 PASS
git add aot/runtime.ql aot/tests/t8_str.ql
git commit -m "feat(aot): runtime.ql __str full-tag dispatch, __type_of/__nullstr/__mknum, __print dual-path, first string literals (M2 str)"
```

---

### Task 4: runtime.ql 哈希表(__hash / __obj_new / __obj_get / __obj_set / __rehash)

**Files:**
- Modify: `aot/runtime.ql`
- Create: `aot/tests/t8_obj.ql`(NATIVE-only)

**Interfaces:**
- Consumes: Task 1/2/3(writeU64/readU64/allocBox/ql_mem_get_ptr/ql_mem_store_ptr、字符串字面量)。
- Produces: `__hash(key) → 数字`;`__obj_new() → OBJECT 盒`;`__obj_get(o, key) → 值盒|错误盒`;`__obj_set(o, key, v) → void`;`__rehash(o) → void`。OBJECT 盒 `{tag@0=6, table@8, cap@16, count@24}`;桶表 `ql_alloc(16*cap)`,`[k0,v0,k1,v1,...]`,槽 i 键 `table+i*16`、值 `table+i*16+8`;**空槽哨兵 = `__EMPTY`(interned `""` 字符串盒),绝不存 raw 0**。

- [ ] **Step 1: 空槽哨兵**

顶层(与 `__LABEL_*` 同批):

```ql
let __EMPTY = "";
```

> 空槽存 `__EMPTY` 盒而非 raw 0:`k == __EMPTY` 比较两盒 payload f64(box 内 `+8` 的 8 字节),raw 0 不是盒,任何对该值的解引用都会读地址 0~8 → 段错误。真实键盒的 buf 地址 ≠ `""` 的 buf 地址 → 恒不等。对象字段名是标识符,永远不是 `""`,故无冲突。

- [ ] **Step 2: `__hash`**

```ql
let __hash = (key) -> {
  let h = 7;
  let i = 0;
  let b = 0;          // 顶层声明(循环体内 let 不受支持),循环内只赋值
  while i < 24 {
    b = ql_mem_get(key, i);
    h = (h * 31 + b) % 1000003;
    i = i + 1;
  };
  h;
};
```

- [ ] **Step 3: `__obj_new`**

```ql
let __obj_new = () -> {
  let o = allocBox(6, 32);
  let cap = 4;
  let table = ql_alloc(16 * cap);
  let i = 0;
  while i < 8 {
    ql_mem_store_ptr(table, i * 8, __EMPTY);
    i = i + 1;
  };
  ql_mem_store_ptr(o, 8, table);
  writeU64(o, 16, cap);
  writeU64(o, 24, 0);
  o;
};
```

- [ ] **Step 4: `__obj_get`**

线性探测;空槽终止探测。状态机 `state`:0 探测中 / 1 命中 / 2 未命中(空槽)。`found` 存值盒。

```ql
let __obj_get = (o, key) -> {
  let table = ql_mem_get_ptr(o, 8);
  let cap = readU64(o, 16);
  let h = __hash(key);
  let i = 0;
  let state = 0;
  let found = null;
  let slot = 0;       // 循环内临时量,全部顶层声明
  let k = null;
  while state == 0 {
    slot = (h + i) % cap;
    k = ql_mem_get_ptr(table, slot * 16);
    if k == __EMPTY {
      state = 2;
    } else {
      if k == key {
        found = ql_mem_get_ptr(table, slot * 16 + 8);
        state = 1;
      } else {
        i = i + 1;
      };
    };
  };
  if state == 1 {
    found;
  } else {
    __err("UndefinedField", "Undefined field");
  };
};
```

> `k == __EMPTY` / `k == key` 都是"比较两盒 payload f64"(qlangc `==` 无条件内联 fcmp oeq)。键盒永远非 0,安全解引用。

- [ ] **Step 5: `__obj_set` + `__rehash`**

```ql
let __obj_set = (o, key, v) -> {
  let table = ql_mem_get_ptr(o, 8);
  let cap = readU64(o, 16);
  let count = readU64(o, 24);
  let h = __hash(key);
  let i = 0;
  let done = 0;
  let slot = 0;       // 循环内临时量,全部顶层声明
  let k = null;
  while done == 0 {
    slot = (h + i) % cap;
    k = ql_mem_get_ptr(table, slot * 16);
    if k == __EMPTY {
      ql_mem_store_ptr(table, slot * 16, key);
      ql_mem_store_ptr(table, slot * 16 + 8, v);
      count = count + 1;
      writeU64(o, 24, count);
      if count * 10 >= cap * 7 {
        __rehash(o);
      };
      done = 1;
    } else {
      if k == key {
        ql_mem_store_ptr(table, slot * 16 + 8, v);
        done = 1;
      } else {
        i = i + 1;
      };
    };
  };
  null;
};

let __rehash = (o) -> {
  let old = ql_mem_get_ptr(o, 8);
  let cap = readU64(o, 16);
  let newcap = cap * 2;
  let table = ql_alloc(16 * newcap);
  let i = 0;
  while i < newcap * 2 {
    ql_mem_store_ptr(table, i * 8, __EMPTY);
    i = i + 1;
  };
  let j = 0;
  let k = null;       // 以下循环/分支临时量全部顶层声明
  let v = null;
  let h = 0;
  let p = 0;
  let done = 0;
  let slot = 0;
  let k2 = null;
  while j < cap {
    k = ql_mem_get_ptr(old, j * 16);
    if k != __EMPTY {
      v = ql_mem_get_ptr(old, j * 16 + 8);
      h = __hash(k);
      p = 0;
      done = 0;
      while done == 0 {
        slot = (h + p) % newcap;
        k2 = ql_mem_get_ptr(table, slot * 16);
        if k2 == __EMPTY {
          ql_mem_store_ptr(table, slot * 16, k);
          ql_mem_store_ptr(table, slot * 16 + 8, v);
          done = 1;
        } else {
          p = p + 1;
        };
      };
    };
    j = j + 1;
  };
  ql_mem_store_ptr(o, 8, table);
  writeU64(o, 16, newcap);
  null;
};
```

> 负载增长 `count * 10 >= cap * 7` 即 70%;整数域精确。原地换 `table` 指针 → 盒地址不变,别名安全。

- [ ] **Step 6: 写失败测试(NATIVE-only,期望人工核算)**

`aot/tests/t8_obj.ql`:

```ql
let o = __obj_new();
__obj_set(o, "a", 1);
__obj_set(o, "b", 2);
__obj_set(o, "c", 3);
__obj_set(o, "d", 4);
__obj_set(o, "e", 5);
__obj_set(o, "f", 6);
println(__obj_get(o, "a"));
println(__obj_get(o, "f"));
println(__obj_get(o, "c"));
println(__obj_get(o, "d"));
__obj_set(o, "a", 10);
println(__obj_get(o, "a"));
let p = o;
__obj_set(o, "z", 9);
println(__obj_get(p, "z"));
println(__obj_get(p, "a"));
```

期望输出(6 次插入跨 70% 触发两次翻倍 rehash,盒地址不变;`p` 别名读到 `z`):

```
1
6
3
4
10
9
10
```

- [ ] **Step 7: 编译运行确认**

```bash
./target/debug/qlang --compile aot/tests/t8_obj.ql -o /tmp/t8_obj.bin && /tmp/t8_obj.bin
```
先跑一次确认失败(缺 `__obj_new` 等 → 链接错误/`?Error`),实现后逐行匹配期望。

- [ ] **Step 8: 回归 + Commit**

```bash
bash aot/run_v1_tests.sh
git add aot/runtime.ql aot/tests/t8_obj.ql
git commit -m "feat(aot): runtime.ql self-contained hash table — __hash/__obj_new/__obj_get/__obj_set/__rehash, __EMPTY sentinel (M2 obj)"
```

---

### Task 5: runtime.ql 复合原语(__norm_idx / __get_length / __get_field / __set_field / __get_index / __set_index / __arr_add / __arr_remove / __add)

**Files:**
- Modify: `aot/runtime.ql`
- Create: `aot/tests/t8_comp.ql`(NATIVE-only)

**Interfaces:**
- Consumes: Task 3/4(`__obj_get`/`__obj_set`/`__err`/`__mknum`、字符串盒)。
- Produces: 复合值原语。STRING/ARRAY 盒布局见父 spec;`__get_index` 对 STRING 返回单字符 STRING 盒(M2 ASCII 字节语义,白名单无 Unicode)。

- [ ] **Step 1: `__norm_idx`**

```ql
let __norm_idx = (i, len) -> {
  let bad = 0;
  let idx = 0;
  let t = 0;          // 分支内临时量,顶层声明
  if i % 1 != 0 {
    bad = 1;
  } else {
    if i < 0 {
      t = len + i;
      if t < 0 { bad = 1; }
      else { idx = t; };
    } else {
      if i >= len { bad = 1; }
      else { idx = i; };
    };
  };
  if bad == 1 {
    __err("IndexOutOfBounds", "Index out of bounds");
  } else {
    idx;
  };
};
```

> `i % 1 != 0` 捕获非整数与 NaN(NaN % 1 = NaN ≠ 0)。返回 NUMBER 盒或错误盒,调用方用 `readU64(r, 0) == 8` 区分。

- [ ] **Step 2: `__get_length` / `__get_field` / `__set_field`**

```ql
let __get_length = (o, klen) -> {
  let tag = readU64(o, 0);
  if tag == 2 {
    readU64(o, 16);
  } else {
    if tag == 5 {
      readU64(o, 16);
    } else {
      if tag == 6 {
        __obj_get(o, klen);
      } else {
        __err("NotAnObject", "Not an object");
      };
    };
  };
};

let __get_field = (o, key) -> {
  let tag = readU64(o, 0);
  if tag == 6 {
    __obj_get(o, key);
  } else {
    if tag == 5 {
      __err("UndefinedField", "Undefined field");
    } else {
      if tag == 2 {
        __err("NotAnObject", "Not an object");
      } else {
        __err("NotAnObject", "Not an object");
      };
    };
  };
};

let __set_field = (o, key, v) -> {
  let tag = readU64(o, 0);
  if tag == 6 {
    __obj_set(o, key, v);
    null;
  } else {
    __err("NotAnObject", "Not an object");
  };
};
```

- [ ] **Step 3: `__get_index`**

```ql
let __get_index = (c, i) -> {
  let tag = readU64(c, 0);
  let els = null;     // 分支/嵌套内临时量,全部顶层声明(两分支共用槽)
  let len = 0;
  let r = null;
  let buf = null;
  let chb = null;
  let box = null;
  if tag == 5 {
    els = ql_mem_get_ptr(c, 8);
    len = readU64(c, 16);
    r = __norm_idx(i, len);
    if readU64(r, 0) == 8 {
      r;
    } else {
      ql_mem_get_ptr(els, r * 8);
    };
  } else {
    if tag == 2 {
      buf = ql_mem_get_ptr(c, 8);
      len = readU64(c, 16);
      r = __norm_idx(i, len);
      if readU64(r, 0) == 8 {
        r;
      } else {
        chb = ql_alloc(1);
        ql_mem_store(chb, 0, ql_mem_get(buf, r));
        box = allocBox(2, 24);
        ql_mem_store_ptr(box, 8, chb);
        writeU64(box, 16, 1);
        box;
      };
    } else {
      __err("CannotIndex", "Cannot index");
    };
  };
};
```

> `ql_mem_get_ptr(els, r * 8)` 中 r 是 NUMBER 盒;`r * 8` → 内联 fmul → NUMBER 盒;leaf arg 位置经 `boxToInt`。`ql_mem_get(buf, r)` 同理由 `boxToInt` 取整。

- [ ] **Step 4: `__set_index`**

```ql
let __set_index = (c, i, v) -> {
  let tag = readU64(c, 0);
  let els = null;     // 分支/循环内临时量,全部顶层声明
  let len = 0;
  let ne = null;
  let k = 0;
  let r = null;
  if tag == 5 {
    els = ql_mem_get_ptr(c, 8);
    len = readU64(c, 16);
    if i == len {
      ne = ql_alloc(8 * (len + 1));
      k = 0;
      while k < len {
        ql_mem_store_ptr(ne, k * 8, ql_mem_get_ptr(els, k * 8));
        k = k + 1;
      };
      ql_mem_store_ptr(ne, len * 8, v);
      ql_mem_store_ptr(c, 8, ne);
      writeU64(c, 16, len + 1);
      null;
    } else {
      r = __norm_idx(i, len);
      if readU64(r, 0) == 8 {
        r;
      } else {
        ql_mem_store_ptr(els, r * 8, v);
        null;
      };
    };
  } else {
    if tag == 2 {
      __err("CannotIndex", "Cannot index a string");
    } else {
      __err("CannotIndex", "Cannot index");
    };
  };
};
```

> `i == len` 比较两盒 payload(NUMBER 盒 payload 相等即 f64 相等),命中 append(c37 镜像);越界 → 错误盒(host 是硬错误,白名单不含这类 case,记为已知近似)。

- [ ] **Step 5: `__arr_add` / `__arr_remove`**

```ql
let __arr_add = (a, v) -> {
  let els = ql_mem_get_ptr(a, 8);
  let len = readU64(a, 16);
  let ne = ql_alloc(8 * (len + 1));
  let k = 0;
  while k < len {
    ql_mem_store_ptr(ne, k * 8, ql_mem_get_ptr(els, k * 8));
    k = k + 1;
  };
  ql_mem_store_ptr(ne, len * 8, v);
  ql_mem_store_ptr(a, 8, ne);
  writeU64(a, 16, len + 1);
  null;
};

let __arr_remove = (a, i) -> {
  let els = ql_mem_get_ptr(a, 8);
  let len = readU64(a, 16);
  let r = __norm_idx(i, len);
  let j = 0;          // 分支内临时量,顶层声明
  if readU64(r, 0) == 8 {
    null;
  } else {
    j = r;
    while j < len - 1 {
      ql_mem_store_ptr(els, j * 8, ql_mem_get_ptr(els, (j + 1) * 8));
      j = j + 1;
    };
    writeU64(a, 16, len - 1);
    null;
  };
};
```

> 坏下标静默 no-op(host 镜像),返回 Void。

- [ ] **Step 6: `__add`**

```ql
let __add = (a, b) -> {
  let ta = readU64(a, 0);
  let tb = readU64(b, 0);
  let ab = null;      // 分支/循环内临时量,全部顶层声明
  let al = 0;
  let bb = null;
  let bl = 0;
  let nb = null;
  let i = 0;
  let j = 0;
  let box = null;
  if ta == 2 && tb == 2 {
    ab = ql_mem_get_ptr(a, 8);
    al = readU64(a, 16);
    bb = ql_mem_get_ptr(b, 8);
    bl = readU64(b, 16);
    nb = ql_alloc(al + bl);
    i = 0;
    while i < al {
      ql_mem_store(nb, i, ql_mem_get(ab, i));
      i = i + 1;
    };
    j = 0;
    while j < bl {
      ql_mem_store(nb, al + j, ql_mem_get(bb, j));
      j = j + 1;
    };
    box = allocBox(2, 24);
    ql_mem_store_ptr(box, 8, nb);
    writeU64(box, 16, al + bl);
    box;
  } else {
    __err("TypeMismatch", "Type mismatch");
  };
};
```

- [ ] **Step 7: 写失败测试(NATIVE-only,期望人工核算)**

`aot/tests/t8_comp.ql`:

```ql
let mkarr = (a, b, c) -> {
  let arr = allocBox(5, 24);
  let els = ql_alloc(24);
  ql_mem_store_ptr(els, 0, a);
  ql_mem_store_ptr(els, 8, b);
  ql_mem_store_ptr(els, 16, c);
  ql_mem_store_ptr(arr, 8, els);
  writeU64(arr, 16, 3);
  arr;
};
let a = mkarr(1, 2, 3);
println(__get_index(a, 0));
println(__get_index(a, -1));
println(__get_index(a, 1));
__arr_add(a, 4);
println(__get_length(a, "length"));
println(__get_index(a, 3));
__arr_remove(a, 0);
println(__get_index(a, 0));
println(__get_length(a, "length"));
let s = "abc";
println(__get_index(s, 0));
println(__get_index(s, 2));
println(__add("ab", "cd"));
let o = __obj_new();
__obj_set(o, "buf", 1);
__obj_set(o, "len", 2);
println(__get_field(o, "buf"));
```

期望输出:

```
1
3
2
4
4
2
3
a
c
abcd
1
```

> **不用对象字面量 `{ buf: 1, len: 2 }` 构造被测对象**:M1 objFieldSlots 布局(字段存 `[obj+16+8*slot]`)不是哈希表,`__get_field` → `__obj_get` 会读 `[obj+8]`(未初始化)→ 段错误。此处显式 `__obj_new`+`__obj_set` 构造哈希对象(独立于 Task 7),任何顺序都稳定输出 1。Task 7 删除 objFieldSlots 后对象字面量同样走哈希表,语义一致。

- [ ] **Step 8: 编译运行 + 回归 + Commit**

```bash
./target/debug/qlang --compile aot/tests/t8_comp.ql -o /tmp/t8_comp.bin && /tmp/t8_comp.bin
bash aot/run_v1_tests.sh
git add aot/runtime.ql aot/tests/t8_comp.ql
git commit -m "feat(aot): runtime.ql composite primitives — get/set index, length, field, arr add/remove, str concat (M2 comp)"
```

---

### Task 6: qlangc Array literal + GetIndex/SetIndex emit

**Files:**
- Modify: `aot/qlangc.ql`
- Create: `aot/tests/t8_arr.ql`(NATIVE-only)

**Interfaces:**
- Consumes: Task 5 原语(`__get_index`/`__set_index`);`emitCallRegs` 辅助(本任务新建,Task 7/8 复用)。
- Produces: `emitArrayExpr(node) → 盒寄存器`;`emitGetIndex(node) → 寄存器`;`emitAssignStmt` 的 `IndexAccess` 目标分支;`emitCallRegs(fname, argRegs) → 寄存器`(用已算好的寄存器组构造 args 数组 + 通用调用,callee 经 `emitIdentifier(fname)` 查全局帧)。

- [ ] **Step 1: `emitCallRegs` 辅助**

从 `emitCall` 通用分支(约 540–566 行)抽出的公共调用:给定 callee 名与**已计算的参数寄存器**,构造 args 数组并调用。插入 `emitCall` 之前:

```ql
let emitCallRegs = (fname, argRegs) -> {
  let FN = emitIdentifier(fname);
  let narg = argRegs.length;
  let arr = temp();
  line("  " + arr + " = call ptr @ql_alloc(i64 " + std.String.toString(8 * narg) + ")");
  let i = 0;
  while i < narg {
    let aoff = temp();
    line("  " + aoff + " = getelementptr ptr, ptr " + arr + ", i64 " + std.String.toString(i));
    line("  store ptr " + argRegs[i] + ", ptr " + aoff);
    i = i + 1;
  };
  let codep = temp();
  let codev = temp();
  line("  " + codep + " = getelementptr i8, ptr " + FN + ", i64 8");
  line("  " + codev + " = load ptr, ptr " + codep);
  let envp = temp();
  let envv = temp();
  line("  " + envp + " = getelementptr i8, ptr " + FN + ", i64 16");
  line("  " + envv + " = load ptr, ptr " + envp);
  let r = temp();
  line("  " + r + " = call ptr " + codev + "(ptr " + envv + ", ptr " + arr + ", i64 " + std.String.toString(narg) + ")");
  r;
};
```

> runtime.ql 函数是顶层 let → 全局帧槽 → `emitIdentifier(fname)` 解析成功。callee 名如 `"__get_index"`/`"__obj_set"`。

- [ ] **Step 2: `emitArrayExpr`**

```ql
let emitArrayExpr = (node) -> {
  let b = temp();
  line("  " + b + " = call ptr @ql_alloc(i64 24)");
  line("  store i64 5, ptr " + b);                    // tag ARRAY
  let n = node.elements.length;
  let els = temp();
  line("  " + els + " = call ptr @ql_alloc(i64 " + std.String.toString(8 * n) + ")");
  let eoff = temp();
  line("  " + eoff + " = getelementptr i8, ptr " + b + ", i64 8");
  line("  store ptr " + els + ", ptr " + eoff);
  let i = 0;
  while i < n {
    let v = emitExpr(node.elements[i]);
    let aoff = temp();
    line("  " + aoff + " = getelementptr ptr, ptr " + els + ", i64 " + std.String.toString(i));
    line("  store ptr " + v + ", ptr " + aoff);
    i = i + 1;
  };
  let loff = temp();
  line("  " + loff + " = getelementptr i8, ptr " + b + ", i64 16");
  line("  store i64 " + std.String.toString(n) + ", ptr " + loff);
  b;
};
```

- [ ] **Step 3: emitExpr dispatch 加 Array / IndexAccess**

```ql
} else if node.type == "Array" {
  emitArrayExpr(node);
} else if node.type == "IndexAccess" {
  let C = emitExpr(node.object);
  let I = emitExpr(node.index);
  emitCallRegs("__get_index", [C, I]);
}
```

- [ ] **Step 4: emitAssignStmt 加 IndexAccess 目标分支**

在 `emitAssignStmt` 的 Identifier 分支旁:

```ql
} else if node.target.type == "IndexAccess" {
  let O = emitExpr(node.target.object);
  let I = emitExpr(node.target.index);
  let V = emitExpr(node.value);
  emitCallRegs("__set_index", [O, I, V]);
}
```

> `a[a.length] = v` 时 `node.target.index` 是 MemberAccess `.length` → 本任务阶段 `a.length` 还未降级(Task 7),会走 M1 objFieldSlots 未知槽 → emitNull。c37 镜像的 append 在 Task 7 之后全通;本任务测试先不用 `a[a.length]` 下标。

- [ ] **Step 5: 写失败测试(NATIVE-only)**

`aot/tests/t8_arr.ql`:

```ql
let a = [1, 2, 3];
println(a[1]);
println(a[-1]);
println(a[0]);
a[3] = 4;
println(a[3]);
a[0] = 9;
println(a[0]);
let b = [];
println(b.length);
let c = [[1, 2], [3, 4]];
println(c[1][0]);
```

> `b.length` 依赖 Task 7 的 MemberAccess 降级;`c[1][0]` 是嵌套 IndexAccess(递归 emit,本任务即可)。**Task 6 阶段的完整输出为 `2 3 1 4 9 null 3`(b.length 走 M1 未知槽 → emitNull → `null`)**;本任务断言前五行 `2 3 1 4 9`。Task 7 完成后 `b.length` 降级为 `__get_length` → 0,全量输出变 `2 3 1 4 9 0 3`,在 Task 7 Step 7 核对。

```
2
3
1
4
9
```

- [ ] **Step 6: 编译运行**

```bash
./target/debug/qlang --compile aot/tests/t8_arr.ql -o /tmp/t8_arr.bin && /tmp/t8_arr.bin
```
先跑确认失败(Array literal 未实现 → 语法/发射错误),实现后前五行匹配。

- [ ] **Step 7: 回归 + Commit**

```bash
bash aot/run_v1_tests.sh
git add aot/qlangc.ql aot/tests/t8_arr.ql
git commit -m "feat(aot): qlangc Array literal + index get/set emit, emitCallRegs helper (M2 arr)"
```

---

### Task 7: qlangc Object literal + member access 降级 + assign 目标分派 + `.add/.remove` 调用降级

**Files:**
- Modify: `aot/qlangc.ql`
- Create: `aot/tests/t8_member.ql`(NATIVE-only)

**Interfaces:**
- Consumes: Task 2 internString / Task 4 哈希原语 / Task 5 复合原语 / Task 6 emitCallRegs。
- Produces: `emitObjectExpr(node)`(删 objFieldSlots,`__obj_new()` + N×`__obj_set`);`emitMemberAccess(node)`(`.length`→`__get_length(o, lenKey)`;否则→`__get_field(o, key)`);`emitCall` 的 `.add(x)`/`.remove(i)` 特殊降级;`emitAssignStmt` 的 `MemberAccess` 目标分支。

- [ ] **Step 1: 删除 `objFieldSlots` 与旧 object emit**

删除 23 行 `let objFieldSlots = {};`、`emitObjectExpr`(579–599 行)、`emitMemberAccess`(602–615 行)中的槽映射逻辑,替换为:

```ql
let emitObjectExpr = (node) -> {
  let o = emitCallRegs("__obj_new", []);
  let i = 0;
  while i < node.fields.length {
    let f = node.fields[i];
    let V = emitExpr(f.value);
    let key = internString(f.name);
    emitCallRegs("__obj_set", [o, key, V]);
    i = i + 1;
  };
  o;
};

let emitMemberAccess = (node) -> {
  let O = emitExpr(node.object);
  if node.field == "length" {
    let k = internString("length");
    emitCallRegs("__get_length", [O, k]);
  } else {
    let k = internString(node.field);
    emitCallRegs("__get_field", [O, k]);
  };
};
```

- [ ] **Step 2: emitExpr dispatch 加 Object / MemberAccess**

```ql
} else if node.type == "Object" {
  emitObjectExpr(node);
} else if node.type == "MemberAccess" {
  emitMemberAccess(node);
}
```

- [ ] **Step 3: emitAssignStmt 加 MemberAccess 目标分支**

```ql
} else if node.target.type == "MemberAccess" {
  let O = emitExpr(node.target.object);
  let V = emitExpr(node.value);
  let key = internString(node.target.field);
  emitCallRegs("__set_field", [O, key, V]);
}
```

- [ ] **Step 4: emitCall 加 `.add`/`.remove` 调用降级**

在 `emitCall` 的 `isLeaf` 判断之后、通用分支之前插入(callee 是 MemberAccess 且字段为 `add`/`remove` 时,调用形状直接降级):

```ql
if isLeaf(cname) {
  ...原 isLeaf 分支...
} else if node.callee.type == "MemberAccess" && node.callee.field == "add" && node.arguments.length >= 1 {
  let O = emitExpr(node.callee.object);
  let V = emitExpr(node.arguments[0]);
  emitCallRegs("__arr_add", [O, V]);
} else if node.callee.type == "MemberAccess" && node.callee.field == "remove" && node.arguments.length >= 1 {
  let O = emitExpr(node.callee.object);
  let I = emitExpr(node.arguments[0]);
  emitCallRegs("__arr_remove", [O, I]);
} else if calleeIsId || node.callee.type == "MemberAccess" {
  ...原通用分支...
}
```

> 单独取 `.add`/`.remove` 值(MemberAccess 而非 Call)走 `__get_field` → ARRAY 非 length → 错误盒,符合 spec 决策 3(M2 surface 外)。

- [ ] **Step 5: 写失败测试(NATIVE-only)**

`aot/tests/t8_member.ql`:

```ql
let o = { a: 1, b: 2 };
println(o.a);
println(o.b);
o.a = 5;
println(o.a);
let p = o;
o.b = 7;
println(p.b);
let s = "abc";
println(s.length);
let a = [1, 2, 3];
println(a.length);
a.add(4);
println(a.length);
println(a[3]);
a.remove(0);
println(a[0]);
println(a.length);
let o2 = { length: 5 };
println(o2.length);
let c = [[1, 2], [3, 4]];
println(c[1][0]);
```

期望输出:

```
1
2
5
7
3
3
4
4
2
2
5
3
```

> 覆盖:字段读写、别名同一、`.length` 三 tag、`.add`/`.remove` 降级、对象 `length` 字段回退(`__get_length` tag 6 → `__obj_get`)、嵌套数组。

- [ ] **Step 6: 编译运行**

```bash
./target/debug/qlang --compile aot/tests/t8_member.ql -o /tmp/t8_member.bin && /tmp/t8_member.bin
```
先跑确认失败(Object literal 仍走槽映射 → 字段盒对不上),实现后逐行匹配。

- [ ] **Step 7: 补 Task 6 的 `t8_arr.ql` 全量核对 + 回归 + Commit**

```bash
./target/debug/qlang --compile aot/tests/t8_arr.ql -o /tmp/t8_arr.bin && /tmp/t8_arr.bin
# 期望含 b.length=0、c[1][0]=3
bash aot/run_v1_tests.sh
git add aot/qlangc.ql aot/tests/t8_member.ql aot/tests/t8_arr.ql
git commit -m "feat(aot): qlangc Object literal -> __obj_new/__obj_set, member access lowering, assign target dispatch, .add/.remove call lowering (M2 member)"
```

---

### Task 8: `+` 双字符串字面量 → `__add`

**Files:**
- Modify: `aot/qlangc.ql`
- Create: `aot/tests/t8_concat.ql`(NATIVE-only)

**Interfaces:**
- Consumes: Task 5 `__add`;Task 6 `emitCallRegs`。
- Produces: `emitBinaryOp` 中 `+` 的编译期静态判定:左右**都是 String 字面量节点** → `__add(L, R)`;否则保留 M1 内联 fadd。

- [ ] **Step 1: emitBinaryOp 的 `+` 分支**

在 `emitBinaryOp`(94–140 行)的 `+` 分支内,先用已算出的 L/R 寄存器判断:

```ql
if op == "+" {
  if node.left.type == "String" && node.right.type == "String" {
    emitCallRegs("__add", [L, R]);
  } else {
    ...现有内联 fadd 的 L/R 逻辑...
  };
} else ...
```

> L/R 在 emitBinaryOp 开头已由 emitExpr 算出。`"ab" + "cd"` → `__add(abBox, cdBox)`;`"a" + 1` 或变量拼接不满足双字面量 → 仍走 fadd(白名单不含)。

- [ ] **Step 2: 写失败测试(NATIVE-only)**

`aot/tests/t8_concat.ql`:

```ql
println("ab" + "cd");
println("x" + "y" + "z");
let a = "he";
let b = "llo";
println(a + b);
```

> `"x" + "y" + "z"` 是左结合:内层 `"x"+"y"` 双字面量 → `__add` 返回运行时 STRING 盒;外层 `+` 左操作数不是字面量节点(是 Call)→ 走 fadd → **发散**。故期望只保留第一行 `abcd`;后两行在本任务只保证编译通过不崩。白名单不覆盖变量拼接。

期望输出(首行):

```
abcd
```

- [ ] **Step 3: 编译运行 + 回归 + Commit**

```bash
./target/debug/qlang --compile aot/tests/t8_concat.ql -o /tmp/t8_concat.bin && /tmp/t8_concat.bin
# 首行输出 abcd;后两行允许非预期(发散,fadd)但不得崩溃
bash aot/run_v1_tests.sh
git add aot/qlangc.ql aot/tests/t8_concat.ql
git commit -m "feat(aot): compile-time double-String-literal '+' -> __add, keep inline fadd otherwise (M2 concat)"
```

---

### Task 9: difftest.py 四端升级(NATIVE 列 + NATIVE_CASES 白名单 + native_disp + m 系列 SAFE_CASES + NODE_CASES)

**Files:**
- Modify: `difftest.py`

**Interfaces:**
- Consumes: 现有 `SAFE_CASES`/`COMPLEX_CASES`/`RISKY_CASES`/`NODE_CASES`/`host_disp`/`boot_disp`/`last_expr`/`norm_err`/`hres` 结构;M2 全部原语。
- Produces: `NATIVE_CASES` 白名单;`native_disp()`(只用 qlangc+runtime.ql 能编译的构造,类型探测走 `__type_of`,渲染走 `__str`);`write_native_one(path, cid, src)`;main 的 NATIVE 段(编译→跑 ELF→取 `cid=` 行→与 host 值对比);`SAFE_CASES` m01–m12;对应 `NODE_CASES` JS 翻译。

- [ ] **Step 1: 新增 SAFE_CASES m 系列(操作面 = medium)**

追加到 `SAFE_CASES`(保持纯整数域、成功路径、不用字符串相等):

```python
("m01", "let a = [1, 2]; a.add(3); a.length;"),
("m02", "let a = [1, 2]; a.add(3); a[2];"),
("m03", "let a = [1, 2, 3]; a.remove(0); a.length;"),
("m04", "let a = [1, 2, 3]; a.remove(1); a[0] + a[1];"),
("m05", "let o = { a: 1 }; o.b = 2; o.a + o.b;"),
("m06", "let o = { a: 1 }; o.a = 5; o.a;"),
("m07", 'let s = "ab"; s[0] + s[1];'),
("m08", "let a = []; a.add(1); a.add(2); a.length;"),
("m09", "let a = [1]; a.remove(0); a.length;"),
("m10", "let o = { a: [1, 2] }; o.a.length;"),
('m11', 'let s = "hello"; s.length;'),
("m12", "let a = [1, 2, 3]; let i = 1; a[i];"),
```

> 这些 case 必须同时在 host/boot 全绿(`SAFE_CASES` 自动覆盖);m07 的 `s[0] + s[1]` 两操作数都是**变量**不是字面量 → 走 fadd 发散,故 m07 **不进 NATIVE_CASES**(host/boot 照常)。

- [ ] **Step 2: NODE_CASES 补 JS 翻译**

为 m01–m12 加 JS 等价(`.add`→`.push`、`.remove`→`.splice(i,1)`):

```python
("m01", "let a = [1, 2]; a.push(3); a.length;"),
("m02", "let a = [1, 2]; a.push(3); a[2];"),
("m03", "let a = [1, 2, 3]; a.splice(0, 1); a.length;"),
("m04", "let a = [1, 2, 3]; a.splice(1, 1); a[0] + a[1];"),
("m05", "let o = { a: 1 }; o.b = 2; o.a + o.b;"),
("m06", "let o = { a: 1 }; o.a = 5; o.a;"),
("m07", 'let s = "ab"; s[0] + s[1];'),
("m08", "let a = []; a.push(1); a.push(2); a.length;"),
("m09", "let a = [1]; a.splice(0, 1); a.length;"),
("m10", "let o = { a: [1, 2] }; o.a.length;"),
("m11", 'let s = "hello"; s.length;'),
("m12", "let a = [1, 2, 3]; let i = 1; a[i];"),
```

- [ ] **Step 3: native_disp()**

在 `boot_disp` 旁加(生成 .ql 的一部分;只走 runtime.ql 原语;**嵌套 if/else**;`t == "Number"` 走 interned 盒 f64 比较):

```python
def native_disp():
    return (
        "let disp = (v) -> {\n"
        "  let t = __type_of(v);\n"
        '  if t == "Number" {\n'
        "    __itoa(v);\n"
        "  } else {\n"
        '    if t == "String" {\n'
        "      __str(v);\n"
        "    } else {\n"
        '      if t == "Boolean" {\n'
        "        __boolstr(v);\n"
        "      } else {\n"
        '        if t == "Null" {\n'
        "          __nullstr();\n"
        "        } else {\n"
        "          __str(v);\n"
        "        };\n"
        "      };\n"
        "    };\n"
        "  };\n"
        "};\n"
    )
```

> 渲染:Number→`__itoa`(整数域)、String→`__str`(tag 2 → {buf,len})、Boolean/Null、其余(数组/对象/错误 tag 5/6/8)→ `__str` 发 `"?Array"`/`"?Object"`/`"?Error"` 标签。`__type_of` 返回的标签盒与 disp 源里的字面量同内容 → 同 intern 盒 → fcmp 命中。**不使用字符串 `+` 拼接**(非双字面量,发散)。

- [ ] **Step 4: write_native_one()**

生成单个 NATIVE case 的独立 `.ql`(compile 时 runtime.ql 自动前置;`__print` 直出 disp 结果,因为 disp 返回 {buf,len} 对象,走 `print` 会再被 `__str` 打上对象标签):

```python
def write_native_one(path, cid, src):
    with open(path, "w") as f:
        f.write(native_disp())
        f.write(src + "\n")
        f.write('print("{}=");\n'.format(cid))
        f.write("__print(disp(%s));\n" % last_expr(src))
        f.write('print("\\n");\n')
```

- [ ] **Step 5: NATIVE_CASES 白名单**

在模块顶部加(只放 M1 回归 + M2-surface 整数域;排除 c17/c18/c19/c21(字符串相等/Unicode)、c32(含 `return`)、c33/c34(柯里化 `f(3)(4)`)、e/r 错误与 RISKY、非整数域):

```python
NATIVE_CASES = [
    # M1 回归(数值/控制/短路/闭包)
    "c01", "c02", "c03", "c04", "c05", "c06", "c07", "c08", "c09", "c10",
    "c11", "c12", "c13", "c20", "c22", "c23", "c24", "c25", "c26", "c27",
    "c28", "c29", "c30", "c31", "c35", "c42", "c43", "c44", "c45", "c46",
    "c47", "c48", "c54",
    # M2 surface:字符串/数组/对象(整数域)
    "c14", "c15", "c16", "c36", "c37", "c38", "c39", "c41", "c49", "c50",
    "c51", "c52", "c53", "c56",
    # M2 新增
    "m01", "m02", "m03", "m04", "m05", "m06", "m08", "m09", "m10", "m11", "m12",
]
```

> c37 `a[a.length] = 5` 依赖 `a.length` 在 IndexAccess 下标里走 member access 降级(Task 7);c41 嵌套数组;c49 `"a\nb".length` 验证转义表;c53 `p == o` 验证指针同一。**m07 不进**(变量拼接 fadd 发散)。

- [ ] **Step 6: main 加 NATIVE 段**

在现 main 末尾(host/boot/node 全量之后)追加。host 值直接复用 `hres`(白名单 ⊆ SAFE_CASES):

```python
print("=== NATIVE cases (M2 whitelist) ===")
nc_fail = 0
for cid in NATIVE_CASES:
    src = dict(SAFE_CASES)[cid]
    ql = os.path.join(tmp, "_df_native_%s.ql" % cid)
    binp = os.path.join(tmp, "_df_native_%s.bin" % cid)
    write_native_one(ql, cid, src)
    r = subprocess.run(CARGO + ["--compile", ql, "-o", binp],
                       cwd=ROOT, capture_output=True, text=True)
    if r.returncode != 0:
        print("NATIVE COMPILE-FAIL %s: %s" % (cid, r.stderr.strip()))
        nc_fail = 1
        continue
    run = subprocess.run([binp], capture_output=True, text=True)
    if run.returncode != 0:
        print("NATIVE RUN-FAIL %s (rc=%s): %s" % (cid, run.returncode, run.stderr.strip()))
        nc_fail = 1
        continue
    line = [l for l in run.stdout.splitlines() if l.startswith(cid + "=")]
    nval = norm_err(line[0].split("=", 1)[1]) if line else "ERR"
    # SAFE_CASES 的 hres[cid][1][0] 是**去前缀的值**(hmap 已在 `cid=` 处切开),没有
    # 前缀可剥;norm_err(v, cid) 只在 v 确实带前缀时剥,与 diff_case 的宿主归一完全一致。
    hval = norm_err(hres[cid][1][0], cid)
    if nval == hval:
        print("NATIVE PASS %s" % cid)
    else:
        print("NATIVE FAIL %s: native=%r host=%r" % (cid, nval, hval))
        nc_fail = 1
print("=== NATIVE done ===")
```

> `hres[cid]` = `(exit_code, lines, stderr)`;`hres[cid][1][0]` = lines 首行。SAFE_CASES 的该值已被 hmap 剥掉 `cid=` 前缀(纯值),RISKY/COMPLEX 的才是整行 —— 但白名单 ⊆ SAFE_CASES,统一走 `norm_err(value, cid)`(前缀存在才剥)。NATIVE 侧 ELF 输出整行 `cid=value`(write_native_one 的 `print("cid=")` 序列),故 `split("=",1)[1]` 正确。

- [ ] **Step 7: 运行 difftest 全量**

```bash
python3 difftest.py
```
期望:`SAFE: N/N (was N/N)` 计数随 m 系列增加且全绿;`NATIVE PASS` 覆盖白名单全部;host/boot/node 三端全量无回归。逐一修白名单 case 的 native 发散(多为漏降级),不改 host/boot。

- [ ] **Step 8: Commit**

```bash
git add difftest.py
git commit -m "feat(aot): difftest four-end — NATIVE column, NATIVE_CASES whitelist, native_disp, m-series SAFE+NODE cases (M2 difftest)"
```

---

### Task 10: M2 出口 gate

**Files:**
- 无新增代码文件;执行验证。

**Interfaces:**
- Consumes: Task 1–9 全部。

- [ ] **Step 1: 全量 difftest 四端**

```bash
python3 difftest.py
```
期望:host/boot/node 全量全绿(SAFE/COMPLEX/RISKY/NODE 计数不减,含 m 系列);NATIVE 白名单全 PASS。

- [ ] **Step 2: M1 v1 测试集三端一致不回归**

```bash
bash aot/run_v1_tests.sh
```
期望:全部 PASS。

- [ ] **Step 3: 零新 native 审计**

```bash
grep -n "ql_mem_get_ptr\|ql_mem_store_ptr" aot/runtime.c
```
期望:仅这两个(回退免费,`readU64`/`writeU64` 全局替换语义逐字节相同)。`--compile` 驱动、qlangc、difftest 无其他 native 新增。

- [ ] **Step 4: NATIVE 白名单三端逐字节一致抽查**

对白名单中每个 cid,host/boot/native 三端输出 diff 为空(白名单值已由 `NATIVE PASS` 对齐 host;boot 由 SAFE_CASES 全量覆盖保证,抽查 3 个 M2 case 人工 diff):

```bash
for c in m01 m05 m10; do
  python3 - <<PY
import difftest as D
cid="$c"
src=dict(D.SAFE_CASES)[cid]
open("/tmp/_g_$c.ql","w").write(D.native_disp()+src+'\nprint("X=");\n__print(D.last_expr(src));\nprint("\\n");\n')
PY
  ./target/debug/qlang --compile /tmp/_g_$c.ql -o /tmp/_g_$c.bin >/dev/null 2>&1 && /tmp/_g_$c.bin
done
```

> 若 difftest 已按 hres 对齐 host 且 boot 全量绿,抽查仅作额外证据。

- [ ] **Step 5: 汇总 + 收尾 commit(若测试文件有调整)**

```bash
git add -A
git status
git commit -m "test(aot): M2 gate green — four-end difftest + v1 suite + NATIVE whitelist (M2 exit)"
```

---

## 自检(Self-Review)

**Spec 覆盖:**
- §盒布局(STRING/ARRAY/OBJECT)→ Task 1(槽原语)、Task 2(STRING 盒发射)、Task 6(ARRAY 盒)、Task 4(OBJECT 盒)。
- §哈希函数 31/1000003 → Task 4 `__hash`。
- §键 = 指针同一(编译期名字识别)→ Task 2 intern + Task 4/7(字段名盒 + `k == key` payload 比较)。
- §runtime.ql 原语表(__hash/__obj_new/__obj_get/__obj_set/__get_length/__get_field/__get_index/__set_index/__arr_add/__arr_remove/__add/__err/__type_of)→ Task 4/5。
- §第一批字符串字面量(?Array/?Object/?Error)→ Task 3 `__LABEL_*`。
- §leaf 扩展(ql_mem_get_ptr/ql_mem_store_ptr,性能原语)→ Task 1。
- §渲染模型(native_disp 用 __type_of;不需要整体容器渲染)→ Task 9。
- §验证策略四端 difftest + NATIVE_CASES 白名单 → Task 9/10。
- §qlangc emit 表(String literal/.rodata、Array、Object 降级、GetIndex/SetIndex、.length、.field、.add/.remove、`+` 静态双字面量)→ Task 2/6/7/8。
- §M2 出口标准 4 条 → Task 10。
- 四个关键设计决策(键指针同一、{buf,len} 字面量零改动、.add/.remove 调用形状降级、错误盒统一)→ Task 4/7/5。

**Placeholder 扫描:** 无 TBD/TODO;每个实现步骤带完整 qlangc/runtime.ql/Python 代码;测试步骤带期望输出;文件路径全显式。

**类型一致性:**
- leaf 名 `ql_mem_get_ptr`/`ql_mem_store_ptr` 在 Task 1(runtime.c/qlangc/prelude)与 Task 4/5(runtime.ql 调用)一致。
- 原语签名 `__obj_set(o,key,v)`/`__get_index(c,i)`/`__get_length(o,klen)`/`__arr_add(a,v)`/`__arr_remove(a,i)`/`__add(a,b)` 在 Task 4/5 定义、Task 6/7/8 emit 调用一致。
- `emitCallRegs(fname, argRegs)` 在 Task 6 引入,Task 7/8 复用,参数为寄存器名数组一致。
- 白名单 cid 均在 SAFE_CASES 且不为 m07(变量拼接发散);`norm_err`/`hres[cid][1][0]` 按 difftest 实际结构取 host 值,Step 6 注明按实际结构调整。

**已知近似(不阻塞 M2 gate):**
- `__set_index` 越界返回错误盒 vs host 硬错误 → 白名单不含这类 case。
- `"x"+"y"+"z"` 嵌套拼接与变量拼接走 fadd 发散 → 白名单只测双字面量。
- 单字符 `s[i]` 是字节索引(ASCII);Unicode case 不进 NATIVE。
- **预检裁定(2026-08-15,见 SDD ledger):** ① `null` 盒 intern 为全局 16B 盒(Task 2 Step 4)修复 c22/c23 三端发散;② `@ql_truthy` 对 STRING/ARRAY/OBJECT/FUNCTION/ERROR 恒假(host 非空复合为真)→ **M2 白名单无一 case 触发**(c25/c26/c27 条件均假侧、c46 空串假侧),**记 ledger 已知发散,推迟 M3**(419/419 会强制修);③ `null == 0` payload 比较仍发散,白名单无此 case,推迟 M3。
