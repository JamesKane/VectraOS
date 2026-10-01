// posixd: the POSIX personality's process table (docs/01 §9): pids, parents,
// process groups and sessions, and wait. The protocol is lib/vx-posix/posix.h.
//
// It serves one port: READABLE on the listen channel (/srv/posixd) and on
// each process's own channel, and EXIT on each process's task. A process that
// ends stays as a zombie until its parent waits for it; a wait that finds
// none yet is answered when one ends. The reply to a call can come later
// than the call: the kernel matches it to the caller by its txid.
//
// Signals: posixd delivers each by thread_interrupt, which diverts a thread
// of the target to its C library's handler (01 §9); the library keeps the
// dispositions and the mask, and acts on it. SIGKILL, and a signal to a task
// with no handler that would end it, posixd carries out itself, with
// task_kill. A child's end is SIGCHLD to its parent.
//
// The table lives only here, so posixd is not restarted: a new one would
// know no processes.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-posix/posix.h"

static constexpr uint32_t MAX_PROCS = 64;
static constexpr int64_t INIT_PID = 1; // posixd: the parent of orphans

// Port keys: what the packet is about, and for a process, its slot and the
// slot's generation, so a packet for an earlier occupant is ignored.
enum : uint64_t { KEY_LISTEN = 1, KEY_CHANNEL = 2, KEY_EXIT = 3 };
static uint64_t key_for(uint64_t kind, uint32_t slot, uint32_t gen) {
  return kind | (uint64_t)slot << 8 | (uint64_t)gen << 32;
}

typedef struct proc {
  bool used, zombie;
  uint32_t gen;
  int64_t pid, ppid, pgid, sid;
  vx_handle task, chan;
  int64_t status;     // its wait status, once a zombie
  bool waiting;       // a WAIT not yet answered:
  uint32_t wait_txid; // its call,
  int64_t wait_pid;   // and which children it waits for
} proc;

static proc procs[MAX_PROCS];
static vx_handle port, listen_ch;
static int64_t next_pid = 2;

static proc *by_pid(int64_t pid) {
  for (uint32_t i = 0; i < MAX_PROCS; i++)
    if (procs[i].used && procs[i].pid == pid) return &procs[i];
  return nullptr;
}

static bool group_in_session(int64_t pgid, int64_t sid) {
  for (uint32_t i = 0; i < MAX_PROCS; i++)
    if (procs[i].used && !procs[i].zombie && procs[i].pgid == pgid && procs[i].sid == sid) return true;
  return false;
}

