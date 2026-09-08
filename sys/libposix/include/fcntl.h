/*
fcntl.h -- the open flags, and `fcntl` for descriptor duplication.

The flags a program passes `open`. The read/write mode maps to the wire's
`O_RDONLY`/`O_WRONLY`/`O_RDWR` one to one. `O_CREAT`, `O_TRUNC` and
`O_APPEND` are the library's, turned into a create or a seek in
`sysdeps`. See `docs/DEVTOOLS.md` section 8.
*/
#ifndef FCNTL_H
#define FCNTL_H

#define O_RDONLY 0
#define O_WRONLY 1
#define O_RDWR 2
#define O_CREAT 0x40
#define O_TRUNC 512
#define O_APPEND 0x400

#define F_DUPFD 0
#define F_GETFD 1
#define F_SETFD 2
#define F_GETFL 3
#define F_SETFL 4

int open(const char *path, int flags, ...);
int creat(const char *path, unsigned int mode);
int fcntl(int fd, int cmd, ...);

#endif
