// ring_test.c: lib/vx-ring on the host: the layout, both queues, wraparound,
// the sleep handshake, a hostile peer, and two threads passing two million
// entries through a real doorbell. A lost wake-up would hang that last test,
// so an alarm turns a hang into a failure.

#define _GNU_SOURCE
#include <pthread.h>
#include <signal.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "check.h"
#include "../../lib/vx-ring/ring.c"

// A ring in ordinary memory, laid out as the kernel lays one out.
static uint8_t *make_ring(const vx_ring_params *p, vx_ring_header *h) {
  if (vx_ring_layout(p, h) != VX_OK) return nullptr;
  uint8_t *mem = aligned_alloc(4096, h->size);
  memset(mem, 0, h->size);
  memcpy(mem, h, sizeof *h);
  return mem;
}

static void test_layout(void) {
  vx_ring_header h;
  CHECK(vx_ring_layout(&(vx_ring_params){3, 4, 64, 32, 0, 0}, &h) == VX_ERR_INVALID); // not a power of two
  CHECK(vx_ring_layout(&(vx_ring_params){8192, 4, 64, 32, 0, 0}, &h) == VX_ERR_INVALID);
  CHECK(vx_ring_layout(&(vx_ring_params){4, 4, 40, 32, 0, 0}, &h) == VX_ERR_INVALID); // not a multiple of 16
  CHECK(vx_ring_layout(&(vx_ring_params){64, 64, 64, 32, 5000, 1}, &h) == VX_OK);
  CHECK(h.sq_offset == 8192 && h.cq_offset == 8192 + 64 * 64);
  CHECK(h.client_arena_offset % 4096 == 0 && h.client_arena_size == 8192 && h.server_arena_size == 4096);
  CHECK(h.size == h.server_arena_offset + 4096);
}

static void test_queues(void) {
  vx_ring_header h;
  static const vx_ring_params p = {8, 8, 64, 32, 4096, 4096};
  uint8_t *mem = make_ring(&p, &h);
  vx_ring client, server;
  CHECK(vx_ring_attach(&client, mem, h.size, true, &p) == VX_OK);
  CHECK(vx_ring_attach(&server, mem, h.size, false, &p) == VX_OK);

  // Three laps of the queue, filling it each time.
  uint64_t next = 0, expect = 0;
  for (int lap = 0; lap < 3; lap++) {
    for (int i = 0; i < 8; i++) {
      vx_sqe *e = vx_ring_produce_slot(&client);
      CHECK(e != nullptr);
      if (!e) return;
      *e = (vx_sqe){.opcode = 1, .user_data = next++};
      vx_ring_produce(&client);
    }
    CHECK(vx_ring_produce_slot(&client) == nullptr); // full
    vx_sqe got;
    while (vx_ring_consume(&server, &got) == VX_OK) CHECK(got.user_data == expect++);
    CHECK(expect == next);
  }

  // Completions flow the other way.
  vx_cqe *c = vx_ring_produce_slot(&server);
  *c = (vx_cqe){.user_data = 77, .result = -2};
  vx_ring_produce(&server);
  vx_cqe done;
  CHECK(vx_ring_consume(&client, &done) == VX_OK && done.user_data == 77 && done.result == -2);
  CHECK(vx_ring_consume(&client, &done) == VX_ERR_SHOULD_WAIT);

  // The sleep handshake: the producer learns the consumer is asleep.
  CHECK(vx_ring_prepare_sleep(&server)); // empty: may sleep
  vx_sqe *e = vx_ring_produce_slot(&client);
  *e = (vx_sqe){.user_data = 5};
  CHECK(vx_ring_produce(&client)); // asleep: ring the doorbell
  vx_ring_end_sleep(&server);
  CHECK(!vx_ring_prepare_sleep(&server)); // an entry is waiting: do not sleep
  vx_sqe got;
  CHECK(vx_ring_consume(&server, &got) == VX_OK && got.user_data == 5);
  e = vx_ring_produce_slot(&client);
  *e = (vx_sqe){.user_data = 6};
  CHECK(!vx_ring_produce(&client)); // awake: no doorbell
  CHECK(vx_ring_consume(&server, &got) == VX_OK);

  // Arenas: each side writes its own; the peer's ranges are checked.
  uint64_t size;
  uint8_t *mine = vx_ring_arena(&client, &size);
  CHECK(size == 4096);
  mine[100] = 42;
  CHECK(vx_ring_peer_bytes(&server, 100, 1) && *vx_ring_peer_bytes(&server, 100, 1) == 42);
  CHECK(vx_ring_peer_bytes(&server, 4000, 97) == nullptr);
  CHECK(vx_ring_peer_bytes(&server, UINT64_MAX, 2) == nullptr);
  free(mem);
}

