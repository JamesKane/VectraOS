/*
posixchild -- the program `posixtest` runs, `docs/DEVTOOLS.md` step 7.

It reads the environment variable its parent set through `execve`, prints
its argument, and exits with a number the parent's `waitpid` reads back.
This is the far side of the fork-exec-wait shape, and the proof that
`execve`'s environment reached the new program.
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

int main(int argc, char **argv)
{
	const char *v = getenv("PXCHILD");
	printf("posixchild: argc=%d arg1=%s env=%s\n", argc,
		argc > 1 ? argv[1] : "?", v ? v : "(unset)");
	if (v == NULL || strcmp(v, "ok") != 0) {
		exit(70);
	}
	exit(7);
}
