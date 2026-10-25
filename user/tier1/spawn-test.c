// spawn-test: posix_spawn and waitpid (FDIO's, D80), which boot-cpu runs
// through rc, whose namespace has /bin. It starts floor-hello, which
// passes its own checks and exits 0, waits for it, and sees a missing
// program and an unknown child refused. C because it is C's interface.

#include <errno.h>
#include <spawn.h>
#include <stdio.h>
#include <sys/wait.h>
#include <unistd.h>

static int failures;

static void check(int ok, const char *what) {
  if (!ok) {
    printf("spawn-test: FAILED: %s\n", what);
    failures++;
  }
}

int main(void) {
  char *argv[] = {"floor-hello", NULL};
  pid_t pid = 0;
  int status = -1;
  check(posix_spawn(&pid, "/bin/floor-hello", NULL, NULL, argv, environ) == 0 && pid > 0, "posix_spawn");
  check(waitpid(pid, &status, 0) == pid && WIFEXITED(status) && WEXITSTATUS(status) == 0,
        "waitpid: floor-hello passed and exited 0");
  check(waitpid(pid, &status, 0) == -1 && errno == ECHILD, "waitpid again: ECHILD");
  pid_t again = 0;
  check(posix_spawnp(&again, "floor-hello", NULL, NULL, argv, environ) == 0 && again > 0 && again != pid,
        "posix_spawnp from /bin");
  check(waitpid(-1, &status, 0) == again && WEXITSTATUS(status) == 0, "waitpid(-1)");
  check(posix_spawn(&pid, "/bin/no-such-program", NULL, NULL, argv, environ) == ENOENT, "a missing program: ENOENT");
  posix_spawn_file_actions_t actions;
  posix_spawn_file_actions_init(&actions);
  check(posix_spawn(&pid, "/bin/floor-hello", &actions, NULL, argv, environ) == ENOSYS, "file actions: ENOSYS");
  printf(failures ? "spawn-test: FAILED\n" : "spawn-test: passed\n");
  return failures ? 1 : 0;
}