static void test_hostile_peer(void) {
  vx_ring_header h;
  static const vx_ring_params p = {8, 8, 64, 32, 0, 0};
  uint8_t *mem = make_ring(&p, &h);
  vx_ring server, other;
  CHECK(vx_ring_attach(&other, mem, h.size - 1, false, &p) == VX_ERR_INVALID); // mapping too small
  CHECK(vx_ring_produce_slot(&other) == nullptr); // a failed attach leaves nothing usable
  ((vx_ring_header *)mem)->cq_offset += 64;       // a rewritten header
  CHECK(vx_ring_attach(&other, mem, h.size, true, &p) == VX_ERR_INVALID);
  ((vx_ring_header *)mem)->cq_offset -= 64;

  // A ring made, consistently, with bigger entries than this side's protocol
  // has: refused, since each consume would copy an entry that size into the
  // caller's (smaller) buffer.
  vx_ring_header big;
  uint8_t *wide = make_ring(&(vx_ring_params){8, 8, 64, 256, 0, 0}, &big);
  CHECK(big.size <= h.size + 4096); // it may even fit the same mapping
  CHECK(vx_ring_attach(&other, wide, big.size, true, &p) == VX_ERR_INVALID);
  free(wide);

  // A client whose tail runs past what fits: the server marks the ring broken.
  CHECK(vx_ring_attach(&server, mem, h.size, false, &p) == VX_OK);
  ((vx_ring_index *)(mem + VX_RING_INDEX_OFFSET))[VX_RING_SQ_TAIL].index = 9;
  vx_sqe got;
  CHECK(!server.broken);
  CHECK(vx_ring_consume(&server, &got) == VX_ERR_BAD_STATE);
  CHECK(server.broken); // by the overrun check, not by an earlier failure
  ((vx_ring_index *)(mem + VX_RING_INDEX_OFFSET))[VX_RING_SQ_TAIL].index =
      1; // putting it back does not mend it
  CHECK(vx_ring_consume(&server, &got) == VX_ERR_BAD_STATE);
  CHECK(vx_ring_produce_slot(&server) == nullptr);
  free(mem);
}

// --- Two threads and a doorbell ---

typedef struct doorbell { // what ring_notify and a port_wait do, in host terms
  pthread_mutex_t lock;
  pthread_cond_t rung;
  uint64_t count;
} doorbell;

static void ring_bell(doorbell *d) {
  pthread_mutex_lock(&d->lock);
  d->count++;
  pthread_cond_broadcast(&d->rung);
  pthread_mutex_unlock(&d->lock);
}

static uint64_t bell_count(doorbell *d) {
  pthread_mutex_lock(&d->lock);
  uint64_t c = d->count;
  pthread_mutex_unlock(&d->lock);
  return c;
}

static void wait_bell(doorbell *d, uint64_t seen) {
  pthread_mutex_lock(&d->lock);
  while (d->count == seen) pthread_cond_wait(&d->rung, &d->lock);
  pthread_mutex_unlock(&d->lock);
}

static constexpr uint64_t STRESS_ENTRIES = 2'000'000;
static vx_ring stress_client, stress_server;
static doorbell server_bell = {PTHREAD_MUTEX_INITIALIZER, PTHREAD_COND_INITIALIZER, 0};

static void *producer(void *arg) {
  (void)arg;
  for (uint64_t i = 0; i < STRESS_ENTRIES; i++) {
    vx_sqe *e;
    while (!(e = vx_ring_produce_slot(&stress_client))) sched_yield(); // full: let the consumer run
    *e = (vx_sqe){.user_data = i};
    if (vx_ring_produce(&stress_client)) ring_bell(&server_bell);
  }
  return nullptr;
}

static void alarm_fired(int sig) {
  (void)sig;
  static const char msg[] = "ring_test: the consumer slept through a doorbell (lost wake-up)\n";
  write(2, msg, sizeof msg - 1);
  _exit(1);
}

static void test_threads(void) {
  vx_ring_header h;
  static const vx_ring_params p = {64, 64, 64, 32, 0, 0};
  uint8_t *mem = make_ring(&p, &h);
  vx_ring_attach(&stress_client, mem, h.size, true, &p);
  vx_ring_attach(&stress_server, mem, h.size, false, &p);
  signal(SIGALRM, alarm_fired);
  alarm(60);

  pthread_t t;
  pthread_create(&t, nullptr, producer, nullptr);
  uint64_t expect = 0, sleeps = 0;
  bool in_order = true;
  while (expect < STRESS_ENTRIES) {
    vx_sqe got;
    if (vx_ring_consume(&stress_server, &got) == VX_OK) {
      in_order = in_order && got.user_data == expect;
      expect++;
      continue;
    }
    uint64_t seen = bell_count(&server_bell); // before announcing: a ring after this is not missed
    if (vx_ring_prepare_sleep(&stress_server)) {
      sleeps++;
      wait_bell(&server_bell, seen);
    }
    vx_ring_end_sleep(&stress_server);
  }
  pthread_join(t, nullptr);
  alarm(0);
  CHECK(in_order);
  CHECK(sleeps > 0); // the handshake was exercised, not just the busy path
  free(mem);
}

int main(void) {
  test_layout();
  test_queues();
  test_hostile_peer();
  test_threads();
  return check_result();
}
