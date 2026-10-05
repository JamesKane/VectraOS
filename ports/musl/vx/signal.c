// signal.c: POSIX signals (docs/01 §9). Part of backend.c.
//
// Signals are built on notes (ADR-0010). The dispositions, the mask and the
// pending set live here, in the process. A signal from another process is a
// note ("posix: SIGTERM pid=12", or Plan 9's "interrupt" and the like) that
// procfs posts when it is written to /proc (kill, below); sig_note, this process's note handler (lib/vx-rt/note.c),
// maps it to its signal through lib/vx-posix/posix.h's table. So does any
// fault, which becomes SIGSEGV, SIGBUS, SIGILL, SIGFPE or SIGTRAP. A note
// that is no signal ends the process with it, as in Plan 9. A signal to
// itself (raise, abort, kill of its own pid) is made pending here.
//
// A handler never runs inside the back end, which is not reentrant and may be
// in the middle of a ring submission: a signal that arrives there is made
// pending, the call it interrupted returns ERR_INTERRUPTED, and __vx_syscall
// delivers it on its way out. Then the call returns EINTR if a handler that
// is not SA_RESTART ran, and is made again otherwise. A signal that arrives
// in the program's own code is delivered at once, on its stack.
//
// A stopping signal's default stops the process through its ctl ("stop SIG",
// so its parent's wait learns which); SIGSTOP, SIGKILL and SIGCONT from
// another process, procfs carries out itself (ADR-0011). kill writes notes to
// /proc, as 9front's APE does: note for a process, notepg for a group.
//
// Not yet: an alternate signal stack, and the registers in a handler's ucontext.

static constexpr int SIG_MAX = 64;

// rt_sigaction's argument, as musl lays it out (musl's src/internal/ksigaction.h
// and arch/x86_64/ksigaction.h: the same on both architectures, which define
// SA_RESTORER).
typedef struct k_sigaction {
  void (*handler)(int);
  unsigned long flags;
  void (*restorer)(void);
  unsigned mask[2];
} k_sigaction;

static struct {
  uintptr_t handler; // SIG_DFL, SIG_IGN, or a function
  unsigned long flags;
  uint64_t mask;
} sig_actions[SIG_MAX + 1];

static uint64_t sig_mask; // bit n - 1 for signal n
// Pending: atomic, as a note handler may set a bit between the load and the
// store of a change made in the program's code.
static _Atomic uint64_t sig_pending;
static int64_t sig_sender[SIG_MAX + 1]; // who sent each pending one
static volatile int sig_depth;          // inside __vx_syscall: delivery waits for its return
static uint32_t sig_handlers_ran;       // how many handlers have run
static uint32_t sig_eintr_ran;          // how many of them were not SA_RESTART (a call they interrupt ends)

static uint64_t sig_bit(int sig) { return 1ull << (sig - 1); }
static constexpr uint64_t SIG_UNBLOCKABLE = 1ull << (SIGKILL - 1) | 1ull << (SIGSTOP - 1);

// Ends the process as the signal does by default, with an exit string a
// parent's wait reads as that signal (lib/vx-posix/posix.h): a fault's note,
// or the signal's. A fault is reported first, as the kernel would.
[[noreturn]] static void sig_terminate(int sig, const vx_exception *e, vx_str fault) {
  if (e) {
    char line[160];
    vx_str name = vx_spawn.name;
    int n =
        snprintf(line, sizeof line, "vx-musl: %.*s (pid %ld): fatal signal %d at pc 0x%llx, address 0x%llx\n",
                 (int)name.len, name.ptr, posix_pid(), sig,
#ifdef __x86_64__
                 (unsigned long long)e->regs.rip,
#else
                 (unsigned long long)e->regs.pc,
#endif
                 (unsigned long long)e->address);
    if (n > 0) console_write(line, (size_t)n < sizeof line ? (size_t)n : sizeof line - 1);
  }
  if (e && e->kind != VX_EXCEPTION_INTERRUPT) { // a fault: again, uncaught; a crash directory, then its end
    vx_exception again = *e;
    vx_note_crash(&again);
  }
  char note[VX_ERRMAX];
  proc_exit_str(fault.len ? fault : (vx_str){note, posix_note(sig, 0, note)});
}

