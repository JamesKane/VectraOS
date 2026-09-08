/*
sys/ioctl.h -- the one request the library answers, `docs/DEVTOOLS.md`
section 8.

`TIOCGWINSZ` asks a window its size, from the window's `ctl`. Every other
request is `ENOTTY`, and a serial console, which is no window, is
`ENOTTY` for this one too, so a program falls back to a default size.
*/
#ifndef SYS_IOCTL_H
#define SYS_IOCTL_H

#define TIOCGWINSZ 0x5413

struct winsize {
	unsigned short ws_row;
	unsigned short ws_col;
	unsigned short ws_xpixel;
	unsigned short ws_ypixel;
};

int ioctl(int fd, unsigned long request, ...);

#endif
