// aot/runtime.ql — 编译进产物的运行时语义层(QLang)
// 仅依赖 leaf:ql_alloc / ql_mem_get / ql_mem_store / ql_write / ql_exit / ql_mem_get_ptr / ql_mem_store_ptr。
// 内存函数(对象头、字符串缓冲)全部封装于此,不暴露给编译器。
// QLang 无移位符 → u64 字节读写用「除 256 + 取模」分解/合成。

// 顶层标签/键盒:字符串字面量被 qlangc intern,"buf"/"len" 字段名与 __K_BUF/__K_LEN
// 内容相同 → 同一盒 = 「键 = 指针同一」的落点。
let __LABEL_ARR = "?Array";
let __LABEL_OBJ = "?Object";
let __LABEL_ERR = "?Error";
let __LABEL_FN = "?Function";
let __LABEL_NULL = "null";
let __K_BUF = "buf";
let __K_LEN = "len";

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

// NUMBER 盒 → 新 NUMBER 盒:readU64 读出 f64 原始 8 字节位模式,writeU64 写回 → 位保持
let __mknum = (x) -> {
  let b = allocBox(1, 16);
  writeU64(b, 8, readU64(x, 8));
  b;
};

// ERROR 盒:kind/msg 为字符串盒(M3 的 error read zone 再读)
let __err = (kind, msg) -> {
  let b = allocBox(8, 32);
  ql_mem_store_ptr(b, 8, kind);
  ql_mem_store_ptr(b, 16, msg);
  b;
};

// [M2 占位:__hash → __obj_new → __obj_get → __obj_set → __rehash → __norm_idx →
//  __get_length → __get_field → __set_field → __get_index → __set_index →
//  __arr_add → __arr_remove → __add 在此插入(Task 4/5)]

// 值 → interned 类型标签字符串盒
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

// 数字 → 字符串对象 {buf, len}:整数快速路径(host Value::to_string 镜像)
// 非整数/|n|>=1e15 回退到整数截断 —— M2 补完整 f64 Display;v1 测试集全整数
let __itoa = (n) -> {
  let neg = n < 0;
  let x = n;
  if neg { x = -n; };
  let k = 0;
  let t = x;
  while t >= 1 {
    k = k + 1;
    t = (t - t % 10) / 10;
  };
  if k == 0 { k = 1; };                       // "0"
  let start = 0;
  if neg { start = 1; };
  let total = start + k;
  let buf = ql_alloc(total);
  if neg { ql_mem_store(buf, 0, 45); };       // '-'
  let v = x;
  let d = 0;                                  // d 必须函数顶层声明(分支内 let 不受支持)
  let i = 0;
  while i < k {
    d = v % 10;
    ql_mem_store(buf, start + k - 1 - i, 48 + d);
    v = (v - d) / 10;
    i = i + 1;
  };
  { buf: buf, len: total };
};

// BOOL 盒 → "true"/"false" 字节缓冲
let __boolstr = (b) -> {
  let val = readU64(b, 8);
  let buf = ql_alloc(5);
  let len = 4;
  if val == 1 {
    ql_mem_store(buf, 0, 116);
    ql_mem_store(buf, 1, 114);
    ql_mem_store(buf, 2, 117);
    ql_mem_store(buf, 3, 101);
  } else {
    len = 5;
    ql_mem_store(buf, 0, 102);
    ql_mem_store(buf, 1, 97);
    ql_mem_store(buf, 2, 108);
    ql_mem_store(buf, 3, 115);
    ql_mem_store(buf, 4, 101);
  };
  { buf: buf, len: len };
};

// 空字符串对象 {buf, len}:NULL 盒的标签字符串
let __nullstr = () -> {
  { buf: ql_mem_get_ptr(__LABEL_NULL, 8), len: readU64(__LABEL_NULL, 16) };
};

// 值 → 字符串对象:按盒 tag 全分派(NUMBER→__itoa,STRING→盒内读,BOOL→__boolstr,NULL→"null",
// ARR/OBJ/ERR/FN→标签字符串)。
// 只用嵌套 if/else(boot parser 把 else-if 拍平成 branches[],emitIfStmt 只处理 branches[0])。
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

// 字符串输出:双路径 —— STRING 盒(tag 2)内联读 buf@8/len@16;{buf,len} 对象(tag 6)走成员访问。
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

let print = (v) -> { __print(__str(v)); null; };

let println = (v) -> {
  __print(__str(v));
  let nl = ql_alloc(1);
  ql_mem_store(nl, 0, 10);
  __print({ buf: nl, len: 1 });
  null;
};
