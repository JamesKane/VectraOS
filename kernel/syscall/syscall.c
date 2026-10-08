// syscall.c: the syscalls M1 implements, and user memory access (docs/01 §3).
//
// Every syscall returns an int64: a count or value when >= 0, a vx_status when
// < 0. The rest of the 61 in abi/vx/syscalls.def return VX_ERR_UNSUPPORTED
// until the milestone that needs them. The argument conventions here are a
// draft until ADR-0004 freezes vx-abi v0.

static task *current_task(void) { return this_cpu()->current->task; }

// User pointers are checked against the current task's page tables before the
// kernel touches them, and then touched only through arch_user_copy_in and _out: another
// thread may unmap a range between the check and the copy, and a fault there
// makes the copy fail instead of the kernel. (With SMAP and PAN switched on,
// these will also open and close user access.)
// A page not mapped yet that a touch would bring in, a lazy VMO's
// (ADR-0046) or a pager's, is brought in here as that touch would, waiting
// for the pager if it must: a buffer a program has not touched yet is as
// good as one it has (the dynamic loader's first read into its heap, 6f1a).
static bool user_range_ok(uint64_t addr, uint64_t len, bool write) {
  uint64_t end;
  if (len == 0) return true;
  if (ckd_add(&end, addr, len) || end > USER_TOP) return false;
  for (uint64_t page = addr & ~4095ull; page < end; page += 4096)
    if (!user_page_ok(current_task()->root, page, write) &&
        (pager_fault(page, write ? 1 : 0) != PAGER_MAPPED ||
         !user_page_ok(current_task()->root, page, write)))
      return false;
  return true;
}

// A copy the caller's protection-key rights stop (ADR-0035: the hardware
// checks them for the kernel's accesses too) is ACCESS, any other fault INVALID.
static vx_status copy_from_user(void *dst, uint64_t src, uint64_t len) {
  if (!user_range_ok(src, len, false)) return VX_ERR_INVALID;
  if (!arch_user_copy_in(dst, (const void *)src, len)) return VX_OK;
  return arch_user_copy_denied() ? VX_ERR_ACCESS : VX_ERR_INVALID;
}

static vx_status copy_to_user(uint64_t dst, const void *src, uint64_t len) {
  if (!user_range_ok(dst, len, true)) return VX_ERR_INVALID;
  if (!arch_user_copy_out((void *)dst, src, len)) return VX_OK;
  return arch_user_copy_denied() ? VX_ERR_ACCESS : VX_ERR_INVALID;
}

static constexpr uint32_t ALL_RIGHTS = (1u << VX_RIGHT_BIT_COUNT) - 1;

static void object_destroy(object *obj) {
  switch (obj->type) {
  case OBJ_VMO: vmo_destroy((vmo *)obj); break;
  case OBJ_PORT: port_destroy((port *)obj); break;
  case OBJ_CHANNEL: channel_destroy((channel *)obj); break;
  case OBJ_COUNTER: counter_destroy((counter *)obj); break;
  case OBJ_RING: ring_destroy((ring_end *)obj); break;
  case OBJ_TASK: task_destroy((task *)obj); break;
  case OBJ_THREAD: thread_destroy((thread *)obj); break;
  case OBJ_RESOURCE: pool_free(&resource_pool, obj); break;
  case OBJ_IRQ: irq_destroy((irq *)obj); break;
  case OBJ_IORANGE: pool_free(&iorange_pool, obj); break;
  case OBJ_DMA_DOMAIN: dma_domain_destroy((dma_domain *)obj); break;
  case OBJ_DMA_MAPPING: dma_mapping_destroy((dma_mapping *)obj); break;
  case OBJ_PAGER: pager_destroy((pager *)obj); break;
  case OBJ_SCHED_CTX: sched_ctx_destroy((sched_ctx *)obj); break;
  default: break;
  }
}

// Gives the current task a handle to a new object, dropping the creator's reference.
static int64_t return_handle(object *obj, uint32_t rights, uint64_t out) {
  vx_handle h;
  vx_status st = handle_add(current_task(), obj, rights, &h);
  object_release(obj);
  if (st != VX_OK) return st;
  st = copy_to_user(out, &h, sizeof h);
  if (st != VX_OK) handle_close(current_task(), h);
  return st;
}

static int64_t sys_debug_write(uint64_t ptr, uint64_t len) {
  if (!current_task()->may_debug_write) return VX_ERR_ACCESS;
  char buf[256];
  while (len) {
    uint64_t n = len < sizeof buf ? len : sizeof buf;
    vx_status st = copy_from_user(buf, ptr, n);
    if (st != VX_OK) return st;
    thread *self = this_cpu()->current;
    console_user_write((vx_str){buf, n}, self->console_buf, sizeof self->console_buf, &self->console_len);
    ptr += n;
    len -= n;
  }
  return VX_OK;
}

// The task a task_info or task_kill acts on: the handle's, or with an id, that
// task in the handle's tree (abi.h). With a reference.
static task *task_target(vx_handle h, uint32_t rights, uint64_t id, bool next, vx_status *st) {
  task *t = (task *)handle_get(current_task(), h, OBJ_TASK, rights, st);
  if (!t || (!id && !next)) return t;
  task *found = task_find(t->id, id, next);
  object_release(&t->obj);
  if (!found) *st = VX_ERR_NOT_FOUND;
  return found;
}

static int64_t sys_task_info(vx_handle h, uint64_t out, uint64_t id, uint64_t flags) {
  if (flags & ~(uint64_t)VX_TASK_NEXT) return VX_ERR_INVALID;
  vx_status st;
  task *t = task_target(h, VX_RIGHT_INSPECT, id, flags & VX_TASK_NEXT, &st);
  if (!t) return st;
  spin_lock(&t->lock);
  vx_task_summary info = {.id = t->id,
                          .state = t->state,
                          .threads = t->live_threads,
                          .mapped = t->mapped,
                          .exit_len = t->exit_len};
  memcpy(info.exit, t->exit, t->exit_len);
  for (const thread *th = t->threads; th; th = th->task_next) info.blocked += th->state == THREAD_BLOCKED;
  memcpy(info.name, t->name, sizeof info.name);
  spin_unlock(&t->lock);
  object_release(&t->obj);
  return copy_to_user(out, &info, sizeof info);
}

static int64_t sys_port_create(uint64_t options, uint64_t out) {
  if (options) return VX_ERR_INVALID;
  port *p;
  vx_status st = port_create(&p);
  if (st != VX_OK) return st;
  return return_handle(&p->obj, ALL_RIGHTS & ~(uint32_t)(VX_RIGHT_EXEC | VX_RIGHT_MAP | VX_RIGHT_DEBUG), out);
}

// Returns packets as soon as any are queued; otherwise joins the waiters and
// blocks. The reference handle_get took keeps the port alive through the wait,
// even if another thread closes the handle meanwhile.
static int64_t port_wait_on(port *p, vx_instant deadline, vx_duration leeway, uint64_t out, uint64_t max) {
  for (;;) {
    vx_packet got[PORT_CAPACITY];
    uint32_t n = port_take(p, got, (uint32_t)max);
    if (n) {
      vx_status st = copy_to_user(out, got, n * sizeof(vx_packet));
      return st == VX_OK ? n : st;
    }
    if (clock_now() >= deadline) return VX_ERR_TIMED_OUT;
    thread *t = this_cpu()->current;
    if (!port_join_waiters(p, t)) continue; // a packet arrived meanwhile
    int64_t woke = thread_block(deadline, leeway);
    if (woke != VX_OK) { // its deadline, or a kill: still on the list, so off it
      port_remove_waiter(p, t);
      return woke;
    }
  }
}

static int64_t sys_port_wait(vx_handle h, vx_instant deadline, vx_duration leeway, uint64_t out,
                             uint64_t max) {
  if (max == 0 || max > PORT_CAPACITY || leeway < 0) return VX_ERR_INVALID;
  if (!user_range_ok(out, max * sizeof(vx_packet), true)) return VX_ERR_INVALID;
  vx_status st;
  port *p = (port *)handle_get(current_task(), h, OBJ_PORT, VX_RIGHT_WAIT, &st);
  if (!p) return st;
  int64_t result = port_wait_on(p, deadline, leeway, out, max);
  object_release(&p->obj);
  return result;
}

static int64_t sys_port_post(vx_handle h, uint64_t packet) {
  vx_packet pk;
  vx_status st = copy_from_user(&pk, packet, sizeof pk);
  if (st != VX_OK) return st;
  port *p = (port *)handle_get(current_task(), h, OBJ_PORT, VX_RIGHT_SIGNAL, &st);
  if (!p) return st;
  pk.timestamp = clock_now();
  pk.source = 0;
  pk.trigger = VX_TRIGGER_USER;
  st = port_post(p, &pk);
  object_release(&p->obj);
  return st;
}

// What device objects carry besides the rights to use them: they can be
// passed on, never widened.
static constexpr uint32_t DEVICE_RIGHTS = VX_RIGHT_DUPLICATE | VX_RIGHT_TRANSFER | VX_RIGHT_INSPECT;

