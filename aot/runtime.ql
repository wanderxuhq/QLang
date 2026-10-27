// aot/runtime.ql — 编译进产物的运行时语义层(QLang)
// 依赖内存/输出 leaf,以及 ql_openat / ql_read / ql_close / ql_readlinkat 文件系统调用。
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
let __EMPTY = null; // Empty buckets must not collide with the valid empty-string key.

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

let readU64 = (p, off): Number -> {
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
  if tag == 5 { writeU64(p, 24, 0); };
  p;
};

// Numbers are immutable inline values; copying does not allocate.
// tag-2 STRING box {tag@0=2, buf@8, len@16, count@24, lastIdx+1@32, lastPos@40}.
// count caches the scalar length and (lastIdx+1,lastPos) cache the last scalar
// lookup, so sequential s[i] (the QLang String library, frontend lexer) is O(n)
// instead of O(n^2). 0 means "not cached"; every box is mutable.
let __str_new = (buf, len) -> {
  let box = allocBox(2, 48);
  ql_mem_store_ptr(box, 8, buf);
  writeU64(box, 16, len);
  writeU64(box, 24, 0);
  writeU64(box, 32, 0);
  writeU64(box, 40, 0);
  box;
};

// ERROR: public values kind@8/message@24/line@40/col@56/cause@72; private file@88/trace@104 (120 bytes).
// kind/message are String values, line/col inline Numbers, cause an Error or null.
let __zero_num = 0;
// Non-null contexts suppress implementation-code provenance while evaluating ASTs.
let __error_source = null;
let __err_new = (kind, msg, cause) -> {
  let b = allocBox(8, 120);
  ql_value_store(b, 8, kind);
  ql_value_store(b, 24, msg);
  ql_value_store(b, 40, __zero_num);
  ql_value_store(b, 56, __zero_num);
  ql_value_store(b, 72, cause);
  ql_value_store(b, 88, "");
  ql_value_store(b, 104, null);
  if __error_source != null {
    ql_value_store(b, 40, __error_source.line);
    ql_value_store(b, 56, __error_source.col);
    ql_value_store(b, 88, __error_source.file);
    // A private origin marker distinguishes a fresh error from a cached error
    // returned at the very same source position in a later invocation.
    ql_value_store(b, 104, {file: "", line: 0, col: 0, parent: null, birth: __error_source});
  };
  b;
};
let __err = (kind, msg) -> { __err_new(kind, msg, null); };
let __isError = (v) -> { readU64(v, 0) == 8; };
let __err_cause = (e) -> { ql_value_get(e, 72); };
// Error provenance is persistent: reusing a stored Error never changes its
// original location or previous call paths. Only failure edges allocate.
let __err_at = (e, file, line, col, callFrame) -> {
  if __error_source != null { return e; };
  __err_record(e, file, line, col, callFrame);
};
let __err_record = (e, file, line, col, callFrame) -> {
  let previous = ql_value_get(e, 104);
  let located = ql_value_get(e, 40) != 0;
  if located && __error_source != null && previous != null && __same_ptr(previous.birth, __error_source) { return e; };
  if located && !callFrame { return e; };
  let copy = __err_new(ql_value_get(e, 8), ql_value_get(e, 24), ql_value_get(e, 72));
  if located {
    ql_value_store(copy, 40, ql_value_get(e, 40));
    ql_value_store(copy, 56, ql_value_get(e, 56));
    ql_value_store(copy, 88, ql_value_get(e, 88));
    let frame = {file: file, line: line, col: col, parent: ql_value_get(e, 104), birth: null};
    ql_value_store(copy, 104, frame);
  } else {
    ql_value_store(copy, 40, line); ql_value_store(copy, 56, col);
    ql_value_store(copy, 88, file);
  };
  copy;
};
let __err_get = (e, field) -> {
  let k = field;
  if k == "kind" { ql_value_get(e, 8); }
  else { if k == "message" { ql_value_get(e, 24); }
  else { if k == "line" { ql_value_get(e, 40); }
  else { if k == "col" { ql_value_get(e, 56); }
  else { if k == "cause" { ql_value_get(e, 72); }
  else { __err("UndefinedField", "Undefined field: " + field); }; }; }; }; };
};

// OBJECT 盒 {tag@0=6, table@8, cap@16, count@24};桶表 ql_alloc(32*cap),[k0,v0,k1,v1,...],
// 槽 i 键 table+i*32、值 table+i*32+16;空槽哨兵 __EMPTY 值(绝不存 raw 0)。

// Hash string contents, matching __str_eq. Hashing the box header includes
// its buffer address and makes equal dynamically-created keys unreachable.
// Floating remainder via exact power-of-two subtraction (Sterbenz lemma).
// The common bounded integer case uses an integer remainder primitive, not
// a floating quotient converted to i64. The fallback handles all finite f64s.
let __num_rem = (a, b) -> {
  if a != a || b != b || (a - a) != 0 { return __num_nan(); };
  if (b - b) != 0 || a == 0 { return a; };
  let negative = a < 0; let x = a; let y = b;
  if negative { x = -x; }; if y < 0 { y = -y; };
  if y == 0 { return __op_div0(); };
  if x >= y {
    if x <= 9007199254740991 && y <= 9007199254740991 && (x | 0) == x && (y | 0) == y {
      x = ql_integer_rem(x, y);
    } else {
      let scale = y;
      while scale <= x / 2 { scale = scale * 2; };
      while scale >= y {
        if x >= scale { x = x - scale; };
        scale = scale / 2;
      };
    };
  };
  if negative { -x } else { x };
};

let __hash = (key) -> {
  let h = 7;
  let i = 0;
  let buf = ql_mem_get_ptr(key, 8);
  let len = readU64(key, 16);
  while i < len {
    h = (h * 31 + ql_mem_get(buf, i)) % 1000003;
    i = i + 1;
  };
  h;
};

let __obj_new = () -> {
  let o = allocBox(6, 32);
  let cap = 4;
  let table = ql_alloc(32 * cap);
  let i = 0;
  while i < 8 {
    ql_value_store(table, i * 16, __EMPTY);
    i = i + 1;
  };
  ql_mem_store_ptr(o, 8, table);
  writeU64(o, 16, cap);
  writeU64(o, 24, 0);
  o;
};

