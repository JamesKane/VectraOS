// SPDX-License-Identifier: BSD-3-Clause

// What the libc's Swift reaches in C for stdio (M6c): C's va_list, which
// Swift can't read, through stdio.c's readers; and the floor's stdout
// (system/sys/floor/Stdout.swift), reached by symbol (the floor imports the
// libc, so the libc can't import the floor).

#pragma once
#include <stddef.h>
#include <stdint.h>

/// The next variadic argument: an integer of `size` bytes (its bits), a
/// double, a long double, a pointer. `ap` is a va_list's address.
uint64_t td_va_integer(void *ap, int size);
double td_va_double(void *ap);
/// The next long double's bytes: x87's 10 (then padding) on amd64,
/// binary128's 16 elsewhere.
void td_va_long_double(void *ap, uint64_t out[2]);
uintptr_t td_va_pointer(void *ap);

void td_stdout_write(const void *bytes, size_t n);
void td_stdout_flush(void);
void td_stderr_write(const void *bytes, size_t n);
ptrdiff_t td_stdin_read(void *buffer, size_t n);
