// ring_model_test.c: vx-check on the ring's wake protocol (lib/vx-ring,
// docs/01 §4.3). A producer publishes entries and rings the doorbell when the
// consumer said it sleeps; the consumer drains the queue, announces it will
// sleep, rechecks, and sleeps until the doorbell rings.
//
// The protocol as written must hold in every interleaving, and so must one
// change to it: reading the doorbell count after announcing the sleep instead
// of before. (A ring in between follows a published tail, which the recheck
// sees, so the consumer never sleeps on it.) Four broken variants must each be
// caught: without the producer's fence, without the consumer's, without both,
// and without the recheck. A checker that cannot find those would prove
// nothing about the real one.

#include "check.h"
#include "../../lib/vx-check/check.c"

enum { TAIL, FLAG, DOORBELL }; // shared: the SQ tail, the consumer's NEED_WAKEUP, the doorbell counter
enum { PRODUCER, CONSUMER };
enum { PRODUCED = 0, SAW_FLAG = 1 }; // producer locals
enum { HEAD = 0, SEEN_BELL = 1 };    // consumer locals

static int64_t entries; // how many the producer publishes
static bool producer_fence, consumer_fence, bell_before_flag, recheck;

static void init(vxc_state *s) { (void)s; }

static void producer_step(vxc_ctx *c) {
  vxc_thread *t = vxc_me(c);
  switch (t->pc) {
  case 0: // write the entry, publish the tail
    if (t->local[PRODUCED] == entries) {
      t->done = true;
      return;
    }
    vxc_store(c, TAIL, ++t->local[PRODUCED]);
    t->pc = producer_fence ? 1 : 2;
    return;
  case 1: vxc_fence(c), t->pc = 2; return;
  case 2: t->local[SAW_FLAG] = vxc_load(c, FLAG), t->pc = 3; return;
  case 3: // ring the doorbell if the consumer sleeps
    if (t->local[SAW_FLAG]) vxc_kernel_add(c, DOORBELL, 1);
    t->pc = 0;
    return;
  default: return;
  }
}

static void consumer_step(vxc_ctx *c) {
  vxc_thread *t = vxc_me(c);
  switch (t->pc) {
  case 0: // drain
    if (vxc_load(c, TAIL) != t->local[HEAD]) {
      if (++t->local[HEAD] == entries) t->done = true;
      return;
    }
    t->pc = bell_before_flag ? 1 : 2;
    return;
  case 1: t->local[SEEN_BELL] = vxc_kernel_load(c, DOORBELL), t->pc = bell_before_flag ? 2 : 3; return;
  case 2: vxc_store(c, FLAG, 1), t->pc = bell_before_flag ? 3 : 1; return; // NEED_WAKEUP
  case 3: // the fence (or straight on without one)
    if (consumer_fence) vxc_fence(c);
    t->pc = recheck ? 4 : 5;
    return;
  case 4: t->pc = vxc_load(c, TAIL) != t->local[HEAD] ? 6 : 5; return; // recheck
  case 5: vxc_kernel_wait_above(c, DOORBELL, t->local[SEEN_BELL]), t->pc = 6; return;
  case 6: vxc_store(c, FLAG, 0), t->pc = 0; return; // awake
  default: return;
  }
}

static void step(vxc_ctx *c) {
  if (c->tid == PRODUCER)
    producer_step(c);
  else
    consumer_step(c);
}

static bool final_ok(const vxc_state *s, const char **why) {
  if (s->t[CONSUMER].done) return true;
  *why = "the consumer sleeps with entries waiting (a lost wake-up)";
  return false;
}

static bool check_variant(const char *name, int64_t n, bool pfence, bool cfence, bool bell_first,
                          bool check_again) {
  entries = n;
  producer_fence = pfence;
  consumer_fence = cfence;
  bell_before_flag = bell_first;
  recheck = check_again;
  vxc_model m = {.name = name, .threads = 2, .init = init, .step = step, .final_ok = final_ok};
  return vxc_check(&m);
}

int main(void) {
  CHECK(check_variant("ring wake protocol, 1 entry", 1, true, true, true, true));
  CHECK(check_variant("ring wake protocol, 3 entries", 3, true, true, true, true));
  CHECK(check_variant("doorbell read after the flag", 3, true, true, false, true));
  fprintf(stderr, "vx-check: the next four are broken on purpose and must fail:\n");
  CHECK(!check_variant("no producer fence", 2, false, true, true, true));
  CHECK(!check_variant("no consumer fence", 2, true, false, true, true));
  CHECK(!check_variant("no fences", 2, false, false, true, true));
  CHECK(!check_variant("no recheck", 2, true, true, true, false));
  return check_result();
}
