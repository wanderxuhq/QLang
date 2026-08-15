// aot/qlangc.ql — QLang → LLVM IR 编译器(QLang 写,跑在 boot 解释器上)
// host --compile 驱动:boot 解释器执行本文件;args[0] = 源码文本,args[1] = 源路径。
// 输出:纯 IR 文本到 stdout(本文件不 import main.ql,故无 banner)。
// R5:import 路径相对本文件 (aot/) 解析 → 必须指到 ../bootstrapped/*.ql。
import ../bootstrapped/lexer.ql;
import ../bootstrapped/ast.ql;
import ../bootstrapped/parser.ql;

// ---- emit 基础设施 ----
let out = [];
let tmpN = 0;
let lblN = 0;
// R10-c:每函数单独 sink。函数体 emit 期 line() 经 curSink 落到当前函数块(fnBlocks 元素),
// 函数定义收尾后恢复调用方 sink(闭包盒指令回调用方当前块);main 整体先 flush out、再按序
// flush 各 fnBlocks。QLang 数组是引用类型,curSink 保存数组对象即完成重定向。
let fnBlocks = [];
let curSink = out;
let line = (s) -> { curSink[curSink.length] = s; };
let temp = () -> { tmpN = tmpN + 1; "%t" + std.String.toString(tmpN); };
let lbl = () -> { lblN = lblN + 1; "bb" + std.String.toString(lblN); };
let f64lit = (x) -> { if x % 1 == 0 { std.String.toString(x) + ".0"; } else { std.String.toString(x); }; };
// ---- M2 字符串字面量(Task 2)----
// 全局 .rodata 字符串常量 + interned 全局 STRING 盒(tag=2)。strDecls 缓冲在 main 末尾 flush。
let strCounter = 0;             // 字符串盒序号
let strDecls = [];              // 缓冲的全局常量/盒定义(flush 在 main 末尾)
let stringIntern = {};          // 内容 → @.strboxN(跨 runtime.ql+用户源码整个编译单元)

// escapeC:把解码后的字节重编码为 LLVM IR 字符串常量转义(aot/tests/m0_hello.ll 的
// `[3 x i8] c"hi\0A"` 格式;\0A = `\`+大写两位十六进制,**无 NUL 终止**)。
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

// ---- M3 T1 差异项 6:字符串字面量 UTF-8 字节计数 ----
// escapeC 的转义为 3 字符(\0A 等,每转义 = 1 字节),非 ASCII 原样保留。字节数 =
// 5 个转义字符各 1 字节 + 可打印 ASCII 各 1 字节 + 非 ASCII 各 3 字节(本项目
// 实际用到的非 ASCII 为 U+2500~U+2514 框线字符,UTF-8 恒 3 字节)。
let __PRINT_ASCII = " !\"#$%&'()*+,-./0123456789:;<=>?@ABCDEFGHIJKLMNOPQRSTUVWXYZ[\\]^_`abcdefghijklmnopqrstuvwxyz{|}~";
let strByteLen = (s) -> {
  let n = s.length;
  let total = 0;
  let i = 0;
  while i < n {
    let c = s[i];
    if c == "\n" { total = total + 1; }
    else {
      if c == "\t" { total = total + 1; }
      else {
        if c == "\r" { total = total + 1; }
        else {
          if c == "\"" { total = total + 1; }
          else {
            if c == "\\" { total = total + 1; }
            else {
              if std.String.includes(__PRINT_ASCII)(c) { total = total + 1; }
              else { total = total + 3; };
            };
          };
        };
      };
    };
    i = i + 1;
  };
  total;
};

// internString:内容 → 恒同的全局 STRING 盒地址 @.strboxN(跨整个编译单元 intern)。
// STRING 盒布局 {tag@0=2, buf@8, len@16};[LEN x i8] 的 LEN = UTF-8 字节长度(无 NUL)。
let internString = (s) -> {
  let hit = stringIntern[s];
  if isError(hit) || hit == null {
    let n = strCounter;
    strCounter = strCounter + 1;
    let lbl = "@.strbox" + std.String.toString(n);
    stringIntern[s] = lbl;
    let bufLbl = "@.str" + std.String.toString(n);
    let len = strByteLen(s);
    strDecls[strDecls.length] = bufLbl + " = private unnamed_addr constant [" + std.String.toString(len) + " x i8] c\"" + escapeC(s) + "\"";
    strDecls[strDecls.length] = lbl + " = global { i64, ptr, i64 } { i64 2, ptr " + bufLbl + ", i64 " + std.String.toString(len) + " }";
    lbl;
  } else {
    hit;
  };
};

let emitStringLiteral = (node) -> {
  internString(node.value);
};
// R10-c:函数计数,生成 ql_fn<N> 名字。
let funcCounter = 0;

// 分配一个只写了 header tag 的盒(16 字节);payload 由调用方后续 store。
let allocBox = (tag) -> {
  let b = temp();
  line("  " + b + " = call ptr @ql_alloc(i64 16)");
  line("  store i64 " + tag + ", ptr " + b);
  b;
};

// 数字字面量:tag=1(NUMBER),payload = f64
let emitNumber = (node) -> {
  let b = allocBox("1");
  let pay = temp();
  line("  " + pay + " = getelementptr i8, ptr " + b + ", i64 8");
  line("  store double " + f64lit(node.value) + ", ptr " + pay);
  b;
};

// 布尔字面量:tag=3(BOOL),payload = i64 0/1
let emitBoolean = (node) -> {
  let b = allocBox("3");
  let pay = temp();
  line("  " + pay + " = getelementptr i8, ptr " + b + ", i64 8");
  let v = if node.value { "1" } else { "0" };
  line("  store i64 " + v + ", ptr " + pay);
  b;
};

// null 字面量:tag=4(NULL)。返回 interned 全局 16B 盒 {tag=4, payload=0} 地址:
//   [box+8] 恒读 0.0 → null == null(同一盒)fcmp oeq 恒真、null != null 恒假,
//   host 镜像(c22/c23)。地址非零 → 满足红线(空槽哨兵不能是 0 指针)。
let emitNull = () -> {
  "@.nullbox";
};

