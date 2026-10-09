// prof.c: /proc/N/prof (docs/05 §9, 20 §7), a process's profiling zones,
// samples and counters. Part of procfs.c.
//
//   /proc/N/prof/ctl       zones on|off · sample HZ|off · count EVENTS [period N]|off
//   /proc/N/prof/zones     the ring as it is now: a vx_prof_header, then the
//                          records it holds, oldest first (lib/vx-prof/prof.h)
//   /proc/N/prof/samples   its samples (7a3c1): a vx_pmu_ring, then the
//                          SAMPLE and FRAMES records it holds, oldest first
//   /proc/N/prof/counters  its counters' totals, an ndb record each
//
// Samples and counters are the kernel's (pmu_configure, ADR-0050) through
// procfs's handle to the task, for whoever may open these files: the
// process's owner, as for its memory. EVENTS are comma-separated: cycles,
// instructions, cache-misses, branch-misses; with a period, the first is
// sampled each N of it, into samples.
//
// A process gives procfs its ring with PROC_PROF (vx_prof_init): procfs maps
// the VMO too, writes a challenge of its own into it, and takes it only if
// the process's memory, at the address it says it maps the ring at, then
// shows that challenge: the proof that the process maps that VMO there. (What
// the sender wrote itself proves nothing: it chose the address, and could
// name bytes another process happens to hold.)

static vx_prof_header *rings[MAX_PROCS]; // each process's, mapped here; null if none

// Each process's samples: the ring's VMO and where procfs maps it, read-only;
// and the events procfs counts for it, for counters' names.
static constexpr uint64_t SAMPLE_RING = 1 << 20; // 32767 records
static struct {
  vx_handle vmo;
  uint64_t at;
  uint32_t count, events[VX_PMU_MAX];
} sampling[MAX_PROCS];

static const char *const EVENT_NAMES[] = {
    [VX_PMU_CYCLES] = "cycles",
    [VX_PMU_INSTRUCTIONS] = "instructions",
    [VX_PMU_CACHE_MISSES] = "cache-misses",
    [VX_PMU_BRANCH_MISSES] = "branch-misses",
};

static void samples_forget(const proc *p) {
  uint32_t i = (uint32_t)(p - procs);
  if (sampling[i].at) vx_as_unmap(vx_self, sampling[i].at, SAMPLE_RING);
  if (sampling[i].vmo) vx_handle_close(sampling[i].vmo);
  sampling[i] = (typeof(sampling[0])){};
}

