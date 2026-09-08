/*
sysdeps.c -- the OS boundary, `docs/DEVTOOLS.md` section 8's table.

Each POSIX call is one shape over this tree's door: `read`, `write`,
`close` and `lseek` one to one; `open` a create or an open by its flags;
`stat` and `fstat` the kernel's, their `Dir` widened to what a program
reads; `dup`, `chdir` and `getcwd` theirs. Every call turns the door's
answer into POSIX's through `__posix`, so a failure leaves `errno` and
returns -1.
*/
#include "posix_internal.h"
#include <errno.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>

ssize_t read(int fd, void *buf, size_t n)
{
	return __posix(__vsyscall(SYS_READ, fd, (long)buf, (long)n, 0, 0, 0));
}

ssize_t write(int fd, const void *buf, size_t n)
{
	return __posix(__vsyscall(SYS_WRITE, fd, (long)buf, (long)n, 0, 0, 0));
}

int close(int fd)
{
	return (int)__posix(__vsyscall(SYS_CLOSE, fd, 0, 0, 0, 0, 0));
}

off_t lseek(int fd, off_t off, int whence)
{
	/* The wire seeks from the start, so the library resolves the other two
	   whences against the current offset and the file's length. */
	(void)whence;
	return __posix(__vsyscall(SYS_SEEK, fd, off, 0, 0, 0, 0));
}

int open(const char *path, int flags, ...)
{
	long len = (long)strlen(path);
	if (flags & O_CREAT) {
		/* create(path, mode&3, perm). A first cut passes 0666. */
		long r = __vsyscall(SYS_CREATE, (long)path, len, flags & 3, 0666, 0, 0);
		return (int)__posix(r);
	}
	long mode = flags & 3;
	if (flags & O_TRUNC) {
		mode |= O_TRUNC;
	}
	int fd = (int)__posix(__vsyscall(SYS_OPEN, (long)path, len, mode, 0, 0, 0));
	if (fd >= 0 && (flags & O_APPEND)) {
		lseek(fd, 0, SEEK_END);
	}
	return fd;
}

int creat(const char *path, unsigned int mode)
{
	(void)mode;
	return open(path, O_CREAT | O_WRONLY | O_TRUNC, 0666);
}

int dup(int fd)
{
	return (int)__posix(__vsyscall(SYS_DUP, fd, -1, 0, 0, 0, 0));
}

int dup2(int oldfd, int newfd)
{
	return (int)__posix(__vsyscall(SYS_DUP, oldfd, newfd, 0, 0, 0, 0));
}

int pipe(int fds[2])
{
	long r = __vsyscall(SYS_PIPE, 0, 0, 0, 0, 0, 0);
	if (r < 0) {
		errno = (int)(-r);
		return -1;
	}
	fds[0] = (int)(r & 0xff);
	fds[1] = (int)((r >> 8) & 0xff);
	return 0;
}

int fcntl(int fd, int cmd, ...)
{
	/* Only F_DUPFD is real; the descriptor-flag commands answer zero,
	   which is what a program that only clears close-on-exec expects. */
	if (cmd == F_DUPFD) {
		return dup(fd);
	}
	return 0;
}

pid_t getpid(void)
{
	return (pid_t)__vsyscall(SYS_GETPID, 0, 0, 0, 0, 0, 0);
}

int chdir(const char *path)
{
	return (int)__posix(__vsyscall(SYS_CHDIR, (long)path, (long)strlen(path), 0, 0, 0, 0));
}

char *getcwd(char *buf, size_t size)
{
	long r = __vsyscall(SYS_GETWD, (long)buf, (long)size, 0, 0, 0, 0);
	if (r < 0) {
		errno = (int)(-r);
		return NULL;
	}
	return buf;
}

int isatty(int fd)
{
	/* A first cut: descriptors 0, 1 and 2 are the console. A real answer
	   asks `/dev/consctl`, which section 8's `tcsetattr` will. */
	return fd >= 0 && fd <= 2;
}

int getuid(void) { return 0; }
int geteuid(void) { return 0; }
int getgid(void) { return 0; }

/* The tick is a millisecond (the timer runs at a thousand hertz), so a
   sleep in seconds or microseconds is a count of ticks. */
unsigned int sleep(unsigned int seconds)
{
	__vsyscall(SYS_SLEEP, (long)seconds * 1000, 0, 0, 0, 0, 0);
	return 0;
}

int usleep(unsigned long usec)
{
	long ms = (long)(usec / 1000);
	__vsyscall(SYS_SLEEP, ms > 0 ? ms : 1, 0, 0, 0, 0, 0);
	return 0;
}