// && / || 短路 emit(controller 裁定语义 = host interpreter.rs eval_binary_op):
//   && :A 假 → 结果 = A 盒(不 eval B);A 真 → 结果 = B 盒
//   || :A 真 → 结果 = A 盒(不 eval B);A 假 → 结果 = B 盒
// 返回原值盒,不造 false 盒;done 块 phi = [ A, A 所在块 ] + [ B, B 所在块 ] + [ errRes, err 块 ]。
// M3 R2:左操作数为 Error → 操作区截获(host:&&/|| 对错误不短路),结果 = TypeMismatch。
// 每次 @ql_truthy 调用前必须 ptrtoint 桥(Task 4 Deviation #6):@ql_truthy 参数是 i64 地址值。
let emitShortCircuit = (node) -> {
  let op = node.operator;
  let A = emitExpr(node.left);
  // M3 R2:左操作数为 Error → 操作区截获(host:&&/|| 对错误不短路),结果 = TypeMismatch
  let tA = temp(); let eA = temp();
  line("  " + tA + " = load i64, ptr " + A);
  line("  " + eA + " = icmp eq i64 " + tA + ", 8");
  let lErr = lbl(); let lNorm = lbl(); let lDone = lbl();
  line("  br i1 " + eA + ", label %" + lErr + ", label %" + lNorm);
  line(lErr + ":");
  curLbl = lErr;
  let errRes = emitCallRegs("__op_zone_error", [internString("logical operation"), A, emitNull()]);
  let errLbl = curLbl;
  line("  br label %" + lDone);
  line(lNorm + ":");
  curLbl = lNorm;
  let A2 = temp(); let trA = temp();
  line("  " + A2 + " = ptrtoint ptr " + A + " to i64");
  line("  " + trA + " = call i1 @ql_truthy(i64 " + A2 + ")");
  let predA = curLbl;                       // emit A + truthy 所在块 = br 的前驱
  let lEvalB = lbl();
  if op == "&&" {
    line("  br i1 " + trA + ", label %" + lEvalB + ", label %" + lDone);
  } else {
    line("  br i1 " + trA + ", label %" + lDone + ", label %" + lEvalB);
  };
  line(lEvalB + ":");
  curLbl = lEvalB;
  let B = emitExpr(node.right);
  // Critical fix (Fix Round 1):B 自身若是短路,emit 会再产 evalB/done 块并把 curLbl
  // 设为其 done 块 → 外层 br label %lDone 实际从 B 的 done 块发出,phi 前驱必须记
  // curLbl 而非硬编码 lEvalB(否则 "PHI node entries do not match predecessors!",clang 拒绝)。
  let predB = curLbl;
  line("  br label %" + lDone);
  line(lDone + ":");
  curLbl = lDone;
  let res = temp();
  line("  " + res + " = phi ptr [ " + A + ", %" + predA + " ], [ " + B + ", %" + predB + " ], [ " + errRes + ", %" + errLbl + " ]");
  res;
};

// 数值路径(内联):仅当调用方已确认左右 tag 均 == 1(NUMBER)。除零检查内联。
// 位运算:差异项 3 —— fptosi → and/or/xor → sitofp(与算术同构)。
let emitNumOp = (op, L, R) -> {
  let a1 = temp(); let f1 = temp(); let a2 = temp(); let f2 = temp();
  line("  " + a1 + " = getelementptr i8, ptr " + L + ", i64 8");
  line("  " + f1 + " = load double, ptr " + a1);
  line("  " + a2 + " = getelementptr i8, ptr " + R + ", i64 8");
  line("  " + f2 + " = load double, ptr " + a2);
  if op == "+" || op == "-" || op == "*" {
    let rr = temp();
    let fop = if op == "+" { "fadd" } else if op == "-" { "fsub" } else { "fmul" };
    line("  " + rr + " = " + fop + " double " + f1 + ", " + f2);
    let b = allocBox("1");
    let bpay = temp();
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  store double " + rr + ", ptr " + bpay);
    b;
  } else if op == "/" || op == "%" {
    // 除零检查:R == 0.0 → __op_div0(造 DivisionByZero 错误)
    let z = temp(); let l0 = lbl(); let lOk = lbl(); let lEnd = lbl();
    line("  " + z + " = fcmp oeq double " + f2 + ", 0.0");
    line("  br i1 " + z + ", label %" + l0 + ", label %" + lOk);
    line(lOk + ":");
    curLbl = lOk;
    let rr = temp();
    if op == "%" {
      // a - b*trunc(a/b)(M2 内联,frem 降级规避)
      let q = temp(); let qi = temp(); let qf = temp(); let m = temp();
      line("  " + q + " = fdiv double " + f1 + ", " + f2);
      line("  " + qi + " = fptosi double " + q + " to i64");
      line("  " + qf + " = sitofp i64 " + qi + " to double");
      line("  " + m + " = fmul double " + f2 + ", " + qf);
      line("  " + rr + " = fsub double " + f1 + ", " + m);
    } else {
      line("  " + rr + " = fdiv double " + f1 + ", " + f2);
    };
    let b = allocBox("1");
    let bpay = temp();
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  store double " + rr + ", ptr " + bpay);
    let okLbl = curLbl;
    line("  br label %" + lEnd);
    line(l0 + ":");
    curLbl = l0;
    let errV = emitCallRegs("__op_div0", []);
    let zeroLbl = curLbl;
    line("  br label %" + lEnd);
    line(lEnd + ":");
    curLbl = lEnd;
    let res = temp();
    line("  " + res + " = phi ptr [ " + b + ", %" + okLbl + " ], [ " + errV + ", %" + zeroLbl + " ]");
    res;
  } else if op == "==" || op == "!=" || op == "<" || op == "<=" || op == ">" || op == ">=" {
    let cmp = if op == "==" { "oeq" } else if op == "!=" { "une" } else if op == "<" { "olt" } else if op == "<=" { "ole" } else if op == ">" { "ogt" } else { "oge" };
    let c = temp(); let c2 = temp();
    line("  " + c + " = fcmp " + cmp + " double " + f1 + ", " + f2);
    line("  " + c2 + " = zext i1 " + c + " to i64");
    let b = allocBox("3");
    let bpay = temp();
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  store i64 " + c2 + ", ptr " + bpay);
    b;
  } else {
    // 位运算 & | ^(差异项 3):fptosi → and/or/xor → sitofp
    let op2 = if op == "&" { "and" } else if op == "|" { "or" } else { "xor" };
    let i1 = temp(); let i2 = temp(); let ir = temp();
    line("  " + i1 + " = fptosi double " + f1 + " to i64");
    line("  " + i2 + " = fptosi double " + f2 + " to i64");
    line("  " + ir + " = " + op2 + " i64 " + i1 + ", " + i2);
    let fr = temp();
    line("  " + fr + " = sitofp i64 " + ir + " to double");
    let b = allocBox("1");
    let bpay = temp();
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  store double " + fr + ", ptr " + bpay);
    b;
  };
};

// 非数值派发路径:每 op 有至多一个合法非数值组合(+ STR 拼接;== / != tag 感知),其余 TypeMismatch。
let emitDispOp = (op, L, R) -> {
  if op == "+" {
    emitCallRegs("__op_add", [L, R]);
  } else if op == "==" {
    emitCallRegs("__op_eq", [L, R]);
  } else if op == "!=" {
    emitCallRegs("__op_ne", [L, R]);
  } else {
    let word = if op == "-" || op == "*" || op == "/" || op == "%" {
      "numeric operation"
    } else if op == "<" || op == "<=" || op == ">" || op == ">=" {
      "comparison"
    } else {
      "bitwise operation"
    };
    emitCallRegs("__op_zone_error", [internString(word), L, R]);
  };
};

