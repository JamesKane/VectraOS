// trace.c: the kernel's trace (20 §4, ADR-0049, M7 step 7a1): one ring per
// CPU of 32-byte records, in one VMO procfs maps read-only.
//
// The writer is the CPU itself, and the kernel runs with interrupts off, so
// a ring has one writer and needs no lock (Fuchsia's ktrace, ktrace.cc:92).
// Stopping clears the mask, then waits until no CPU is mid-record: each sets
// its `writing` flag before it looks at the mask and clears it after, so
// once the mask is clear and every flag has been seen clear, no record is
// being written (in place of Fuchsia's IPI barrier, ktrace.cc:275).

static struct {
  spinlock lock; // configuration
  vmo *rings;
  uint64_t ring_size, stride;
  uint32_t cpus;
  bool circular;
  _Atomic uint32_t writing[MAX_CPUS];
} trace;

static uint32_t trace_tid(const struct thread *t) {
  return t && t->task ? (uint32_t)(t->task->id << 12 | (t->id & 0xfff)) : 0;
}

// Where byte `at` of the rings' VMO is, through the direct map.
static uint8_t *trace_at(uint64_t at) {
  uint64_t pa = vmo_page(trace.rings, at / 4096);
  return pa ? (uint8_t *)phys_to_virt(pa) + at % 4096 : nullptr;
}

static void trace_write(uint16_t kind, uint64_t a, uint64_t b) {
  uint32_t i = arch_cpu_index();
  atomic_store_explicit(&trace.writing[i], 1, memory_order_seq_cst);
  if (atomic_load_explicit(&trace_mask, memory_order_seq_cst) && trace.rings && i < trace.cpus) {
    vx_trace_ring *h = (vx_trace_ring *)trace_at(i * trace.stride);
    uint64_t n = trace.ring_size / sizeof(vx_trace_record);
    uint64_t head = atomic_load_explicit(&h->head, memory_order_relaxed);
    uint64_t now = arch_counter();
    if (!trace.circular && head >= n) { // full: counted, not written
      if (!h->dropped++) h->first_drop = now;
      h->last_drop = now;
    } else {
      vx_trace_record *r = (vx_trace_record *)trace_at(i * trace.stride + 4096 + (head % n) * sizeof *r);
      if (r)
        *r = (vx_trace_record){
            .time = now, .kind = kind, .cpu = (uint16_t)i, .a = a, .b = b, .tid = trace_tid(cpus[i].current)};
      atomic_store_explicit(&h->head, head + 1, memory_order_release);
    }
  }
  atomic_store_explicit(&trace.writing[i], 0, memory_order_release);
}

// A sample (20 §6): the interrupted PC and up to 64 return addresses from
// its frame-pointer chain, a frame holding the caller's frame pointer and
// then the return address on both architectures. User frames are read with
// the fault-safe copy, which pages nothing in: the walk stops at the first
// frame not mapped, or that does not move up the stack. The records follow
// one another in this CPU's ring, its interrupts off. tag: the PMU's
// (1 << 62 | its event << 48), 0 for the tick's.
static void trace_sample(bool from_user, uint64_t pc, uint64_t fp, uint64_t tag) {
  uint64_t ret[64];
  uint32_t n = 0;
  while (n < 64 && fp && !(fp & 7)) {
    uint64_t frame[2];
    if (from_user) {
      if (fp >= USER_TOP - 16 || arch_user_copy_in(frame, (const void *)fp, sizeof frame)) break;
    } else {
      if ((int64_t)fp >= 0) break; // the kernel's own frames only
      memcpy(frame, (const void *)fp, sizeof frame);
    }
    if (!frame[1]) break;
    ret[n++] = frame[1];
    if (frame[0] <= fp) break;
    fp = frame[0];
  }
  trace_write(VX_TK_SAMPLE, pc, n | tag | (from_user ? 1ull << 63 : 0));
  for (uint32_t i = 0; i < n; i += 2) trace_write(VX_TK_FRAMES, ret[i], i + 1 < n ? ret[i + 1] : 0);
}

// Writing stops, and returns once no CPU is mid-record.
static void trace_quiesce(void) {
  atomic_store_explicit(&trace_mask, 0, memory_order_seq_cst);
  for (uint32_t i = 0; i < MAX_CPUS; i++)
    while (atomic_load_explicit(&trace.writing[i], memory_order_seq_cst)) arch_pause();
}

