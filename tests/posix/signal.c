/*
posixsignal -- a signal caught, `docs/DEVTOOLS.md` step 7.

It installs a handler for SIGTERM, raises it at itself, and waits for the
handler to run. `raise` writes the note to its own `/proc/n/note`, the
kernel delivers it, and the handler turns it back into SIGTERM and sets a
flag. The program exits `0` when the flag was set, which proves a note was
caught as a signal.
*/
#include <stdio.h>
#include <stdlib.h>
#include <signal.h>
#include <unistd.h>

static volatile int caught = 0;

static void on_term(int sig)
{
	if (sig == SIGTERM) {
		caught = 1;
	}
}

int main(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	signal(SIGTERM, on_term);
	if (raise(SIGTERM) != 0) {
		printf("posixsignal: raise failed\n");
		exit(1);
	}
	/* The note is delivered at a boundary; sleep gives it one. */
	for (int i = 0; i < 100 && !caught; i++) {
		usleep(2000);
	}
	if (!caught) {
		printf("posixsignal: the signal was not caught\n");
		exit(2);
	}
	printf("posixsignal: SIGTERM caught\n");
	exit(0);
}
