// crash.c: crash directories (docs/05 §5). Part of procfs.c.
//
// procfs binds each process's exception port, the last in line: a fault
// that neither a debugger nor the program's own handler takes reaches it
// (vx-rt and the musl back end let such a fault happen again, uncaught).
// procfs then stops the process's other threads and saves it as a directory
// shaped like /proc/N, so dbg opens it with the code it uses for a live one:
//
//   /tmp/crash/NAME.PID/
//       info status maps images     as /proc/N's, at the moment of the fault
//       note                        the fault in Plan 9's words: its exit string
//       threads/T/status regs regs.ndb fpregs
//       mem/0xBASE                  each writable mapping's bytes, from its base
//
// Read-only mappings are not copied: the images are named by their build
// IDs; of the writable ones, at most CRASH_MEM_MAX bytes, so one crash does
// not fill /tmp. Each call to tmpfs has a time limit: the process that faulted
// may be tmpfs, or one tmpfs waits on, and procfs would otherwise wait on it
// as it waits on procfs. Then the task is killed with the trap's words, as an unhandled fault
// always ends it. The directories go to tmpfs (connect=tmpfs), reached the
// first time one is needed; /lib/crash and $home/lib/crash wait for a file
// system that keeps them (docs/milestones.md).

static vx_handle tmpfs; // a connector to /srv/tmpfs
static p9_conn crash_conn;
static uint32_t crash_root; // /crash on it, once made
static constexpr uint64_t CRASH_MEM_MAX = 16ull << 20, CRASH_WAIT = 5'000'000'000;

// A directory `name` made in dir: a fid walked to it, not open, so files
// can be made in it (9P walks only from a fid that is not open).
static uint32_t crash_mkdir(p9_client *c, uint32_t dir, vx_str name) {
  uint32_t fid;
  if (p9c_walk(c, dir, VX_STR(""), &fid) != VX_OK) return 0;
  vx_status st = p9c_create(c, fid, name, P9_DMDIR | 0755, P9_OREAD);
  p9c_clunk(c, fid);
  return st == VX_OK && p9c_walk(c, dir, name, &fid) == VX_OK ? fid : 0;
}

// The connection to tmpfs, and its /crash, made the first time.
static p9_client *crash_fs(void) {
  if (crash_root && !crash_conn.dead) return &crash_conn.c;
  if (crash_root) p9_ring_disconnect(&crash_conn); // it timed out: made again
  crash_root = 0;
  uint32_t root = 0, dir = 0;
  if (!tmpfs || p9_ring_connect(tmpfs, &crash_conn) != VX_OK) return nullptr;
  crash_conn.timeout = CRASH_WAIT;
  p9_client *c = &crash_conn.c;
  if (p9c_attach(c, VX_STR(""), &root) != VX_OK) {
    p9_ring_disconnect(&crash_conn);
    return nullptr;
  }
  vx_status st = p9c_walk(c, root, VX_STR("crash"), &dir);
  if (st != VX_OK) { // made: then walked to, for a fid that is not open (an open one cannot be walked from)
    uint32_t made = crash_mkdir(c, root, VX_STR("crash"));
    st = made ? VX_OK : VX_ERR_NOT_FOUND;
    dir = made;
  }
  p9c_clunk(c, root);
  if (st != VX_OK) {
    p9_ring_disconnect(&crash_conn);
    return nullptr;
  }
  crash_root = dir;
  return c;
}

// A file `name` in dir, holding len bytes.
static void crash_file(p9_client *c, uint32_t dir, vx_str name, const void *data, size_t len) {
  uint32_t fid;
  if (p9c_walk(c, dir, VX_STR(""), &fid) != VX_OK) return;
  if (p9c_create(c, fid, name, 0644, P9_OWRITE) == VX_OK) {
    for (size_t done = 0; done < len;) {
      int64_t n = p9c_write(c, fid, done, (const uint8_t *)data + done,
                            (uint32_t)(len - done < (1u << 20) ? len - done : 1u << 20));
      if (n <= 0) break;
      done += (size_t)n;
    }
  }
  p9c_clunk(c, fid);
}

