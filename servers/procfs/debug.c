// debug.c: /proc/N's debug files (docs/05 §3), as acid reads Plan 9's.
// Part of procfs.c.
//
//   /proc/N/ctl          also: break ADDR [if COND] [after N] · unbreak ADDR ·
//                        watch ADDR LEN write|rw · unwatch ADDR · step T ·
//                        freeze T · thaw T · detach
//   /proc/N/events       a read waits for a debug event, then returns its record:
//                          event=break thread=1 pc=0x401a20
//                          event=step thread=1 pc=0x401a24
//                          event=fault thread=1 pc=0x401a30 addr=0x0 access=read
//                          event=trap thread=1 pc=0x401a40   (a breakpoint the program has)
//                          event=watch thread=1 pc=0x401a50 addr=0x4c2008 access=write
//   /proc/N/mem          the address space as a file: read or write at an address
//   /proc/N/maps         one record per mapping: base= size= prot=r-x offset=
//   /proc/N/images       one record per ELF image: name= base= build-id=
//   /proc/N/info         arch= watchpoints= (the hardware's) breakpoints= (procfs's)
//   /proc/N/threads/T/   status (state= reason= pc=), regs (vx_regs, binary),
//                        regs.ndb (the same as one record; write NAME=VALUE to
//                        set), fpregs (vx_fpregs, binary), xregs (the whole FP/SIMD state, ADR-0035), ctl (step · resume ·
//                        freeze · thaw)
//
// Breakpoints live here, not in the debugger, so a shell script and dbg share
// them: procfs writes the trap (int3, brk #0) through task_mem_rw, which gives
// the task a private copy of the code page, and binds its port to the task's
// exceptions first (FIRST_CHANCE) the first time a breakpoint is set or
// events is opened. A
// thread that reaches one stays stopped, with an event, until ctl's start (or
// the thread's resume or step): then procfs puts the code back, steps the
// thread over it, and puts the trap back. A simple condition is evaluated here,
// without a round trip to the debugger: a register, or the word at an
// address, against a constant (`if rdi==3`, `if [0x7f001000]>=100`), and
// `after N` lets N hits go by. A fault stops the thread with an event, and
// resuming it passes the fault on, to the program's handler or the default.
// Watchpoints are the task's debug registers (thread_state SET_WATCH); a
// thread stopped at one is stepped past it with them off, since aarch64 stops
// before the access and would only stop again.
//
// Reading registers needs the thread held still: stopped at an event, or
// frozen (thread_suspend, as ctl's stop does to every thread).
//
// All-stop (M6 step 6d6a), as a debugger expects: when a thread stops with
// an event, procfs suspends every other thread of the task (each by its own
// thread_suspend, which counts, so a freeze of the debugger's own outlasts
// it), and starts them again when the stopped one is let go (its resume,
// ctl's start); a step of the stopped one leaves them stopped. While a
// thread steps over a breakpoint, its trap taken out, the others stay
// stopped too, even for a breakpoint whose condition let it go on, so none
// runs past the trap while it is out. A thread made while the others are
// stopped runs. Any number of threads are followed: the tables grow.

static constexpr uint32_t DBG_BREAKS = 32, DBG_EVENTS = 32, DBG_EVENT_LEN = 160, DBG_FIRST_THREADS = 16;

typedef enum cmp_op : uint8_t { CMP_NONE, CMP_EQ, CMP_NE, CMP_LT, CMP_LE, CMP_GT, CMP_GE } cmp_op;

typedef struct breakpoint {
  bool used;
  uint64_t addr;
  uint8_t orig[4]; // the code the trap replaced
  cmp_op op;       // the condition, if any: a register's value, or (mem) the word at `at`
  bool mem;
  uint32_t reg;
  uint64_t at, value;
  uint64_t after, hits; // it stops once hits > after
} breakpoint;

// Why procfs holds a thread stopped at its exception port.
typedef enum why : uint8_t {
  WHY_NONE,
  WHY_BREAK,
  WHY_STEP,
  WHY_FAULT,
  WHY_TRAP,
  WHY_OVER,
  WHY_WATCH,
  WHY_WOVER
} why;

typedef struct held {
  uint32_t tid;
  why why;
  bool user_step; // WHY_OVER: a step the debugger asked for, which ends with an event
  int32_t bp;     // WHY_BREAK, WHY_OVER: the breakpoint
  uint64_t pc;
  uint32_t kind, code; // WHY_FAULT: the fault, to know it again (passed below)
  uint64_t address;
} held;

// A fault passed on to the thread's own handler: one that declines it runs
// the instruction again (vx_note_crash), and the same fault comes back to
// procfs first. That one is passed on again, not a second stop (the Odin
// port's finding), so it reaches the default and the crash directory.
typedef struct passed {
  uint32_t tid, kind, code;
  uint64_t address, pc;
} passed;

typedef struct debugger {
  bool bound; // procfs's port takes the task's exceptions first
  breakpoint bp[DBG_BREAKS];
  vx_watches watches; // the task's watchpoints, as procfs set them
  // The threads followed (cap entries), and the faults passed on (pcap), in
  // memory of their own, each table grown alone (dbg_grow, passed_grow), so
  // growing one never moves a held entry a caller has: freed when the
  // debugger is forgotten.
  held *threads;
  passed *passed;
  uint32_t cap, pcap;
  // All-stop: the threads procfs suspended for an event or a step over, and
  // whether the debugger has let the task go on since its last event.
  uint32_t *paused;
  uint32_t npaused, cappaused;
  bool pausing, stopped;
  char events[DBG_EVENTS][DBG_EVENT_LEN];
  uint8_t lens[DBG_EVENTS];
  uint32_t ev_head, ev_count, lost;
} debugger;

static debugger dbgs[MAX_PROCS]; // by the process's slot

static debugger *dbg_of(const proc *p) { return &dbgs[p - procs]; }

// The key of a process's exception binding: as its exit key, with bit 40 set.
static constexpr uint64_t DBG_KEY_BIT = 1ull << 40;
static uint64_t dbg_key(const proc *p) { return exit_key(p) | DBG_KEY_BIT; }

