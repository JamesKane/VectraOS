/*
crt0.c -- `_start` for a POSIX program, the runtime before `main`.

The kernel enters with the `abi.Args` block in the first argument register.
This lays out the thread pointer first, because `errno` is thread-local and
the library uses it from the first call; then it turns the block's Odin
strings into a C `argv`, runs the constructors in `.init_array`, and calls
`main`. A `main` that returns hands its value to `exit`, the number as
text, so a parent's `waitpid` reads it back. See `docs/DEVTOOLS.md`
section 8.
*/
#include "posix_internal.h"

extern int main(int argc, char **argv, char **envp);
extern void exit(int) __attribute__((noreturn));
extern void *malloc(usize);
extern usize __tls_block_size(void);
extern void *__tls_init(void *block);
extern long vtls_set(void *tp);

typedef struct {
	long count;
	VString *strings;
} Args;

typedef void (*initfn)(void);
extern initfn __init_array_start[];
extern initfn __init_array_end[];

#define ARGV_MAX 64
static char argv_bytes[ARGS_MAX + ARGV_MAX + 1];
static char *argv[ARGV_MAX + 1];
static char *envp_empty[1];

static void setup_tls(void)
{
	void *block = malloc(__tls_block_size());
	if (block == NULL) {
		return;
	}
	vtls_set(__tls_init(block));
}

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
			for (long k = 0; k < s.len && at < ARGS_MAX + ARGV_MAX; k++) {
				argv_bytes[at++] = s.data[k];
			}
			argv_bytes[at++] = 0;
		}
	}
	argv[argc] = NULL;
	envp_empty[0] = NULL;

	/* The thread pointer before anything reads `errno`, and before the
	   constructors, which may. */
	setup_tls();

	for (initfn *f = __init_array_start; f < __init_array_end; f++) {
		(*f)();
	}

	exit(main(argc, argv, envp_empty));
}
