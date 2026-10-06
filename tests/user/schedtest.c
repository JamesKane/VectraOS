// schedtest: scheduling contexts (M6 step 6d6c, ADR-0038), in the sched
// scenario (tests/qemu/sched.ndb), on four CPUs. Under 32 busy threads, each
// counting, a thread counts too; what it gets is measured against what they
// get at the same time, so a host that runs the machine slower slows both:
// a thread of the hogs' own band gets what one of them does; one bound to a
// realtime context of 3 ms in each 10 ms gets its 30%, about 2.6 times what a
// hog gets (the other 3.7 CPUs shared by 32), and no more, which would be a
// whole CPU, 10.7 times; one bound to a reserved CPU gets nearly that CPU.
// Donation (6d6c2): the realtime thread's calls to a background server, which
// the hogs would starve, are answered: one in each of its periods, each within
// its budget; back to back, on its budget, which they spend, the server
// running for them as realtime, on the caller's loan, and background after.
// Admission past 80% of the CPUs, and a reservation of the shared CPU, are
// refused, as are parameters out of range. Each check prints a line only
// when it fails; the last line counts them, and the shares measured.

#include "../../lib/vx-rt/rt.c"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_print(VX_STR("schedtest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static constexpr int HOGS = 32;
static constexpr vx_duration MEASURE = 1'000'000'000;
static _Atomic bool stop, go;

// The unit of work every thread counts, one function for all of them: two
// loops of their own would compare their code's layout, too.
[[gnu::noinline]] static void burn(void) {
  for (volatile uint32_t k = 0; k < 4096; k++) {}
}

// Counts for d nanoseconds of the clock: how far it got.
static uint64_t count_for(vx_duration d) {
  vx_instant end = vx_clock_read() + d;
  uint64_t n = 0;
  for (;;) {
    burn();
    n++;
    if ((n & 15) == 0 && vx_clock_read() >= end) return n;
  }
}

static uint64_t hog_counts[HOGS];

static void hog(void *arg) {
  uint64_t *n = arg;
  while (!atomic_load(&go)) {}
  while (!atomic_load(&stop)) {
    burn();
    ++*n;
  }
}

// --- A background server, and calls to it ---

static constexpr int CALLS = 40;
static constexpr vx_duration WORK = 500'000; // the server's, for each call
static vx_handle server_end, client_end;
static vx_sched_info after_reply; // the server's, once it has blocked after its last reply
static _Atomic bool server_waiting;

typedef struct reply_msg {
  vx_msg_header h;
  vx_sched_info si; // the server's, as it served the call
} reply_msg;

static void server(void *arg) {
  (void)arg;
  vx_status own = vx_intent_set(VX_INTENT_BACKGROUND);
  vx_handle port = VX_HANDLE_NONE;
  if (own != VX_OK || vx_port_create(0, &port) != VX_OK) return;
  for (bool quit = false; !quit;) {
    vx_msg_header req;
    vx_msg_size got;
    vx_status st = vx_channel_read(server_end, &req, sizeof req, nullptr, 0, &got);
    if (st == VX_ERR_SHOULD_WAIT) {
      vx_packet pkt;
      if (vx_port_bind(port, server_end, VX_TRIGGER_READABLE, 0, 0) != VX_OK) break;
      atomic_store(&server_waiting, true);
      vx_port_wait(port, VX_INFINITE, 0, &pkt, 1);
      continue;
    }
    if (st != VX_OK) break;
    quit = req.ordinal == 1;
    count_for(WORK);
    reply_msg rep = {.h = {.txid = req.txid}};
    vx_thread_state(vx_self, 0, VX_STATE_GET_SCHED, &rep.si, sizeof rep.si);
    vx_channel_write(server_end, &rep, sizeof rep, nullptr, 0);
  }
  vx_packet none; // answered, it keeps the loan until it next blocks
  vx_port_wait(port, vx_clock_read() + 1'000'000, 0, &none, 1);
  vx_thread_state(vx_self, 0, VX_STATE_GET_SCHED, &after_reply, sizeof after_reply);
  vx_handle_close(port);
}

typedef struct called {
  bool periodic;       // one call in each 10 ms, rather than back to back
  uint32_t ok, lent;   // calls answered; answered by the server on this thread's loan
  vx_duration longest; // from call to answer
  uint64_t exhausted;  // periods this thread's context ran out in, during the calls
} called;

