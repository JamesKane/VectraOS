// ring.c: rings, the data plane (docs/01 §4.3).
//
// The kernel makes a ring's shared VMO and writes its header (lib/vx-ring's
// layout), and after that never reads the ring: the queues are the two sides'
// business, and lib/vx-ring is the protocol. What the kernel keeps is per end:
//
//  - a doorbell: a counter the peer rings with ring_notify, which a port waits
//    on through a COUNTER_GE binding on the end (counter_read on the end reads
//    it), and PEER_CLOSED bindings for when the peer goes away;
//  - the handle side channel: an entry cannot carry a capability, so a side
//    puts handles in a numbered slot (ring_xfer_handles, PUT), names the slot
//    in the entry, and the peer takes them (TAKE). Unclaimed slots are
//    released with the ring.

typedef struct ring_slot {
  uint32_t count; // 0: free
  moved_handle handles[VX_RING_SLOT_HANDLES];
} ring_slot;

struct ring_pair;

typedef struct ring_end {
  object obj;
  struct ring_pair *pair;
  uint32_t side;     // 0: the client, 1: the server
  counter *doorbell; // rung by the peer
  observers obs;     // PEER_CLOSED
} ring_end;

typedef struct ring_pair {
  spinlock lock;
  ring_end *ends[2];                 // nullptr once that end is destroyed
  ring_slot slots[2][VX_RING_SLOTS]; // slots[d]: put by side d, taken by the other
} ring_pair;

static pool ring_end_pool = POOL_FOR(ring_end);
static pool ring_pair_pool = POOL_FOR(ring_pair);
static_assert(sizeof(ring_pair) <= 4096); // a pool object fits in a page

// A new ring: its memory, with the header written, and its two ends.
static vx_status ring_create(const vx_ring_params *p, ring_end **client, ring_end **server, vmo **memory) {
  vx_ring_header h;
  vx_status st = vx_ring_layout(p, &h);
  if (st != VX_OK) return st;
  vmo *v;
  if ((st = vmo_create(h.size, &v)) != VX_OK) return st;
  vmo_write(v, 0, &h, sizeof h);
  ring_pair *pair = pool_alloc(&ring_pair_pool);
  ring_end *ends[2] = {};
  counter *bells[2] = {};
  bool ok = pair;
  for (uint32_t i = 0; i < 2 && ok; i++) {
    ok = (ends[i] = pool_alloc(&ring_end_pool)) && counter_create(0, &bells[i]) == VX_OK;
    if (!ok) break;
    ends[i]->obj.type = OBJ_RING;
    atomic_store_explicit(&ends[i]->obj.refs, 1, memory_order_relaxed);
    ends[i]->pair = pair;
    ends[i]->side = i;
    ends[i]->doorbell = bells[i];
    pair->ends[i] = ends[i];
  }
  if (!ok) {
    for (uint32_t i = 0; i < 2; i++) {
      if (bells[i]) object_release(&bells[i]->obj);
      if (ends[i]) pool_free(&ring_end_pool, ends[i]);
    }
    if (pair) pool_free(&ring_pair_pool, pair);
    object_release(&v->obj);
    return VX_ERR_NO_MEMORY;
  }
  *client = ends[0];
  *server = ends[1];
  *memory = v;
  return VX_OK;
}

// Rings the peer's doorbell (the producer saw it sleep). PEER_CLOSED if it is gone.
static vx_status ring_notify(ring_end *e) {
  spin_lock(&e->pair->lock);
  ring_end *peer = e->pair->ends[1 - e->side];
  counter *bell = peer ? peer->doorbell : nullptr;
  if (bell) object_ref(&bell->obj);
  spin_unlock(&e->pair->lock);
  if (!bell) return VX_ERR_PEER_CLOSED;
  counter_add(bell, 1);
  object_release(&bell->obj);
  return VX_OK;
}

// COUNTER_GE waits on this end's doorbell; PEER_CLOSED on the peer going.
static vx_status ring_bind(ring_end *e, binding *b) {
  if (b->trigger == VX_TRIGGER_COUNTER_GE) return counter_bind(e->doorbell, b);
  if (b->trigger != VX_TRIGGER_PEER_CLOSED) return VX_ERR_INVALID;
  spin_lock(&e->pair->lock);
  if (!e->pair->ends[1 - e->side])
    binding_fire(b, 0);
  else
    observers_add(&e->obs, b);
  spin_unlock(&e->pair->lock);
  return VX_OK;
}

// Puts moved handles in a free slot for the peer; returns the slot, or SHOULD_WAIT if all are taken.
static int64_t ring_put(ring_end *e, const moved_handle *handles, uint32_t count) {
  spin_lock(&e->pair->lock);
  int64_t result = VX_ERR_SHOULD_WAIT;
  for (uint32_t i = 0; i < VX_RING_SLOTS; i++) {
    ring_slot *s = &e->pair->slots[e->side][i];
    if (s->count) continue;
    s->count = count;
    memcpy(s->handles, handles, count * sizeof(moved_handle));
    result = i;
    break;
  }
  spin_unlock(&e->pair->lock);
  return result;
}

// Takes the peer's slot; its handles are the caller's to install. INVALID if
// the slot holds nothing.
static vx_status ring_take(ring_end *e, uint32_t slot, moved_handle *out, uint32_t *count) {
  if (slot >= VX_RING_SLOTS) return VX_ERR_INVALID;
  spin_lock(&e->pair->lock);
  ring_slot *s = &e->pair->slots[1 - e->side][slot];
  vx_status st = s->count ? VX_OK : VX_ERR_INVALID;
  if (st == VX_OK) {
    *count = s->count;
    memcpy(out, s->handles, s->count * sizeof(moved_handle));
    s->count = 0;
  }
  spin_unlock(&e->pair->lock);
  return st;
}

static void ring_destroy(ring_end *e) {
  ring_pair *pair = e->pair;
  spin_lock(&pair->lock);
  pair->ends[e->side] = nullptr;
  ring_end *peer = pair->ends[1 - e->side];
  if (peer) observers_fire(&peer->obs, VX_TRIGGER_PEER_CLOSED, 0);
  binding *bindings = e->obs.head;
  spin_unlock(&pair->lock);
  observers_free(bindings);
  object_drop(&e->doorbell->obj);
  pool_free(&ring_end_pool, e);
  if (peer) return;
  for (uint32_t d = 0; d < 2; d++) // the last end: unclaimed handles go with the ring
    for (uint32_t i = 0; i < VX_RING_SLOTS; i++)
      for (uint32_t k = 0; k < pair->slots[d][i].count; k++) object_drop(pair->slots[d][i].handles[k].obj);
  pool_free(&ring_pair_pool, pair);
}
