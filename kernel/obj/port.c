// port.c: ports, the one wait (docs/01 §4.4).
//
// A port queues packets. port_wait returns up to a buffer's worth, or blocks
// until one arrives or the deadline passes. In M1 the only source is port_post;
// bindings to channels, rings, IRQs and counters come in M2, each with one
// packet of its own that later signals coalesce into. Until then a port holds
// at most PORT_CAPACITY posted packets, and a post to a full port fails with
// SHOULD_WAIT instead of being charged to the poster's budget.
//
// Locks are taken port first, scheduler second. A waiter whose deadline passes
// is woken by the timer, which holds only the scheduler's lock, so it takes
// itself off the port's list afterwards (port_remove_waiter).

static constexpr uint32_t PORT_CAPACITY = 64;

typedef struct port {
  object obj;
  spinlock lock;
  uint32_t head, count;
  thread *waiters; // first come, first served; may hold waiters that timed out
  vx_packet queue[PORT_CAPACITY];
} port;

static pool port_pool = POOL_FOR(port);

static vx_status port_create(port **out) {
  port *p = pool_alloc(&port_pool);
  if (!p) return VX_ERR_NO_MEMORY;
  p->obj.type = OBJ_PORT;
  atomic_store_explicit(&p->obj.refs, 1, memory_order_relaxed);
  *out = p;
  return VX_OK;
}

// Queues a packet and wakes the first waiter still waiting.
static vx_status port_post(port *p, const vx_packet *packet) {
  spin_lock(&p->lock);
  if (p->count == PORT_CAPACITY) {
    spin_unlock(&p->lock);
    return VX_ERR_SHOULD_WAIT;
  }
  p->queue[(p->head + p->count++) % PORT_CAPACITY] = *packet;
  while (p->waiters) {
    thread *t = p->waiters;
    p->waiters = t->next;
    if (thread_wake_from_port(t, p)) break;
  }
  spin_unlock(&p->lock);
  return VX_OK;
}

// Takes up to max packets into out. Returns how many.
static uint32_t port_take(port *p, vx_packet *out, uint32_t max) {
  spin_lock(&p->lock);
  uint32_t n = p->count < max ? p->count : max;
  for (uint32_t i = 0; i < n; i++) out[i] = p->queue[(p->head + i) % PORT_CAPACITY];
  p->head = (p->head + n) % PORT_CAPACITY;
  p->count -= n;
  spin_unlock(&p->lock);
  return n;
}

// Joins the port's waiters, unless a packet is already queued. Returns whether
// it joined; the caller then blocks.
static bool port_join_waiters(port *p, thread *t) {
  spin_lock(&p->lock);
  bool join = p->count == 0;
  if (join) {
    t->port = p; // set before t is on the list; wakers only find it there, under this lock
    t->next = nullptr;
    thread **link = &p->waiters;
    while (*link) link = &(*link)->next;
    *link = t;
  }
  spin_unlock(&p->lock);
  return join;
}

static void port_remove_waiter(port *p, thread *t) {
  spin_lock(&p->lock);
  for (thread **link = &p->waiters; *link; link = &(*link)->next) {
    if (*link == t) {
      *link = t->next;
      break;
    }
  }
  spin_unlock(&p->lock);
}
