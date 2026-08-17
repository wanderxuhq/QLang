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
let __EMPTY = "";   // 哈希表空槽哨兵(interned "" 字符串盒)

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

// M3:tag-2 STRING 盒 {tag@0=2, buf@8, len@16}
let __str_new = (buf, len) -> {
  let box = allocBox(2, 24);
  ql_mem_store_ptr(box, 8, buf);
  writeU64(box, 16, len);
  box;
};

// M3:48B ERROR 盒 {tag@0=8, kind@8, message@16, line@24, col@32, cause@40}
// kind/message 为 tag-2 STRING 盒;line/col 为 interned 数字零盒;cause 为 ERROR 盒或 nullbox。
let __zero_num = 0;
let __err_new = (kind, msg, cause) -> {
  let b = allocBox(8, 48);
  ql_mem_store_ptr(b, 8, kind);
  ql_mem_store_ptr(b, 16, msg);
  ql_mem_store_ptr(b, 24, __zero_num);
  ql_mem_store_ptr(b, 32, __zero_num);
  ql_mem_store_ptr(b, 40, cause);
  b;
};
let __err = (kind, msg) -> { __err_new(kind, msg, null); };
let __isError = (v) -> { readU64(v, 0) == 8; };
let __err_cause = (e) -> { ql_mem_get_ptr(e, 40); };
let __err_get = (e, field) -> {
  let k = field;
  if k == "kind" { ql_mem_get_ptr(e, 8); }
  else { if k == "message" { ql_mem_get_ptr(e, 16); }
  else { if k == "line" { ql_mem_get_ptr(e, 24); }
  else { if k == "col" { ql_mem_get_ptr(e, 32); }
  else { if k == "cause" { ql_mem_get_ptr(e, 40); }
  else { __err("UndefinedField", "Undefined field: " + field); }; }; }; }; };
};

// OBJECT 盒 {tag@0=6, table@8, cap@16, count@24};桶表 ql_alloc(16*cap),[k0,v0,k1,v1,...],
// 槽 i 键 table+i*16、值 table+i*16+8;空槽哨兵 __EMPTY 盒(绝不存 raw 0)。

// 键字符串 → 散列:逐字节扫前 24B,f64 盒 payload 含长度+内容(ql_mem_get 单字节读)
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

// 线性探测;空槽终止探测。state:0 探测中 / 1 命中 / 2 未命中(空槽)。found 存值盒。
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
    if tag == 8 {
      // M3 T4:ERROR 盒读域(host error_read_zone 镜像):.type→kind@8、.message→message@16、
      // .line/.col→零盒@24/@32、.cause→cause@40;未知域 → UndefinedField。
      if key == "type" { ql_mem_get_ptr(o, 8); }
      else { if key == "message" { ql_mem_get_ptr(o, 16); }
      else { if key == "line" { ql_mem_get_ptr(o, 24); }
      else { if key == "col" { ql_mem_get_ptr(o, 32); }
      else { if key == "cause" { ql_mem_get_ptr(o, 40); }
      else { __err("UndefinedField", "Undefined field: " + key); }; }; }; }; };
    } else {
      if tag == 5 {
        __err("UndefinedField", "Undefined field");
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
    if tag == 6 {
      // M3 T5 Gap A:OBJECT 索引读 —— i 为键 STRING 盒(interned/表内键 → 指针同一命中)
      __obj_get(c, i);
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
};

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
    if tag == 6 {
      // M3 T5 Gap A:OBJECT 索引写 —— i 为键 STRING 盒(interned/表内键 → 指针同一命中)
      __obj_set(c, i, v);
      null;
    } else {
      if tag == 2 {
        __err("CannotIndex", "Cannot index a string");
      } else {
        __err("CannotIndex", "Cannot index");
      };
    };
  };
};

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

// ---- M3 T2:操作区派发(R1/R14)----
// 递归安全:__op_zone_error 的 "cannot apply " + word + ... STRING 拼接在编译期经
// emitBinaryOp 派发 __op_add,__op_add 内字节拷贝算术全 NUMBER → 内联,无递归;__op_eq
// 内 ta == 8 等为 NUMBER 比较 → 内联 fcmp;true/false 字面量 ✓。

// BOOL 盒 {tag@0=3, payload@8=i64 0/1}
let __mkbool = (b) -> {
  let box = allocBox(3, 16);
  let v = 0;
  if b { v = 1; };
  writeU64(box, 8, v);
  box;
};

// 操作区:任一操作数 Error → TypeMismatch(cause=出错操作数)。消息格式归一化下等价 host。
let __op_zone_error = (word, L, R) -> {
  let tL = readU64(L, 0);
  let tR = readU64(R, 0);
  if tL == 8 {
    __err_new("TypeMismatch", "cannot apply " + word + " to " + __type_of(L) + " and " + __type_of(R), L);
  } else {
    if tR == 8 {
      __err_new("TypeMismatch", "cannot apply " + word + " to " + __type_of(L) + " and " + __type_of(R), R);
    } else {
      __err("TypeMismatch", "cannot apply " + word + " to " + __type_of(L) + " and " + __type_of(R));
    };
  };
};

let __op_div0 = () -> {
  __err("DivisionByZero", "division by zero");
};

// 字符串内容相等:len 相等 + 逐字节相等(ASCII 域 len = 字符数)
let __str_eq = (a, b) -> {
  let la = readU64(a, 16);
  let lb = readU64(b, 16);
  let same = 0;
  let ba = null;    // 分支内临时量,顶层声明
  let bb = null;
  let i = 0;
  let eq = 0;
  if la == lb {
    ba = ql_mem_get_ptr(a, 8);
    bb = ql_mem_get_ptr(b, 8);
    i = 0;
    eq = 1;
    while i < la && eq == 1 {
      if ql_mem_get(ba, i) != ql_mem_get(bb, i) { eq = 0; };
      i = i + 1;
    };
    same = eq;
  };
  __mkbool(same == 1);
};

