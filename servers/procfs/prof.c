// prof.c: /proc/N/prof (docs/05 §9), a process's profiling zones. Part of
// procfs.c.
//
//   /proc/N/prof/ctl     zones on · zones off
//   /proc/N/prof/zones   the ring as it is now: a vx_prof_header, then the
//                        records it holds, oldest first (lib/vx-prof/prof.h)
//
// A process gives procfs its ring with PROC_PROF (vx_prof_init): procfs maps
// the VMO too, writes a challenge of its own into it, and takes it only if
// the process's memory, at the address it says it maps the ring at, then
// shows that challenge: the proof that the process maps that VMO there. (What
// the sender wrote itself proves nothing: it chose the address, and could
// name bytes another process happens to hold.)

static vx_prof_header *rings[MAX_PROCS]; // each process's, mapped here; null if none
static constexpr uint32_t PROF_SLOTS = (VX_PROF_RING - sizeof(vx_prof_header)) / sizeof(vx_prof_record);

static void prof_forget(const proc *p) {
  vx_prof_header **r = &rings[p - procs];
  if (*r) vx_as_unmap(vx_self, (uint64_t)*r, VX_PROF_RING);
  *r = nullptr;
}

static vx_status prof_register(const proc_msg *m, vx_handle vmo) {
  proc *p = by_pid((uint64_t)m->arg[0]);
  uint64_t at = 0, theirs = 0;
  vx_status st = p ? vx_as_map(vx_self, vmo, 0, VX_PROF_RING, VX_MAP_WRITE, &at) : VX_ERR_NOT_FOUND;
  vx_handle_close(vmo);
  if (st != VX_OK) return st;
  vx_prof_header *h = (vx_prof_header *)at;
  static uint64_t challenges;
  uint64_t challenge = (vx_cycles() ^ (++challenges * 0x9e37'79b9'7f4a'7c15)) | 1;
  h->nonce = challenge;
  st = mem_rw(p, (uint64_t)m->arg[1] + offsetof(vx_prof_header, nonce), &theirs, sizeof theirs, false);
  if (st != VX_OK || h->magic != VX_PROF_MAGIC || theirs != challenge) {
    vx_as_unmap(vx_self, at, VX_PROF_RING);
    return VX_ERR_ACCESS; // not that process's ring
  }
  prof_forget(p);
  rings[p - procs] = h;
  return VX_OK;
}

static vx_status prof_ctl(const proc *p, vx_str cmd) {
  vx_prof_header *h = rings[p - procs];
  if (!h) return VX_ERR_NOT_FOUND; // it has no ring (it never called vx_prof_init)
  if (word_is(cmd, "zones on"))
    atomic_store_explicit(&h->enabled, 1, memory_order_relaxed);
  else if (word_is(cmd, "zones off"))
    atomic_store_explicit(&h->enabled, 0, memory_order_relaxed);
  else
    return VX_ERR_INVALID;
  return VX_OK;
}

// The ring, as it is now: its header, then its records in order. The process
// still writes the header, so what it says is read once and held to the
// ring's size: a cap or head it changed gives it nonsense, not procfs a fault.
static size_t prof_snapshot(const proc *p, uint8_t *out, size_t cap) {
  const vx_prof_header *h = rings[p - procs];
  if (!h || cap < sizeof *h) return 0;
  memcpy(out, h, sizeof *h);
  uint64_t head = atomic_load_explicit(&h->head, memory_order_acquire);
  uint32_t ring = ((vx_prof_header *)out)->cap;
  if (!ring || ring > PROF_SLOTS) ring = PROF_SLOTS;
  ((vx_prof_header *)out)->cap = ring;
  uint64_t n = head < ring ? head : ring, first = head - n;
  size_t len = sizeof *h;
  const vx_prof_record *recs = (const vx_prof_record *)(h + 1);
  for (uint64_t i = 0; i < n && len + sizeof *recs <= cap; i++, len += sizeof *recs)
    memcpy(out + len, &recs[(first + i) % ring], sizeof *recs);
  return len;
}
