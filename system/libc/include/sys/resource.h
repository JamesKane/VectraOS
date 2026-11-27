// SPDX-License-Identifier: BSD-3-Clause

// <sys/resource.h> (POSIX): getrusage. ru_utime is the CPU time the
// process (RUSAGE_SELF) or the calling thread (RUSAGE_THREAD, Linux's)
// has run, as the kernel counts it; croi doesn't split it by mode, so
// ru_stime is 0, and so is every other field. RUSAGE_CHILDREN is all
// zeros: no child's time is kept once it has gone.

#pragma once
#include <sys/time.h>

#ifdef __cplusplus
extern "C" {
#endif

#define RUSAGE_SELF 0
#define RUSAGE_CHILDREN (-1)
#define RUSAGE_THREAD 1

struct rusage {
  struct timeval ru_utime;
  struct timeval ru_stime;
  long ru_maxrss;
  long ru_ixrss;
  long ru_idrss;
  long ru_isrss;
  long ru_minflt;
  long ru_majflt;
  long ru_nswap;
  long ru_inblock;
  long ru_oublock;
  long ru_msgsnd;
  long ru_msgrcv;
  long ru_nsignals;
  long ru_nvcsw;
  long ru_nivcsw;
};

int getrusage(int who, struct rusage *usage);

#ifdef __cplusplus
}
#endif