// tag 感知相等(host values_equal 镜像)。数值路径不达此(emit 内联);字符串内容、对象/数组/函数载荷同一。
let __op_eq = (a, b) -> {
  let ta = readU64(a, 0);
  let tb = readU64(b, 0);
  if ta == 8 {
    __op_zone_error("comparison", a, b);
  } else {
    if tb == 8 {
      __op_zone_error("comparison", a, b);
    } else {
      if ta == 4 && tb == 4 {
        true;
      } else {
        if ta == 2 && tb == 2 {
          __str_eq(a, b);
        } else {
          if ta == 3 && tb == 3 {
            __mkbool(readU64(a, 8) == readU64(b, 8));
          } else {
            if ta == 5 && tb == 5 {
              __mkbool(readU64(a, 8) == readU64(b, 8));
            } else {
              if ta == 6 && tb == 6 {
                __mkbool(readU64(a, 8) == readU64(b, 8));
              } else {
                if ta == 7 && tb == 7 {
                  __mkbool(readU64(a, 16) == readU64(b, 16));
                } else {
                  // Ruling T6-C:双 NUMBER 盒 → 内联 fcmp(emitBinaryOp 双 tag1 路径,不递归)
                  if ta == 1 && tb == 1 { a == b; } else { false; };
                };
              };
            };
          };
        };
      };
    };
  };
};

let __op_ne = (a, b) -> {
  let ta = readU64(a, 0);
  let tb = readU64(b, 0);
  if ta == 8 {
    __op_zone_error("comparison", a, b);
  } else {
    if tb == 8 {
      __op_zone_error("comparison", a, b);
    } else {
      !__op_eq(a, b);
    };
  };
};

// 字符串拼接(STR+STR → tag-2;错误传播;其余 TypeMismatch)。数值路径不达此。
let __op_add = (a, b) -> {
  let ta = readU64(a, 0);
  let tb = readU64(b, 0);
  let ab = null;    // 分支/循环内临时量,全部顶层声明
  let al = 0;
  let bb = null;
  let bl = 0;
  let nb = null;
  let i = 0;
  let j = 0;
  if ta == 8 {
    __op_zone_error("addition", a, b);
  } else {
    if tb == 8 {
      __op_zone_error("addition", a, b);
    } else {
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
        __str_new(nb, al + bl);
      } else {
        __op_zone_error("addition", a, b);
      };
    };
  };
};

// M2 遗留测试(t8_comp.ql 直接调用 __add)兼容别名。
let __add = (a, b) -> {
  __op_add(a, b);
};

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
// 非整数:精确十进制展开(预算 ≤12 位小数,终止才渲染,否则回退整数截断)
// M3 T5(差异项 5):10/4 → "2.5"、1/8 → "0.125"(可精确表示二进制分数与 host f64 Display 一致)
let __itoa = (n) -> {
  let neg = n < 0;
  let x = n;
  if neg { x = -n; };
  let ip = x - (x % 1);          // 整数部分(Ruling T5-F:显式括号)
  let fr = x % 1;                // 小数部分
  let k = 0;                     // 整数部分位数
  let t = 0;                     // 通用临时量(k 计数 / 分数展开)
  let start = 0;
  let total = 0;
  let buf = null;
  let v = 0;
  let d = 0;                     // 顶层声明(分支/循环内只赋值)
  let i = 0;
  let j = 0;
  let digits = [];
  let f = 0;
  let budget = 12;
  let done = 0;
  let nd = 0;
  let dd = null;
  if fr == 0 {
    // 整数快速路径(M2 逐位逻辑,逐字节不变)
    k = 0;
    t = ip;
    while t >= 1 {
      k = k + 1;
      t = (t - t % 10) / 10;
    };
    if k == 0 { k = 1; };                     // "0"
    start = 0;
    if neg { start = 1; };
    total = start + k;
    buf = ql_alloc(total);
    if neg { ql_mem_store(buf, 0, 45); };     // '-'
    v = ip;
    i = 0;
    while i < k {
      d = v % 10;
      ql_mem_store(buf, start + k - 1 - i, 48 + d);
      v = (v - d) / 10;
      i = i + 1;
    };
    __str_new(buf, total);
  } else {
    // 精确十进制展开:预算 12 位小数,终止才渲染,否则回退整数截断
    f = fr;
    budget = 12;
    done = 0;
    while done == 0 {
      if f == 0 { done = 1; }
      else {
        if budget <= 0 { done = 2; }
        else {
          t = f * 10;
          d = t - (t % 1);
          digits.add(d);
          f = t - d;
          budget = budget - 1;
        };
      };
    };
    if done == 2 {
      // 回退:整数截断
      k = 0;
      t = ip;
      while t >= 1 {
        k = k + 1;
        t = (t - t % 10) / 10;
      };
      if k == 0 { k = 1; };
      start = 0;
      if neg { start = 1; };
      total = start + k;
      buf = ql_alloc(total);
      if neg { ql_mem_store(buf, 0, 45); };
      v = ip;
      i = 0;
      while i < k {
        d = v % 10;
        ql_mem_store(buf, start + k - 1 - i, 48 + d);
        v = (v - d) / 10;
        i = i + 1;
      };
      __str_new(buf, total);
    } else {
      // 整数部分 + '.' + 逐位小数
      k = 0;
      t = ip;
      while t >= 1 {
        k = k + 1;
        t = (t - t % 10) / 10;
      };
      if k == 0 { k = 1; };
      nd = readU64(digits, 16);
      start = 0;
      if neg { start = 1; };
      total = start + k + 1 + nd;
      buf = ql_alloc(total);
      if neg { ql_mem_store(buf, 0, 45); };
      v = ip;
      i = 0;
      while i < k {
        d = v % 10;
        ql_mem_store(buf, start + k - 1 - i, 48 + d);
        v = (v - d) / 10;
        i = i + 1;
      };
      ql_mem_store(buf, start + k, 46);       // '.'
      j = 0;
      while j < nd {
        dd = ql_mem_get_ptr(ql_mem_get_ptr(digits, 8), j * 8);
        ql_mem_store(buf, start + k + 1 + j, 48 + dd);
        j = j + 1;
      };
      __str_new(buf, total);
    };
  };
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
  __str_new(buf, len);
};

