/*
sys/mman.h -- memory maps over segments, `docs/DEVTOOLS.md` section 8.

An anonymous map is `segalloc`, a run of fresh pages, and `munmap` is
`segdetach`. A private file map is a run read from the file once, which is
what a compiler's input wants. A shared file map is refused with ENODEV:
no server here maps a file into a client, and LLVM does not need it.
*/
#ifndef SYS_MMAN_H
#define SYS_MMAN_H

#include <sys/types.h>

#define PROT_NONE 0
#define PROT_READ 1
#define PROT_WRITE 2
#define PROT_EXEC 4

#define MAP_SHARED 1
#define MAP_PRIVATE 2
#define MAP_ANONYMOUS 0x20
#define MAP_ANON 0x20
#define MAP_FIXED 0x10

#define MAP_FAILED ((void *)-1)

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off);
int munmap(void *addr, size_t len);
int mprotect(void *addr, size_t len, int prot);

/* Vectra shared buffers, docs/DEVTOOLS.md step 1: a buffer two processes
   map by an id. Not POSIX. */
void *shmalloc_v(size_t bytes, unsigned long *id_out);
void *shmattach_v(unsigned long id);

#endif
