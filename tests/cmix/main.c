/*
cmix -- a C main and an Odin package in one image, step 0's mixed proof.

`main` calls `odin_triple`, an Odin procedure, and `odin_triple` calls
`c_inc`, defined here. So one image holds a call from C into Odin and one
from Odin back into C, on the platform's calling convention. The answer is
`c_inc(3) * 3 = 12`; the line shows it and the exit word says whether it
held, which is what the self-test reads.
*/
#include "vlibc.h"

/* Called from the Odin side. */
int c_inc(int n)
{
	return n + 1;
}

/* Defined in the Odin package. */
extern int odin_triple(int n);

int main(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	int r = odin_triple(3);
	print("cmix: odin_triple(3)=%d\n", r);
	exits(r == 12 ? "cmix ok" : "cmix bad");
	return 0;
}
