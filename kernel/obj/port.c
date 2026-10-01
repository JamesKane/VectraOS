// port.c: ports, the one wait, and the bindings that feed them (docs/01 §4.4).
//
// A port delivers packets from two places: bindings and posts. port_bind
// attaches a one-shot binding to a source, such as a channel end, a counter or
// a task. When the source's condition holds, at once if it already does, the
// binding moves to the port's ready list; port_wait returns it as a packet and
// the binding is gone. Each binding is the packet it delivers, allocated when it
// is bound, so bindings can never overflow a port. Posts (port_post) queue in a
// fixed ring of PORT_CAPACITY; a post to a full ring fails with SHOULD_WAIT
// (charging posts to the poster's budget comes with budgets).
//
// Locks are taken source first, then port, then scheduler. A waiter whose
// deadline passes is woken by the timer, which holds only the scheduler's lock,
// so it takes itself off the port's list afterwards (port_remove_waiter).

static constexpr uint32_t PORT_CAPACITY = 64;

struct binding;

typedef struct port {
  object obj;
  spinlock lock;
  uint32_t head, count;                    // posted packets in queue
  struct binding *ready_head, *ready_tail; // fired bindings, oldest first
  thread *waiters;                         // first come, first served; may hold waiters that timed out
  vx_packet queue[PORT_CAPACITY];
} port;

typedef struct binding {
  struct binding *next; // on its source's list, then on its port's ready list
  port *port;           // holds a reference until it fires; then the port holds it
  bool fired;
  uint64_t key;
  uint64_t threshold; // COUNTER_GE
  uint32_t trigger;
  uint32_t source_handle;
  vx_packet packet; // filled when it fires
} binding;

static pool port_pool = POOL_FOR(port);
static pool binding_pool = POOL_FOR(binding);

static vx_status port_create(port **out) {
  port *p = pool_alloc(&port_pool);
  if (!p) return VX_ERR_NO_MEMORY;
  p->obj.type = OBJ_PORT;
  atomic_store_explicit(&p->obj.refs, 1, memory_order_relaxed);
  *out = p;
  return VX_OK;
}

// Wakes the first waiter still waiting. Called with the port's lock held.
static void port_wake_one(port *p) {
  while (p->waiters) {
    thread *t = p->waiters;
    p->waiters = t->wait_next;
    if (thread_wake_token(t, p, VX_OK)) break;
  }
}

// Queues a packet and wakes the first waiter still waiting.
static vx_status port_post(port *p, const vx_packet *packet) {
  spin_lock(&p->lock);
  if (p->count == PORT_CAPACITY) {
    spin_unlock(&p->lock);
    return VX_ERR_SHOULD_WAIT;
  }
  p->queue[(p->head + p->count++) % PORT_CAPACITY] = *packet;
  port_wake_one(p);
  spin_unlock(&p->lock);
  return VX_OK;
}

static void binding_free(binding *b) {
  if (!b->fired) object_drop(&b->port->obj); // a fired one gave its reference up
  pool_free(&binding_pool, b);
}

// Takes up to max packets into out, fired bindings first. Returns how many.
static uint32_t port_take(port *p, vx_packet *out, uint32_t max) {
  binding *done = nullptr;
  spin_lock(&p->lock);
  uint32_t n = 0;
  while (n < max && p->ready_head) {
    binding *b = p->ready_head;
    p->ready_head = b->next;
    if (!p->ready_head) p->ready_tail = nullptr;
    out[n++] = b->packet;
    b->next = done;
    done = b;
  }
  while (n < max && p->count) {
    out[n++] = p->queue[p->head];
    p->head = (p->head + 1) % PORT_CAPACITY;
    p->count--;
  }
  spin_unlock(&p->lock);
  while (done) {
    binding *next = done->next;
    binding_free(done);
    done = next;
  }
  return n;
}

// Joins the port's waiters, unless a packet is already there. Returns whether
// it joined; the caller then blocks.
static bool port_join_waiters(port *p, thread *t) {
  spin_lock(&p->lock);
  bool join = p->count == 0 && !p->ready_head;
  if (join) {
    t->wait_token = p; // set before t is on the list; wakers only find it there, under this lock
    t->wait_next = nullptr;
    thread **link = &p->waiters;
    while (*link) link = &(*link)->wait_next;
    *link = t;
  }
  spin_unlock(&p->lock);
  return join;
}

static void port_remove_waiter(port *p, thread *t) {
  spin_lock(&p->lock);
  for (thread **link = &p->waiters; *link; link = &(*link)->wait_next) {
    if (*link == t) {
      *link = t->wait_next;
      break;
    }
  }
  spin_unlock(&p->lock);
}

// --- Bindings ---

static binding *binding_new(port *p, uint32_t trigger, uint64_t key, uint64_t threshold, vx_handle source) {
  binding *b = pool_alloc(&binding_pool);
  if (!b) return nullptr;
  object_ref(&p->obj);
  b->port = p;
  b->trigger = trigger;
  b->key = key;
  b->threshold = threshold;
  b->source_handle = source;
  return b;
}

// Moves a binding to its port's ready list as a packet with this value.
static void binding_fire(binding *b, uint64_t value) {
  port *p = b->port;
  b->packet = (vx_packet){.key = b->key,
                          .value = value,
                          .timestamp = clock_now(),
                          .source = b->source_handle,
                          .trigger = b->trigger};
  b->next = nullptr;
  b->fired = true;
  spin_lock(&p->lock);
  if (p->ready_tail)
    p->ready_tail->next = b;
  else
    p->ready_head = b;
  p->ready_tail = b;
  port_wake_one(p);
  spin_unlock(&p->lock);
  // The port owns the fired binding now, so the binding no longer keeps the
  // port alive: a port with packets no one takes is still freed (port_destroy).
  // Only a drop: this runs under the source's lock, or in an interrupt.
  object_drop(&p->obj);
}

// The last reference is gone: the packets fired into the port go with it.
static void port_destroy(port *p) {
  for (binding *b = p->ready_head, *next; b; b = next) {
    next = b->next;
    pool_free(&binding_pool, b);
  }
  pool_free(&port_pool, p);
}

static void observers_add(observers *o, binding *b) {
  b->next = o->head;
  o->head = b;
}

// Fires every binding waiting for this trigger; for COUNTER_GE, only those
// whose threshold `value` has reached. Called with the source's lock held.
static void observers_fire(observers *o, uint32_t trigger, uint64_t value) {
  for (binding **link = &o->head; *link;) {
    binding *b = *link;
    if (b->trigger == trigger && (trigger != VX_TRIGGER_COUNTER_GE || value >= b->threshold)) {
      *link = b->next;
      binding_fire(b, value);
    } else {
      link = &b->next;
    }
  }
}

// The source is being destroyed: its unfired bindings go too. The caller takes
// them off the source under its lock and calls this without it.
static void observers_free(binding *list) {
  while (list) {
    binding *next = list->next;
    binding_free(list);
    list = next;
  }
}
