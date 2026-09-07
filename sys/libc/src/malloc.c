/*
malloc.c -- a heap over one segment, grown by `segbrk`.

`sys/libuser` has a real allocator over the same calls, with a free list
and coalescing; this is the smaller thing a C program starts with. One
segment from `segalloc`, a bump pointer through it, and `segbrk` to grow
when the bump runs out. `free` is a no-op, because a bump does not take
memory back. A program that frees and reuses in a loop wants the Odin
heap or section 8's allocator; a tool that allocates a few things and
exits wants nothing more than this.
*/
#include "vlibc.h"

#define HEAP_STEP (1 << 20)

static uintptr heap_base;
static uintptr heap_top;  /* end of the mapped run */
static uintptr heap_next; /* the bump */

static int grow(usize need)
{
	if (heap_base == 0) {
		usize want = need > HEAP_STEP ? need : HEAP_STEP;
		long a = __vsyscall(SYS_SEGALLOC, (long)want, 0, 0, 0, 0, 0);
		if (a < 0) {
			return 0;
		}
		heap_base = (uintptr)a;
		heap_next = heap_base;
		heap_top = heap_base + want;
		return 1;
	}
	usize have = heap_top - heap_base;
	usize want = have;
	while (want - (heap_next - heap_base) < need) {
		want += HEAP_STEP;
	}
	if (__vsyscall(SYS_SEGBRK, (long)heap_base, (long)(heap_base + want), 0, 0, 0, 0) != 0) {
		return 0;
	}
	heap_top = heap_base + want;
	return 1;
}

void *malloc(usize n)
{
	if (n == 0) {
		n = 1;
	}
	n = (n + 15) & ~(usize)15;
	if (heap_next + n > heap_top) {
		if (!grow(n)) {
			return NULL;
		}
	}
	void *p = (void *)heap_next;
	heap_next += n;
	return p;
}

void free(void *p)
{
	(void)p;
}
