// procfs: /proc, the one process table (ADR-0011), with 9front's files.
//
// A process's pid is its task's kernel id, which is never reused, and exec
// keeps the task (ADR-0012). Whoever spawns a process registers it here
// before it runs (lib/vx-proc/proc.h), on the listen channel posted as
// /srv/proc, with a handle to its task; svcd is registered through the
// "tasks" handle it gives procfs, and registers the services it started
// before procfs.
//
//   /proc/N/status   one ndb record: pid=7 name=gsh state=waiting threads=1 mem=412K sid=7
//   /proc/N/ctl      kill · stop [SIG] · start · setsid · childnotes
//   /proc/N/note     a write posts a note (ADR-0010)
//   /proc/N/notepg   a write posts a note to every process in N's note group
//   /proc/N/noteid   N's note group: read it, or write a group's id to join it
//   /proc/N/ppid     the parent's pid
//   /proc/N/ns       its namespace group's text, namespace(6) (ADR-0009), from nsd
//   /proc/N/wait     a read waits for a child to end, then returns its record:
//                    pid=9 name=ls noteid=7 status="" real=12 (ms); its length is the count
//
// As in 9front's pexit, a process that ends leaves a wait record for its
// parent, at most 128 queued, unless it was registered with PROC_NOWAIT, or
// the parent has gone or is not registered. A parent that goes leaves its
// children's ppid as it was. A note posted to a process whose wait read procfs
// holds ends that read, "interrupted", after the note, so the caller sees the
// note first, as ptyd does with the reads it holds.
//
// notepg includes the writer, unlike 9front's: a note to oneself is delivered
// before the write returns, so kill(0) signals the caller too, as POSIX has it.
//
// For POSIX (lib/vx-posix/posix.h), which builds signals on notes: procfs
// carries out the ones a process cannot, being stopped or unable to catch
// them: a note naming SIGKILL kills, SIGSTOP stops, and SIGCONT continues
// before it is delivered. A process that writes `childnotes` to its ctl gets
// the note "posix: SIGCHLD pid=N" when a child ends, stops or continues, and
// wait records for stops (stopped=SIG) and continues (continued) too.
//
// The debug files (05 §3: events, mem, maps, images, threads/, and ctl's
// break, step and the rest) are debug.c's; crash directories (05 §5),
// crash.c's; profiling zones (05 §9, /proc/N/prof), prof.c's.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-proc/proc.h"
#include "../../lib/vx-posix/posix.h"
#include "../../lib/vx-ns/nsd.h"
#include "../../lib/vx-prof/prof.h"

static constexpr uint32_t MAX_PROCS = 128;
static constexpr uint32_t MAX_RECORDS = 2048; // wait records, for every parent together: 16 parents' worth
static constexpr uint32_t MAX_WAITS = 128;    // queued for one parent, as 9front's pexit

typedef struct proc {
  bool used;
  bool root;        // svcd, through "tasks": never killed
  bool nowait;      // its parent wants no record of its end
  bool stopped;     // ctl stop
  bool wait_held;   // a read of its wait file is held
  bool interrupted; // a note came while it was: the read ends
  bool childnotes;  // SIGCHLD notes, and records of children's stops and continues (POSIX)
  uint32_t gen;
  uint64_t pid, ppid, noteid, sid;
  vx_handle task;
  vx_instant start;
  uint32_t nwait;       // records queued for it
  uint32_t first, last; // its queue, through record.next; 0 is none
} proc;

enum record_kind : uint8_t { ENDED, STOPPED, CONTINUED };

typedef struct record {
  uint32_t next;   // 0: the end
  uint64_t pid;    // 0: the slot is free
  uint8_t kind;    // enum record_kind
  uint8_t sig;     // STOPPED: the signal that stopped it
  uint64_t noteid; // its note group then, for a POSIX wait for a group's children
  uint64_t real_ms;
  char name[24];
  uint8_t len;
  char status[VX_ERRMAX];
} record;

static proc procs[MAX_PROCS];
static record records[MAX_RECORDS + 1]; // records[0] is never used
static p9_ring_server server;

static proc *by_pid(uint64_t pid) {
  for (uint32_t i = 0; pid && i < MAX_PROCS; i++)
    if (procs[i].used && procs[i].pid == pid) return &procs[i];
  return nullptr;
}

// The key of a process's EXIT binding: its slot and the slot's generation.
static uint64_t exit_key(const proc *p) {
  return P9_KEY_USER | (uint64_t)p->gen << 16 | (uint64_t)(p - procs);
}

// Whether p has living children that will leave a record, for a wait to wait for.
static bool has_children(const proc *p) {
  for (uint32_t i = 0; i < MAX_PROCS; i++)
    if (procs[i].used && procs[i].ppid == p->pid && !procs[i].nowait && &procs[i] != p) return true;
  return false;
}

static uint64_t self_id; // procfs's own pid

