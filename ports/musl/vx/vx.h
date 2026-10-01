// vx.h: the back end's external symbols, the ones reached by name from
// outside it: by musl (syscall_arch.h declares __vx_syscall for musl's C99)
// and by crt1.
#pragma once

#include "../../../abi/vx/abi.h"

// Every system call musl makes: a Linux number and arguments, a Linux result.
[[gnu::visibility("hidden")]] long __vx_syscall(long n, long a1, long a2, long a3, long a4, long a5, long a6);

// crt1's _start passes the bootstrap channel and the program's main. It reads
// the spawn message and calls musl's __libc_start_main, which ends in exit.
[[gnu::visibility("hidden"), noreturn]] void __vx_start(vx_handle bootstrap,
                                                        int (*main)(int, char **, char **));

// The kernel enters _start, as if called, with the bootstrap channel.
[[noreturn]] void _start(void);
int main(int argc, char **argv, char **envp);
