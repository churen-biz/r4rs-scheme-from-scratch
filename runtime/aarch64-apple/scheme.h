#ifndef SCHEME_H
#define SCHEME_H
#include <stdint.h>
typedef int64_t ptr;
ptr scheme_entry(ptr *heap, uint64_t heap_nbytes);
void rt_print(ptr x);
void rt_error(const char *msg);
#endif