// A new process for task (which it takes, if it succeeds), its parent's pid, and flags.
static vx_status admit(vx_handle task, uint64_t ppid, uint32_t flags, uint64_t group, bool root, proc **out) {
  vx_task_summary info;
  if (vx_task_info(task, &info) != VX_OK || info.state == VX_TASK_EXITED) return VX_ERR_INVALID;
  if (by_pid(info.id)) return VX_ERR_EXISTS;
  uint32_t slot = 0;
  while (slot < MAX_PROCS && procs[slot].used) slot++;
  if (slot == MAX_PROCS) return VX_ERR_NO_MEMORY;
  proc *p = &procs[slot];
  const proc *parent = by_pid(ppid);
  *p = (proc){.used = true,
              .root = root,
              .nowait = flags & PROC_NOWAIT,
              .gen = (p->gen + 1) & 0xff'ffff, // 24 bits in the keys
              .pid = info.id,
              .ppid = ppid,
              .task = task,
              .start = vx_clock_read()};
  p->noteid = parent && !(flags & (PROC_NOTEG | PROC_SETSID)) ? parent->noteid : p->pid;
  p->sid = parent && !(flags & PROC_SETSID) ? parent->sid : p->pid;
  bool joined = !group;
  for (uint32_t i = 0; i < MAX_PROCS && !joined; i++)
    joined = procs[i].used && &procs[i] != p && procs[i].noteid == group && procs[i].sid == p->sid;
  if (!joined) {
    *p = (proc){.gen = p->gen};
    return VX_ERR_ACCESS; // not a group in its session
  }
  if (group) p->noteid = group;
  // svcd, the root, never ends; its handle ("tasks") carries no WAIT right.
  // A fault nothing else takes comes to procfs, for a crash directory
  // (crash.c); but not procfs's own, which would wait for procfs to take it:
  // procfs ends instead, and svcd starts it again.
  vx_status st = root ? VX_OK : vx_port_bind(server.port, task, VX_TRIGGER_EXIT, exit_key(p), 0);
  if (st == VX_OK && !root && info.id != self_id)
    st = vx_exception_bind(task, server.port, exit_key(p) | (1ull << 41), 0);
  if (st != VX_OK) {
    *p = (proc){.gen = p->gen};
    return st;
  }
  *out = p;
  return VX_OK;
}

// A registration on the listen channel (lib/vx-proc/proc.h).
static vx_status prof_register(const proc_msg *m, vx_handle vmo); // prof.c

static void registered(void *ctx, const void *msg, uint32_t len, vx_handle handle) {
  (void)ctx;
  proc_msg m = {};
  memcpy(&m, msg, len < sizeof m ? len : sizeof m);
  if (len >= sizeof m && m.h.ordinal == PROC_PROF && handle) { // a profiling ring
    proc_msg prep = {
        .h = {.txid = m.h.txid, .ordinal = PROC_PROF, .flags = (uint32_t)prof_register(&m, handle)}};
    vx_channel_write(server.listen, &prep, sizeof prep, nullptr, 0);
    return;
  }
  proc_msg rep = {.h = {.txid = m.h.txid, .ordinal = PROC_REGISTER}};
  vx_status st = len >= sizeof m && m.h.ordinal == PROC_REGISTER && handle ? VX_OK : VX_ERR_INVALID;
  proc *p = nullptr;
  if (st == VX_OK) st = admit(handle, (uint64_t)m.arg[0], (uint32_t)m.arg[1], (uint64_t)m.arg[2], false, &p);
  if (st == VX_OK)
    rep.arg[0] = (int64_t)p->pid;
  else if (handle)
    vx_handle_close(handle);
  rep.h.flags = (uint32_t)st;
  vx_channel_write(server.listen, &rep, sizeof rep, nullptr, 0);
}

// Queues a record of what happened to child c for its parent, if there is
// room: as 9front's pexit leaves one, at most MAX_WAITS.
static void queue_record(proc *parent, const proc *c, uint8_t kind, uint8_t sig) {
  vx_task_summary info;
  uint32_t r = 1;
  while (r <= MAX_RECORDS && records[r].pid) r++;
  if (r > MAX_RECORDS || parent->nwait >= MAX_WAITS || vx_task_info(c->task, &info) != VX_OK) return;
  record *rec = &records[r];
  *rec = (record){.pid = c->pid,
                  .noteid = c->noteid,
                  .kind = kind,
                  .sig = sig,
                  .real_ms = (uint64_t)(vx_clock_read() - c->start) / 1'000'000,
                  .len = kind == ENDED ? (uint8_t)info.exit_len : 0};
  memcpy(rec->name, info.name, sizeof rec->name);
  if (kind == ENDED) memcpy(rec->status, info.exit, info.exit_len);
  if (parent->last)
    records[parent->last].next = r;
  else
    parent->first = r;
  parent->last = r;
  parent->nwait++;
  server.again = true; // a wait read held for the parent may go on
}

