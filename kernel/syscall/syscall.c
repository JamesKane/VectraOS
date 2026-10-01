// syscall.c: the syscalls M1 implements, and user memory access (docs/01 §3).
//
// Every syscall returns an int64: a count or value when >= 0, a vx_status when
// < 0. The rest of the 61 in abi/vx/syscalls.def return VX_ERR_UNSUPPORTED
// until the milestone that needs them. The argument conventions here are a
// draft until ADR-0004 freezes vx-abi v0.

// User pointers are checked against the current task's page tables before the
// kernel touches them. Mappings are only ever added in M1 and the kernel runs
// with interrupts off on one CPU, so nothing can unmap them in between. (With
// SMAP and PAN switched on, the copies will also open and close user access.)
static bool user_range_ok(uint64_t addr, uint64_t len, bool write) {
  uint64_t end;
  if (len == 0) return true;
  if (ckd_add(&end, addr, len) || end > USER_TOP) return false;
  for (uint64_t page = addr & ~4095ull; page < end; page += 4096)
    if (!user_page_ok(sched.current->task->root, page, write)) return false;
  return true;
}

static vx_status copy_from_user(void *dst, uint64_t src, uint64_t len) {
  if (!user_range_ok(src, len, false)) return VX_ERR_INVALID;
  memcpy(dst, (const void *)src, len);
  return VX_OK;
}

static vx_status copy_to_user(uint64_t dst, const void *src, uint64_t len) {
  if (!user_range_ok(dst, len, true)) return VX_ERR_INVALID;
  memcpy((void *)dst, src, len);
  return VX_OK;
}

static constexpr uint32_t ALL_RIGHTS = (1u << VX_RIGHT_BIT_COUNT) - 1;

static void object_release(object *obj) {
  if (--obj->refs) return;
  switch (obj->type) {
  case OBJ_VMO: vmo_destroy((vmo *)obj); break;
  case OBJ_PORT: pool_free(&port_pool, obj); break;
  default: break; // tasks and threads never end in M1
  }
}

// Gives the current task a handle to a new object, dropping the creator's reference.
static int64_t return_handle(object *obj, uint32_t rights, uint64_t out) {
  vx_handle h;
  vx_status st = handle_add(sched.current->task->handles, obj, rights, &h);
  object_release(obj);
  if (st != VX_OK) return st;
  st = copy_to_user(out, &h, sizeof h);
  if (st != VX_OK) handle_close(sched.current->task->handles, h);
  return st;
}

static int64_t sys_debug_write(uint64_t ptr, uint64_t len) {
  if (!sched.current->task->may_debug_write) return VX_ERR_ACCESS;
  char buf[256];
  while (len) {
    uint64_t n = len < sizeof buf ? len : sizeof buf;
    vx_status st = copy_from_user(buf, ptr, n);
    if (st != VX_OK) return st;
    kput((vx_str){buf, n});
    ptr += n;
    len -= n;
  }
  return VX_OK;
}

static int64_t sys_task_info(vx_handle h, uint64_t out) {
  vx_status st;
  task *t = (task *)handle_get(sched.current->task->handles, h, OBJ_TASK, VX_RIGHT_INSPECT, &st);
  if (!t) return st;
  vx_task_summary info = {.id = t->id};
  memcpy(info.name, t->name, sizeof info.name);
  return copy_to_user(out, &info, sizeof info);
}

static int64_t sys_port_create(uint64_t options, uint64_t out) {
  if (options) return VX_ERR_INVALID;
  port *p;
  vx_status st = port_create(&p);
  if (st != VX_OK) return st;
  return return_handle(&p->obj, ALL_RIGHTS & ~(uint32_t)(VX_RIGHT_EXEC | VX_RIGHT_MAP | VX_RIGHT_DEBUG), out);
}

