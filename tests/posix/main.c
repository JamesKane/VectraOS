/*
posixtest -- the POSIX library's shapes, `docs/DEVTOOLS.md` step 7.

It prints through `printf`, moves bytes through a `pipe`, and runs
`posixchild` through `fork`, `execv` and `waitpid`, checking the number
the child exited with comes back. It exits `ok` when every shape held,
or the name of the first that did not, which the self-test reads.
*/
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>
#include <sys/wait.h>
#include <sys/mman.h>
#include <time.h>
#include <poll.h>
#include <sys/ioctl.h>

int main(int argc, char **argv)
{
	(void)argc;
	(void)argv;
	printf("posixtest: hello through printf, pid %d\n", getpid());

	/* A pipe: write four bytes, read them back. */
	int fds[2];
	if (pipe(fds) != 0) {
		printf("posixtest: pipe failed\n");
		exit(1);
	}
	if (write(fds[1], "ping", 4) != 4) {
		exit(2);
	}
	char buf[8];
	long n = read(fds[0], buf, sizeof(buf));
	if (n != 4 || memcmp(buf, "ping", 4) != 0) {
		printf("posixtest: pipe read %d bytes\n", (int)n);
		exit(3);
	}
	close(fds[0]);
	close(fds[1]);

	/* fork, exec the child, wait for its number. */
	pid_t pid = fork();
	if (pid < 0) {
		exit(4);
	}
	if (pid == 0) {
		char *cargv[3];
		cargv[0] = "posixchild";
		cargv[1] = "from-fork";
		cargv[2] = NULL;
		char *cenv[2];
		cenv[0] = "PXCHILD=ok";
		cenv[1] = NULL;
		execve("/bin/posixchild", cargv, cenv);
		_exit(99); /* exec returned: it failed. */
	}
	int status = 0;
	pid_t got = waitpid(pid, &status, 0);
	if (got != pid) {
		printf("posixtest: waitpid returned %d, wanted %d\n", (int)got, (int)pid);
		exit(5);
	}
	if (!WIFEXITED(status) || WEXITSTATUS(status) != 7) {
		printf("posixtest: child status %x\n", status);
		exit(6);
	}

	/* An anonymous map: write a pattern across a page, read it back. */
	long *page = (long *)mmap(NULL, 4096, PROT_READ | PROT_WRITE,
		MAP_ANONYMOUS | MAP_PRIVATE, -1, 0);
	if (page == MAP_FAILED) {
		exit(7);
	}
	for (int i = 0; i < 512; i++) {
		page[i] = i * 3;
	}
	for (int i = 0; i < 512; i++) {
		if (page[i] != i * 3) {
			exit(8);
		}
	}
	munmap(page, 4096);

	/* The clock: two reads a sleep apart, the second not before the first. */
	struct timespec a, b;
	clock_gettime(CLOCK_REALTIME, &a);
	struct timespec nap = {0, 5000000};
	nanosleep(&nap, NULL);
	clock_gettime(CLOCK_REALTIME, &b);
	long dsec = (long)(b.tv_sec - a.tv_sec);
	if (dsec < 0 || (dsec == 0 && b.tv_nsec < a.tv_nsec)) {
		exit(9);
	}

	/* poll a readable pipe: a byte waiting, POLLIN reported. */
	int pf[2];
	if (pipe(pf) != 0) {
		exit(10);
	}
	write(pf[1], "x", 1);
	struct pollfd p = {pf[0], POLLIN, 0};
	if (poll(&p, 1, 0) < 1 || !(p.revents & POLLIN)) {
		exit(11);
	}
	close(pf[0]);
	close(pf[1]);

	/* A shared buffer across a fork: the parent writes, a child that maps
	   it by id sees the write and writes back, and the parent sees that.
	   The two are separate address spaces sharing the same frames. */
	unsigned long shid = 0;
	unsigned char *shbuf = (unsigned char *)shmalloc_v(4096, &shid);
	if (shbuf == MAP_FAILED) {
		exit(15);
	}
	shbuf[0] = 0xAB;
	shbuf[1] = 0;
	pid_t sp = fork();
	if (sp < 0) {
		exit(16);
	}
	if (sp == 0) {
		unsigned char *c = (unsigned char *)shmattach_v(shid);
		if (c == MAP_FAILED || c[0] != 0xAB) {
			_exit(51);
		}
		c[1] = 0xCD;
		_exit(0);
	}
	int sst = 0;
	waitpid(sp, &sst, 0);
	if (!WIFEXITED(sst) || WEXITSTATUS(sst) != 0 || shbuf[1] != 0xCD) {
		exit(17);
	}

	/* The environment: set a variable, read it back. */
	setenv("PXVAR", "42", 1);
	const char *pv = getenv("PXVAR");
	if (pv == NULL || strcmp(pv, "42") != 0) {
		exit(12);
	}

	/* The terminal, read-only so the shared console mode is not touched:
	   a standard descriptor is a tty, and the window-size request is
	   ENOTTY on a console that is no window. */
	if (!isatty(0) || !isatty(1)) {
		exit(13);
	}
	struct winsize ws;
	if (ioctl(1, TIOCGWINSZ, &ws) != -1) {
		exit(14);
	}

	printf("posixtest: pipe, fork, exec, wait, mmap, clock, poll, env and tty all held\n");
	exit(0);
}