#ifdef __x86_64__
static const uint8_t TRAP[] = {0xcc}; // int3
static const char *const REG_NAMES[] = {"rax", "rbx", "rcx", "rdx", "rsi", "rdi", "rbp", "rsp", "r8",
                                        "r9",  "r10", "r11", "r12", "r13", "r14", "r15", "rip", "rflags"};
static uint64_t *reg_pc(vx_regs *r) { return &r->rip; }
#else
static const uint8_t TRAP[] = {0x00, 0x00, 0x20, 0xd4}; // brk #0
static const char *const REG_NAMES[] = {"x0",  "x1",  "x2",  "x3",  "x4",  "x5",  "x6",    "x7",  "x8",
                                        "x9",  "x10", "x11", "x12", "x13", "x14", "x15",   "x16", "x17",
                                        "x18", "x19", "x20", "x21", "x22", "x23", "x24",   "x25", "x26",
                                        "x27", "x28", "x29", "x30", "sp",  "pc",  "pstate"};
static uint64_t *reg_pc(vx_regs *r) { return &r->pc; }
#endif
static constexpr uint32_t REG_COUNT = sizeof REG_NAMES / sizeof REG_NAMES[0];
static_assert(sizeof(vx_regs) == REG_COUNT * sizeof(uint64_t));
static_assert(sizeof(vx_regs) <= sizeof(vx_fpregs)); // procfs.c's write buffer holds either

static uint64_t *reg_at(vx_regs *r, uint32_t i) { return (uint64_t *)r + i; }

static int32_t reg_index(vx_str name) {
  for (uint32_t i = 0; i < REG_COUNT; i++)
    if (word_is(name, REG_NAMES[i])) return (int32_t)i;
  return -1;
}

// --- Text ---

static size_t hex_text(uint64_t v, char *out) {
  char digits[16];
  size_t n = 0;
  do digits[n++] = "0123456789abcdef"[v & 15];
  while (v >>= 4);
  out[0] = '0', out[1] = 'x';
  for (size_t i = 0; i < n; i++) out[2 + i] = digits[n - 1 - i];
  return n + 2;
}

static void put_dec(vx_ndb_writer *w, const char *key, uint64_t v) {
  char d[24];
  size_t n = sizeof d;
  do d[--n] = (char)('0' + v % 10);
  while (v /= 10);
  vx_ndb_put(w, key, (vx_str){d + n, sizeof d - n});
}

static void put_hex(vx_ndb_writer *w, const char *key, uint64_t v) {
  char buf[18];
  vx_ndb_put(w, key, (vx_str){buf, hex_text(v, buf)});
}

// A hexadecimal digit's value, or 16.
static uint64_t hex_digit(char c) {
  if (c >= '0' && c <= '9') return (uint64_t)(c - '0');
  if (c >= 'a' && c <= 'f') return (uint64_t)(c - 'a') + 10;
  if (c >= 'A' && c <= 'F') return (uint64_t)(c - 'A') + 10;
  return 16;
}

// A number: decimal, or hexadecimal after 0x.
static bool parse_num(vx_str s, uint64_t *out) {
  if (s.len > 2 && s.ptr[0] == '0' && (s.ptr[1] == 'x' || s.ptr[1] == 'X')) {
    uint64_t v = 0;
    if (s.len > 18) return false;
    for (size_t i = 2; i < s.len; i++) {
      uint64_t d = hex_digit(s.ptr[i]);
      if (d == 16) return false;
      v = v << 4 | d;
    }
    *out = v;
    return true;
  }
  return parse_u64(s, out);
}

// The next space-separated word of *s, taken off it.
static vx_str next_word(vx_str *s) {
  size_t i = 0;
  while (i < s->len && s->ptr[i] == ' ') i++;
  size_t start = i;
  while (i < s->len && s->ptr[i] != ' ') i++;
  vx_str w = {s->ptr + start, i - start};
  *s = (vx_str){s->ptr + i, s->len - i};
  return w;
}

// --- Events ---

static void dbg_event(proc *p, const char *kind, uint32_t tid, uint64_t pc, const char *extra) {
  debugger *d = dbg_of(p);
  if (d->ev_count == DBG_EVENTS) { // no one is reading: the newest are lost, and counted
    d->lost++;
    return;
  }
  uint32_t at = (d->ev_head + d->ev_count++) % DBG_EVENTS;
  vx_ndb_writer w = {.buf = d->events[at], .cap = DBG_EVENT_LEN};
  vx_ndb_put(&w, "event", vx_cstr(kind));
  vx_ndb_put_u64(&w, "thread", tid);
  put_hex(&w, "pc", pc);
  if (extra) {
    vx_str e = vx_cstr(extra);
    for (size_t i = 0; i < e.len && w.len + 1 < w.cap; i++) w.buf[w.len++] = e.ptr[i];
  }
  vx_ndb_end(&w);
  d->lens[at] = (uint8_t)(w.failed ? 0 : w.len);
  server.again = true; // a read of events held may go on
}

static vx_status take_event(proc *p, char *buf, size_t cap, size_t *len) {
  debugger *d = dbg_of(p);
  if (!d->ev_count) return VX_ERR_SHOULD_WAIT;
  uint32_t at = d->ev_head;
  d->ev_head = (d->ev_head + 1) % DBG_EVENTS;
  d->ev_count--;
  *len = d->lens[at] < cap ? d->lens[at] : cap;
  memcpy(buf, d->events[at], *len);
  return VX_OK;
}

// --- The task ---

static vx_status mem_rw(const proc *p, uint64_t addr, void *buf, uint64_t len, bool write) {
  vx_mem_op op = {.address = addr, .buffer = (uint64_t)buf, .size = len, .write = write};
  vx_status st = vx_task_mem_rw(p->task, &op, 1);
  return st != VX_OK ? st : (vx_status)op.status;
}

