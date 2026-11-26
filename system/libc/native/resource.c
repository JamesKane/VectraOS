// SPDX-License-Identifier: BSD-3-Clause

// getrusage (<sys/resource.h>): the process's or the thread's CPU time,
// from the kernel's TASK_RUNTIME record of its own handle. In C because
// it fills a struct rusage from a croi record through the floor's handles
// (td_native.h), which the libc's Swift can't import (the floor imports
// the libc).

#include <croi/syscall.h>
#include <errno.h>
#include <string.h>
#include <sys/resource.h>
#include <td_native.h>

int getrusage(int who, struct rusage *usage) {
  uint32_t handle;
  switch (who) {
  case RUSAGE_SELF: handle = td_runtime_process_self; break;
  case RUSAGE_THREAD: handle = td_runtime_thread_self; break;
  case RUSAGE_CHILDREN:
    memset(usage, 0, sizeof *usage);
    return 0;
  default: errno = EINVAL; return -1;
  }
  croi_info_task_runtime_t runtime;
  if (croi_syscall6(CROI_SYS_OBJECT_GET_INFO, handle, CROI_INFO_TASK_RUNTIME, (uint64_t)(uintptr_t)&runtime,
                    sizeof runtime, 0, 0) != 0) {
    errno = EINVAL;
    return -1;
  }
  memset(usage, 0, sizeof *usage);
  usage->ru_utime.tv_sec = runtime.cpu_time / 1000000000;
  usage->ru_utime.tv_usec = runtime.cpu_time % 1000000000 / 1000;
  return 0;
}
