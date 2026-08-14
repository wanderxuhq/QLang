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
