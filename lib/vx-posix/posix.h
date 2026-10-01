// posix.h: posixd's protocol (docs/01 §9), shared by posixd and the musl back
// end. Calls are channel_calls of one posix_msg, answered by one.
//
// A process has its own channel to posixd, so posixd knows who calls. A
// process started by something that is not a POSIX process (svcd) connects
// through /srv/posixd with CONNECT, giving posixd a handle to its own task;
// it becomes the leader of a new session, its parent pid 1. A POSIX parent
// registers each child with CHILD before starting it, giving posixd the
// child's task, and passes the child the channel the reply carries. posixd
// keeps the task handles: it is told of each exit, and (with signals) it is
// what kills.
//
// pid 1 is posixd itself. An orphan's parent becomes 1, and posixd reaps it.

#pragma once

#include "../../abi/vx/abi.h"

enum posix_call : uint32_t {
  POSIX_CONNECT = 1, // on /srv/posixd; handles [the caller's task] -> {pid}, handles [its channel]
  POSIX_CHILD,       // handles [a new task]; {pgid: -1 to inherit, 0 its own; setsid} -> {pid}, [its channel]
  POSIX_IDS,         // -> {pid, ppid, pgid, sid}
  POSIX_SETPGID,     // {pid, pgid}, 0 for the caller and its pid -> {}
  POSIX_SETSID,      // -> {sid}
  POSIX_GETPGID,     // {pid}, 0 for the caller -> {pgid}
  POSIX_GETSID,      // {pid}, 0 for the caller -> {sid}
  POSIX_WAIT,        // {pid, options} as wait4's -> {pid, status} once a child has ended; {0} with WNOHANG
  POSIX_EXEC,        // handles [a new task] -> {pid}, handles [its channel]: the caller's process goes on
                     // in the new task (execve), with its pid, parent, group, session and children; the
                     // caller's own task and channel are let go, and its end is not reported
};

// A reply's h.flags: 0, or why the call failed, as the errno it becomes.
enum posix_error : uint32_t {
  POSIX_OK = 0,
  POSIX_ESRCH,  // no such process or group
  POSIX_EPERM,  // not allowed
  POSIX_ECHILD, // no child to wait for
  POSIX_EINVAL,
  POSIX_EAGAIN, // the process table is full
};

typedef struct posix_msg {
  vx_msg_header h;
  int64_t arg[4];
} posix_msg;

static constexpr int64_t POSIX_WNOHANG = 1; // wait4's options, as Linux numbers them

// The wait status of a process that exited with status s (the kernel's exit
// status): its low byte as an exit code; a fault (-1) as SIGSEGV; a kill for
// signal n (-(256 + n), from posixd) as that signal; any other kill as SIGKILL.
static constexpr int64_t POSIX_SIGKILL = 9, POSIX_SIGSEGV = 11;

[[maybe_unused]] static int64_t posix_wait_status(int64_t s) {
  if (s >= 0) return (s & 0xff) << 8;
  if (s == -1) return POSIX_SIGSEGV;
  if (s <= -257 && s >= -256 - 64) return -s - 256;
  return POSIX_SIGKILL;
}
