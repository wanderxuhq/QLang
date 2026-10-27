/* aot/runtime.c — leaf:QLang 语言表达不了的 syscall 边界。
 * aarch64 Linux syscall；动态扩展使用系统 libdl。保守式非移动回收,仅追踪原始分配块中的地址。
 * 编译进产物:clang -fuse-ld=lld <out.ll> aot/runtime.c -o <out> */
#include <stddef.h>
#include <stdint.h>
#include <string.h>
#include <dlfcn.h>
#include <stdlib.h>
#include <unistd.h>
#include <fcntl.h>
#include <sys/wait.h>

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


/* Conservative, non-moving collection of raw allocations. No QLang tags or
 * language semantics are inspected. Slabs allow interior-pointer lookup in
 * constant time; side metadata and mark queues are never treated as roots. */
#define PAGE_BYTES ((size_t)65536)
#define MAX_PAGES ((size_t)65536)
#define CLASSES 33
#define MIN_SHIFT 4
#define MIN_COLLECTION ((size_t)8 * 1024 * 1024)
typedef struct {
  size_t owner;
  unsigned shift;
  unsigned char state[PAGE_BYTES >> MIN_SHIFT]; /* 0=free, 1=used, 2=marked */
} Page;
static Page* pages;
static uintptr_t heap_base;
static size_t page_count;
static void* free_blocks[CLASSES];
static size_t used_blocks;
static size_t allocated_since_gc;
static size_t collection_threshold = MIN_COLLECTION;
static uintptr_t* mark_queue;
static size_t queue_capacity;
static size_t queue_read, queue_write;
/* The generated main publishes argv, above its entire stack frame. Embedders
 * which do not publish a stack bound retain the old allocation-only behavior. */
void* ql_stack_top;

