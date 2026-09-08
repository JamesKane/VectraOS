/*
sys/wait.h -- `waitpid` and the macros that read its status.

The status the library packs is the child's exit number in the high byte,
so `WEXITSTATUS` reads it. A child ended by a note, not a number, has a
non-zero low byte, which `WIFSIGNALED` reports. See `docs/DEVTOOLS.md`
section 8.
*/
#ifndef SYS_WAIT_H
#define SYS_WAIT_H

#include <sys/types.h>

pid_t wait(int *status);
pid_t waitpid(pid_t pid, int *status, int flags);

#define WNOHANG 1

#define WIFEXITED(s) (((s) & 0xff) == 0)
#define WEXITSTATUS(s) (((s) >> 8) & 0xff)
#define WIFSIGNALED(s) (((s) & 0xff) != 0)
#define WTERMSIG(s) ((s) & 0xff)

#endif
