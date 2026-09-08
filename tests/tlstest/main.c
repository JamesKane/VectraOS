/*
tlstest -- thread-local storage in C, `docs/DEVTOOLS.md` step 0.

`crt0` sets a thread pointer, and this reads and writes a `_Thread_local`
through it. `seed` starts from `.tdata`, so a read before any write proves
the initial image was copied. Then it writes its pid, sleeps so the
scheduler runs other programs, and reads again: the value survives only
if the kernel saved and restored the thread pointer on the switches. Two
copies run at once from `tls.rc`, each with its own block at its own
address, so a switch that did not restore would read the other's.
*/
#include "vlibc.h"

static _Thread_local long seed = 0x5eed;
static _Thread_local long mine = 0;

int main(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	if (seed != 0x5eed) {
		print("tlstest: initial image wrong: %d\n", (int)seed);
		exits("tls init");
	}
	mine = vgetpid();
	for (int i = 0; i < 30; i++) {
		vsleep(3);
		if (mine != vgetpid() || seed != 0x5eed) {
			print("tlstest: lost across a switch: mine=%d seed=%x\n", (int)mine, (int)seed);
			exits("tls lost");
		}
	}
	print("tlstest: thread-local survived %d switches, pid %d\n", 30, (int)vgetpid());
	exits("tls ok");
	return 0;
}
