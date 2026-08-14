// aot/tests/m0_itoa_driver.ql — boot 侧:M0 验证 runtime.ql __itoa 与手写 IR 输出一致
// (controller R4) boot import 只合并 export,故本 driver 自包含:把 m0_mem_mock.ql 与 ../runtime.ql
// 的内容原样内联到顶部(删掉原 import 行)。mock / runtime.ql 各自保持与 brief 逐字节一致。
// (plan known-risk #2 fallback) host stdlib 的 std.String 模块无 fromCodePoint(README 有文档但未实现),
// 故在调用 ql_write 前补一个 polyfill;mock 与 runtime.ql 文件不改动。
// (R4 自包含 paste 副作用修正)runtime.ql 的顶层 let println 会遮蔽 host 原生 println,而 mock 的
// ql_write 依赖 host println;故在 paste 之前先捕获原生 println,再在 body 之前恢复。

let __host_stdout = println;                    // 捕获 host 原生 println(在 runtime.ql 遮蔽之前)

// --- 以下为 aot/tests/m0_mem_mock.ql 全文(verbatim)---
// aot/tests/m0_mem_mock.ql — boot 上模拟 leaf 内存函数(数组模拟内存,偏移 = 地址)
// 仅供 M0 boot 侧验证 runtime.ql 逻辑,不进产物。
let mem = {};
let heapTop = 0;
let ql_alloc = (n) -> {
  let p = heapTop;
  heapTop = heapTop + n;
  p;
};
let ql_mem_store = (p, off, v) -> { mem[p + off] = v; };
let ql_mem_get = (p, off) -> mem[p + off];
let ql_write = (fd, buf, len) -> {
  // boot 无裸内存读;把字节序列读回并 println(boot 打印字符串)
  let chars = "";
  let i = 0;
  while i < len {
    chars = chars + std.String.fromCodePoint(mem[buf + i]);
    i = i + 1;
  };
  println(chars);
};
// --- 以下为 aot/runtime.ql 全文(verbatim)---
// aot/runtime.ql — 编译进产物的运行时语义层(QLang)
// 仅依赖 leaf:ql_alloc / ql_mem_get / ql_mem_store / ql_write / ql_exit。
// 内存函数(对象头、字符串缓冲)全部封装于此,不暴露给编译器。
// QLang 无移位符 → u64 字节读写用「除 256 + 取模」分解/合成。

let writeU64 = (p, off, v) -> {
  let b0 = v % 256;        ql_mem_store(p, off,     b0);
  let v1 = (v - b0) / 256;
  let b1 = v1 % 256;       ql_mem_store(p, off + 1, b1);
  let v2 = (v1 - b1) / 256;
  let b2 = v2 % 256;       ql_mem_store(p, off + 2, b2);
  let v3 = (v2 - b2) / 256;
  let b3 = v3 % 256;       ql_mem_store(p, off + 3, b3);
  let v4 = (v3 - b3) / 256;
  let b4 = v4 % 256;       ql_mem_store(p, off + 4, b4);
  let v5 = (v4 - b4) / 256;
  let b5 = v5 % 256;       ql_mem_store(p, off + 5, b5);
  let v6 = (v5 - b5) / 256;
  let b6 = v6 % 256;       ql_mem_store(p, off + 6, b6);
  let v7 = (v6 - b6) / 256;
  let b7 = v7 % 256;       ql_mem_store(p, off + 7, b7);
  null;
};

let readU64 = (p, off) -> {
  let acc = 0;
  let mult = 1;
  let i = 0;
  while i < 8 {
    acc = acc + ql_mem_get(p, off + i) * mult;
    mult = mult * 256;
    i = i + 1;
  };
  acc;
};

let allocBox = (tag, size) -> {
  let p = ql_alloc(size);
  writeU64(p, 0, tag);
  p;
};

// 数字 → 字符串对象 {buf, len}:整数快速路径(host Value::to_string 镜像)
// 非整数/|n|>=1e15 回退到整数截断 —— M2 补完整 f64 Display;v1 测试集全整数
let __itoa = (n) -> {
  let neg = n < 0;
  let x = if neg { -n } else { n };
  let k = 0;
  let t = x;
  while t >= 1 {
    k = k + 1;
    t = (t - t % 10) / 10;
  };
  if k == 0 { k = 1; };                       // "0"
  let start = if neg { 1 } else { 0 };
  let total = start + k;
  let buf = ql_alloc(total);
  if neg { ql_mem_store(buf, 0, 45); };       // '-'
  let v = x;
  let i = 0;
  while i < k {
    let d = v % 10;
    ql_mem_store(buf, start + k - 1 - i, 48 + d);
    v = (v - d) / 10;
    i = i + 1;
  };
  { buf: buf, len: total };
};

let __print = (s) -> { ql_write(1, s.buf, s.len); };

let print = (v) -> { __print(__itoa(v)); null; };

let println = (v) -> {
  __print(__itoa(v));
  let nl = ql_alloc(1);
  ql_mem_store(nl, 0, 10);
  __print({ buf: nl, len: 1 });
  null;
};
// --- host stdlib 缺口 fallback(plan known-risk #2):补 std.String.fromCodePoint ---
std.String.fromCodePoint = (cp) -> {
  let digits = "0123456789";
  if cp >= 48 && cp <= 57 { digits[cp - 48]; }
  else if cp == 45 { "-"; }
  else { "?"; };
};

println = __host_stdout;                        // 恢复 host 原生 println(mock 的 ql_write 依赖它)

// 与 native 手写 IR、host 解释器三方对照:都应是 "120"
let r = __itoa(120);
ql_write(1, r.buf, r.len);
