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
  atomic_store_explicit(&h->spans, tr.spans && tr.on,
                        memory_order_relaxed); // a trace with spans takes its too
  return VX_OK;
}

// Process i's ring, if it has one, and its pid: for trace.c's merge.
static vx_prof_header *prof_ring(uint32_t i, uint64_t *pid) {
  if (i >= MAX_PROCS || !procs[i].used || !rings[i]) return nullptr;
  *pid = procs[i].pid;
  return rings[i];
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

// The rings, as they are now: the header, then every ring's records merged
// oldest first by their end (each thread's ring is in that order already;
// ring 0, shared, nearly). The process still writes all of it, so what it
// says is read once and held to the VMO's layout: a head it changed gives it
// nonsense, not procfs a fault; and a record its thread may have been
// writing over while it was copied is left out (6d6b).
static size_t prof_snapshot(const proc *p, uint8_t *out, size_t cap) {
  vx_prof_header *h = rings[p - procs];
  constexpr uint32_t n_rings = VX_PROF_THREADS + 1;
  static vx_prof_record all[n_rings * VX_PROF_CAP];
  uint32_t from[n_rings], to[n_rings];
  if (!h || cap < sizeof *h) return 0;
  memcpy(out, h, sizeof *h);
  for (uint32_t i = 0; i < n_rings; i++) {
    vx_prof_ring *r = vx_prof_ring_at(h, i);
    uint64_t head = atomic_load_explicit(&r->head, memory_order_acquire);
    uint64_t n = head < VX_PROF_CAP ? head : VX_PROF_CAP, first = head - n;
    vx_prof_record *mine = &all[(size_t)i * VX_PROF_CAP];
    for (uint64_t k = 0; k < n; k++) mine[k] = vx_prof_ring_records(r)[(first + k) % VX_PROF_CAP];
    uint64_t after = atomic_load_explicit(&r->head, memory_order_acquire); // what was written meanwhile
    uint64_t lost = after > head ? after - head : 0;                       // over the oldest ones
    if (after < head) lost = n; // a head it set back: nothing trusted
    uint64_t base = (uint64_t)i * VX_PROF_CAP;
    from[i] = (uint32_t)(base + (lost < n ? lost : n)), to[i] = (uint32_t)(base + n);
  }
  size_t len = sizeof *h;
  for (; len + sizeof(vx_prof_record) <= cap; len += sizeof(vx_prof_record)) { // the earliest end among them
    int32_t best = -1;
    for (uint32_t i = 0; i < n_rings; i++)
      if (from[i] < to[i] && (best < 0 || all[from[i]].end < all[from[best]].end)) best = (int32_t)i;
    if (best < 0) break;
    memcpy(out + len, &all[from[best]++], sizeof(vx_prof_record));
  }
  vx_prof_header *o = (vx_prof_header *)out;
  uint64_t written = (len - sizeof *h) / sizeof(vx_prof_record);
  atomic_store_explicit(&o->head, written, memory_order_relaxed);
  o->cap = (uint32_t)written, o->rings = 0;
  return len;
}