static vx_status dbg_bind(proc *p) {
  debugger *d = dbg_of(p);
  if (d->bound) return VX_OK;
  vx_status st = vx_exception_bind(p->task, server.port, dbg_key(p), VX_EXCEPTION_FIRST_CHANCE);
  d->bound = st == VX_OK;
  return st;
}

// Memory for the tables: a VMO of n bytes, mapped; nullptr if there is none.
static void *dbg_alloc(size_t n) {
  vx_handle vmo;
  uint64_t at = 0, size = (n + 4095) & ~(uint64_t)4095;
  if (vx_vmo_create(size, 0, &vmo) != VX_OK) return nullptr;
  vx_status st = vx_as_map(vx_self, vmo, 0, size, VX_MAP_WRITE, &at);
  vx_handle_close(vmo); // the mapping keeps it
  return st == VX_OK ? (void *)at : nullptr;
}

static void dbg_free(void *p, size_t n) {
  if (p) vx_as_unmap(vx_self, (uint64_t)p, (n + 4095) & ~(uint64_t)4095);
}

// The thread tables twice as big (or made): false if there is no memory.
static bool dbg_grow(debugger *d) {
  uint32_t cap = d->cap ? d->cap * 2 : DBG_FIRST_THREADS;
  held *t = dbg_alloc(cap * sizeof *t);
  if (!t) return false;
  memset(t, 0, cap * sizeof *t);
  if (d->cap) memcpy(t, d->threads, d->cap * sizeof *t), dbg_free(d->threads, d->cap * sizeof *t);
  d->threads = t, d->cap = cap;
  return true;
}

// The faults' table grown: never the threads', whose entries a caller of
// passed_of may hold (release's h; the Odin port's finding).
static bool passed_grow(debugger *d) {
  uint32_t cap = d->pcap ? d->pcap * 2 : DBG_FIRST_THREADS;
  passed *q = dbg_alloc(cap * sizeof *q);
  if (!q) return false;
  memset(q, 0, cap * sizeof *q);
  if (d->pcap) memcpy(q, d->passed, d->pcap * sizeof *q), dbg_free(d->passed, d->pcap * sizeof *q);
  d->passed = q, d->pcap = cap;
  return true;
}

static held *held_of(proc *p, uint32_t tid, bool make) {
  debugger *d = dbg_of(p);
  held *free_slot = nullptr;
  for (uint32_t i = 0; i < d->cap; i++) {
    if (d->threads[i].tid == tid) return &d->threads[i];
    if (!d->threads[i].tid && !free_slot) free_slot = &d->threads[i];
  }
  if (!make) return nullptr;
  if (!free_slot) {
    uint32_t at = d->cap;
    if (!dbg_grow(d)) return nullptr;
    free_slot = &d->threads[at];
  }
  *free_slot = (held){.tid = tid, .bp = -1};
  return free_slot;
}

// The fault last passed on for thread tid, or a free place for one; nullptr
// if neither (no memory for more: it is then stopped again).
static passed *passed_of(proc *p, uint32_t tid) {
  debugger *d = dbg_of(p);
  passed *free_slot = nullptr;
  for (uint32_t i = 0; i < d->pcap; i++) {
    if (d->passed[i].tid == tid) return &d->passed[i];
    if (!d->passed[i].tid && !free_slot) free_slot = &d->passed[i];
  }
  if (!free_slot) { // the new half is free
    uint32_t at = d->pcap;
    if (passed_grow(d)) free_slot = &d->passed[at];
  }
  return free_slot;
}

// --- All-stop (see the top) ---

static bool is_paused(const debugger *d, uint32_t tid) {
  for (uint32_t i = 0; i < d->npaused; i++)
    if (d->paused[i] == tid) return true;
  return false;
}

// Every other thread of p suspended: those paused already stay so, and
// threads made since are paused too; one held at an exception of its own
// is not, as it is stopped already and must be able to step when let go.
static void pause_others(proc *p, uint32_t tid) {
  debugger *d = dbg_of(p);
  d->pausing = true;
  vx_thread_info ti = {};
  while (vx_thread_state(p->task, ti.id, VX_STATE_NEXT_THREAD, &ti, sizeof ti) == VX_OK) {
    if (ti.id == tid || is_paused(d, ti.id)) continue;
    const held *h = held_of(p, ti.id, false);
    if (h && h->why != WHY_NONE) continue;
    if (d->npaused == d->cappaused) {
      uint32_t cap = d->cappaused ? d->cappaused * 2 : 64;
      uint32_t *more = dbg_alloc(cap * sizeof *more);
      if (!more) break; // the rest run: no memory to keep them
      if (d->paused)
        memcpy(more, d->paused, d->npaused * sizeof *more),
            dbg_free(d->paused, (size_t)d->cappaused * sizeof *more);
      d->paused = more, d->cappaused = cap;
    }
    if (vx_thread_suspend(p->task, ti.id) == VX_OK) d->paused[d->npaused++] = ti.id;
  }
}

// A thread whose exception came while procfs had it paused (it stopped at
// the same time as the one that paused it): not paused any more, as it is
// held at its exception, and a suspended thread could not step over a
// breakpoint when let go.
static void unpause_one(proc *p, uint32_t tid) {
  debugger *d = dbg_of(p);
  for (uint32_t i = 0; i < d->npaused; i++)
    if (d->paused[i] == tid) {
      vx_thread_resume(p->task, tid);
      d->paused[i] = d->paused[--d->npaused];
      return;
    }
}

// The paused threads started again, if the debugger has let the task go on
// and no thread is stepping over a breakpoint or a watchpoint on its own.
static void maybe_unpause(proc *p) {
  debugger *d = dbg_of(p);
  if (!d->pausing || d->stopped) return;
  for (uint32_t i = 0; i < d->cap; i++)
    if (d->threads[i].tid && (d->threads[i].why == WHY_OVER || d->threads[i].why == WHY_WOVER) &&
        !d->threads[i].user_step)
      return;
  for (uint32_t i = 0; i < d->npaused; i++) vx_thread_resume(p->task, d->paused[i]); // gone, it may be
  d->npaused = 0;
  d->pausing = false;
}

