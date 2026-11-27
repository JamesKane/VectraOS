// SPDX-License-Identifier: BSD-3-Clause

// <getopt.h>: POSIX's getopt and the GNU getopt_long and getopt_long_only
// (system/libc/native/getopt.c). Options are taken from the front of argv
// up to the first operand or "--", as POSIX's getopt and GNU's with a
// leading '+' do: argv is never permuted. A long option may be given by a
// unique prefix of its name, its argument after '=' or as the next
// argument. A leading ':' in the options makes a missing argument ':' and
// silences the messages, as opterr = 0 does.

#pragma once

#ifdef __cplusplus
extern "C" {
#endif

extern char *optarg;
extern int optind, opterr, optopt;

struct option {
  const char *name;
  int has_arg;
  int *flag;
  int val;
};

#define no_argument 0
#define required_argument 1
#define optional_argument 2

int getopt(int argc, char *const argv[], const char *options);
int getopt_long(int argc, char *const argv[], const char *options, const struct option *longopts, int *longindex);
int getopt_long_only(int argc, char *const argv[], const char *options, const struct option *longopts,
                     int *longindex);

#ifdef __cplusplus
}
#endif
