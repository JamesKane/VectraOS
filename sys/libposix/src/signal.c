/*
signal.c -- signals over notes, `docs/DEVTOOLS.md` section 8.

`signal` stores a handler and, the first time, arms `notify`. When a note
is delivered, `dispatch` turns its text into a signal number by the table
the plan names -- `interrupt` is SIGINT, a `kill` is SIGTERM, a `sys:`
trap is SIGSEGV -- and calls the handler, then resumes the program.
`kill` writes the signal's name to the target's `/proc/n/note`, and
`raise` sends to oneself. The numbers are Linux's.
*/
#include "posix_internal.h"
#include <signal.h>
#include <string.h>
#include <errno.h>

static sighandler_t handlers[NSIG];
static int armed = 0;

/* has reports whether `note` contains `word`. */
static int has(const char *note, const char *word)
{
	usize wl = 0;
	while (word[wl]) {
		wl++;
	}
	for (usize i = 0; note[i]; i++) {
		usize j = 0;
		while (j < wl && note[i + j] == word[j]) {
			j++;
		}
		if (j == wl) {
			return 1;
		}
	}
	return 0;
}

static int note_to_signal(const char *note)
{
	if (has(note, "interrupt")) {
		return SIGINT;
	}
	if (has(note, "hangup")) {
		return SIGHUP;
	}
	if (has(note, "alarm")) {
		return SIGALRM;
	}
	if (has(note, "kill")) {
		return SIGTERM;
	}
	if (has(note, "trap") || has(note, "sys:")) {
		return SIGSEGV;
	}
	return SIGTERM;
}

static const char *signal_to_note(int sig)
{
	switch (sig) {
	case SIGINT: return "interrupt";
	case SIGHUP: return "hangup";
	case SIGALRM: return "alarm";
	case SIGSEGV: return "sys: trap";
	default: return "kill";
	}
}

/* dispatch is `notify`'s handler: it runs the program's, then resumes. */
static void dispatch(void *ureg, const char *note)
{
	(void)ureg;
	int sig = note_to_signal(note);
	sighandler_t h = (sig >= 0 && sig < NSIG) ? handlers[sig] : SIG_DFL;
	if (h != SIG_DFL && h != SIG_IGN && h != SIG_ERR) {
		h(sig);
		__vsyscall(SYS_NOTED, NCONT, 0, 0, 0, 0, 0);
	}
	if (h == SIG_IGN) {
		__vsyscall(SYS_NOTED, NCONT, 0, 0, 0, 0, 0);
	}
	/* No handler, or the default: the note's default action, an ending. */
	__vsyscall(SYS_NOTED, NDFLT, 0, 0, 0, 0, 0);
}

sighandler_t signal(int sig, sighandler_t handler)
{
	if (sig < 0 || sig >= NSIG) {
		errno = EINVAL;
		return SIG_ERR;
	}
	if (!armed) {
		__vsyscall(SYS_NOTIFY, (long)dispatch, 0, 0, 0, 0, 0);
		armed = 1;
	}
	sighandler_t old = handlers[sig];
	handlers[sig] = handler;
	return old;
}

int kill(pid_t pid, int sig)
{
	const char *name = signal_to_note(sig);
	char path[48];
	int n = 0;
	const char *pre = "/proc/";
	for (int i = 0; pre[i]; i++) {
		path[n++] = pre[i];
	}
	/* the pid, in decimal */
	char tmp[12];
	int t = 0;
	unsigned int v = (unsigned int)pid;
	if (v == 0) {
		tmp[t++] = '0';
	}
	while (v) {
		tmp[t++] = (char)('0' + v % 10);
		v /= 10;
	}
	while (t > 0) {
		path[n++] = tmp[--t];
	}
	const char *suf = "/note";
	for (int i = 0; suf[i]; i++) {
		path[n++] = suf[i];
	}
	path[n] = 0;

	int fd = (int)__vsyscall(SYS_OPEN, (long)path, n, 1 /* O_WRONLY */, 0, 0, 0);
	if (fd < 0) {
		errno = (int)(-fd);
		return -1;
	}
	long wl = (long)strlen(name);
	long w = __vsyscall(SYS_WRITE, fd, (long)name, wl, 0, 0, 0);
	__vsyscall(SYS_CLOSE, fd, 0, 0, 0, 0, 0);
	if (w != wl) {
		errno = EIO;
		return -1;
	}
	return 0;
}

int raise(int sig)
{
	pid_t self = (pid_t)__vsyscall(SYS_GETPID, 0, 0, 0, 0, 0, 0);
	return kill(self, sig);
}