// Every ring's header written afresh: empty, no drops.
static void trace_rewind(void) {
  for (uint32_t i = 0; i < trace.cpus; i++) {
    vx_trace_ring *h = (vx_trace_ring *)trace_at(i * trace.stride);
    *h = (vx_trace_ring){.magic = VX_TRACE_MAGIC,
                         .cpu = i,
                         .ring_size = trace.ring_size,
                         .stride = trace.stride,
                         .cpus = trace.cpus,
                         .circular = trace.circular,
                         .counter_hz = clock.hz};
  }
}

static vx_status trace_start(const vx_trace_start *s) {
  uint64_t size = s->ring_size ? s->ring_size : 1ull << 20;
  uint32_t online = atomic_load(&cpus_online);
  if ((size & 4095) || size < 4096 || s->circular > 1 || !s->categories ||
      (s->categories & ~(uint32_t)(VX_TC_SCHED | VX_TC_IPC | VX_TC_IRQ | VX_TC_VM | VX_TC_FUTEX |
                                   VX_TC_SYSCALL | VX_TC_SAMPLE | VX_TC_MARK)) ||
      s->sample_hz > 10'000 || s->reserved)
    return VX_ERR_INVALID;
  if (!online || (size + 4096) * online > VMO_MAX_SIZE) return VX_ERR_RANGE;
  trace_quiesce();
  if (!trace.rings || trace.ring_size != size || trace.cpus != online) { // new rings; readers keep the old
    vmo *v;
    vx_status st = vmo_create((size + 4096) * online, &v);
    if (st != VX_OK) return st;
    if (trace.rings) object_release(&trace.rings->obj);
    trace.rings = v, trace.ring_size = size, trace.stride = size + 4096, trace.cpus = online;
  }
  trace.circular = s->circular;
  atomic_store(&trace_sample_ns, 1'000'000'000ull / (s->sample_hz ? s->sample_hz : 1000));
  trace_rewind();
  atomic_store_explicit(&trace_mask, s->categories, memory_order_seq_cst);
  return VX_OK;
}

// trace_configure(resource, op, data, len): with a Resource handle that has
// VX_RIGHT_TRACE (procfs's) or MANAGE (the root's).
static int64_t sys_trace_configure(vx_handle rh, uint64_t op, uint64_t data, uint64_t len) {
  vx_status st;
  object *r = handle_get(current_task(), rh, OBJ_RESOURCE, VX_RIGHT_TRACE, &st);
  if (!r) r = handle_get(current_task(), rh, OBJ_RESOURCE, VX_RIGHT_MANAGE, &st);
  if (!r) return st;
  object_release(r);
  int64_t ret = VX_OK;
  spin_lock(&trace.lock);
  switch (op) {
  case VX_TRACE_START: {
    vx_trace_start s;
    ret = len == sizeof s ? copy_from_user(&s, data, sizeof s) : VX_ERR_INVALID;
    if (ret == VX_OK) ret = trace_start(&s);
    break;
  }
  case VX_TRACE_STOP: trace_quiesce(); break;
  case VX_TRACE_REWIND: {
    uint32_t mask = atomic_load(&trace_mask);
    trace_quiesce();
    if (trace.rings) trace_rewind();
    atomic_store(&trace_mask, mask);
    break;
  }
  case VX_TRACE_RINGS: {
    vx_handle h = VX_HANDLE_NONE;
    if (len != sizeof h) {
      ret = VX_ERR_INVALID;
      break;
    }
    if (!trace.rings) {
      ret = VX_ERR_BAD_STATE; // never started
      break;
    }
    object_ref(&trace.rings->obj);
    ret = handle_add(current_task(), &trace.rings->obj,
                     VX_RIGHT_READ | VX_RIGHT_MAP | VX_RIGHT_DUPLICATE | VX_RIGHT_TRANSFER, &h);
    if (ret != VX_OK) object_release(&trace.rings->obj);
    if (ret == VX_OK && len == sizeof h)
      ret = copy_to_user(data, &h, sizeof h);
    else if (ret == VX_OK)
      ret = VX_ERR_INVALID;
    break;
  }
  case VX_TRACE_MARK: {
    uint64_t text[2] = {};
    ret = len <= sizeof text ? copy_from_user(text, data, len) : VX_ERR_INVALID;
    if (ret == VX_OK) TRACE(VX_TC_MARK, VX_TK_MARK, text[0], text[1]);
    break;
  }
  default: ret = VX_ERR_INVALID;
  }
  spin_unlock(&trace.lock);
  return ret;
}
