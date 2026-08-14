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
let line = (s) -> { out[out.length] = s; };
let temp = () -> { tmpN = tmpN + 1; "%t" + std.String.toString(tmpN); };
let lbl = () -> { lblN = lblN + 1; "bb" + std.String.toString(lblN); };
let f64lit = (x) -> { if x % 1 == 0 { std.String.toString(x) + ".0"; } else { std.String.toString(x); }; };

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

// null 字面量:tag=4(NULL),无 payload
let emitNull = () -> {
  allocBox("4");
};

// 二元运算:先求值左右操作数,再解盒;算术造新 NUMBER 盒,比较造 BOOL 盒。
let emitBinaryOp = (node) -> {
  let L = emitExpr(node.left);
  let R = emitExpr(node.right);
  let op = node.operator;
  let a1 = temp(); let f1 = temp(); let a2 = temp(); let f2 = temp();
  line("  " + a1 + " = getelementptr i8, ptr " + L + ", i64 8");
  line("  " + f1 + " = load double, ptr " + a1);
  line("  " + a2 + " = getelementptr i8, ptr " + R + ", i64 8");
  line("  " + f2 + " = load double, ptr " + a2);
  if op == "+" || op == "-" || op == "*" || op == "/" || op == "%" {
    let rr = temp();
    if op == "%" {
      // `frem` 在 AArch64 后端被降级为 libm fmod 调用,而产物无 libc 依赖(runtime.c 纯 syscall,
      // 且 src/main.rs 不在本 task 提交范围)→ 用 a - b*trunc(a/b) 内联实现浮点余数(语义同 frem:
      // 结果带被除数符号;v1 测试商值均落在 i64 内,fptosi 安全)。
      let q = temp(); let qi = temp(); let qf = temp(); let m = temp();
      line("  " + q + " = fdiv double " + f1 + ", " + f2);
      line("  " + qi + " = fptosi double " + q + " to i64");
      line("  " + qf + " = sitofp i64 " + qi + " to double");
      line("  " + m + " = fmul double " + f2 + ", " + qf);
      line("  " + rr + " = fsub double " + f1 + ", " + m);
    } else {
      let fop = if op == "+" { "fadd" } else if op == "-" { "fsub" } else if op == "*" { "fmul" } else { "fdiv" };
      line("  " + rr + " = " + fop + " double " + f1 + ", " + f2);
    }
    let b = allocBox("1");
    let bpay = temp();
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  store double " + rr + ", ptr " + bpay);
    b;
  } else {
    // 比较:== oeq,!= une,< olt,<= ole,> ogt,>= oge
    let cmp = if op == "==" { "oeq" } else if op == "!=" { "une" } else if op == "<" { "olt" } else if op == "<=" { "ole" } else if op == ">" { "ogt" } else { "oge" };
    let c = temp(); let c2 = temp();
    line("  " + c + " = fcmp " + cmp + " double " + f1 + ", " + f2);
    line("  " + c2 + " = zext i1 " + c + " to i64");
    let b = allocBox("3");
    let bpay = temp();
    line("  " + bpay + " = getelementptr i8, ptr " + b + ", i64 8");
    line("  store i64 " + c2 + ", ptr " + bpay);
    b;
  };
};

