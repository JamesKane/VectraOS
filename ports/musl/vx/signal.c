// signal.c: POSIX signals (docs/01 §9). Part of backend.c.
//
// Signals are built on notes (ADR-0010). The dispositions, the mask and the
// pending set live here, in the process. A signal from another process is a
// note ("posix: SIGTERM pid=12", or Plan 9's "interrupt" and the like) that
// posixd posts; sig_note, this process's note handler (lib/vx-rt/note.c),
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
// A stopping signal's default asks posixd to stop the process (POSIX_STOP);
// SIGSTOP from another process posixd carries out itself.
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

static uint64_t sig_mask, sig_pending;  // bit n - 1 for signal n
static int64_t sig_sender[SIG_MAX + 1]; // who sent each pending one
static volatile int sig_depth;          // inside __vx_syscall: delivery waits for its return
static uint32_t sig_handlers_ran;       // how many handlers have run

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
      int64_t args[1] = {sig};
      posix_msg rep;
      if (posix_chan) posix_call(posix_chan, POSIX_STOP, args, 1, VX_HANDLE_NONE, &rep, nullptr);
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
  if (flags & SA_SIGINFO) {
    siginfo_t info = {.si_signo = sig, .si_code = code};
    if (e)
      info.si_addr = (void *)address; // a fault's; a signal's sender shares the union with it
    else
      info.si_pid = (pid_t)sender;
    ucontext_t uc = {};
    memcpy(&uc.uc_sigmask, &old, sizeof old);
    ((void (*)(int, siginfo_t *, void *))h)(sig, &info, &uc);
  } else {
    ((void (*)(int))h)(sig);
  }
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
    if (sig_depth == 0) sig_deliver_pending(); // in the program's own code
    return VX_NCONT;
  }
  int sig = SIGSEGV, code = SEGV_MAPERR;
  switch (e->kind) {
  case VX_EXCEPTION_ALIGNMENT: sig = SIGBUS, code = BUS_ADRALN; break;
  case VX_EXCEPTION_ILLEGAL:
  case VX_EXCEPTION_FP_DISABLED: sig = SIGILL, code = ILL_ILLOPC; break;
  case VX_EXCEPTION_ARITHMETIC: sig = SIGFPE, code = FPE_INTDIV; break;
  case VX_EXCEPTION_BREAKPOINT:
  case VX_EXCEPTION_STEP: sig = SIGTRAP, code = TRAP_BRKPT; break;
  case VX_EXCEPTION_GENERAL: code = SI_KERNEL; break;
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
static long sig_suspend(uint64_t mask) {
  uint64_t was = sig_mask;
  sig_mask = mask & ~SIG_UNBLOCKABLE;
  static const _Atomic uint32_t never;
  for (;;) {
    if (sig_pending & ~sig_mask) {
      sig_deliver_pending();
      if (!(sig_pending & ~sig_mask)) break;
    }
    vx_futex_wait(&never, 0, VX_INFINITE); // an interrupt ends it, with the signal pending
  }
  sig_mask = was;
  return -EINTR;
}

static long sig_kill(long pid, int sig) {
  if (sig < 0 || sig > SIG_MAX) return -EINVAL;
  bool self = pid == posix_pid() || pid == 0 || pid == -1;
  if (posix_chan) {
    int64_t args[2] = {pid, sig};
    posix_msg rep;
    long r = posix_call(posix_chan, POSIX_KILL, args, 2, VX_HANDLE_NONE, &rep, nullptr);
    if (r < 0) return r;
    self = rep.arg[0] != 0;
  } else if (!self) {
    return -ESRCH;
  }
  if (self && sig) sig_raise_self(sig); // delivered as this call returns
  return 0;
}
