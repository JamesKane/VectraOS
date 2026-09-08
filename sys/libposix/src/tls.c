/*
tls.c -- the thread-local block's layout, shared by `crt0` and `pthread`.

The main thread's block is laid out by `crt0`, and each `pthread` gets its
own, so two threads do not share an `errno`. Both call `__tls_block_size`
for how much to allocate and `__tls_init` to lay the block out and answer
the thread pointer, by the architecture's ABI. `vtls_set` puts the pointer
where the kernel saves it. See `docs/DEVTOOLS.md` sections 3 and 8.
*/
#include "posix_internal.h"

extern char __tdata_start[];
extern char __tdata_end[];
extern char __tbss_end[];
extern void *memcpy(void *, const void *, usize);
extern void *memset(void *, int, usize);

static usize tls_align(usize n)
{
	return (n + 15) & ~(usize)15;
}

usize __tls_block_size(void)
{
	usize total = tls_align((usize)(__tbss_end - __tdata_start));
#if defined(__x86_64__)
	return total + 16;
#elif defined(__aarch64__)
	return 16 + total;
#else
	return total > 0 ? total : 16;
#endif
}

void *__tls_init(void *block)
{
	usize data = (usize)(__tdata_end - __tdata_start);
	usize total = tls_align((usize)(__tbss_end - __tdata_start));
	char *b = (char *)block;
#if defined(__x86_64__)
	/* Variant II: the pointer is the block's end, data below it, a
	   self-pointer at the pointer. */
	char *tp = b + total;
	memcpy(b, __tdata_start, data);
	memset(b + data, 0, total - data);
	*(void **)tp = tp;
	return tp;
#elif defined(__aarch64__)
	/* Variant I: a 16-byte control block, then the data. */
	memset(b, 0, 16);
	memcpy(b + 16, __tdata_start, data);
	memset(b + 16 + data, 0, total - data);
	return b;
#else
	/* riscv64: the pointer is the block's start, the data there. */
	memcpy(b, __tdata_start, data);
	memset(b + data, 0, total - data);
	return b;
#endif
}

long vtls_set(void *tp)
{
	return __vsyscall(SYS_TLS, (long)tp, 0, 0, 0, 0, 0);
}
