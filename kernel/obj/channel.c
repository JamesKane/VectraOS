// channel.c: channels, the control plane (docs/01 §4.2).
//
// A channel is two ends. A message written to one end is queued at the other:
// a 16-byte header, a body of up to 64 KiB, and up to 64 handles, which move
// out of the writer's handle table and into the reader's. The kernel copies the
// body twice, in and out, and writes the header's sender_intent itself.
//
// Each end's queue is bounded by CHANNEL_QUEUE_MESSAGES and
// CHANNEL_QUEUE_BYTES, so a flood fails the writer with SHOULD_WAIT and never
// grows the kernel. (Charging the queue to the writer's budget comes with
// budgets.)
//
// channel_call writes a request and waits on its own end for the reply whose
// txid matches; the kernel picks the txid, and the reply goes straight to the
// waiting caller instead of the queue. (Running the server on the caller's
// scheduling context, 01 §4.5, comes with scheduling contexts.)
//
// Both ends share one lock. Objects that leave the kernel's hands (a message's
// handles, a dying end's bindings) are released after it is dropped, because
// releasing one may destroy another channel.

static constexpr uint32_t CHANNEL_QUEUE_MESSAGES = 64;
static constexpr uint64_t CHANNEL_QUEUE_BYTES = 1ull << 20;

typedef struct moved_handle {
  object *obj; // the reference the sender's handle held
  uint32_t rights;
} moved_handle;

typedef struct channel_msg {
  struct channel_msg *next;
  struct call_wait *call; // the channel_call that sent it, while it waits in a queue
  unsigned order;         // the physical block it lives in
  uint32_t len;           // body bytes, header included
  uint32_t count;         // handles
  moved_handle handles[];
  // then the body
} channel_msg;

static uint8_t *msg_body(channel_msg *m) { return (uint8_t *)&m->handles[m->count]; }

struct channel_pair;

// A thread in channel_call, waiting on its own end for its reply.
typedef struct call_wait {
  struct call_wait *next;
  thread *thread;
  uint32_t txid;
  channel_msg *reply; // set by the writer of the reply
  bool read;          // its request has left the server's queue: read, and maybe freed
} call_wait;

typedef struct channel {
  object obj;
  struct channel_pair *pair;
  uint32_t side;            // this end is pair->ends[side]
  channel_msg *head, *tail; // messages for this end's reader
  uint32_t count;
  uint64_t bytes;
  observers obs;    // READABLE and PEER_CLOSED bindings on this end
  call_wait *calls; // channel_calls waiting for a reply on this end
  uint32_t next_txid;
} channel;

typedef struct channel_pair {
  spinlock lock;
  channel *ends[2]; // nullptr once that end is destroyed
} channel_pair;

// Kernel-picked txids have the top bit set; bit 30 says which end's call it
// is, so a call in each direction at once is never taken for the other's reply.
static constexpr uint32_t CALL_TXID = 0x8000'0000, SIDE_TXID = 0x4000'0000;

static pool channel_pool = POOL_FOR(channel);
static pool channel_pair_pool = POOL_FOR(channel_pair);

static vx_status channel_create(channel **a, channel **b) {
  channel_pair *pair = pool_alloc(&channel_pair_pool);
  channel *e0 = pair ? pool_alloc(&channel_pool) : nullptr;
  channel *e1 = e0 ? pool_alloc(&channel_pool) : nullptr;
  if (!e1) {
    if (e0) pool_free(&channel_pool, e0);
    if (pair) pool_free(&channel_pair_pool, pair);
    return VX_ERR_NO_MEMORY;
  }
  channel *ends[2] = {e0, e1};
  for (uint32_t i = 0; i < 2; i++) {
    ends[i]->obj.type = OBJ_CHANNEL;
    atomic_store_explicit(&ends[i]->obj.refs, 1, memory_order_relaxed);
    ends[i]->pair = pair;
    ends[i]->side = i;
    ends[i]->next_txid = CALL_TXID | i << 30; // each end's calls in a half of their own
    pair->ends[i] = ends[i];
  }
  *a = e0;
  *b = e1;
  return VX_OK;
}

static channel *channel_peer(channel *c) { return c->pair->ends[1 - c->side]; }