// An event reported: the task stays stopped until the debugger lets it go.
static void stop_all(proc *p, uint32_t tid) {
  dbg_of(p)->stopped = true;
  pause_others(p, tid);
}

static int32_t bp_at(const debugger *d, uint64_t addr) {
  for (uint32_t i = 0; i < DBG_BREAKS; i++)
    if (d->bp[i].used && d->bp[i].addr == addr) return (int32_t)i;
  return -1;
}

static bool bp_condition(const proc *p, const breakpoint *b, vx_regs *r) {
  if (b->op == CMP_NONE) return true;
  uint64_t v = 0;
  if (b->mem) {
    if (mem_rw(p, b->at, &v, sizeof v, false) != VX_OK) return true; // unreadable: stop, and let the user see
  } else {
    v = *reg_at(r, b->reg);
  }
  switch (b->op) {
  case CMP_EQ: return v == b->value;
  case CMP_NE: return v != b->value;
  case CMP_LT: return v < b->value;
  case CMP_LE: return v <= b->value;
  case CMP_GT: return v > b->value;
  case CMP_GE: return v >= b->value;
  default: return true;
  }
}

// Steps a thread held at breakpoint bp over it: the code put back for one
// instruction, then the trap again (dbg_exception, at the STEP).
static vx_status step_over(proc *p, held *h, bool user_step) {
  pause_others(p, h->tid); // none runs past the breakpoint while its trap is out
  const breakpoint *b = &dbg_of(p)->bp[h->bp];
  vx_status st = mem_rw(p, b->addr, (void *)b->orig, sizeof TRAP, true);
  if (st != VX_OK) return st;
  h->why = WHY_OVER;
  h->user_step = user_step;
  return vx_exception_resume(p->task, h->tid, VX_RESUME_STEP, nullptr);
}

// Sets the task's watchpoints: as procfs keeps them, or (off) none, while a
// thread steps past one.
static vx_status set_watches(proc *p, bool off) {
  vx_watches none = {};
  return vx_thread_state(p->task, 0, VX_STATE_SET_WATCH, off ? &none : &dbg_of(p)->watches, sizeof none);
}

// Steps a thread held at a watchpoint past it, the watchpoints off for the
// one instruction (dbg_exception puts them back, at the STEP).
static vx_status watch_over(proc *p, held *h, bool user_step) {
  pause_others(p, h->tid); // none passes the watchpoint while they are off
  vx_status st = set_watches(p, true);
  if (st != VX_OK) return st;
  h->why = WHY_WOVER;
  h->user_step = user_step;
  return vx_exception_resume(p->task, h->tid, VX_RESUME_STEP, nullptr);
}

// Lets a held thread go: over its breakpoint, past its fault (to whoever is
// next in line), or on.
static vx_status release(proc *p, held *h) {
  vx_status st;
  if (h->why == WHY_BREAK) return step_over(p, h, false);
  if (h->why == WHY_WATCH) return watch_over(p, h, false);
  if (h->why == WHY_OVER || h->why == WHY_WOVER) return VX_OK; // on its way already
  if (h->why == WHY_FAULT) {
    passed *q = passed_of(p, h->tid);
    if (q) *q = (passed){.tid = h->tid, .kind = h->kind, .code = h->code, .address = h->address, .pc = h->pc};
  }
  st = vx_exception_resume(p->task, h->tid,
                           h->why == WHY_FAULT || h->why == WHY_TRAP ? VX_RESUME_PASS : VX_RESUME_CONTINUE,
                           nullptr);
  *h = (held){};
  return st;
}

// A held thread let go by the debugger: the others with it, once it is past
// its breakpoint.
static vx_status let_go(proc *p, held *h) {
  dbg_of(p)->stopped = false;
  vx_status st = release(p, h);
  maybe_unpause(p);
  return st;
}

static vx_status step_thread(proc *p, uint32_t tid) {
  held *h = held_of(p, tid, false);
  if (!h || h->why == WHY_OVER || h->why == WHY_WOVER)
    return VX_ERR_BAD_STATE; // only one stopped at an event
  if (h->why == WHY_BREAK) return step_over(p, h, true);
  if (h->why == WHY_WATCH) return watch_over(p, h, true);
  h->why = WHY_OVER; // a step with no breakpoint to put back
  h->bp = -1;
  h->user_step = true;
  return vx_exception_resume(p->task, tid, VX_RESUME_STEP, nullptr);
}

static const char *fault_access(const vx_exception *e) {
  if (e->kind != VX_EXCEPTION_PAGE_FAULT) return "";
  if (e->code == 1) return " access=write";
  return e->code == 2 ? " access=exec" : " access=read";
}