// 一元运算:- → fneg 新 NUMBER 盒;! → @ql_truthy 反转后存 BOOL 盒。
let emitUnaryOp = (node) -> {
  let O = emitExpr(node.operand);
  if node.operator == "-" {
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
let defineSlot = (name) -> {
  let n = std.Object.keys(curScope.slots).length;
  curScope.slots[name] = n;
  n;
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
  let V = emitExpr(node.value);
  let slot = defineSlot(node.name);
  let off = temp();
  line("  " + off + " = getelementptr i8, ptr " + curEnv + ", i64 " + std.String.toString(16 + 8 * slot));
  line("  store ptr " + V + ", ptr " + off);
  slot;
};

// assign:沿链找目标帧 slot 写(R9 帧/槽全 ptr 型)。未命中 → 注释 + 不求值 value。
let emitAssignStmt = (node) -> {
  let hit = lookupSlot(node.target.name);
  if hit == null {
    line("; error: assign to undefined " + node.target.name);
  } else {
    let V = emitExpr(node.value);
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

// 表达式位置的 Call:Task 4 只特例顶层 print/println;回退 NULL 盒保证 IR 有效。
let emitCall = (node) -> {
  line("; unhandled Call in expr (Task 4): " + node.callee.type);
  emitNull();
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
  line("@ql_str_true = private unnamed_addr constant [4 x i8] c\"true\"");
  line("@ql_str_false = private unnamed_addr constant [5 x i8] c\"false\"");
  // `\\0A` 在 QLang 字符串里是「字面反斜杠 + 0A」,落到 .ll 文件即为 LLVM hex 转义 `\0A`。
  line("@ql_str_nl = private unnamed_addr constant [1 x i8] c\"\\0A\"");

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

  // --- @ql_print_uint(i64 %box, i1 %nl):按 tag 分派解盒输出;%nl 真时追加 '\n' ---
  // 数字路径:解盒 f64 → fptosi i64 → 十进制 write(复刻 m0_factorial.ll 的 div/rev 结构,
  // 补 n==0 写 '0';另加负数符号 '-' 处理 —— t4 测试含 println(-3))。
  // 注意:QLang 无前向引用,所有寄存器/标签名必须先声明后使用 —— 因此下面先一次性分配
  // @ql_print_uint 所需的全部 temp()/lbl() 名,再逐行输出 IR 文本。
  line("define internal void @ql_print_uint(i64 %box, i1 %nl) {");
  let pe = lbl();
  let pboxp = temp();
  let pbuf = temp(); let pbp = temp();
  let ptag = temp(); let pisnum = temp(); let pisbool = temp();
  let plnum = lbl(); let plchk = lbl();
  let plbool = lbl(); let plnl = lbl();
  let ppa = temp(); let pfv = temp(); let pn = temp();
  let pisz = temp(); let pisneg = temp(); let pnegd = temp();
  let plzero = lbl(); let plsign = lbl();
  let plsneg = lbl(); let plloop = lbl();
  let pi = temp(); let px = temp(); let pd = temp(); let pch = temp();
  let pc = temp(); let poff = temp(); let pq = temp(); let pinext = temp(); let pnz = temp();
  let plrev = lbl(); let plrevloop = lbl(); let plout = lbl();
  let plen = temp(); let pj = temp(); let phalf = temp(); let pdone = temp();
  let pjo = temp(); let pa = temp(); let plast = temp(); let pr2 = temp();
  let pjro = temp(); let pb = temp(); let pjnext = temp();
  let plbtrue = lbl(); let plbfalse = lbl();
  let ppb = temp(); let pbv = temp(); let pistrue = temp();
  let plwritenl = lbl(); let pldone = lbl();
  line(pe + ":");
  line("  " + pboxp + " = inttoptr i64 %box to ptr");
  line("  " + pbuf + " = alloca [24 x i8], align 1");
  line("  " + pbp + " = getelementptr inbounds [24 x i8], ptr " + pbuf + ", i64 0, i64 0");
  line("  " + ptag + " = load i64, ptr " + pboxp);
  line("  " + pisnum + " = icmp eq i64 " + ptag + ", 1");
  line("  " + pisbool + " = icmp eq i64 " + ptag + ", 3");
  line("  br i1 " + pisnum + ", label %" + plnum + ", label %" + plchk);
  line(plchk + ":");
  line("  br i1 " + pisbool + ", label %" + plbool + ", label %" + plnl);
  line(plnum + ":");
  line("  " + ppa + " = getelementptr i8, ptr " + pboxp + ", i64 8");
  line("  " + pfv + " = load double, ptr " + ppa);
  line("  " + pn + " = fptosi double " + pfv + " to i64");
  line("  " + pisz + " = icmp eq i64 " + pn + ", 0");
  line("  br i1 " + pisz + ", label %" + plzero + ", label %" + plsign);
  line(plzero + ":");
  line("  store i8 48, ptr " + pbp);
  line("  call void @ql_write(i32 1, ptr " + pbp + ", i64 1)");
  line("  br label %" + plnl);
  line(plsign + ":");
  line("  " + pisneg + " = icmp slt i64 " + pn + ", 0");
  line("  " + pnegd + " = sub i64 0, " + pn);
  line("  br i1 " + pisneg + ", label %" + plsneg + ", label %" + plloop);
  line(plsneg + ":");
  line("  store i8 45, ptr " + pbp);
  line("  call void @ql_write(i32 1, ptr " + pbp + ", i64 1)");
  line("  br label %" + plloop);
  line(plloop + ":");
  line("  " + pi + " = phi i64 [ 0, %" + plsign + " ], [ 0, %" + plsneg + " ], [ " + pinext + ", %" + plloop + " ]");
  line("  " + px + " = phi i64 [ " + pn + ", %" + plsign + " ], [ " + pnegd + ", %" + plsneg + " ], [ " + pq + ", %" + plloop + " ]");
  line("  " + pd + " = urem i64 " + px + ", 10");
  line("  " + pch + " = add i64 48, " + pd);
  line("  " + pc + " = trunc i64 " + pch + " to i8");
  line("  " + poff + " = getelementptr i8, ptr " + pbp + ", i64 " + pi);
  line("  store i8 " + pc + ", ptr " + poff);
  line("  " + pq + " = udiv i64 " + px + ", 10");
  line("  " + pinext + " = add i64 " + pi + ", 1");
  line("  " + pnz + " = icmp ne i64 " + pq + ", 0");
  line("  br i1 " + pnz + ", label %" + plloop + ", label %" + plrev);
  line(plrev + ":");
  line("  " + plen + " = phi i64 [ " + pinext + ", %" + plloop + " ], [ " + plen + ", %" + plrevloop + " ]");
  line("  " + pj + " = phi i64 [ 0, %" + plloop + " ], [ " + pjnext + ", %" + plrevloop + " ]");
  line("  " + phalf + " = udiv i64 " + plen + ", 2");
  line("  " + pdone + " = icmp uge i64 " + pj + ", " + phalf);
  line("  br i1 " + pdone + ", label %" + plout + ", label %" + plrevloop);
  line(plrevloop + ":");
  line("  " + pjo + " = getelementptr i8, ptr " + pbp + ", i64 " + pj);
  line("  " + pa + " = load i8, ptr " + pjo);
  line("  " + plast + " = sub i64 " + plen + ", 1");
  line("  " + pr2 + " = sub i64 " + plast + ", " + pj);
  line("  " + pjro + " = getelementptr i8, ptr " + pbp + ", i64 " + pr2);
  line("  " + pb + " = load i8, ptr " + pjro);
  line("  store i8 " + pb + ", ptr " + pjo);
  line("  store i8 " + pa + ", ptr " + pjro);
  line("  " + pjnext + " = add i64 " + pj + ", 1");
  line("  br label %" + plrev);
  line(plout + ":");
  line("  call void @ql_write(i32 1, ptr " + pbp + ", i64 " + plen + ")");
  line("  br label %" + plnl);
  line(plbool + ":");
  line("  " + ppb + " = getelementptr i8, ptr " + pboxp + ", i64 8");
  line("  " + pbv + " = load i64, ptr " + ppb);
  line("  " + pistrue + " = icmp ne i64 " + pbv + ", 0");
  line("  br i1 " + pistrue + ", label %" + plbtrue + ", label %" + plbfalse);
  line(plbtrue + ":");
  line("  call void @ql_write(i32 1, ptr @ql_str_true, i64 4)");
  line("  br label %" + plnl);
  line(plbfalse + ":");
  line("  call void @ql_write(i32 1, ptr @ql_str_false, i64 5)");
  line("  br label %" + plnl);
  line(plnl + ":");
  line("  br i1 %nl, label %" + plwritenl + ", label %" + pldone);
  line(plwritenl + ":");
  line("  call void @ql_write(i32 1, ptr @ql_str_nl, i64 1)");
  line("  br label %" + pldone);
  line(pldone + ":");
  line("  ret void");
  line("}");
};

// 顶层语句:Let/Assign 真实 emit;print/println 特例;其余一律按表达式语句求值丢弃
// (boot parser 无 ExprStmt 包装 —— 裸表达式节点直接出现在 program.statements)。
let emitTopLevelStmt = (node) -> {
  if node.type == "Let" {
    emitLetStmt(node);
  } else if node.type == "Assign" {
    emitAssignStmt(node);
  } else if node.type == "Call" && node.callee.type == "Identifier" && (node.callee.name == "print" || node.callee.name == "println") {
    // print/println 特例:v1 只处理单参数数字/布尔盒
    // 注意:host 解析器不允许行首续行二元运算符,条件必须写在同一行。
    let V = emitExpr(node.arguments[0]);
    let V2 = temp();
    let nl = if node.callee.name == "println" { "true" } else { "false" };
    line("  " + V2 + " = ptrtoint ptr " + V + " to i64");
    line("  call void @ql_print_uint(i64 " + V2 + ", i1 " + nl + ")");
  } else {
    // 表达式语句:求值并丢弃返回值
    emitExpr(node);
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
  let i = 0;
  while i < program.statements.length {
    emitTopLevelStmt(program.statements[i]);
    i = i + 1;
  };
  line("  ret i32 0");
  line("}");
  let i2 = 0;
  while i2 < out.length {
    println(out[i2]);
    i2 = i2 + 1;
  };
};

main(args);
