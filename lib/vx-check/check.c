// vx-check: an exhaustive interleaving model checker (docs/04 §7), host only.
//
// A model is a few threads, each a state machine whose step function performs
// exactly one memory operation per call. The checker runs every possible order
// of those steps, and of the moments each thread's buffered stores reach
// memory, and checks the model's final condition in every state where nothing
// can move any more. A violation prints the interleaving that led to it.
//
// The memory model is a store-buffer model (TSO): a thread's stores wait in its
// own FIFO buffer, where its own loads see them, until a flush makes them
// visible to everyone; a fence (seq_cst) waits until its buffer is empty. That
// is the reordering behind lost wake-ups (the store-buffer litmus test), the
// one the ring protocol's fences exist to stop. It is not the whole C11 model:
// the weaker reorderings ARM allows on top (load-load, load-store) are kept out
// of these protocols by their acquire and release orderings, which the models
// do not try to break. Kernel operations (vxc_kernel_*) act like syscalls:
// they drain the caller's buffer first, then act on memory atomically.
//
// States are remembered by 128-bit fingerprints, so a collision could hide a
// state; at these model sizes the odds are negligible.

#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

enum : uint32_t {
  VXC_MAX_THREADS = 4,
  VXC_MAX_VARS = 16,
  VXC_MAX_LOCALS = 8,
  VXC_BUFFER = 8,  // stores a thread can have waiting
  VXC_DEPTH = 256, // steps before the checker gives up on a path
};

typedef struct vxc_thread {
  uint32_t pc;
  bool done;
  uint8_t buffered;
  uint8_t buffer_var[VXC_BUFFER];
  int64_t buffer_value[VXC_BUFFER];
  int64_t local[VXC_MAX_LOCALS];
} vxc_thread;

typedef struct vxc_state {
  int64_t mem[VXC_MAX_VARS];
  vxc_thread t[VXC_MAX_THREADS];
} vxc_state;

// What a step function gets: the state to change and its thread. An operation
// whose precondition fails (a fence with stores waiting, a full buffer, a wait
// for a condition that does not hold) sets `blocked`: that step is not
// possible now, and the checker throws its effects away.
typedef struct vxc_ctx {
  vxc_state *s;
  uint32_t tid;
  bool blocked;
} vxc_ctx;

typedef struct vxc_model {
  const char *name;
  uint32_t threads;
  void (*init)(vxc_state *s);
  void (*step)(vxc_ctx *c); // one operation of thread c->tid; sets t.done at its end
  bool (*final_ok)(const vxc_state *s, const char **why);
} vxc_model;

// --- Operations for step functions ---

static vxc_thread *vxc_me(vxc_ctx *c) { return &c->s->t[c->tid]; }

static int64_t vxc_load(vxc_ctx *c, uint32_t var) {
  vxc_thread *t = vxc_me(c);
  for (int i = t->buffered - 1; i >= 0; i--)
    if (t->buffer_var[i] == var) return t->buffer_value[i]; // its own newest store
  return c->s->mem[var];
}

static void vxc_store(vxc_ctx *c, uint32_t var, int64_t value) {
  vxc_thread *t = vxc_me(c);
  if (t->buffered == VXC_BUFFER) {
    c->blocked = true;
    return;
  }
  t->buffer_var[t->buffered] = (uint8_t)var;
  t->buffer_value[t->buffered] = value;
  t->buffered++;
}

static void vxc_fence(vxc_ctx *c) {
  if (vxc_me(c)->buffered) c->blocked = true;
}

static int64_t vxc_kernel_load(vxc_ctx *c, uint32_t var) {
  vxc_fence(c);
  return c->s->mem[var];
}

static void vxc_kernel_add(vxc_ctx *c, uint32_t var, int64_t delta) {
  vxc_fence(c);
  c->s->mem[var] += delta;
}

// Sleeps until mem[var] > seen (a port_wait on a COUNTER_GE binding).
static void vxc_kernel_wait_above(vxc_ctx *c, uint32_t var, int64_t seen) {
  vxc_fence(c);
  if (c->s->mem[var] <= seen) c->blocked = true;
}

// --- The checker ---

typedef struct vxc_action {
  uint8_t kind; // 0: thread steps, 1: thread's oldest store reaches memory
  uint8_t tid;
} vxc_action;

typedef struct vxc_run {
  const vxc_model *m;
  uint64_t *seen; // fingerprints, two words each, 0 0 meaning empty
  uint64_t seen_cap, seen_count;
  uint64_t states, finals, truncated;
  vxc_action path[VXC_DEPTH];
  bool failed;
} vxc_run;

static void vxc_fingerprint(const vxc_state *s, uint64_t out[2]) {
  const uint8_t *p = (const uint8_t *)s;
  uint64_t a = 0xcbf29ce484222325, b = 0x84222325cbf29ce4;
  for (size_t i = 0; i < sizeof *s; i++) {
    a = (a ^ p[i]) * 0x100000001b3;
    b = (b ^ p[i]) * 0x9e3779b97f4a7c15;
    b ^= b >> 29;
  }
  out[0] = a | 1; // never 0: 0 0 marks an empty slot
  out[1] = b;
}