// sample HZ: a ring for its samples, given to the kernel; sample off.
static vx_status samples_ctl(const proc *p, vx_str arg) {
  uint32_t i = (uint32_t)(p - procs);
  if (word_is(arg, "off")) {
    vx_pmu_samples none = {.vmo = VX_HANDLE_NONE};
    vx_status st = vx_pmu_configure(p->task, VX_PMU_SAMPLES, &none, sizeof none);
    if (st == VX_OK) samples_forget(p);
    return st;
  }
  uint64_t hz;
  if (!parse_u64(arg, &hz) || !hz || hz > 10'000) return VX_ERR_INVALID;
  vx_handle v = VX_HANDLE_NONE;
  uint64_t at = 0;
  vx_status st = vx_vmo_create(SAMPLE_RING, 0, &v); // committed: the kernel writes it from interrupts
  if (st == VX_OK) st = vx_as_map(vx_self, v, 0, SAMPLE_RING, 0, &at);
  vx_handle given = VX_HANDLE_NONE;
  if (st == VX_OK) st = vx_handle_dup(v, VX_RIGHTS_SAME, &given);
  vx_pmu_samples s = {.vmo = given, .hz = (uint32_t)hz};
  if (st == VX_OK) st = vx_pmu_configure(p->task, VX_PMU_SAMPLES, &s, sizeof s);
  if (given) vx_handle_close(given); // the kernel holds the VMO itself
  if (st != VX_OK) {
    if (at) vx_as_unmap(vx_self, at, SAMPLE_RING);
    if (v) vx_handle_close(v);
    return st;
  }
  uint32_t count = sampling[i].count, events[VX_PMU_MAX];
  memcpy(events, sampling[i].events, sizeof events);
  samples_forget(p);
  sampling[i].vmo = v, sampling[i].at = at, sampling[i].count = count;
  memcpy(sampling[i].events, events, sizeof events);
  return VX_OK;
}

// count EVENTS [period N]: the counters; count off.
static vx_status counters_ctl(const proc *p, vx_str arg) {
  vx_pmu_config c = {};
  if (!word_is(arg, "off")) {
    vx_str names, rest = arg;
    if (!vx_str_split(&rest, VX_STR(" "), &names)) return VX_ERR_INVALID;
    vx_str name;
    while (names.len && vx_str_split(&names, VX_STR(","), &name)) {
      uint32_t e = 0;
      for (uint32_t k = VX_PMU_CYCLES; k <= VX_PMU_BRANCH_MISSES; k++)
        if (vx_str_eq(name, vx_cstr(EVENT_NAMES[k]))) e = k;
      if (!e || c.count == VX_PMU_MAX) return VX_ERR_INVALID;
      c.events[c.count++] = e;
    }
    vx_str w;
    if (rest.ptr && vx_str_split(&rest, VX_STR(" "), &w) && w.len) {
      if (!vx_str_eq(w, VX_STR("period")) || !vx_str_split(&rest, VX_STR(" "), &w) ||
          !parse_u64(w, &c.sample_period[0]))
        return VX_ERR_INVALID;
    }
    if (!c.count) return VX_ERR_INVALID;
  }
  vx_status st = vx_pmu_configure(p->task, VX_PMU_SET, &c, sizeof c);
  if (st == VX_OK) {
    uint32_t i = (uint32_t)(p - procs);
    sampling[i].count = c.count;
    memcpy(sampling[i].events, c.events, sizeof c.events);
  }
  return st;
}

// The samples as they are now: the header, then the records it holds,
// oldest first; a record the kernel may have been writing over while it was
// copied is left out, as zones' are.
static size_t samples_snapshot(const proc *p, uint8_t *out, size_t cap) {
  const vx_pmu_ring *h = (const vx_pmu_ring *)sampling[p - procs].at;
  if (!h || cap < sizeof *h || h->magic != VX_PMU_RING_MAGIC) return 0;
  uint64_t ring_cap = (SAMPLE_RING - sizeof *h) / sizeof(vx_trace_record); // the VMO's, not what it says
  uint64_t head = atomic_load_explicit(&h->head, memory_order_acquire);
  uint64_t n = head < ring_cap ? head : ring_cap, first = head - n;
  if (n > (cap - sizeof *h) / sizeof(vx_trace_record)) n = (cap - sizeof *h) / sizeof(vx_trace_record);
  const vx_trace_record *r = (const vx_trace_record *)(h + 1);
  vx_trace_record *o = (vx_trace_record *)(out + sizeof *h);
  for (uint64_t k = 0; k < n; k++) o[k] = r[(first + k) % ring_cap];
  uint64_t after = atomic_load_explicit(&h->head, memory_order_acquire);
  uint64_t lost = after - head < n ? after - head : n; // overwritten while copied: the oldest
  memmove(o, o + lost, (n - lost) * sizeof *o);
  n -= lost;
  memcpy(out, h, sizeof *h);
  vx_pmu_ring *oh = (vx_pmu_ring *)out;
  atomic_store_explicit(&oh->head, n, memory_order_relaxed);
  oh->cap = n;
  return sizeof *h + n * sizeof(vx_trace_record);
}

// counters: event=NAME count=N, a record each (counter=I for one the
// process set itself).
static size_t counters_text(const proc *p, char *text, size_t cap) {
  uint64_t v[VX_PMU_MAX];
  if (vx_pmu_configure(p->task, VX_PMU_READ, v, sizeof v) != VX_OK) return 0;
  uint32_t i = (uint32_t)(p - procs);
  vx_ndb_writer w = {.buf = text, .cap = cap};
  for (uint32_t k = 0; k < VX_PMU_MAX; k++) {
    if (k < sampling[i].count)
      vx_ndb_put(&w, "event", vx_cstr(EVENT_NAMES[sampling[i].events[k]]));
    else if (v[k])
      vx_ndb_put_u64(&w, "counter", k);
    else
      continue;
    vx_ndb_put_u64(&w, "count", v[k]);
    vx_ndb_end(&w);
  }
  return w.failed ? 0 : w.len;
}

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
  vx_str rest = cmd, w = {};
  if (vx_str_split(&rest, VX_STR(" "), &w) && vx_str_eq(w, VX_STR("sample")) && rest.ptr)
    return samples_ctl(p, rest);
  if (vx_str_eq(w, VX_STR("count")) && rest.ptr) return counters_ctl(p, rest);
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

// /proc/N/heap (7a4b): its process heap (lib/vx-rt/heap.c), read from its
// memory through the address its ring names: the heap's extent, then a
// record for each size class in use (its slabs, blocks in use and their
// room), its large blocks and its free runs, from its table of spans.
// Nothing for a process with no ring, or no heap made yet.
static size_t heap_text(const proc *p, char *text, size_t cap) {
  const vx_prof_header *r = rings[p - procs];
  uint64_t where = r ? r->heap : 0, at = 0;
  vx_heap h;
  if (!where || mem_rw(p, where, &at, sizeof at, false) != VX_OK || !at ||
      mem_rw(p, at, &h, sizeof h, false) != VX_OK || h.nil || h.top > h.spans)
    return 0;
  static struct {
    uint32_t slabs, used;
  } cls[VX_HEAP_CLASSES];
  memset(cls, 0, sizeof cls);
  uint64_t large = 0, large_spans = 0, free_spans = 0, dirty = 0, meta = 0;
  static vx_heap_span chunk[256];
  for (uint32_t i = 0; i < h.top; i += 256) {
    uint32_t n = h.top - i < 256 ? h.top - i : 256;
    if (mem_rw(p, (uint64_t)(uintptr_t)(h.span + i), chunk, n * sizeof *chunk, false) != VX_OK) return 0;
    for (uint32_t k = 0; k < n; k++) {
      const vx_heap_span *s = &chunk[k];
      if (s->kind == HEAP_SLAB && s->cls < VX_HEAP_CLASSES) cls[s->cls].slabs++, cls[s->cls].used += s->used;
      if (s->kind == HEAP_LARGE) large++, large_spans += s->len;
      if (s->kind == HEAP_FREE && s->at == i + k)
        free_spans += s->len, dirty += s->dirty ? s->len : 0; // a run's head
      if (s->kind == HEAP_META) meta++;
    }
  }
  vx_ndb_writer w = {.buf = text, .cap = cap};
  vx_ndb_put_u64(&w, "heap", h.size);
  vx_ndb_put_u64(&w, "top", (uint64_t)h.top * VX_HEAP_SPAN);
  vx_ndb_put_u64(&w, "segments", h.segments);
  vx_ndb_put_u64(&w, "meta", meta * VX_HEAP_SPAN);
  vx_ndb_end(&w);
  for (uint32_t c = 0; c < VX_HEAP_CLASSES; c++) {
    if (!cls[c].slabs) continue;
    vx_ndb_put_u64(&w, "class", VX_HEAP_CLASS[c]);
    vx_ndb_put_u64(&w, "slabs", cls[c].slabs);
    vx_ndb_put_u64(&w, "used", cls[c].used);
    vx_ndb_put_u64(&w, "blocks", cls[c].slabs * (VX_HEAP_SPAN / VX_HEAP_CLASS[c]));
    vx_ndb_end(&w);
  }
  vx_ndb_put_u64(&w, "large", large);
  vx_ndb_put_u64(&w, "bytes", large_spans * VX_HEAP_SPAN);
  vx_ndb_end(&w);
  vx_ndb_put_u64(&w, "free", free_spans * VX_HEAP_SPAN);
  vx_ndb_put_u64(&w, "dirty", dirty * VX_HEAP_SPAN);
  vx_ndb_end(&w);
  return w.failed ? 0 : w.len;
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