// Delivers a note: the kernel interrupts p with it, and a wait read p is
// blocked in ends, after the note.
static vx_status deliver(proc *p, vx_str note) {
  vx_status st = vx_thread_interrupt(p->task, 0, note);
  if (st == VX_OK && p->wait_held) p->interrupted = server.again = true; // the held read ends
  return st;
}

// Tells c's parent what happened to it: a record (a stop or a continue only
// for a parent that asked for childnotes), and the SIGCHLD note if it did.
static void tell_parent(const proc *c, uint8_t kind, uint8_t sig) {
  proc *parent = by_pid(c->ppid);
  if (!parent || c->nowait) return;
  if (kind == ENDED || parent->childnotes) queue_record(parent, c, kind, sig);
  if (!parent->childnotes) return;
  char note[VX_ERRMAX];
  deliver(parent, (vx_str){note, posix_note(POSIX_SIGCHLD, (int64_t)c->pid, note)});
}

// The task has ended: its parent hears, and its own unread records go.
static void dbg_forget(const proc *p);  // debug.c
static void prof_forget(const proc *p); // prof.c

static void ended(proc *p) {
  dbg_forget(p);
  prof_forget(p);
  tell_parent(p, ENDED, 0);
  for (uint32_t i = p->first; i;) {
    uint32_t next = records[i].next;
    records[i] = (record){};
    i = next;
  }
  vx_handle_close(p->task);
  *p = (proc){.gen = p->gen};
  // Reads held for it go round again, record or not: a debugger's events
  // read, and a parent's wait read that is now waiting for nothing.
  server.again = true;
}

// Stops every thread of p, for signal sig (its parent hears which), or
// continues it.
static vx_status stop(proc *p, uint8_t sig) {
  if (p->stopped) return VX_OK;
  vx_status st = vx_thread_suspend(p->task, 0);
  if (st != VX_OK) return st;
  p->stopped = true;
  tell_parent(p, STOPPED, sig);
  return VX_OK;
}

static vx_status cont(proc *p) {
  if (!p->stopped) return VX_OK;
  p->stopped = false;
  vx_status st = vx_thread_resume(p->task, 0);
  tell_parent(p, CONTINUED, 0);
  return st;
}

static void dbg_exception(proc *p, uint32_t tid); // debug.c
static void crash(proc *p, uint32_t tid);         // crash.c

