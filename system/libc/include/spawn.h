// SPDX-License-Identifier: BSD-3-Clause

// <spawn.h> (POSIX XSH): posix_spawn and posix_spawnp, a program started
// as a process of its own (natively FDIO's, system/fdio/native/Spawn.swift:
// Process.start, D80; there is no fork). C's only, as <ftw.h> is: the
// libc's module map is left as the toolchain's stdlib was built against
// it. No file actions or attributes yet: posix_spawn refuses any.

#pragma once

#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct {
  int __none;
} posix_spawn_file_actions_t;

typedef struct {
  int __none;
} posix_spawnattr_t;

int posix_spawn(pid_t *pid, const char *path, const posix_spawn_file_actions_t *actions,
                const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]);
int posix_spawnp(pid_t *pid, const char *file, const posix_spawn_file_actions_t *actions,
                 const posix_spawnattr_t *attributes, char *const argv[], char *const envp[]);
int posix_spawn_file_actions_init(posix_spawn_file_actions_t *actions);
int posix_spawn_file_actions_destroy(posix_spawn_file_actions_t *actions);
int posix_spawnattr_init(posix_spawnattr_t *attributes);
int posix_spawnattr_destroy(posix_spawnattr_t *attributes);

#ifdef __cplusplus
}
#endif
