// posix.h: what the POSIX personality's pieces share (docs/01 §9): the musl
// back end, which builds signals on notes, procfs, which carries out the ones
// a process cannot (SIGKILL, SIGSTOP, SIGCONT), and ptyd, which sends a
// terminal's to its foreground group. The process calls themselves are files
// in /proc (ADR-0011).

#pragma once

#include "../../abi/vx/abi.h"
#include "../vx-note/note.c"

// Signals are notes (ADR-0010). A signal another process sends (kill) is the
// note "posix: SIGTERM pid=12", which names the sender; one with Plan 9 words
// of its own, from the system, is a Plan 9 note ("interrupt", "hangup",
// "alarm", "sys: write on closed pipe", "sys: trap: ..."). Both map back to
// the signal here, as do the exit strings a process ends with: "killed" is
// SIGKILL's. Signal numbers are Linux's, as musl's are.
static constexpr int64_t POSIX_SIGHUP = 1, POSIX_SIGINT = 2, POSIX_SIGILL = 4, POSIX_SIGTRAP = 5,
                         POSIX_SIGBUS = 7, POSIX_SIGFPE = 8, POSIX_SIGKILL = 9, POSIX_SIGSEGV = 11,
                         POSIX_SIGPIPE = 13, POSIX_SIGALRM = 14, POSIX_SIGCHLD = 17, POSIX_SIGCONT = 18,
                         POSIX_SIGSTOP = 19, POSIX_SIGURG = 23, POSIX_SIGWINCH = 28, POSIX_NSIG = 64;

static const char *const POSIX_SIGNAMES[32] = {
    nullptr,     "SIGHUP",  "SIGINT",    "SIGQUIT", "SIGILL",   "SIGTRAP", "SIGABRT", "SIGBUS",
    "SIGFPE",    "SIGKILL", "SIGUSR1",   "SIGSEGV", "SIGUSR2",  "SIGPIPE", "SIGALRM", "SIGTERM",
    "SIGSTKFLT", "SIGCHLD", "SIGCONT",   "SIGSTOP", "SIGTSTP",  "SIGTTIN", "SIGTTOU", "SIGURG",
    "SIGXCPU",   "SIGXFSZ", "SIGVTALRM", "SIGPROF", "SIGWINCH", "SIGIO",   "SIGPWR",  "SIGSYS",
};

// The Plan 9 notes that are signals, and the prefixes of trap notes.
static const struct {
  const char *note;
  int64_t sig;
  bool prefix;
} POSIX_PLAN9_NOTES[] = {
    {"hangup", POSIX_SIGHUP, false},
    {"interrupt", POSIX_SIGINT, false},
    {"alarm", POSIX_SIGALRM, false},
    {"sys: write on closed pipe", POSIX_SIGPIPE, false},
    {"killed", POSIX_SIGKILL, false},
    {"sys: trap: fault ", POSIX_SIGSEGV, true},
    {"sys: trap: general fault", POSIX_SIGSEGV, true},
    {"sys: trap: illegal instruction", POSIX_SIGILL, true},
    {"sys: trap: fp disabled", POSIX_SIGILL, true},
    {"sys: trap: arithmetic", POSIX_SIGFPE, true},
    {"sys: trap: misaligned", POSIX_SIGBUS, true},
    {"sys: breakpoint", POSIX_SIGTRAP, true},
    {"sys: trap: step", POSIX_SIGTRAP, true},
};

