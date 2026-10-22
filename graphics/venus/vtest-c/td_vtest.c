// SPDX-License-Identifier: BSD-3-Clause

// vtest's descriptor passing (D121; from todhchai's sdk/linux): in C
// because SCM_RIGHTS's control message is built with macros Swift can't
// import. Hosted only: the device never runs vtest.

#define _GNU_SOURCE
#include "td_vtest.h"

#include <errno.h>
#include <string.h>
#include <sys/socket.h>

int td_vtest_receive_fd(int socket) {
  char byte;
  struct iovec iov = {.iov_base = &byte, .iov_len = 1};
  union {
    struct cmsghdr header;
    char space[CMSG_SPACE(sizeof(int))];
  } control;
  struct msghdr msg = {.msg_iov = &iov, .msg_iovlen = 1, .msg_control = control.space, .msg_controllen = sizeof control.space};
  ssize_t n;
  do {
    n = recvmsg(socket, &msg, MSG_CMSG_CLOEXEC);
  } while (n < 0 && errno == EINTR);
  if (n <= 0) {
    if (n == 0) errno = ECONNRESET;
    return -1;
  }
  struct cmsghdr *c = CMSG_FIRSTHDR(&msg);
  if (!c || c->cmsg_level != SOL_SOCKET || c->cmsg_type != SCM_RIGHTS || c->cmsg_len != CMSG_LEN(sizeof(int))) {
    errno = EPROTO;
    return -1;
  }
  int fd;
  memcpy(&fd, CMSG_DATA(c), sizeof fd);
  return fd;
}
