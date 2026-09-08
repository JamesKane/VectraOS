/*
crt0.c -- `_start` for a C or C++ program, the runtime before `main`.

The kernel enters here with the `abi.Args` block in the first argument
register, the same one an Odin `_start` reads. This turns the block's Odin
strings, which carry a length and no terminator, into a C `argv` of
NUL-terminated strings, runs the constructors the linker gathered in
`.init_array`, and calls `main`. A `main` that returns hands its value to
`exits`: zero is the empty status, and anything else is its decimal.

C++ works as far as a runtime-free program goes: constructors run here,
and templates, classes and placement `new` never needed a runtime.
Exceptions and RTTI are section 8's, and a program builds with
`-fno-exceptions -fno-rtti` until then. See `docs/DEVTOOLS.md` section 3.
*/
#include "vlibc.h"

extern int main(int argc, char **argv);

/* The linker's bounds on the constructor array, from `link_user.ld`. */
typedef void (*initfn)(void);
extern initfn __init_array_start[];
extern initfn __init_array_end[];

/* The initial thread-local image, from `link_user.ld`: `.tdata` is copied,
   the `.tbss` past it is zeroed. */
extern char __tdata_start[];
extern char __tdata_end[];
extern char __tbss_end[];

static usize tls_align(usize n)
{
	return (n + 15) & ~(usize)15;
}

/*
setup_tls lays out this program's thread-local storage and sets the thread
pointer, so a `_Thread_local` variable reads and writes correctly. The
layout is each architecture's own ABI, and the thread pointer is set with
`SYS_TLS`, which the kernel then saves and restores on a context switch.

There is one block per program, allocated here. A program with no
thread-local data has an empty `.tdata` and `.tbss`, and still gets a
pointer, because the kernel's save and restore want one.
*/
static void setup_tls(void)
{
	usize data = (usize)(__tdata_end - __tdata_start);
	usize total = tls_align((usize)(__tbss_end - __tdata_start));

#if defined(__x86_64__)
	/* Variant II: the thread pointer is the block's end, thread-local data
	   sits below it, and the word at the pointer points to itself. */
	char *block = (char *)malloc(total + 16);
	if (block == NULL) {
		return;
	}
	char *tp = block + total;
	memcpy(block, __tdata_start, data);
	memset(block + data, 0, total - data);
	*(void **)tp = tp;
	vtls(tp);
#elif defined(__aarch64__)
	/* Variant I: the thread pointer is the block's start, a 16-byte control
	   block comes first, and thread-local data follows it. */
	char *block = (char *)malloc(16 + total);
	if (block == NULL) {
		return;
	}
	memset(block, 0, 16);
	memcpy(block + 16, __tdata_start, data);
	memset(block + 16 + data, 0, total - data);
	vtls(block);
#else
	/* riscv64: the thread pointer is the block's start, and thread-local
	   data begins there. */
	char *block = (char *)malloc(total > 0 ? total : 16);
	if (block == NULL) {
		return;
	}
	memcpy(block, __tdata_start, data);
	memset(block + data, 0, total - data);
	vtls(block);
#endif
}

/* argv and its backing bytes, in bss: a program's arguments are bounded by
   ARGS_MAX and ARGV_MAX, so no allocation is needed to lay them out. */
static char argv_bytes[ARGS_MAX + ARGV_MAX + 1];
static char *argv[ARGV_MAX + 1];

void _start(Args *block)
{
	int argc = 0;
	if (block != NULL && block->count > 0 && block->strings != NULL) {
		argc = (int)block->count;
		if (argc > ARGV_MAX) {
			argc = ARGV_MAX;
		}
		int at = 0;
		for (int i = 0; i < argc; i++) {
			VString s = block->strings[i];
			argv[i] = &argv_bytes[at];
			for (isize k = 0; k < s.len && at < ARGS_MAX + ARGV_MAX; k++) {
				argv_bytes[at++] = s.data[k];
			}
			argv_bytes[at++] = 0;
		}
	}
	argv[argc] = NULL;

	// The thread pointer before the constructors, so a `_Thread_local`
	// works in one, and before `main`.
	setup_tls();

	for (initfn *f = __init_array_start; f < __init_array_end; f++) {
		(*f)();
	}

	int r = main(argc, argv);
	if (r == 0) {
		exits(NULL);
	}
	/* A non-zero return becomes a decimal status, the way a shell reads one. */
	char msg[16];
	int n = 0;
	unsigned int v = (unsigned int)(r < 0 ? -r : r);
	char tmp[12];
	int t = 0;
	if (r < 0) {
		msg[n++] = '-';
	}
	do {
		tmp[t++] = (char)('0' + v % 10);
		v /= 10;
	} while (v);
	while (t > 0) {
		msg[n++] = tmp[--t];
	}
	msg[n] = 0;
	exits(msg);
}
