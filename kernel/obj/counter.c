// counter.c: counters, the kernel's monotonic timelines (docs/01 §4.4). A
// counter only goes up: counter_signal sets it to the larger of its value and
// the one given, and fires the COUNTER_GE bindings that value reaches. Ring
// doorbells and GPU fences are counters (M2 onward). (The read-only page that
// lets programs poll a counter without a syscall comes with rings.)

typedef struct counter {
  object obj;
  spinlock lock;
  uint64_t value;
  observers obs;
} counter;

static pool counter_pool = POOL_FOR(counter);

static vx_status counter_create(uint64_t initial, counter **out) {
  counter *c = pool_alloc(&counter_pool);
  if (!c) return VX_ERR_NO_MEMORY;
  c->obj.type = OBJ_COUNTER;
  atomic_store_explicit(&c->obj.refs, 1, memory_order_relaxed);
  c->value = initial;
  *out = c;
  return VX_OK;
}

static void counter_signal(counter *c, uint64_t v) {
  spin_lock(&c->lock);
  if (v > c->value) {
    c->value = v;
    observers_fire(&c->obs, VX_TRIGGER_COUNTER_GE, v);
  }
  spin_unlock(&c->lock);
}

// Adds to the counter (a doorbell rings by one), firing what the new value reaches.
static void counter_add(counter *c, uint64_t delta) {
  spin_lock(&c->lock);
  c->value += delta;
  observers_fire(&c->obs, VX_TRIGGER_COUNTER_GE, c->value);
  spin_unlock(&c->lock);
}

static uint64_t counter_read(counter *c) {
  spin_lock(&c->lock);
  uint64_t v = c->value;
  spin_unlock(&c->lock);
  return v;
}

static vx_status counter_bind(counter *c, binding *b) {
  if (b->trigger != VX_TRIGGER_COUNTER_GE) return VX_ERR_INVALID;
  spin_lock(&c->lock);
  if (c->value >= b->threshold)
    binding_fire(b, c->value);
  else
    observers_add(&c->obs, b);
  spin_unlock(&c->lock);
  return VX_OK;
}

static void counter_destroy(counter *c) {
  spin_lock(&c->lock);
  binding *bindings = c->obs.head;
  spin_unlock(&c->lock);
  observers_free(bindings);
  pool_free(&counter_pool, c);
}
