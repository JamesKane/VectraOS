/*
signal.h -- catching a note as a signal, `docs/DEVTOOLS.md` section 8.

A signal is Plan 9's note under a number. `signal` registers a handler and
arms `notify`; when a note arrives, a table turns its text into a number
and calls the handler. `kill` writes the signal's name to the target's
`/proc/n/note`. The numbers are Linux's, the ones a program expects.
*/
#ifndef SIGNAL_H
#define SIGNAL_H

#include <sys/types.h>

#define SIGHUP 1
#define SIGINT 2
#define SIGQUIT 3
#define SIGILL 4
#define SIGABRT 6
#define SIGFPE 8
#define SIGKILL 9
#define SIGSEGV 11
#define SIGPIPE 13
#define SIGALRM 14
#define SIGTERM 15
#define NSIG 32

typedef void (*sighandler_t)(int);

#define SIG_DFL ((sighandler_t)0)
#define SIG_IGN ((sighandler_t)1)
#define SIG_ERR ((sighandler_t)-1)

sighandler_t signal(int sig, sighandler_t handler);
int raise(int sig);
int kill(pid_t pid, int sig);

#endif