// ?? 空值合并:T9 实现真实逻辑;T2 先以 stub 占位,保证 qlangc 解析不崩。
let emitCoalesce = (node) -> {
  line("; T2 stub: coalesce");
  emitNull();
};

// 二元运算:M3 R1 双路径 —— 静态两侧均为 Number 字面量 → 内联 emitNumOp;否则运行期
// tag 检查,双 NUMBER → 内联数值路径,否则按 op 派发 __op_add/__op_eq/__op_ne/__op_zone_error。
// && / || 不走这里 —— 先在顶部截获走 emitShortCircuit(短路,避免无条件先求值右操作数)。
let emitBinaryOp = (node) -> {
  if node.operator == "&&" || node.operator == "||" {
    emitShortCircuit(node);
  } else if node.operator == "??" {
    emitCoalesce(node);        // T9 定义;T2 内先留 stub(见 Step 4)
  } else {
    let op = node.operator;
    let bothNum = node.left.type == "Number" && node.right.type == "Number";
    let isDivMod = op == "/" || op == "%";
    if bothNum && !isDivMod {
      let L = emitExpr(node.left);
      let R = emitExpr(node.right);
      emitNumOp(op, L, R);
    } else {
      let L = emitExpr(node.left);
      let R = emitExpr(node.right);
      let t1 = temp(); let t2 = temp(); let c1 = temp(); let c2 = temp(); let c3 = temp();
      line("  " + t1 + " = load i64, ptr " + L);
      line("  " + t2 + " = load i64, ptr " + R);
      line("  " + c1 + " = icmp eq i64 " + t1 + ", 1");
      line("  " + c2 + " = icmp eq i64 " + t2 + ", 1");
      line("  " + c3 + " = and i1 " + c1 + ", " + c2);
      let lNum = lbl(); let lDisp = lbl(); let lMerge = lbl();
      line("  br i1 " + c3 + ", label %" + lNum + ", label %" + lDisp);
      line(lNum + ":");
      curLbl = lNum;
      let numRes = emitNumOp(op, L, R);
      let numLbl = curLbl;
      line("  br label %" + lMerge);
      line(lDisp + ":");
      curLbl = lDisp;
      let dispRes = emitDispOp(op, L, R);
      let dispLbl = curLbl;
      line("  br label %" + lMerge);
      line(lMerge + ":");
      curLbl = lMerge;
      let res = temp();
      line("  " + res + " = phi ptr [ " + numRes + ", %" + numLbl + " ], [ " + dispRes + ", %" + dispLbl + " ]");
      res;
    };
  };
};

// 一元运算:`?` → Error 折回函数 epilogue(顶层 __exit_error + unreachable);- → fneg 新 NUMBER 盒;
// ! → @ql_truthy 反转后存 BOOL 盒。
let emitUnaryOp = (node) -> {
  let O = emitExpr(node.operand);
  if node.operator == "?" {
    // M3 T3 Propagate:operand 为 Error → 折回函数返回(或顶层 __exit_error);否则原值继续
    let tO = temp(); let eO = temp();
    line("  " + tO + " = load i64, ptr " + O);
    line("  " + eO + " = icmp eq i64 " + tO + ", 8");
    let lProp = lbl(); let lOk = lbl();
    line("  br i1 " + eO + ", label %" + lProp + ", label %" + lOk);
    line(lProp + ":");
    curLbl = lProp;
    if isTopLevel {
      emitCallRegs("__exit_error", [O]);
      line("  unreachable");
    } else {
      line("  store ptr " + O + ", ptr " + curRetv);
      line("  br label %" + curEpiLbl);
    };
    line(lOk + ":");
    curLbl = lOk;
    O;
  } else if node.operator == "-" {
    let a = temp(); let f = temp(); let n = temp();
    line("  " + a + " = getelementptr i8, ptr " + O + ", i64 8");
    line("  " + f + " = load double, ptr " + a);
    line("  " + n + " = fneg double " + f);
    let b = allocBox("1");
    let bpay = temp();
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  store double " + n + ", ptr " + bpay);
    b;
  } else if node.operator == "!" {
    // R3:`!` 的 zext 临时名必须用 temp(),不可硬编码 %z0(否则 `!` 出现两次即重复定义)。
    let O2 = temp();
    let tr = temp(); let inv = temp(); let z = temp();
    line("  " + O2 + " = ptrtoint ptr " + O + " to i64");
    line("  " + tr + " = call i1 @ql_truthy(i64 " + O2 + ")");
    line("  " + inv + " = xor i1 " + tr + ", true");
    let b = allocBox("3");
    let bpay = temp();
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  " + z + " = zext i1 " + inv + " to i64");
    line("  store i64 " + z + ", ptr " + bpay);
    b;
  } else {
    O;
  };
};

// ---- 编译期作用域模型(Task 5)----
// 运行期环境 = 链式帧 {parent: ptr, slots: [ptr]}(spec「let 绑定当前帧新槽」),编译期用 QLang
// 对象链镜像:scope = { slots: {name → slotIndex}, parent: scope|null }。帧/槽一律 ptr 型(R9)。
let globalScope = { slots: {}, parent: null };
let curScope = globalScope;
// scopePush:进入新函数时挂到当前作用域下(Task 6+ 函数 emit 用;v1 顶层只有 globalScope)。
let scopePush = (parent) -> { curScope = { slots: {}, parent: parent }; };
// defineSlot:slots 现有键数即新 slot 索引(std.Object.keys 在 bootstrapped/stdlib.ql 可用,已实测)。
// R10-i/幂等:若名字已在本作用域定义则返回既有 slot(不重定义)—— 这修复 Task 5 Minor-5b
// (同作用域重复 let 的孤儿槽),也是「函数预扫(defineSlot)后函数体 emit 中再对同一名字按
// 已绑定处理(emitStoreByName)」能拿到同一槽号的前提。Task 7 顶层函数递归:`let F=<Function>`
// 必须 defineSlot(F) 先于 emitExpr(Function),否则函数体里的 F 按未绑定处理。
let defineSlot = (name) -> {
  let existing = curScope.slots[name];
  if !isError(existing) && existing != null {
    existing;
  } else {
    let n = std.Object.keys(curScope.slots).length;
    curScope.slots[name] = n;
    n;
  };
};
// lookupSlot:返回 {depth, slot} 或 null。R8 累加器形态 —— QLang 的 while 是语句,body 值不回流,
// brief 草图(while 内 if 表达式直接产 {depth, slot})命中后 s 不再更新,会无限循环。
let lookupSlot = (name) -> {
  let d = 0;
  let s = curScope;
  let hit = null;
  while s != null && hit == null {
    let v = s.slots[name];
    if !isError(v) && v != null { hit = { depth: d, slot: v }; }
    else { s = s.parent; d = d + 1; };
  };
  hit;
};
// R9/R1:当前函数入口 env 寄存器名(main = 全局帧寄存器);不硬编码 "env0" 字面量。
let curEnv = "";
// 当前正在 emit 的基本块标签(短路 phi 需记录「emit A + truthy 所在块」作前驱;main 入口、
// if/while 各块、短路各块处都要更新 —— 否则短路出现在非 entry 块时 phi 前驱写错)。
let curLbl = "";
// M3 T3:`?` 的传播目标 = 当前函数 epilogue(%retv alloca + %epilogue label)。
// 顶层(isTopLevel)无 epilogue → `?` 走 __exit_error + unreachable。
let curRetv = "";       // 当前函数 %retv 寄存器名
let curEpiLbl = "";     // 当前函数 epilogue label 名
let isTopLevel = true;  // main 顶层 ? → __exit_error

