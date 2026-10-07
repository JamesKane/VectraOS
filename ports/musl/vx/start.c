// start.c: the process: its start from the spawn message, its exit, what it
// is, and time. Part of backend.c.

// The program's ELF header, which lld places at the start of the first loaded
// segment: musl finds the TLS segment through AT_PHDR.
extern const Elf64_Ehdr __ehdr_start;

int __libc_start_main(int (*main)(int, char **, char **), int argc, char **argv, void (*init)(void),
                      void (*fini)(void), void (*ldso)(void));

static uint64_t proc_kernel_task_id; // the kernel's id for the task
static void posix_init(void);        // process.c
static void sig_init(void);          // signal.c

// What Linux puts on a new process's stack, built here instead: argc, the
// arguments, the environment and the auxiliary vector, one array as musl
// reads it, and the strings they point to.
static constexpr uint32_t PROC_AUX = 12; // pairs
static struct {
  uintptr_t words[1 + VX_SPAWN_MAX_ARGS + 2 + VX_SPAWN_MAX_ARGS + 1 + 2 * PROC_AUX];
  char strings[VX_CHANNEL_MAX_BYTES + 2 * VX_SPAWN_MAX_ARGS + 64];
  uint8_t random[16];
} proc_start;

static char *proc_string(size_t *used, vx_str s) {
  char *p = proc_start.strings + *used;
  memcpy(p, s.ptr, s.len);
  p[s.len] = 0;
  *used += s.len + 1;
  return p;
}

// The process's random generator (lib/vx-rand), seeded with the entropy= its
// parent gave it (svcd, or a POSIX parent: spawn_records). It makes AT_RANDOM,
// which seeds musl's stack protector and malloc, answers getrandom, and
// seeds each child. A process given no seed has an unseeded generator:
// AT_RANDOM then comes from the clock and its layout, not secret, and
// getrandom fails (EAGAIN) rather than pretend.
static vx_drbg proc_entropy;

static void proc_random(void) {
  vx_ndb_record rec;
  vx_str seed = vx_spawn_record("entropy", &rec) ? vx_ndb_get(&rec, "entropy") : (vx_str){};
  if (seed.len >= 16) vx_drbg_mix(&proc_entropy, seed.ptr, seed.len, true);
  uint64_t fallback[2] = {(uint64_t)vx_clock_read(), (uintptr_t)&proc_start ^ proc_kernel_task_id << 32};
  if (!proc_entropy.seeded) vx_drbg_mix(&proc_entropy, fallback, sizeof fallback, false);
  vx_drbg_read(&proc_entropy, proc_start.random, sizeof proc_start.random);
}

// vx-rt spawn.c's seed for a child (a POSIX parent's records carry their own).
static void vx_random_bytes(void *out, size_t n) { vx_drbg_read(&proc_entropy, out, n); }

static long proc_getrandom(void *buf, size_t n) {
  if (!proc_entropy.seeded) return -EAGAIN;
  if (n > 1u << 20) n = 1u << 20;
  vx_drbg_read(&proc_entropy, buf, n);
  return (long)n;
}

// Called by crt1's _start with the bootstrap channel and the program's main.
// argv[0] is the program's name from the spawn message; its arguments follow.
// No stack protector: musl sets the guard (from AT_RANDOM) while this frame
// is live, and this function never returns to check it.
[[gnu::no_stack_protector]] void __vx_start(vx_handle bootstrap, int (*main)(int, char **, char **)) {
  vx_read_spawn(bootstrap);
  fd_init();
  vx_task_summary me;
  if (vx_self && vx_task_info(vx_self, &me) == VX_OK) proc_kernel_task_id = me.id;
  posix_init();
  sig_init();
  proc_random();

  uintptr_t *w = proc_start.words;
  size_t used = 0, n = 0;
  uint32_t argc = 1 + vx_spawn.argc;
  w[n++] = argc;
  vx_str argv0 = vx_spawn.argv0.ptr ? vx_spawn.argv0 : vx_spawn.name; // argv0= from a POSIX parent
  char *name = proc_string(&used, argv0.len ? argv0 : VX_STR("a.out"));
  w[n++] = (uintptr_t)name;
  for (uint32_t i = 0; i < vx_spawn.argc; i++) w[n++] = (uintptr_t)proc_string(&used, vx_spawn.args[i]);
  w[n++] = 0;
  for (uint32_t i = 0; i < vx_spawn.envc; i++) w[n++] = (uintptr_t)proc_string(&used, vx_spawn.envs[i]);
  w[n++] = 0;
  const uintptr_t aux[PROC_AUX * 2] = {
      AT_PHDR,   (uintptr_t)&__ehdr_start + __ehdr_start.e_phoff,
      AT_PHENT,  sizeof(Elf64_Phdr),
      AT_PHNUM,  __ehdr_start.e_phnum,
      AT_PAGESZ, 4096,
      AT_RANDOM, (uintptr_t)proc_start.random,
      AT_EXECFN, (uintptr_t)name,
      AT_NULL,   0,
  };
  memcpy(w + n, aux, sizeof aux);
  __libc_start_main(main, (int)argc, (char **)(w + 1), nullptr, nullptr, nullptr);
  __builtin_trap(); // it ends in exit, never returning
}

