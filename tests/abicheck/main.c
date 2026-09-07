/*
abicheck -- the generated header's proof, `docs/DEVTOOLS.md` section 3.

`sys/abi/abi.h` is generated from `sys/abi/abi.odin`, and the kernel reads
the same file as Odin constants. The self-test spawns this with those
constants as arguments, in a fixed order, each the kernel's own value.
This compares each to the same name in `abi.h` and exits `ok`, or the name
of the first that differs. A number that moved in the Odin file and was not
regenerated, or was mistranslated, is a mismatch here.

The order is: SYS_WRITE, SYS_READ, SYS_OPEN, SYS_EXITS, O_RDONLY, O_WRONLY,
O_TRUNC, RFPROC, RFMEM, ARGS_MAX.
*/
#include "vlibc.h"

static long atol_(const char *s)
{
	long v = 0;
	int neg = 0;
	if (*s == '-') {
		neg = 1;
		s++;
	}
	while (*s >= '0' && *s <= '9') {
		v = v * 10 + (*s - '0');
		s++;
	}
	return neg ? -v : v;
}

int main(int argc, char **argv)
{
	static const struct {
		const char *name;
		long value;
	} expect[] = {
		{"SYS_WRITE", SYS_WRITE},
		{"SYS_READ", SYS_READ},
		{"SYS_OPEN", SYS_OPEN},
		{"SYS_EXITS", SYS_EXITS},
		{"O_RDONLY", O_RDONLY},
		{"O_WRONLY", O_WRONLY},
		{"O_TRUNC", O_TRUNC},
		{"RFPROC", RFPROC},
		{"RFMEM", RFMEM},
		{"ARGS_MAX", ARGS_MAX},
	};
	int n = (int)(sizeof(expect) / sizeof(expect[0]));
	if (argc != n + 1) {
		print("abicheck: got %d args, want %d\n", argc - 1, n);
		exits("argc");
	}
	for (int i = 0; i < n; i++) {
		long kernel = atol_(argv[i + 1]);
		if (kernel != expect[i].value) {
			print("abicheck: %s: header %d, kernel %d\n",
				expect[i].name, (int)expect[i].value, (int)kernel);
			exits(expect[i].name);
		}
	}
	print("abicheck: %d constants agree with the kernel\n", n);
	exits("abi ok");
	return 0;
}