// True if the state was new (and is now remembered).
static bool vxc_remember(vxc_run *r, const vxc_state *s) {
  if (r->seen_count * 2 >= r->seen_cap) { // grow at half full
    uint64_t old_cap = r->seen_cap, *old = r->seen;
    r->seen_cap = old_cap ? old_cap * 2 : 1 << 16;
    r->seen = calloc(r->seen_cap * 2, sizeof(uint64_t));
    for (uint64_t i = 0; i < old_cap; i++) {
      if (!old[2 * i]) continue;
      uint64_t j = old[2 * i] & (r->seen_cap - 1);
      while (r->seen[2 * j]) j = (j + 1) & (r->seen_cap - 1);
      r->seen[2 * j] = old[2 * i];
      r->seen[2 * j + 1] = old[2 * i + 1];
    }
    free(old);
  }
  uint64_t fp[2];
  vxc_fingerprint(s, fp);
  uint64_t j = fp[0] & (r->seen_cap - 1);
  while (r->seen[2 * j]) {
    if (r->seen[2 * j] == fp[0] && r->seen[2 * j + 1] == fp[1]) return false;
    j = (j + 1) & (r->seen_cap - 1);
  }
  r->seen[2 * j] = fp[0];
  r->seen[2 * j + 1] = fp[1];
  r->seen_count++;
  return true;
}

// Tries action a on a copy of s. Returns false if it is not possible now.
static bool vxc_apply(const vxc_run *r, const vxc_state *s, vxc_action a, vxc_state *out) {
  *out = *s;
  vxc_thread *t = &out->t[a.tid];
  if (a.kind == 1) {
    if (!t->buffered) return false;
    out->mem[t->buffer_var[0]] = t->buffer_value[0];
    t->buffered--;
    memmove(t->buffer_var, t->buffer_var + 1, t->buffered);
    memmove(t->buffer_value, t->buffer_value + 1, t->buffered * sizeof(int64_t));
    memset(t->buffer_var + t->buffered, 0, VXC_BUFFER - t->buffered); // keep fingerprints canonical
    memset(t->buffer_value + t->buffered, 0, (VXC_BUFFER - t->buffered) * sizeof(int64_t));
    return true;
  }
  if (t->done) return false;
  vxc_ctx c = {.s = out, .tid = a.tid};
  r->m->step(&c);
  return !c.blocked;
}

static void vxc_report(const vxc_run *r, uint32_t depth, const char *why) {
  fprintf(stderr, "vx-check: %s: violation: %s\n  interleaving:", r->m->name, why);
  for (uint32_t i = 0; i < depth; i++)
    fprintf(stderr, " %s%u", r->path[i].kind ? "flush" : "T", r->path[i].tid);
  fprintf(stderr, "\n");
}

// Depth-first over every interleaving, iteratively (no recursion, as in the
// rest of the tree), with one frame per step on the current path.
static void vxc_explore(vxc_run *r, const vxc_state *start) {
  typedef struct frame {
    vxc_state s;
    uint32_t next; // the next action to try: tid * 2 + kind
    bool any;      // some action was possible here
  } frame;
  frame *stack = calloc(VXC_DEPTH + 1, sizeof(frame));
  uint32_t depth = 0;
  stack[0].s = *start;
  vxc_remember(r, start);
  r->states++;
  for (;;) {
    frame *f = &stack[depth];
    bool moved = false;
    while (f->next < r->m->threads * 2) {
      vxc_action a = {.kind = (uint8_t)(f->next % 2), .tid = (uint8_t)(f->next / 2)};
      f->next++;
      vxc_state n;
      if (!vxc_apply(r, &f->s, a, &n)) continue;
      f->any = true;
      if (!vxc_remember(r, &n)) continue; // reached before, by another order
      r->states++;
      if (depth + 1 == VXC_DEPTH) {
        r->truncated++;
        continue;
      }
      r->path[depth] = a;
      depth++;
      stack[depth] = (frame){.s = n};
      moved = true;
      break;
    }
    if (moved) continue;
    if (!f->any) { // nothing could move here: a final state
      const char *why = "";
      r->finals++;
      if (!r->m->final_ok(&f->s, &why) && !r->failed) {
        r->failed = true;
        vxc_report(r, depth, why);
      }
    }
    if (depth == 0) break;
    depth--;
  }
  free(stack);
}

// Explores every interleaving of the model. Returns true if no final state
// broke its condition, and prints what it covered.
[[maybe_unused]] static bool vxc_check(const vxc_model *m) {
  vxc_run r = {.m = m};
  vxc_state s;
  memset(&s, 0, sizeof s);
  m->init(&s);
  vxc_explore(&r, &s);
  fprintf(stderr, "vx-check: %s: %llu states, %llu final, %llu cut at the depth bound: %s\n", m->name,
          (unsigned long long)r.states, (unsigned long long)r.finals, (unsigned long long)r.truncated,
          r.failed ? "VIOLATION" : "ok");
  free(r.seen);
  return !r.failed && r.truncated == 0;
}
