/*
process.c -- fork, exec, wait and exit, `docs/DEVTOOLS.md` section 8.

`fork` is `rfork(RFPROC|RFFDG)`, a child with a copy of the memory and the
descriptors. `execv` builds the argument block the kernel reads -- an Odin
string, a pointer and a length, per argument -- and calls `exec`.
`waitpid` is `await`, whose `pid status` line it parses, and `exit` is
`exits` with the number as text, so the two meet on a string.
*/
#include "posix_internal.h"
#include <errno.h>
#include <unistd.h>
#include <stdlib.h>
#include <string.h>

pid_t fork(void)
{
	/* RFPROC a child, RFFDG a copy of the descriptors. The memory is
	   copied because RFMEM is absent. */
	return (pid_t)__posix(__vsyscall(SYS_RFORK, RFPROC | RFFDG, 0, 0, 0, 0, 0));
}

/* argv_block turns a C `argv` into the kernel's array of Odin strings, in a
   static buffer bounded by the kernel's own `ARGV_MAX`. */
#define ARGV_MAX 64
static VString argv_store[ARGV_MAX];

static int build_argv(char *const argv[])
{
	int n = 0;
	if (argv != NULL) {
		for (; argv[n] != NULL && n < ARGV_MAX; n++) {
			argv_store[n].data = argv[n];
			argv_store[n].len = (long)strlen(argv[n]);
		}
	}
	return n;
}

int execv(const char *path, char *const argv[])
{
	int n = build_argv(argv);
	long r = __vsyscall(SYS_EXEC, (long)path, (long)strlen(path), (long)argv_store, n, 0, 0);
	/* exec returns only on failure. */
	errno = (int)(-r);
	return -1;
}

int execvp(const char *file, char *const argv[])
{
	/* No PATH search yet: the namespace's `/bin` is where a program is,
	   and a caller that wants a search binds one. */
	return execv(file, argv);
}

extern int putenv(char *nameval);

int execve(const char *path, char *const argv[], char *const envp[])
{
	/* The environment is a set of files under `/env`, shared across the
	   exec because the namespace is. So each `NAME=VALUE` is written there
	   before the exec, and the new program reads it with `getenv`. */
	if (envp != NULL) {
		for (int i = 0; envp[i] != NULL; i++) {
			putenv(envp[i]);
		}
	}
	return execv(path, argv);
}

pid_t waitpid(pid_t pid, int *status, int flags)
{
	(void)flags;
	char buf[64];
	long r = __vsyscall(SYS_AWAIT, pid <= 0 ? 0 : (long)pid, (long)buf, (long)sizeof(buf), 0, 0, 0);
	if (r < 0) {
		errno = (int)(-r);
		return -1;
	}
	/* The line is `pid status`. The status word is the exit number a child
	   gave `exit`, or a note's text; a number parses, and anything else is
	   a signal, reported as a non-zero low byte. */
	buf[r < (long)sizeof(buf) ? r : (long)sizeof(buf) - 1] = 0;
	int i = 0;
	long got = 0;
	while (buf[i] >= '0' && buf[i] <= '9') {
		got = got * 10 + (buf[i] - '0');
		i++;
	}
	while (buf[i] == ' ') {
		i++;
	}
	int code = 0;
	if (buf[i] >= '0' && buf[i] <= '9') {
		int v = 0;
		for (int j = i; buf[j] >= '0' && buf[j] <= '9'; j++) {
			v = v * 10 + (buf[j] - '0');
		}
		code = (v & 0xff) << 8; /* WEXITSTATUS reads the high byte. */
	} else if (buf[i] != 0) {
		code = 1; /* A word, not a number: a signal ended it. */
	}
	if (status != NULL) {
		*status = code;
	}
	return (pid_t)got;
}

pid_t wait(int *status)
{
	return waitpid(-1, status, 0);
}

pid_t getppid(void)
{
	/* A first cut: the parent is not read from `/proc/n/status` yet. */
	return 0;
}

void exit(int code)
{
	/* The number as text, so a parent's `waitpid` parses it back. */
	char msg[16];
	int n = 0;
	unsigned int v = (unsigned int)(code < 0 ? -code : code);
	char tmp[12];
	int t = 0;
	if (code < 0) {
		msg[n++] = '-';
	}
	do {
		tmp[t++] = (char)('0' + v % 10);
		v /= 10;
	} while (v);
	while (t > 0) {
		msg[n++] = tmp[--t];
	}
	msg[n] = 0;
	__vsyscall(SYS_EXITS, (long)msg, n, 0, 0, 0, 0);
	for (;;) {
	}
}

void _exit(int code)
{
	char msg[16];
	int n = 0;
	unsigned int v = (unsigned int)(code < 0 ? -code : code);
	char tmp[12];
	int t = 0;
	do {
		tmp[t++] = (char)('0' + v % 10);
		v /= 10;
	} while (v);
	while (t > 0) {
		msg[n++] = tmp[--t];
	}
	msg[n] = 0;
	__vsyscall(SYS_EXITS, (long)msg, n, 0, 0, 0, 0);
	for (;;) {
	}
}

void abort(void)
{
	__vsyscall(SYS_EXITS, (long)"abort", 5, 0, 0, 0, 0);
	for (;;) {
	}
}
