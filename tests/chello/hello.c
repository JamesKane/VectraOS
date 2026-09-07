/*
chello -- the first C program, `docs/DEVTOOLS.md` step 0's boot line.

It writes a line to standard output through `sys/libc`, then exits with a
word. The line proves the door, the library, `crt0` and the build all
work, and the self-test reads the word. The line is what a person sees;
the word is what the kernel checks.
*/
#include "vlibc.h"

int main(int argc, char **argv)
{
	print("hello from C, argc=%d argv0=%s\n", argc, argc > 0 ? argv[0] : "?");
	exits("chello ok");
	return 0;
}
