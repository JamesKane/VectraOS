/*
unistd.h -- the POSIX process and file calls the library maps to the door.

Each is one shape in `docs/DEVTOOLS.md` section 8's table. `read`, `write`,
`close` and `lseek` are the calls one to one; `fork` is `rfork`; `execv`
and `execvp` are `exec`; `getpid` and `getcwd` are theirs. The whence
values for `lseek` are the standard three.
*/
#ifndef UNISTD_H
#define UNISTD_H

#include <sys/types.h>

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

#define STDIN_FILENO 0
#define STDOUT_FILENO 1
#define STDERR_FILENO 2

ssize_t read(int fd, void *buf, size_t n);
ssize_t write(int fd, const void *buf, size_t n);
int close(int fd);
off_t lseek(int fd, off_t off, int whence);
int dup(int fd);
int dup2(int oldfd, int newfd);
int pipe(int fds[2]);

pid_t fork(void);
int execv(const char *path, char *const argv[]);
int execvp(const char *file, char *const argv[]);
int execve(const char *path, char *const argv[], char *const envp[]);
pid_t getpid(void);
pid_t getppid(void);
int chdir(const char *path);
char *getcwd(char *buf, size_t size);
unsigned int sleep(unsigned int seconds);
int usleep(unsigned long usec);
int isatty(int fd);
int getuid(void);
int geteuid(void);
int getgid(void);
void _exit(int code) __attribute__((noreturn));

#endif