static void event(void *ctx, const vx_packet *pk) {
  (void)ctx;
  uint32_t slot = (uint32_t)(pk->key & 0xffff),
           gen = (uint32_t)(pk->key >> 16 & 0xff'ffff); // below DBG_KEY_BIT
  if (slot >= MAX_PROCS) return;
  proc *p = &procs[slot];
  if (!p->used || p->gen != gen) return;
  if (pk->trigger == VX_TRIGGER_EXIT) ended(p);
  if (pk->trigger == VX_TRIGGER_EXCEPTION && (pk->key & 1ull << 41))
    crash(p, (uint32_t)pk->value);
  else if (pk->trigger == VX_TRIGGER_EXCEPTION)
    dbg_exception(p, (uint32_t)pk->value);
}

// Posts a note to p (a write to note or notepg). The signals a process cannot
// act on itself, procfs carries out. svcd takes none: it has no handler, and
// any note would end it, and the system with it.
static vx_status post(proc *p, vx_str note) {
  if (p->root) return VX_ERR_ACCESS;
  int64_t sender;
  int64_t sig = posix_note_signal(note, &sender);
  if (sig == POSIX_SIGKILL) return vx_task_kill(p->task, VX_STR("killed"));
  if (sig == POSIX_SIGSTOP) return stop(p, (uint8_t)sig);
  if (sig == POSIX_SIGCONT) cont(p); // and then its handler, if it has one
  return deliver(p, note);
}

// --- The tree ---
//
// Node numbers: 1 is /proc; the rest are a process's pid shifted left 32,
// then a thread's id shifted left 8 (0 for the process's own files), then the
// file's number below: a process's, or under threads/T, a thread's.

enum : uint64_t { ROOT = 1 };
enum : uint32_t {
  DIR,
  STATUS,
  CTL,
  NOTE,
  NOTEPG,
  NOTEID,
  PPID,
  WAIT,
  NS,
  EVENTS,
  MEM,
  MAPS,
  IMAGES,
  INFO,
  PROF,
  THREADS,
  FILES,
  PROF_CTL, // in prof/, not listed in the process's directory
  PROF_ZONES
};
enum : uint32_t { T_DIR, T_STATUS, T_REGS, T_REGS_NDB, T_FPREGS, T_CTL, T_FILES };

typedef struct file_entry {
  vx_str name;
  uint32_t mode;
} file_entry;

static const file_entry FILE_TABLE[FILES] = {
    [STATUS] = {VX_STR("status"), 0444},
    [CTL] = {VX_STR("ctl"), 0222},
    [NOTE] = {VX_STR("note"), 0222},
    [NOTEPG] = {VX_STR("notepg"), 0222},
    [NOTEID] = {VX_STR("noteid"), 0664},
    [PPID] = {VX_STR("ppid"), 0444},
    [WAIT] = {VX_STR("wait"), 0444},
    [NS] = {VX_STR("ns"), 0444},
    [EVENTS] = {VX_STR("events"), 0444},
    [MEM] = {VX_STR("mem"), 0664},
    [MAPS] = {VX_STR("maps"), 0444},
    [IMAGES] = {VX_STR("images"), 0444},
    [INFO] = {VX_STR("info"), 0444},
    [PROF] = {VX_STR("prof"), P9_DMDIR | 0555},
    [THREADS] = {VX_STR("threads"), P9_DMDIR | 0555},
};

static const file_entry THREAD_FILES[T_FILES] = {
    [T_STATUS] = {VX_STR("status"), 0444},     [T_REGS] = {VX_STR("regs"), 0664},
    [T_REGS_NDB] = {VX_STR("regs.ndb"), 0664}, [T_FPREGS] = {VX_STR("fpregs"), 0664},
    [T_CTL] = {VX_STR("ctl"), 0222},
};

static vx_handle nsd; // a connector to nsd's post, for /proc/N/ns

// The namespace text of the group pid is in, from nsd: its length in buf, or 0.
static size_t ns_text(uint64_t pid, char *buf, size_t cap) {
  alignas(nsd_msg) static uint8_t reply[sizeof(nsd_msg) + NSD_TEXT_MAX];
  nsd_msg req = {.h = {.ordinal = NSD_TEXT}, .a = {.task = pid}};
  vx_call c = {.wr_bytes = &req, .wr_len = sizeof req, .rd_bytes = reply, .rd_cap = sizeof reply};
  if (!nsd || vx_channel_call(nsd, &c, vx_clock_read() + 1'000'000'000) != VX_OK) return 0;
  const nsd_msg *rep = (const nsd_msg *)reply;
  if (c.actual.bytes < sizeof *rep || rep->h.flags || rep->a.text_len > c.actual.bytes - sizeof *rep)
    return 0;
  size_t n = rep->a.text_len < cap ? rep->a.text_len : cap;
  memcpy(buf, reply + sizeof *rep, n);
  return n;
}

static proc *proc_of(uint64_t node) { return node == ROOT ? nullptr : by_pid(node >> 32); }
static uint32_t file_of(uint64_t node) { return (uint32_t)(node & 0xff); }
static uint32_t thread_of(uint64_t node) { return (uint32_t)(node >> 8 & 0xff'ffff); }
static uint64_t node_of(uint64_t pid, uint32_t tid, uint32_t file) {
  return pid << 32 | (uint64_t)tid << 8 | file;
}

// Whether thread tid of p is alive.
static bool thread_alive(const proc *p, uint32_t tid) {
  vx_thread_info ti;
  return tid && vx_thread_state(p->task, tid - 1, VX_STATE_NEXT_THREAD, &ti, sizeof ti) == VX_OK &&
         ti.id == tid;
}

static const file_entry PROF_FILES[2] = {{VX_STR("ctl"), 0222}, {VX_STR("zones"), 0444}};

static const file_entry *entry_of(uint64_t node) {
  if (thread_of(node)) return &THREAD_FILES[file_of(node)];
  return file_of(node) > FILES ? &PROF_FILES[file_of(node) - PROF_CTL] : &FILE_TABLE[file_of(node)];
}

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = ROOT;
  return VX_OK;
}

static bool parse_u64(vx_str s, uint64_t *out) {
  uint64_t v = 0;
  if (!s.len || s.len > 19) return false;
  for (size_t i = 0; i < s.len; i++) {
    if (s.ptr[i] < '0' || s.ptr[i] > '9') return false;
    v = v * 10 + (uint64_t)(s.ptr[i] - '0');
  }
  *out = v;
  return true;
}

static bool word_is(vx_str s, const char *w) {
  vx_str t = vx_cstr(w);
  return s.len == t.len && memcmp(s.ptr, t.ptr, t.len) == 0;
}

#include "debug.c"

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  uint64_t n;
  if (dir == ROOT) {
    if (!parse_u64(name, &n) || name.ptr[0] == '0' || !by_pid(n)) return VX_ERR_NOT_FOUND;
    *child = node_of(n, 0, DIR);
    return VX_OK;
  }
  const proc *p = proc_of(dir);
  if (!p) return VX_ERR_NOT_FOUND;
  uint32_t tid = thread_of(dir), f = file_of(dir);
  if (!tid && f == THREADS) { // a thread's directory, by its id
    if (!parse_u64(name, &n) || name.ptr[0] == '0' || n > 0xff'ffff || !thread_alive(p, (uint32_t)n))
      return VX_ERR_NOT_FOUND;
    *child = node_of(p->pid, (uint32_t)n, T_DIR);
    return VX_OK;
  }
  if (!tid && f == PROF) { // prof/'s files
    for (uint32_t k = 0; k < 2; k++)
      if (PROF_FILES[k].name.len == name.len && memcmp(PROF_FILES[k].name.ptr, name.ptr, name.len) == 0) {
        *child = node_of(p->pid, 0, PROF_CTL + k);
        return VX_OK;
      }
    return VX_ERR_NOT_FOUND;
  }
  if (f != DIR) return VX_ERR_NOT_FOUND;
  const file_entry *table = tid ? THREAD_FILES : FILE_TABLE;
  for (uint32_t k = 1; k < (tid ? T_FILES : FILES); k++)
    if (table[k].name.len == name.len && memcmp(table[k].name.ptr, name.ptr, name.len) == 0) {
      *child = node_of(p->pid, tid, k);
      return VX_OK;
    }
  return VX_ERR_NOT_FOUND;
}

static vx_status fs_parent(void *ctx, uint64_t node, uint64_t *parent) {
  (void)ctx;
  uint64_t pid = node >> 32;
  uint32_t tid = thread_of(node), f = file_of(node);
  if (node == ROOT || (!tid && f == DIR))
    *parent = ROOT;
  else if (tid && f == T_DIR)
    *parent = node_of(pid, 0, THREADS);
  else if (!tid && f > FILES)
    *parent = node_of(pid, 0, PROF);
  else
    *parent = node_of(pid, tid, DIR); // a file: its process's directory, or its thread's
  return VX_OK;
}

static char name_buf[24];

static vx_status fs_stat(void *ctx, uint64_t node, p9_stat *out) {
  (void)ctx;
  if (node == ROOT) {
    *out = (p9_stat){.qid = {P9_QTDIR, 0, ROOT}, .mode = P9_DMDIR | 0555, .name = VX_STR("/")};
  } else {
    const proc *p = proc_of(node);
    if (!p) return VX_ERR_NOT_FOUND;
    uint32_t f = file_of(node), tid = thread_of(node);
    if (f == DIR) {
      uint64_t id = tid ? tid : p->pid; // its directory's name: the pid, or the thread's id, in decimal
      size_t n = sizeof name_buf;
      do name_buf[--n] = (char)('0' + id % 10);
      while (id /= 10);
      *out = (p9_stat){
          .qid = {P9_QTDIR, 0, node}, .mode = P9_DMDIR | 0555, .name = {name_buf + n, sizeof name_buf - n}};
    } else {
      const file_entry *e = entry_of(node);
      *out = (p9_stat){
          .qid = {e->mode & P9_DMDIR ? P9_QTDIR : P9_QTFILE, 0, node}, .mode = e->mode, .name = e->name};
      if (!tid && f == WAIT) out->length = p->nwait; // as 9front's: more than 0 means a read will not wait
      if (!tid && f == EVENTS) out->length = dbg_of(p)->ev_count;
    }
  }
  out->uid = out->gid = out->muid = VX_STR("proc");
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t node, uint8_t mode) {
  (void)ctx;
  if (mode & P9_ORCLOSE) return VX_ERR_ACCESS;
  if (node == ROOT) return (mode & 3) == P9_OREAD ? VX_OK : VX_ERR_ACCESS;
  proc *p = proc_of(node);
  if (!p) return VX_ERR_NOT_FOUND;
  uint32_t f = file_of(node), perm = f == DIR ? 0555 : entry_of(node)->mode & 0777;
  bool reads = (mode & 3) == P9_OREAD || (mode & 3) == P9_ORDWR;
  bool writes = (mode & 3) == P9_OWRITE || (mode & 3) == P9_ORDWR;
  if ((reads && !(perm & 0444)) || (writes && !(perm & 0222))) return VX_ERR_ACCESS;
  if (!thread_of(node) && f == EVENTS && !p->root) return dbg_bind(p); // a reader of events is a debugger
  return VX_OK; // OTRUNC means nothing to a file made as it is read
}

// A process's status record, as it is now.
static size_t status_text(const proc *p, char *buf, size_t cap) {
  vx_task_summary info;
  if (vx_task_info(p->task, &info) != VX_OK) return 0;
  size_t name_len = 0;
  while (name_len < sizeof info.name && info.name[name_len]) name_len++;
  vx_ndb_writer w = {.buf = buf, .cap = cap};
  vx_ndb_put_u64(&w, "pid", p->pid);
  vx_ndb_put(&w, "name", (vx_str){info.name, name_len});
  vx_str state = VX_STR("running");
  if (info.state == VX_TASK_NEW)
    state = VX_STR("new");
  else if (p->stopped)
    state = VX_STR("stopped");
  else if (info.threads && info.blocked == info.threads)
    state = VX_STR("waiting");
  vx_ndb_put(&w, "state", state);
  vx_ndb_put_u64(&w, "threads", info.threads);
  char mem[24];
  uint64_t kib = info.mapped / 1024, n = sizeof mem;
  mem[--n] = 'K';
  do mem[--n] = (char)('0' + kib % 10);
  while (kib /= 10);
  vx_ndb_put(&w, "mem", (vx_str){mem + n, sizeof mem - n});
  vx_ndb_put_u64(&w, "sid", p->sid);
  vx_ndb_end(&w);
  return w.failed ? 0 : w.len;
}

static size_t number_text(uint64_t v, char *buf) {
  char digits[20];
  size_t n = sizeof digits;
  do digits[--n] = (char)('0' + v % 10);
  while (v /= 10);
  memcpy(buf, digits + n, sizeof digits - n);
  return sizeof digits - n;
}

// The next wait record for p, taken from its queue: SHOULD_WAIT if there is
// none yet, NO_CHILD if none will come, INTERRUPTED if a note ended the wait.
static vx_status take_record(proc *p, char *buf, size_t cap, size_t *len) {
  if (p->interrupted) {
    p->interrupted = p->wait_held = false;
    return VX_ERR_INTERRUPTED;
  }
  if (!p->first) {
    p->wait_held = has_children(p);
    return p->wait_held ? VX_ERR_SHOULD_WAIT : VX_ERR_NO_CHILD;
  }
  p->wait_held = false;
  record *rec = &records[p->first];
  p->first = rec->next;
  if (!p->first) p->last = 0;
  p->nwait--;
  size_t name_len = 0;
  while (name_len < sizeof rec->name && rec->name[name_len]) name_len++;
  vx_ndb_writer w = {.buf = buf, .cap = cap};
  vx_ndb_put_u64(&w, "pid", rec->pid);
  vx_ndb_put(&w, "name", (vx_str){rec->name, name_len});
  vx_ndb_put_u64(&w, "noteid", rec->noteid);
  if (rec->kind == STOPPED) {
    vx_ndb_put_u64(&w, "stopped", rec->sig);
  } else if (rec->kind == CONTINUED) {
    vx_ndb_flag(&w, "continued");
  } else {
    vx_ndb_put(&w, "status", (vx_str){rec->status, rec->len});
    vx_ndb_put_u64(&w, "real", rec->real_ms);
  }
  vx_ndb_end(&w);
  *rec = (record){};
  *len = w.failed ? 0 : w.len;
  return VX_OK;
}

// A thread's files: status and the registers, binary or as text.
static vx_status thread_read(proc *p, uint32_t tid, uint32_t f, uint64_t offset, uint8_t *buf,
                             uint32_t *count) {
  static char text[1024];
  size_t len = 0;
  vx_regs r;
  vx_fpregs fp;
  vx_status st = VX_OK;
  if (f == T_STATUS) len = thread_status_text(p, tid, text, sizeof text);
  if (f == T_REGS_NDB) len = regs_ndb_text(p, tid, text, sizeof text);
  if (f == T_REGS && (st = vx_thread_state(p->task, tid, VX_STATE_GET_REGS, &r, sizeof r)) == VX_OK)
    memcpy(text, &r, len = sizeof r);
  if (f == T_FPREGS && (st = vx_thread_state(p->task, tid, VX_STATE_GET_FPREGS, &fp, sizeof fp)) == VX_OK)
    memcpy(text, &fp, len = sizeof fp);
  if (st != VX_OK) return st; // running: its registers will not hold still
  uint64_t left = offset < len ? len - offset : 0;
  if (*count > left) *count = (uint32_t)left;
  memcpy(buf, text + offset * (*count != 0), *count);
  return VX_OK;
}

// mem: the task's memory at offset, as much of it as is mapped.
// A page at a time, so a hole ends the read where it starts: what came
// before it; at the hole itself, an error, not an empty read (the end of a
// file).
static vx_status mem_read(const proc *p, uint64_t offset, uint8_t *buf, uint32_t *count) {
  uint32_t done = 0, want = *count;
  while (done < want) {
    uint64_t at = offset + done, page_left = 4096 - (at & 4095);
    uint32_t n = want - done < page_left ? want - done : (uint32_t)page_left;
    if (mem_rw(p, at, buf + done, n, false) != VX_OK) break;
    done += n;
  }
  *count = done;
  return done || !want ? VX_OK : VX_ERR_INVALID;
}

#include "crash.c"
#include "prof.c"

static vx_status fs_read(void *ctx, uint64_t node, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  proc *p = proc_of(node);
  if (!p) return VX_ERR_NOT_FOUND;
  if (thread_of(node)) return thread_read(p, thread_of(node), file_of(node), offset, buf, count);
  static char text[NSD_TEXT_MAX];
  size_t len = 0;
  switch (file_of(node)) {
  case MEM: return mem_read(p, offset, buf, count);
  case MAPS: len = maps_text(p, text, sizeof text); break;
  case IMAGES: len = images_text(p, text, sizeof text); break;
  case INFO: len = info_text(p, text, sizeof text); break;
  case PROF_ZONES: { // a whole ring: bigger than text
    static uint8_t snap[VX_PROF_RING];
    size_t n = prof_snapshot(p, snap, sizeof snap);
    uint64_t left = offset < n ? n - offset : 0;
    if (*count > left) *count = (uint32_t)left;
    memcpy(buf, snap + offset * (*count != 0), *count);
    return VX_OK;
  }
  case EVENTS: { // a record each read, as wait's; a read waits for one
    vx_status st = take_event(p, text, sizeof text, &len);
    if (st != VX_OK) return st;
    if (*count > len) *count = (uint32_t)len;
    memcpy(buf, text, *count);
    return VX_OK;
  }
  case STATUS: len = status_text(p, text, sizeof text); break;
  case NS: len = ns_text(p->pid, text, sizeof text); break;
  case NOTEID: len = number_text(p->noteid, text); break;
  case PPID: len = number_text(p->ppid, text); break;
  case WAIT: { // a record each read, whatever the offset, as 9front's
    vx_status st = take_record(p, text, sizeof text, &len);
    if (st != VX_OK) return st;
    if (*count > len) *count = (uint32_t)len;
    memcpy(buf, text, *count);
    return VX_OK;
  }
  default: break;
  }
  uint64_t left = offset < len ? len - offset : 0;
  if (*count > left) *count = (uint32_t)left;
  memcpy(buf, text + offset * (*count != 0), *count);
  return VX_OK;
}

// What a write says, without the newline at its end (echo adds one).
static vx_str written(const uint8_t *buf, uint32_t count) {
  while (count && (buf[count - 1] == '\n' || buf[count - 1] == ' ')) count--;
  return (vx_str){(const char *)buf, count};
}

static vx_status ctl(proc *p, vx_str cmd) {
  if (word_is(cmd, "kill")) {
    if (p->root) return VX_ERR_ACCESS; // svcd: the system needs it
    return vx_task_kill(p->task, VX_STR("killed"));
  }
  if (cmd.len >= 4 && memcmp(cmd.ptr, "stop", 4) == 0 && (cmd.len == 4 || cmd.ptr[4] == ' ')) {
    uint64_t sig = POSIX_SIGSTOP; // stop SIG: which signal stopped it, for its parent's wait
    if (cmd.len > 5 && (!parse_u64((vx_str){cmd.ptr + 5, cmd.len - 5}, &sig) || !sig || sig > POSIX_NSIG))
      return VX_ERR_INVALID;
    return p->root ? VX_ERR_ACCESS : stop(p, (uint8_t)sig);
  }
  if (word_is(cmd, "start")) {
    release_all(p); // threads held at events, and those stopped
    return cont(p);
  }
  if (word_is(cmd, "setsid")) {
    // POSIX: refused if any process's group is the caller's pid (a leader,
    // or one that left its group with others still in it), whose group would
    // then span two sessions.
    for (uint32_t i = 0; i < MAX_PROCS; i++)
      if (procs[i].used && procs[i].noteid == p->pid) return VX_ERR_ACCESS;
    p->sid = p->noteid = p->pid; // a session, and a note group, of its own
    return VX_OK;
  }
  if (word_is(cmd, "childnotes")) {
    p->childnotes = true;
    return VX_OK;
  }
  vx_status st = dbg_ctl(p, cmd);
  return st == VX_ERR_NOT_FOUND ? VX_ERR_INVALID : st;
}

// Joins note group `group`: one that exists in p's session, or a new one
// named by p's own pid, as 9front's changenoteid allows.
static vx_status join_group(proc *p, uint64_t group) {
  bool exists = group == p->pid;
  for (uint32_t i = 0; i < MAX_PROCS && !exists; i++)
    exists = procs[i].used && procs[i].noteid == group && procs[i].sid == p->sid;
  if (!exists) return VX_ERR_ACCESS;
  p->noteid = group;
  return VX_OK;
}

// NOLINTNEXTLINE(readability-non-const-parameter): p9_fs's signature
static vx_status fs_write(void *ctx, uint64_t node, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx, (void)offset;
  proc *p = proc_of(node);
  if (!p) return VX_ERR_NOT_FOUND;
  uint32_t tid = thread_of(node), f = file_of(node);
  if (tid && (f == T_REGS || f == T_FPREGS)) { // whole, at offset 0
    vx_fpregs whole;                           // the larger of the two
    uint32_t size = f == T_REGS ? (uint32_t)sizeof(vx_regs) : (uint32_t)sizeof(vx_fpregs);
    if (*count != size || offset) return VX_ERR_INVALID;
    memcpy(&whole, buf, size);
    return vx_thread_state(p->task, tid, f == T_REGS ? VX_STATE_SET_REGS : VX_STATE_SET_FPREGS, &whole, size);
  }
  if (!tid && f == MEM) {
    if (p->root) return VX_ERR_ACCESS;
    static uint8_t copy[P9_RING_MSIZE]; // task_mem_rw's buffer is the caller's to read and write
    if (*count > sizeof copy) return VX_ERR_INVALID;
    memcpy(copy, buf, *count);
    // A page at a time, as reads go: what was written before a page that
    // cannot be is counted, not reported as nothing.
    uint32_t done = 0, want = *count;
    while (done < want) {
      uint64_t at = offset + done, page_left = 4096 - (at & 4095);
      uint32_t n = want - done < page_left ? want - done : (uint32_t)page_left;
      vx_status st = mem_rw(p, at, copy + done, n, true);
      if (st != VX_OK) {
        if (!done) return st;
        break;
      }
      done += n;
    }
    *count = done;
    return VX_OK;
  }
  vx_str s = written(buf, *count);
  if (tid && f == T_REGS_NDB) return regs_ndb_write(p, tid, s);
  if (tid && f == T_CTL) return thread_ctl(p, tid, s);
  if (tid) return VX_ERR_ACCESS;
  if (f == PROF_CTL) return prof_ctl(p, s);
  uint64_t group;
  switch (f) {
  case CTL: return ctl(p, s);
  case NOTE: return s.len && s.len <= VX_ERRMAX ? post(p, s) : VX_ERR_INVALID;
  case NOTEPG:
    if (!s.len || s.len > VX_ERRMAX) return VX_ERR_INVALID;
    group = p->noteid;
    for (uint32_t i = 0; i < MAX_PROCS; i++)
      if (procs[i].used && procs[i].noteid == group) post(&procs[i], s);
    return VX_OK;
  case NOTEID: return parse_u64(s, &group) && group ? join_group(p, group) : VX_ERR_INVALID;
  default: return VX_ERR_ACCESS;
  }
}

// The root's entries are the processes, in table order; a process's are its files.
static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  const proc *p = proc_of(dir);
  if (dir != ROOT && !thread_of(dir) && file_of(dir) == THREADS) { // the threads, by id
    vx_thread_info ti = {};
    for (uint32_t i = 0; i <= index; i++)
      if (!p || vx_thread_state(p->task, ti.id, VX_STATE_NEXT_THREAD, &ti, sizeof ti) != VX_OK)
        return VX_ERR_NOT_FOUND;
    *child = node_of(p->pid, ti.id, T_DIR);
    return VX_OK;
  }
  if (dir != ROOT && !thread_of(dir) && file_of(dir) == PROF) { // ctl, zones
    if (!p || index >= 2) return VX_ERR_NOT_FOUND;
    *child = node_of(p->pid, 0, PROF_CTL + index);
    return VX_OK;
  }
  if (dir != ROOT) {
    if (!p || index + 1 >= (thread_of(dir) ? T_FILES : FILES)) return VX_ERR_NOT_FOUND;
    *child = dir | (index + 1);
    return VX_OK;
  }
  for (uint32_t i = 0, seen = 0; i < MAX_PROCS; i++) {
    if (!procs[i].used) continue;
    if (seen++ == index) {
      *child = node_of(procs[i].pid, 0, DIR);
      return VX_OK;
    }
  }
  return VX_ERR_NOT_FOUND;
}

const char *vx_main(void) {
  vx_handle tasks = vx_spawn_take("tasks");
  nsd = vx_spawn_take("srv:nsd");
  tmpfs = vx_spawn_take("srv:tmpfs"); // for crash directories
  // Field by field: the server is too big for a compound literal, which would
  // be built on the stack first.
  server.fs = (p9_fs){.attach = fs_attach,
                      .walk = fs_walk,
                      .parent = fs_parent,
                      .stat = fs_stat,
                      .open = fs_open,
                      .read = fs_read,
                      .readdir = fs_readdir,
                      .write = fs_write};
  server.name = VX_STR("procfs");
  server.event = event;
  server.listen_msg = registered;
  server.listen = vx_spawn_take("listen");
  static p9_ring_conn conns[MAX_PROCS]; // a connection for each process, at most
  server.conns = conns;
  server.max_conns = MAX_PROCS;
  proc *root = nullptr;
  vx_task_summary me;
  if (vx_task_info(vx_self, &me) == VX_OK) self_id = me.id;
  if (!tasks || !server.listen || vx_port_create(0, &server.port) != VX_OK ||
      admit(tasks, 0, 0, 0, true, &root) != VX_OK) {
    vx_print(VX_STR("procfs: FAILED: no task tree or listen channel\n"));
    return "no task tree or listen channel";
  }
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
