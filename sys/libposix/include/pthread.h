/*
pthread.h -- threads and a mutex, `docs/DEVTOOLS.md` section 8.

A thread is `rfork(RFPROC|RFMEM)` onto a stack of its own with a
thread-local block of its own, so two threads share memory but not
`errno`. A mutex is a semaphore on a word, `semacquire` and `semrelease`,
which is the futex the plan names. This is the subset the section 8 test
uses; condition variables and the attributes come with a program that
needs them.
*/
#ifndef PTHREAD_H
#define PTHREAD_H

#include <sys/types.h>

typedef struct pthread *pthread_t;

typedef struct {
	long sem;
} pthread_mutex_t;

typedef struct {
	int unused;
} pthread_attr_t;
typedef struct {
	int unused;
} pthread_mutexattr_t;

#define PTHREAD_MUTEX_INITIALIZER {1}

int pthread_create(pthread_t *t, const pthread_attr_t *attr, void *(*start)(void *), void *arg);
int pthread_join(pthread_t t, void **retval);
pthread_t pthread_self(void);

int pthread_mutex_init(pthread_mutex_t *m, const pthread_mutexattr_t *attr);
int pthread_mutex_destroy(pthread_mutex_t *m);
int pthread_mutex_lock(pthread_mutex_t *m);
int pthread_mutex_unlock(pthread_mutex_t *m);

#endif