static int64_t new_pid(void) {
  for (;;) { // a pid is not used again while it names a process or a group
    int64_t pid = next_pid++;
    if (next_pid > 0x3fff'ffff) next_pid = 2;
    bool taken = false;
    for (uint32_t i = 0; i < MAX_PROCS && !taken; i++)
      taken = procs[i].used && (procs[i].pid == pid || procs[i].pgid == pid || procs[i].sid == pid);
    if (!taken) return pid;
  }
}

static void reply(vx_handle ch, uint32_t txid, uint32_t error, const int64_t *values, uint32_t count,
                  vx_handle give) {
  posix_msg m = {.h = {.txid = txid, .flags = error}};
  for (uint32_t i = 0; i < count && i < 4; i++) m.arg[i] = values[i];
  vx_status st = vx_channel_write(ch, &m, sizeof m, give ? &give : nullptr, give ? 1 : 0);
  if (st != VX_OK && give) vx_handle_close(give); // the caller has gone
}

static void forget(proc *p) {
  if (p->task) vx_handle_close(p->task);
  if (p->chan) vx_handle_close(p->chan);
  uint32_t gen = p->gen;
  *p = (proc){.gen = gen + 1};
}

// A new process for `task` (which it takes), with its channel's other end in
// *give. parent is null for one that connected itself.
static uint32_t admit(vx_handle task, const proc *parent, int64_t pgid, bool setsid, proc **out,
                      vx_handle *give) {
  *give = VX_HANDLE_NONE;
  vx_task_summary info;
  if (vx_task_info(task, &info) != VX_OK) {
    vx_handle_close(task);
    return POSIX_EINVAL;
  }
  uint32_t slot = 0;
  while (slot < MAX_PROCS && procs[slot].used) slot++;
  vx_handle ch[2] = {};
  if (slot == MAX_PROCS || vx_channel_create(0, ch) != VX_OK) {
    vx_handle_close(task);
    return POSIX_EAGAIN;
  }
  proc *p = &procs[slot];
  int64_t pid = new_pid();
  *p = (proc){.used = true, .gen = p->gen, .pid = pid, .task = task, .chan = ch[0]};
  if (parent && !setsid) {
    p->ppid = parent->pid;
    p->sid = parent->sid;
    p->pgid = parent->pgid;
    if (pgid == 0) p->pgid = pid;
    if (pgid > 0) p->pgid = pgid;
  } else {
    p->ppid = parent ? parent->pid : INIT_PID;
    p->sid = p->pgid = pid; // a session of its own
  }
  if (vx_port_bind(port, ch[0], VX_TRIGGER_READABLE, key_for(KEY_CHANNEL, slot, p->gen), 0) != VX_OK ||
      vx_port_bind(port, task, VX_TRIGGER_EXIT, key_for(KEY_EXIT, slot, p->gen), 0) != VX_OK) {
    forget(p); // which closes the task and the channel's end
    vx_handle_close(ch[1]);
    return POSIX_EAGAIN;
  }
  *out = p;
  *give = ch[1];
  return POSIX_OK;
}

static void drain(vx_handle ch, proc *p, uint64_t key); // below

// Signals waiting to be delivered: a call or an exit only queues them, and
// the main loop delivers them, so delivering (which reads the target's calls)
// never runs inside another call. By pid: a process that has gone on in a
// new task (EXEC) still gets its signals.
typedef struct outgoing {
  int64_t pid, sig, sender;
} outgoing;
static outgoing outbox[4 * MAX_PROCS];
static uint32_t outbox_count;

static void post(const proc *t, int64_t sig, int64_t sender) {
  if (outbox_count < sizeof outbox / sizeof outbox[0])
    outbox[outbox_count++] = (outgoing){t->pid, sig, sender};
  else
    vx_print(VX_STR("posixd: too many signals at once; one is lost\n"));
}

// Signals t, from sender (a pid, or 0). Calls t has made are answered first,
// so that the interrupt never ends one in flight; a WAIT it is blocked in is
// let go here, as the interrupt ends it (the library calls again).
static void deliver(proc *t, int64_t sig, int64_t sender) {
  if (sig <= 0 || sig > POSIX_NSIG || !t->used || t->zombie) return;
  if (sig == POSIX_SIGKILL) {
    vx_task_kill(t->task, -256 - sig);
    return;
  }
  uint32_t slot = (uint32_t)(t - procs);
  drain(t->chan, t, key_for(KEY_CHANNEL, slot, t->gen));
  if (!t->used || t->zombie) return;
  t->waiting = false;
  vx_status st = vx_thread_interrupt(t->task, 0, (uint64_t)sig | (uint64_t)sender << 16);
  if (st == VX_ERR_BAD_STATE && !posix_default_ignored(sig)) vx_task_kill(t->task, -256 - sig); // no handler
}

static bool waits_for(const proc *parent, const proc *child) {
  if (child->ppid != parent->pid) return false;
  int64_t w = parent->wait_pid;
  if (w > 0) return child->pid == w;
  if (w == -1) return true;
  if (w == 0) return child->pgid == parent->pgid;
  return child->pgid == -w;
}

// Answers p's waiting WAIT with a zombie child, if one matches. Returns
// whether it did.
static bool reap_for(proc *p) {
  for (uint32_t i = 0; i < MAX_PROCS; i++) {
    proc *c = &procs[i];
    if (!c->used || !c->zombie || !waits_for(p, c)) continue;
    int64_t values[2] = {c->pid, c->status};
    p->waiting = false;
    reply(p->chan, p->wait_txid, POSIX_OK, values, 2, VX_HANDLE_NONE);
    forget(c);
    return true;
  }
  return false;
}

static void ended(proc *p, int64_t exit_status) {
  p->zombie = true;
  p->status = posix_wait_status(exit_status);
  p->waiting = false;
  vx_handle_close(p->task);
  vx_handle_close(p->chan);
  p->task = p->chan = VX_HANDLE_NONE;
  for (uint32_t i = 0; i < MAX_PROCS; i++) { // its children are orphans now: posixd reaps them
    proc *c = &procs[i];
    if (!c->used || c->ppid != p->pid) continue;
    c->ppid = INIT_PID;
    if (c->zombie) forget(c);
  }
  proc *parent = by_pid(p->ppid);
  if (!parent || parent->zombie) {
    forget(p); // nobody will wait for it
    return;
  }
  int64_t pid = p->pid;
  if (parent->waiting) reap_for(parent); // which may forget p
  post(parent, POSIX_SIGCHLD, pid);      // after the wait's answer, which it must not end
}

[[gnu::nonnull(1)]] static void call(proc *p, const posix_msg *m, vx_handle handle) {
  uint32_t txid = m->h.txid, err = POSIX_OK;
  int64_t values[4] = {};
  uint32_t count = 0;
  if (handle && m->h.ordinal != POSIX_CHILD && m->h.ordinal != POSIX_EXEC) { // nothing else carries one
    vx_handle_close(handle);
    handle = VX_HANDLE_NONE;
  }
  switch (m->h.ordinal) {
  case POSIX_CHILD: {
    proc *c = nullptr;
    vx_handle give = VX_HANDLE_NONE;
    int64_t pgid = m->arg[0];
    if (!handle)
      err = POSIX_EINVAL;
    else if (pgid > 0 && !group_in_session(pgid, p->sid))
      err = POSIX_EPERM;
    if (err != POSIX_OK && handle) vx_handle_close(handle);
    if (err == POSIX_OK) err = admit(handle, p, pgid, m->arg[1] != 0, &c, &give);
    if (err == POSIX_OK) values[count++] = c->pid;
    reply(p->chan, txid, err, values, count, give);
    return;
  }
  case POSIX_EXEC: {
    vx_task_summary info;
    vx_handle ch[2] = {};
    if (!handle || vx_task_info(handle, &info) != VX_OK)
      err = POSIX_EINVAL;
    else if (vx_channel_create(0, ch) != VX_OK)
      err = POSIX_EAGAIN;
    if (err != POSIX_OK) {
      if (handle) vx_handle_close(handle);
      break;
    }
    // A new generation for the slot: the old task's EXIT and the old
    // channel's packets are ignored from here on.
    uint32_t slot = (uint32_t)(p - procs);
    vx_handle old_task = p->task, old_chan = p->chan;
    p->gen++;
    p->task = handle;
    p->chan = ch[0];
    vx_port_bind(port, ch[0], VX_TRIGGER_READABLE, key_for(KEY_CHANNEL, slot, p->gen), 0);
    vx_port_bind(port, handle, VX_TRIGGER_EXIT, key_for(KEY_EXIT, slot, p->gen), 0);
    values[0] = p->pid;
    reply(old_chan, txid, POSIX_OK, values, 1, ch[1]);
    vx_handle_close(old_chan);
    vx_handle_close(old_task);
    return;
  }
  case POSIX_KILL: {
    int64_t pid = m->arg[0], sig = m->arg[1];
    if (sig < 0 || sig > POSIX_NSIG) {
      err = POSIX_EINVAL;
      break;
    }
    // Who: one process; the caller's group (0); every process but posixd
    // and the caller (-1); or a group (-pgid).
    proc *targets[MAX_PROCS];
    uint32_t n = 0;
    bool self = false;
    for (uint32_t i = 0; i < MAX_PROCS; i++) {
      proc *t = &procs[i];
      if (!t->used || t->zombie) continue;
      bool named = (pid > 0 && t->pid == pid) || (pid == 0 && t->pgid == p->pgid) || (pid == -1 && t != p) ||
                   (pid < -1 && t->pgid == -pid);
      if (!named) continue;
      if (t == p)
        self = true;
      else
        targets[n++] = t;
    }
    if (!n && !self) {
      err = POSIX_ESRCH;
      break;
    }
    values[count++] = self;
    reply(p->chan, txid, POSIX_OK, values, count, VX_HANDLE_NONE); // before the others run
    for (uint32_t i = 0; i < n; i++) post(targets[i], sig, p->pid);
    return;
  }
  case POSIX_IDS:
    values[0] = p->pid, values[1] = p->ppid, values[2] = p->pgid, values[3] = p->sid;
    count = 4;
    break;
  case POSIX_SETPGID: {
    proc *t = m->arg[0] ? by_pid(m->arg[0]) : p;
    if (m->arg[1] < 0) {
      err = POSIX_EINVAL;
    } else if (!t || t->zombie || (t != p && t->ppid != p->pid)) {
      err = POSIX_ESRCH;
    } else {
      int64_t pgid = m->arg[1] ? m->arg[1] : t->pid;
      // Not across sessions, not for a session leader, and only into a group
      // that exists in its session, or a new one of its own.
      bool allowed =
          t->sid == p->sid && t->pid != t->sid && (pgid == t->pid || group_in_session(pgid, t->sid));
      if (allowed)
        t->pgid = pgid;
      else
        err = POSIX_EPERM;
    }
    break;
  }
  case POSIX_SETSID:
    if (p->pgid == p->pid) {
      err = POSIX_EPERM; // a group leader: its group would span two sessions
    } else {
      p->sid = p->pgid = p->pid;
      values[count++] = p->sid;
    }
    break;
  case POSIX_GETPGID:
  case POSIX_GETSID: {
    const proc *t = m->arg[0] ? by_pid(m->arg[0]) : p;
    if (!t)
      err = POSIX_ESRCH;
    else
      values[count++] = m->h.ordinal == POSIX_GETPGID ? t->pgid : t->sid;
    break;
  }
  case POSIX_WAIT: {
    bool any = false;
    p->wait_pid = m->arg[0];
    for (uint32_t i = 0; i < MAX_PROCS && !any; i++) any = procs[i].used && waits_for(p, &procs[i]);
    if (!any) {
      err = POSIX_ECHILD;
      break;
    }
    p->waiting = true;
    p->wait_txid = txid;
    if (reap_for(p)) return;
    if (!(m->arg[1] & POSIX_WNOHANG)) return; // answered when a child ends
    p->waiting = false;
    values[count++] = 0;
    break;
  }
  default: err = POSIX_EINVAL; break;
  }
  reply(p->chan, txid, err, values, count, VX_HANDLE_NONE);
}

// Every message waiting on a channel, then the binding again.
static void drain(vx_handle ch, proc *p, uint64_t key) {
  for (;;) {
    posix_msg m;
    vx_handle got[VX_CHANNEL_MAX_HANDLES] = {};
    vx_msg_size size;
    vx_status st = vx_channel_read(ch, &m, sizeof m, got, VX_CHANNEL_MAX_HANDLES, &size);
    if (st == VX_ERR_TOO_SMALL) { // not ours: read it whole and drop it
      static uint8_t junk[VX_CHANNEL_MAX_BYTES];
      st = vx_channel_read(ch, junk, sizeof junk, got, VX_CHANNEL_MAX_HANDLES, &size);
      for (uint32_t i = 0; st == VX_OK && i < size.handles; i++) vx_handle_close(got[i]);
      continue;
    }
    if (st != VX_OK) break; // empty, or the process has gone (its EXIT says so)
    for (uint32_t i = 1; i < size.handles; i++) vx_handle_close(got[i]);
    if (size.bytes < sizeof m) {
      if (size.handles) vx_handle_close(got[0]);
      continue;
    }
    vx_handle h = size.handles ? got[0] : VX_HANDLE_NONE;
    if (p) {
      call(p, &m, h);
    } else if (m.h.ordinal == POSIX_CONNECT && h) {
      proc *n = nullptr;
      vx_handle give = VX_HANDLE_NONE;
      uint32_t err = admit(h, nullptr, -1, true, &n, &give);
      int64_t pid = n ? n->pid : 0;
      reply(listen_ch, m.h.txid, err, &pid, n ? 1 : 0, give);
    } else {
      if (h) vx_handle_close(h);
      reply(listen_ch, m.h.txid, POSIX_EINVAL, nullptr, 0, VX_HANDLE_NONE);
    }
    if (p && (!p->used || p->chan != ch))
      return; // gone, or gone on in a new task (EXEC), while it was served
  }
  vx_port_bind(port, ch, VX_TRIGGER_READABLE, key, 0);
}

int vx_main(void) {
  listen_ch = vx_spawn_take("listen");
  if (!listen_ch || vx_port_create(0, &port) != VX_OK) {
    vx_print(VX_STR("posixd: no listen channel\n"));
    return 1;
  }
  vx_port_bind(port, listen_ch, VX_TRIGGER_READABLE, KEY_LISTEN, 0);
  vx_print(VX_STR("posixd: serving /srv/posixd\n"));
  for (;;) {
    vx_packet pk[16];
    int64_t n = vx_port_wait(port, VX_INFINITE, 0, pk, 16);
    for (int64_t i = 0; i < n; i++) {
      uint64_t kind = pk[i].key & 0xff;
      uint32_t slot = (uint32_t)(pk[i].key >> 8 & 0xff'ffff), gen = (uint32_t)(pk[i].key >> 32);
      if (kind == KEY_LISTEN) {
        drain(listen_ch, nullptr, KEY_LISTEN);
        continue;
      }
      if (slot >= MAX_PROCS || !procs[slot].used || procs[slot].gen != gen) continue; // an earlier occupant's
      proc *p = &procs[slot];
      if (kind == KEY_EXIT)
        ended(p, (int64_t)pk[i].value);
      else if (kind == KEY_CHANNEL && !p->zombie)
        drain(p->chan, p, pk[i].key);
    }
    // Delivering may answer calls that queue more: until none are left.
    for (uint32_t i = 0; i < outbox_count; i++) {
      proc *t = by_pid(outbox[i].pid);
      if (t) deliver(t, outbox[i].sig, outbox[i].sender);
    }
    outbox_count = 0;
  }
}
