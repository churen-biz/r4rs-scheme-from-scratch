#include "scheme.h"
#include <stdio.h>
#include <stdlib.h>

void rt_error(const char *msg) {
    fprintf(stderr, "%s\n", msg);
    exit(1);
}

void rt_print(ptr x) {
    /* L00: not yet tagged; print as signed decimal. Do not hard-code 42. */
    printf("%lld\n", (long long)x);
}

int main(void) {
    size_t n = 64u * 1024u * 1024u;
    ptr *heap = aligned_alloc(8, n);
    if (!heap) rt_error("heap alloc failed");
    ptr r = scheme_entry(heap, n);
    rt_print(r);
    return 0;
}
