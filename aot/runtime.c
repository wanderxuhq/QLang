/* aot/runtime.c — leaf:QLang 语言表达不了的 syscall 边界。
 * aarch64 Linux 纯 syscall,无 libc 依赖。leak+arena 内存策略:brk bump,程序跑完即退。
 * 编译进产物:clang -fuse-ld=lld <out.ll> aot/runtime.c -o <out> */
#include <stddef.h>
#include <stdint.h>
#include <string.h>

static inline long syscall1(long n, long a) {
  register long x0 __asm__("x0") = a;
  register long x8 __asm__("x8") = n;
  __asm__ volatile("svc 0" : "+r"(x0) : "r"(x8) : "memory");
  return x0;
}
static inline long syscall3(long n, long a, long b, long c) {
  register long x0 __asm__("x0") = a;
  register long x1 __asm__("x1") = b;
  register long x2 __asm__("x2") = c;
  register long x8 __asm__("x8") = n;
  __asm__ volatile("svc 0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x8) : "memory");
  return x0;
}

static void* brk_(void* new_brk) { return (void*)syscall1(214, (long)new_brk); } /* aarch64 brk */

static void* heap_end = 0;

void* ql_alloc(size_t n) {
  if (heap_end == 0) heap_end = brk_(0);
  n = (n + 7UL) & ~7UL;                        /* 8 字节对齐 */
  void* p = heap_end;
  void* want = (char*)heap_end + n;
  void* got = brk_(want);
  if (got < want) return 0;                    /* 分配失败:v1 不处理,保持不崩 */
  heap_end = want;
  return p;
}

void ql_write(int fd, const void* buf, size_t n) {
  syscall3(64, fd, (long)buf, n);              /* aarch64 write */
}

void ql_exit(int code) {
  syscall1(93, code);                          /* aarch64 exit */
}

uint8_t ql_mem_get(const void* p, size_t off) { return ((const uint8_t*)p)[off]; }

void ql_mem_store(void* p, size_t off, uint8_t v) { ((uint8_t*)p)[off] = v; }

void* ql_mem_get_ptr(const void* p, size_t off) {
    void* v;
    memcpy(&v, (const char*)p + off, sizeof(void*));
    return v;
}
void ql_mem_store_ptr(void* p, size_t off, void* v) {
    memcpy((char*)p + off, &v, sizeof(void*));
}