// Carries out sig's disposition. Returns whether a call it interrupted
// returns EINTR: a handler ran that is not SA_RESTART.
static bool sig_act(int sig, int code, int64_t sender, uint64_t address, const vx_exception *e,
                    vx_str fault) {
  uintptr_t h = sig_actions[sig].handler;
  unsigned long flags = sig_actions[sig].flags;
  if (h == (uintptr_t)SIG_IGN) return false;
  if (h == (uintptr_t)SIG_DFL) {
    if (sig == SIGSTOP || sig == SIGTSTP || sig == SIGTTIN || sig == SIGTTOU) { // stop, until SIGCONT
      char cmd[16];
      snprintf(cmd, sizeof cmd, "stop %d", sig);
      proc_write(posix_pid(), "ctl", cmd); // answered, then stopped on the way out
      return false;
    }
    if (posix_default_ignored(sig)) return false;
    sig_terminate(sig, e, fault);
  }
  uint64_t old = sig_mask;
  sig_mask |= sig_actions[sig].mask & ~SIG_UNBLOCKABLE;
  if (!(flags & SA_NODEFER)) sig_mask |= sig_bit(sig);
  if (flags & SA_RESETHAND) sig_actions[sig] = (typeof(sig_actions[0])){(uintptr_t)SIG_DFL, 0, 0};
  sig_handlers_ran++;
  if (!(flags & SA_RESTART)) sig_eintr_ran++;
  // The handler is the program's own code, even when the back end delivers
  // it (sigsuspend, ppoll, a fault in a call): a signal during it is
  // delivered at once, and a siglongjmp out of it leaves the back end as it
  // is in the program's code.
  int depth = sig_depth;
  sig_depth = 0;
  if (flags & SA_SIGINFO) {
    siginfo_t info = {.si_signo = sig, .si_code = code};
    if (e) {
      info.si_addr = (void *)address;                 // a fault's; a signal's sender shares the union with it
      if (code == SEGV_PKUERR) info.si_pkey = e->key; // the page's protection key (ADR-0035)
    } else {
      info.si_pid = (pid_t)sender;
    }
    ucontext_t uc = {};
    memcpy(&uc.uc_sigmask, &old, sizeof old);
    ((void (*)(int, siginfo_t *, void *))h)(sig, &info, &uc);
  } else {
    ((void (*)(int))h)(sig);
  }
  sig_depth = depth;
  sig_mask = old;
  return !(flags & SA_RESTART);
}

// Delivers every pending signal that is not blocked, lowest first.
static bool sig_deliver_pending(void) {
  bool eintr = false;
  for (uint64_t ready; (ready = sig_pending & ~sig_mask);) {
    int sig = __builtin_ctzll(ready) + 1;
    sig_pending &= ~sig_bit(sig);
    eintr =
        sig_act(sig, sig_sender[sig] ? SI_USER : SI_KERNEL, sig_sender[sig], 0, nullptr, (vx_str){}) || eintr;
  }
  return eintr;
}

// From __vx_syscall, the pending signals not blocked, delivered as from the
// program's code; a sleep's or poll's deadline kept from a handler's own.
static void sig_run_pending(void) {
  if (!(sig_pending & ~sig_mask)) return;
  int depth = sig_depth;
  vx_instant kept = sig_call_deadline;
  sig_depth = 0;
  sig_deliver_pending();
  sig_depth = depth;
  sig_call_deadline = kept;
}

static void sig_raise_self(int sig) {
  sig_pending |= sig_bit(sig);
  sig_sender[sig] = posix_pid();
}