static int64_t sys_port_wait(vx_handle h, vx_instant deadline, vx_duration leeway, uint64_t out,
                             uint64_t max) {
  vx_status st;
  port *p = (port *)handle_get(sched.current->task->handles, h, OBJ_PORT, VX_RIGHT_WAIT, &st);
  if (!p) return st;
  if (max == 0 || max > PORT_CAPACITY || leeway < 0) return VX_ERR_INVALID;
  if (!user_range_ok(out, max * sizeof(vx_packet), true)) return VX_ERR_INVALID;

  p->obj.refs++; // the port outlives this wait even if another thread closes the handle
  int64_t result;
  for (;;) {
    if (p->count) {
      vx_packet got[PORT_CAPACITY];
      uint32_t n = port_take(p, got, (uint32_t)max);
      result = copy_to_user(out, got, n * sizeof(vx_packet));
      if (result == VX_OK) result = n;
      break;
    }
    if (clock_now() >= deadline) {
      result = VX_ERR_TIMED_OUT;
      break;
    }
    thread *t = sched.current;
    t->port = p;
    t->next = nullptr;
    thread **link = &p->waiters;
    while (*link) link = &(*link)->next;
    *link = t;
    if (thread_block(deadline, leeway) == VX_ERR_TIMED_OUT) {
      result = VX_ERR_TIMED_OUT;
      break;
    }
  }
  object_release(&p->obj);
  return result;
}

static int64_t sys_port_post(vx_handle h, uint64_t packet) {
  vx_status st;
  port *p = (port *)handle_get(sched.current->task->handles, h, OBJ_PORT, VX_RIGHT_SIGNAL, &st);
  if (!p) return st;
  vx_packet pk;
  st = copy_from_user(&pk, packet, sizeof pk);
  if (st != VX_OK) return st;
  pk.timestamp = clock_now();
  pk.source = 0;
  pk.trigger = VX_TRIGGER_USER;
  return port_post(p, &pk);
}

static int64_t sys_vmo_create(uint64_t size, uint64_t options, uint64_t out) {
  if (options) return VX_ERR_INVALID;
  vmo *v;
  vx_status st = vmo_create(size, &v);
  if (st != VX_OK) return st;
  return return_handle(&v->obj, ALL_RIGHTS & ~(uint32_t)(VX_RIGHT_EXEC | VX_RIGHT_DEBUG), out);
}

// as_map(task, vmo, flags, &address): maps the whole VMO. The full call, with
// offsets into the VMO and reservations (01 §5), lands with as_reserve.
static int64_t sys_as_map(vx_handle th, vx_handle vh, uint64_t flags, uint64_t addr_ptr) {
  vx_status st;
  task *t = (task *)handle_get(sched.current->task->handles, th, OBJ_TASK, VX_RIGHT_MANAGE, &st);
  if (!t) return st;
  uint32_t need = VX_RIGHT_MAP | VX_RIGHT_READ | (flags & VX_MAP_WRITE ? VX_RIGHT_WRITE : 0) |
                  (flags & VX_MAP_EXEC ? VX_RIGHT_EXEC : 0);
  vmo *v = (vmo *)handle_get(sched.current->task->handles, vh, OBJ_VMO, need, &st);
  if (!v) return st;
  if (flags & ~(uint64_t)(VX_MAP_WRITE | VX_MAP_EXEC)) return VX_ERR_INVALID;
  uint64_t va;
  if ((st = copy_from_user(&va, addr_ptr, sizeof va)) != VX_OK) return st;
  if ((st = task_map(t, v, (uint32_t)flags, &va)) != VX_OK) return st;
  return copy_to_user(addr_ptr, &va, sizeof va);
}

static int64_t syscall_dispatch(uint64_t nr, const uint64_t a[6]) {
  switch (nr) {
  case VX_SYS_debug_write: return sys_debug_write(a[0], a[1]);
  case VX_SYS_clock_read: return clock_now();
  case VX_SYS_task_info: return sys_task_info((vx_handle)a[0], a[1]);
  case VX_SYS_port_create: return sys_port_create(a[0], a[1]);
  case VX_SYS_port_wait:
    return sys_port_wait((vx_handle)a[0], (vx_instant)a[1], (vx_duration)a[2], a[3], a[4]);
  case VX_SYS_port_post: return sys_port_post((vx_handle)a[0], a[1]);
  case VX_SYS_vmo_create: return sys_vmo_create(a[0], a[1], a[2]);
  case VX_SYS_as_map: return sys_as_map((vx_handle)a[0], (vx_handle)a[1], a[2], a[3]);
  case VX_SYS_handle_close: return handle_close(sched.current->task->handles, (vx_handle)a[0]);
  default: return VX_ERR_UNSUPPORTED;
  }
}