static inline long syscall6(long n, long a, long b, long c, long d, long e, long f) {
  register long x0 __asm__("x0") = a;
  register long x1 __asm__("x1") = b;
  register long x2 __asm__("x2") = c;
  register long x3 __asm__("x3") = d;
  register long x4 __asm__("x4") = e;
  register long x5 __asm__("x5") = f;
  register long x8 __asm__("x8") = n;
  __asm__ volatile("svc 0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3), "r"(x4), "r"(x5), "r"(x8) : "memory");
  return x0;
}
static void* map_metadata(size_t size) {
  long p = syscall6(222, 0, (long)size, 3, 34, -1, 0); /* mmap, RW, PRIVATE|ANONYMOUS */
  if ((uintptr_t)p >= (uintptr_t)-4095) return 0;
  return (void*)p;
}
static void exhausted(void) {
  static const char message[] = "OutOfMemory: native heap exhausted\n";
  syscall3(64, 2, (long)message, sizeof(message) - 1);
  syscall1(93, 1);
  __builtin_unreachable();
}
static size_t block_slot(uintptr_t p, Page* page) {
  return (p - (heap_base + page->owner * PAGE_BYTES)) >> page->shift;
}
static void mark_candidate(uintptr_t p) {
  if (p < heap_base || p >= heap_base + page_count * PAGE_BYTES) return;
  Page* page = &pages[pages[(p - heap_base) / PAGE_BYTES].owner];
  size_t slot = block_slot(p, page);
  if (page->state[slot] != 1) return;
  page->state[slot] = 2;
  mark_queue[queue_write++] = heap_base + page->owner * PAGE_BYTES + (slot << page->shift);
}
static void scan_words(uintptr_t start, uintptr_t end) {
  start = (start + sizeof(uintptr_t) - 1) & ~(uintptr_t)(sizeof(uintptr_t) - 1);
  for (; start + sizeof(uintptr_t) <= end; start += sizeof(uintptr_t))
    mark_candidate(*(volatile uintptr_t*)start);
}
__attribute__((noinline)) static void collect_heap(void) {
  if (!ql_stack_top || !used_blocks) return;
  if (queue_capacity < used_blocks) {
    size_t capacity = used_blocks + used_blocks / 2 + 1024;
    uintptr_t* next = map_metadata(capacity * sizeof(uintptr_t));
    if (!next) exhausted();
    if (mark_queue) syscall3(215, (long)mark_queue, queue_capacity * sizeof(uintptr_t), 0);
    mark_queue = next;
    queue_capacity = capacity;
  }
  queue_read = queue_write = 0;
  /* Live values across an external call are on the stack or in callee-saved
   * registers. Spill those registers before scanning, independent of -O level. */
  uintptr_t saved[10];
  __asm__ volatile(
    "stp x19, x20, [%0, #0]\n"
    "stp x21, x22, [%0, #16]\n"
    "stp x23, x24, [%0, #32]\n"
    "stp x25, x26, [%0, #48]\n"
    "stp x27, x28, [%0, #64]\n" : : "r"(saved) : "memory");
  uintptr_t sp;
  __asm__ volatile("mov %0, sp" : "=r"(sp) : : "memory");
  scan_words((uintptr_t)saved, (uintptr_t)(saved + 10));
  scan_words(sp, (uintptr_t)ql_stack_top);
  while (queue_read < queue_write) {
    uintptr_t block = mark_queue[queue_read++];
    Page* page = &pages[(block - heap_base) / PAGE_BYTES];
    scan_words(block, block + ((size_t)1 << page->shift));
  }
  size_t live_bytes = 0;
  for (size_t i = 0; i < page_count; ) {
    Page* page = &pages[i];
    size_t size = (size_t)1 << page->shift;
    size_t slots = size < PAGE_BYTES ? PAGE_BYTES / size : 1;
    for (size_t j = 0; j < slots; ++j) {
      if (page->state[j] == 2) {
        page->state[j] = 1;
        live_bytes += size;
      } else if (page->state[j] == 1) {
        void* block = (void*)(heap_base + i * PAGE_BYTES + j * size);
        page->state[j] = 0;
        *(void**)block = free_blocks[page->shift];
        free_blocks[page->shift] = block;
        --used_blocks;
      }
    }
    i += size > PAGE_BYTES ? size / PAGE_BYTES : 1;
  }
  allocated_since_gc = 0;
  collection_threshold = live_bytes / 2;
  if (collection_threshold < MIN_COLLECTION) collection_threshold = MIN_COLLECTION;
}
void* ql_alloc(size_t n) {
  if (n > (size_t)1 << (CLASSES - 1)) return 0;
  if (!pages) {
    pages = map_metadata(MAX_PAGES * sizeof(Page));
    if (!pages) exhausted();
    /* libc/libdl owns the process break. A private lazy virtual reservation
     * prevents the language heap from overlapping loader allocations. */
    long reservation = syscall6(222, 0, MAX_PAGES * PAGE_BYTES + PAGE_BYTES,
                                0, 34, -1, 0); /* mmap PROT_NONE, reserve VA only */
    if ((uintptr_t)reservation >= (uintptr_t)-4095) exhausted();
    heap_base = ((uintptr_t)reservation + PAGE_BYTES - 1) & ~(uintptr_t)(PAGE_BYTES - 1);
  }
  unsigned shift = MIN_SHIFT;
  while (((size_t)1 << shift) < n) ++shift;
  size_t size = (size_t)1 << shift;
  if (allocated_since_gc >= collection_threshold) collect_heap();
  if (!free_blocks[shift]) {
    size_t count = size > PAGE_BYTES ? size / PAGE_BYTES : 1;
    if (count > MAX_PAGES - page_count) exhausted();
    uintptr_t start = heap_base + page_count * PAGE_BYTES;
    /* Commit only the pages being added, not the entire maximum heap. */
    if (syscall3(226, (long)start, count * PAGE_BYTES, 3) < 0) exhausted(); /* mprotect RW */
    for (size_t j = 0; j < count; ++j) {
      pages[page_count + j].owner = page_count;
      pages[page_count + j].shift = shift;
    }
    size_t slots = size < PAGE_BYTES ? PAGE_BYTES / size : 1;
    for (size_t j = slots; j > 0; --j) {
      void* block = (void*)(start + (j - 1) * size);
      *(void**)block = free_blocks[shift];
      free_blocks[shift] = block;
    }
    page_count += count;
  }
  void* result = free_blocks[shift];
  free_blocks[shift] = *(void**)result;
  Page* page = &pages[((uintptr_t)result - heap_base) / PAGE_BYTES];
  page->state[block_slot((uintptr_t)result, page)] = 1;
  ++used_blocks;
  allocated_since_gc += size;
  memset(result, 0, size);
  return result;
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

/* File-system leaves expose OS operations only. Text decoding, buffering and
 * error values are implemented by runtime.ql. Linux AArch64 syscall ABI. */
static inline long syscall4(long n, long a, long b, long c, long d) {
  register long x0 __asm__("x0") = a;
  register long x1 __asm__("x1") = b;
  register long x2 __asm__("x2") = c;
  register long x3 __asm__("x3") = d;
  register long x8 __asm__("x8") = n;
  __asm__ volatile("svc 0" : "+r"(x0) : "r"(x1), "r"(x2), "r"(x3), "r"(x8) : "memory");
  return x0;
}
long ql_openat(long dirfd, const void* path, long flags) {
  return syscall3(56, dirfd, (long)path, flags);
}
long ql_read(long fd, void* buf, long count) {
  return syscall3(63, fd, (long)buf, count);
}
long ql_close(long fd) { return syscall1(57, fd); }
long ql_readlinkat(long dirfd, const void* path, void* buf, long count) {
  return syscall4(78, dirfd, (long)path, (long)buf, count);
}

/* Entropy only; retry policy and conversion to a QLang Number live in QLang. */
long ql_getrandom(void* buf, long count) {
  return syscall3(278, (long)buf, count, 0); /* Linux AArch64 getrandom */
}

/* OS loader boundary. Pin one reference per DSO: escaped code and static
 * strings may outlive any one module namespace. No QLang heap roots here. */
typedef struct ExtensionHandle {
  void *handle;
  struct ExtensionHandle *next;
} ExtensionHandle;
static ExtensionHandle *extension_handles;
void *ql_extension_open(const char *path, const char *abi, uint64_t *status) {
  *status = 0;
  void *handle = dlopen(path, RTLD_NOW | RTLD_LOCAL);
  if (!handle) { *status = 1; return NULL; }
  const char *actual = (const char *)dlsym(handle, "qlang_extension_abi_v1");
  if (!actual || strcmp(actual, abi)) {
    dlclose(handle); *status = 2; return NULL;
  }
  void *entry = dlsym(handle, "qlang_extension_init_v1");
  if (!entry) { dlclose(handle); *status = 3; return NULL; }
  for (ExtensionHandle *p = extension_handles; p; p = p->next) {
    if (p->handle == handle) { dlclose(handle); return entry; }
  }
  ExtensionHandle *p = map_metadata(sizeof(*p));
  if (!p) { dlclose(handle); *status = 1; return NULL; }
  p->handle = handle; p->next = extension_handles; extension_handles = p;
  return entry;
}

/* ---- 进程:语言表达不了的 exec 边界 -------------------------------------------
 * argv 用 NUL 分隔的缓冲传进来,避免 QLang 侧拼 shell 命令;stdout/stderr 重定向到
 * 两个临时文件(由调用方给路径),这样父进程不需要 poll 管道,也不可能死锁。
 * 返回值:子进程退出码(正常退出)或 128+信号;负数表示机制本身失败。 */
long ql_getpid(void) { return (long)getpid(); }
long ql_unlink(const char *path) { return unlink(path); }
/* 写文件:构建驱动要把编译器输出(IR)落盘。返回 0 成功,负数失败。 */
long ql_write_file(const char *path, const void *data, long length) {
  int fd = open(path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
  if (fd < 0) return -1;
  long offset = 0;
  while (offset < length) {
    long n = write(fd, (const char *)data + offset, (size_t)(length - offset));
    if (n <= 0) { close(fd); return -2; }
    offset += n;
  }
  close(fd);
  return 0;
}
long ql_spawn(const char *argbuf, long nargs, const char *out_path, const char *err_path) {
  if (!argbuf || nargs <= 0 || nargs >= 64) return -1000;
  char *argv[64];
  const char *p = argbuf;
  for (long i = 0; i < nargs; i++) {
    if (!*p) return -1001;
    argv[i] = (char *)p;
    p += strlen(p) + 1;
  }
  argv[nargs] = NULL;
  int out = -1, err = -1;
  if (out_path && *out_path) {
    out = open(out_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (out < 0) return -1002;
  }
  if (err_path && *err_path) {
    err = open(err_path, O_WRONLY | O_CREAT | O_TRUNC, 0644);
    if (err < 0) { if (out >= 0) close(out); return -1003; }
  }
  pid_t pid = fork();
  if (pid < 0) { if (out >= 0) close(out); if (err >= 0) close(err); return -1004; }
  if (pid == 0) {
    if (out >= 0) { dup2(out, 1); close(out); }
    if (err >= 0) { dup2(err, 2); close(err); }
    execvp(argv[0], argv);
    _exit(127);
  }
  int st = 0;
  while (waitpid(pid, &st, 0) < 0) {}
  if (out >= 0) close(out);
  if (err >= 0) close(err);
  if (WIFEXITED(st)) return WEXITSTATUS(st);
  return 128 + (st & 0x7f);
}