// A thread of p stopped at procfs's port.
static void dbg_exception(proc *p, uint32_t tid) {
  debugger *d = dbg_of(p);
  vx_exception e;
  if (vx_thread_state(p->task, tid, VX_STATE_GET_EXCEPTION, &e, sizeof e) != VX_OK) return;
  if (!d->bound) { // queued before a detach, which let go of the port: let the thread go on
    uint64_t pc = *reg_pc(&e.regs);
    uint32_t go = VX_RESUME_CONTINUE; // a step or a watchpoint: nothing to see now
    if (e.kind == VX_EXCEPTION_BREAKPOINT) {
#ifdef __x86_64__
      uint64_t addr = pc - 1;
#else
      uint64_t addr = pc;
#endif
      uint8_t now[sizeof TRAP];
      // The trap still there is the program's own; one gone was a breakpoint
      // detach took out: the instruction it replaced runs, from its start.
      if (mem_rw(p, addr, now, sizeof now, false) == VX_OK && memcmp(now, TRAP, sizeof TRAP) != 0) {
        *reg_pc(&e.regs) = addr;
        vx_thread_state(p->task, tid, VX_STATE_SET_REGS, &e.regs, sizeof e.regs);
      } else {
        go = VX_RESUME_PASS;
      }
    } else if (e.kind != VX_EXCEPTION_STEP && e.kind != VX_EXCEPTION_WATCHPOINT) {
      go = VX_RESUME_PASS; // a fault: as if no debugger had been there
    }
    vx_exception_resume(p->task, tid, go, nullptr);
    return;
  }
  unpause_one(p, tid);
  held *h = held_of(p, tid, true);
  if (!h) { // no memory to follow it: let it go
    vx_exception_resume(p->task, tid, VX_RESUME_PASS, nullptr);
    return;
  }
  uint64_t pc = *reg_pc(&e.regs);
  if (e.kind == VX_EXCEPTION_STEP) {
    // The trap, back, once no other thread is stepping over it still: put back
    // under one that has not run the instruction yet, it would stop again.
    // So with the watchpoints (the Odin port's finding): back once no other
    // thread is past them.
    bool others = false;
    for (uint32_t i = 0; (h->why == WHY_OVER || h->why == WHY_WOVER) && i < d->cap && !others; i++)
      others = d->threads[i].tid && d->threads[i].tid != tid && d->threads[i].why == h->why &&
               (h->why == WHY_WOVER || d->threads[i].bp == h->bp);
    if (h->why == WHY_OVER && h->bp >= 0 && d->bp[h->bp].used && !others)
      mem_rw(p, d->bp[h->bp].addr, (void *)TRAP, sizeof TRAP, true);
    if (h->why == WHY_WOVER && !others) set_watches(p, false);          // the watchpoints, back
    if ((h->why == WHY_OVER || h->why == WHY_WOVER) && !h->user_step) { // past it, on the way on
      *h = (held){};
      vx_exception_resume(p->task, tid, VX_RESUME_CONTINUE, nullptr);
      maybe_unpause(p); // the others with it, unless the debugger holds them
      return;
    }
    *h = (held){.tid = tid, .why = WHY_STEP, .bp = -1, .pc = pc};
    stop_all(p, tid);
    dbg_event(p, "step", tid, pc, nullptr);
    return;
  }
  if (e.kind == VX_EXCEPTION_BREAKPOINT) {
#ifdef __x86_64__
    uint64_t addr = pc - 1; // int3 reports the instruction after it
#else
    uint64_t addr = pc;
#endif
    int32_t i = bp_at(d, addr);
    if (i < 0) { // the program's own
      *h = (held){.tid = tid, .why = WHY_TRAP, .bp = -1, .pc = pc};
      stop_all(p, tid);
      dbg_event(p, "trap", tid, pc, nullptr);
      return;
    }
    *reg_pc(&e.regs) = addr; // back at the instruction the trap replaced
    vx_thread_state(p->task, tid, VX_STATE_SET_REGS, &e.regs, sizeof e.regs);
    breakpoint *b = &d->bp[i];
    b->hits++;
    *h = (held){.tid = tid, .why = WHY_BREAK, .bp = i, .pc = addr};
    if (b->hits <= b->after || !bp_condition(p, b, &e.regs)) { // not this time: on, at once
      step_over(p, h, false);
      return;
    }
    stop_all(p, tid);
    dbg_event(p, "break", tid, addr, nullptr);
    return;
  }
  if (e.kind == VX_EXCEPTION_WATCHPOINT) {
    *h = (held){.tid = tid, .why = WHY_WATCH, .bp = -1, .pc = pc};
    const vx_watchpoint *w = &d->watches.slot[e.code < VX_WATCH_MAX ? e.code : 0];
    char extra[64] = " addr=";
    size_t n = 6 + hex_text(e.address, extra + 6);
    const char *access = w->kind == VX_WATCH_WRITE ? " access=write" : " access=rw";
    memcpy(extra + n, access, vx_cstr(access).len + 1);
    stop_all(p, tid);
    dbg_event(p, "watch", tid, pc, extra);
    return;
  }
  if (e.kind == VX_EXCEPTION_INTERRUPT) { // a note, not a fault: to the program's handler
    *h = (held){};
    vx_exception_resume(p->task, tid, VX_RESUME_PASS, nullptr);
    return;
  }
  passed *q = passed_of(p, tid);
  bool again =
      q && q->tid == tid && q->kind == e.kind && q->code == e.code && q->address == e.address && q->pc == pc;
  if (q) *q = (passed){};
  if (again) { // declined by its handler, and raised again: on to the default
    *h = (held){};
    vx_exception_resume(p->task, tid, VX_RESUME_PASS, nullptr);
    return;
  }
  *h = (held){
      .tid = tid, .why = WHY_FAULT, .bp = -1, .pc = pc, .kind = e.kind, .code = e.code, .address = e.address};
  char extra[64] = " addr=";
  size_t n = 6 + hex_text(e.address, extra + 6);
  const char *access = fault_access(&e);
  memcpy(extra + n, access, vx_cstr(access).len + 1);
  stop_all(p, tid);
  dbg_event(p, "fault", tid, pc, extra);
}

// Whether an event is waiting to be read: then ctl's start lets nothing go
// (M6 step 6d6a), so a debugger that continues after one thread's stop sees
// the stop another thread made at the same time before anything runs on.
static bool dbg_pending(const proc *p) { return dbg_of(p)->ev_count > 0; }

// Every held thread let go: ctl's start.
static void release_all(proc *p) {
  debugger *d = dbg_of(p);
  d->stopped = false;
  for (uint32_t i = 0; i < d->cap; i++)
    if (d->threads[i].tid) release(p, &d->threads[i]);
  maybe_unpause(p);
}

// --- ctl ---

