/*
termios.h -- the terminal's mode, over `/dev/consctl`.

Raw and cooked are the two the console has, and `docs/DEVFS.md` names them
the same way. `tcsetattr` writes `rawon` or `rawoff` to `/dev/consctl`,
and `tcgetattr` reads which is in force. The flag words are the standard
ones a program tests, and `cfmakeraw` clears the two that matter here:
canonical input and echo. See `docs/DEVTOOLS.md` section 8.
*/
#ifndef TERMIOS_H
#define TERMIOS_H

typedef unsigned int tcflag_t;
typedef unsigned char cc_t;

#define NCCS 32

struct termios {
	tcflag_t c_iflag;
	tcflag_t c_oflag;
	tcflag_t c_cflag;
	tcflag_t c_lflag;
	cc_t c_cc[NCCS];
};

/* c_lflag bits the library reads: canonical input, and echo. */
#define ICANON 0x0002
#define ECHO 0x0008

#define TCSANOW 0
#define TCSADRAIN 1
#define TCSAFLUSH 2

int tcgetattr(int fd, struct termios *t);
int tcsetattr(int fd, int actions, const struct termios *t);
void cfmakeraw(struct termios *t);

#endif
