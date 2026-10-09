// procfs's /proc/trace (20 §7, ADR-0049, M7 step 7a1b): the kernel's trace,
// read by the one process svcd gives a trace-only Resource ("trace").
//
//   /proc/trace/ctl      start sched,ipc,irq,vm,futex,syscall,mark [size 4M] [circular] · stop · rewind · mark TEXT
//   /proc/trace/events   every CPU's ring merged by time, oldest first: 32-byte records (.schema)
//   /proc/trace/status   ndb: the state, then a record per ring: records and drops
//   /proc/trace/.schema  the record's fields and kinds
//
// It shows every process's activity, so it is a broad grant (ADR-0029): the
// directory is there only for an attach by a user who administers (adm),
// by users(6)'s default, as procfs has no namespace to read /adm/users in.
//
// events is a snapshot, made when a read starts at offset 0 (the rings
// merged into one buffer) and read from there until the next read at 0, so
// a reader sees one consistent stream however it splits its reads.

#include "../../lib/vx-users/users.c"

enum : uint32_t { TR_DIR = 1, TR_CTL, TR_EVENTS, TR_STATUS, TR_SCHEMA, TR_FILES };
static constexpr uint64_t TRACE_PID = 0xffff'ffff; // no task has it

static const file_entry TRACE_FILES[TR_FILES] = {
    [TR_DIR] = {VX_STR("trace"), P9_DMDIR | 0550}, [TR_CTL] = {VX_STR("ctl"), 0220},
    [TR_EVENTS] = {VX_STR("events"), 0440},        [TR_STATUS] = {VX_STR("status"), 0440},
    [TR_SCHEMA] = {VX_STR(".schema"), 0440},
};

static struct {
  vx_handle resource; // svcd's "trace": VX_RIGHT_TRACE alone
  vx_handle rings;
  uint64_t base, size; // the rings' VMO, mapped read-only
  bool on, circular;
  bool spans; // processes write spans (20 §5), merged into events
  uint64_t span_from[MAX_PROCS][VX_PROF_THREADS +
                                1]; // each ring's head at the start: earlier records are not this trace's
  uint32_t categories;
  uint64_t ring_size;
  uint8_t *snap; // the merged snapshot (on the process heap)
  uint64_t snap_len;
} tr;

static vx_prof_header *prof_ring(uint32_t i, uint64_t *pid); // prof.c

static bool trace_node(uint64_t node) { return node >> 32 == TRACE_PID; }

// Every process's ring takes spans, or stops. tr.spans stays as the trace
// started: whether its snapshot takes them.
static void trace_spans(bool on) {
  uint64_t pid;
  for (uint32_t i = 0; i < MAX_PROCS; i++) {
    vx_prof_header *h = prof_ring(i, &pid);
    if (h) atomic_store_explicit(&h->spans, on, memory_order_relaxed);
  }
}
static uint64_t trace_node_of(uint32_t f) { return TRACE_PID << 32 | f; }

// Whether uname may see /proc/trace: an administrator, by users(6)'s default.
static bool trace_allowed(vx_str uname) {
  static vx_users t;
  static bool parsed;
  if (!parsed) parsed = vx_users_parse(&t, VX_STR(VX_USERS_DEFAULT));
  return parsed && vx_users_adm(&t, uname);
}

static const struct {
  const char *name;
  uint32_t bit;
} TRACE_CATS[] = {{"sched", VX_TC_SCHED},   {"ipc", VX_TC_IPC},     {"irq", VX_TC_IRQ},
                  {"vm", VX_TC_VM},         {"futex", VX_TC_FUTEX}, {"syscall", VX_TC_SYSCALL},
                  {"sample", VX_TC_SAMPLE}, {"mark", VX_TC_MARK}};