// vmo_create(size, options, &out, resource, physical_address): anonymous
// memory, or with VX_VMO_PHYSICAL, device memory minted from a Resource, or
// with VX_VMO_PAGER (the fourth argument a Pager, the fifth a key), memory
// a pager supplies.
static int64_t sys_vmo_create(uint64_t size, uint64_t options, uint64_t out, vx_handle rh, uint64_t pa) {
  uint64_t kinds = options & (VX_VMO_PHYSICAL | VX_VMO_PAGER | VX_VMO_RESIZABLE);
  if ((options & ~(uint64_t)(VX_VMO_PHYSICAL | VX_VMO_PAGER | VX_VMO_RESIZABLE | VX_VMO_LAZY)) ||
      (kinds & (kinds - 1)))
    return VX_ERR_INVALID; // one kind at most
  if ((options & VX_VMO_LAZY) && (options & (VX_VMO_PHYSICAL | VX_VMO_PAGER)))
    return VX_ERR_INVALID; // lazy: anonymous memory's (ADR-0046)
  vmo *v;
  vx_status st;
  if (options & VX_VMO_PAGER) {
    if (pa > UINT32_MAX) return VX_ERR_INVALID;
    pager *g = (pager *)handle_get(current_task(), rh, OBJ_PAGER, VX_RIGHT_WRITE, &st);
    if (!g) return st;
    st = vmo_create_pager(size, g, (uint32_t)pa, &v);
    object_release(&g->obj);
    if (st != VX_OK) return st;
    return return_handle(&v->obj, ALL_RIGHTS & ~(uint32_t)VX_RIGHT_DEBUG, out);
  }
  if (options & VX_VMO_PHYSICAL) {
    resource *r = (resource *)handle_get(current_task(), rh, OBJ_RESOURCE, VX_RIGHT_MANAGE, &st);
    if (!r) return st;
    st = vmo_create_physical(pa, size, &v);
    object_release(&r->obj);
    if (st != VX_OK) return st;
    return return_handle(&v->obj, VX_RIGHT_READ | VX_RIGHT_WRITE | VX_RIGHT_MAP | DEVICE_RIGHTS, out);
  }
  st = options & VX_VMO_LAZY ? vmo_create_lazy(size, &v) : vmo_create(size, &v);
  if (st != VX_OK) return st;
  v->resizable = options & VX_VMO_RESIZABLE; // vmo_op RESIZE may change it (ADR-0042)
  // EXEC included: loaders and JITs map their own code. W^X holds per mapping
  // (task_map), never per VMO.
  return return_handle(&v->obj, ALL_RIGHTS & ~(uint32_t)VX_RIGHT_DEBUG, out);
}

// --- Pagers (obj/pager.c) ---

// pager_create(resource, port, key, deadline_ns, &out): needs a Resource
// handle with VX_RIGHT_PAGER (what svcd gives a pager), or the root's.
static int64_t sys_pager_create(vx_handle rh, vx_handle ph, uint64_t key, uint64_t deadline, uint64_t out) {
  vx_status st;
  resource *r = (resource *)handle_get(current_task(), rh, OBJ_RESOURCE, VX_RIGHT_PAGER, &st);
  if (!r) r = (resource *)handle_get(current_task(), rh, OBJ_RESOURCE, VX_RIGHT_MANAGE, &st);
  if (!r) return st;
  object_release(&r->obj);
  port *p = (port *)handle_get(current_task(), ph, OBJ_PORT, VX_RIGHT_SIGNAL, &st);
  if (!p) return st;
  pager *g;
  st = pager_create(p, key, (vx_duration)deadline, &g);
  object_release(&p->obj);
  if (st != VX_OK) return st;
  return return_handle(
      &g->obj, VX_RIGHT_READ | VX_RIGHT_WRITE | VX_RIGHT_DUPLICATE | VX_RIGHT_TRANSFER | VX_RIGHT_INSPECT,
      out);
}

// pager_supply(pager, vmo, offset, size, source, source_offset)
static int64_t sys_pager_supply(vx_handle gh, vx_handle vh, uint64_t offset, uint64_t size, vx_handle sh,
                                uint64_t src_offset) {
  vx_status st;
  pager *g = (pager *)handle_get(current_task(), gh, OBJ_PAGER, VX_RIGHT_WRITE, &st);
  if (!g) return st;
  vmo *v = (vmo *)handle_get(current_task(), vh, OBJ_VMO, 0, &st);
  vmo *src = v ? (vmo *)handle_get(current_task(), sh, OBJ_VMO, VX_RIGHT_READ, &st) : nullptr;
  if (src) st = pager_supply(g, v, offset, size, src, src_offset);
  if (src) object_release(&src->obj);
  if (v) object_release(&v->obj);
  object_release(&g->obj);
  return st;
}

// pager_op(pager, vmo, op, offset, size, ranges)
static int64_t sys_pager_op(vx_handle gh, vx_handle vh, uint64_t op, uint64_t offset, uint64_t size,
                            uint64_t out) {
  uint64_t end;
  if (op < VX_PAGER_DIRTY || op > VX_PAGER_RESIZE || (offset | size) & 4095) return VX_ERR_INVALID;
  if (ckd_add(&end, offset, size)) return VX_ERR_RANGE;
  if (op == VX_PAGER_DIRTY && !user_range_ok(out, VX_PAGER_RANGES * sizeof(vx_pager_range), true))
    return VX_ERR_INVALID;
  vx_status st;
  pager *g = (pager *)handle_get(current_task(), gh, OBJ_PAGER, VX_RIGHT_WRITE, &st);
  if (!g) return st;
  vmo *v = (vmo *)handle_get(current_task(), vh, OBJ_VMO, 0, &st);
  int64_t r = st;
  if (v && v->pager != g) r = VX_ERR_INVALID;
  if (v && v->pager == g) {
    uint64_t first = offset / 4096, count = size / 4096;
    if (op == VX_PAGER_DIRTY) {
      vx_pager_range ranges[VX_PAGER_RANGES];
      r = pager_dirty(v, offset, size, ranges);
      if (r > 0) {
        vx_status c = copy_to_user(out, ranges, (size_t)r * sizeof ranges[0]);
        if (c != VX_OK) r = c;
      }
    } else if (op == VX_PAGER_RESIZE) { // the pager's alone: every mapping of the VMO shares its size
      r = offset ? VX_ERR_INVALID : vmo_resize(v, size);
    } else if (op == VX_PAGER_IDLE) { // only the caller's handle, and this call's own reference
      r = atomic_load(&v->obj.refs) <= 2 ? 1 : 0;
    } else if (op == VX_PAGER_CLEAN) {
      pager_clean(v, first, count);
      r = VX_OK;
    } else {
      pager_evict(v, first, count);
      r = VX_OK;
    }
  }
  if (v) object_release(&v->obj);
  object_release(&g->obj);
  return r;
}

// vmo_op(vmo, op, arg, size): VX_VMO_RESIZE to arg bytes, or VX_VMO_DECOMMIT
// the pages of [arg, arg + size) (ADR-0046). A pager-backed VMO is its
// pager's to resize (pager_op RESIZE): anyone it is shared with may write it,
// and a writer must not shrink it under the others.
static int64_t sys_vmo_op(vx_handle h, uint64_t op, uint64_t arg, uint64_t size) {
  if (op != VX_VMO_RESIZE && op != VX_VMO_DECOMMIT) return VX_ERR_INVALID;
  vx_status st;
  vmo *v = (vmo *)handle_get(current_task(), h, OBJ_VMO, VX_RIGHT_WRITE, &st);
  if (!v) return st;
  if (v->pager || vmo_sealed(v))
    st = VX_ERR_ACCESS; // its pager's to resize; sealed: no change at all (ADR-0043)
  else if (v->lease_of)
    st = vmo_revoked(v) ? VX_ERR_REVOKED : VX_ERR_UNSUPPORTED; // a lease's size is its parent's
  else if (op == VX_VMO_DECOMMIT)
    st = vmo_decommit(v, arg, size);
  else
    st = vmo_resize(v, arg);
  object_release(&v->obj);
  return st;
}

// vmo_seal(vmo), with WRITE (ADR-0043): sealed first, then every task looked
// at for a writable mapping of it or a lease of it; one found unseals it and
// fails. A map in between checks the seal under its task's lock, which the
// look takes, so none slips past.
static int64_t sys_vmo_seal(vx_handle h) {
  vx_status st;
  vmo *v = (vmo *)handle_get(current_task(), h, OBJ_VMO, VX_RIGHT_WRITE, &st);
  if (!v) return st;
  if (v->physical || v->pager)
    st = VX_ERR_UNSUPPORTED;
  else if (v->lease_of)
    st = VX_ERR_INVALID; // the parent's holder seals it
  else if (!atomic_exchange(&v->sealed, true) && vmo_mapped_writable(v))
    atomic_store(&v->sealed, false), st = VX_ERR_BAD_STATE;
  object_release(&v->obj);
  return st;
}

// vmo_lease(vmo, &lease) (ADR-0043): a lease with the caller's rights and
// MANAGE, which revokes it.
static int64_t sys_vmo_lease(vx_handle h, uint64_t out) {
  if (!user_range_ok(out, sizeof(vx_handle), true)) return VX_ERR_INVALID;
  vx_status st;
  uint32_t rights = 0;
  vmo *v = (vmo *)handle_get_rights(current_task(), h, OBJ_VMO, VX_RIGHT_READ, &rights, &st);
  if (!v) return st;
  vmo *lease = nullptr;
  st = vmo_revoked(v) ? VX_ERR_REVOKED : vmo_lease_create(v, &lease);
  object_release(&v->obj);
  if (st != VX_OK) return st;
  return return_handle(&lease->obj, rights | VX_RIGHT_MANAGE, out);
}

