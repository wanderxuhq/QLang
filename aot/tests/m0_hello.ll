; aot/tests/m0_hello.ll — leaf 三件套 + .rodata 字符串 + ql_write + ql_exit
; 构建:clang -fuse-ld=lld aot/tests/m0_hello.ll aot/runtime.c -o /tmp/m0_hello
; 期望:运行输出 "hi" 且退出码 0

@msg = private unnamed_addr constant [3 x i8] c"hi\0A"

declare void @ql_write(i32, ptr, i64)
declare void @ql_exit(i32)

define i32 @main() {
entry:
  call void @ql_write(i32 1, ptr @msg, i64 3)
  call void @ql_exit(i32 0)
  unreachable
}
