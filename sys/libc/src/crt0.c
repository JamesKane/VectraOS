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