static vx_status set_break(proc *p, vx_str args) {
  debugger *d = dbg_of(p);
  uint64_t addr;
  if (!parse_num(next_word(&args), &addr)) return VX_ERR_INVALID;
  breakpoint b = {.used = true, .addr = addr};
  for (vx_str w = next_word(&args); w.len; w = next_word(&args)) {
    if (word_is(w, "after")) {
      if (!parse_num(next_word(&args), &b.after)) return VX_ERR_INVALID;
      continue;
    }
    if (!word_is(w, "if")) return VX_ERR_INVALID;
    vx_str c = next_word(&args); // LHS OP VALUE, with no spaces: rdi==3, [0x1000]>=100
    size_t at = 0;
    while (at < c.len && c.ptr[at] != '=' && c.ptr[at] != '!' && c.ptr[at] != '<' && c.ptr[at] != '>') at++;
    if (at == 0 || at + 1 >= c.len) return VX_ERR_INVALID;
    vx_str lhs = {c.ptr, at}, rest = {c.ptr + at, c.len - at};
    static const struct {
      const char *text;
      cmp_op op;
    } OPS[] = {{"==", CMP_EQ}, {"!=", CMP_NE}, {"<=", CMP_LE}, {">=", CMP_GE}, {"<", CMP_LT}, {">", CMP_GT}};
    size_t oplen = 0;
    for (size_t k = 0; k < sizeof OPS / sizeof OPS[0] && !b.op; k++) {
      size_t n = vx_cstr(OPS[k].text).len;
      if (rest.len > n && memcmp(rest.ptr, OPS[k].text, n) == 0) b.op = OPS[k].op, oplen = n;
    }
    if (!b.op || !parse_num((vx_str){rest.ptr + oplen, rest.len - oplen}, &b.value)) return VX_ERR_INVALID;
    if (lhs.len > 2 && lhs.ptr[0] == '[' && lhs.ptr[lhs.len - 1] == ']') {
      b.mem = true;
      if (!parse_num((vx_str){lhs.ptr + 1, lhs.len - 2}, &b.at)) return VX_ERR_INVALID;
    } else {
      int32_t r = reg_index(lhs);
      if (r < 0) return VX_ERR_INVALID;
      b.reg = (uint32_t)r;
    }
  }
  int32_t i = bp_at(d, addr);
  if (i >= 0) { // the same place: its condition and count replaced, the trap kept
    memcpy(b.orig, d->bp[i].orig, sizeof b.orig);
    d->bp[i] = b;
    return VX_OK;
  }
  for (i = 0; i < (int32_t)DBG_BREAKS && d->bp[i].used; i++) {}
  if (i == (int32_t)DBG_BREAKS) return VX_ERR_NO_MEMORY;
  vx_status st = dbg_bind(p);
  if (st == VX_OK) st = mem_rw(p, addr, b.orig, sizeof TRAP, false);
  if (st == VX_OK) st = mem_rw(p, addr, (void *)TRAP, sizeof TRAP, true);
  if (st == VX_OK) d->bp[i] = b;
  return st;
}

static vx_status clear_break(proc *p, uint64_t addr) {
  debugger *d = dbg_of(p);
  int32_t i = bp_at(d, addr);
  if (i < 0) return VX_ERR_NOT_FOUND;
  vx_status st = VX_OK;
  bool stepping = false; // a thread stepping over it has the code back already, and must not get the trap
  for (uint32_t k = 0; k < d->cap; k++) {
    held *h = &d->threads[k];
    if (h->tid && h->bp == i) {
      stepping = stepping || h->why == WHY_OVER;
      if (h->why == WHY_BREAK) h->why = WHY_STEP; // held still, with nothing to step over
      h->bp = -1;
    }
  }
  if (!stepping) st = mem_rw(p, addr, d->bp[i].orig, sizeof TRAP, true);
  d->bp[i] = (breakpoint){};
  return st;
}

// watch ADDR LEN write|rw: a free slot of the hardware's; the same address
// again replaces it.
static vx_status set_watch(proc *p, vx_str args) {
  debugger *d = dbg_of(p);
  uint64_t addr, len;
  if (!parse_num(next_word(&args), &addr) || !parse_num(next_word(&args), &len)) return VX_ERR_INVALID;
  vx_str kind = next_word(&args);
  if (!word_is(kind, "write") && !word_is(kind, "rw")) return VX_ERR_INVALID;
  vx_watches now;
  vx_status st = vx_thread_state(p->task, 0, VX_STATE_GET_WATCH, &now, sizeof now); // the hardware's count
  if (st != VX_OK) return st;
  uint32_t slot = VX_WATCH_MAX;
  for (uint32_t i = 0; i < now.count && slot == VX_WATCH_MAX; i++)
    if (d->watches.slot[i].kind != VX_WATCH_OFF && d->watches.slot[i].address == addr) slot = i;
  for (uint32_t i = 0; i < now.count && slot == VX_WATCH_MAX; i++)
    if (d->watches.slot[i].kind == VX_WATCH_OFF) slot = i;
  if (slot == VX_WATCH_MAX) return VX_ERR_NO_MEMORY;
  if ((st = dbg_bind(p)) != VX_OK) return st;
  vx_watchpoint was = d->watches.slot[slot];
  d->watches.slot[slot] = (vx_watchpoint){
      .address = addr, .len = (uint32_t)len, .kind = word_is(kind, "write") ? VX_WATCH_WRITE : VX_WATCH_RW};
  st = set_watches(p, false);
  if (st != VX_OK) d->watches.slot[slot] = was; // refused (not aligned, say): as it was
  return st;
}

static vx_status clear_watch(proc *p, uint64_t addr) {
  debugger *d = dbg_of(p);
  for (uint32_t i = 0; i < VX_WATCH_MAX; i++)
    if (d->watches.slot[i].kind != VX_WATCH_OFF && d->watches.slot[i].address == addr) {
      d->watches.slot[i] = (vx_watchpoint){};
      return set_watches(p, false);
    }
  return VX_ERR_NOT_FOUND;
}

// Every breakpoint out, every held thread let go, the binding gone.
static void detach(proc *p) {
  debugger *d = dbg_of(p);
  for (uint32_t i = 0; i < DBG_BREAKS; i++)
    if (d->bp[i].used) clear_break(p, d->bp[i].addr);
  d->watches = (vx_watches){};
  set_watches(p, true);
  release_all(p);
  if (d->bound) vx_exception_bind(p->task, VX_HANDLE_NONE, 0, VX_EXCEPTION_FIRST_CHANCE);
  d->stopped = false;
  for (uint32_t i = 0; i < d->npaused; i++) vx_thread_resume(p->task, d->paused[i]); // whatever is in flight
  dbg_forget(p);
}

