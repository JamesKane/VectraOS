// SPDX-License-Identifier: BSD-3-Clause

// <sys/types.h> (POSIX XBD): the types the file interfaces use, with
// Linux's widths on 64-bit machines (M6g).

#pragma once
#include <stddef.h>
#include <stdint.h>

typedef long ssize_t;
typedef int64_t off_t;
typedef uint32_t mode_t;
typedef uint64_t dev_t;
typedef uint64_t ino_t;
typedef uint64_t nlink_t;
typedef uint32_t uid_t;
typedef uint32_t gid_t;
typedef int32_t pid_t;
typedef long blksize_t;
typedef int64_t blkcnt_t;
