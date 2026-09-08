/*
mman.c -- memory maps over this tree's segments.

An anonymous map is a fresh run of pages from `segalloc`, and `munmap`
gives one back with `segdetach`. A private file map allocates the run and
reads the file into it once, which is a compiler reading its input. A
shared file map is refused, ENODEV, the price section 8 names: no server
here maps a file into a client. `mprotect` answers success without
changing anything, because a program's own segments are already readable
and writable. See `docs/DEVTOOLS.md` section 8.
*/
#include "posix_internal.h"
#include <sys/mman.h>
#include <errno.h>
#include <unistd.h>

void *mmap(void *addr, size_t len, int prot, int flags, int fd, off_t off)
{
	(void)addr;
	(void)prot;
	if (len == 0) {
		errno = EINVAL;
		return MAP_FAILED;
	}
	if ((flags & MAP_SHARED) && fd >= 0) {
		errno = ENODEV; /* a shared file mapping, refused. */
		return MAP_FAILED;
	}
	long r = __vsyscall(SYS_SEGALLOC, (long)len, 0, 0, 0, 0, 0);
	if (r < 0) {
		errno = (int)(-r);
		return MAP_FAILED;
	}
	void *base = (void *)r;
	if (!(flags & MAP_ANONYMOUS) && fd >= 0) {
		/* A private file map: read the file into the run once. */
		char *p = (char *)base;
		size_t got = 0;
		while (got < len) {
			long n = __vsyscall(SYS_PREAD, fd, (long)(p + got), (long)(len - got), (long)off + (long)got, 0, 0);
			if (n <= 0) {
				break;
			}
			got += (size_t)n;
		}
	}
	return base;
}

int munmap(void *addr, size_t len)
{
	(void)len;
	return (int)__posix(__vsyscall(SYS_SEGDETACH, (long)addr, 0, 0, 0, 0, 0));
}

int mprotect(void *addr, size_t len, int prot)
{
	(void)addr;
	(void)len;
	(void)prot;
	return 0;
}

/*
Vectra shared buffers, the primitive the window store is built on. Not
POSIX: a program maps a buffer other processes can map by its id, so a
window's client and the draw server paint and composite the same pixels.
See `docs/DEVTOOLS.md` step 1.
*/
void *shmalloc_v(size_t bytes, unsigned long *id_out)
{
	long r = __vsyscall(SYS_SHMALLOC, (long)bytes, (long)id_out, 0, 0, 0, 0);
	if (r < 0) {
		errno = (int)(-r);
		return MAP_FAILED;
	}
	return (void *)r;
}

void *shmattach_v(unsigned long id)
{
	long r = __vsyscall(SYS_SHMATTACH, (long)id, 0, 0, 0, 0, 0);
	if (r < 0) {
		errno = (int)(-r);
		return MAP_FAILED;
	}
	return (void *)r;
}
