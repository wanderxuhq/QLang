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
                  false;
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
  __str_new(buf, total);
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