// The rings, mapped afresh: a start may have made new ones.
static void trace_map(void) {
  if (tr.base) vx_as_unmap(vx_self, tr.base, tr.size), tr.base = 0;
  if (tr.rings) vx_handle_close(tr.rings), tr.rings = VX_HANDLE_NONE;
  vx_trace_ring h;
  if (vx_trace_configure(tr.resource, VX_TRACE_RINGS, &tr.rings, sizeof tr.rings) != VX_OK ||
      vx_vmo_rw(tr.rings, VX_VMO_READ, 0, &h, sizeof h) != VX_OK || h.magic != VX_TRACE_MAGIC)
    return;
  tr.size = h.stride * h.cpus;
  if (vx_as_map(vx_self, tr.rings, 0, tr.size, 0, &tr.base) != VX_OK) tr.base = 0;
}

static const vx_trace_ring *trace_ring(uint32_t i) {
  const vx_trace_ring *h0 = (const vx_trace_ring *)tr.base;
  return tr.base && i < h0->cpus ? (const vx_trace_ring *)(tr.base + i * h0->stride) : nullptr;
}

// ctl's words.
static vx_status trace_ctl(vx_str cmd) {
  vx_str rest = cmd, w;
  if (!tr.resource) return VX_ERR_UNSUPPORTED;
  if (!vx_str_split(&rest, VX_STR(" "), &w)) return VX_ERR_INVALID;
  while (rest.len && rest.ptr[rest.len - 1] == '\n') rest.len--;
  if (vx_str_eq(w, VX_STR("stop"))) {
    vx_status st = vx_trace_configure(tr.resource, VX_TRACE_STOP, nullptr, 0);
    if (st == VX_OK) tr.on = false;
    trace_spans(false);
    return st;
  }
  if (vx_str_eq(w, VX_STR("rewind"))) return vx_trace_configure(tr.resource, VX_TRACE_REWIND, nullptr, 0);
  if (vx_str_eq(w, VX_STR("mark"))) {
    char text[16] = {};
    memcpy(text, rest.ptr, rest.len < sizeof text ? rest.len : sizeof text);
    return vx_trace_configure(tr.resource, VX_TRACE_MARK, text, sizeof text);
  }
  if (!vx_str_eq(w, VX_STR("start"))) return VX_ERR_INVALID;
  vx_trace_start s = {};
  bool spans = false;
  vx_str cats;
  if (!vx_str_split(&rest, VX_STR(" "), &cats)) return VX_ERR_INVALID;
  for (vx_str c; vx_str_split(&cats, VX_STR(","), &c);) {
    uint32_t bit = 0;
    for (size_t i = 0; i < sizeof TRACE_CATS / sizeof TRACE_CATS[0]; i++)
      if (vx_str_eq(c, vx_cstr(TRACE_CATS[i].name))) bit = TRACE_CATS[i].bit;
    if (vx_str_eq(c, VX_STR("span"))) { // the processes', not the kernel's
      spans = true;
      continue;
    }
    if (!bit) return VX_ERR_INVALID;
    s.categories |= bit;
  }
  while (rest.ptr && vx_str_split(&rest, VX_STR(" "), &w)) {
    if (vx_str_eq(w, VX_STR("circular"))) {
      s.circular = 1;
    } else if (vx_str_eq(w, VX_STR("size")) && vx_str_split(&rest, VX_STR(" "), &w) && w.len) {
      uint64_t mult = 1;
      if (w.ptr[w.len - 1] == 'k' || w.ptr[w.len - 1] == 'K') mult = 1024, w.len--;
      if (w.ptr[w.len - 1] == 'm' || w.ptr[w.len - 1] == 'M') mult = 1 << 20, w.len--;
      uint64_t n;
      if (!vx_str_u64(w, &n)) return VX_ERR_INVALID;
      s.ring_size = n * mult;
    } else if (vx_str_eq(w, VX_STR("rate")) && vx_str_split(&rest, VX_STR(" "), &w)) { // samples a second
      uint64_t hz;
      if (!vx_str_u64(w, &hz) || !hz || hz > 10'000) return VX_ERR_INVALID;
      s.sample_hz = (uint32_t)hz;
    } else if (w.len) {
      return VX_ERR_INVALID;
    }
  }
  if (!s.categories) s.categories = VX_TC_MARK; // spans alone: the kernel keeps marks
  vx_status st = vx_trace_configure(tr.resource, VX_TRACE_START, &s, sizeof s);
  if (st != VX_OK) return st;
  tr.spans = spans;
  trace_spans(spans);
  if (spans) { // the spans start empty, as the rings do
    uint64_t pid;
    for (uint32_t i = 0; i < MAX_PROCS; i++) {
      vx_prof_header *h = prof_ring(i, &pid);
      for (uint32_t r = 0; h && r < h->rings; r++)
        tr.span_from[i][r] = atomic_load(&vx_prof_ring_at(h, r)->head);
    }
  }
  tr.on = true, tr.categories = s.categories, tr.circular = s.circular;
  tr.ring_size = s.ring_size ? s.ring_size : 1 << 20;
  trace_map();
  return VX_OK;
}

// The rings merged by time into the snapshot: in each ring, its records
// from the oldest kept (all, or a circular ring's last ring_size / 32).
static void trace_snapshot(void) {
  tr.snap_len = 0;
  const vx_trace_ring *h0 = trace_ring(0);
  if (!h0) return;
  uint32_t cpus = h0->cpus < 64 ? h0->cpus : 64;
  uint64_t at[64], end[64], total = 0, cap = h0->ring_size / sizeof(vx_trace_record);
  for (uint32_t i = 0; i < cpus; i++) {
    uint64_t head = atomic_load(&trace_ring(i)->head);
    end[i] = head, at[i] = head > cap ? head - cap : 0;
    // A ring still going round (the flight recorder): its oldest records may
    // be overwritten while they are copied, so they are left out.
    if (tr.on && tr.circular && head > cap) at[i] += cap / 16;
    total += end[i] - at[i];
  }
  // The processes' spans: counted first, then copied after the kernel's.
  uint64_t spans = 0, pid;
  for (uint32_t i = 0; tr.spans && i < MAX_PROCS; i++) {
    vx_prof_header *h = prof_ring(i, &pid);
    for (uint32_t r = 0; h && r < h->rings && r <= VX_PROF_THREADS; r++) {
      uint64_t head = atomic_load(&vx_prof_ring_at(h, r)->head), from = tr.span_from[i][r];
      if (head > from) spans += head - from < VX_PROF_CAP ? head - from : VX_PROF_CAP;
    }
  }
  vx_heap_free(vx_heap_process(), tr.snap);
  tr.snap =
      total + spans ? vx_heap_alloc(vx_heap_process(), (total + spans) * sizeof(vx_trace_record)) : nullptr;
  if (!tr.snap) return;
  vx_trace_record *out = (vx_trace_record *)tr.snap;
  for (uint64_t k = 0; k < total; k++) {
    int best = -1;
    const vx_trace_record *pick = nullptr;
    for (uint32_t i = 0; i < cpus; i++) {
      if (at[i] == end[i]) continue;
      const vx_trace_record *r =
          (const vx_trace_record *)((const uint8_t *)trace_ring(i) + 4096) + at[i] % cap;
      if (!pick || r->time < pick->time) pick = r, best = (int)i;
    }
    out[k] = *pick;
    at[best]++;
  }
  uint64_t n = total;
  for (uint32_t i = 0; tr.spans && i < MAX_PROCS; i++) {
    vx_prof_header *h = prof_ring(i, &pid);
    for (uint32_t r = 0; h && r < h->rings && r <= VX_PROF_THREADS; r++) {
      vx_prof_ring *ring = vx_prof_ring_at(h, r);
      uint64_t head = atomic_load(&ring->head), from = tr.span_from[i][r];
      if (head > from + VX_PROF_CAP) from = head - VX_PROF_CAP;
      for (uint64_t j = from; j < head && n < total + spans; j++) {
        vx_prof_record rec = vx_prof_ring_records(ring)[j % VX_PROF_CAP];
        if (!rec.flow) continue; // a zone
        out[n++] = (vx_trace_record){.time = rec.start,
                                     .kind = VX_TK_SPAN,
                                     .cpu = 0xffff,
                                     .tid = (uint32_t)(pid << 12 | (rec.thread & 0xfff)),
                                     .a = rec.flow,
                                     .b = (uint64_t)(rec.zone & 0xffff) << 48 |
                                          ((rec.end - rec.start) & 0xffff'ffff'ffff)};
      }
    }
  }
  // The spans by time among themselves (each ring's in order already), then
  // merged with the kernel's, which are.
  for (uint64_t k = total + 1; k < n; k++) {
    vx_trace_record x = out[k];
    uint64_t j = k;
    while (j > total && out[j - 1].time > x.time) out[j] = out[j - 1], j--;
    out[j] = x;
  }
  if (n > total && total) {
    vx_trace_record *merged = vx_heap_alloc(vx_heap_process(), n * sizeof *merged);
    if (merged) {
      for (uint64_t a = 0, b = total, m = 0; m < n; m++)
        merged[m] = b == n || (a < total && out[a].time <= out[b].time) ? out[a++] : out[b++];
      vx_heap_free(vx_heap_process(), tr.snap);
      tr.snap = (uint8_t *)merged;
    }
  }
  tr.snap_len = n * sizeof(vx_trace_record);
}

static size_t trace_status_text(char *buf, size_t cap) {
  vx_ndb_writer w = {.buf = buf, .cap = cap};
  vx_ndb_put(&w, "trace", tr.on ? VX_STR("on") : VX_STR("off"));
  char cats[96];
  size_t n = 0;
  for (size_t i = 0; i < sizeof TRACE_CATS / sizeof TRACE_CATS[0]; i++)
    if (tr.categories & TRACE_CATS[i].bit)
      n +=
          vx_bfmt((vx_bytes){(uint8_t *)cats + n, sizeof cats - n}, "%s%s", n ? "," : "", TRACE_CATS[i].name);
  if (n) vx_ndb_put(&w, "categories", (vx_str){cats, n});
  vx_ndb_put(&w, "mode", tr.circular ? VX_STR("circular") : VX_STR("oneshot"));
  vx_ndb_put_u64(&w, "size", tr.ring_size);
  vx_ndb_end(&w);
  for (uint32_t i = 0; trace_ring(i); i++) {
    const vx_trace_ring *h = trace_ring(i);
    vx_ndb_put_u64(&w, "ring", i);
    vx_ndb_put_u64(&w, "records", atomic_load(&h->head));
    vx_ndb_put_u64(&w, "dropped", h->dropped);
    if (h->dropped)
      vx_ndb_put_u64(&w, "first_drop", h->first_drop), vx_ndb_put_u64(&w, "last_drop", h->last_drop);
    vx_ndb_put_u64(&w, "hz", h->counter_hz);
    vx_ndb_end(&w);
  }
  return w.failed ? 0 : w.len;
}

static const char TRACE_SCHEMA[] =
    "record size=32 order=little\n"
    "field=time offset=0 size=8 what=\"the cycle counter; status's hz gives its frequency\"\n"
    "field=kind offset=8 size=2\n"
    "field=cpu offset=10 size=2\n"
    "field=tid offset=12 size=4 what=\"task id << 12 | thread id in the task; 0 the kernel\"\n"
    "field=a offset=16 size=8\n"
    "field=b offset=24 size=8\n"
    "kind=1 name=switch a=\"thread out | its state << 32\" b=\"thread in\"\n"
    "kind=2 name=wake a=thread b=\"waker, 0 for a deadline\"\n"
    "kind=3 name=block a=\"why: 1 port 2 futex 3 channel 4 pager 5 exception 6 sleep\" b=object\n"
    "kind=4 name=call a=channel b=flow\n"
    "kind=5 name=reply a=channel b=flow\n"
    "kind=6 name=donate a=\"thread lent to\" b=lender\n"
    "kind=7 name=return a=thread\n"
    "kind=8 name=irq_in a=line\n"
    "kind=9 name=irq_out a=line\n"
    "kind=10 name=timer a=now\n"
    "kind=11 name=fault a=address b=\"1 lazy 2 pager 3 upgrade 4 stands\"\n"
    "kind=12 name=pager_wait a=vmo b=offset\n"
    "kind=13 name=pager_done a=vmo b=offset\n"
    "kind=14 name=futex_wait a=word\n"
    "kind=15 name=futex_woken a=word b=\"ns waited\"\n"
    "kind=16 name=sys_in a=number\n"
    "kind=17 name=sys_out a=number b=result\n"
    "kind=18 name=mark a=text b=text\n"
    "kind=19 name=sample a=pc b=\"frames that follow | 1 << 63 in user mode | 1 << 62 | event << 48 from a "
    "counter\"\n"
    "kind=20 name=frames a=\"return address\" b=\"return address, 0 for none\"\n"
    "kind=64 name=span a=flow b=\"message type << 48 | cycles\" cpu=0xffff tid=\"pid << 12 | thread\"\n";

// The last `seconds` of the trace, as events has them, for a crash
// directory (20 §7): *len bytes from *out, at most 4 MiB, the newest kept.
// None if no trace runs.
static void trace_last(uint64_t seconds, const uint8_t **out, size_t *len) {
  *out = nullptr, *len = 0;
  const vx_trace_ring *h0 = trace_ring(0);
  if (!tr.on || !h0) return;
  trace_snapshot();
  const vx_trace_record *r = (const vx_trace_record *)tr.snap;
  size_t n = tr.snap_len / sizeof *r, first = 0;
  if (!n) return;
  uint64_t newest = r[n - 1].time, back = seconds * h0->counter_hz;
  while (first < n && newest - r[first].time > back) first++;
  if (n - first > (4u << 20) / sizeof *r) first = n - (4u << 20) / sizeof *r;
  *out = (const uint8_t *)(r + first), *len = (n - first) * sizeof *r;
}

// vx.trace=flight on the kernel's command line (svcd gives procfs it): the
// flight recorder, sched, ipc and irq in circular mode from now (20 §7).
static void trace_flight(void) {
  vx_str rest = vx_spawn.cmdline, w;
  bool flight = false;
  while (!flight && vx_str_split(&rest, VX_STR(" "), &w)) flight = vx_str_eq(w, VX_STR("vx.trace=flight"));
  if (!flight || !tr.resource) return;
  vx_status st = trace_ctl(VX_STR("start sched,ipc,irq size 1M circular"));
  vx_print(st == VX_OK ? VX_STR("procfs: the flight recorder is on\n")
                       : VX_STR("procfs: the flight recorder could not start\n"));
}

static vx_status trace_read(uint32_t f, uint64_t offset, uint8_t *buf, uint32_t *count) {
  static char text[8192];
  size_t len = 0;
  const uint8_t *src = (const uint8_t *)text;
  if (f == TR_EVENTS) {
    if (offset == 0) trace_snapshot();
    src = tr.snap, len = tr.snap_len;
  } else if (f == TR_STATUS) {
    len = trace_status_text(text, sizeof text);
  } else if (f == TR_SCHEMA) {
    src = (const uint8_t *)TRACE_SCHEMA, len = sizeof TRACE_SCHEMA - 1;
  } else {
    return VX_ERR_ACCESS;
  }
  uint64_t left = offset >= len ? 0 : len - offset;
  uint32_t n = (uint32_t)(left < *count ? left : *count);
  if (n) memcpy(buf, src + offset, n);
  *count = n;
  return VX_OK;
}

static vx_status trace_write_ctl(uint32_t f, const uint8_t *buf, const uint32_t *count) {
  if (f != TR_CTL) return VX_ERR_ACCESS;
  return trace_ctl((vx_str){(const char *)buf, *count});
}

static vx_status trace_stat(uint64_t node, p9_stat *out) {
  uint32_t f = (uint32_t)node;
  if (!f || f >= TR_FILES) return VX_ERR_NOT_FOUND;
  const file_entry *e = &TRACE_FILES[f];
  *out = (p9_stat){
      .qid = {e->mode & P9_DMDIR ? P9_QTDIR : P9_QTFILE, 0, node}, .mode = e->mode, .name = e->name};
  if (f == TR_EVENTS) out->length = tr.snap_len;
  out->uid = out->gid = out->muid = VX_STR("adm");
  return VX_OK;
}
