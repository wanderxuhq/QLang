#include <stdint.h>
#include <stddef.h>
extern void* ql_alloc(size_t);
extern void* ql_stack_top;

typedef struct Cell { struct Cell* next; uintptr_t value; } Cell;
int main(int argc, char** argv) {
  (void)argc;
  ql_stack_top = argv;
  if (ql_alloc(SIZE_MAX) != 0) return 1;
  unsigned char* base = ql_alloc(262144);
  for (size_t i = 0; i < 262144; ++i) base[i] = (unsigned char)(i % 251);
  // Keep only an interior pointer into a multi-page allocation.
  unsigned char* volatile interior = base + 12345;
  base = 0;
  Cell* volatile chain = 0;
  for (size_t i = 0; i < 600; ++i) {
    Cell* cell = ql_alloc(sizeof(Cell));
    if ((uintptr_t)cell % 8) return 2;
    cell->next = chain; cell->value = i;
    chain = cell;
  }
  for (size_t i = 0; i < 300000; ++i) {
    unsigned char* garbage = ql_alloc(256);
    garbage[0] = (unsigned char)i;
  }
  if (interior[0] != 12345 % 251 || interior[200000] != 212345 % 251) return 3;
  Cell* cell = chain;
  for (size_t i = 600; i > 0; --i) {
    if (!cell || cell->value != i - 1) return 4;
    cell = cell->next;
  }
  return cell != 0;
}