// Ends the process with msg as its exit string (ADR-0010). The back end's
// buffers go out first, and stdout's pipe closes so its reader sees the end
// of the file.
[[noreturn]] static void proc_exit_str(vx_str msg) {
  fd_exit();
  vx_task_kill(vx_self, msg);
  vx_thread_exit();
}

// exit and exit_group (musl has flushed its own buffers): as APE does, exit
// code 0 is the empty exit string, and any other is its number in decimal.
// The code is the status's low byte, all a parent's wait can see.
[[noreturn]] static void proc_exit(int status) {
  char code[4];
  vx_note_buf b = {code, 0, sizeof code};
  if (status & 0xff) vx_note_dec(&b, (uint64_t)(status & 0xff));
  proc_exit_str((vx_str){code, b.len});
}

static uint64_t proc_kernel_id(void) { return proc_kernel_task_id; }

// The process's user id (6e1c3): its user's in users(6), from /adm/users
// where the namespace has it; else adm 0, none 1, and any other 1000, the id
// install gives the first user. Each user is its own group, as in Plan 9, so
// the gid is the same. Looked up once.
static long proc_uid(void) {
  static long uid = -1;
  if (uid >= 0) return uid;
  vx_str name = vx_user_name();
  uid = 1000;
  if (name.len == 3 && !memcmp(name.ptr, "adm", 3)) uid = 0;
  if (name.len == 4 && !memcmp(name.ptr, "none", 4)) uid = 1;
  static char text[16 * 1024];
  static vx_users table;
  size_t len = 0;
  if (vx_ns_read_all(fd_namespace(), VX_STR("/adm/users"), text, sizeof text, &len) == VX_OK &&
      vx_users_parse(&table, (vx_str){text, len})) {
    uint32_t i = vx_users_named(&table, name);
    if (i != table.none || (name.len == 4 && !memcmp(name.ptr, "none", 4))) uid = table.user[i].id;
  }
  return uid;
}

// setuid and its kin: to the ids the process has, a no-op; to any other, EPERM.
static long proc_setid(long a, long b, long c) {
  long me = proc_uid(), ids[3] = {a, b, c};
  for (int i = 0; i < 3; i++)
    if (ids[i] != -1 && ids[i] != me) return -EPERM;
  return 0;
}

static long proc_uname(struct utsname *u) {
  *u = (struct utsname){};
  memcpy(u->sysname, "VectraOS", 9);
  vx_hostname(fd_namespace(), u->nodename, sizeof u->nodename - 1); // /sys/name (6e1c3)
  memcpy(u->release, "0.1.0", 6);
  memcpy(u->version, "M6", 3);
#ifdef __x86_64__
  memcpy(u->machine, "x86_64", 7);
#else
  memcpy(u->machine, "aarch64", 8);
#endif
  return 0;
}

// getrlimit and prlimit: no limits are set, except the descriptor table's size.
static long proc_prlimit(struct rlimit *old) {
  if (old) *old = (struct rlimit){RLIM_INFINITY, RLIM_INFINITY};
  return 0;
}

#ifdef SYS_set_thread_area // x86_64's FS base; aarch64's musl writes TPIDR_EL0 itself
static long proc_set_tls(uint64_t p) {
  return vx_errno(vx_thread_state(vx_self, 0, VX_STATE_SET_TLS, &p, sizeof p));
}
#endif

// --- Time ---
//
// Every clock is the kernel's monotonic one, in nanoseconds since boot; the
// realtime clocks add the kernel's UTC offset (ADR-0031), which is 0 until
// a clock driver has set it (no RTC: 1970, as before). The CPU-time clocks
// are the kernel's samples of the process's and the thread's (ADR-0041), to
// 10 ms; another thread's or process's (a negative id) is refused.

