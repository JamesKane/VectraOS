// mem_words_test.c: mem_test.c with vx-mem's word paths, aarch64's, forced on
// an x86 host, where memcpy and memset are otherwise the string instructions.

#define VX_MEM_WORDS
#include "mem_test.c"
