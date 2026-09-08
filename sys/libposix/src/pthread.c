/*
pthread.c -- threads and a mutex over this tree's process calls.

A thread is a process that shares its maker's memory, `rfork(RFPROC|RFMEM)`
onto a stack of its own, which `vectra_proc_fork` from `sys/libthread`
sets up. The maker allocates the stack and the thread's own thread-local
block first, so the thread itself allocates nothing before it has an
`errno`. A mutex is a semaphore on a word, one `semacquire` to lock and
one `semrelease` to unlock. See `docs/DEVTOOLS.md` section 8.
*/
#include "posix_internal.h"
#include <pthread.h>
#include <stdlib.h>

extern usize __tls_block_size(void);
extern void *__tls_init(void *block);
extern long vtls_set(void *tp);

/* From `sys/libthread`'s `thread_<arch>.S`, linked into every program:
   rfork by `nr` and `flags`, the child moved onto `sp` and calling
   `entry(arg)` there. */
extern long vectra_proc_fork(unsigned long nr, unsigned long flags, unsigned long sp,
	void (*entry)(void *), void *arg);

#define THREAD_STACK (64 * 1024)

struct pthread {
	long pid;
	void *stack;
	void *tls;
	long done; /* a semaphore the thread releases when it finishes */
	void *(*start)(void *);
	void *arg;
	void *ret;
};

static void sem_get(long *s)
{
	while (__vsyscall(SYS_SEMACQUIRE, (long)s, 1, 0, 0, 0, 0) < 0) {
		/* EINTR: a note arrived; ask again. */
	}
}

static void sem_put(long *s, long n)
{
	__vsyscall(SYS_SEMRELEASE, (long)s, n, 0, 0, 0, 0);
}

static void thread_entry(void *arg)
{
	struct pthread *t = (struct pthread *)arg;
	/* This thread's own thread pointer, so its `errno` is its own. */
	vtls_set(__tls_init(t->tls));
	t->ret = t->start(t->arg);
	sem_put(&t->done, 1);
	/* The thread's process ends; the memory stays for the others. */
	__vsyscall(SYS_EXITS, (long)"0", 1, 0, 0, 0, 0);
	for (;;) {
	}
}

int pthread_create(pthread_t *tp, const pthread_attr_t *attr, void *(*start)(void *), void *arg)
{
	(void)attr;
	struct pthread *t = (struct pthread *)malloc(sizeof(struct pthread));
	if (t == NULL) {
		return -1;
	}
	t->stack = malloc(THREAD_STACK);
	t->tls = malloc(__tls_block_size());
	if (t->stack == NULL || t->tls == NULL) {
		return -1;
	}
	t->done = 0;
	t->start = start;
	t->arg = arg;
	t->ret = NULL;
	unsigned long sp = ((unsigned long)t->stack + THREAD_STACK) & ~(unsigned long)15;
	long pid = vectra_proc_fork(SYS_RFORK, RFPROC | RFMEM, sp, thread_entry, t);
	if (pid < 0) {
		return -1;
	}
	t->pid = pid;
	*tp = t;
	return 0;
}

int pthread_join(pthread_t t, void **retval)
{
	sem_get(&t->done);
	if (retval != NULL) {
		*retval = t->ret;
	}
	/* Reap the thread's process, now that it has finished. */
	__vsyscall(SYS_WAIT, t->pid, 0, 0, 0, 0, 0);
	return 0;
}

pthread_t pthread_self(void)
{
	return NULL;
}

int pthread_mutex_init(pthread_mutex_t *m, const pthread_mutexattr_t *attr)
{
	(void)attr;
	m->sem = 1;
	return 0;
}

int pthread_mutex_destroy(pthread_mutex_t *m)
{
	(void)m;
	return 0;
}

int pthread_mutex_lock(pthread_mutex_t *m)
{
	sem_get(&m->sem);
	return 0;
}

int pthread_mutex_unlock(pthread_mutex_t *m)
{
	sem_put(&m->sem, 1);
	return 0;
}
