// vx-rc: the rc shell language (Tom Duff's, as 9front's rc has it), for gsh
// (docs/milestones.md, M4 step 7). A script is read by a lexer, parsed into a
// tree, compiled into code, and run by a machine, as rc does; none of it
// recurses (the house rules): the parser and the compiler keep stacks of their
// own, and functions run on the machine's frames.
//
// What runs a command is the host's: rc_host's callbacks start programs (each
// stage of a pipeline at once), open the files redirections name, read
// directories for globbing, and give builtins of the host's own. So the
// language is tested on the host (tests/host/rc_test.c), and gsh puts it on
// vx-rt and the namespace.
//
// Freestanding: the interpreter keeps its words, variables and code in a heap
// the caller gives it (rc_new), and makes no system call itself.
//
// Without fork, two things are narrower than rc's: each stage of a pipeline,
// and a command run with &, must be a program (not a function, builtin or
// block); and `{...} and @{...} run in the shell itself, so what they assign
// is seen after (docs/milestones.md, known gaps).

#pragma once

#include "../../abi/vx/abi.h"
#if __STDC_HOSTED__
#include <string.h> // host tests
#else
#include "../vx-mem/mem.h"
#endif

typedef struct rc rc; // an interpreter

// A word, and a list of them, as the machine keeps them.
typedef struct rc_word {
  struct rc_word *next;
  size_t len;
  char s[]; // len bytes, then a NUL
} rc_word;

// Where a file descriptor goes for a command: one of the shell's own (as it
// inherited them), a file the host opened for a redirection, another
// descriptor, closed, the shell's capture of what it writes (for `{...}), or
// a pipe to or from the next stage of a pipeline.
enum rc_fd_kind : uint8_t {
  RC_FD_INHERIT,
  RC_FD_READ,
  RC_FD_WRITE,
  RC_FD_APPEND,
  RC_FD_RDWR,
  RC_FD_DUP,
  RC_FD_CLOSED,
  RC_FD_CAPTURE,  // into the shell, for `{...}: rc_capture_write
  RC_FD_PIPE_OUT, // a pipeline's: into the next stage
  RC_FD_PIPE_IN,  // from the stage before
};

static constexpr uint32_t RC_FDS = 10; // 0 to 9, as rc's >[n]

typedef struct rc_fd {
  uint8_t kind;     // enum rc_fd_kind
  uint8_t dup;      // RC_FD_INHERIT: which of the shell's own; RC_FD_DUP: the descriptor it copies;
                    // RC_FD_CAPTURE: which capture
  uint32_t handle;  // a file's, as the host's open gave it
  const char *path; // and its path
  size_t path_len;
} rc_fd;

typedef struct rc_command {
  const rc_word *argv; // the words
  uint32_t argc;
  rc_fd fds[RC_FDS]; // after redirections; a pipeline's stages are joined by the host
} rc_command;

typedef struct rc_host {
  void *ctx;
  // Runs a pipeline of n programs (n is 1 for a plain command), each stage's
  // standard output into the next's standard input, as one job: waits for
  // it, unless async, and gives each stage's exit status (rc's: "" is
  // success) through set_status. False if a program could not be started
  // (why, in its status). async: the pid it started, in *pid.
  bool (*run)(void *ctx, rc *r, const rc_command *stages, uint32_t n, bool async, uint64_t *pid);
  // Writes to a descriptor of the shell's own (a builtin's output): fd 1 or 2,
  // with redirections already applied by the shell when it captures.
  void (*write)(void *ctx, const rc_fd *fd, uint32_t which, const char *s, size_t n);
  // A directory's entries, for globbing: calls each(name) for each; false if
  // it cannot be read.
  bool (*readdir)(void *ctx, const char *path, size_t len,
                  void (*each)(void *arg, const char *name, size_t n), void *arg);
  // The host's builtins (cd, and gsh's namespace commands): true if argv[0]
  // is one, which it ran (setting $status).
  bool (*builtin)(void *ctx, rc *r, const rc_word *argv, uint32_t argc, const rc_fd *fds);
  // A file's text, for `.`: its length into buf (cap bytes), or -1.
  int64_t (*read_file)(void *ctx, const char *path, size_t len, char *buf, size_t cap);
  // Opens a redirection's file, once, where the redirection is (kind: READ,
  // WRITE, which empties it, APPEND, RDWR): its handle in *handle; false if it
  // cannot be (why, in $status). close lets it go when the redirection ends.
  bool (*open)(void *ctx, rc *r, const char *path, size_t len, uint8_t kind, uint32_t *handle);
  void (*close)(void *ctx, uint32_t handle);
} rc_host;
