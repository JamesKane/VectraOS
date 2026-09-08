/*
posixthreads -- four threads and a mutex, `docs/DEVTOOLS.md` step 7.

Each thread adds to a shared counter many times under one mutex. If the
mutex holds, the total is exactly the threads times the additions; a race
would lose some. Each thread also sets its own `errno`, and checks it kept
its value across the others' runs, which proves the thread-local storage
is per thread. The program exits `0` when both held.
*/
#include <stdio.h>
#include <stdlib.h>
#include <errno.h>
#include <pthread.h>

#define THREADS 4
#define ADDS 2000

static long counter = 0;
static pthread_mutex_t lock = PTHREAD_MUTEX_INITIALIZER;

static void *worker(void *arg)
{
	long id = (long)arg;
	errno = 1000 + (int)id;
	for (int i = 0; i < ADDS; i++) {
		pthread_mutex_lock(&lock);
		counter++;
		pthread_mutex_unlock(&lock);
	}
	/* errno is this thread's own: the others set theirs, and this kept
	   the value it wrote. */
	if (errno != 1000 + (int)id) {
		return (void *)1;
	}
	return (void *)0;
}

int main(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	pthread_t t[THREADS];
	for (long i = 0; i < THREADS; i++) {
		if (pthread_create(&t[i], NULL, worker, (void *)i) != 0) {
			printf("posixthreads: create %d failed\n", (int)i);
			exit(1);
		}
	}
	long bad = 0;
	for (int i = 0; i < THREADS; i++) {
		void *r = NULL;
		pthread_join(t[i], &r);
		bad += (long)r;
	}
	if (bad != 0) {
		printf("posixthreads: a thread lost its errno\n");
		exit(2);
	}
	if (counter != (long)THREADS * ADDS) {
		printf("posixthreads: counter %d, wanted %d\n", (int)counter, THREADS * ADDS);
		exit(3);
	}
	printf("posixthreads: %d threads added under a mutex to %d\n", THREADS, (int)counter);
	exit(0);
}