// ctl's debug verbs; NOT_FOUND for any other.
static vx_status dbg_ctl(proc *p, vx_str cmd) {
  vx_str args = cmd, verb = next_word(&args);
  uint64_t n;
  if (word_is(verb, "break")) return untouchable(p) ? VX_ERR_ACCESS : set_break(p, args);
  if (word_is(verb, "unbreak")) return parse_num(next_word(&args), &n) ? clear_break(p, n) : VX_ERR_INVALID;
  if (word_is(verb, "watch")) return untouchable(p) ? VX_ERR_ACCESS : set_watch(p, args);
  if (word_is(verb, "unwatch")) return parse_num(next_word(&args), &n) ? clear_watch(p, n) : VX_ERR_INVALID;
  if (word_is(verb, "detach")) {
    detach(p);
    return VX_OK;
  }
  bool step = word_is(verb, "step"), freeze = word_is(verb, "freeze"), thaw = word_is(verb, "thaw");
  if (!step && !freeze && !thaw) return VX_ERR_NOT_FOUND;
  if (!parse_u64(next_word(&args), &n) || !n || n > UINT32_MAX) return VX_ERR_INVALID;
  if (untouchable(p)) return VX_ERR_ACCESS;
  if (step) return step_thread(p, (uint32_t)n);
  return freeze ? vx_thread_suspend(p->task, n) : vx_thread_resume(p->task, n);
}

// A thread's ctl: step · resume · freeze · thaw.
static vx_status thread_ctl(proc *p, uint32_t tid, vx_str cmd) {
  if (untouchable(p)) return VX_ERR_ACCESS;
  if (word_is(cmd, "step")) return step_thread(p, tid);
  if (word_is(cmd, "freeze")) return vx_thread_suspend(p->task, tid);
  if (word_is(cmd, "thaw")) return vx_thread_resume(p->task, tid);
  if (!word_is(cmd, "resume")) return VX_ERR_INVALID;
  held *h = held_of(p, tid, false);
  return h ? let_go(p, h) : VX_ERR_BAD_STATE;
}

// --- The files ---

static size_t maps_text(const proc *p, char *buf, size_t cap) {
  vx_ndb_writer w = {.buf = buf, .cap = cap};
  vx_map_info m;
  for (uint64_t at = 0; vx_as_query(p->task, at, &m) == VX_OK && !w.failed; at = m.base + m.size) {
    put_hex(&w, "base", m.base);
    put_hex(&w, "size", m.size);
    char prot[3] = {'r', m.flags & VX_MAP_WRITE ? 'w' : '-', m.flags & VX_MAP_EXEC ? 'x' : '-'};
    vx_ndb_put(&w, "prot", (vx_str){prot, 3});
    put_hex(&w, "offset", m.offset);
    vx_ndb_end(&w);
  }
  return w.failed ? 0 : w.len;
}

// The program's ELF image: where its header is mapped (the lowest mapping
// that starts with one), and its build ID, from its PT_NOTE.
static size_t images_text(const proc *p, char *buf, size_t cap) {
  vx_task_summary info;
  if (vx_task_info(p->task, &info) != VX_OK) return 0;
  size_t name_len = 0;
  while (name_len < sizeof info.name && info.name[name_len]) name_len++;
  vx_map_info m;
  for (uint64_t at = 0; vx_as_query(p->task, at, &m) == VX_OK; at = m.base + m.size) {
    uint8_t eh[64];
    if (mem_rw(p, m.base, eh, sizeof eh, false) != VX_OK || memcmp(eh,
                                                                   "\x7f"
                                                                   "ELF",
                                                                   4) != 0)
      continue;
    uint64_t phoff, id_at = 0;
    uint16_t phentsize, phnum;
    memcpy(&phoff, eh + 32, 8), memcpy(&phentsize, eh + 54, 2), memcpy(&phnum, eh + 56, 2);
    uint32_t id_len = 0;
    for (uint16_t i = 0; i < phnum && i < 32 && phentsize >= 56 && !id_len; i++) {
      uint8_t ph[56];
      if (mem_rw(p, m.base + phoff + (uint64_t)i * phentsize, ph, sizeof ph, false) != VX_OK) break;
      uint32_t type;
      uint64_t vaddr, filesz;
      memcpy(&type, ph, 4), memcpy(&vaddr, ph + 16, 8), memcpy(&filesz, ph + 32, 8);
      for (uint64_t off = 0; type == 4 && off + 12 <= filesz && !id_len;) { // PT_NOTE: its notes
        uint32_t nh[3];
        if (mem_rw(p, vaddr + off, nh, sizeof nh, false) != VX_OK) break;
        uint64_t desc = vaddr + off + 12 + ((nh[0] + 3) & ~3u);
        if (nh[2] == 3 && nh[0] == 4 && nh[1] <= 32) id_at = desc, id_len = nh[1]; // NT_GNU_BUILD_ID, "GNU"
        off += 12 + ((nh[0] + 3) & ~3u) + ((nh[1] + 3) & ~3u);
      }
    }
    uint8_t id[32];
    char hex[64];
    if (id_len && mem_rw(p, id_at, id, id_len, false) != VX_OK) id_len = 0;
    for (size_t i = 0; i < id_len; i++)
      hex[2 * i] = "0123456789abcdef"[id[i] >> 4], hex[2 * i + 1] = "0123456789abcdef"[id[i] & 15];
    vx_ndb_writer w = {.buf = buf, .cap = cap};
    vx_ndb_put(&w, "name", (vx_str){info.name, name_len});
    put_hex(&w, "base", m.base);
    if (id_len) vx_ndb_put(&w, "build-id", (vx_str){hex, 2 * (size_t)id_len});
    vx_ndb_end(&w);
    return w.failed ? 0 : w.len;
  }
  return 0;
}

static const char *const RUN_STATES[] = {"", "running", "blocked", "stopped", "frozen"};
static const char *const REASONS[] = {"", "break", "step", "fault", "trap", "step", "watch", "step"};

