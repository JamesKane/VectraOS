/*
tlstest2 -- a second thread-local program, larger, to prove the restore.

Its thread-local storage is a page, so its thread pointer sits at a
different offset from `tlstest`'s. Run at the same time, the two have
different pointers, and a switch that did not restore the pointer would
read one program's local through the other's. It fills its array from its
pid, sleeps so the other runs, and checks the array held. See
`docs/DEVTOOLS.md` step 0.
*/
#include "vlibc.h"

#define N 512

static _Thread_local long big[N];
static _Thread_local long tag = 0x1234;

int main(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	if (tag != 0x1234) {
		exits("tls init");
	}
	long pid = vgetpid();
	for (int i = 0; i < N; i++) {
		big[i] = pid + i;
	}
	for (int r = 0; r < 30; r++) {
		vsleep(3);
		for (int i = 0; i < N; i++) {
			if (big[i] != pid + i) {
				print("tlstest2: big[%d]=%d want %d\n", i, (int)big[i], (int)(pid + i));
				exits("tls lost");
			}
		}
		if (tag != 0x1234) {
			exits("tls tag");
		}
	}
	print("tlstest2: %d thread-locals survived, pid %d\n", N, (int)pid);
	exits("tls ok");
	return 0;
}