static void msg_free(channel_msg *m) {
  for (uint32_t i = 0; i < m->count; i++) object_drop(m->handles[i].obj);
  phys_free((uint64_t)m - boot.hhdm, m->order);
}

static void msg_list_free(channel_msg *m) {
  while (m) {
    channel_msg *next = m->next;
    msg_free(m);
    m = next;
  }
}

// A message block for `len` body bytes and `count` handles, or nullptr.
static channel_msg *msg_alloc(uint32_t len, uint32_t count) {
  size_t size = sizeof(channel_msg) + count * sizeof(moved_handle) + len;
  unsigned order = 0;
  while ((4096ull << order) < size) order++;
  uint64_t pa = phys_alloc(order);
  if (!pa) return nullptr;
  channel_msg *m = phys_to_virt(pa);
  *m = (channel_msg){.order = order, .len = len, .count = count};
  return m;
}

// Queues m for the reader of `to`, or hands it to the channel_call waiting for
// it there. Called with the pair's lock held. Fails with SHOULD_WAIT when the
// queue is full.
static vx_status channel_deliver(channel *to, channel_msg *m) {
  uint32_t txid = ((const vx_msg_header *)msg_body(m))->txid;
  for (call_wait **link = &to->calls; txid && *link; link = &(*link)->next) {
    call_wait *w = *link;
    if (w->txid != txid) continue;
    *link = w->next;
    w->reply = m;
    thread_wake_token(w->thread, w, VX_OK);
    return VX_OK;
  }
  if (to->count == CHANNEL_QUEUE_MESSAGES || to->bytes + m->len > CHANNEL_QUEUE_BYTES)
    return VX_ERR_SHOULD_WAIT;
  m->next = nullptr;
  if (to->tail)
    to->tail->next = m;
  else
    to->head = m;
  to->tail = m;
  to->count++;
  to->bytes += m->len;
  observers_fire(&to->obs, VX_TRIGGER_READABLE, to->count);
  return VX_OK;
}

// Sends a message the caller has filled in, handles included, to c's peer.
// On success the message belongs to the channel; on failure to the caller.
static vx_status channel_write(channel *c, channel_msg *m) {
  ((vx_msg_header *)msg_body(m))->sender_intent = thread_intent(this_cpu()->current);
  spin_lock(&c->pair->lock);
  channel *peer = channel_peer(c);
  vx_status st = peer ? channel_deliver(peer, m) : VX_ERR_PEER_CLOSED;
  spin_unlock(&c->pair->lock);
  return st;
}

// Takes the next message if it fits caps of `cap` bytes and `count_cap`
// handles; otherwise reports its size in *need and leaves it queued.
static vx_status channel_read(channel *c, uint32_t cap, uint32_t count_cap, channel_msg **out,
                              vx_msg_size *need) {
  spin_lock(&c->pair->lock);
  channel_msg *m = c->head;
  vx_status st = VX_OK;
  if (!m) {
    st = channel_peer(c) ? VX_ERR_SHOULD_WAIT : VX_ERR_PEER_CLOSED;
  } else {
    *need = (vx_msg_size){m->len, m->count};
    if (m->len > cap || m->count > count_cap) {
      st = VX_ERR_TOO_SMALL;
    } else {
      c->head = m->next;
      if (!c->head) c->tail = nullptr;
      c->count--;
      c->bytes -= m->len;
      if (m->call) m->call->read = true, m->call = nullptr;
      *out = m;
    }
  }
  spin_unlock(&c->pair->lock);
  return st;
}

