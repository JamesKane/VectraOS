// SPDX-License-Identifier: BSD-3-Clause

// getopt (POSIX), getopt_long and getopt_long_only (GNU's interface), as
// <getopt.h> describes them. In C because their state is data under C
// names (optarg, optind, opterr, optopt) that programs read and set.
// Setting optind to 0 starts a new walk. Messages go to stderr
// as "<program>: <what>".

#include <getopt.h>
#include <stdio.h>
#include <string.h>

char *optarg;
int optind = 1, opterr = 1, optopt = '?';

// The next short option's place in argv[optind], or NULL between arguments.
static const char *next;

static void complain(const char *program, const char *what, const char *name, int c, int silent) {
  if (silent || !opterr) return;
  if (name != NULL) {
    fprintf(stderr, "%s: %s '--%s'\n", program, what, name);
  } else {
    fprintf(stderr, "%s: %s -- '%c'\n", program, what, c);
  }
}

// A long option at argv[optind] + skip (past "--", or "-" for
// getopt_long_only): its value, or '?' (or ':') and a message. Returns -2
// for getopt_long_only when no long option matches, to try the short ones.
static int long_option(int argc, char *const argv[], const struct option *longopts, int *longindex, int skip,
                       int silent, int only) {
  const char *arg = argv[optind] + skip;
  const char *eq = strchr(arg, '=');
  size_t length = eq ? (size_t)(eq - arg) : strlen(arg);
  int found = -1, ambiguous = 0;
  for (int i = 0; longopts[i].name != NULL; i++) {
    if (strncmp(longopts[i].name, arg, length) != 0) continue;
    if (strlen(longopts[i].name) == length) {
      found = i;
      ambiguous = 0;
      break;
    }
    if (found >= 0) {
      ambiguous = 1;
    } else {
      found = i;
    }
  }
  if (found < 0 && only) return -2;
  optind++;
  if (found < 0) {
    complain(argv[0], "unrecognized option", arg, 0, silent);
    optopt = 0;
    return '?';
  }
  if (ambiguous) {
    complain(argv[0], "ambiguous option", arg, 0, silent);
    optopt = 0;
    return '?';
  }
  const struct option *o = &longopts[found];
  optarg = NULL;
  if (o->has_arg == no_argument) {
    if (eq) {
      complain(argv[0], "option doesn't allow an argument", o->name, 0, silent);
      optopt = o->flag ? 0 : o->val;
      return '?';
    }
  } else if (eq) {
    optarg = (char *)eq + 1;
  } else if (o->has_arg == required_argument) {
    if (optind >= argc) {
      complain(argv[0], "option requires an argument", o->name, 0, silent);
      optopt = o->flag ? 0 : o->val;
      return silent ? ':' : '?';
    }
    optarg = argv[optind++];
  }
  if (longindex) *longindex = found;
  if (o->flag) {
    *o->flag = o->val;
    return 0;
  }
  return o->val;
}

static int walk(int argc, char *const argv[], const char *options, const struct option *longopts, int *longindex,
                int only) {
  if (optind == 0) {
    optind = 1;
    next = NULL;
  }
  if (*options == '+' || *options == '-') options++;
  int silent = *options == ':';
  optarg = NULL;
  if (next == NULL || *next == 0) {
    next = NULL;
    if (optind >= argc || argv[optind] == NULL || argv[optind][0] != '-' || argv[optind][1] == 0) return -1;
    if (strcmp(argv[optind], "--") == 0) {
      optind++;
      return -1;
    }
    if (longopts != NULL && argv[optind][1] == '-') return long_option(argc, argv, longopts, longindex, 2, silent, 0);
    if (longopts != NULL && only) {
      // A long option first; a single short one if none matches.
      int c = long_option(argc, argv, longopts, longindex, 1, silent, argv[optind][2] == 0 ? 1 : 0);
      if (c != -2) return c;
    }
    next = argv[optind] + 1;
  }
  int c = (unsigned char)*next++;
  const char *spec = c == ':' ? NULL : strchr(options, c);
  if (spec == NULL) {
    optopt = c;
    complain(argv[0], "invalid option", NULL, c, silent);
    if (*next == 0) optind++;
    return '?';
  }
  if (spec[1] != ':') {
    if (*next == 0) optind++;
    return c;
  }
  // An argument: the rest of this one, or (unless optional) the next.
  if (*next != 0) {
    optarg = (char *)next;
    optind++;
  } else if (spec[2] == ':') {
    optind++;
  } else if (optind + 1 >= argc) {
    optind++;
    optopt = c;
    complain(argv[0], "option requires an argument", NULL, c, silent);
    next = NULL;
    return silent ? ':' : '?';
  } else {
    optarg = argv[optind + 1];
    optind += 2;
  }
  next = NULL;
  return c;
}

int getopt(int argc, char *const argv[], const char *options) { return walk(argc, argv, options, NULL, NULL, 0); }

int getopt_long(int argc, char *const argv[], const char *options, const struct option *longopts, int *longindex) {
  return walk(argc, argv, options, longopts, longindex, 0);
}

int getopt_long_only(int argc, char *const argv[], const char *options, const struct option *longopts,
                     int *longindex) {
  return walk(argc, argv, options, longopts, longindex, 1);
}
