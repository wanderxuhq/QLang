; aot/tests/m0_factorial.ll — M0 风险解除:全盒指针 ABI + 数字→文本
; 语义:以全盒 NUMBER([tag=1][f64]) 计算 5! = 120,解盒为 i64,十进制输出 "120"。
; 构建:clang -fuse-ld=lld aot/tests/m0_factorial.ll aot/runtime.c -o /tmp/m0_factorial
; 期望输出:"120"

declare ptr  @ql_alloc(i64)
declare void @ql_write(i32, ptr, i64)
declare void @ql_exit(i32)

; --- 全盒工具 ---
define internal ptr @make_number(double %v) {
entry:
  %p = call ptr @ql_alloc(i64 16)
  store i64 1, ptr %p
  %pay = getelementptr i8, ptr %p, i64 8
  store double %v, ptr %pay
  ret ptr %p
}

; box_mul(a, b) → 解盒、fmul、新盒
define internal ptr @box_mul(ptr %a, ptr %b) {
entry:
  %pa = getelementptr i8, ptr %a, i64 8
  %fa = load double, ptr %pa
  %pb = getelementptr i8, ptr %b, i64 8
  %fb = load double, ptr %pb
  %r = fmul double %fa, %fb
  %nb = call ptr @ql_alloc(i64 16)
  store i64 1, ptr %nb
  %np = getelementptr i8, ptr %nb, i64 8
  store double %r, ptr %np
  ret ptr %nb
}

; 5! 的全盒计算链
define internal ptr @fact5() {
entry:
  %b5 = call ptr @make_number(double 5.0)
  %b4 = call ptr @make_number(double 4.0)
  %b3 = call ptr @make_number(double 3.0)
  %b2 = call ptr @make_number(double 2.0)
  %b1 = call ptr @make_number(double 1.0)
  %m1 = call ptr @box_mul(ptr %b5, ptr %b4)
  %m2 = call ptr @box_mul(ptr %m1, ptr %b3)
  %m3 = call ptr @box_mul(ptr %m2, ptr %b2)
  %m4 = call ptr @box_mul(ptr %m3, ptr %b1)
  ret ptr %m4
}

; --- 整数十进制输出(整数快速路径,复刻 host Value::to_string 的整数分支) ---
define internal void @print_uint(i64 %n) {
entry:
  %buf = alloca [24 x i8], align 1
  %bp = getelementptr inbounds [24 x i8], ptr %buf, i64 0, i64 0
  %isz = icmp eq i64 %n, 0
  br i1 %isz, label %zero, label %loop
zero:
  store i8 48, ptr %bp
  call void @ql_write(i32 1, ptr %bp, i64 1)
  ret void
loop:
  %i = phi i64 [ 0, %entry ], [ %i1, %loop ]
  %x = phi i64 [ %n, %entry ], [ %q, %loop ]
  %d = urem i64 %x, 10
  %ch = add i64 48, %d
  %c = trunc i64 %ch to i8
  %off = getelementptr i8, ptr %bp, i64 %i
  store i8 %c, ptr %off
  %q = udiv i64 %x, 10
  %i1 = add i64 %i, 1
  %nz = icmp ne i64 %q, 0
  br i1 %nz, label %loop, label %rev
rev:
  %len = phi i64 [ %i1, %loop ], [ %len, %revloop ]
  %j = phi i64 [ 0, %loop ], [ %j1, %revloop ]
  %half = udiv i64 %len, 2
  %done = icmp uge i64 %j, %half
  br i1 %done, label %out, label %revloop
revloop:
  %jo = getelementptr i8, ptr %bp, i64 %j
  %a = load i8, ptr %jo
  %last = sub i64 %len, 1
  %r2 = sub i64 %last, %j
  %jro = getelementptr i8, ptr %bp, i64 %r2
  %b = load i8, ptr %jro
  store i8 %b, ptr %jo
  store i8 %a, ptr %jro
  %j1 = add i64 %j, 1
  br label %rev
out:
  call void @ql_write(i32 1, ptr %bp, i64 %len)
  ret void
}

define i32 @main() {
entry:
  %r = call ptr @fact5()
  %pa = getelementptr i8, ptr %r, i64 8
  %f = load double, ptr %pa
  %n = fptosi double %f to i64
  call void @print_uint(i64 %n)
  call void @ql_exit(i32 0)
  unreachable
}