// Each writable mapping, a page at a time: a page that cannot be read (never
// touched, say) ends that mapping's file there.
static void crash_mem(p9_client *c, uint32_t dir, const proc *p) {
  static uint8_t page[4096];
  uint32_t mem = crash_mkdir(c, dir, VX_STR("mem"));
  if (!mem) return;
  vx_map_info m;
  uint64_t saved = 0;
  for (uint64_t at = 0; saved < CRASH_MEM_MAX && vx_as_query(p->task, at, &m) == VX_OK;
       at = m.base + m.size) {
    if (!(m.flags & VX_MAP_WRITE)) continue;
    char name[18];
    uint32_t fid;
    if (p9c_walk(c, mem, VX_STR(""), &fid) != VX_OK) continue;
    if (p9c_create(c, fid, (vx_str){name, hex_text(m.base, name)}, 0644, P9_OWRITE) == VX_OK)
      for (uint64_t off = 0; off < m.size && saved < CRASH_MEM_MAX; off += sizeof page, saved += sizeof page)
        if (mem_rw(p, m.base + off, page, sizeof page, false) != VX_OK ||
            p9c_write(c, fid, off, page, sizeof page) != (int64_t)sizeof page)
          break;
    p9c_clunk(c, fid);
  }
  p9c_clunk(c, mem);
}

static void crash_thread(p9_client *c, uint32_t threads, proc *p, uint32_t tid) {
  static char text[1024];
  char name[12];
  uint32_t dir = crash_mkdir(c, threads, (vx_str){name, number_text(tid, name)});
  if (!dir) return;
  size_t len = thread_status_text(p, tid, text, sizeof text);
  crash_file(c, dir, VX_STR("status"), text, len);
  len = regs_ndb_text(p, tid, text, sizeof text);
  crash_file(c, dir, VX_STR("regs.ndb"), text, len);
  vx_regs r;
  if (vx_thread_state(p->task, tid, VX_STATE_GET_REGS, &r, sizeof r) == VX_OK)
    crash_file(c, dir, VX_STR("regs"), &r, sizeof r);
  vx_fpregs fp;
  if (vx_thread_state(p->task, tid, VX_STATE_GET_FPREGS, &fp, sizeof fp) == VX_OK)
    crash_file(c, dir, VX_STR("fpregs"), &fp, sizeof fp);
  p9c_clunk(c, dir);
}

// Thread tid of p faulted, and nothing took it: saved, then killed.
static void crash(proc *p, uint32_t tid) {
  vx_exception e;
  vx_task_summary info;
  if (vx_thread_state(p->task, tid, VX_STATE_GET_EXCEPTION, &e, sizeof e) != VX_OK ||
      vx_task_info(p->task, &info) != VX_OK) {
    vx_exception_resume(p->task, tid, VX_RESUME_KILL, nullptr);
    return;
  }
  vx_thread_suspend(p->task, 0); // the others hold still, their registers readable
  held *h = held_of(p, tid, true);
  if (h) *h = (held){.tid = tid, .why = WHY_FAULT, .bp = -1, .pc = *reg_pc(&e.regs)};
  char note[VX_ERRMAX];
  size_t note_len = vx_trap_note(e.kind, e.code, e.address, *reg_pc(&e.regs), note);
  // NAME.PID
  char dirname[48];
  size_t len = 0;
  while (len < sizeof info.name && info.name[len]) dirname[len] = info.name[len], len++;
  dirname[len++] = '.';
  len += number_text(p->pid, dirname + len);
  p9_client *c = crash_fs();
  uint32_t dir = c ? crash_mkdir(c, crash_root, (vx_str){dirname, len}) : 0;
  if (dir) {
    static char text[NSD_TEXT_MAX];
    crash_file(c, dir, VX_STR("note"), note, note_len);
    size_t n = status_text(p, text, sizeof text);
    crash_file(c, dir, VX_STR("status"), text, n);
    n = info_text(p, text, sizeof text);
    crash_file(c, dir, VX_STR("info"), text, n);
    n = maps_text(p, text, sizeof text);
    crash_file(c, dir, VX_STR("maps"), text, n);
    n = images_text(p, text, sizeof text);
    crash_file(c, dir, VX_STR("images"), text, n);
    uint32_t threads = crash_mkdir(c, dir, VX_STR("threads"));
    vx_thread_info ti = {};
    while (threads && vx_thread_state(p->task, ti.id, VX_STATE_NEXT_THREAD, &ti, sizeof ti) == VX_OK)
      crash_thread(c, threads, p, ti.id);
    if (threads) p9c_clunk(c, threads);
    crash_mem(c, dir, p);
    p9c_clunk(c, dir);
  }
  vx_print(VX_STR("procfs: "));
  vx_print((vx_str){dirname, len});
  vx_print(VX_STR(": "));
  vx_print((vx_str){note, note_len});
  vx_print(dir ? VX_STR("; saved in /tmp/crash\n") : VX_STR("; not saved\n"));
  if (h) *h = (held){};
  vx_exception_resume(p->task, tid, VX_RESUME_KILL, nullptr); // the default: the trap's words end it
}