// 表达式位置的标识符:沿当前帧 parent 链走 depth 步,读目标帧 slot(帧/槽全 ptr 型)。
let emitIdentifier = (node) -> {
  let hit = lookupSlot(node.name);
  if hit == null {
    // 未绑定名字:报错注释 + 合法 NULL 盒,保证 IR 有效(任务裁定的 fallback)。
    line("; error: undefined " + node.name);
    emitNull();
  } else {
    let cur = curEnv;
    let d = 0;
    while d < hit.depth {
      let p = temp();
      line("  " + p + " = load ptr, ptr " + cur);
      cur = p;
      d = d + 1;
    };
    let off = temp(); let v = temp();
    line("  " + off + " = getelementptr i8, ptr " + cur + ", i64 " + std.String.toString(16 + 8 * hit.slot));
    line("  " + v + " = load ptr, ptr " + off);
    v;
  };
};

// 顶层 let:绑定到当前帧新槽(R9 Design 2 —— 不造新帧)。返回 slot 编号(编译期用,不产 IR 值)。
let emitLetStmt = (node) -> {
  if !isError(node.annotation) && node.annotation != null {
    line("; annotation ignored (v1)");
  };
  // R10-i:`let F = <Function>` 必须 defineSlot(F) 先于 emitExpr —— 函数体 emit 期间 F
  // 已在当前作用域(顶层 → globalScope),函数体内沿 parent 链 depth 1 命中,递归成立
  // (host 语义证明:共享 env 捕获,fact(5)→120)。非函数值保持旧序(先求值后定义)。
  let slot = null;
  if node.value.type == "Function" {
    slot = defineSlot(node.name);
  };
  let V = emitExpr(node.value);
  if slot == null {
    slot = defineSlot(node.name);
  };
  let off = temp();
  line("  " + off + " = getelementptr i8, ptr " + curEnv + ", i64 " + std.String.toString(16 + 8 * slot));
  line("  store ptr " + V + ", ptr " + off);
  slot;
};

// 按名字求值 value 并写入目标槽(assign 与「分支内已绑定 let 按 assign 处理」共用)。
// 未命中 → 注释 + 不求值 value。
let emitStoreByName = (name, value) -> {
  let hit = lookupSlot(name);
  if hit == null {
    line("; error: assign to undefined " + name);
  } else {
    let V = emitExpr(value);
    let cur = curEnv;
    let d = 0;
    while d < hit.depth {
      let p = temp();
      line("  " + p + " = load ptr, ptr " + cur);
      cur = p;
      d = d + 1;
    };
    let off = temp();
    line("  " + off + " = getelementptr i8, ptr " + cur + ", i64 " + std.String.toString(16 + 8 * hit.slot));
    line("  store ptr " + V + ", ptr " + off);
  };
};

// assign:沿链找目标帧 slot 写(R9 帧/槽全 ptr 型)。
// M2 arr:IndexAccess 目标 → 数组元素写(__set_index);其余目标走旧 emitStoreByName。
let emitAssignStmt = (node) -> {
  if node.target.type == "IndexAccess" {
    let O = emitExpr(node.target.object);
    let I = emitExpr(node.target.index);
    let V = emitExpr(node.value);
    emitCallRegs("__set_index", [O, I, V]);
  } else if node.target.type == "MemberAccess" {
    let O = emitExpr(node.target.object);
    let V = emitExpr(node.value);
    let key = internString(node.target.field);
    emitCallRegs("__set_field", [O, key, V]);
  } else {
    emitStoreByName(node.target.name, node.value);
  };
};

