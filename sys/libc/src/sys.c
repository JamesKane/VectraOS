/*
sys.c -- the system calls a C program makes, each one call to the door.

The wrappers pass the kernel's answer through: a count or a descriptor at
zero or more, `-errno` below. Nothing here interprets an error, the way
`sys/libuser` does not, because a C program reads the number the same way
the kernel wrote it. See `vlibc.h`.
*/
#include "vlibc.h"

long vwrite(int fd, const void *buf, long n)
{
	return __vsyscall(SYS_WRITE, fd, (long)buf, n, 0, 0, 0);
}

long vread(int fd, void *buf, long n)
{
	return __vsyscall(SYS_READ, fd, (long)buf, n, 0, 0, 0);
}

int vopen(const char *path, long mode)
{
	return (int)__vsyscall(SYS_OPEN, (long)path, (long)strlen(path), mode, 0, 0, 0);
}

int vclose(int fd)
{
	return (int)__vsyscall(SYS_CLOSE, fd, 0, 0, 0, 0, 0);
}

long vseek(int fd, long off)
{
	return __vsyscall(SYS_SEEK, fd, off, 0, 0, 0, 0);
}

void vsleep(long ms)
{
	__vsyscall(SYS_SLEEP, ms, 0, 0, 0, 0, 0);
}

long vgetpid(void)
{
	return __vsyscall(SYS_GETPID, 0, 0, 0, 0, 0, 0);
}

void exits(const char *msg)
{
	long n = msg ? (long)strlen(msg) : 0;
	__vsyscall(SYS_EXITS, (long)msg, n, 0, 0, 0, 0);
	for (;;) {
	}
}

void _exit(int code)
{
	__vsyscall(SYS_EXIT, code, 0, 0, 0, 0, 0);
	for (;;) {
	}
}

long vtls(void *tp)
{
	return __vsyscall(SYS_TLS, (long)tp, 0, 0, 0, 0, 0);
}