static size_t info_text(const proc *p, char *buf, size_t cap) {
  vx_watches w;
  vx_ndb_writer out = {.buf = buf, .cap = cap};
#ifdef __x86_64__
  vx_ndb_put(&out, "arch", VX_STR("x86_64"));
#else
  vx_ndb_put(&out, "arch", VX_STR("aarch64"));
#endif
  if (vx_thread_state(p->task, 0, VX_STATE_GET_WATCH, &w, sizeof w) == VX_OK)
    vx_ndb_put_u64(&out, "watchpoints", w.count);
  vx_ndb_put_u64(&out, "breakpoints", DBG_BREAKS);
  vx_ndb_end(&out);
  return out.failed ? 0 : out.len;
}

static size_t thread_status_text(proc *p, uint32_t tid, char *buf, size_t cap) {
  vx_thread_info ti;
  if (vx_thread_state(p->task, tid - 1, VX_STATE_NEXT_THREAD, &ti, sizeof ti) != VX_OK || ti.id != tid)
    return 0;
  vx_ndb_writer w = {.buf = buf, .cap = cap};
  // Suspended while blocked in a call: frozen, as it runs no more when the call returns (6d6a).
  uint32_t state = ti.state == VX_THREAD_BLOCKED && ti.suspend_count ? VX_THREAD_SUSPENDED : ti.state;
  vx_ndb_put(&w, "state", vx_cstr(state <= VX_THREAD_SUSPENDED ? RUN_STATES[state] : "unknown"));
  const held *h = held_of(p, tid, false);
  if (h && h->why) vx_ndb_put(&w, "reason", vx_cstr(REASONS[h->why]));
  vx_regs r;
  if (vx_thread_state(p->task, tid, VX_STATE_GET_REGS, &r, sizeof r) == VX_OK) put_hex(&w, "pc", *reg_pc(&r));
  vx_ndb_end(&w);
  return w.failed ? 0 : w.len;
}

// threads/T/sched (ADR-0038): its intent, and its context's period, budget,
// what is left of it this period, the periods it ran out in, and its CPUs.
static size_t sched_text(const proc *p, uint32_t tid, char *buf, size_t cap) {
  static const char *const INTENTS[] = {"",           "realtime",  "interactive-frame", "interactive",
                                        "throughput", "background"};
  vx_sched_info si;
  if (vx_thread_state(p->task, tid, VX_STATE_GET_SCHED, &si, sizeof si) != VX_OK) return 0;
  vx_ndb_writer w = {.buf = buf, .cap = cap};
  vx_ndb_put(&w, "intent", vx_cstr(si.intent <= VX_INTENT_BACKGROUND ? INTENTS[si.intent] : "unknown"));
  vx_ndb_put(&w, "context", si.bound ? VX_STR("yes") : VX_STR("no"));
  if (si.period) {
    put_dec(&w, "period", (uint64_t)si.period), put_dec(&w, "budget", (uint64_t)si.budget);
    put_dec(&w, "left", (uint64_t)si.left), put_dec(&w, "exhausted", si.exhausted);
  }
  if (si.reserved) put_hex(&w, "reserved", si.reserved), put_dec(&w, "cores", si.reserved_count);
  if (si.core >= 0) put_dec(&w, "core", (uint64_t)si.core);
  if (si.lent_task) put_dec(&w, "lent_task", si.lent_task), put_dec(&w, "lent_thread", si.lent_thread);
  vx_ndb_end(&w);
  return w.failed ? 0 : w.len;
}

static size_t regs_ndb_text(const proc *p, uint32_t tid, char *buf, size_t cap) {
  vx_regs r;
  if (vx_thread_state(p->task, tid, VX_STATE_GET_REGS, &r, sizeof r) != VX_OK) return 0;
  vx_ndb_writer w = {.buf = buf, .cap = cap};
  for (uint32_t i = 0; i < REG_COUNT; i++) put_hex(&w, REG_NAMES[i], *reg_at(&r, i));
#ifdef __x86_64__
  // Its protection-key rights (ADR-0035), where there are keys: PKRU, from
  // its extended state at the place CPUID gives it. xregs sets them.
  static uint8_t xs[4096];
  if (vx_cpu()->keys && vx_thread_state(p->task, tid, VX_STATE_GET_XSTATE, xs, sizeof xs) == VX_OK) {
    uint32_t a = 0xd, b, c = 9, d;
    __asm__ volatile("cpuid" : "+a"(a), "=b"(b), "+c"(c), "=d"(d));
    uint32_t pkru;
    if (b + sizeof pkru <= sizeof xs) memcpy(&pkru, xs + b, sizeof pkru), put_hex(&w, "rights", pkru);
  }
#endif
  vx_ndb_end(&w);
  return w.failed ? 0 : w.len;
}

// NAME=VALUE ...: those registers set, the rest as they are.
static vx_status regs_ndb_write(const proc *p, uint32_t tid, vx_str s) {
  vx_regs r;
  vx_status st = vx_thread_state(p->task, tid, VX_STATE_GET_REGS, &r, sizeof r);
  if (st != VX_OK) return st;
  for (vx_str t = next_word(&s); t.len; t = next_word(&s)) {
    size_t eq = 0;
    while (eq < t.len && t.ptr[eq] != '=') eq++;
    uint64_t v;
    int32_t i = reg_index((vx_str){t.ptr, eq});
    if (i < 0 || eq == t.len || !parse_num((vx_str){t.ptr + eq + 1, t.len - eq - 1}, &v))
      return VX_ERR_INVALID;
    *reg_at(&r, (uint32_t)i) = v;
  }
  return vx_thread_state(p->task, tid, VX_STATE_SET_REGS, &r, sizeof r);
}

// A process ended, or its slot is reused: nothing of its debugging is left.
static void dbg_forget(const proc *p) {
  debugger *d = dbg_of(p);
  dbg_free(d->threads, d->cap * sizeof *d->threads), dbg_free(d->passed, d->pcap * sizeof *d->passed);
  dbg_free(d->paused, d->cappaused * sizeof *d->paused);
  *d = (debugger){};
}