// "null" 标签的 tag-2 STRING 盒:复用 interned "null" 字符串盒的 buf/len
let __nullstr = () -> {
  __str_new(ql_mem_get_ptr(__LABEL_NULL, 8), readU64(__LABEL_NULL, 16));
};

// 值 → tag-2 STRING 盒:按盒 tag 全分派(NUMBER→__itoa,STRING→恒同盒,
// BOOL→__boolstr,NULL→"null",ARR/OBJ/ERR/FN→interned 标签字符串盒)。
// 只用嵌套 if/else(boot parser 把 else-if 拍平成 branches[],emitIfStmt 只处理 branches[0])。
let __str = (v) -> {
  let tag = readU64(v, 0);
  if tag == 1 {
    __itoa(v);
  } else {
    if tag == 2 {
      v;
    } else {
      if tag == 3 {
        __boolstr(v);
      } else {
        if tag == 4 {
          __nullstr();
        } else {
          if tag == 5 {
            __str_new(ql_mem_get_ptr(__LABEL_ARR, 8), readU64(__LABEL_ARR, 16));
          } else {
            if tag == 6 {
              __str_new(ql_mem_get_ptr(__LABEL_OBJ, 8), readU64(__LABEL_OBJ, 16));
            } else {
              if tag == 8 {
                __str_new(ql_mem_get_ptr(__LABEL_ERR, 8), readU64(__LABEL_ERR, 16));
              } else {
                __str_new(ql_mem_get_ptr(__LABEL_FN, 8), readU64(__LABEL_FN, 16));
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
  __print(__str_new(nl, 1));
  null;
};

// ---- M3 T3:错误链格式化 + 顶层未捕获错误退出 ----

// 错误链文本:`{kind}: {message}` + 每级 cause `\n  └─ caused by: {kind}: {message}`
// (递归;`"\n  └─ caused by: "` 含非 ASCII → qlangc byte-aware internString 已就绪)
let __err_chain = (e) -> {
  let base = __err_get(e, "kind") + ": " + __err_get(e, "message");
  let c = __err_cause(e);
  let r = base;
  if __isError(c) {
    r = base + "\n  └─ caused by: " + __err_chain(c);
  };
  r;
};

// 写 fd(1/2)+ 字符串(直接 STRING 盒)
let __wfd = (fd, s) -> {
  ql_write(fd, ql_mem_get_ptr(s, 8), readU64(s, 16));
  null;
};

// 顶层未捕获错误:stderr 打印错误链 + exit 1
let __exit_error = (e) -> {
  __wfd(2, __err_chain(e));
  let nl = ql_alloc(1);
  ql_mem_store(nl, 0, 10);
  ql_write(2, nl, 1);
  ql_exit(1);
  null;
};

// ---- M3 T4:类型系统 + std.Type + Array/Object 构造器 + std.Error(R4/R18)----
// 类型值识别:tag6 对象且带 tag7 函数 check 字段(host types.rs:16-27 is_type_value 镜像)。
// 全部函数定义为「顶层 let」(仅建闭包盒,无 init 副作用);单例与 std 对象字面量置于本文件
// 最末尾(init 期执行的对象字面量),遵守 init-time forward-reference 纪律。
let __is_type_value = (v) -> {
  let tag = readU64(v, 0);
  let c = null;
  if tag == 6 {
    c = __obj_get(v, "check");
    if readU64(c, 0) == 8 {
      false;
    } else {
      readU64(c, 0) == 7;
    };
  } else {
    false;
  };
};

// 类型单例谓词(host builtin_type 镜像)。Function = tag7 或带 check 的对象(419 断言依赖)。
let __pred_number = (v) -> { readU64(v, 0) == 1; };
let __pred_string = (v) -> { readU64(v, 0) == 2; };
let __pred_boolean = (v) -> { readU64(v, 0) == 3; };
let __pred_null = (v) -> { readU64(v, 0) == 4; };
let __pred_array = (v) -> { readU64(v, 0) == 5; };
let __pred_object = (v) -> { readU64(v, 0) == 6 && !__is_type_value(v); };
let __pred_function = (v) -> { readU64(v, 0) == 7 || __is_type_value(v); };
let __pred_any = (v) -> { true; };
let __pred_never = (v) -> { false; };
let __pred_error = (v) -> { readU64(v, 0) == 8; };
let __pred_type = (v) -> { __is_type_value(v); };

// 类型对象构造 {check: cf}(普通 tag6 对象,非受保护;host user_type 镜像)
let __mk_otype = (cf) -> {
  let o = __obj_new();
  __obj_set(o, "check", cf);
  o;
};

// Type.make(f)(host types.rs:148-159 镜像):f 非 tag7 函数 → TypeMismatch
let __type_make = (f) -> {
  if readU64(f, 0) == 7 {
    __mk_otype(f);
  } else {
    __err("TypeMismatch", "Type.make: expected a function");
  };
};

// Type.of(v)(host types.rs:129-147 镜像):tag→类型单例;Object 带 check → Type;否则 AnyObject。
let __type_of_val = (v) -> {
  let tag = readU64(v, 0);
  if tag == 1 {
    Number;
  } else {
    if tag == 2 {
      String;
    } else {
      if tag == 3 {
        Boolean;
      } else {
        if tag == 4 {
          Null;
        } else {
          if tag == 5 {
            AnyArray;
          } else {
            if tag == 7 {
              Function;
            } else {
              if tag == 8 {
                Error;
              } else {
                if __is_type_value(v) {
                  Type;
                } else {
                  AnyObject;
                };
              };
            };
          };
        };
      };
    };
  };
};

// 数组类型:所有元素通过谓词(host all_check 镜像:任一元素失败/错误 → false)
let __arr_elem_check = (cf, a) -> {
  let tag = readU64(a, 0);
  let ok = 0;
  let els = null;
  let len = 0;
  let i = 0;
  let r = null;
  if tag == 5 {
    els = ql_mem_get_ptr(a, 8);
    len = readU64(a, 16);
    ok = 1;
    i = 0;
    while ok == 1 && i < len {
      r = cf(ql_mem_get_ptr(els, i * 8));
      if readU64(r, 0) == 8 {
        ok = 0;
      } else {
        if readU64(r, 8) == 0 {
          ok = 0;
        } else {
          i = i + 1;
        };
      };
    };
  };
  __mkbool(ok == 1);
};

// 数组类型:逐位置检查(host ArrayMode::Tuple 镜像):长度相等 + 每位通过
let __tuple_check = (checks, a) -> {
  let tag = readU64(a, 0);
  let ok = 0;
  let els = null;
  let len = 0;
  let clen = 0;
  let i = 0;
  let r = null;
  let ce = null;
  if tag == 5 {
    els = ql_mem_get_ptr(a, 8);
    len = readU64(a, 16);
    clen = readU64(checks, 16);
    if len == clen {
      ok = 1;
      i = 0;
      while ok == 1 && i < len {
        ce = ql_mem_get_ptr(ql_mem_get_ptr(checks, 8), i * 8);
        r = ce(ql_mem_get_ptr(els, i * 8));
        if readU64(r, 0) == 8 {
          ok = 0;
        } else {
          if readU64(r, 8) == 0 {
            ok = 0;
          } else {
            i = i + 1;
          };
        };
      };
    };
  };
  __mkbool(ok == 1);
};

// 对象键收集(遍历桶表;键为 tag-2 STRING 盒)→ tag-5 数组盒
let __obj_keys = (o) -> {
  let table = ql_mem_get_ptr(o, 8);
  let cap = readU64(o, 16);
  let res = null;
  let els = null;
  let j = 0;
  let k = null;
  let n = 0;
  res = allocBox(5, 24);
  els = ql_alloc(8 * cap);
  ql_mem_store_ptr(res, 8, els);
  writeU64(res, 16, 0);
  j = 0;
  while j < cap {
    k = ql_mem_get_ptr(table, j * 16);
    if k != __EMPTY {
      ql_mem_store_ptr(els, n * 8, k);
      n = n + 1;
    };
    j = j + 1;
  };
  writeU64(res, 16, n);
  res;
};

// 对象值收集(遍历桶表;值为 tag-2 盒等)→ tag-5 数组盒
// Ruling T5-A:T4 只定义了 __obj_keys,这里补 __obj_values 镜像(收集值盒 table[j*16+8])
let __obj_values = (o) -> {
  let table = ql_mem_get_ptr(o, 8);
  let cap = readU64(o, 16);
  let res = null;
  let els = null;
  let j = 0;
  let k = null;
  let v = null;
  let n = 0;
  res = allocBox(5, 24);
  els = ql_alloc(8 * cap);
  ql_mem_store_ptr(res, 8, els);
  writeU64(res, 16, 0);
  j = 0;
  while j < cap {
    k = ql_mem_get_ptr(table, j * 16);
    if k != __EMPTY {
      v = ql_mem_get_ptr(table, j * 16 + 8);
      ql_mem_store_ptr(els, n * 8, v);
      n = n + 1;
    };
    j = j + 1;
  };
  writeU64(res, 16, n);
  res;
};

// std.Object.merge(o1)(o2) 柯里化:o1 键序 + o2 键序复制进新对象(键为表内键 → 指针同一)
let __obj_merge = (o1) -> (o2) -> {
  let out = __obj_new();
  let k1 = __obj_keys(o1);
  let i = 0;
  let k = null;     // 循环内临时量,顶层声明
  while i < readU64(k1, 16) {
    k = __get_index(k1, i);
    __obj_set(out, k, __obj_get(o1, k));
    i = i + 1;
  };
  let k2 = __obj_keys(o2);
  let j = 0;
  while j < readU64(k2, 16) {
    k = __get_index(k2, j);
    __obj_set(out, k, __obj_get(o2, k));
    j = j + 1;
  };
  out;
};

// std.Object.hasOwn(o)(k) 柯里化:键缺失 → __obj_get 返回 tag-8 ERROR 盒 → false
let __obj_hasown = (o) -> (k) -> {
  let v = __obj_get(o, k);
  readU64(v, 0) != 8;
};

// std.Object.get(o)(k) 柯里化:键缺失 → null(host fields.get → Void 镜像)
let __obj_get2 = (o) -> (k) -> {
  let v = __obj_get(o, k);
  if readU64(v, 0) == 8 { null; } else { v; };
};

// Object(Type):所有键通过 key_check(host object_check_keys 镜像)
let __obj_check_keys = (kc, o) -> {
  let tag = readU64(o, 0);
  let ok = 0;
  let keys = null;
  let kn = 0;
  let i = 0;
  let k = null;
  let r = null;
  if tag == 6 && !__is_type_value(o) {
    keys = __obj_keys(o);
    kn = readU64(keys, 16);
    ok = 1;
    i = 0;
    while ok == 1 && i < kn {
      k = ql_mem_get_ptr(ql_mem_get_ptr(keys, 8), i * 8);
      r = kc(k);
      if readU64(r, 0) == 8 {
        ok = 0;
      } else {
        if readU64(r, 8) == 0 {
          ok = 0;
        } else {
          i = i + 1;
        };
      };
    };
  };
  __mkbool(ok == 1);
};

// Object(schema):每个 schema 键存在且通过对应检查(host object_check_schema 镜像)
let __obj_check_schema = (ks, cs, o) -> {
  let tag = readU64(o, 0);
  let ok = 0;
  let kn = 0;
  let i = 0;
  let fv = null;
  let ce = null;
  let r = null;
  if tag == 6 && !__is_type_value(o) {
    ok = 1;
    kn = readU64(ks, 16);
    i = 0;
    while ok == 1 && i < kn {
      fv = __obj_get(o, ql_mem_get_ptr(ql_mem_get_ptr(ks, 8), i * 8));
      if readU64(fv, 0) == 8 {
        ok = 0;
      } else {
        ce = ql_mem_get_ptr(ql_mem_get_ptr(cs, 8), i * 8);
        r = ce(fv);
        if readU64(r, 0) == 8 {
          ok = 0;
        } else {
          if readU64(r, 8) == 0 {
            ok = 0;
          } else {
            i = i + 1;
          };
        };
      };
    };
  };
  __mkbool(ok == 1);
};

// Object(pred):谓词函数判对象(host object_check_predicate 镜像)
let __obj_check_pred = (pred, o) -> {
  let tag = readU64(o, 0);
  let ok = 0;
  let r = null;
  if tag == 6 && !__is_type_value(o) {
    r = pred(o);
    if readU64(r, 0) == 8 {
      ok = 0;
    } else {
      if readU64(r, 8) == 0 {
        ok = 0;
      } else {
        ok = 1;
      };
    };
  };
  __mkbool(ok == 1);
};

// 编译 schema 成员为类型值(host compile_schema_type 镜像):类型值 → 自身;
// {length,element} 对象 → Array 类型;普通描述符对象 → Object 类型;否则 TypeMismatch(fallback)。
let __compile_schema = (v, fallback) -> {
  let tag = readU64(v, 0);
  let L = null;
  let E = null;
  if __is_type_value(v) {
    v;
  } else {
    if tag == 6 {
      L = __get_field(v, "length");
      E = __get_field(v, "element");
      if readU64(L, 0) == 8 || readU64(E, 0) == 8 {
        __obj_ctor(v);
      } else {
        __arr_ctor(v);
      };
    } else {
      __err("TypeMismatch", fallback);
    };
  };
};

// Array 构造器(host build_array_type 镜像,4 联合):Number 定长 / Type 元素 / [Type] 逐位 /
// {length, element} 元数据(长度拷贝 element.check 的 tuple)。
let __arr_ctor = (x) -> {
  let tag = readU64(x, 0);
  let cf = null;
  let checks = null;
  let els = null;
  let clen = 0;
  let i = 0;
  let ce = null;
  let bad = 0;
  let nb = null;
  let lv = null;
  if tag == 1 {
    if x % 1 != 0 || x < 0 {
      __err("TypeMismatch", "Array: length must be a non-negative integer");
    } else {
      __mk_otype((a) -> { readU64(a, 0) == 5 && readU64(a, 16) == x; });
    };
  } else {
    if __is_type_value(x) {
      cf = __get_field(x, "check");
      __mk_otype((a) -> { __arr_elem_check(cf, a); });
    } else {
      if tag == 5 {
        els = ql_mem_get_ptr(x, 8);
        clen = readU64(x, 16);
        bad = 0;
        i = 0;
        while i < clen {
          ce = ql_mem_get_ptr(els, i * 8);
          if __is_type_value(ce) {
            i = i + 1;
          } else {
            bad = 1;
            i = clen;
          };
        };
        if bad == 1 {
          __err("TypeMismatch", "Array: tuple elements must all be type values");
        } else {
          // 校验函数指针数组须为 tag-5 Array 盒(@8=els,@16=len),供 __tuple_check 读取。
          checks = allocBox(5, 24);
          nb = ql_alloc(8 * clen);
          ql_mem_store_ptr(checks, 8, nb);
          writeU64(checks, 16, clen);
          i = 0;
          while i < clen {
            ce = ql_mem_get_ptr(els, i * 8);
            ql_mem_store_ptr(nb, i * 8, __get_field(ce, "check"));
            i = i + 1;
          };
          __mk_otype((a) -> { __tuple_check(checks, a); });
        };
      } else {
        if tag == 6 {
          lv = __get_field(x, "length");
          cf = __get_field(x, "element");
          if readU64(lv, 0) == 8 || readU64(cf, 0) == 8 {
            __err("TypeMismatch", "Array: metadata must have a type 'element'");
          } else {
            if readU64(lv, 0) != 1 || lv % 1 != 0 || lv < 0 {
              __err("TypeMismatch", "Array: metadata must have a non-negative integer 'length'");
            } else {
              ce = __compile_schema(cf, "metadata must have a type 'element'");
              if readU64(ce, 0) == 8 {
                ce;
              } else {
                cf = __get_field(ce, "check");
                // 同上:校验指针须为 tag-5 Array 盒(@8=els,@16=len)。
                checks = allocBox(5, 24);
                els = ql_alloc(8 * lv);
                ql_mem_store_ptr(checks, 8, els);
                writeU64(checks, 16, lv);
                i = 0;
                while i < lv {
                  ql_mem_store_ptr(els, i * 8, cf);
                  i = i + 1;
                };
                __mk_otype((a) -> { __tuple_check(checks, a); });
              };
            };
          };
        } else {
          __err("TypeMismatch", "Array: argument must be a length, a type, a list of types, or {length, element}");
        };
      };
    };
  };
};

// Object 构造器(host build_object_type 镜像,3 联合):Type 键类型 / shape 描述符 / 谓词函数。
let __obj_ctor = (x) -> {
  let tag = readU64(x, 0);
  let cf = null;
  let ks = null;
  let cs = null;
  let kn = 0;
  let i = 0;
  let k = null;
  let fv = null;
  let ce = null;
  let bad = 0;
  let nb = null;
  if __is_type_value(x) {
    cf = __get_field(x, "check");
    __mk_otype((o) -> { __obj_check_keys(cf, o); });
  } else {
    if tag == 6 {
      ks = __obj_keys(x);
      kn = readU64(ks, 16);
      // 校验函数指针须为 tag-5 Array 盒(@8=els,@16=len),供 __obj_check_schema 读取。
      cs = allocBox(5, 24);
      nb = ql_alloc(8 * kn);
      ql_mem_store_ptr(cs, 8, nb);
      writeU64(cs, 16, kn);
      bad = 0;
      i = 0;
      while i < kn {
        k = ql_mem_get_ptr(ql_mem_get_ptr(ks, 8), i * 8);
        fv = __obj_get(x, k);
        if readU64(fv, 0) == 8 {
          bad = 1;
          ce = fv;
          i = kn;
        } else {
          ce = __compile_schema(fv, "schema field is not a type value");
          if readU64(ce, 0) == 8 {
            bad = 1;
            i = kn;
          } else {
            ql_mem_store_ptr(nb, i * 8, __get_field(ce, "check"));
            i = i + 1;
          };
        };
      };
      if bad == 1 {
        ce;
      } else {
        __mk_otype((o) -> { __obj_check_schema(ks, cs, o); });
      };
    } else {
      if tag == 7 {
        __mk_otype((o) -> { __obj_check_pred(x, o); });
      } else {
        __err("TypeMismatch", "Object: argument must be a type (keys), a shape object (schema), or a predicate function");
      };
    };
  };
};

// std.Error.raise(kind, message, cause)(host create_error_module 镜像):kind 非字符串 → "Error";
// message 非字符串 → 值 to_string;cause 非 Error → 忽略(null)。
let __error_raise = (kind, message, cause) -> {
  let k = null;
  let m = null;
  let c = null;
  if readU64(kind, 0) == 2 {
    k = kind;
  } else {
    k = "Error";
  };
  if readU64(message, 0) == 2 {
    m = message;
  } else {
    m = __str(message);
  };
  if readU64(cause, 0) == 8 {
    c = cause;
  } else {
    c = null;
  };
  __err_new(k, m, c);
};

// std.Error.toString(err)(host create_error_module toString 镜像;__err_chain 已在 T3 定义)
let __error_tostring = (err) -> {
  if readU64(err, 0) == 8 {
    __err_chain(err);
  } else {
    "not an error";
  };
};

// std.Number.isNaN(n):NUMBER 盒 → n != n(NaN 探测,inline fcmp une);非数值 → false
let __num_isnan = (n) -> {
  if readU64(n, 0) == 1 { n != n; } else { false; };
};

// std.Number.isFinite(n):NUMBER 盒 → NaN 或 inf-inf → 非有限(host n.is_finite 镜像)
let __num_isfinite = (n) -> {
  if readU64(n, 0) == 1 { !(n != n || (n - n) != (n - n)); } else { false; };
};

// std.Number.parseFloat(s):trim 空白 + 可选 '-' + 数字 + 可选 '.' 小数;失败 → __mknum_from_zero
// (失败路径白名单外,已知发散不阻塞;成功路径数值正确)
let __parse_float = (s) -> {
  let buf = ql_mem_get_ptr(s, 8);
  let len = readU64(s, 16);
  let i = 0;
  let neg = 0;
  let acc = 0;
  let any = 0;
  let fr = 0;
  let scale = 1;
  let v = 0;
  while i < len && ql_mem_get(buf, i) == 32 { i = i + 1; };
  if i < len && ql_mem_get(buf, i) == 45 { neg = 1; i = i + 1; };
  while i < len && ql_mem_get(buf, i) >= 48 && ql_mem_get(buf, i) <= 57 {
    acc = acc * 10 + (ql_mem_get(buf, i) - 48);
    any = 1;
    i = i + 1;
  };
  if i < len && ql_mem_get(buf, i) == 46 {
    i = i + 1;
    while i < len && ql_mem_get(buf, i) >= 48 && ql_mem_get(buf, i) <= 57 {
      fr = fr * 10 + (ql_mem_get(buf, i) - 48);
      scale = scale * 10;
      any = 1;
      i = i + 1;
    };
  };
  if any == 0 {
    __mknum_from_zero();          // NaN 不可廉价产 → 用 0 占位(已知发散,白名单外)
  } else {
    v = acc + fr / scale;
    if neg == 1 { -v; } else { v; };
  };
};

// 前向引用安全(M2 pre-scan):__parse_float 的失败占位
let __mknum_from_zero = () -> { 0; };

// ---- 类型单例 + std(init 期执行的对象字面量;置于文件最末尾,遵守 init-time forward-ref 纪律)----
let Number = { check: __pred_number };
let String = { check: __pred_string };
let Boolean = { check: __pred_boolean };
let Null = { check: __pred_null };
let AnyArray = { check: __pred_array };
let AnyObject = { check: __pred_object };
let Function = { check: __pred_function };
let Any = { check: __pred_any };
let Never = { check: __pred_never };
let Error = { check: __pred_error };
let Type = { check: __pred_type, of: __type_of_val, make: __type_make };
let stdError = { raise: __error_raise, toString: __error_tostring };
// M3 T5:std.Object / std.Number(host create_object_module/create_number_module 镜像)
// Ruling T5-B:field 必须非柯里化 2 参(host arity-2);merge/hasOwn/get 保持柯里化
let stdObject = {
  keys: __obj_keys,
  values: __obj_values,
  merge: __obj_merge,
  hasOwn: __obj_hasown,
  get: __obj_get2,
  field: (o, k) -> { __obj_get(o, k); },
};
let stdNumber = {
  toString: __itoa,
  isNaN: __num_isnan,
  isFinite: __num_isfinite,
  parseFloat: __parse_float,
};
// ---- M3 T6:std.Array / std.String 辅助(host stdlib/mod.rs create_array_module/
// create_string_module 镜像)。Ruling T6-H:内部辅助 __arr_indexof/__arr_join 非柯里化
// (链式柯里化调用 f(a)(b) 在 native emitNull 丢弃);柯里化成员为薄包装(体内一次 Call,无链)。
// Ruling T6-B:分支/循环内无 let,临时量全部顶层声明。
let __arr_push = (a) -> (v) -> {
  __arr_add(a, v);
  readU64(a, 16);
};
let __arr_pop = (a) -> () -> {
  let n = readU64(a, 16);
  let v = null;        // 分支内临时量,顶层声明
  if n == 0 {
    null;
  } else {
    v = __get_index(a, n - 1);
    __arr_remove(a, n - 1);
    v;
  };
};
let __arr_indexof = (a, v) -> {
  let n = readU64(a, 16);
  let i = 0;
  let found = -1;
  while i < n && found < 0 {
    if __op_eq(__get_index(a, i), v) { found = i; };
    i = i + 1;
  };
  found;
};
let __arr_join = (a, sep) -> {
  let n = readU64(a, 16);
  let out = "";
  let i = 0;
  while i < n {
    if i > 0 { out = out + __str(sep); };
    out = out + __str(__get_index(a, i));
    i = i + 1;
  };
  out;
};
// Ruling T6-A:toString = `[` + 逐元素 __str + `", "` 分隔 + `]`(host JS 风格)
let __arr_tostring = (a) -> {
  let n = readU64(a, 16);
  let out = "[";
  let i = 0;
  while i < n {
    if i > 0 { out = out + ", "; };
    out = out + __str(__get_index(a, i));
    i = i + 1;
  };
  out + "]";
};
// Ruling T6-J:reverse 返回新数组(host reversed.clone()+reverse),原数组不变
let __arr_reverse = (a) -> {
  let n = readU64(a, 16);
  let out = [];
  let i = 0;
  while i < n {
    out.add(__get_index(a, n - 1 - i));
    i = i + 1;
  };
  out;
};
let __arr_concat = (a) -> (b) -> {
  let out = [];
  let i = 0;
  while i < readU64(a, 16) {
    out.add(__get_index(a, i));
    i = i + 1;
  };
  let j = 0;
  while j < readU64(b, 16) {
    out.add(__get_index(b, j));
    j = j + 1;
  };
  out;
};
// ---- std.String 辅助(全 ASCII 字节操作;Ruling T6-E)----
let __s_len = (s) -> { readU64(s, 16); };
let __s_concat = (a, b) -> { __op_add(a, b); };
let __s_trim = (s) -> {
  let buf = ql_mem_get_ptr(s, 8);
  let len = readU64(s, 16);
  let i = 0;
  while i < len && ql_mem_get(buf, i) == 32 { i = i + 1; };
  let j = len;
  while j > i && ql_mem_get(buf, j - 1) == 32 { j = j - 1; };
  let nb = ql_alloc(j - i);
  let k = 0;
  while k < j - i {
    ql_mem_store(nb, k, ql_mem_get(buf, i + k));
    k = k + 1;
  };
  __str_new(nb, j - i);
};
let __s_case = (s, up) -> {
  let buf = ql_mem_get_ptr(s, 8);
  let len = readU64(s, 16);
  let nb = ql_alloc(len);
  let i = 0;
  let c = 0;           // 循环内临时量,顶层声明
  while i < len {
    c = ql_mem_get(buf, i);
    if up {
      if c >= 97 && c <= 122 { ql_mem_store(nb, i, c - 32); }
      else { ql_mem_store(nb, i, c); };
    } else {
      if c >= 65 && c <= 90 { ql_mem_store(nb, i, c + 32); }
      else { ql_mem_store(nb, i, c); };
    };
    i = i + 1;
  };
  __str_new(nb, len);
};
let __s_includes = (hay) -> (needle) -> {
  let hb = ql_mem_get_ptr(hay, 8);
  let hlen = readU64(hay, 16);
  let nb = ql_mem_get_ptr(needle, 8);
  let nlen = readU64(needle, 16);
  let found = 0;
  let i = 0;
  let j = 0;           // 循环内临时量,顶层声明
  let eq = 1;
  while i <= hlen - nlen && found == 0 {
    j = 0;
    eq = 1;
    while j < nlen && eq == 1 {
      if ql_mem_get(hb, i + j) != ql_mem_get(nb, j) { eq = 0; };
      j = j + 1;
    };
    if eq == 1 { found = 1; };
    i = i + 1;
  };
  found == 1;
};
let __s_replace = (s) -> (from) -> (to) -> {
  let sb = ql_mem_get_ptr(s, 8);
  let sl = readU64(s, 16);
  let fb = ql_mem_get_ptr(from, 8);
  let fl = readU64(from, 16);
  let tb = ql_mem_get_ptr(to, 8);
  let tl = readU64(to, 16);
  let pos = -1;
  let i = 0;
  let j = 0;           // 循环内临时量,顶层声明
  let eq = 1;
  let out = null;
  let k = 0;
  let m = 0;
  let r = 0;
  while i <= sl - fl && pos < 0 {
    j = 0;
    eq = 1;
    while j < fl && eq == 1 {
      if ql_mem_get(sb, i + j) != ql_mem_get(fb, j) { eq = 0; };
      j = j + 1;
    };
    if eq == 1 { pos = i; };
    i = i + 1;
  };
  // 未找到 → 返回原串(host str::replace 无匹配镜像);避免负偏移越界写
  if pos < 0 {
    s;
  } else {
    out = ql_alloc(sl - fl + tl);
    while k < pos { ql_mem_store(out, k, ql_mem_get(sb, k)); k = k + 1; };
    while m < tl { ql_mem_store(out, pos + m, ql_mem_get(tb, m)); m = m + 1; };
    while r < sl - fl - pos { ql_mem_store(out, pos + tl + r, ql_mem_get(sb, pos + fl + r)); r = r + 1; };
    __str_new(out, sl - fl + tl);
  };
};
let __s_repeat = (s) -> (n) -> {
  let sb = ql_mem_get_ptr(s, 8);
  let sl = readU64(s, 16);
  let nb = ql_alloc(sl * n);
  let i = 0;
  let j = 0;           // 循环内临时量,顶层声明
  while i < n {
    j = 0;
    while j < sl { ql_mem_store(nb, i * sl + j, ql_mem_get(sb, j)); j = j + 1; };
    i = i + 1;
  };
  __str_new(nb, sl * n);
};
let __s_sw = (s) -> (prefix) -> {
  let sb = ql_mem_get_ptr(s, 8);
  let pb = ql_mem_get_ptr(prefix, 8);
  let pl = readU64(prefix, 16);
  let i = 0;           // 分支内临时量,顶层声明
  let eq = 1;
  if readU64(s, 16) < pl {
    false;
  } else {
    i = 0;
    eq = 1;
    while i < pl && eq == 1 {
      if ql_mem_get(sb, i) != ql_mem_get(pb, i) { eq = 0; };
      i = i + 1;
    };
    eq == 1;
  };
};
let __s_ew = (s) -> (suffix) -> {
  let sb = ql_mem_get_ptr(s, 8);
  let sl = readU64(s, 16);
  let fb = ql_mem_get_ptr(suffix, 8);
  let fl = readU64(suffix, 16);
  let i = 0;           // 分支内临时量,顶层声明
  let eq = 1;
  if sl < fl {
    false;
  } else {
    i = 0;
    eq = 1;
    while i < fl && eq == 1 {
      if ql_mem_get(sb, sl - fl + i) != ql_mem_get(fb, i) { eq = 0; };
      i = i + 1;
    };
    eq == 1;
  };
};
let __s_split = (s) -> (sep) -> {
  let sb = ql_mem_get_ptr(s, 8);
  let sl = readU64(s, 16);
  let pb = ql_mem_get_ptr(sep, 8);
  let pl = readU64(sep, 16);
  let parts = [];
  let cur = [];
  let i = 0;
  let j = 0;           // 循环内临时量,顶层声明
  let eq = 1;
  let b = null;
  let k = 0;
  while i < sl {
    j = 0;
    eq = 1;
    while j < pl && i + j < sl && eq == 1 {
      if ql_mem_get(sb, i + j) != ql_mem_get(pb, j) { eq = 0; };
      j = j + 1;
    };
    if eq == 1 && j == pl {
      b = ql_alloc(cur.length);
      k = 0;
      while k < cur.length { ql_mem_store(b, k, cur[k]); k = k + 1; };
      parts.add(__str_new(b, cur.length));
      cur = [];
      i = i + pl;
    } else {
      cur.add(ql_mem_get(sb, i));
      i = i + 1;
    };
  };
  b = ql_alloc(cur.length);
  k = 0;
  while k < cur.length { ql_mem_store(b, k, cur[k]); k = k + 1; };
  parts.add(__str_new(b, cur.length));
  parts;
};
let stdArray = {
  length: (a) -> { readU64(a, 16); },
  toString: (a) -> { __arr_tostring(a); },
  add: (a) -> (v) -> { __arr_add(a, v); },
  remove: (a) -> (i) -> { __arr_remove(a, i); },
  push: __arr_push,
  pop: __arr_pop,
  get: (a) -> (i) -> { __get_index(a, i); },
  indexOf: (a) -> (v) -> { __arr_indexof(a, v); },
  includes: (a) -> (v) -> { __arr_indexof(a, v) >= 0; },
  join: (a) -> (sep) -> { __arr_join(a, sep); },
  reverse: __arr_reverse,
  concat: __arr_concat,
  at: (a, i) -> { __get_index(a, i); },
};
let stdString = {
  length: __s_len,
  concat: __s_concat,
  toString: (s) -> { s; },
  trim: __s_trim,
  toUpperCase: (s) -> { __s_case(s, true); },
  toLowerCase: (s) -> { __s_case(s, false); },
  includes: __s_includes,
  replace: __s_replace,
  split: __s_split,
  repeat: __s_repeat,
  startsWith: __s_sw,
  endsWith: __s_ew,
  join: (a) -> (sep) -> { __arr_join(a, sep); },
  at: (s, i) -> { __get_index(s, i); },
};
let std = { Type: Type, Error: stdError, Object: stdObject, Number: stdNumber, Array: stdArray, String: stdString };
let isError = __isError;
let Array = __arr_ctor;
let Object = __obj_ctor;