// Internal slot lookup distinguishes absence from an Error stored as data.
// Callers supply a validated Object and String, or trusted runtime values.
let __obj_find = (o, key) -> {
  let table = ql_mem_get_ptr(o, 8); let cap = readU64(o, 16);
  let h = __hash(key); let i = 0;
  while i < cap {
    let slot = (h + i) % cap; let k = ql_value_get(table, slot * 32);
    if k == __EMPTY { return -1; };
    if k == key { return slot; };
    i = i + 1;
  };
  -1;
};
let __obj_get = (o, key) -> {
  let slot = __obj_find(o, key);
  if slot < 0 { return __err("UndefinedField", "Undefined field"); };
  ql_value_get(ql_mem_get_ptr(o, 8), slot * 32 + 16);
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
    k = ql_value_get(table, slot * 32);
    if k == __EMPTY {
      ql_value_store(table, slot * 32, key);
      ql_value_store(table, slot * 32 + 16, v);
      count = count + 1;
      writeU64(o, 24, count);
      if count * 10 >= cap * 7 {
        __rehash(o);
      };
      done = 1;
    } else {
      if k == key {
        ql_value_store(table, slot * 32 + 16, v);
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
  let table = ql_alloc(32 * newcap);
  let i = 0;
  while i < newcap * 2 {
    ql_value_store(table, i * 16, __EMPTY);
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
    k = ql_value_get(old, j * 32);
    if k != __EMPTY {
      v = ql_value_get(old, j * 32 + 16);
      h = __hash(k);
      p = 0;
      done = 0;
      while done == 0 {
        slot = (h + p) % newcap;
        k2 = ql_value_get(table, slot * 32);
        if k2 == __EMPTY {
          ql_value_store(table, slot * 32, k);
          ql_value_store(table, slot * 32 + 16, v);
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
  if readU64(i, 0) == 8 { return i; };
  if readU64(i, 0) != 1 { return __err("CannotIndex", "array index must be a Number"); };
  // Check range/finite values before remainder lowers to an integer conversion.
  if !__num_isfinite(i) || i < -len || i >= len { return __err("IndexOutOfBounds", "Index out of bounds"); };
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
    __s_len(o);
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
  // The interpreter bridge uses this metadata to pass raw arguments to native
  // functions. Ordinary QLang closures must keep probing as an error.
  if tag == 7 && key == "name" && readU64(o, 32) >= 2 && ql_value_get(o, 40) != null {
    return ql_value_get(o, 40);
  };
  if tag == 6 {
    __obj_get(o, key);
  } else {
    if tag == 8 {
      // Preserve the existing public Error fields; provenance stays internal.
      if key == "type" { ql_value_get(o, 8); }
      else { if key == "message" { ql_value_get(o, 24); }
      else { if key == "line" { ql_value_get(o, 40); }
      else { if key == "col" { ql_value_get(o, 56); }
      else { if key == "cause" { ql_value_get(o, 72); }
      else { __err("UndefinedField", "Undefined field: " + key); }; }; }; }; };
    } else {
      if tag == 5 {
        if key == "add" { return __native((v) -> { __arr_add(o, v); null; }, "Array.add", false); };
        if key == "remove" { return __native((i) -> { __arr_remove(o, i); null; }, "Array.remove", false); };
        __err("UndefinedField", "Undefined field");
      } else {
        __err("NotAnObject", "Not an object");
      };
    };
  };
};

let __protected_write = (o, key) -> {
  if key != "check" && key != "raise" && key != "of" && key != "make" { return false; };
  o == Number || o == String || o == Boolean || o == Null || o == AnyArray || o == AnyObject || o == Function || o == Any || o == Never || o == Error || o == Type;
};
let __set_field = (o, key, v) -> {
  let tag = readU64(o, 0);
  if tag == 8 { return o; };
  if tag == 6 {
    if __protected_write(o, key) { return __err("Custom", "cannot overwrite protected member '" + key + "' of built-in type"); };
    __obj_set(o, key, v);
    null;
  } else {
    __err("NotAnObject", "Not an object");
  };
};

let __get_index = (c, i) -> {
  let tag = readU64(c, 0);
  // Error fields are readable through either spelling. The core interpreter
  // uses computed keys even when the user's AST contains a dotted field.
  if tag == 8 && readU64(i, 0) == 2 { return __get_field(c, i); };
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
      ql_value_get(els, r * 16);
    };
  } else {
    if tag == 6 {
      if readU64(i, 0) == 8 { return i; };
      if readU64(i, 0) == 1 { return __obj_get(c, __itoa(i)); };
      if readU64(i, 0) != 2 { return __err("CannotIndex", "object key must be a String or Number"); };
      __obj_get(c, i);
    } else {
      if tag == 2 {
        __s_at(c, i);
      } else {
        __err("CannotIndex", "Cannot index");
      };
    };
  };
};

let __set_index = (c, i, v) -> {
  let tag = readU64(c, 0);
  if tag == 8 { return c; };
  if readU64(i, 0) == 8 { return i; };
  if tag == 5 {
    if readU64(i, 0) != 1 { return __err("CannotIndex", "array index must be a Number"); };
    let len = readU64(c, 16);
    if i == len { __arr_add(c, v); return null; };
    let at = __norm_idx(i, len)?;
    ql_value_store(ql_mem_get_ptr(c, 8), at * 16, v);
    return null;
  };
  if tag == 6 {
    if readU64(i, 0) == 1 { return __set_field(c, __itoa(i), v); };
    if readU64(i, 0) == 2 { return __set_field(c, i, v); };
    return __err("CannotIndex", "object key must be a String or Number");
  };
  __err("CannotIndex", "Cannot index");
};

// ARRAY: tag@0, data@8, length@16, capacity@24. Appending is amortized
// O(1), including arr[arr.length] assignments used by the QLang frontend.
let __arr_add = (a, v) -> {
  let els = ql_mem_get_ptr(a, 8);
  let len = readU64(a, 16); let capacity = readU64(a, 24);
  // Direct array builders may leave capacity at zero; their length is safe.
  if capacity < len { capacity = len; };
  if len >= capacity {
    let next = capacity * 2; if next < 4 { next = 4; };
    let data = ql_alloc(16 * next); let i = 0;
    while i < len {
      ql_value_store(data, i * 16, ql_value_get(els, i * 16)); i = i + 1;
    };
    els = data; ql_mem_store_ptr(a, 8, data); writeU64(a, 24, next);
  };
  ql_value_store(els, len * 16, v);
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
      ql_value_store(els, j * 16, ql_value_get(els, (j + 1) * 16));
      j = j + 1;
    };
    ql_value_store(els, (len - 1) * 16, null);
    writeU64(a, 16, len - 1);
    null;
  };
};

// ---- M3 T2:操作区派发(R1/R14)----
// 递归安全:__op_zone_error 的 "cannot apply " + word + ... STRING 拼接在编译期经
// emitBinaryOp 派发 __op_add,__op_add 内字节拷贝算术全 NUMBER → 内联,无递归;__op_eq
// 内 ta == 8 等为 NUMBER 比较 → 内联 fcmp;true/false 字面量 ✓。

// Inline Boolean: kind=3, payload=0/1.
let __mkbool = (b) -> { if b { true; } else { false; }; };

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

let __neg_error = (value) -> {
  let cause = null; if readU64(value, 0) == 8 { cause = value; };
  __err_new("TypeMismatch", "cannot apply unary negation to " + __type_name(value) + " and Number", cause);
};

let __pos_error = (value) -> {
  let cause = null; if readU64(value, 0) == 8 { cause = value; };
  let name = if __is_type_value(value) { "Type"; } else { __type_name(value); };
  __err_new("TypeMismatch", "cannot apply unary plus to " + name + " and Number", cause);
};

let __op_div0 = () -> {
  __err("DivisionByZero", "division by zero");
};

// panic:契约违反的落点(不可恢复)。物化一个带 kind/message 的 Error 后从顶层退出 —— 走的是
// 「顶层未处理错误」同一条路(__exit_error),所以它**不是值**、不进类型、不产生错误边。
// 对照 Rust:R2(只用于契约违反;数据失败一律 Result)、R1(每个 panic 点必须有可检查的配套)、
// 固定 abort(不做 unwinding ⇒ 没有「可被抓住的 panic」)。详见 log §5⑲.3/⑲.4。
// 本步**只加原语**:目前没有任何调用点,行为不变。
let __panic = (kind, message) -> {
  __exit_error(__err(kind, message));
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
                  __same_ptr(a, b);
                } else {
                  // Ruling T6-C:双 Number 值 → 内联 fcmp(emitBinaryOp 双 tag1 路径,不递归)
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

// Keep the existing exact safe-integer path. Other finite values share the
// existing shortest-round-trip conversion instead of truncating fractions.
let __itoa = (n): String -> {
  if n != n { return "NaN"; };
  if (n - n) != 0 { if n < 0 { return "-inf"; } else { return "inf"; }; };
  if n == 0 && ql_mem_get(n, 15) >= 128 { return "-0"; };
  let negative = n < 0;
  let value = if negative { -n; } else { n; };
  if value > 9007199254740991 || value % 1 != 0 { return __json_number_text(n); };
  let length = 0; let rest = value;
  while rest >= 1 {
    length = length + 1; rest = (rest - rest % 10) / 10;
  };
  if length == 0 { length = 1; };
  let start = if negative { 1; } else { 0; };
  let total = start + length; let buffer = ql_alloc(total);
  if negative { ql_mem_store(buffer, 0, 45); };
  let i = 0;
  while i < length {
    let digit = value % 10;
    ql_mem_store(buffer, start + length - 1 - i, 48 + digit);
    value = (value - digit) / 10; i = i + 1;
  };
  __str_new(buffer, total);
};

// Boolean 值 → "true"/"false" 字节缓冲
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

// User-level contract check (R1: the condition itself is the checkable form).
// Failing it is a contract violation, not a value: __panic exits the process.
let assert = (condition, message) -> {
  if !condition { __panic("AssertionFailed", __str(message)); };
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

// Interpolation renders values rather than the diagnostic labels used by print.
let __interpolate = (v) -> {
  let tag = readU64(v, 0);
  if tag == 5 {
    let text = "["; let i = 0;
    while i < readU64(v, 16) {
      if i > 0 { text = text + ", "; };
      text = text + __interpolate(__get_index(v, i)); i = i + 1;
    };
    return text + "]";
  };
  if tag == 6 {
    let text = "{"; let keys = __obj_keys(v); let i = 0;
    while i < keys.length {
      if i > 0 { text = text + ", "; };
      let key = keys[i]; text = text + key + ": " + __interpolate(__obj_get(v, key)); i = i + 1;
    };
    return text + "}";
  };
  if tag == 7 {
    let mode = readU64(v, 32);
    if mode == 0 || mode == 1 || (mode == 7 && ql_value_get(v, 40) == null) { return "<function>"; };
    return "<native fn " + ql_value_get(v, 40) + ">";
  };
  if tag == 8 { return __err_chain(v); };
  __str(v);
};

// 写 fd(1/2)+ 字符串(直接 STRING 盒)
let __wfd = (fd, s) -> {
  ql_write(fd, ql_mem_get_ptr(s, 8), readU64(s, 16));
  null;
};

// Unhandled diagnostics include provenance. Error.toString retains its
// established message/cause representation for interpolation and data APIs.
let __err_trace_report = (frame) -> {
  if frame == null { return ""; };
  if frame.line == 0 { return __err_trace_report(frame.parent); };
  __err_trace_report(frame.parent) + "\n  at " + frame.file + ":" + __itoa(frame.line) + ":" + __itoa(frame.col);
};
let __err_report = (e) -> {
  let text = __err_get(e, "kind") + ": " + __err_get(e, "message");
  if ql_value_get(e, 40) != 0 {
    text = ql_value_get(e, 88) + ":" + __itoa(ql_value_get(e, 40)) + ":" + __itoa(ql_value_get(e, 56)) + ": " + text;
  };
  text = text + __err_trace_report(ql_value_get(e, 104));
  let cause = __err_cause(e);
  if __isError(cause) { text = text + "\n  └─ caused by: " + __err_report(cause); };
  text;
};
// 顶层未捕获错误:stderr 打印错误链 + exit 1
let __exit_error = (e) -> {
  __wfd(2, __err_report(e));
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

// Built-in predicates: a type object is not itself a function.
let __pred_number = (v) -> { readU64(v, 0) == 1; };
let __pred_string = (v) -> { readU64(v, 0) == 2; };
let __pred_boolean = (v) -> { readU64(v, 0) == 3; };
let __pred_null = (v) -> { readU64(v, 0) == 4; };
let __pred_array = (v) -> { readU64(v, 0) == 5; };
let __pred_object = (v) -> { readU64(v, 0) == 6 && !__is_type_value(v); };
let __pred_function = (v) -> { readU64(v, 0) == 7; };
let __pred_any = (v) -> { true; };
let __pred_never = (v) -> { false; };
let __pred_error = (v) -> { readU64(v, 0) == 8; };
let __pred_type = (v) -> { __is_type_value(v); };

// 类型对象构造 {check: cf}(普通 tag6 对象,非受保护;host user_type 镜像)
let __mk_atype = (cf) -> {
  __native(cf, "<Array.check>", false);
  __mk_otype(cf);
};
let __mk_otype = (cf) -> {
  if readU64(cf, 32) == 1 { __native(cf, "<Object.check>", false); };
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
      r = cf(ql_value_get(els, i * 16));
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
        ce = ql_value_get(ql_mem_get_ptr(checks, 8), i * 16);
        r = ce(ql_value_get(els, i * 16));
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
let __obj_keys = (o): AnyArray -> {
  if readU64(o, 0) != 6 { return __err("TypeMismatch", "Object.keys expects Object"); };
  let table = ql_mem_get_ptr(o, 8);
  let cap = readU64(o, 16);
  let res = null;
  let els = null;
  let j = 0;
  let k = null;
  let n = 0;
  res = allocBox(5, 32);
  els = ql_alloc(16 * cap);
  ql_mem_store_ptr(res, 8, els);
  writeU64(res, 16, 0);
  j = 0;
  while j < cap {
    k = ql_value_get(table, j * 32);
    if k != __EMPTY {
      ql_value_store(els, n * 16, k);
      n = n + 1;
    };
    j = j + 1;
  };
  writeU64(res, 16, n);
  res;
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
      k = ql_value_get(ql_mem_get_ptr(keys, 8), i * 16);
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
      fv = __obj_get(o, ql_value_get(ql_mem_get_ptr(ks, 8), i * 16));
      if readU64(fv, 0) == 8 {
        ok = 0;
      } else {
        ce = ql_value_get(ql_mem_get_ptr(cs, 8), i * 16);
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
      __mk_atype((a) -> { readU64(a, 0) == 5 && readU64(a, 16) == x; });
    };
  } else {
    if __is_type_value(x) {
      cf = __get_field(x, "check");
      __mk_atype((a) -> { __arr_elem_check(cf, a); });
    } else {
      if tag == 5 {
        els = ql_mem_get_ptr(x, 8);
        clen = readU64(x, 16);
        bad = 0;
        i = 0;
        while i < clen {
          ce = ql_value_get(els, i * 16);
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
          checks = allocBox(5, 32);
          nb = ql_alloc(16 * clen);
          ql_mem_store_ptr(checks, 8, nb);
          writeU64(checks, 16, clen);
          i = 0;
          while i < clen {
            ce = ql_value_get(els, i * 16);
            ql_value_store(nb, i * 16, __get_field(ce, "check"));
            i = i + 1;
          };
          __mk_atype((a) -> { __tuple_check(checks, a); });
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
                checks = allocBox(5, 32);
                els = ql_alloc(16 * lv);
                ql_mem_store_ptr(checks, 8, els);
                writeU64(checks, 16, lv);
                i = 0;
                while i < lv {
                  ql_value_store(els, i * 16, cf);
                  i = i + 1;
                };
                __mk_atype((a) -> { __tuple_check(checks, a); });
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
      cs = allocBox(5, 32);
      nb = ql_alloc(16 * kn);
      ql_mem_store_ptr(cs, 8, nb);
      writeU64(cs, 16, kn);
      bad = 0;
      i = 0;
      while i < kn {
        k = ql_value_get(ql_mem_get_ptr(ks, 8), i * 16);
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
            ql_value_store(nb, i * 16, __get_field(ce, "check"));
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

// Private numeric predicates remain for language/runtime operations.
let __num_isfinite = (n) -> {
  if readU64(n, 0) == 1 { !(n != n || (n - n) != (n - n)); } else { false; };
};
let __num_nan = () -> __number_bits(2251799813685248, 2047, false);

// The Error type constructor takes a message and an optional Error cause.
// The dispatcher supplies its argument array, avoiding implicit currying.
let __error_construct = (args) -> {
  let message = "error";
  let cause = null;
  if args.length > 0 { message = args[0]; };
  if args.length > 1 { cause = args[1]; };
  __error_raise("Error", message, cause);
};

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
let Error = { check: __pred_error, raise: __error_construct };
let Type = { check: __pred_type, of: __type_of_val, make: __type_make };
let stdError = { raise: __error_raise, toString: __error_tostring };
// M3 T5:std.Object / std.Number(host create_object_module/create_number_module 镜像)
// Ruling T5-B:field 必须非柯里化 2 参(host arity-2);merge/hasOwn/get 保持柯里化
// Ordinary Object algorithms are installed from the shared library bundle.
let stdObject = { keys: __obj_keys };
// Low-level binary64 mechanisms: frexp/ldexp expose the representation only
// (mantissa in [1,2) and a power-of-two exponent). Every Math algorithm that
// builds on them lives in the shared QLang library.
let __num_frexp = (x): AnyArray -> {
  if readU64(x, 0) != 1 { return __err("TypeMismatch", "Number.frexp expects Number"); };
  if x == 0 || !__num_isfinite(x) { return [x, 0]; };
  let negative = ql_mem_get(x, 15) >= 128;
  let magnitude = x; if negative { magnitude = -x; };
  let parts = __math_parts(magnitude);
  if negative { return [-parts[0], parts[1]]; };
  parts;
};
let __num_ldexp = (m) -> {
  (e) -> {
    if readU64(m, 0) != 1 || readU64(e, 0) != 1 { return __err("TypeMismatch", "Number.ldexp expects Number"); };
    __math_scale(m, e);
  };
};
let stdNumber = {
  toString: __itoa,
  frexp: __num_frexp,
  ldexp: __num_ldexp,
};
// Language string length/indexing primitives (Unicode scalar semantics).
let __s_len = (s) -> {
  if readU64(s, 0) != 2 { return __err("TypeMismatch", "String.length expects String"); };
  let cached = readU64(s, 24);
  if cached != 0 { return cached; };
  let buf = ql_mem_get_ptr(s, 8);
  let len = readU64(s, 16);
  if len == 0 { return 0; };
  let pos = 0; let count = 0;
  while pos < len { pos = pos + __utf8_width(ql_mem_get(buf, pos)); count = count + 1; };
  writeU64(s, 24, count);
  count;
};
// Array algorithms are installed from the shared ordinary QLang module.
let stdArray = {};
// String indices count Unicode scalars, while STRING headers retain byte lengths.
let __utf8_width = (byte) -> {
  if byte < 128 { 1; } else if byte < 224 { 2; } else if byte < 240 { 3; } else { 4; };
};
// Byte position of scalar `index`, using and updating the (lastIdx+1,lastPos)
// cache in the box so sequential traversal is O(1) amortized.
let __s_pos = (s, buf, index) -> {
  let cachedIdx = readU64(s, 32);
  let cachedPos = readU64(s, 40);
  let pos = 0; let i = 0;
  if cachedIdx != 0 && index == cachedIdx - 1 { pos = cachedPos; }
  else if cachedIdx != 0 && index == cachedIdx { pos = cachedPos + __utf8_width(ql_mem_get(buf, cachedPos)); }
  else { while i < index { pos = pos + __utf8_width(ql_mem_get(buf, pos)); i = i + 1; }; };
  writeU64(s, 32, index + 1);
  writeU64(s, 40, pos);
  pos;
};
let __s_at = (s, idx) -> {
  if readU64(s, 0) != 2 || readU64(idx, 0) != 1 { return __err("TypeMismatch", "String.at expects String and Number"); };
  let index = __norm_idx(idx, __s_len(s))?;
  let buf = ql_mem_get_ptr(s, 8);
  let pos = __s_pos(s, buf, index);
  // Clamp a truncated trailing multibyte scalar to the byte length: never read
  // past the buffer for malformed UTF-8.
  let len = readU64(s, 16);
  let width = __utf8_width(ql_mem_get(buf, pos));
  if pos + width > len { width = len - pos; };
  // 单字节 ASCII ⇒ 共享盒(不做分配)。这里直接用叶子读表:走 `__get_index` 的话,
  // 下标规整(有限/整数/回绕)比它省下的分配还贵。
  if width == 1 {
    let byte = ql_mem_get(buf, pos);
    if byte < 128 { return ql_value_get(ql_mem_get_ptr(__asciiChars, 8), byte * 16); };
  };
  let out = ql_alloc(width);
  let i = 0;
  while i < width { ql_mem_store(out, i, ql_mem_get(buf, pos + i)); i = i + 1; };
  __str_new(out, width);
};
let __s_codepoint = (s) -> {
  if readU64(s, 0) != 2 { return __err("TypeMismatch", "String.codePointAt expects String"); };
  // Migration debt: `?` can return an Error, so this inner function must not
  // claim `: Number` until it is migrated to a Result return type.
  (idx) -> {
    if readU64(idx, 0) != 1 { return __err("TypeMismatch", "String.codePointAt expects Number"); };
    let buf = ql_mem_get_ptr(s, 8);
    let at = __norm_idx(idx, __s_len(s))?;
    let pos = __s_pos(s, buf, at);
    let len = readU64(s, 16);
    let b = ql_mem_get(buf, pos);
    let width = __utf8_width(b);
    if pos + width > len { width = len - pos; };
    let cp = b;
    if width == 2 { cp = b - 192; };
    if width == 3 { cp = b - 224; };
    if width == 4 { cp = b - 240; };
    let j = 1;
    while j < width { cp = cp * 64 + ql_mem_get(buf, pos + j) - 128; j = j + 1; };
    cp;
  };
};

// Inverse of codePointAt: UTF-8 encode one Unicode scalar into a STRING
// box. Low-level string-construction mechanism only; no library algorithm.
let __s_from_codepoint = (cp) -> {
  if readU64(cp, 0) != 1 { return __err("TypeMismatch", "String.fromCodePoint expects Number"); };
  if cp != cp || cp % 1 != 0 || cp < 0 || cp > 1114111 || (cp >= 55296 && cp <= 57343) {
    return __err("RangeError", "String.fromCodePoint expects a Unicode scalar value");
  };
  let buf = ql_alloc(4);
  let n = 1;
  if cp < 128 { ql_mem_store(buf, 0, cp); }
  else if cp < 2048 {
    ql_mem_store(buf, 0, 192 + (cp - cp % 64) / 64);
    ql_mem_store(buf, 1, 128 + cp % 64); n = 2;
  } else if cp < 65536 {
    ql_mem_store(buf, 0, 224 + (cp - cp % 4096) / 4096);
    ql_mem_store(buf, 1, 128 + ((cp - cp % 64) / 64) % 64);
    ql_mem_store(buf, 2, 128 + cp % 64); n = 3;
  } else {
    ql_mem_store(buf, 0, 240 + (cp - cp % 262144) / 262144);
    ql_mem_store(buf, 1, 128 + ((cp - cp % 4096) / 4096) % 64);
    ql_mem_store(buf, 2, 128 + ((cp - cp % 64) / 64) % 64);
    ql_mem_store(buf, 3, 128 + cp % 64); n = 4;
  };
  __str_new(buf, n);
};

// Transitional primitive only: its portable scalar-codepoint API is tracked.
// All other String members are supplied by the shared QLang library loader.
let stdString = { codePointAt: __s_codepoint, fromCodePoint: __s_from_codepoint };
// Binary64 representation mechanisms (frexp/ldexp), the variadic max/min
// wrappers and their comparison all stay here. The call-buffer contract requires
// a variadic Math.max/Math.min call to perform no per-call heap work, which holds
// only for runtime-internal code (a library call would allocate a frame); the
// variadic dispatch also carries the diagnostic name t26 pins.
// Scale by a power of two, keeping the final subnormal rounding in one step.
// Callers use bounded integral exponents; no approximate decimal powers.
let __math_scale = (n, e) -> {
  if e > 1023 { return (n * __number_bits(0, e, false)) * __number_bits(0, 2046, false); };
  if e < -1022 { return (n * __number_bits(0, e + 1074 + 1023, false)) * __number_bits(1, 0, false); };
  n * __number_bits(0, e + 1023, false);
};
// Positive finite n -> [mantissa in [1,2), binary exponent].
let __math_parts = (n) -> {
  let b6 = ql_mem_get(n, 14); let hi = ql_mem_get(n, 15);
  let e = (hi & 127) * 16 + (b6 & 240) / 16;
  let m = b6 & 15; let i = 5;
  while i >= 0 { m = m * 256 + ql_mem_get(n, 8 + i); i = i - 1; };
  if e == 0 {
    e = -1022;
    while m < 4503599627370496 { m = m * 2; e = e - 1; };
  } else { m = m + 4503599627370496; e = e - 1023; };
  [m / 4503599627370496, e];
};
// The dispatcher lends the entire argument list to these variadic natives.
// Consume it synchronously; never capture or return the borrowed descriptor.
let __math_number = (n, name) -> {
  if readU64(n, 0) == 1 { return n; };
  __err("TypeMismatch", name + " expects Number");
};
let __math_extreme = (args, maximum) -> {
  let result = __number_bits(0, 2047, maximum);
  let name = if maximum { "Math.max" } else { "Math.min" };
  let i = 0;
  while i < args.length {
    let n = __math_number(args[i], name)?;
    // Keep checking types after NaN; a later invalid argument is still an error.
    if n != n { result = n; }
    else if result == result {
      if (maximum && n > result) || (!maximum && n < result) { result = n; }
      else if n == 0 && result == 0 {
        let negative = ql_mem_get(n, 15) >= 128;
        if maximum != negative { result = n; };
      };
    };
    i = i + 1;
  };
  result;
};
let __math_max = (args) -> __math_extreme(args, true);
let __math_min = (args) -> __math_extreme(args, false);
let __math_random = () -> {
  // Construct a uniform 53-bit integer. Handle short reads and EINTR in QLang;
  // never turn an entropy failure into a constant or predictable fallback.
  let buf = ql_alloc(7); let done = 0; let value = 0;
  while done < 7 {
    let got = ql_getrandom(buf, 7 - done);
    if got != -4 {
      if got <= 0 || got > 7 - done { return __err("IOError", "Math.random: entropy unavailable"); };
      let i = 0;
      while i < got {
        let byte = ql_mem_get(buf, i);
        if done == 0 { value = byte % 32; } else { value = value * 256 + byte; };
        i = i + 1; done = done + 1;
      };
    };
  };
  value / 9007199254740992;
};
// Variadic max/min dispatch and entropy-backed random are language mechanisms;
// every other Math algorithm is supplied by the shared QLang library.
let stdMath = {
  max: __math_max,
  min: __math_min,
  random: __math_random,
};
// Exact nonnegative integers in base 10^7. Limb arithmetic stays below 2^53,
// so f64-backed QLang numbers represent every intermediate integer exactly.
let __big = (n) -> {
  let a = [];
  while n > 0 { let d = n % 10000000; __arr_add(a, d); n = (n - d) / 10000000; };
  if a.length == 0 { __arr_add(a, 0); };
  a;
};
let __big_copy = (a) -> {
  let n = readU64(a, 16);
  let src = ql_mem_get_ptr(a, 8);
  let out = allocBox(5, 32);
  let dst = ql_alloc(16 * n);
  let i = 0;
  while i < n { ql_value_store(dst, i * 16, ql_value_get(src, i * 16)); i = i + 1; };
  ql_mem_store_ptr(out, 8, dst); writeU64(out, 16, n);
  out;
};
let __big_mul = (a, m) -> {
  let n = readU64(a, 16);
  let data = ql_mem_get_ptr(a, 8);
  let carry = 0; let i = 0;
  while i < n {
    let v = ql_value_get(data, i * 16) * m + carry;
    let d = v % 10000000;
    ql_value_store(data, i * 16, d);
    carry = (v - d) / 10000000;
    i = i + 1;
  };
  if carry > 0 { __arr_add(a, carry); };
  a;
};
let __big_add = (a, b) -> {
  let na = readU64(a, 16); let nb = readU64(b, 16);
  let da = ql_mem_get_ptr(a, 8); let db = ql_mem_get_ptr(b, 8);
  let n = na; if nb > n { n = nb; };
  let out = allocBox(5, 32); let data = ql_alloc(16 * (n + 1));
  let i = 0; let carry = 0;
  while i < n {
    let v = carry;
    if i < na { v = v + ql_value_get(da, i * 16); };
    if i < nb { v = v + ql_value_get(db, i * 16); };
    let d = v % 10000000;
    ql_value_store(data, i * 16, d);
    carry = (v - d) / 10000000;
    i = i + 1;
  };
  if carry > 0 { ql_value_store(data, n * 16, carry); n = n + 1; };
  ql_mem_store_ptr(out, 8, data); writeU64(out, 16, n);
  out;
};
let __big_cmp = (a, b) -> {
  let na = readU64(a, 16); let nb = readU64(b, 16);
  if na < nb { return -1; };
  if na > nb { return 1; };
  let da = ql_mem_get_ptr(a, 8); let db = ql_mem_get_ptr(b, 8);
  let i = na - 1;
  while i >= 0 {
    let va = ql_value_get(da, i * 16); let vb = ql_value_get(db, i * 16);
    if va < vb { return -1; };
    if va > vb { return 1; };
    i = i - 1;
  };
  0;
};
let __big_sub = (a, b) -> {
  let na = readU64(a, 16); let nb = readU64(b, 16);
  let da = ql_mem_get_ptr(a, 8); let db = ql_mem_get_ptr(b, 8);
  let borrow = 0; let i = 0;
  while i < na {
    let v = ql_value_get(da, i * 16) - borrow;
    if i < nb { v = v - ql_value_get(db, i * 16); };
    borrow = 0;
    if v < 0 { v = v + 10000000; borrow = 1; };
    ql_value_store(da, i * 16, v); i = i + 1;
  };
  while na > 1 && ql_value_get(da, (na - 1) * 16) == 0 { na = na - 1; };
  writeU64(a, 16, na);
  a;
};
// Construct the f64 payload directly, including subnormals, NaN/Infinity
// and signed zero. No temporary heap Number or lossy integer round trip.
let __number_bits = (mantissa, exponent, negative): Number -> ql_number_bits(mantissa, exponent, negative);
let __json_number_text = (n) -> {
  let high = ql_mem_get(n, 15);
  let negative = high >= 128;
  if n == 0 { if negative { return "-0"; } else { return "0"; }; };
  let b6 = ql_mem_get(n, 14);
  let exponent = (high % 128) * 16 + (b6 - b6 % 16) / 16;
  let m = b6 % 16;
  let i = 5;
  while i >= 0 { m = m * 256 + ql_mem_get(n, 8 + i); i = i - 1; };
  let binary = -1074;
  if exponent > 0 { m = m + 4503599627370496; binary = exponent - 1075; };
  let even = m % 2 == 0;
  let r = __big_mul(__big(m), 4);
  let s = __big(4);
  let lower = __big(2);
  let upper = __big(2);
  if exponent > 1 && m == 4503599627370496 { lower = __big(1); };
  while binary >= 23 {
    __big_mul(r, 8388608); __big_mul(lower, 8388608); __big_mul(upper, 8388608); binary = binary - 23;
  };
  while binary > 0 {
    __big_mul(r, 2); __big_mul(lower, 2); __big_mul(upper, 2); binary = binary - 1;
  };
  while binary <= -23 { __big_mul(s, 8388608); binary = binary + 23; };
  while binary < 0 { __big_mul(s, 2); binary = binary + 1; };
  let decimal = 0;
  let chunk = __big_mul(__big_copy(s), 10000000);
  while __big_cmp(r, chunk) >= 0 {
    s = chunk; chunk = __big_mul(__big_copy(s), 10000000); decimal = decimal + 7;
  };
  chunk = __big_mul(__big_copy(r), 10000000);
  while __big_cmp(chunk, s) < 0 {
    r = chunk; chunk = __big_mul(__big_copy(r), 10000000);
    __big_mul(lower, 10000000); __big_mul(upper, 10000000); decimal = decimal - 7;
  };
  let ten = __big_mul(__big_copy(s), 10);
  while __big_cmp(r, ten) >= 0 {
    s = ten; ten = __big_mul(__big_copy(s), 10); decimal = decimal + 1;
  };
  while __big_cmp(r, s) < 0 {
    __big_mul(r, 10); __big_mul(lower, 10); __big_mul(upper, 10); decimal = decimal - 1;
  };
  let digits = [];
  let done = false;
  while !done {
    let d = 0;
    while __big_cmp(r, s) >= 0 { __big_sub(r, s); d = d + 1; };
    __arr_add(digits, d);
    let lc = __big_cmp(r, lower);
    let uc = __big_cmp(__big_add(r, upper), s);
    let low = lc < 0 || (even && lc == 0);
    let up = uc > 0 || (even && uc == 0);
    if low || up {
      let round = false;
      if up && !low { round = true; };
      if up && low {
        let cmp = __big_cmp(__big_mul(__big_copy(r), 2), s);
        round = cmp > 0 || (cmp == 0 && d % 2 == 1);
      };
      if round {
        let j = digits.length - 1;
        while j >= 0 && digits[j] == 9 { digits[j] = 0; j = j - 1; };
        if j < 0 { digits = [1]; decimal = decimal + 1; }
        else { digits[j] = digits[j] + 1; };
      };
      done = true;
    } else {
      __big_mul(r, 10); __big_mul(lower, 10); __big_mul(upper, 10);
    };
  };
  while digits.length > 1 && digits[digits.length - 1] == 0 { writeU64(digits, 16, digits.length - 1); };
  let point = decimal + 1;
  let out = ql_alloc(400);
  let pos = 0;
  if negative { ql_mem_store(out, pos, 45); pos = pos + 1; };
  if point <= 0 {
    ql_mem_store(out, pos, 48); ql_mem_store(out, pos + 1, 46); pos = pos + 2;
    let j = 0;
    while j < -point { ql_mem_store(out, pos, 48); pos = pos + 1; j = j + 1; };
  };
  let length = digits.length;
  if point > length { length = point; };
  i = 0;
  while i < length {
    if i == point && point > 0 { ql_mem_store(out, pos, 46); pos = pos + 1; };
    let d = 0;
    if i < digits.length { d = digits[i]; };
    ql_mem_store(out, pos, 48 + d); pos = pos + 1; i = i + 1;
  };
  __str_new(out, pos);
};

// JSON.parse is installed from the shared QLang library.
let stdJSON = {};

// Linux filesystem interface. Paths are UTF-8 strings without embedded NUL.
let __fs_path = (path) -> {
  if readU64(path, 0) != 2 { return __err("TypeMismatch", "path must be a string"); };
  let len = readU64(path, 16); let src = ql_mem_get_ptr(path, 8);
  let buf = ql_alloc(len + 1); let i = 0;
  while i < len {
    let c = ql_mem_get(src, i);
    if c == 0 { return __err("IOError", "path contains NUL"); };
    ql_mem_store(buf, i, c); i = i + 1;
  };
  ql_mem_store(buf, len, 0);
  // Wrap the raw pointer for error checking at callers.
  __str_new(buf, len);
};
let __valid_utf8 = (s) -> {
  let buf = ql_mem_get_ptr(s, 8); let len = readU64(s, 16); let i = 0;
  while i < len {
    let c = ql_mem_get(buf, i); let width = 1;
    if c >= 194 && c <= 223 { width = 2; }
    else if c >= 224 && c <= 239 { width = 3; }
    else if c >= 240 && c <= 244 { width = 4; }
    else if c >= 128 { return false; };
    if i + width > len { return false; };
    if width > 1 {
      let second = ql_mem_get(buf, i + 1);
      if (c == 224 && second < 160) || (c == 237 && second >= 160) || (c == 240 && second < 144) || (c == 244 && second >= 144) { return false; };
      let j = 1;
      while j < width {
        let next = ql_mem_get(buf, i + j);
        if next < 128 || next > 191 { return false; }; j = j + 1;
      };
    };
    i = i + width;
  };
  true;
};
let __fs_read_text = (path) -> {
  let name = __fs_path(path)?;
  let fd = ql_openat(-100, ql_mem_get_ptr(name, 8), 524288);
  while fd == -4 { fd = ql_openat(-100, ql_mem_get_ptr(name, 8), 524288); };
  if fd < 0 { return __err("IOError", "cannot read " + path); };
  let chunks = []; let finished = false;
  while !finished {
    let buf = ql_alloc(65536); let n = ql_read(fd, buf, 65536);
    while n == -4 { n = ql_read(fd, buf, 65536); };
    if n < 0 { ql_close(fd); return __err("IOError", "cannot read " + path); };
    if n == 0 { finished = true; } else { __arr_add(chunks, __str_new(buf, n)); };
  };
  ql_close(fd);
  let text = ""; let ci = 0;
  while ci < chunks.length { text = text + chunks[ci]; ci = ci + 1; };
  if !__valid_utf8(text) { return __err("IOError", "invalid UTF-8 in " + path); };
  text;
};
let __fs_canonical = (path) -> {
  let name = __fs_path(path)?;
  // O_PATH | O_CLOEXEC: let the kernel resolve symlinks and '..' in order.
  let fd = ql_openat(-100, ql_mem_get_ptr(name, 8), 2621440);
  while fd == -4 { fd = ql_openat(-100, ql_mem_get_ptr(name, 8), 2621440); };
  if fd < 0 { return __err("IOError", "cannot resolve " + path); };
  let link = __fs_path("/proc/self/fd/" + __itoa(fd));
  let capacity = 4096; let done = false; let result = null;
  while !done {
    let buf = ql_alloc(capacity);
    let n = ql_readlinkat(-100, ql_mem_get_ptr(link, 8), buf, capacity);
    while n == -4 { n = ql_readlinkat(-100, ql_mem_get_ptr(link, 8), buf, capacity); };
    if n < 0 { ql_close(fd); return __err("IOError", "cannot resolve " + path); };
    if n < capacity { result = __str_new(buf, n); done = true; }
    else { capacity = capacity * 2; };
  };
  ql_close(fd);
  if !__valid_utf8(result) { return __err("IOError", "invalid UTF-8 in resolved path"); };
  result;
};
// 进程机制(std.process):argv 用 NUL 分隔的缓冲送进 C 叶子;stdout/stderr 落到
// 两个临时文件,C 侧不需要 poll 管道。公开面是 std.process.run(args)。
let __fs_remove = (path) -> { ql_unlink(ql_mem_get_ptr(path, 8)); null; };
let __procSeq = 0;
let __spawnRaw = (args, outPath, errPath) -> {
  let n = args.length;
  let total = 0; let i = 0;
  while i < n { total = total + __s_len(args[i]) + 1; i = i + 1; };
  let buf = ql_alloc(total);
  let off = 0; i = 0;
  while i < n {
    let str = args[i]; let src = ql_mem_get_ptr(str, 8); let len = __s_len(str); let j = 0;
    while j < len { ql_mem_store(buf, off + j, ql_mem_get(src, j)); j = j + 1; };
    ql_mem_store(buf, off + len, 0);
    off = off + len + 1; i = i + 1;
  };
  ql_spawn(buf, n, ql_mem_get_ptr(outPath, 8), ql_mem_get_ptr(errPath, 8));
};
let __procTemp = () -> {
  __procSeq = __procSeq + 1;
  "/tmp/.qlang-proc-" + __itoa(ql_getpid()) + "-" + __itoa(__procSeq);
};
let __procRun = (args) -> {
  if readU64(args, 0) != 5 { return __err("TypeMismatch", "std.process.run expects an array of arguments"); };
  let outPath = __procTemp(); let errPath = __procTemp();
  let status = __spawnRaw(args, outPath, errPath);
  let outText = ""; let errText = "";
  let outRead = __fs_read_text(outPath);
  if !isError(outRead) && outRead != null { outText = outRead; };
  let errRead = __fs_read_text(errPath);
  if !isError(errRead) && errRead != null { errText = errRead; };
  __fs_remove(outPath); __fs_remove(errPath);
  { status: status, stdout: outText, stderr: errText };
};
// 二进制(std.Bytes):Bytes 值就是一个按字节存放的 QLang 字符串(字符串本身是
// 字节序列,长度按字节算)。不要拿 String 的函数去量它的"字符数"。
let __bytes_read = (path) -> {
  let name = __fs_path(path)?;
  let fd = ql_openat(-100, ql_mem_get_ptr(name, 8), 524288);
  while fd == -4 { fd = ql_openat(-100, ql_mem_get_ptr(name, 8), 524288); };
  if fd < 0 { return __err("IOError", "cannot read " + path); };
  let chunks = []; let finished = false;
  while !finished {
    let buf = ql_alloc(65536); let n = ql_read(fd, buf, 65536);
    while n == -4 { n = ql_read(fd, buf, 65536); };
    if n < 0 { ql_close(fd); return __err("IOError", "cannot read " + path); };
    if n == 0 { finished = true; } else { __arr_add(chunks, __str_new(buf, n)); };
  };
  ql_close(fd);
  let data = ""; let ci = 0;
  while ci < chunks.length { data = data + chunks[ci]; ci = ci + 1; };
  data;
};
let __bytes_check = (b) -> readU64(b, 0) == 2;
let __bytes_length = (b) -> {
  if !__bytes_check(b) { return __err("TypeMismatch", "std.Bytes expects Bytes"); };
  // 声明长度在字符串头 +16;__s_len 是 UTF-8 字符数,对二进制是错的。
  readU64(b, 16);
};
let __bytes_at = (b, index) -> {
  if !__bytes_check(b) || readU64(index, 0) != 1 { return __err("TypeMismatch", "std.Bytes.byteAt expects Bytes and Number"); };
  let i = index;
  if i < 0 || i >= readU64(b, 16) { return __err("IndexOutOfBounds", "Bytes.byteAt"); };
  ql_mem_get(ql_mem_get_ptr(b, 8), i);
};
let __bytes_u32 = (b, index) -> {
  if !__bytes_check(b) || readU64(index, 0) != 1 { return __err("TypeMismatch", "std.Bytes.u32 expects Bytes and Number"); };
  let i = index;
  if i < 0 || i + 4 > readU64(b, 16) { return __err("IndexOutOfBounds", "Bytes.u32"); };
  let p = ql_mem_get_ptr(b, 8);
  ql_mem_get(p, i) + ql_mem_get(p, i + 1) * 256 + ql_mem_get(p, i + 2) * 65536 + ql_mem_get(p, i + 3) * 16777216;
};
let __bytes_u64 = (b, index) -> {
  let low = __bytes_u32(b, index)?;
  let high = __bytes_u32(b, index + 4)?;
  low + high * 4294967296;
};
let __hex_digit = (v) -> if v < 10 { 48 + v; } else { 87 + v; };
let __bytes_hex = (b, offset, count) -> {
  if !__bytes_check(b) { return __err("TypeMismatch", "std.Bytes.hex expects Bytes"); };
  if offset < 0 || count < 0 || offset + count > readU64(b, 16) { return __err("IndexOutOfBounds", "Bytes.hex"); };
  let src = ql_mem_get_ptr(b, 8);
  let out = ql_alloc(count * 2 + 1);
  let i = 0;
  while i < count {
    let v = ql_mem_get(src, offset + i);
    let low = v % 16; let high = (v - low) / 16;
    ql_mem_store(out, i * 2, __hex_digit(high));
    ql_mem_store(out, i * 2 + 1, __hex_digit(low));
    i = i + 1;
  };
  __str_new(out, count * 2);
};
let stdBytes = { read: __bytes_read, length: __bytes_length, byteAt: __bytes_at, u32: __bytes_u32, u64: __bytes_u64, hex: __bytes_hex };
let stdFs = { readFileText: __fs_read_text, canonicalPath: __fs_canonical };
// 公开能力:运行一个外部程序并拿到 status/stdout/stderr。
let stdProcess = { run: __procRun };

// Private embedding capability used by the QLang AST evaluator. Source points
// are ordinary language data; LLVM does not recognize interpreter/library names.
let __source_valid = (point) -> {
  if readU64(point, 0) != 6 { return false; };
  let file = point.file; let line = point.line; let col = point.col;
  if readU64(file, 0) != 2 || readU64(line, 0) != 1 || readU64(col, 0) != 1 { return false; };
  if file == "" && line == 0 && col == 0 { return true; };
  line >= 1 && line <= 9007199254740991 && col >= 1 && col <= 9007199254740991 && line % 1 == 0 && col % 1 == 0;
};
let __source_enter = (point) -> {
  let context = {file: "", line: 0, col: 0};
  if point == null && __error_source != null { point = __error_source; };
  if point != null {
    if !__source_valid(point) { return __err("TypeMismatch", "invalid diagnostic source point"); };
    context.file = point.file; context.line = point.line; context.col = point.col;
  };
  let previous = __error_source; __error_source = context; previous;
};
let __source_leave = (previous) -> {
  if previous != null && !__source_valid(previous) { return __err("TypeMismatch", "invalid diagnostic source context"); };
  __error_source = previous; null;
};
let __source_error = (error, point, callFrame) -> {
  if readU64(error, 0) != 8 { return error; };
  if point == null { return error; };
  if !__source_valid(point) { return __err("TypeMismatch", "invalid diagnostic source point"); };
  __err_record(error, point.file, point.line, point.col, callFrame);
};
let __source_api = {enter: __source_enter, leave: __source_leave, error: __source_error};

// Internal bootstrap ABI: forward an argument list to the ordinary dispatcher.
// No source-level spread syntax or special per-builtin arity table is needed.
let __call_native = (fn, arguments) -> {
  if readU64(arguments, 0) != 5 { return __err("TypeMismatch", "native call bridge expects Array arguments"); };
  let previous = __error_source;
  // Every host invocation resumes native provenance, including partials.
  // Unlocated primitive failures acquire the interpreted call site on return.
  // A callback into the interpreter establishes/restores its own source scope.
  __error_source = null;
  let result = __call_borrowed(fn, arguments, false);
  __error_source = previous;
  result;
};
// ASCII 单字符盒:s[i]、split("") 这类操作每取一个字符就新建一个 STRING 盒,而 128 个
// ASCII 字符的盒子是常量。预建一份共享盒(模块级数组 ⇒ 从运行期作用域可达 ⇒ GC 根),
// `__s_at` 命中时直接返回共享盒,不再分配。
let __asciiChars = [];
let __asciiBuild = 0;
while __asciiBuild < 128 {
  let asciiBuf = ql_alloc(1);
  ql_mem_store(asciiBuf, 0, __asciiBuild);
  __asciiChars[__asciiBuild] = __str_new(asciiBuf, 1);
  __asciiBuild = __asciiBuild + 1;
};

let std = { __diagnostics: __source_api, __callNative: __call_native, __panic: __panic, Type: Type, Error: stdError, Object: stdObject, Number: stdNumber, Array: stdArray, String: stdString, Math: stdMath, JSON: stdJSON, fs: stdFs, process: stdProcess, Bytes: stdBytes };
// Copy namespace tables so augmenting std in one file cannot affect another.
// Function values and canonical type values retain their identities.
let __copy_table = (object) -> {
  let result = {}; let keys = __obj_keys(object); let i = 0;
  while i < keys.length {
    let key = keys[i]; __obj_set(result, key, __obj_get(object, key)); i = i + 1;
  };
  result;
};
let __fresh_std = () -> {
  let result = {}; let keys = __obj_keys(std); let i = 0;
  while i < keys.length {
    let key = keys[i]; let value = __obj_get(std, key);
    // Only tables are copied. Guarding with the object predicate keeps a member that
    // is not an object (a scalar, or a function) from being dereferenced as one.
    if key != "Type" && AnyObject.check(value) && readU64(value, 0) == 6 { value = __copy_table(value); };
    __obj_set(result, key, value); i = i + 1;
  };
  result;
};
// Bootstrap installs library exports once; later files copy namespace tables.
// Only value/namespace plumbing belongs here, never library algorithms.
let __install_library = (library) -> {
  if __isError(library) { __exit_error(library); };
  let names = __obj_keys(library); let i = 0;
  while i < names.length {
    let name = names[i]; let module = __obj_get(library, name);
    let target = __obj_get(std, name);
    // A member may be *any* value, not only a module object: a function, a type or a
    // scalar is installed as-is. Only when the member and the existing target are both
    // objects are the member's keys merged into the target.
    if AnyObject.check(module) && AnyObject.check(target) {
      let keys = __obj_keys(module); let j = 0;
      while j < keys.length {
        let key = keys[j]; __obj_set(target, key, __obj_get(module, key)); j = j + 1;
      };
    } else {
      __obj_set(std, name, module);
    };
    i = i + 1;
  };
  null;
};
let __process_args = (count, pointers) -> {
  let result = []; let i = 1;
  while i < count {
    let buf = ql_mem_get_ptr(pointers, i * 8); let len = 0;
    while ql_mem_get(buf, len) != 0 { len = len + 1; };
    __arr_add(result, __str_new(buf, len)); i = i + 1;
  };
  result;
};
let args = [];
let isError = __isError;
let Array = __arr_ctor;
let Object = __obj_ctor;

// Call policy belongs to the function value, so aliases and computed callees
// behave identically. Closure layout: tag/code/env/arity/policy/name/annotations, 72 bytes; name@40 and annotations@56 are 16-byte values.
// policy 0=user, 1=internal, 2=native, 3=diagnostic native, 4=partial native,
// 5=diagnostic variadic native, 6=ordinary variadic native (argument array).
// 7=internal evaluator callback: forwards argument array and check exemption.
let __native = (fn, name, accepts) -> {
  let mode = 2; if accepts { mode = 3; };
  writeU64(fn, 32, mode);
  ql_value_store(fn, 40, name);
  fn;
};
let __native_module = (module, name) -> {
  let keys = __obj_keys(module);
  let i = 0;
  while i < keys.length {
    let key = keys[i];
    let fn = __obj_get(module, key);
    if readU64(fn, 0) == 7 { __native(fn, name + "." + key, false); };
    i = i + 1;
  };
};
let __arity_error = (expected, actual) -> {
  __err("ArityMismatch", "Arity mismatch: expected " + __itoa(expected) + " arguments, got " + __itoa(actual));
};
// The call dispatcher borrows its argument array. Only partial application
// retains the list: copy its slots, preserving the identity of reference values.
let __copy_call_args = (args) -> {
  let count = readU64(args, 16);
  let source = ql_mem_get_ptr(args, 8);
  let result = allocBox(5, 32); let data = ql_alloc(16 * count);
  ql_mem_store_ptr(result, 8, data);
  writeU64(result, 16, count); writeU64(result, 24, count);
  let i = 0;
  while i < count {
    ql_value_store(data, i * 16, ql_value_get(source, i * 16)); i = i + 1;
  };
  result;
};
// Partial application assembles the saved and new argument lists internally.
// This is calling-convention plumbing, independent of std.Array.
let __partial_args = (bound, more) -> {
  let result = []; let i = 0;
  while i < bound.length { __arr_add(result, bound[i]); i = i + 1; };
  i = 0;
  while i < more.length { __arr_add(result, more[i]); i = i + 1; };
  result;
};
let __partial = (fn, bound, remaining) -> {
  bound = __copy_call_args(bound);
  // The host's partial result is a native with exact remaining arity. The
  // thunk borrows one argument array; its public arity lives in the metadata.
  let thunk = (more) -> { __call_borrowed(fn, __partial_args(bound, more), false); };
  writeU64(thunk, 24, remaining);
  writeU64(thunk, 32, 4);
  ql_value_store(thunk, 40, "<curried>");
  thunk;
};
// Annotation checks use the normal call dispatcher; only user predicates are
// exempt from rejecting an Error argument (native predicates retain policy).
let __type_name = (v) -> {
  let tag = readU64(v, 0);
  if tag == 5 { return "Array"; };
  if tag == 6 { return "Object"; };
  if tag == 7 { return "Function"; };
  if tag == 8 { return "Error"; };
  __type_of(v);
};
let __check_value = (value, ty) -> {
  if !__is_type_value(ty) { return __err("TypeCheck", "type annotation is not a type value"); };
  let result = __call_borrowed(__obj_get(ty, "check"), [value], true)?;
  !!result;
};
let __check_binding = (value, ty, text) -> {
  let passed = __check_value(value, ty)?;
  if passed { return value; };
  let cause = null; if __isError(value) { cause = value; };
  __err_new("TypeCheck", "value of type \"" + __type_name(value) + "\" does not match the annotated type \"" + text + "\"", cause);
};
let __call_depth = 0;
// args is borrowed and read-only. Normal callees receive only its elements.
// Modes 4/5/6 consume the wrapper synchronously (partial / Error / Math extrema).
// A new partial must own a copy; no return path may retain the borrowed list.
let __call_borrowed = (fn, args, exempt) -> {
  if readU64(fn, 0) != 7 { return __err("NotCallable", "Not callable: " + __type_name(fn)); };
  let mode = readU64(fn, 32);
  let count = readU64(args, 16);
  let expected = readU64(fn, 24);
  let name = ql_value_get(fn, 40);
  // The QLang evaluator implements ordinary function rules for this proxy.
  // Own the forwarded list: callback bodies may retain it after this call.
  // Passing exempt separately preserves internal annotation-check semantics.
  if mode == 7 { return __invoke(fn, [__copy_call_args(args), exempt]); };
  if mode != 1 && mode != 3 && mode != 5 && !(exempt && mode == 0) {
    let i = 0;
    while i < count {
      let v = __get_index(args, i);
      if __isError(v) {
        let message = "attempt to pass error value as argument";
        if mode != 0 { message = message + " to " + name; };
        return __err_new("TypeMismatch", message, v);
      };
      i = i + 1;
    };
  };
  if mode == 5 || mode == 6 { return __invoke(fn, [args]); };
  if mode == 0 && count < expected { return __partial(fn, args, expected - count); };
  if count != expected { return __arity_error(expected, count); };
  if mode == 4 { return __invoke(fn, [args]); };
  if mode == 0 {
    let annotations = ql_value_get(fn, 56);
    if readU64(annotations, 0) == 5 {
      let i = 0;
      while i < count {
        let ann = __get_index(annotations, i);
        if ann != null {
          let passed = __check_value(__get_index(args, i), ann[0])?;
          if !passed { return __err("TypeCheck", "argument " + __itoa(i + 1) + " does not match the annotated type \"" + ann[1] + "\""); };
        };
        i = i + 1;
      };
    };
    if __call_depth >= 300 { return __err("StackOverflow", "maximum recursion depth exceeded"); };
    __call_depth = __call_depth + 1;
  };
  let result = __invoke(fn, args);
  if mode == 0 { __call_depth = __call_depth - 1; };
  // Curried standard-library members manufacture internal closures. Expose
  // those as native functions, preserving their arity and error-argument rules.
  if (mode == 2 || mode == 3) && readU64(result, 0) == 7 && readU64(result, 32) == 1 {
    __native(result, name + "<curried>", mode == 3);
  };
  result;
};

// Compatibility for bootstrapping with older emitters that pass owned arrays.
let __call = __call_borrowed;

__native(__call_native, "<native call bridge>", true);
__native(__source_enter, "<diagnostic source enter>", true);
__native(__source_leave, "<diagnostic source leave>", true);
__native(__source_error, "<diagnostic source error>", true);
__native_module(stdString, "String");
__native_module(stdObject, "Object");
__native_module(stdNumber, "Number");
__native_module(stdMath, "Math");
writeU64(__math_max, 32, 6);
writeU64(__math_min, 32, 6);
__native_module(stdJSON, "JSON");
__native_module(stdFs, "fs");
__native_module(stdBytes, "bytes");
__native_module(stdProcess, "process");
__native(__type_make, "Type.make", false);
__native(__type_of_val, "Type.of", true);
__native(__error_raise, "Error.raise", true);
__native(__error_construct, "Error.raise", true);
writeU64(__error_construct, 32, 5);
__native(__error_tostring, "Error.toString", true);
__native(print, "print", true);
__native(println, "println", true);
__native(assert, "assert", false);
__native(isError, "isError", true);
__native(Array, "Array", false);
__native(Object, "Object", false);
__native(__pred_number, "Number", true);
__native(__pred_string, "String", true);
__native(__pred_boolean, "Boolean", true);
__native(__pred_null, "Null", true);
__native(__pred_array, "AnyArray", true);
__native(__pred_object, "AnyObject", true);
__native(__pred_function, "Function", true);
__native(__pred_any, "Any", true);
__native(__pred_never, "Never", true);
__native(__pred_error, "Error", true);
__native(__pred_type, "Type", true);

// Dynamic module policy stays in QLang; the C leaf only loads native symbols.
let __extensions_loading = {};
let __extension_import = (path, origin, hostEnv, abi) -> {
  let checked = __fs_path(path)?;
  if readU64(path, 16) == 0 { return __err("ImportError", "extension path is empty"); };
  let resolved = path;
  if ql_mem_get(ql_mem_get_ptr(path, 8), 0) != 47 {
    let data = ql_mem_get_ptr(origin, 8); let len = readU64(origin, 16); let i = 0; let last = 0;
    while i < len { if ql_mem_get(data, i) == 47 { last = i + 1; }; i = i + 1; };
    resolved = __str_new(data, last) + path;
  };
  resolved = __fs_canonical(resolved)?;
  let flag = __obj_get(__extensions_loading, resolved);
  if readU64(flag, 0) == 3 && flag { return __err("ImportCycle", "cyclic extension import: " + resolved); };
  let name = __fs_path(resolved)?;
  let status = ql_alloc(8); writeU64(status, 0, 0);
  let entry = ql_extension_open(ql_mem_get_ptr(name, 8), abi, status);
  let code = readU64(status, 0);
  if code == 1 { return __err("ImportError", "cannot load native extension: " + resolved); };
  if code == 2 { return __err("ImportABI", "incompatible QLang extension: " + resolved); };
  if code == 3 { return __err("ImportError", "missing QLang extension entry: " + resolved); };
  __obj_set(__extensions_loading, resolved, true);
  let result = __extension_enter(entry, hostEnv);
  __obj_set(__extensions_loading, resolved, false);
  result;
};

// Private embedding hooks used by the QLang AST interpreter. Neither pointers
// nor loader configuration are exposed to interpreted programs.
let __extension_host_env = null;
let __extension_host_abi = null;
let __extension_args_slot = 0;
let __extension_bind_host = (env, abi, argsSlot) -> {
  __extension_host_env = env; __extension_host_abi = abi;
  __extension_args_slot = argsSlot; null;
};
let __extension_bridge_load = (path, origin, arguments) -> {
  if __extension_host_env == null { return __err("NativeExtensionUnavailable", "compiler has not configured the native extension bridge"); };
  // An embedded interpreter has its own process arguments. Copy the runtime
  // frame so module initialization receives those bindings without changing the
  // launching interpreter process. Reference values/closures remain shared.
  let size = 16 + 64 * readU64(__extension_host_env, 8);
  let env = ql_alloc(size); let i = 0;
  while i < size { ql_mem_store(env, i, ql_mem_get(__extension_host_env, i)); i = i + 1; };
  ql_value_store(env, 16 + 64 * __extension_args_slot, arguments);
  __extension_import(path, origin, env, __extension_host_abi);
};
let __extension_bridge_call = (fn, arguments, exempt) -> {
  let previous = __error_source; __error_source = null;
  let result = __call_borrowed(fn, arguments, exempt);
  __error_source = previous; result;
};
let __extension_bridge_callback = (body, name) -> {
  let thunk = (arguments, exempt) -> {
    // Adapter code is an implementation boundary, not a user call frame.
    // Evaluated callback nodes establish their own source scopes inside it.
    let previous = __error_source;
    __error_source = {file: "", line: 0, col: 0};
    let result = body(arguments, exempt);
    __error_source = previous;
    result;
  };
  writeU64(thunk, 32, 7); ql_value_store(thunk, 40, name); thunk;
};
std.__extensions = {load: __extension_bridge_load, call: __extension_bridge_call, callback: __extension_bridge_callback};
