// SPDX-License-Identifier: BSD-3-Clause

// <sys/wait.h> (POSIX XSH): waitpid for a child posix_spawn started
// (natively FDIO's, system/fdio/native/Spawn.swift), with Linux's status
// encoding. C's only, as <spawn.h> is.

#pragma once

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define WNOHANG 1

// A status: the exit code in bits 8 to 15; a process is never stopped or
// killed by a signal (there are none), only exits.
#define WIFEXITED(status) (((status) & 0x7f) == 0)
#define WEXITSTATUS(status) (((status) >> 8) & 0xff)
#define WIFSIGNALED(status) 0
#define WTERMSIG(status) 0

pid_t waitpid(pid_t pid, int *status, int options);

#ifdef __cplusplus
}
#endif
