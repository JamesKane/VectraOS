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
		execv("/bin/posixchild", cargv);
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

	printf("posixtest: pipe, fork, exec and wait all held\n");
	exit(0);
}
