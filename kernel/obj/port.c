// port.c: ports, the one wait (docs/01 §4.4).
//
// A port queues packets. port_wait returns up to a buffer's worth, or blocks
// until one arrives or the deadline passes. In M1 the only source is port_post;
// bindings to channels, rings, IRQs and counters come in M2, each with one
// packet of its own that later signals coalesce into. Until then a port holds
// at most PORT_CAPACITY posted packets, and a post to a full port fails with
// SHOULD_WAIT instead of being charged to the poster's budget.

constexpr uint32_t PORT_CAPACITY = 64;

typedef struct port {
    object    obj;
    uint32_t  head, count;
    thread   *waiters;   // blocked in port_wait, first come first served
    vx_packet queue[PORT_CAPACITY];
} port;

static pool port_pool = POOL_FOR(port);

static vx_status port_create(port **out) {
    port *p = pool_alloc(&port_pool);
    if (!p) return VX_ERR_NO_MEMORY;
    p->obj = (object){ .type = OBJ_PORT, .refs = 1 };
    *out = p;
    return VX_OK;
}

static vx_status port_post(port *p, const vx_packet *packet) {
    if (p->count == PORT_CAPACITY) return VX_ERR_SHOULD_WAIT;
    p->queue[(p->head + p->count++) % PORT_CAPACITY] = *packet;
    if (p->waiters) {
        thread *t = p->waiters;
        p->waiters = t->next;
        thread_wake(t, VX_OK);
    }
    return VX_OK;
}

// Takes up to max packets. Returns how many.
static uint32_t port_take(port *p, vx_packet *out, uint32_t max) {
    uint32_t n = p->count < max ? p->count : max;
    for (uint32_t i = 0; i < n; i++) out[i] = p->queue[(p->head + i) % PORT_CAPACITY];
    p->head = (p->head + n) % PORT_CAPACITY;
    p->count -= n;
    return n;
}

static void port_remove_waiter(struct port *p, thread *t) {
    for (thread **link = &p->waiters; *link; link = &(*link)->next) {
        if (*link == t) {
            *link = t->next;
            return;
        }
    }
}