// ---- 函数/闭包 emit(Task 7,R10-a/b/c/i) ----
// 函数 = 闭包盒(tag 7 @0、code fnptr @8、env ptr @16)+ 独立 LLVM 函数 ql_fn<N>。
// ABI(R10-b):define ptr @ql_fn<N>(ptr %env, ptr %args, i64 %argc)。%env = 定义时刻环境帧
// (闭包捕获);%args = ptr 元素数组;返回盒值(恒有值,默认 NULL 盒)。
// 函数帧(Design 2):call ptr @ql_alloc(i64 16+8*n) → parent@0,n_slots@8,slots@16+8*a。
// R10-c:函数体写独立 fnBlocks 元素;闭包盒指令写回调用方当前块。R10-i:调用方必须先
// defineSlot(name)(emitLetStmt 的 Function 分支负责),函数体里同名标识符沿 parent 链
// depth 1 命中全局帧 → 递归成立。
let emitFunction = (node, name) -> {
  let fname = "ql_fn" + std.String.toString(funcCounter);
  funcCounter = funcCounter + 1;
  let savedScope = curScope;
  let savedEnv = curEnv;
  let savedLbl = curLbl;
  let savedSink = curSink;
  // 函数体作用域 = 新空作用域,parent = 定义处作用域(闭包环境链的编译期镜像)。
  curScope = { slots: {}, parent: savedScope };
  // 预扫:参数槽 0..k-1,函数体顶层 let 槽 k..n-1(幂等 defineSlot → 函数体 emit 对同一
  // 名字按已绑定走 emitStoreByName,槽号一致)。
  let k = node.parameters.length;
  let p = 0;
  while p < k {
    defineSlot(node.parameters[p].name);
    p = p + 1;
  };
  let st = 0;
  while st < node.body.statements.length {
    let s = node.body.statements[st];
    if s.type == "Let" { defineSlot(s.name); };
    st = st + 1;
  };
  let n = std.Object.keys(curScope.slots).length;
  let blk = [];
  curSink = blk;
  line("define ptr @" + fname + "(ptr %env, ptr %args, i64 %argc) {");
  line("entry:");
  curLbl = "entry";
  let f = temp();
  line("  " + f + " = call ptr @ql_alloc(i64 " + std.String.toString(16 + 8 * n) + ")");
  line("  store ptr %env, ptr " + f);                          // parent = 闭包捕获 env
  let no = temp();
  line("  " + no + " = getelementptr i8, ptr " + f + ", i64 8");
  line("  store i64 " + std.String.toString(n) + ", ptr " + no);   // n_slots
  curEnv = f;
  let a = 0;
  while a < k {
    let ro = temp(); let rv = temp();
    line("  " + ro + " = getelementptr ptr, ptr %args, i64 " + std.String.toString(a));
    line("  " + rv + " = load ptr, ptr " + ro);
    let off = temp();
    line("  " + off + " = getelementptr i8, ptr " + f + ", i64 " + std.String.toString(16 + 8 * a));
    line("  store ptr " + rv + ", ptr " + off);
    a = a + 1;
  };
  // M3 T3:epilogue —— %retv alloca 在 entry 分配;body 末 store + br;? 的 prop 分支同样 store 后 br。
  let rv = temp();
  line("  " + rv + " = alloca ptr");
  let lEpi = lbl();
  let savedRetv = curRetv; let savedEpi = curEpiLbl; let savedTop = isTopLevel;
  curRetv = rv; curEpiLbl = lEpi; isTopLevel = false;
  // 函数体:R10-a 语句级 last-value 语义 —— emitBlockStmts 返回最后值寄存器;函数结果 =
  // 函数体最后值(恒有值,默认 NULL 盒)。
  let bodyLast = emitBlockStmts(node.body.statements);
  let bl = bodyLast;
  if bl == null {
    bl = emitNull();
  };
  line("  store ptr " + bl + ", ptr " + rv);
  line("  br label %" + lEpi);
  line(lEpi + ":");
  let rv2 = temp();
  line("  " + rv2 + " = load ptr, ptr " + rv);
  line("  ret ptr " + rv2);
  line("}");
  curRetv = savedRetv; curEpiLbl = savedEpi; isTopLevel = savedTop;
  fnBlocks[fnBlocks.length] = blk;
  // 恢复调用方上下文;闭包盒指令写回调用方当前块/当前 sink。
  curSink = savedSink;
  curScope = savedScope;
  curEnv = savedEnv;
  curLbl = savedLbl;
  // 闭包盒:tag 7 @0、code @8、env @16(定义时刻环境帧)。
  let c = temp();
  line("  " + c + " = call ptr @ql_alloc(i64 24)");
  line("  store i64 7, ptr " + c);
  let cp = temp();
  line("  " + cp + " = getelementptr i8, ptr " + c + ", i64 8");
  line("  store ptr @" + fname + ", ptr " + cp);
  let ep = temp();
  line("  " + ep + " = getelementptr i8, ptr " + c + ", i64 16");
  line("  store ptr " + savedEnv + ", ptr " + ep);
  c;
};

// ---- 控制流语句 emit(Task 6 + Task 7 语句级 last-value)----
// 语句分派(Let 之外的所有语句类型):顶层与分支块共用;返回该语句产生的「最后值」寄存器
// (R10-a):Assign/While → null(不改 last);If → 所走分支体最后值的 phi(见 emitIfStmt);
// 裸表达式语句/Call → emitExpr 结果。prevLast = 本块此前语句的最后值寄存器(或 null),
// 传给 emitIfStmt 用于「无 else 且条件假 → 不改 last」的 phi 路径。
// R10-e:print/println 特例已删 —— 走 emitCall 通用用户函数调用(runtime.ql 顶层函数)。
let emitStmtDispatch = (node, prevLast) -> {
  if node.type == "Assign" {
    emitAssignStmt(node);
    null;
  } else if node.type == "If" {
    emitIfStmt(node, prevLast);
  } else if node.type == "While" {
    emitWhileStmt(node);
    null;
  } else {
    // 表达式语句(Call/BinaryOp/Identifier 等):求值,返回值作为本块 last。
    emitExpr(node);
  };
};

// 分支块语句遍历:复用 emitStmtDispatch;仅 Let 特判 —— 新名字报不支持(不求值 value),
// 已在当前函数帧( lookupSlot 命中)按 assign 处理(emitStoreByName)。绝不对分支内 let 调
// defineSlot/emitLetStmt:main 帧已按顶层 K 预分配,defineSlot 会得越界 slot → 写到帧外(UB)。
// 返回:块内最后值寄存器(R10-a:Let/Assign/While 不改 last;裸表达式/If 更新),无则 null。
let emitBlockStmts = (stmts) -> {
  let last = null;
  let i = 0;
  while i < stmts.length {
    let s = stmts[i];
    if s.type == "Let" {
      let hit = lookupSlot(s.name);
      if hit == null {
        line("; v1: branch-level let unsupported: " + s.name);
      } else {
        emitStoreByName(s.name, s.value);
      };
    } else {
      let v = emitStmtDispatch(s, last);
      if v != null { last = v; };
    };
    i = i + 1;
  };
  last;
};

// If:实测形状 {type:"If", branches:[IfBranch], elseBody};IfBranch = {condition, body:Block}。
// v1 只处理 branches[0](无 else-if);elseBody 可能为 null。@ql_truthy 前必 ptrtoint 桥。
// R10-a:返回「所走分支体最后值」的 phi 寄存器 —— 空/全 let 分支 → 沿用 prevLast(不改 last),
// prevLast 也无 → NULL 盒(空块 last = Void/NULL);无 else + 条件假 → phi 取 prevLast(= 不改)。
// phi 前驱用 curLbl(emit 分支体后 br label %lEnd 的实际发出块)而非硬编码 lThen/lElse:
// 分支体内嵌套 if/while 会再产块,硬编码前驱将得 "PHI node entries do not match predecessors!"
// (Task 6 Fix Round 1 同类问题的推广)。
let emitIfStmt = (node, prevLast) -> {
  if node.branches.length > 1 {
    line("; v1: else-if branches ignored (only branches[0] handled)");
  };
  let br = node.branches[0];
  let C = emitExpr(br.condition);
  let C2 = temp(); let tr = temp();
  line("  " + C2 + " = ptrtoint ptr " + C + " to i64");
  line("  " + tr + " = call i1 @ql_truthy(i64 " + C2 + ")");
  let lThen = lbl(); let lElse = lbl(); let lEnd = lbl();
  line("  br i1 " + tr + ", label %" + lThen + ", label %" + lElse);
  line(lThen + ":");
  curLbl = lThen;
  let tv = emitBlockStmts(br.body.statements);
  let thenIn = tv;
  if thenIn == null {
    if prevLast != null { thenIn = prevLast; }
    else { thenIn = emitNull(); };
  };
  let thenLbl = curLbl;
  line("  br label %" + lEnd);
  line(lElse + ":");
  curLbl = lElse;
  let ev = null;
  if node.elseBody != null {
    ev = emitBlockStmts(node.elseBody.statements);
  };
  let elseIn = ev;
  if elseIn == null {
    if prevLast != null { elseIn = prevLast; }
    else { elseIn = emitNull(); };
  };
  let elseLbl = curLbl;
  line("  br label %" + lEnd);
  line(lEnd + ":");
  curLbl = lEnd;
  let res = temp();
  line("  " + res + " = phi ptr [ " + thenIn + ", %" + thenLbl + " ], [ " + elseIn + ", %" + elseLbl + " ]");
  res;
};

