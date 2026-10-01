// signal.c: POSIX signals (docs/01 §9). Part of backend.c.
//
// The dispositions, the mask and the pending set live here, in the process.
// posixd delivers a signal from another process by thread_interrupt, which
// diverts this thread to __vx_sig_entry, the task's in-task exception handler;
// so does any fault, which becomes SIGSEGV, SIGBUS, SIGILL, SIGFPE or
// SIGTRAP. A signal to itself (raise, abort, kill of its own pid) is made
// pending here.
//
// A handler never runs inside the back end, which is not reentrant and may be
// in the middle of a ring submission: a signal that arrives there is made
// pending, the call it interrupted returns ERR_INTERRUPTED, and __vx_syscall
// delivers it on its way out. Then the call returns EINTR if a handler that
// is not SA_RESTART ran, and is made again otherwise. A signal that arrives
// in the program's own code is delivered at once, on its stack.
//
// Not yet: an alternate signal stack, the registers in a handler's ucontext,
// and stopping (SIGSTOP and the rest are ignored until job control, M4 step 4).

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

static uint64_t sig_bit(int sig) { return 1ull << (sig - 1); }
static constexpr uint64_t SIG_UNBLOCKABLE = 1ull << (SIGKILL - 1) | 1ull << (SIGSTOP - 1);

// Ends the process as the signal does by default: the wait status says which
// (lib/vx-posix/posix.h). A fault is reported first, as the kernel would.
[[noreturn]] static void sig_terminate(int sig, const vx_exception *e) {
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
  fd_exit();
  vx_thread_exit(-256 - sig);
}

// Carries out sig's disposition. Returns whether a call it interrupted
// returns EINTR: a handler ran that is not SA_RESTART.
static bool sig_act(int sig, int code, int64_t sender, uint64_t address, const vx_exception *e) {
  uintptr_t h = sig_actions[sig].handler;
  unsigned long flags = sig_actions[sig].flags;
  if (h == (uintptr_t)SIG_IGN) return false;
  if (h == (uintptr_t)SIG_DFL) {
    if (posix_default_ignored(sig) || sig == SIGSTOP || sig == SIGTSTP || sig == SIGTTIN || sig == SIGTTOU)
      return false;
    sig_terminate(sig, e);
  }
  uint64_t old = sig_mask;
  sig_mask |= sig_actions[sig].mask & ~SIG_UNBLOCKABLE;
  if (!(flags & SA_NODEFER)) sig_mask |= sig_bit(sig);
  if (flags & SA_RESETHAND) sig_actions[sig] = (typeof(sig_actions[0])){(uintptr_t)SIG_DFL, 0, 0};
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
    eintr = sig_act(sig, sig_sender[sig] ? SI_USER : SI_KERNEL, sig_sender[sig], 0, nullptr) || eintr;
  }
  return eintr;
}

static void sig_raise_self(int sig) {
  sig_pending |= sig_bit(sig);
  sig_sender[sig] = posix_pid();
}

// The in-task handler: a fault, or an interrupt carrying a signal.
[[gnu::used]] static void sig_handle(vx_exception *e) {
  if (e->kind == VX_EXCEPTION_INTERRUPT) {
    int sig = (int)(e->address & POSIX_SIGNAL_MASK);
    if (sig < 1 || sig > SIG_MAX) return;
    sig_pending |= sig_bit(sig);
    sig_sender[sig] = (int64_t)(e->address >> 16);
    if (sig_depth == 0) sig_deliver_pending(); // in the program's own code
    return;
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
  if ((sig_mask & sig_bit(sig)) || h == (uintptr_t)SIG_IGN) sig_terminate(sig, e);
  sig_act(sig, code, 0, e->address, e); // then the instruction again, unless the handler jumped away
}

// Resumes the thread where it was diverted from, with the registers it had.
[[gnu::used, noreturn]] static void sig_resume(vx_exception *e) {
  vx_syscall(VX_SYS_exception_resume, vx_self, 0, VX_RESUME_CONTINUE, (uint64_t)&e->regs, 0, 0);
  __builtin_trap(); // exception_resume does not return
}

// The handler's entry. The kernel saves the general registers in the
// vx_exception, but not FP/SIMD: they are saved here, on the stack, before
// any C runs, and loaded again before resuming.
#ifdef __x86_64__
__asm__(".text\n"
        ".global __vx_sig_entry\n"
        ".hidden __vx_sig_entry\n"
        ".type __vx_sig_entry, @function\n"
        "__vx_sig_entry:\n"
        "  endbr64\n"
        "  movq %rdi, %rbx\n" // the vx_exception, kept across the calls
        "  subq $528, %rsp\n"
        "  andq $-64, %rsp\n"
        "  fxsave64 (%rsp)\n"
        "  call sig_handle\n"
        "  fxrstor64 (%rsp)\n"
        "  movq %rbx, %rdi\n"
        "  call sig_resume\n"
        "  ud2\n");
#else
__asm__(".text\n"
        ".global __vx_sig_entry\n"
        ".hidden __vx_sig_entry\n"
        ".type __vx_sig_entry, %function\n"
        "__vx_sig_entry:\n"
        "  bti c\n"
        "  mov x19, x0\n" // the vx_exception, kept across the calls
        "  sub sp, sp, #528\n"
        "  stp q0, q1, [sp, #0]\n  stp q2, q3, [sp, #32]\n  stp q4, q5, [sp, #64]\n  stp q6, q7, [sp, #96]\n"
        "  stp q8, q9, [sp, #128]\n  stp q10, q11, [sp, #160]\n  stp q12, q13, [sp, #192]\n"
        "  stp q14, q15, [sp, #224]\n  stp q16, q17, [sp, #256]\n  stp q18, q19, [sp, #288]\n"
        "  stp q20, q21, [sp, #320]\n  stp q22, q23, [sp, #352]\n  stp q24, q25, [sp, #384]\n"
        "  stp q26, q27, [sp, #416]\n  stp q28, q29, [sp, #448]\n  stp q30, q31, [sp, #480]\n"
        "  mrs x9, fpcr\n  mrs x10, fpsr\n  add x11, sp, #512\n  stp x9, x10, [x11]\n"
        "  bl sig_handle\n"
        "  ldp q0, q1, [sp, #0]\n  ldp q2, q3, [sp, #32]\n  ldp q4, q5, [sp, #64]\n  ldp q6, q7, [sp, #96]\n"
        "  ldp q8, q9, [sp, #128]\n  ldp q10, q11, [sp, #160]\n  ldp q12, q13, [sp, #192]\n"
        "  ldp q14, q15, [sp, #224]\n  ldp q16, q17, [sp, #256]\n  ldp q18, q19, [sp, #288]\n"
        "  ldp q20, q21, [sp, #320]\n  ldp q22, q23, [sp, #352]\n  ldp q24, q25, [sp, #384]\n"
        "  ldp q26, q27, [sp, #416]\n  ldp q28, q29, [sp, #448]\n  ldp q30, q31, [sp, #480]\n"
        "  add x11, sp, #512\n  ldp x9, x10, [x11]\n  msr fpcr, x9\n  msr fpsr, x10\n"
        "  mov x0, x19\n"
        "  bl sig_resume\n"
        "  brk #0\n");
#endif

static void sig_init(void) {
  vx_exception_bind(vx_self, VX_HANDLE_NONE, (uint64_t)__vx_sig_entry, VX_EXCEPTION_IN_TASK);
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