// vmo_revoke(lease), with MANAGE: its mappings lose their pages everywhere,
// and every use of it from now on is REVOKED.
static int64_t sys_vmo_revoke(vx_handle h) {
  vx_status st;
  vmo *v = (vmo *)handle_get(current_task(), h, OBJ_VMO, VX_RIGHT_MANAGE, &st);
  if (!v) return st;
  if (!v->lease_of) {
    st = VX_ERR_INVALID;
  } else if (!atomic_exchange(&v->revoked, true)) {
    vmo_unmap_everywhere(v, 0, v->size / 4096);
  }
  object_release(&v->obj);
  return st;
}

// clock_set(resource, utc): the wall clock, with the root Resource's MANAGE.
static int64_t sys_clock_set(vx_handle rh, uint64_t utc) {
  if ((int64_t)utc <= 0) return VX_ERR_INVALID;
  vx_status st;
  resource *r = (resource *)handle_get(current_task(), rh, OBJ_RESOURCE, VX_RIGHT_MANAGE, &st);
  if (!r) return st;
  object_release(&r->obj);
  clock_set_utc((int64_t)utc);
  return VX_OK;
}

// system_power(resource, op): the machine off, with the root Resource's MANAGE.
static int64_t sys_system_power(vx_handle rh, uint64_t op) {
  if (op != VX_POWER_OFF) return VX_ERR_INVALID;
  vx_status st;
  resource *r = (resource *)handle_get(current_task(), rh, OBJ_RESOURCE, VX_RIGHT_MANAGE, &st);
  if (!r) return st;
  object_release(&r->obj);
  return arch_system_off();
}

// --- Devices (obj/device.c) ---

// irq_create(resource, line, options, &out, &msi): a line, or with VX_IRQ_MSI
// an MSI for the PCI function `line` names, with what to program into it.
static int64_t sys_irq_create(vx_handle rh, uint64_t line, uint64_t options, uint64_t out, uint64_t msi_out) {
  if ((options & ~(uint64_t)VX_IRQ_MSI) || line > UINT32_MAX) return VX_ERR_INVALID;
  vx_status st;
  resource *r = (resource *)handle_get(current_task(), rh, OBJ_RESOURCE, VX_RIGHT_MANAGE, &st);
  if (!r) return st;
  uint32_t canonical;
  irq *q = nullptr;
  vx_msi msi = {};
  if (options & VX_IRQ_MSI) {
    st = irq_create_msi((uint32_t)line, &q, &msi);
    if (st == VX_OK && (st = copy_to_user(msi_out, &msi, sizeof msi)) != VX_OK) object_release(&q->obj);
  } else {
    st = arch_irq_canonical((uint32_t)line, &canonical);
    if (st == VX_OK) st = irq_create(canonical, &q);
  }
  object_release(&r->obj);
  if (st != VX_OK) return st;
  return return_handle(&q->obj, VX_RIGHT_WAIT | VX_RIGHT_WRITE | DEVICE_RIGHTS, out);
}

static int64_t sys_irq_ack(vx_handle h) {
  vx_status st;
  irq *q = (irq *)handle_get(current_task(), h, OBJ_IRQ, VX_RIGHT_WRITE, &st);
  if (!q) return st;
  irq_ack(q);
  object_release(&q->obj);
  return VX_OK;
}

static int64_t sys_dma_domain_create(vx_handle rh, uint64_t source, uint64_t options, uint64_t out) {
  if (options || source > 0xffff) return VX_ERR_INVALID; // pass-through: the only kind so far
  vx_status st;
  resource *r = (resource *)handle_get(current_task(), rh, OBJ_RESOURCE, VX_RIGHT_MANAGE, &st);
  if (!r) return st;
  dma_domain *d = nullptr;
  st = dma_domain_create((uint32_t)source, &d);
  object_release(&r->obj);
  if (st != VX_OK) return st;
  return return_handle(&d->obj, VX_RIGHT_MAP | VX_RIGHT_MANAGE | VX_RIGHT_WAIT | DEVICE_RIGHTS, out);
}

// dma_map(domain, vmo, offset, size, options, mapped): what the device may
// do is what the VMO handle allows (READ to read it, WRITE to write it).
static int64_t sys_dma_map(vx_handle dh, vx_handle vh, uint64_t offset, uint64_t size, uint64_t options,
                           uint64_t out) {
  static constexpr uint64_t MAX_PAGES = 512;
  vx_dma_mapped req;
  vx_status st = copy_from_user(&req, out, sizeof req);
  if (st != VX_OK) return st;
  uint64_t list = (uint64_t)req.addresses;
  if (!options || options & ~(uint64_t)(VX_DMA_READ | VX_DMA_WRITE) || size / 4096 > MAX_PAGES ||
      !user_range_ok(list, size / 4096 * sizeof(uint64_t), true))
    return VX_ERR_INVALID;
  dma_domain *d = (dma_domain *)handle_get(current_task(), dh, OBJ_DMA_DOMAIN, VX_RIGHT_MAP, &st);
  if (!d) return st;
  uint32_t need = (options & VX_DMA_READ ? VX_RIGHT_READ : 0) | (options & VX_DMA_WRITE ? VX_RIGHT_WRITE : 0);
  vmo *v = (vmo *)handle_get(current_task(), vh, OBJ_VMO, need, &st);
  uint64_t addresses[MAX_PAGES];
  if (v &&
      (v->pager || v->resizable || v->lazy || v->lease_of)) { // its pages come and go (a pager's, a shrink, a
                                                              // revoke): no device may hold them
    object_release(&v->obj);
    v = nullptr;
    st = VX_ERR_UNSUPPORTED;
  }
  dma_mapping *m = nullptr;
  if (v) {
    st = dma_map(d, v, offset, size, (uint32_t)options, addresses, &m);
    if (st == VX_OK) st = copy_to_user(list, addresses, size / 4096 * sizeof(uint64_t));
    if (st == VX_OK) {
      st = (vx_status)return_handle(&m->obj, VX_RIGHT_INSPECT, out + offsetof(vx_dma_mapped, mapping));
      m = nullptr; // the handle's now, or gone with it
    }
    if (m) { // never handed out: the device was never told of it
      dma_unmap(m);
      object_release(&m->obj);
    }
    object_release(&v->obj);
  }
  object_release(&d->obj);
  return st;
}

static int64_t sys_dma_unmap(vx_handle mh) {
  vx_status st;
  dma_mapping *m = (dma_mapping *)handle_get(current_task(), mh, OBJ_DMA_MAPPING, 0, &st);
  if (!m) return st;
  st = dma_unmap(m);
  object_release(&m->obj);
  return st;
}

// dma_domain_op(domain, op, 0): REVOKE and QUIESCED are the owner's (MANAGE); FAULTS, INSPECT.
static int64_t sys_dma_domain_op(vx_handle dh, uint64_t op, uint64_t arg) {
  if (arg || op < VX_DMA_REVOKE || op > VX_DMA_FAULTS) return VX_ERR_INVALID;
  vx_status st;
  dma_domain *d = (dma_domain *)handle_get(current_task(), dh, OBJ_DMA_DOMAIN,
                                           op == VX_DMA_FAULTS ? VX_RIGHT_INSPECT : VX_RIGHT_MANAGE, &st);
  if (!d) return st;
  int64_t r = VX_OK;
  if (op == VX_DMA_REVOKE) dma_revoke(d);
  if (op == VX_DMA_QUIESCED) dma_quiesced(d);
  if (op == VX_DMA_FAULTS) {
    spin_lock(&d->lock);
    r = d->faults > INT64_MAX ? INT64_MAX : (int64_t)d->faults;
    spin_unlock(&d->lock);
  }
  object_release(&d->obj);
  return r;
}

static int64_t sys_iorange_create(vx_handle rh, uint64_t base, uint64_t count, uint64_t out) {
  vx_status st;
  resource *r = (resource *)handle_get(current_task(), rh, OBJ_RESOURCE, VX_RIGHT_MANAGE, &st);
  if (!r) return st;
  iorange *io = nullptr;
  st = iorange_create(base, count, &io);
  object_release(&r->obj);
  if (st != VX_OK) return st;
  return return_handle(&io->obj, VX_RIGHT_MAP | DEVICE_RIGHTS, out);
}

// as_unmap(task, address, size): the pages of a range, mapped or not.
static int64_t sys_as_unmap(vx_handle th, uint64_t va, uint64_t size) {
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
  if (!t) return st;
  st = task_unmap(t, va, size);
  object_release(&t->obj);
  return st;
}

// NOACCESS is alone (ADR-0042): no write or execute beside it.
static bool map_flags_ok(uint64_t flags, uint64_t allowed) {
  if (flags & ~allowed) return false;
  return !((flags & VX_MAP_NOACCESS) && (flags & (VX_MAP_WRITE | VX_MAP_EXEC)));
}

static int64_t sys_as_protect(vx_handle th, uint64_t va, uint64_t size, uint64_t flags) {
  if (!map_flags_ok(flags, VX_MAP_WRITE | VX_MAP_EXEC | VX_MAP_KEY_MASK | VX_MAP_NOACCESS))
    return VX_ERR_INVALID;
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
  if (!t) return st;
  st = task_protect(t, va, size, (uint32_t)flags);
  object_release(&t->obj);
  return st;
}

