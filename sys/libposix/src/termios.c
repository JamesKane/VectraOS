/*
termios.c -- the terminal mode over `/dev/consctl`, and `ioctl` for size.

`tcsetattr` turns off canonical input and echo into `rawon`, and their
presence into `rawoff`, written to `/dev/consctl`; `tcgetattr` reads the
line back and reports the flags. A window that wants its own mode opens
its own `consctl`, which is where a windowed program's descriptor leads.
`ioctl(TIOCGWINSZ)` answers a window's size or `ENOTTY`; a first cut has
no window ctl on the descriptor, so it is `ENOTTY` and a program uses a
default. See `docs/DEVTOOLS.md` section 8.
*/
#include "posix_internal.h"
#include <termios.h>
#include <sys/ioctl.h>
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

int tcgetattr(int fd, struct termios *t)
{
	if (!isatty(fd)) {
		errno = ENOTTY;
		return -1;
	}
	memset(t, 0, sizeof(*t));
	int cf = open("/dev/consctl", O_RDONLY);
	int raw = 0;
	if (cf >= 0) {
		char buf[16];
		long n = read(cf, buf, sizeof(buf) - 1);
		close(cf);
		if (n >= 5 && strncmp(buf, "rawon", 5) == 0) {
			raw = 1;
		}
	}
	/* Cooked has canonical input and echo; raw has neither. */
	t->c_lflag = raw ? 0 : (ICANON | ECHO);
	return 0;
}

int tcsetattr(int fd, int actions, const struct termios *t)
{
	(void)actions;
	if (!isatty(fd)) {
		errno = ENOTTY;
		return -1;
	}
	int cf = open("/dev/consctl", O_WRONLY);
	if (cf < 0) {
		errno = (int)ENOTTY;
		return -1;
	}
	const char *word = (t->c_lflag & (ICANON | ECHO)) ? "rawoff" : "rawon";
	long len = (long)strlen(word);
	long w = write(cf, word, len);
	close(cf);
	return w == len ? 0 : -1;
}

void cfmakeraw(struct termios *t)
{
	t->c_lflag &= ~(tcflag_t)(ICANON | ECHO);
}

int ioctl(int fd, unsigned long request, ...)
{
	(void)fd;
	if (request == TIOCGWINSZ) {
		/* No window ctl on this descriptor in the first cut, so a program
		   is told there is no terminal here and uses a default size. */
		errno = ENOTTY;
		return -1;
	}
	errno = ENOTTY;
	return -1;
}
