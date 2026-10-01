// vx9pserve: serves a directory over 9P2000 (with vx-9p's own framework,
// docs/04 §5 M3), for VectraOS to mount: `mount tcp!10.0.2.2!5640 /n/host`.
//
//   vx9pserve --listen ADDR:PORT DIR   one process per connection
//   vx9pserve --stdio DIR              one connection, on stdin and stdout
//                                      (QEMU's guestfwd=...-cmd: runs it so)
//
// Messages are framed as 9P frames them: each begins with its size. A
// message too big for the msize, or too broken to answer, ends the
// connection.

#define _GNU_SOURCE // before any system header: fs.c needs openat and O_PATH
#include <arpa/inet.h>
#include <netinet/in.h>
#include <signal.h>
#include <stdio.h>
#include <sys/socket.h>
#include <sys/wait.h>

#include "fs.c"

static constexpr uint32_t MSIZE = 65536;

static bool read_all(int fd, uint8_t *buf, size_t len) {
  for (size_t got = 0; got < len;) {
    ssize_t n = read(fd, buf + got, len - got);
    if (n <= 0) {
      if (n < 0 && errno == EINTR) continue;
      return false;
    }
    got += (size_t)n;
  }
  return true;
}

static bool write_all(int fd, const uint8_t *buf, size_t len) {
  for (size_t done = 0; done < len;) {
    ssize_t n = write(fd, buf + done, len - done);
    if (n <= 0) {
      if (n < 0 && errno == EINTR) continue;
      return false;
    }
    done += (size_t)n;
  }
  return true;
}

// Serves one connection until it ends.
static int serve(const char *dir, int in, int out) {
  static hostfs h;
  static p9_server s;
  static uint8_t req[MSIZE], resp[MSIZE];
  if (!hostfs_init(&h, &s, dir, MSIZE)) {
    fprintf(stderr, "vx9pserve: cannot open %s\n", dir);
    return 1;
  }
  for (;;) {
    if (!read_all(in, req, 4)) return 0; // the client hung up
    uint32_t size =
        (uint32_t)req[0] | (uint32_t)req[1] << 8 | (uint32_t)req[2] << 16 | (uint32_t)req[3] << 24;
    if (size < 7 || size > MSIZE || !read_all(in, req + 4, size - 4)) return 1;
    size_t n = p9_serve(&s, req, size, resp, sizeof resp);
    if (n == 0 || n == P9_DEFER) return 1; // nothing here waits, so DEFER cannot happen
    if (!write_all(out, resp, n)) return 0;
  }
}

static int listen_on(const char *where, const char *dir) {
  char host[64];
  const char *colon = strrchr(where, ':');
  if (!colon || (size_t)(colon - where) >= sizeof host) return 2;
  memcpy(host, where, (size_t)(colon - where));
  host[colon - where] = 0;
  struct sockaddr_in a = {.sin_family = AF_INET, .sin_port = htons((uint16_t)atoi(colon + 1))};
  if (inet_pton(AF_INET, host, &a.sin_addr) != 1) return 2;
  int s = socket(AF_INET, SOCK_STREAM | SOCK_CLOEXEC, 0), one = 1;
  setsockopt(s, SOL_SOCKET, SO_REUSEADDR, &one, sizeof one);
  if (s < 0 || bind(s, (struct sockaddr *)&a, sizeof a) != 0 || listen(s, 16) != 0) {
    perror("vx9pserve: listen");
    return 1;
  }
  signal(SIGCHLD, SIG_IGN); // children are reaped by the kernel
  for (;;) {
    int c = accept(s, nullptr, nullptr);
    if (c < 0) {
      if (errno == EINTR) continue;
      perror("vx9pserve: accept");
      return 1;
    }
    pid_t pid = fork();
    if (pid == 0) {
      close(s);
      _exit(serve(dir, c, c));
    }
    close(c);
  }
}

int main(int argc, char **argv) {
  if (argc == 3 && strcmp(argv[1], "--stdio") == 0) return serve(argv[2], 0, 1);
  if (argc == 4 && strcmp(argv[1], "--listen") == 0) return listen_on(argv[2], argv[3]);
  fprintf(stderr, "usage: vx9pserve --listen ADDR:PORT DIR | --stdio DIR\n");
  return 2;
}