static int64_t sys_as_key_alloc(vx_handle th, uint64_t key_ptr) {
  vx_status st;
  if (!user_range_ok(key_ptr, sizeof(uint32_t), true)) return VX_ERR_INVALID;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
  if (!t) return st;
  uint32_t key = 0;
  st = task_key_alloc(t, &key);
  object_release(&t->obj);
  return st == VX_OK ? copy_to_user(key_ptr, &key, sizeof key) : st;
}

static int64_t sys_as_key_free(vx_handle th, uint64_t key) {
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
  if (!t) return st;
  st = key > 15 ? VX_ERR_INVALID : task_key_free(t, (uint32_t)key);
  object_release(&t->obj);
  return st;
}

// clock_read(&info): the clock's counter, for /sys/clock/info; with no
// argument, the time (dispatched below).
static int64_t sys_clock_info(uint64_t info_ptr) {
  vx_clock_info info = {.counter_hz = clock.hz, .flags = arch_counter_flags()};
  if (atomic_load(&utc_set)) info.flags |= VX_CLOCK_UTC, info.utc_offset = atomic_load(&utc_offset);
  vx_status st = copy_to_user(info_ptr, &info, sizeof info);
  return st == VX_OK ? clock_now() : st;
}

// as_reserve(task, size, align, flags, &address) (ADR-0042).
static int64_t sys_as_reserve(vx_handle th, uint64_t size, uint64_t align, uint64_t flags,
                              uint64_t addr_ptr) {
  if (flags & ~(uint64_t)(VX_AS_FIXED | VX_AS_RELEASE) || flags == (VX_AS_FIXED | VX_AS_RELEASE))
    return VX_ERR_INVALID;
  uint64_t va;
  vx_status st = copy_from_user(&va, addr_ptr, sizeof va);
  if (st != VX_OK) return st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
  if (!t) return st;
  st = task_reserve(t, size, align, (uint32_t)flags, &va);
  object_release(&t->obj);
  vx_status out = st == VX_OK || st == VX_ERR_EXISTS ? copy_to_user(addr_ptr, &va, sizeof va) : VX_OK;
  return out != VX_OK ? out : st;
}

// as_query(task, address, &info): the first mapping ending after address.
static int64_t sys_as_query(vx_handle th, uint64_t addr, uint64_t info_ptr) {
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_INSPECT, &st);
  if (!t) return st;
  vx_map_info info;
  st = task_query(t, addr, &info);
  object_release(&t->obj);
  return st == VX_OK ? copy_to_user(info_ptr, &info, sizeof info) : st;
}