// The note handler: a note from another process, or a fault.
static vx_noted sig_note(vx_exception *e, vx_str note) {
  if (e->kind == VX_EXCEPTION_INTERRUPT) {
    int64_t sender;
    int sig = (int)posix_note_signal(note, &sender);
    if (sig < 1 || sig > SIG_MAX) return VX_NDFLT; // no signal: the note ends the process
    sig_pending |= sig_bit(sig);
    sig_sender[sig] = sender;
    if (sig_depth == 0) {
      sig_deliver_pending(); // in the program's own code
    } else if (!(sig_mask & sig_bit(sig))) {
      // In the back end, maybe just before it waits: the kernel had this
      // note interrupt nothing (it came in user mode), so the wait is woken
      // here, whichever it is: fd_port's (fd_wait), or sig_seq's.
      atomic_fetch_add(&sig_seq, 1);
      vx_futex_wake(&sig_seq, UINT32_MAX);
      vx_port_post(fd_port, &(vx_packet){.key = FD_KEY_SIGNAL});
    }
    return VX_NCONT;
  }
  int sig = SIGSEGV, code = SEGV_MAPERR;
  switch (e->kind) {
  case VX_EXCEPTION_ALIGNMENT: sig = SIGBUS, code = BUS_ADRALN; break;
  case VX_EXCEPTION_PAGER_TIMEOUT:
    sig = SIGBUS, code = BUS_ADRERR;
    break; // a mapped file's page that did not come
  case VX_EXCEPTION_ILLEGAL:
  case VX_EXCEPTION_FP_DISABLED: sig = SIGILL, code = ILL_ILLOPC; break;
  case VX_EXCEPTION_ARITHMETIC: sig = SIGFPE, code = FPE_INTDIV; break;
  case VX_EXCEPTION_BREAKPOINT:
  case VX_EXCEPTION_STEP: sig = SIGTRAP, code = TRAP_BRKPT; break;
  case VX_EXCEPTION_GENERAL: code = SI_KERNEL; break;
  case VX_EXCEPTION_PROTECTION_KEY: code = SEGV_PKUERR; break; // SIGSEGV, si_pkey the key
  default: break;
  }
  // A fault that is blocked or ignored would only happen again: its default.
  uintptr_t h = sig_actions[sig].handler;
  if ((sig_mask & sig_bit(sig)) || h == (uintptr_t)SIG_IGN) sig_terminate(sig, e, note);
  sig_act(sig, code, 0, e->address, e, note); // then the instruction again, unless the handler jumped away
  return VX_NCONT;
}

static void sig_init(void) {
  vx_note_exit = proc_exit_str; // a note that is no signal ends the process with it
  vx_ndb_record rec;
  uint64_t ignored = 0, mask = 0;
  if (vx_spawn_record("signals", &rec) && vx_ndb_get_u64(&rec, "signals", &ignored) &&
      vx_ndb_get_u64(&rec, "mask", &mask)) { // from a POSIX parent: what exec and posix_spawn keep
    for (int sig = 1; sig <= SIG_MAX; sig++)
      if ((ignored & sig_bit(sig)) && sig != SIGKILL && sig != SIGSTOP)
        sig_actions[sig].handler = (uintptr_t)SIG_IGN;
    sig_mask = mask & ~SIG_UNBLOCKABLE;
  }
  vx_notify(sig_note);
}

// --- The calls ---

static long sig_action(int sig, const k_sigaction *act, k_sigaction *old) {
  if (sig < 1 || sig > SIG_MAX || ((sig == SIGKILL || sig == SIGSTOP) && act)) return -EINVAL;
  if (old) {
    *old = (k_sigaction){.handler = (void (*)(int))sig_actions[sig].handler, .flags = sig_actions[sig].flags};
    memcpy(old->mask, &sig_actions[sig].mask, sizeof old->mask);
  }
  if (act) {
    uint64_t mask;
    memcpy(&mask, act->mask, sizeof mask);
    sig_actions[sig].handler = (uintptr_t)act->handler;
    sig_actions[sig].flags = act->flags;
    sig_actions[sig].mask = mask;
    if ((uintptr_t)act->handler == (uintptr_t)SIG_IGN)
      sig_pending &= ~sig_bit(sig); // discarded, as POSIX has it
  }
  return 0;
}