// The note for signal sig: from a sender (a pid), "posix: NAME pid=N"; from
// the system (sender 0), its Plan 9 words if it has them, else "posix: NAME".
// Returns its length.
[[maybe_unused]] static size_t posix_note(int64_t sig, int64_t sender, char out[VX_ERRMAX]) {
  vx_note_buf b = {out, 0, VX_ERRMAX};
  if (!sender)
    for (size_t i = 0; i < sizeof POSIX_PLAN9_NOTES / sizeof POSIX_PLAN9_NOTES[0]; i++)
      if (POSIX_PLAN9_NOTES[i].sig == sig && !POSIX_PLAN9_NOTES[i].prefix && sig != POSIX_SIGKILL) {
        vx_note_put(&b, vx_cstr(POSIX_PLAN9_NOTES[i].note));
        return b.len;
      }
  vx_note_put(&b, VX_STR("posix: "));
  if (sig > 0 && sig < 32) {
    vx_note_put(&b, vx_cstr(POSIX_SIGNAMES[sig]));
  } else {
    vx_note_put(&b, VX_STR("SIG"));
    vx_note_dec(&b, (uint64_t)sig);
  }
  if (sender > 0) {
    vx_note_put(&b, VX_STR(" pid="));
    vx_note_dec(&b, (uint64_t)sender);
  }
  return b.len;
}

// The signal a note or exit string stands for, and in *sender who sent it (0
// if it does not say); 0 if it is no signal.
[[maybe_unused]] static int64_t posix_note_signal(vx_str note, int64_t *sender) {
  *sender = 0;
  for (size_t i = 0; i < sizeof POSIX_PLAN9_NOTES / sizeof POSIX_PLAN9_NOTES[0]; i++) {
    vx_str n = vx_cstr(POSIX_PLAN9_NOTES[i].note);
    if (POSIX_PLAN9_NOTES[i].prefix ? vx_note_prefix(note, n) : note.len == n.len && vx_note_prefix(note, n))
      return POSIX_PLAN9_NOTES[i].sig;
  }
  if (!vx_note_prefix(note, VX_STR("posix: SIG"))) return 0;
  size_t at = 7, end = at; // the name, from "SIG"
  while (end < note.len && note.ptr[end] != ' ') end++;
  vx_str name = {note.ptr + at, end - at};
  int64_t sig = 0;
  for (int64_t i = 1; i < 32 && !sig; i++)
    if (vx_cstr(POSIX_SIGNAMES[i]).len == name.len && vx_note_prefix(name, vx_cstr(POSIX_SIGNAMES[i])))
      sig = i;
  if (!sig && name.len > 3 && name.len < 6) { // SIG34: a number, for those with no name
    size_t j = 3;
    int64_t v = 0;
    while (j < name.len && name.ptr[j] >= '0' && name.ptr[j] <= '9') v = v * 10 + (name.ptr[j++] - '0');
    if (j == name.len && v > 0 && v <= POSIX_NSIG) sig = v;
  }
  if (!sig) return 0;
  if (note.len - end > 5 && vx_note_prefix((vx_str){note.ptr + end, note.len - end}, VX_STR(" pid=")))
    for (size_t j = end + 5; j < note.len && note.ptr[j] >= '0' && note.ptr[j] <= '9'; j++)
      *sender = *sender * 10 + (note.ptr[j] - '0');
  return sig;
}

// The wait status of a process that ended with this exit string: empty is
// exit code 0; a number is that exit code (its low byte), as exit(n) writes
// it; a signal's note is that signal; anything else is exit code 1.
[[maybe_unused]] static int64_t posix_wait_status(vx_str exit) {
  if (!exit.len) return 0;
  int64_t code = 0;
  size_t i = 0;
  while (i < exit.len && exit.ptr[i] >= '0' && exit.ptr[i] <= '9' && i < 19)
    code = code * 10 + (exit.ptr[i++] - '0');
  if (i == exit.len) return (code & 0xff) << 8;
  int64_t sender;
  int64_t sig = posix_note_signal(exit, &sender);
  return sig ? sig : 1 << 8;
}

// The signals whose default is to be ignored; every other one's ends the
// process (stopping waits for job control, with ptyd).
[[maybe_unused]] static bool posix_default_ignored(int64_t sig) {
  return sig == POSIX_SIGCHLD || sig == POSIX_SIGCONT || sig == POSIX_SIGURG || sig == POSIX_SIGWINCH;
}