// as_map(task, vmo, offset, size, flags, &address): maps part of a VMO.
// Reservations (01 §5) land with as_reserve. With an IoRange in place of the
// VMO (and the rest 0), it lets the task use those I/O ports instead.
static int64_t sys_as_map(vx_handle th, vx_handle vh, uint64_t offset, uint64_t size, uint64_t flags,
                          uint64_t addr_ptr) {
  vx_status st;
  iorange *io = (iorange *)handle_get(current_task(), vh, OBJ_IORANGE, VX_RIGHT_MAP, &st);
  if (io) {
    task *t = (offset | size | flags)
                  ? nullptr
                  : (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
    if (t) {
      st = task_enable_io(t, io);
      object_release(&t->obj);
    } else if (offset | size | flags) {
      st = VX_ERR_INVALID;
    }
    object_release(&io->obj);
    return st;
  }
  if (!map_flags_ok(flags, VX_MAP_WRITE | VX_MAP_EXEC | VX_MAP_KEY_MASK | VX_MAP_NOACCESS | VX_MAP_SHARED))
    return VX_ERR_INVALID;
  uint64_t va;
  st = copy_from_user(&va, addr_ptr, sizeof va);
  if (st != VX_OK) return st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
  if (!t) return st;
  uint32_t need = VX_RIGHT_MAP | VX_RIGHT_READ | (flags & VX_MAP_WRITE ? VX_RIGHT_WRITE : 0) |
                  (flags & VX_MAP_EXEC ? VX_RIGHT_EXEC : 0);
  vmo *v = (vmo *)handle_get(current_task(), vh, OBJ_VMO, need, &st);
  if (v) {
    // What the handle allows, for as_protect later: asked of it once more each.
    uint32_t allowed = 0;
    vx_status ignored;
    for (uint32_t i = 0; i < 2; i++) {
      uint32_t right = i ? VX_RIGHT_EXEC : VX_RIGHT_WRITE;
      object *o = handle_get(current_task(), vh, OBJ_VMO, VX_RIGHT_MAP | right, &ignored);
      if (o) allowed |= i ? VX_MAP_EXEC : VX_MAP_WRITE, object_release(o);
    }
    st = task_map(t, v, offset, size, (uint32_t)flags, allowed, &va);
    object_release(&v->obj);
  }
  object_release(&t->obj);
  if (st != VX_OK) return st;
  return copy_to_user(addr_ptr, &va, sizeof va);
}

// --- Channels ---

static constexpr uint32_t CHANNEL_END_RIGHTS = VX_RIGHT_READ | VX_RIGHT_WRITE | VX_RIGHT_WAIT |
                                               VX_RIGHT_SIGNAL | VX_RIGHT_DUPLICATE | VX_RIGHT_TRANSFER |
                                               VX_RIGHT_INSPECT;

static int64_t sys_channel_create(uint64_t options, uint64_t out) {
  if (options) return VX_ERR_INVALID;
  if (!user_range_ok(out, 2 * sizeof(vx_handle), true)) return VX_ERR_INVALID;
  channel *a, *b;
  vx_status st = channel_create(&a, &b);
  if (st != VX_OK) return st;
  vx_handle h[2];
  st = handle_add(current_task(), &a->obj, CHANNEL_END_RIGHTS, &h[0]);
  if (st == VX_OK) {
    st = handle_add(current_task(), &b->obj, CHANNEL_END_RIGHTS, &h[1]);
    if (st != VX_OK) handle_close(current_task(), h[0]);
  }
  object_release(&a->obj);
  object_release(&b->obj);
  if (st != VX_OK) return st;
  return copy_to_user(out, h, sizeof h);
}

// Builds a message from user memory: the body copied in, the handles moved out
// of the caller's table (gone whatever happens next, as with every write).
// `through` is the channel end written to: neither it nor its peer may travel in the message.
// values: the handles' values, already copied in (a call's, some lent), or
// null to copy them from handles.
static vx_status msg_from_user(uint64_t bytes, uint32_t len, uint64_t handles, const vx_handle *values_in,
                               uint32_t count, const channel *through, channel_msg **out) {
  if (len < sizeof(vx_msg_header) || len > VX_CHANNEL_MAX_BYTES || count > VX_CHANNEL_MAX_HANDLES)
    return VX_ERR_INVALID;
  vx_handle values[VX_CHANNEL_MAX_HANDLES];
  vx_status st = VX_OK;
  if (values_in)
    memcpy(values, values_in, count * sizeof(vx_handle));
  else
    st = copy_from_user(values, handles, count * sizeof(vx_handle));
  if (st != VX_OK) return st;
  channel_msg *m = msg_alloc(len, count);
  if (!m) return VX_ERR_NO_MEMORY;
  st = copy_from_user(msg_body(m), bytes, len);
  // The peer's address is only compared, never followed: no lock is needed for that.
  const object *peer = (const object *)through->pair->ends[1 - through->side];
  if (st == VX_OK) st = handles_take(current_task(), values, count, &through->obj, peer, m->handles);
  if (st != VX_OK) {
    m->count = 0; // nothing was moved
    msg_free(m);
    return st;
  }
  *out = m;
  return VX_OK;
}

// Gives the caller a message: the body copied out, the handles installed. The
// caller has checked the user ranges. The message is freed either way.
static vx_status msg_to_user(channel_msg *m, uint64_t bytes, uint64_t handles) {
  vx_handle values[VX_CHANNEL_MAX_HANDLES];
  vx_status st = copy_to_user(bytes, msg_body(m), m->len);
  if (st == VX_OK) st = handles_put(current_task(), m->handles, m->count, values);
  if (st == VX_OK) st = copy_to_user(handles, values, m->count * sizeof(vx_handle));
  msg_free(m); // drops the message's references; installed handles hold their own
  return st;
}

static int64_t sys_channel_write(vx_handle h, uint64_t bytes, uint64_t len, uint64_t handles,
                                 uint64_t count) {
  vx_status st;
  channel *c = (channel *)handle_get(current_task(), h, OBJ_CHANNEL, VX_RIGHT_WRITE, &st);
  if (!c) return st;
  channel_msg *m;
  st = len > UINT32_MAX || count > UINT32_MAX
           ? VX_ERR_INVALID
           : msg_from_user(bytes, (uint32_t)len, handles, nullptr, (uint32_t)count, c, &m);
  if (st == VX_OK) {
    st = channel_write(c, m);
    if (st != VX_OK) msg_free(m);
  }
  object_release(&c->obj);
  return st;
}

static int64_t sys_channel_read(vx_handle h, uint64_t bytes, uint64_t cap, uint64_t handles,
                                uint64_t count_cap, uint64_t actual) {
  if (cap > VX_CHANNEL_MAX_BYTES || count_cap > VX_CHANNEL_MAX_HANDLES) return VX_ERR_INVALID;
  if (!user_range_ok(bytes, cap, true) || !user_range_ok(handles, count_cap * sizeof(vx_handle), true) ||
      !user_range_ok(actual, sizeof(vx_msg_size), true))
    return VX_ERR_INVALID;
  vx_status st;
  channel *c = (channel *)handle_get(current_task(), h, OBJ_CHANNEL, VX_RIGHT_READ, &st);
  if (!c) return st;
  channel_msg *m = nullptr;
  vx_msg_size need = {};
  st = channel_read(c, (uint32_t)cap, (uint32_t)count_cap, &m, &need);
  object_release(&c->obj);
  if (st == VX_OK || st == VX_ERR_TOO_SMALL) copy_to_user(actual, &need, sizeof need);
  if (st != VX_OK) return st;
  return msg_to_user(m, bytes, handles);
}

// A call's lent handles (ADR-0043): for each, a lease of the caller's VMO in
// its table, with that handle's rights but MANAGE (and TRANSFER, to go in
// the request), whose value takes the lent one's place in values; the
// leases are kept in leases, for the call's end to revoke; *made has a bit
// for each value replaced.
static vx_status lend_handles(vx_handle *values, uint32_t count, uint64_t lent, vmo **leases, uint32_t *n,
                              uint64_t *made) {
  task *me = current_task();
  vx_status st = VX_OK;
  for (uint32_t i = 0; i < count && st == VX_OK; i++) {
    if (!(lent >> i & 1)) continue;
    uint32_t rights = 0;
    vmo *v = (vmo *)handle_get_rights(me, values[i], OBJ_VMO, VX_RIGHT_READ, &rights, &st);
    if (!v) break;
    vmo *lease = nullptr;
    st = vmo_lease_create(v, &lease);
    object_release(&v->obj);
    if (st == VX_OK)
      st = handle_add(me, &lease->obj, (rights & ~VX_RIGHT_MANAGE) | VX_RIGHT_TRANSFER, &values[i]);
    if (lease && st == VX_OK) leases[(*n)++] = lease, *made |= 1ull << i; // kept until the call ends
    if (lease && st != VX_OK) object_release(&lease->obj);
  }
  return st;
}

// Each lease ended: its mappings lose their pages, every use is REVOKED.
static void revoke_leases(vmo **leases, uint32_t n) {
  for (uint32_t i = 0; i < n; i++) {
    if (!atomic_exchange(&leases[i]->revoked, true))
      vmo_unmap_everywhere(leases[i], 0, leases[i]->size / 4096);
    object_release(&leases[i]->obj);
  }
}

static int64_t sys_channel_call(vx_handle h, uint64_t args_ptr, vx_instant deadline) {
  vx_call args;
  vx_status st = copy_from_user(&args, args_ptr, sizeof args);
  if (st != VX_OK) return st;
  if (args.rd_cap > VX_CHANNEL_MAX_BYTES || args.rd_count_cap > VX_CHANNEL_MAX_HANDLES) return VX_ERR_INVALID;
  if (!user_range_ok((uint64_t)args.rd_bytes, args.rd_cap, true) ||
      !user_range_ok((uint64_t)args.rd_handles, args.rd_count_cap * sizeof(vx_handle), true))
    return VX_ERR_INVALID;
  if (args.wr_count > VX_CHANNEL_MAX_HANDLES || (args.wr_count < 64 && args.lent >> args.wr_count))
    return VX_ERR_INVALID; // a lent bit past the handles
  vx_handle values[VX_CHANNEL_MAX_HANDLES];
  vmo *leases[VX_CHANNEL_MAX_HANDLES];
  uint32_t nlease = 0;
  uint64_t made = 0;
  if ((st = copy_from_user(values, (uint64_t)args.wr_handles, args.wr_count * sizeof(vx_handle))) != VX_OK)
    return st;
  channel *c = (channel *)handle_get(current_task(), h, OBJ_CHANNEL, VX_RIGHT_READ | VX_RIGHT_WRITE, &st);
  if (!c) return st;
  channel_msg *request, *reply = nullptr;
  st = lend_handles(values, args.wr_count, args.lent, leases, &nlease, &made);
  if (st == VX_OK)
    st = msg_from_user((uint64_t)args.wr_bytes, args.wr_len, 0, values, args.wr_count, c, &request);
  if (st != VX_OK) // the leases put in the table were not sent: closed (the caller's own stay)
    for (uint32_t i = 0; i < args.wr_count; i++)
      if (made >> i & 1) handle_close(current_task(), values[i]);
  if (st == VX_OK) {
    bool sent;
    st = channel_call(c, request, deadline, &reply, &sent);
    if (!sent) msg_free(request); // once sent, it is the channel's
  }
  object_release(&c->obj);
  revoke_leases(leases, nlease); // however the call ended (ADR-0043)
  if (st != VX_OK) return st;
  args.actual = (vx_msg_size){reply->len, reply->count};
  copy_to_user(args_ptr + offsetof(vx_call, actual), &args.actual, sizeof args.actual);
  if (reply->len > args.rd_cap || reply->count > args.rd_count_cap) {
    msg_free(reply);
    return VX_ERR_TOO_SMALL;
  }
  return msg_to_user(reply, (uint64_t)args.rd_bytes, (uint64_t)args.rd_handles);
}

// --- Counters, bindings, futexes ---

// --- Scheduling contexts (ADR-0038) ---

static int64_t sys_sched_ctx_create(uint64_t params, uint64_t out) {
  vx_sched_params p;
  vx_status st = copy_from_user(&p, params, sizeof p);
  if (st != VX_OK) return st;
  sched_ctx *x;
  if ((st = sched_ctx_new(&p, &x)) != VX_OK) return st;
  return return_handle(
      &x->obj, VX_RIGHT_WRITE | VX_RIGHT_MANAGE | VX_RIGHT_INSPECT | VX_RIGHT_DUPLICATE | VX_RIGHT_TRANSFER,
      out);
}

static int64_t sys_sched_ctx_bind(vx_handle ctx, vx_handle th, uint64_t core) {
  vx_status st = VX_OK;
  sched_ctx *x = ctx == VX_HANDLE_NONE
                     ? nullptr
                     : (sched_ctx *)handle_get(current_task(), ctx, OBJ_SCHED_CTX, VX_RIGHT_WRITE, &st);
  if (ctx != VX_HANDLE_NONE && !x) return st;
  thread *t = th == VX_HANDLE_NONE
                  ? this_cpu()->current
                  : (thread *)handle_get(current_task(), th, OBJ_THREAD, VX_RIGHT_MANAGE, &st);
  if (!t) {
    if (x) object_release(&x->obj);
    return st;
  }
  st = sched_bind(t, x, (int32_t)(int64_t)core);
  if (th != VX_HANDLE_NONE) object_release(&t->obj);
  if (x) object_release(&x->obj);
  return st;
}

static int64_t sys_sched_ctx_configure(vx_handle ctx, uint64_t params) {
  vx_sched_params p;
  vx_status st = copy_from_user(&p, params, sizeof p);
  if (st != VX_OK) return st;
  if (ctx == VX_HANDLE_NONE) return sched_set_own(this_cpu()->current, &p);
  sched_ctx *x = (sched_ctx *)handle_get(current_task(), ctx, OBJ_SCHED_CTX, VX_RIGHT_MANAGE, &st);
  if (!x) return st;
  st = sched_ctx_set(x, &p);
  object_release(&x->obj);
  return st;
}

static int64_t sys_sched_reserve(vx_handle ctx, uint64_t count, uint64_t cls, uint64_t domain, uint64_t flags,
                                 uint64_t out) {
  if ((cls != VX_CORE_ANY && cls != VX_CORE_TIER(0)) || domain != VX_DOMAIN_ANY ||
      (flags & ~(uint64_t)(VX_RESERVE_NO_SMT_SIBLINGS | VX_RESERVE_SAME_LLC)) || count > MAX_CPUS)
    return cls >> 8 == 0x20 || (cls >> 8 == 1 && cls != VX_CORE_TIER(0)) ? VX_ERR_REFUSED : VX_ERR_INVALID;
  vx_status st;
  sched_ctx *x = (sched_ctx *)handle_get(current_task(), ctx, OBJ_SCHED_CTX, VX_RIGHT_MANAGE, &st);
  if (!x) return st;
  vx_core_set set;
  st = sched_reserve_cpus(x, (uint32_t)count, &set);
  object_release(&x->obj);
  vx_status copied = copy_to_user(out, &set, sizeof set);
  return st != VX_OK ? st : copied;
}

static int64_t sys_counter_create(uint64_t initial, uint64_t out) {
  counter *c;
  vx_status st = counter_create(initial, &c);
  if (st != VX_OK) return st;
  return return_handle(&c->obj,
                       VX_RIGHT_READ | VX_RIGHT_SIGNAL | VX_RIGHT_WAIT | VX_RIGHT_DUPLICATE |
                           VX_RIGHT_TRANSFER | VX_RIGHT_INSPECT,
                       out);
}

static int64_t sys_counter_signal(vx_handle h, uint64_t value) {
  vx_status st;
  counter *c = (counter *)handle_get(current_task(), h, OBJ_COUNTER, VX_RIGHT_SIGNAL, &st);
  if (!c) return st;
  counter_signal(c, value);
  object_release(&c->obj);
  return VX_OK;
}

// counter_read on a counter, or on a ring end, whose doorbell it reads.
static int64_t sys_counter_read(vx_handle h) {
  vx_status st;
  object *o = handle_get(current_task(), h, OBJ_COUNTER, VX_RIGHT_READ, &st);
  if (!o) o = handle_get(current_task(), h, OBJ_RING, VX_RIGHT_READ, &st);
  if (!o) return st;
  counter *c = o->type == OBJ_COUNTER ? (counter *)o : ((ring_end *)o)->doorbell;
  uint64_t v = counter_read(c);
  object_release(o);
  return v > INT64_MAX ? VX_ERR_RANGE : (int64_t)v;
}

// port_bind(port, source, trigger, key, threshold): a one-shot binding of a
// channel end, counter, task, ring end or Irq to the port.
static int64_t sys_port_bind(vx_handle ph, vx_handle sh, uint64_t trigger, uint64_t key, uint64_t threshold) {
  vx_status st;
  port *p = (port *)handle_get(current_task(), ph, OBJ_PORT, VX_RIGHT_WRITE, &st);
  if (!p) return st;
  object *src = nullptr;
  static const obj_type SOURCES[] = {OBJ_CHANNEL, OBJ_COUNTER, OBJ_TASK, OBJ_RING, OBJ_IRQ, OBJ_DMA_DOMAIN};
  for (uint32_t i = 0; i < sizeof SOURCES / sizeof SOURCES[0] && !src; i++)
    src = handle_get(current_task(), sh, SOURCES[i], VX_RIGHT_WAIT, &st);
  binding *b = src ? binding_new(p, (uint32_t)trigger, key, threshold, sh) : nullptr;
  if (src && !b) st = VX_ERR_NO_MEMORY;
  if (b) {
    if (src->type == OBJ_CHANNEL)
      st = channel_bind((channel *)src, b);
    else if (src->type == OBJ_COUNTER)
      st = counter_bind((counter *)src, b);
    else if (src->type == OBJ_RING)
      st = ring_bind((ring_end *)src, b);
    else if (src->type == OBJ_IRQ)
      st = irq_bind((irq *)src, b);
    else if (src->type == OBJ_DMA_DOMAIN)
      st = dma_bind((dma_domain *)src, b);
    else
      st = task_bind((task *)src, b);
    if (st != VX_OK) binding_free(b);
  }
  if (src) object_release(src);
  object_release(&p->obj);
  return st;
}

// --- Rings ---

static int64_t sys_ring_create(uint64_t params_ptr, uint64_t out) {
  vx_ring_params p;
  vx_status st = copy_from_user(&p, params_ptr, sizeof p);
  if (st != VX_OK) return st;
  if (!user_range_ok(out, sizeof(vx_ring_handles), true)) return VX_ERR_INVALID;
  ring_end *client, *server;
  vmo *memory;
  if ((st = ring_create(&p, &client, &server, &memory)) != VX_OK) return st;
  static constexpr uint32_t END_RIGHTS = VX_RIGHT_READ | VX_RIGHT_WRITE | VX_RIGHT_WAIT | VX_RIGHT_SIGNAL |
                                         VX_RIGHT_DUPLICATE | VX_RIGHT_TRANSFER | VX_RIGHT_INSPECT;
  static constexpr uint32_t MEMORY_RIGHTS = VX_RIGHT_READ | VX_RIGHT_WRITE | VX_RIGHT_MAP |
                                            VX_RIGHT_DUPLICATE | VX_RIGHT_TRANSFER | VX_RIGHT_INSPECT;
  vx_ring_handles h = {};
  task *t = current_task();
  st = handle_add(t, &client->obj, END_RIGHTS, &h.client);
  if (st == VX_OK) st = handle_add(t, &server->obj, END_RIGHTS, &h.server);
  if (st == VX_OK) st = handle_add(t, &memory->obj, MEMORY_RIGHTS, &h.memory);
  object_release(&client->obj);
  object_release(&server->obj);
  object_release(&memory->obj);
  if (st == VX_OK) st = copy_to_user(out, &h, sizeof h);
  if (st != VX_OK) {
    if (h.client) handle_close(t, h.client);
    if (h.server) handle_close(t, h.server);
    if (h.memory) handle_close(t, h.memory);
  }
  return st;
}

static int64_t sys_ring_notify(vx_handle h) {
  vx_status st;
  ring_end *e = (ring_end *)handle_get(current_task(), h, OBJ_RING, VX_RIGHT_SIGNAL, &st);
  if (!e) return st;
  st = ring_notify(e);
  object_release(&e->obj);
  return st;
}

// ring_xfer_handles(ring, PUT, handles, count, 0) -> slot;
// ring_xfer_handles(ring, TAKE, handles out, capacity, slot) -> count.
static int64_t sys_ring_xfer(vx_handle h, uint64_t op, uint64_t handles, uint64_t count, uint64_t slot) {
  if (op != VX_RING_PUT && op != VX_RING_TAKE) return VX_ERR_INVALID;
  if (count > VX_RING_SLOT_HANDLES || (op == VX_RING_PUT && count == 0)) return VX_ERR_INVALID;
  vx_handle values[VX_RING_SLOT_HANDLES];
  vx_status st = VX_OK;
  if (op == VX_RING_PUT)
    st = copy_from_user(values, handles, count * sizeof(vx_handle));
  else if (!user_range_ok(handles, count * sizeof(vx_handle), true))
    st = VX_ERR_INVALID;
  if (st != VX_OK) return st;
  ring_end *e = (ring_end *)handle_get(current_task(), h, OBJ_RING, VX_RIGHT_WRITE, &st);
  if (!e) return st;
  moved_handle moved[VX_RING_SLOT_HANDLES];
  int64_t result;
  if (op == VX_RING_PUT) {
    const object *peer = (const object *)e->pair->ends[1 - e->side]; // compared only
    result = handles_take(current_task(), values, (uint32_t)count, &e->obj, peer, moved);
    if (result == VX_OK) {
      result = ring_put(e, moved, (uint32_t)count);
      if (result < 0)
        for (uint32_t i = 0; i < count; i++) object_release(moved[i].obj); // gone, as with channel writes
    }
  } else {
    uint32_t n = 0;
    result = ring_take(e, (uint32_t)slot, moved, &n);
    if (result == VX_OK && n > count) result = VX_ERR_TOO_SMALL; // nothing installed; the handles are lost
    if (result == VX_OK) result = handles_put(current_task(), moved, n, values);
    if (result == VX_OK) result = copy_to_user(handles, values, n * sizeof(vx_handle));
    if (result == VX_OK) result = n;
    for (uint32_t i = 0; i < n; i++) object_release(moved[i].obj);
  }
  object_release(&e->obj);
  return result;
}

// --- Tasks and threads ---

static int64_t sys_task_create(uint64_t name_ptr, uint64_t name_len, uint64_t out, uint64_t options) {
  char name[24] = {};
  if (name_len >= sizeof name) return VX_ERR_RANGE;
  if (options & ~(uint64_t)VX_TASK_FORK) return VX_ERR_INVALID;
  vx_status st = copy_from_user(name, name_ptr, name_len);
  if (st != VX_OK) return st;
  task *t;
  st = task_create(name, current_task()->id, &t);
  if (st != VX_OK) return st;
  t->may_debug_write = current_task()->may_debug_write;
  if (options & VX_TASK_FORK) st = task_fork_copy(current_task(), t);
  if (st != VX_OK) {
    task_kill(t, "sys: no memory", 14); // never started: torn down with its last reference
    object_release(&t->obj);
    return st;
  }
  return return_handle(&t->obj, ALL_RIGHTS, out);
}

// thread_create(task, &out, &id): a thread, and (unless id is null) its id in
// the task, which exceptions and thread_interrupt name it by.
static int64_t sys_thread_create(vx_handle th, uint64_t out, uint64_t id_out) {
  vx_status st;
  task *t = (task *)handle_get(current_task(), th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
  if (!t) return st;
  thread *thr;
  spin_lock(&t->lock);
  bool ending = t->ending || t->killed;
  spin_unlock(&t->lock);
  st = ending ? VX_ERR_BAD_STATE : thread_create(t, &thr);
  // A thread made by one of its own task takes its creator's protection-key
  // rights; another task's first, key 0 alone (arch_fp_init) (ADR-0035).
  if (st == VX_OK && t == current_task()) arch_fp_set_rights(thr->fp, arch_rights_read());
  object_release(&t->obj);
  if (st != VX_OK) return st;
  uint32_t id = thr->id;
  st = (vx_status)return_handle(&thr->obj, ALL_RIGHTS, out);
  if (st == VX_OK && id_out) st = copy_to_user(id_out, &id, sizeof id);
  return st;
}

// thread_start(thread, entry, sp, handle, arg2): the handle, unless 0, moves
// from the caller to the thread's task, and the thread gets its value there as
// its first argument.
static int64_t sys_thread_start(vx_handle h, uint64_t entry, uint64_t sp, vx_handle arg, uint64_t arg2) {
  vx_status st;
  thread *th = (thread *)handle_get(current_task(), h, OBJ_THREAD, VX_RIGHT_MANAGE, &st);
  if (!th) return st;
  vx_handle moved = 0;
  if (arg) {
    moved_handle m;
    st = handles_take(current_task(), &arg, 1, nullptr, nullptr, &m);
    if (st == VX_OK) {
      st = handles_put(th->task, &m, 1, &moved);
      object_release(m.obj);
    }
  }
  if (st == VX_OK) {
    st = thread_start(th, entry, sp, moved, arg2);
    if (st != VX_OK && moved) handle_close(th->task, moved);
  }
  object_release(&th->obj);
  return st;
}

// task_kill(task, msg, len, id): ends it with msg as its exit string.
static int64_t sys_task_kill(vx_handle h, uint64_t msg_ptr, uint64_t len, uint64_t id) {
  if (len > VX_ERRMAX) return VX_ERR_RANGE;
  char msg[VX_ERRMAX];
  vx_status st = copy_from_user(msg, msg_ptr, len);
  if (st != VX_OK) return st;
  task *t = task_target(h, VX_RIGHT_MANAGE, id, false, &st);
  if (!t) return st;
  task_kill(t, msg, len);
  object_release(&t->obj);
  return VX_OK;
}

// task_exec(scratch, bootstrap, entry, sp) (ADR-0012): the caller takes the
// address space of scratch, a task it built and never started, and goes on as
// the program in it, keeping its id, parent and EXIT bindings. Its handles are
// all closed but bootstrap, which a new thread gets as its first argument at
// entry, on sp; the calling thread ends. scratch, left with the old address
// space, ends with it. Only a task with one live thread may call it.
static int64_t sys_task_exec(vx_handle sh, vx_handle bootstrap, uint64_t entry, uint64_t sp) {
  if (entry >= USER_TOP || sp > USER_TOP) return VX_ERR_INVALID;
  task *t = current_task();
  vx_status st;
  task *s = (task *)handle_get(t, sh, OBJ_TASK, VX_RIGHT_MANAGE, &st);
  if (!s) return st;
  thread *th = nullptr;
  st = s == t ? VX_ERR_INVALID : thread_create(t, &th); // made first: a failure changes nothing
  if (st == VX_OK) {
    // Both are held so until the swap: a thread started meanwhile, in either,
    // would run on tables about to change hands, and then be freed.
    task *first = t < s ? t : s, *second = t < s ? s : t;
    spin_lock(&first->lock);
    spin_lock(&second->lock);
    bool alone = t->live_threads == 1 && !t->ending && !t->killed && !t->execing;
    bool fresh =
        s->state == VX_TASK_NEW && s->live_threads == 0 && !s->ending && !s->killed && s->root && !s->execing;
    if (alone && fresh) t->execing = s->execing = true;
    spin_unlock(&second->lock);
    spin_unlock(&first->lock);
    if (!alone || !fresh) st = VX_ERR_BAD_STATE;
  }
  moved_handle m = {};
  if (st == VX_OK) {
    st = handles_take(t, &bootstrap, 1, &t->obj, &s->obj, &m);
    if (st != VX_OK) {
      spin_lock(&t->lock);
      t->execing = false;
      spin_unlock(&t->lock);
      spin_lock(&s->lock);
      s->execing = false;
      spin_unlock(&s->lock);
    }
  }
  if (st != VX_OK) {
    if (th) object_release(&th->obj);
    object_release(&s->obj);
    return st;
  }

  // The old program's robust locks are let go while its memory is still the
  // caller's (ADR-0037), and its list goes with it.
  futex_robust_walk(this_cpu()->current);

  // The address spaces change places, and the caller takes the new program's
  // name. Both locks, in a fixed order: nothing else maps into either meanwhile.
  task *first = t < s ? t : s, *second = t < s ? s : t;
  spin_lock(&first->lock);
  spin_lock(&second->lock);
  uint64_t root = t->root, map_next = t->map_next, mapped = t->mapped;
  mapping *maps = t->maps;
  t->root = s->root, t->map_next = s->map_next, t->mapped = s->mapped, t->maps = s->maps;
  s->root = root, s->map_next = map_next, s->mapped = mapped, s->maps = maps;
  reservation resv[TASK_MAX_RESERVATIONS]; // they go with the address space too (ADR-0042)
  memcpy(resv, t->resv, sizeof resv);
  memcpy(t->resv, s->resv, sizeof resv);
  memcpy(s->resv, resv, sizeof resv);
  memcpy(t->name, s->name, sizeof t->name);
  t->exc_handler = 0; // the old program's in-task handler is not in the new one
  spin_unlock(&second->lock);
  spin_unlock(&first->lock);
  // This CPU leaves the old tables now, before they go with s. No other CPU
  // has them loaded: the caller has no other thread, and without ASIDs,
  // loading tables drops every cached translation (ADR-0012).
  cpu *c = this_cpu();
  atomic_store_explicit(&c->user_root, t->root, memory_order_relaxed);
  arch_switch_user_root(t->root);
  atomic_fetch_add_explicit(&c->root_loads, 1, memory_order_release);

  // Every handle the old program held is closed: the new one starts with only
  // what its spawn message names (01 §3).
  for (uint32_t i = 1; i < HANDLE_SLOTS; i++) {
    spin_lock(&t->lock);
    handle_entry *e = &t->handles[i];
    object *obj = e->obj;
    if (obj) {
      e->obj = nullptr;
      if (++e->generation == 0) e->generation = 1;
    }
    spin_unlock(&t->lock);
    if (obj) object_release(obj);
  }
  vx_handle moved = VX_HANDLE_NONE;
  st = handles_put(t, &m, 1, &moved);
  object_release(m.obj);
  spin_lock(&t->lock);
  t->execing = false; // the new program's first thread may start now
  spin_unlock(&t->lock);
  task_kill(s, "", 0); // never started: torn down at once, with the old address space
  object_release(&s->obj);
  if (st == VX_OK) st = thread_start(th, entry, sp, moved, 0);
  object_release(&th->obj); // a started thread holds its own reference
  if (st != VX_OK) task_exit_with("exec failed", 11);
  thread_exit_current(); // the new program goes on in the new thread
}

// --- Memory and handles ---

// Why vmo_rw found no page: a pager's not supplied yet; a lazy one's write
// with no memory for it; past the end of one shrunk meanwhile.
static vx_status vmo_rw_absent(const vmo *v, bool inside) {
  if (v->pager) return VX_ERR_SHOULD_WAIT;
  return inside && v->lazy ? VX_ERR_NO_MEMORY : VX_ERR_RANGE;
}

// vmo_rw(vmo, op, offset, buffer, size): copies between a VMO and the caller's memory.
static int64_t sys_vmo_rw(vx_handle h, uint64_t op, uint64_t offset, uint64_t buf, uint64_t size) {
  if (op != VX_VMO_READ && op != VX_VMO_WRITE) return VX_ERR_INVALID;
  if (!user_range_ok(buf, size, op == VX_VMO_READ)) return VX_ERR_INVALID;
  vx_status st;
  vmo *v =
      (vmo *)handle_get(current_task(), h, OBJ_VMO, op == VX_VMO_READ ? VX_RIGHT_READ : VX_RIGHT_WRITE, &st);
  if (!v) return st;
  uint64_t end;
  if (v->physical)
    st = VX_ERR_UNSUPPORTED; // device memory is not in the direct map: map it instead
  else if (ckd_add(&end, offset, size) || end > v->size)
    st = VX_ERR_RANGE;
  for (uint64_t done = 0; st == VX_OK && done < size;) {
    if (vmo_revoked(v)) st = VX_ERR_REVOKED; // page by page: a revoke stops a long copy (ADR-0043)
    if (op == VX_VMO_WRITE && vmo_sealed(v)) st = VX_ERR_ACCESS;
    if (st != VX_OK) break;
    uint64_t at = offset + done, in_page = at & 4095, n = 4096 - in_page;
    if (n > size - done) n = size - done;
    if (vmo_locked(v)) { // its pages can go (EVICT, a shrink): each touched under its lock, through a bounce
      uint8_t bounce[256];
      if (n > sizeof bounce) n = sizeof bounce;
      if (op == VX_VMO_WRITE && (st = copy_from_user(bounce, buf + done, n)) != VX_OK) break;
      spin_lock(&v->lock);
      bool inside = at / 4096 < v->size / 4096;
      uint64_t pa = 0;
      if (inside) pa = op == VX_VMO_WRITE ? vmo_page_make(v, at / 4096) : vmo_page(v, at / 4096);
      bool hole = inside && !pa && v->lazy && op == VX_VMO_READ; // absent: reads as zeros (ADR-0046)
      if (hole) memset(bounce, 0, n);
      if (pa && op == VX_VMO_READ) memcpy(bounce, (uint8_t *)phys_to_virt(pa) + in_page, n);
      if (pa && op == VX_VMO_WRITE) {
        memcpy((uint8_t *)phys_to_virt(pa) + in_page, bounce, n);
        if (v->pager)
          v->pages[at / 4096] |= PAGE_DIRTY; // written, as a store through a mapping would mark it
      }
      spin_unlock(&v->lock);
      if (!pa && !hole) st = vmo_rw_absent(v, inside);
      if ((pa || hole) && op == VX_VMO_READ) st = copy_to_user(buf + done, bounce, n);
      done += n;
      continue;
    }
    uint8_t *page = (uint8_t *)phys_to_virt(vmo_page(v, at / 4096)) + in_page;
    st = op == VX_VMO_READ ? copy_to_user(buf + done, page, n) : copy_from_user(page, buf + done, n);
    done += n;
  }
  object_release(&v->obj);
  return st;
}

static int64_t sys_handle_dup(vx_handle h, uint64_t rights, uint64_t out) {
  task *t = current_task();
  spin_lock(&t->lock);
  uint32_t index = h & 0xffff;
  handle_entry *e = index && index < HANDLE_SLOTS ? &t->handles[index] : nullptr;
  vx_status st = VX_OK;
  object *obj = nullptr;
  if (!e || !e->obj || e->generation != h >> 16)
    st = VX_ERR_BAD_HANDLE;
  else if (!(e->rights & VX_RIGHT_DUPLICATE) || (rights != VX_RIGHTS_SAME && (rights & ~(uint64_t)e->rights)))
    st = VX_ERR_ACCESS; // needs DUPLICATE, and can only reduce rights (01 §3)
  else
    obj = e->obj;
  if (obj && rights == VX_RIGHTS_SAME) rights = e->rights;
  if (obj) object_ref(obj);
  spin_unlock(&t->lock);
  if (!obj) return st;
  return return_handle(obj, (uint32_t)rights, out);
}

// obj/exception.c, after this file
static int64_t sys_exception_bind(vx_handle th, vx_handle ph, uint64_t key, uint64_t options);
static int64_t sys_exception_resume(vx_handle th, uint64_t id, uint64_t action, uint64_t regs_ptr);
static int64_t sys_thread_state(vx_handle th, uint64_t id, uint64_t op, uint64_t buf, uint64_t size);
static int64_t sys_thread_interrupt(vx_handle th, uint64_t id, uint64_t note_ptr, uint64_t len);
static int64_t sys_vmo_clone(vx_handle h, uint64_t offset, uint64_t size, uint64_t options, uint64_t out);
static int64_t sys_thread_suspend(vx_handle th, uint64_t id);
static int64_t sys_thread_resume(vx_handle th, uint64_t id);
static int64_t sys_task_mem_rw(vx_handle th, uint64_t ops_ptr, uint64_t count);

static int64_t syscall_dispatch(uint64_t nr, const uint64_t a[6]) {
  switch (nr) {
  case VX_SYS_debug_write: return sys_debug_write(a[0], a[1]);
  case VX_SYS_clock_read: return a[0] ? sys_clock_info(a[0]) : clock_now();
  case VX_SYS_task_create: return sys_task_create(a[0], a[1], a[2], a[3]);
  case VX_SYS_task_kill: return sys_task_kill((vx_handle)a[0], a[1], a[2], a[3]);
  case VX_SYS_task_exec: return sys_task_exec((vx_handle)a[0], (vx_handle)a[1], a[2], a[3]);
  case VX_SYS_task_info: return sys_task_info((vx_handle)a[0], a[1], a[2], a[3]);
  case VX_SYS_thread_create: return sys_thread_create((vx_handle)a[0], a[1], a[2]);
  case VX_SYS_thread_start: return sys_thread_start((vx_handle)a[0], a[1], a[2], (vx_handle)a[3], a[4]);
  case VX_SYS_thread_exit: thread_exit_current();
  case VX_SYS_port_create: return sys_port_create(a[0], a[1]);
  case VX_SYS_port_bind: return sys_port_bind((vx_handle)a[0], (vx_handle)a[1], a[2], a[3], a[4]);
  case VX_SYS_port_wait:
    return sys_port_wait((vx_handle)a[0], (vx_instant)a[1], (vx_duration)a[2], a[3], a[4]);
  case VX_SYS_port_post: return sys_port_post((vx_handle)a[0], a[1]);
  case VX_SYS_sched_ctx_create: return sys_sched_ctx_create(a[0], a[1]);
  case VX_SYS_sched_ctx_bind: return sys_sched_ctx_bind((vx_handle)a[0], (vx_handle)a[1], a[2]);
  case VX_SYS_sched_ctx_configure: return sys_sched_ctx_configure((vx_handle)a[0], a[1]);
  case VX_SYS_sched_reserve: return sys_sched_reserve((vx_handle)a[0], a[1], a[2], a[3], a[4], a[5]);
  case VX_SYS_counter_create: return sys_counter_create(a[0], a[1]);
  case VX_SYS_counter_signal: return sys_counter_signal((vx_handle)a[0], a[1]);
  case VX_SYS_counter_read: return sys_counter_read((vx_handle)a[0]);
  case VX_SYS_futex_wait: return futex_wait(a[0], (uint32_t)a[1], (vx_instant)a[2]);
  case VX_SYS_futex_wake: return futex_wake(a[0], (uint32_t)a[1]);
  case VX_SYS_channel_create: return sys_channel_create(a[0], a[1]);
  case VX_SYS_channel_write: return sys_channel_write((vx_handle)a[0], a[1], a[2], a[3], a[4]);
  case VX_SYS_channel_read: return sys_channel_read((vx_handle)a[0], a[1], a[2], a[3], a[4], a[5]);
  case VX_SYS_channel_call: return sys_channel_call((vx_handle)a[0], a[1], (vx_instant)a[2]);
  case VX_SYS_ring_create: return sys_ring_create(a[0], a[1]);
  case VX_SYS_ring_notify: return sys_ring_notify((vx_handle)a[0]);
  case VX_SYS_ring_xfer_handles: return sys_ring_xfer((vx_handle)a[0], a[1], a[2], a[3], a[4]);
  case VX_SYS_vmo_create: return sys_vmo_create(a[0], a[1], a[2], (vx_handle)a[3], a[4]);
  case VX_SYS_irq_create: return sys_irq_create((vx_handle)a[0], a[1], a[2], a[3], a[4]);
  case VX_SYS_irq_ack: return sys_irq_ack((vx_handle)a[0]);
  case VX_SYS_dma_domain_create: return sys_dma_domain_create((vx_handle)a[0], a[1], a[2], a[3]);
  case VX_SYS_dma_map: return sys_dma_map((vx_handle)a[0], (vx_handle)a[1], a[2], a[3], a[4], a[5]);
  case VX_SYS_dma_unmap: return sys_dma_unmap((vx_handle)a[0]);
  case VX_SYS_dma_domain_op: return sys_dma_domain_op((vx_handle)a[0], a[1], a[2]);
  case VX_SYS_system_power: return sys_system_power((vx_handle)a[0], a[1]);
  case VX_SYS_clock_set: return sys_clock_set((vx_handle)a[0], a[1]);
  case VX_SYS_pager_create: return sys_pager_create((vx_handle)a[0], (vx_handle)a[1], a[2], a[3], a[4]);
  case VX_SYS_pager_supply:
    return sys_pager_supply((vx_handle)a[0], (vx_handle)a[1], a[2], a[3], (vx_handle)a[4], a[5]);
  case VX_SYS_pager_op: return sys_pager_op((vx_handle)a[0], (vx_handle)a[1], a[2], a[3], a[4], a[5]);
  case VX_SYS_vmo_op: return sys_vmo_op((vx_handle)a[0], a[1], a[2], a[3]);
  case VX_SYS_iorange_create: return sys_iorange_create((vx_handle)a[0], a[1], a[2], a[3]);
  case VX_SYS_vmo_rw: return sys_vmo_rw((vx_handle)a[0], a[1], a[2], a[3], a[4]);
  case VX_SYS_vmo_seal: return sys_vmo_seal((vx_handle)a[0]);
  case VX_SYS_vmo_lease: return sys_vmo_lease((vx_handle)a[0], a[1]);
  case VX_SYS_vmo_revoke: return sys_vmo_revoke((vx_handle)a[0]);
  case VX_SYS_as_reserve: return sys_as_reserve((vx_handle)a[0], a[1], a[2], a[3], a[4]);
  case VX_SYS_as_map: return sys_as_map((vx_handle)a[0], (vx_handle)a[1], a[2], a[3], a[4], a[5]);
  case VX_SYS_as_unmap: return sys_as_unmap((vx_handle)a[0], a[1], a[2]);
  case VX_SYS_as_protect: return sys_as_protect((vx_handle)a[0], a[1], a[2], a[3]);
  case VX_SYS_as_key_alloc: return sys_as_key_alloc((vx_handle)a[0], a[1]);
  case VX_SYS_as_key_free: return sys_as_key_free((vx_handle)a[0], a[1]);
  case VX_SYS_thread_set_robust: return sys_thread_set_robust(a[0], a[1], a[2]);
  case VX_SYS_as_query: return sys_as_query((vx_handle)a[0], a[1], a[2]);
  case VX_SYS_exception_bind: return sys_exception_bind((vx_handle)a[0], (vx_handle)a[1], a[2], a[3]);
  case VX_SYS_exception_resume: return sys_exception_resume((vx_handle)a[0], a[1], a[2], a[3]);
  case VX_SYS_thread_state: return sys_thread_state((vx_handle)a[0], a[1], a[2], a[3], a[4]);
  case VX_SYS_thread_interrupt: return sys_thread_interrupt((vx_handle)a[0], a[1], a[2], a[3]);
  case VX_SYS_vmo_clone: return sys_vmo_clone((vx_handle)a[0], a[1], a[2], a[3], a[4]);
  case VX_SYS_thread_suspend: return sys_thread_suspend((vx_handle)a[0], a[1]);
  case VX_SYS_thread_resume: return sys_thread_resume((vx_handle)a[0], a[1]);
  case VX_SYS_task_mem_rw: return sys_task_mem_rw((vx_handle)a[0], a[1], a[2]);
  case VX_SYS_handle_dup: return sys_handle_dup((vx_handle)a[0], a[1], a[2]);
  case VX_SYS_handle_close: return handle_close(current_task(), (vx_handle)a[0]);
  default: return VX_ERR_UNSUPPORTED;
  }
}