static void make_calls(called *out) {
  vx_sched_info before, after;
  vx_thread_state(vx_self, 0, VX_STATE_GET_SCHED, &before, sizeof before);
  vx_handle nap = VX_HANDLE_NONE;
  vx_port_create(0, &nap);
  vx_instant start = vx_clock_read();
  for (int i = 0; i < CALLS; i++) {
    if (out->periodic) { // the next period: a fresh budget, whatever waiting for the hogs spent
      vx_packet none;
      vx_port_wait(nap, start + (vx_instant)(i + 1) * 10'000'000, 0, &none, 1);
    }
    vx_msg_header req = {};
    reply_msg rep = {};
    vx_call call = {.wr_bytes = &req, .wr_len = sizeof req, .rd_bytes = &rep, .rd_cap = sizeof rep};
    vx_instant t0 = vx_clock_read();
    vx_status st = vx_channel_call(client_end, &call, t0 + 1'000'000'000);
    vx_duration took = vx_clock_read() - t0;
    if (st != VX_OK) continue;
    out->ok++;
    if (took > out->longest) out->longest = took;
    if (rep.si.intent == VX_INTENT_REALTIME && rep.si.lent_task && rep.si.lent_thread == vx_thread_self_id())
      out->lent++;
  }
  vx_handle_close(nap);
  vx_thread_state(vx_self, 0, VX_STATE_GET_SCHED, &after, sizeof after);
  out->exhausted = after.exhausted - before.exhausted;
}

typedef struct counted {
  vx_handle ctx;
  int32_t core;
  uint64_t n;
  called *calls; // makes calls rather than count
  vx_status bind;
  _Atomic bool bound;
} counted;

static void counter(void *arg) {
  counted *c = arg;
  c->bind = vx_sched_ctx_bind(c->ctx, VX_HANDLE_NONE, c->core); // checked by the main thread
  atomic_store(&c->bound, true);
  while (!atomic_load(&go)) {}
  if (c->calls)
    make_calls(c->calls);
  else
    c->n = count_for(MEASURE);
}

// One counter's count under the hogs, in hundredths of what a hog counted
// meanwhile, on average.
static uint64_t share(vx_handle ctx, int32_t core, called *calls) {
  static vx_thread hogs[HOGS];
  counted c = {.ctx = ctx, .core = core, .calls = calls};
  vx_thread t;
  atomic_store(&stop, false), atomic_store(&go, false);
  CHECK(vx_thread_spawn(&t, counter, &c, 0) == VX_OK);
  while (!atomic_load(&c.bound)) {}
  CHECK(c.bind == VX_OK);
  for (int i = 0; i < HOGS; i++) {
    hog_counts[i] = 0;
    CHECK(vx_thread_spawn(&hogs[i], hog, &hog_counts[i], 16ull * 1024) == VX_OK);
  }
  atomic_store(&go, true);
  vx_thread_join(&t);
  atomic_store(&stop, true);
  uint64_t all = 0;
  for (int i = 0; i < HOGS; i++) vx_thread_join(&hogs[i]), all += hog_counts[i];
  uint64_t mean = all / HOGS;
  return mean ? c.n * 100 / mean : 0;
}

static void say(const char *what, uint64_t v) {
  vx_print(VX_STR("schedtest: "));
  vx_print(vx_cstr(what));
  vx_print(VX_STR(" "));
  vx_print_u64(v);
  vx_print(VX_STR("\n"));
}

const char *vx_main(void) {
  // A realtime context: 3 ms in each 10 ms.
  vx_handle rt;
  vx_sched_params p = {.intent = VX_INTENT_REALTIME, .period = 10'000'000, .budget = 3'000'000};
  CHECK(vx_sched_ctx_create(&p, &rt) == VX_OK);
  uint64_t rt_share = share(rt, -1, nullptr);
  say("realtime against a hog (percent)", rt_share);
  CHECK(rt_share >= 200 && rt_share <= 320); // about 260: its 30%, more than a hog's, and capped
  uint64_t fair = share(VX_HANDLE_NONE, -1, nullptr);
  say("fair against a hog (percent)", fair);
  CHECK(fair >= 70 && fair <= 130); // about 100

  // Admission: 80% of four CPUs is 3.2; with 0.3 admitted, two whole CPUs fit, a third not.
  vx_handle one = VX_HANDLE_NONE, two = VX_HANDLE_NONE, three = VX_HANDLE_NONE;
  vx_sched_params cpu = {.intent = VX_INTENT_REALTIME, .period = 10'000'000, .budget = 10'000'000};
  CHECK(vx_sched_ctx_create(&cpu, &one) == VX_OK && vx_sched_ctx_create(&cpu, &two) == VX_OK);
  CHECK(vx_sched_ctx_create(&cpu, &three) == VX_ERR_REFUSED);
  vx_handle_close(two);
  CHECK(vx_sched_ctx_create(&cpu, &three) == VX_OK); // the closed one's share given back
  vx_handle_close(one), vx_handle_close(three);
  vx_sched_params bad = {.intent = VX_INTENT_REALTIME, .period = 10'000'000, .budget = 20'000'000};
  vx_handle none;
  CHECK(vx_sched_ctx_create(&bad, &none) == VX_ERR_INVALID);  // more than one CPU
  CHECK(vx_intent_set(VX_INTENT_REALTIME) == VX_ERR_INVALID); // that needs a context
  CHECK(vx_intent_set(VX_INTENT_BACKGROUND) == VX_OK);
  vx_sched_info si;
  CHECK(vx_thread_state(vx_self, 0, VX_STATE_GET_SCHED, &si, sizeof si) == VX_OK &&
        si.intent == VX_INTENT_BACKGROUND && !si.bound);
  CHECK(vx_intent_set(VX_INTENT_INTERACTIVE) == VX_OK);

  // A reservation: one CPU, the last; a thread bound to it keeps it.
  vx_handle res;
  vx_sched_params inter = {.intent = VX_INTENT_INTERACTIVE};
  vx_core_set set;
  CHECK(vx_sched_ctx_create(&inter, &res) == VX_OK);
  CHECK(vx_sched_reserve(res, 1, VX_CORE_ANY, VX_DOMAIN_ANY, 0, &set) == VX_OK && set.count == 1 &&
        set.mask == 1u << 3);
  uint64_t reserved = share(res, 3, nullptr);
  say("reserved against a hog (percent)", reserved);
  CHECK(reserved >= 800); // about 1070: a CPU of its own, against the 3/32 of one each hog gets
  vx_handle other;
  CHECK(vx_sched_ctx_create(&inter, &other) == VX_OK);
  CHECK(vx_sched_reserve(other, 3, VX_CORE_ANY, VX_DOMAIN_ANY, 0, &set) ==
        VX_ERR_REFUSED); // the first stays shared
  CHECK(vx_sched_reserve(other, 2, VX_CORE_ANY, VX_DOMAIN_ANY, 0, &set) == VX_OK && set.mask == 0b0110);
  CHECK(vx_sched_reserve(other, 0, VX_CORE_ANY, VX_DOMAIN_ANY, 0, &set) == VX_OK && !set.count);
  CHECK(vx_sched_reserve(res, 1, VX_CORE_TIER(1), VX_DOMAIN_ANY, 0, &set) == VX_ERR_REFUSED); // no such tier
  vx_handle_close(other), vx_handle_close(res);

  // Donation: the realtime thread calls a background server under the hogs.
  vx_handle ends[2];
  vx_thread srv;
  CHECK(vx_channel_create(0, ends) == VX_OK);
  server_end = ends[0], client_end = ends[1];
  CHECK(vx_thread_spawn(&srv, server, nullptr, 0) == VX_OK);
  while (!atomic_load(&server_waiting)) {}
  vx_handle nap; // and blocked there, as a server waits for its calls
  vx_packet none_pkt;
  if (vx_port_create(0, &nap) == VX_OK)
    vx_port_wait(nap, vx_clock_read() + 50'000'000, 0, &none_pkt, 1), vx_handle_close(nap);
  called calls = {.periodic = true};
  share(rt, -1, &calls);
  say("donated calls answered", calls.ok);
  say("longest donated call (us)", (uint64_t)calls.longest / 1000);
  CHECK(calls.ok == CALLS && calls.lent == CALLS);
  CHECK(calls.longest < 3'000'000); // each within the caller's budget, a period's 3 ms
  calls = (called){};
  share(rt, -1, &calls);
  say("back-to-back calls answered", calls.ok);
  say("back-to-back periods exhausted", calls.exhausted);
  CHECK(calls.ok == CALLS && calls.lent == CALLS);
  CHECK(calls.exhausted >= 3); // 20 ms of the server's work, on the caller's 3 ms in each 10
  vx_msg_header quit = {.ordinal = 1};
  reply_msg ack;
  vx_call call = {.wr_bytes = &quit, .wr_len = sizeof quit, .rd_bytes = &ack, .rd_cap = sizeof ack};
  CHECK(vx_channel_call(client_end, &call, vx_clock_read() + 5'000'000'000) == VX_OK);
  vx_thread_join(&srv);
  CHECK(after_reply.intent == VX_INTENT_BACKGROUND && !after_reply.lent_task); // its own again
  vx_handle_close(server_end), vx_handle_close(client_end), vx_handle_close(rt);

  vx_print(VX_STR("schedtest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  vx_print(VX_STR(" failed\n"));
  return nullptr;
}
