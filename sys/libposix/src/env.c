/*
env.c -- the environment as files under `/env`, `docs/DEVTOOLS.md` section 8.

A variable is a file: `getenv` reads `/env/NAME`, `setenv` writes it, and
`execve` writes each of its `envp` entries before the exec, so the new
program reads them from the same `/env` it shares. The value has no
trailing NUL on disk; a read gives its bytes and this adds the terminator
in a small static buffer, one variable at a time, which is what `getenv`'s
contract allows.
*/
#include "posix_internal.h"
#include <stdlib.h>
#include <string.h>
#include <fcntl.h>
#include <unistd.h>

static char getenv_buf[256];

static int env_path(char *path, const char *name)
{
	int n = 0;
	const char *pre = "/env/";
	for (int i = 0; pre[i]; i++) {
		path[n++] = pre[i];
	}
	for (int i = 0; name[i] && n < 200; i++) {
		path[n++] = name[i];
	}
	path[n] = 0;
	return n;
}

char *getenv(const char *name)
{
	char path[224];
	env_path(path, name);
	int fd = open(path, O_RDONLY);
	if (fd < 0) {
		return NULL;
	}
	long n = read(fd, getenv_buf, sizeof(getenv_buf) - 1);
	close(fd);
	if (n < 0) {
		return NULL;
	}
	getenv_buf[n] = 0;
	return getenv_buf;
}

int setenv(const char *name, const char *value, int overwrite)
{
	char path[224];
	env_path(path, name);
	if (!overwrite) {
		int fd = open(path, O_RDONLY);
		if (fd >= 0) {
			close(fd);
			return 0;
		}
	}
	int fd = open(path, O_CREAT | O_WRONLY | O_TRUNC, 0666);
	if (fd < 0) {
		return -1;
	}
	long len = (long)strlen(value);
	long w = write(fd, value, len);
	close(fd);
	return w == len ? 0 : -1;
}

int unsetenv(const char *name)
{
	(void)name;
	/* A first cut: an empty value stands for unset, since `/env` has no
	   remove in the library yet. */
	return setenv(name, "", 1);
}

int putenv(char *nameval)
{
	/* `NAME=VALUE` split at the first `=`. */
	int eq = -1;
	for (int i = 0; nameval[i]; i++) {
		if (nameval[i] == '=') {
			eq = i;
			break;
		}
	}
	if (eq < 0) {
		return -1;
	}
	static char namebuf[128];
	int i = 0;
	for (; i < eq && i < (int)sizeof(namebuf) - 1; i++) {
		namebuf[i] = nameval[i];
	}
	namebuf[i] = 0;
	return setenv(namebuf, nameval + eq + 1, 1);
}