static bool time_is_utc(clockid_t clock) {
  return clock == CLOCK_REALTIME || clock == CLOCK_REALTIME_COARSE || clock == CLOCK_REALTIME_ALARM ||
         clock == CLOCK_TAI;
}

static vx_cpu_times cpu_times(bool thread); // process.c

static long time_get(clockid_t clock, struct timespec *ts) {
  if (clock < 0 || clock > CLOCK_TAI) return -EINVAL;
  vx_instant now = time_is_utc(clock) ? vx_clock_utc() : vx_clock_read();
  if (clock == CLOCK_PROCESS_CPUTIME_ID || clock == CLOCK_THREAD_CPUTIME_ID) {
    vx_cpu_times t = cpu_times(clock == CLOCK_THREAD_CPUTIME_ID);
    now = t.user + t.sys;
  }
  if (now < 0) now = 0;
  *ts = (struct timespec){.tv_sec = now / 1'000'000'000, .tv_nsec = now % 1'000'000'000};
  return 0;
}

static long time_res(clockid_t clock, struct timespec *ts) {
  bool cpu = clock == CLOCK_PROCESS_CPUTIME_ID || clock == CLOCK_THREAD_CPUTIME_ID;
  if (ts) *ts = (struct timespec){.tv_sec = 0, .tv_nsec = cpu ? 10'000'000 : 1}; // the kernel's tick
  return 0;
}

static long time_deadline(const struct timespec *ts, bool absolute, vx_instant *out) {
  if (ts->tv_sec < 0 || ts->tv_nsec < 0 || ts->tv_nsec >= 1'000'000'000) return -EINVAL;
  vx_instant d = 0;
  if (ckd_mul(&d, (vx_instant)ts->tv_sec, (vx_instant)1'000'000'000) || ckd_add(&d, d, ts->tv_nsec) ||
      (!absolute && ckd_add(&d, d, vx_clock_read())))
    d = VX_INFINITE;
  *out = d;
  return 0;
}

// Changed by sig_note for each signal that comes while the back end runs: a
// sleep waits on it, so one that comes just before the sleep ends it too.
static _Atomic uint32_t sig_seq;

// A sleep ends early with EINTR when a signal interrupts it, with what was
// left in *rem; made again after the signal (signal.c), it keeps its deadline.
static long time_sleep(clockid_t clock, int flags, const struct timespec *req, struct timespec *rem) {
  if (clock < 0 || clock > CLOCK_TAI) return -EINVAL;
  vx_instant *deadline = &sig_call_deadline;
  long st = 0;
  if (!sig_restarting) st = time_deadline(req, flags & TIMER_ABSTIME, deadline);
  if (!sig_restarting && st == 0 && (flags & TIMER_ABSTIME) && time_is_utc(clock) && *deadline != VX_INFINITE)
    *deadline -= vx_clock_utc() - vx_clock_read(); // a time of day: on the monotonic clock
  while (st == 0 && vx_clock_read() < *deadline) {
    uint32_t seq = atomic_load(&sig_seq);
    uint32_t held = be_wait_begin();
    vx_status w = vx_futex_wait(&sig_seq, seq, *deadline);
    be_wait_end(held);
    if (w != VX_ERR_INTERRUPTED && w != VX_ERR_BAD_STATE) continue; // the deadline, or nothing
    vx_instant left = *deadline - vx_clock_read();
    if (left < 0) left = 0;
    if (rem && !(flags & TIMER_ABSTIME)) *rem = (struct timespec){left / 1'000'000'000, left % 1'000'000'000};
    return -EINTR;
  }
  return st;
}

// Linux's futex operations, which musl's public headers do not have; the
// private and clock flags (128, 256) change nothing here.
enum { FUTEX_WAIT = 0, FUTEX_WAKE = 1, FUTEX_CMD_MASK = 127 };

static long time_futex(uint32_t *word, int op, uint32_t value, const struct timespec *timeout) {
  switch (op & FUTEX_CMD_MASK) {
  case FUTEX_WAIT: {
    vx_instant deadline = VX_INFINITE;
    long st = timeout ? time_deadline(timeout, false, &deadline) : 0;
    if (st != 0) return st;
    uint32_t held = be_wait_begin(); // a pthread mutex's or condition's: its waker is another thread
    vx_status vst = vx_futex_wait((const _Atomic uint32_t *)word, value, deadline);
    be_wait_end(held);
    return vst == VX_ERR_BAD_STATE ? -EAGAIN : vx_errno(vst); // the word had changed
  }
  case FUTEX_WAKE: return vx_futex_wake((const _Atomic uint32_t *)word, value);
  default: return -ENOSYS;
  }
}