// While:实测形状 {type:"While", condition, body:Block}。
let emitWhileStmt = (node) -> {
  let lCond = lbl(); let lBody = lbl(); let lExit = lbl();
  line("  br label %" + lCond);
  line(lCond + ":");
  curLbl = lCond;
  let C = emitExpr(node.condition);
  let C2 = temp(); let tr = temp();
  line("  " + C2 + " = ptrtoint ptr " + C + " to i64");
  line("  " + tr + " = call i1 @ql_truthy(i64 " + C2 + ")");
  line("  br i1 " + tr + ", label %" + lBody + ", label %" + lExit);
  line(lBody + ":");
  curLbl = lBody;
  emitBlockStmts(node.body.statements);
  line("  br label %" + lCond);
  line(lExit + ":");
  curLbl = lExit;
};

// 盒值 → iN 整数(解盒 f64 → fptosi i64 → 可选 trunc)。叶子参数的位置型强转(R10-g):
// runtime.ql 纪律 —— 数字位(size/off/len/byte)传盒值,指针位(p/buf)传 raw ptr,故按位置强制。
let boxToInt = (reg, w) -> {
  let pa = temp(); let fv = temp(); let iv = temp();
  line("  " + pa + " = getelementptr i8, ptr " + reg + ", i64 8");
  line("  " + fv + " = load double, ptr " + pa);
  line("  " + iv + " = fptosi double " + fv + " to i64");
  if w == "i32" {
    let t = temp();
    line("  " + t + " = trunc i64 " + iv + " to i32");
    t;
  } else if w == "i8" {
    let t = temp();
    line("  " + t + " = trunc i64 " + iv + " to i8");
    t;
  } else {
    iv;
  };
};

