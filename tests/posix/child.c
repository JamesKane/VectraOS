/*
posixchild -- the program `posixtest` runs, `docs/DEVTOOLS.md` step 7.

It prints its argument and exits with a fixed number, so the parent's
`waitpid` reads that number back through the status. This is the far side
of the fork-exec-wait shape.
*/
#include <stdio.h>
#include <stdlib.h>

int main(int argc, char **argv)
{
	printf("posixchild: argc=%d arg1=%s\n", argc, argc > 1 ? argv[1] : "?");
	exit(7);
}
