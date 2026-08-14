// aot/qlangc.ql — QLang → LLVM IR 编译器(QLang 写,跑在 boot 解释器上)
// host --compile 驱动:boot 解释器执行本文件;args[0] = 源码文本,args[1] = 源路径。
// 输出:纯 IR 文本到 stdout(本文件不 import main.ql,故无 banner)。
// R5:import 路径相对本文件 (aot/) 解析 → 必须指到 ../bootstrapped/*.ql。
import ../bootstrapped/lexer.ql;
import ../bootstrapped/ast.ql;
import ../bootstrapped/parser.ql;

// Task 3 骨架:忽略 AST,输出固定 hello IR(管道打通;emit 从 Task 4 开始)
// `\\0A` 在 QLang 字符串里是「字面反斜杠 + 0A」,经 println 落到 .ll 文件即为 LLVM 的
// hex 转义 `\0A`(0x0A 换行字节),clang 才能正确解析。QLang 自身的 `\0` 是 NUL,不可用。
let emitFixedHello = () -> {
  println("@msg = private unnamed_addr constant [3 x i8] c\"hi\\0A\"");
  println("declare void @ql_write(i32, ptr, i64)");
  println("declare void @ql_exit(i32)");
  println("define i32 @main() {");
  println("entry:");
  println("  call void @ql_write(i32 1, ptr @msg, i64 3)");
  println("  call void @ql_exit(i32 0)");
  println("  unreachable");
  println("}");
};

let main = (args) -> {
  emitFixedHello();
};

main(args);
