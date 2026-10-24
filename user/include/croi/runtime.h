// What a user program, C or Embedded Swift, reaches in C: the system
// calls (syscall.h, its own module CroiSyscall), processargs, and the
// floor's C interface (system/sys/floor/include: td_floor.h, td_native.h),
// the one user runtime (D49), with the libc's headers (system/libc/include).
// `_start` reads the bootstrap message, keeps its handles
// (td_startup_take), and calls `main(argc, argv)`; returning from main
// exits the process. stdout (putchar, td_stdout_write) goes to
// the debuglog handed over as fd 1, if there is one.

#pragma once

#include <stddef.h>
#include <stdint.h>

#include "syscall.h"
#include "processargs.h"
#include "td_floor.h"
#include "td_native.h"

// Device registers (croi/mmio.h, its own module CroiMMIO too).
#include "mmio.h"

// The C library (system/libc, V2), through its own headers: what the
// compilers and the Embedded Swift runtime call (mem*, the floor's heap)
// and the rest, pthreads included.
#include <dlfcn.h>
#include <errno.h>
#include <pthread.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/auxv.h>
#include <time.h>
#include <unistd.h>