// The pending signals now unblocked are delivered as the call returns.
static long sig_procmask(int how, const uint64_t *set, uint64_t *old) {
  uint64_t was = sig_mask;
  if (set) {
    if (how == SIG_BLOCK)
      sig_mask |= *set;
    else if (how == SIG_UNBLOCK)
      sig_mask &= ~*set;
    else if (how == SIG_SETMASK)
      sig_mask = *set;
    else
      return -EINVAL;
    sig_mask &= ~SIG_UNBLOCKABLE;
  }
  if (old) *old = was;
  return 0;
}

// sigsuspend and pause: wait with this mask until a signal is delivered, and
// return EINTR; the old mask comes back after the handler.
// Only a handler ends the wait: a signal that is ignored, by its
// disposition or by default, leaves it waiting.
static long sig_suspend(uint64_t mask) {
  uint64_t was = sig_mask;
  sig_mask = mask & ~SIG_UNBLOCKABLE;
  uint32_t ran = sig_handlers_ran;
  for (;;) {
    uint32_t seq = atomic_load(&sig_seq); // before the check: a signal after it changes sig_seq
    if (sig_pending & ~sig_mask) {
      sig_deliver_pending();
      if (sig_handlers_ran != ran) break;
      continue;
    }
    vx_futex_wait(&sig_seq, seq, VX_INFINITE); // an interrupt, or sig_note, ends it
  }
  sig_mask = was;
  return -EINTR;
}

static void sig_forget_pending(uint64_t which) {
  sig_pending &= ~which;
  for (int sig = 1; sig <= SIG_MAX; sig++)
    if (which & sig_bit(sig)) sig_sender[sig] = 0;
}

// What a child keeps of this process's signals (spawn_ctx), as a record for
// sig_init's: the ignored ones, and the mask.
static void sig_records(vx_ndb_writer *w, const spawn_ctx *ctx) {
  uint64_t ignored = 0;
  for (int sig = 1; sig <= SIG_MAX; sig++)
    if (sig_actions[sig].handler == (uintptr_t)SIG_IGN) ignored |= sig_bit(sig);
  vx_ndb_put_u64(w, "signals", ignored & ~ctx->sig_default);
  vx_ndb_put_u64(w, "mask", ctx->has_mask ? ctx->sig_mask : sig_mask);
  vx_ndb_end(w);
}

// kill(-1): every process but this one and svcd (pid 1), through /proc's list.
static long sig_kill_all(const char *note) {
  vx_ns_file dir;
  vx_status st = vx_ns_open(fd_namespace(), VX_STR("/proc"), P9_OREAD, &dir);
  if (st != VX_OK) return -ESRCH;
  static uint8_t buf[4096];
  long sent = 0;
  for (int64_t n; (n = vx_ns_read(&dir, buf, sizeof buf)) > 0;) {
    p9_stat entry;
    for (size_t off = 0; p9_dir_next(buf, (size_t)n, &off, &entry);) {
      char name[24] = {};
      memcpy(name, entry.name.ptr, entry.name.len < sizeof name - 1 ? entry.name.len : sizeof name - 1);
      long pid = strtol(name, nullptr, 10);
      if (pid > 1 && pid != posix_pid() && proc_write(pid, "note", note) == 0) sent++;
    }
  }
  vx_ns_close(&dir);
  if (sent) return 0;
  return -ESRCH;
}

static long sig_kill(long pid, int sig) {
  if (sig < 0 || sig > SIG_MAX) return -EINVAL;
  if (pid == posix_pid()) { // delivered as this call returns
    if (sig) sig_raise_self(sig);
    return 0;
  }
  if (!proc_mounted) return -ESRCH; // alone: no other process to reach
  char note[VX_ERRMAX + 1] = {};
  posix_note(sig, posix_pid(), note);
  if (!sig) { // only whether it is there: the process, or the group's leader
    long who = posix_pid();
    if (pid > 0)
      who = pid;
    else if (pid < -1)
      who = -pid;
    char buf[512];
    long r = proc_read(who, "status", buf, sizeof buf);
    return r < 0 ? r : 0;
  }
  if (pid > 0) return proc_write(pid, "note", note);
  if (pid == 0) return proc_write(posix_pid(), "notepg", note); // which reaches this process too
  if (pid < -1) return proc_write(-pid, "notepg", note);        // the group of its leader, -pid
  return sig_kill_all(note);
}