// 表达式位置的 Call(R10-g):
// 1) 叶子表 {ql_alloc, ql_write, ql_mem_get, ql_mem_store} → 直接 call,位置型强转:
//    ql_alloc(i64 size)→raw ptr;ql_write(i32 fd, ptr buf, i64 len)→void;ql_mem_get(ptr, i64)→i8
//    再打包 NUMBER 盒;ql_mem_store(ptr, i64, i8)→void。raw ptr(ql_alloc 返回值/对象 buf 字段)与
//    盒值统一以 ptr 寄存器流动,强转只发生在叶子边界。
// 2) 其余 Identifier/MemberAccess → 通用用户函数调用 ABI(R10-b):FN=emitExpr(callee);
//    参数数组 = call ptr @ql_alloc(i64 8*n) + GEP+store 每参数(盒或 raw ptr 一律 ptr 型);
//    load 闭包盒 code(+8)/env(+16);call ptr %code(ptr %env, ptr %arr, i64 n)。返回 = call 结果盒。
// 3) 未解析(callee 非 Identifier/MemberAccess)→ 注释 + NULL 盒。
// emitCallRegs(fname, argRegs):给定 callee 名与已计算的参数寄存器,构造 args 数组并调用。
// runtime.ql 函数是顶层 let → 全局帧槽 → emitIdentifier(fname) 解析成功。
let emitCallRegs = (fname, argRegs) -> {
  // NOTE(deviation from brief): emitIdentifier 现签名取 Identifier 节点(读 node.name),
  // 直接传字符串会访问 "str".name → host Error → lookupSlot miss → nullbox(运行期 call null 崩溃)。
  // 构造节点保持 brief 其余部分逐字不变。Task 7/8 复用同一 emitCallRegs(fname 字符串)调用形式。
  let FN = emitIdentifier({ type: "Identifier", name: fname });
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

let emitCall = (node) -> {
  let calleeIsId = node.callee.type == "Identifier";
  let cname = if calleeIsId { node.callee.name } else { "" };
  // M3 R15:错误实参传播只对纯 Identifier 的用户函数。runtime.ql 全部内部函数(__ 前缀 +
  // readU64/writeU64/allocBox/print/println)接受错误值/原始缓冲(host accepts_errors 镜像;
  // 且 readU64(err,0) 必须能读 tag —— 否则 __op_eq/__isError 对错误值无限递归),豁免;
  // MemberAccess callee 不走检查。
  let errAccepting = cname == "print" || cname == "println" || cname == "readU64" || cname == "writeU64" || cname == "allocBox" || (cname.length >= 2 && cname[0] == "_" && cname[1] == "_");
  let isLeaf = calleeIsId && (cname == "ql_alloc" || cname == "ql_write" || cname == "ql_mem_get" || cname == "ql_mem_store" || cname == "ql_mem_get_ptr" || cname == "ql_mem_store_ptr" || cname == "ql_exit");
  if isLeaf {
    if cname == "ql_alloc" {
      let size = boxToInt(emitExpr(node.arguments[0]), "i64");
      let r = temp();
      line("  " + r + " = call ptr @ql_alloc(i64 " + size + ")");
      r;
    } else if cname == "ql_write" {
      let fd = boxToInt(emitExpr(node.arguments[0]), "i32");
      let buf = emitExpr(node.arguments[1]);      // raw ptr,直接传
      let len = boxToInt(emitExpr(node.arguments[2]), "i64");
      line("  call void @ql_write(i32 " + fd + ", ptr " + buf + ", i64 " + len + ")");
      emitNull();
    } else if cname == "ql_mem_get" {
      let p = emitExpr(node.arguments[0]);        // raw ptr,直接传
      let off = boxToInt(emitExpr(node.arguments[1]), "i64");
      let b = temp();
      line("  " + b + " = call i8 @ql_mem_get(ptr " + p + ", i64 " + off + ")");
      // i8 → NUMBER 盒(f64)
      let box = allocBox("1");
      let bv = temp();
      line("  " + bv + " = uitofp i8 " + b + " to double");
      let pay = temp();
      line("  " + pay + " = getelementptr i8, ptr " + box + ", i64 8");
      line("  store double " + bv + ", ptr " + pay);
      box;
    } else if cname == "ql_mem_store" {
      let p = emitExpr(node.arguments[0]);        // raw ptr,直接传
      let off = boxToInt(emitExpr(node.arguments[1]), "i64");
      let v = boxToInt(emitExpr(node.arguments[2]), "i8");
      line("  call void @ql_mem_store(ptr " + p + ", i64 " + off + ", i8 " + v + ")");
      emitNull();
    } else if cname == "ql_mem_get_ptr" {
      let p = emitExpr(node.arguments[0]);        // raw ptr,直接传
      let off = boxToInt(emitExpr(node.arguments[1]), "i64");
      let r = temp();
      line("  " + r + " = call ptr @ql_mem_get_ptr(ptr " + p + ", i64 " + off + ")");
      r;
    } else if cname == "ql_mem_store_ptr" {
      let p = emitExpr(node.arguments[0]);        // raw ptr,直接传
      let off = boxToInt(emitExpr(node.arguments[1]), "i64");
      let v = emitExpr(node.arguments[2]);        // raw ptr,直接传
      line("  call void @ql_mem_store_ptr(ptr " + p + ", i64 " + off + ", ptr " + v + ")");
      emitNull();
    } else if cname == "ql_exit" {
      let code = boxToInt(emitExpr(node.arguments[0]), "i32");
      line("  call void @ql_exit(i32 " + code + ")");
      emitNull();
    };
  } else if node.callee.type == "MemberAccess" && node.callee.field == "add" && node.arguments.length >= 1 {
    let O = emitExpr(node.callee.object);
    let V = emitExpr(node.arguments[0]);
    emitCallRegs("__arr_add", [O, V]);
  } else if node.callee.type == "MemberAccess" && node.callee.field == "remove" && node.arguments.length >= 1 {
    let O = emitExpr(node.callee.object);
    let I = emitExpr(node.arguments[0]);
    emitCallRegs("__arr_remove", [O, I]);
  } else if calleeIsId && !errAccepting {
    // M3 R15:用户函数(纯 Identifier callee)实参为 Error → 该错误成为调用结果(不进入 callee)。
    let FN = emitExpr(node.callee);
    let narg = node.arguments.length;
    let lAllDone = lbl();
    let argRegs = [];
    let errRegs = [];
    let errBlks = [];
    let i = 0;
    while i < narg {
      let v = emitExpr(node.arguments[i]);
      let t = temp(); let e = temp();
      line("  " + t + " = load i64, ptr " + v);
      line("  " + e + " = icmp eq i64 " + t + ", 8");
      let lNext = lbl(); let lErr = lbl();
      line("  br i1 " + e + ", label %" + lErr + ", label %" + lNext);
      line(lErr + ":");
      curLbl = lErr;
      errRegs[errRegs.length] = v;
      errBlks[errBlks.length] = curLbl;
      line("  br label %" + lAllDone);
      line(lNext + ":");
      curLbl = lNext;
      argRegs[argRegs.length] = v;
      i = i + 1;
    };
    let arr = temp();
    line("  " + arr + " = call ptr @ql_alloc(i64 " + std.String.toString(8 * narg) + ")");
    let j = 0;
    while j < narg {
      let aoff = temp();
      line("  " + aoff + " = getelementptr ptr, ptr " + arr + ", i64 " + std.String.toString(j));
      line("  store ptr " + argRegs[j] + ", ptr " + aoff);
      j = j + 1;
    };
    let codep = temp(); let codev = temp();
    line("  " + codep + " = getelementptr i8, ptr " + FN + ", i64 8");
    line("  " + codev + " = load ptr, ptr " + codep);
    let envp = temp(); let envv = temp();
    line("  " + envp + " = getelementptr i8, ptr " + FN + ", i64 16");
    line("  " + envv + " = load ptr, ptr " + envp);
    let r = temp();
    line("  " + r + " = call ptr " + codev + "(ptr " + envv + ", ptr " + arr + ", i64 " + std.String.toString(narg) + ")");
    let cleanBlk = curLbl;
    line("  br label %" + lAllDone);
    line(lAllDone + ":");
    curLbl = lAllDone;
    let res = temp();
    let ph = "  " + res + " = phi ptr [ " + r + ", %" + cleanBlk + " ]";
    let e2 = 0;
    while e2 < errBlks.length {
      ph = ph + ", [ " + errRegs[e2] + ", %" + errBlks[e2] + " ]";
      e2 = e2 + 1;
    };
    line(ph);
    res;
  } else if calleeIsId || node.callee.type == "MemberAccess" {
    // M3 R15:MemberAccess callee(std.* / 实例方法)与 error-accepting 运行时函数不走错误实参检查。
    let FN = emitExpr(node.callee);
    let narg = node.arguments.length;
    let arr = temp();
    line("  " + arr + " = call ptr @ql_alloc(i64 " + std.String.toString(8 * narg) + ")");
    let i = 0;
    while i < narg {
      let v = emitExpr(node.arguments[i]);
      let aoff = temp();
      line("  " + aoff + " = getelementptr ptr, ptr " + arr + ", i64 " + std.String.toString(i));
      line("  store ptr " + v + ", ptr " + aoff);
      i = i + 1;
    };
    let codep = temp(); let codev = temp();
    line("  " + codep + " = getelementptr i8, ptr " + FN + ", i64 8");
    line("  " + codev + " = load ptr, ptr " + codep);
    let envp = temp(); let envv = temp();
    line("  " + envp + " = getelementptr i8, ptr " + FN + ", i64 16");
    line("  " + envv + " = load ptr, ptr " + envp);
    let r = temp();
    line("  " + r + " = call ptr " + codev + "(ptr " + envv + ", ptr " + arr + ", i64 " + std.String.toString(narg) + ")");
    r;
  } else {
    line("; unhandled Call callee: " + node.callee.type);
    emitNull();
  };
};

// 数组字面量(tag 5 盒,R10-e):@0 tag=5,@8 元素数组 ptr,@16 长度 i64。
// 元素数组 = call ptr @ql_alloc(i64 8*n),每元素 GEP+store(盒/raw ptr 一律 ptr 型)。
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

// emitExpr(node) → 承载盒值的寄存器名
let emitExpr = (node) -> {
  let t = node.type;
  if t == "Number" {
    emitNumber(node);
  } else if t == "Boolean" {
    emitBoolean(node);
  } else if t == "Null" {
    emitNull();
  } else if t == "BinaryOp" {
    emitBinaryOp(node);
  } else if t == "UnaryOp" {
    emitUnaryOp(node);
  } else if t == "Call" {
    emitCall(node);
  } else if t == "Identifier" {
    emitIdentifier(node);
  } else if t == "Object" {
    emitObjectExpr(node);
  } else if t == "MemberAccess" {
    emitMemberAccess(node);
  } else if t == "Function" {
    // R10-c/i:函数值 → 闭包盒 emit。name 参数仅作未来诊断用(v1 emitFunction 按 funcCounter
    // 生成 ql_fn<N>,不依赖 name)。调用方(emitLetStmt)已先 defineSlot(name),递归成立。
    emitFunction(node, "");
  } else if t == "String" {
    // M2 Task 2:字符串字面量 → interned 全局 STRING 盒地址(直接可作 ptr 操作数)。
    emitStringLiteral(node);
  } else if node.type == "Array" {
    emitArrayExpr(node);
  } else if node.type == "IndexAccess" {
    let C = emitExpr(node.object);
    let I = emitExpr(node.index);
    emitCallRegs("__get_index", [C, I]);
  } else {
    line("; unhandled expr: " + t);
    emitNull();
  };
};

// ---- 产物头部注入(每产物一份) ----
let emitPrelude = () -> {
  line("; qlangc v1 prelude");
  line("declare ptr  @ql_alloc(i64)");
  line("declare void @ql_write(i32, ptr, i64)");
  line("declare i8   @ql_mem_get(ptr, i64)");
  line("declare void @ql_mem_store(ptr, i64, i8)");
  line("declare ptr  @ql_mem_get_ptr(ptr, i64)");
  line("declare void @ql_mem_store_ptr(ptr, i64, ptr)");
  line("declare void @ql_exit(i32)");

  // M2 Task 2:interned 全局 null 盒 {tag=4, payload=0}(emitNull 返回其地址;见 emitNull 注释)。
  line("@.nullbox = global { i64, i64 } { i64 4, i64 0 }");

  // --- @ql_truthy(i64 %box) → i1:switch tag —— NUMBER !=0(NaN 真)、BOOL 值、其余假(v1) ---
  // %box 参数按 plan 定为 i64(地址值);内部先 inttoptr 还原为指针再解盒。
  line("define internal i1 @ql_truthy(i64 %box) {");
  let te = lbl(); line(te + ":");
  let tboxp = temp(); let ttag = temp(); let tisnum = temp();
  line("  " + tboxp + " = inttoptr i64 %box to ptr");
  line("  " + ttag + " = load i64, ptr " + tboxp);
  line("  " + tisnum + " = icmp eq i64 " + ttag + ", 1");
  let tlnum = lbl(); let tlchk = lbl();
  line("  br i1 " + tisnum + ", label %" + tlnum + ", label %" + tlchk);
  line(tlnum + ":");
  let tpa = temp(); let tfv = temp(); let tne0 = temp();
  line("  " + tpa + " = getelementptr i8, ptr " + tboxp + ", i64 8");
  line("  " + tfv + " = load double, ptr " + tpa);
  line("  " + tne0 + " = fcmp une double " + tfv + ", 0.0");
  line("  ret i1 " + tne0);
  line(tlchk + ":");
  let tisbool = temp();
  line("  " + tisbool + " = icmp eq i64 " + ttag + ", 3");
  let tlbool = lbl(); let tlother = lbl();
  line("  br i1 " + tisbool + ", label %" + tlbool + ", label %" + tlother);
  line(tlbool + ":");
  let tpb = temp(); let tbv = temp(); let tbne0 = temp();
  line("  " + tpb + " = getelementptr i8, ptr " + tboxp + ", i64 8");
  line("  " + tbv + " = load i64, ptr " + tpb);
  line("  " + tbne0 + " = icmp ne i64 " + tbv + ", 0");
  line("  ret i1 " + tbne0);
  line(tlother + ":");
  line("  ret i1 false");
  line("}");

  // R10-e:@ql_print_uint(424-522)与 print/println 特例(269-275)已删除 —— 值→字符串
  // 语义整体移入 runtime.ql(__str/__itoa/__boolstr),编译进产物;@ql_truthy 保留。
};

// 顶层语句:Let 真实 emit;其余(Assign/If/While/表达式语句)走 emitStmtDispatch(node, null)
// (boot parser 无 ExprStmt 包装 —— 裸表达式节点直接出现在 program.statements)。
let emitTopLevelStmt = (node) -> {
  if node.type == "Let" {
    emitLetStmt(node);
  } else {
    emitStmtDispatch(node, null);
  };
};

let main = (args) -> {
  let source = args[0];
  let lexer = Lexer(source);
  let tokens = lexer.tokenize();
  let parser = Parser(tokens);
  let program = parser.parse();
  emitPrelude();
  line("define i32 @main() {");
  line("entry:");
  curLbl = "entry";
  // R9 Design 2:main 建全局帧 —— pre-scan 顶层 Let 总数 K 作帧槽数。
  let K = 0;
  let s0 = 0;
  while s0 < program.statements.length {
    if program.statements[s0].type == "Let" { K = K + 1; };
    s0 = s0 + 1;
  };
  let envReg = temp();
  line("  " + envReg + " = call ptr @ql_alloc(i64 " + std.String.toString(16 + 8 * K) + ")");
  line("  store ptr null, ptr " + envReg);                              // parent = null
  let noff = temp();
  line("  " + noff + " = getelementptr i8, ptr " + envReg + ", i64 8");
  line("  store i64 " + std.String.toString(K) + ", ptr " + noff);       // n_slots = K
  curEnv = envReg;
  // 前向引用安全:先按源码序把全部顶层 let 名注册进 globalScope(defineSlot 幂等 → 槽号
  // 与逐个 emit 时一致),使函数体 emit 期间对「定义于其后的顶层 let」(如 __obj_set 调
  // __rehash)能经 parent 链解析到正确槽号;否则 lookupSlot 未命中 → nullbox → 空指针调用。
  let p0 = 0;
  while p0 < program.statements.length {
    if program.statements[p0].type == "Let" { defineSlot(program.statements[p0].name); };
    p0 = p0 + 1;
  };
  let i = 0;
  while i < program.statements.length {
    emitTopLevelStmt(program.statements[i]);
    i = i + 1;
  };
  line("  ret i32 0");
  line("}");
  // R10-c:先 flush main(out),再按定义序 flush 各函数 fnBlocks(LLVM 允许前向引用:
  // main 经闭包盒 `store ptr @ql_fn<N>` 引用后定义的函数)。
  let i2 = 0;
  while i2 < out.length {
    println(out[i2]);
    i2 = i2 + 1;
  };
  let b = 0;
  while b < fnBlocks.length {
    let blk = fnBlocks[b];
    let j = 0;
    while j < blk.length {
      println(blk[j]);
      j = j + 1;
    };
    b = b + 1;
  };
  // M2 Task 2:flush 全局字符串常量/盒(LLVM 顶层实体无序,放函数定义之后合法)。
  // 注意:必须 println 直接落 IR —— line() 会追加到已 flush 过的 out(死数据,永不出现在 IR)。
  let si = 0;
  while si < strDecls.length {
    println(strDecls[si]);
    si = si + 1;
  };
};

main(args);
