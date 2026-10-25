// SPDX-License-Identifier: BSD-3-Clause

// <sys/mman.h> (POSIX XSH): anonymous mappings (natively the floor's,
// system/sys/floor/Posix.swift: a VMO mapped into the process's root
// VMAR), with Linux's values. C's only, as <ftw.h> is: the libc's module
// map is left as the toolchain's stdlib was built against it.

#pragma once

#include <stddef.h>
#include <sys/types.h>

#ifdef __cplusplus
extern "C" {
#endif

#define PROT_NONE 0
#define PROT_READ 1
#define PROT_WRITE 2
#define PROT_EXEC 4

#define MAP_SHARED 0x01
#define MAP_PRIVATE 0x02
#define MAP_FIXED 0x10
#define MAP_ANONYMOUS 0x20
#define MAP_ANON MAP_ANONYMOUS

#define MAP_FAILED ((void *)-1)

void *mmap(void *address, size_t length, int prot, int flags, int fd, off_t offset);
int munmap(void *address, size_t length);
int mprotect(void *address, size_t length, int prot);

#ifdef __cplusplus
}
#endif