// Writes a request with a kernel-picked txid and waits on c for the reply, or
// the deadline. The reply is returned whole; the caller checks its size. *sent
// says whether the request went out: if so it belongs to the channel, whatever
// happens next; if not it is still the caller's.
static vx_status channel_call(channel *c, channel_msg *request, vx_instant deadline, channel_msg **reply,
                              bool *sent) {
  thread *t = this_cpu()->current;
  call_wait w = {.thread = t};
  *sent = false;
  spin_lock(&c->pair->lock);
  channel *peer = channel_peer(c);
  if (!peer) {
    spin_unlock(&c->pair->lock);
    return VX_ERR_PEER_CLOSED;
  }
  w.txid = c->next_txid;
  c->next_txid = CALL_TXID | (c->next_txid & SIDE_TXID) | ((c->next_txid + 1) & ~(CALL_TXID | SIDE_TXID));
  ((vx_msg_header *)msg_body(request))->txid = w.txid;
  ((vx_msg_header *)msg_body(request))->sender_intent = thread_intent(this_cpu()->current);
  request->call = &w;
  vx_status st = channel_deliver(peer, request);
  if (st != VX_OK) request->call = nullptr;
  if (st == VX_OK) {
    *sent = true;
    t->wait_token = &w;
    w.next = c->calls;
    c->calls = &w;
  }
  spin_unlock(&c->pair->lock);
  if (st != VX_OK) return st;

  // A call that ends without its reply (interrupted, timed out) takes back a
  // request the server has not read yet, so the server never answers a call
  // nobody waits for. Whether it is still queued is w.read, not a search for
  // its address: once read, its block may be freed and given to another
  // message in the same queue. An interrupted call whose request the server has read
  // waits on for the reply, so no answer is lost: the interrupt is delivered
  // once it returns. (A server that holds a call, as posixd does a wait,
  // answers it before it interrupts the caller.)
  int64_t woke;
  for (;;) {
    woke = thread_block(deadline, 0);
    spin_lock(&c->pair->lock);
    channel *server = channel_peer(c);
    bool queued = server && !w.read && !w.reply;
    for (channel_msg **link = queued ? &server->head : nullptr, *prev = nullptr; link && *link;
         prev = *link, link = &(*link)->next) {
      if (*link != request) continue;
      if (woke == VX_ERR_INTERRUPTED || woke == VX_ERR_TIMED_OUT || woke == VX_ERR_KILLED) {
        *link = request->next;
        if (server->tail == request) server->tail = prev;
        server->count--;
        server->bytes -= request->len;
        request->call = nullptr;
        *sent = false; // the caller's again, and freed with its handles
      }
      break;
    }
    if (!w.reply && woke == VX_ERR_INTERRUPTED && server && !queued) {
      t->wait_token = &w; // the server has it: its answer is coming
      spin_unlock(&c->pair->lock);
      continue;
    }
    for (call_wait **link = &c->calls; *link; link = &(*link)->next) { // stop waiting
      if (*link == &w) {
        *link = w.next;
        break;
      }
    }
    if (*sent && !w.read && server) request->call = nullptr; // left queued: w is gone
    spin_unlock(&c->pair->lock);
    break;
  }
  if (w.reply) {
    *reply = w.reply;
    return VX_OK;
  }
  return woke == VX_OK ? VX_ERR_PEER_CLOSED : (vx_status)woke;
}

// Attaches a READABLE or PEER_CLOSED binding, or fires it at once if it holds.
static vx_status channel_bind(channel *c, binding *b) {
  if (b->trigger != VX_TRIGGER_READABLE && b->trigger != VX_TRIGGER_PEER_CLOSED) return VX_ERR_INVALID;
  spin_lock(&c->pair->lock);
  if (b->trigger == VX_TRIGGER_READABLE && c->head)
    binding_fire(b, c->count);
  else if (b->trigger == VX_TRIGGER_PEER_CLOSED && !channel_peer(c))
    binding_fire(b, 0);
  else
    observers_add(&c->obs, b);
  spin_unlock(&c->pair->lock);
  return VX_OK;
}

// The last reference to an end is gone: its peer sees PEER_CLOSED, and calls
// waiting on the peer end fail.
static void channel_destroy(channel *c) {
  channel_pair *pair = c->pair;
  spin_lock(&pair->lock);
  channel_msg *queued = c->head;
  binding *bindings = c->obs.head;
  pair->ends[c->side] = nullptr;
  channel *peer = channel_peer(c);
  if (peer) {
    observers_fire(&peer->obs, VX_TRIGGER_PEER_CLOSED, 0);
    for (call_wait *w = peer->calls; w; w = w->next) thread_wake_token(w->thread, w, VX_ERR_PEER_CLOSED);
    peer->calls = nullptr;
  }
  spin_unlock(&pair->lock);
  msg_list_free(queued);
  observers_free(bindings);
  pool_free(&channel_pool, c);
  if (!peer) pool_free(&channel_pair_pool, pair);
}
