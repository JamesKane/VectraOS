// tlgen: a trace of its own making for dbg's timeline (M7 step 7g1b2;
// tests/qemu/timeline.ndb), the same records each run, so the window can be
// matched by screenshot: two CPUs and four threads of three processes that
// do not exist (their tracks named by number), a 9Px request's client and
// server spans, a frame's DRAW and LATCH and a COMPOSE, a call and its reply,
// interrupts, faults and samples. It writes them to /tmp/timeline.trace and
// runs dbg -t on the file.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/nsapi.c"

static constexpr uint64_t K = 1000, M = 1'000'000, BASE = 50 * M;
static constexpr uint32_t APP = 900 << 12 | 1, SERVER = 901 << 12 | 1, SERVER2 = 901 << 12 | 2,
                          WIN = 902 << 12 | 1;

static vx_trace_record recs[256];
static uint32_t nrecs;

static void rec(uint64_t t, uint16_t kind, uint16_t cpu, uint32_t tid, uint64_t a, uint64_t b) {
  recs[nrecs++] = (vx_trace_record){.time = BASE + t, .kind = kind, .cpu = cpu, .tid = tid, .a = a, .b = b};
}

static void sw(uint64_t t, uint16_t cpu, uint32_t out, uint32_t in) {
  rec(t, VX_TK_SWITCH, cpu, out, out, in);
}

static void span(uint64_t t0, uint64_t t1, uint32_t tid, uint16_t type, uint64_t flow) {
  rec(t0, VX_TK_SPAN, 0xffff, tid, flow | 1, (uint64_t)type << 48 | (t1 - t0));
}

const char *vx_main(void) {
  sw(0, 0, 0, APP);
  sw(3 * M, 0, APP, SERVER);
  sw(4 * M, 0, SERVER, 0);
  sw(5 * M, 0, 0, APP);
  sw(8 * M, 0, APP, WIN);
  sw(9 * M, 0, WIN, 0);
  sw(M, 1, 0, WIN);
  sw(2 * M, 1, WIN, 0);
  sw(6 * M, 1, 0, SERVER2);
  sw(7500 * K, 1, SERVER2, 0);
  rec(3900 * K, VX_TK_IRQ_IN, 0, 0, 33, 0);
  rec(3950 * K, VX_TK_IRQ_OUT, 0, 0, 33, 0);
  rec(6200 * K, VX_TK_IRQ_IN, 1, 0, 40, 0);
  rec(6260 * K, VX_TK_IRQ_OUT, 1, 0, 40, 0);
  rec(1500 * K, VX_TK_FAULT, 0, APP, 0x40'0000, VX_TF_LAZY);
  rec(5600 * K, VX_TK_FAULT, 0, APP, 0x40'1000, VX_TF_PAGER);
  for (uint64_t t = 250 * K; t < 3 * M; t += 250 * K) rec(t, VX_TK_SAMPLE, 0, APP, 0x40'1234, 1ull << 63);
  for (uint64_t t = 5250 * K; t < 8 * M; t += 250 * K) rec(t, VX_TK_SAMPLE, 0, APP, 0x40'1234, 1ull << 63);
  span(2500 * K, 4200 * K, APP, 116, 0x1000);    // a Tread: the client's
  span(3100 * K, 3800 * K, SERVER, 116, 0x1000); // and the server's
  rec(5500 * K, VX_TK_CALL, 0, APP, 7, 0x2001);
  rec(6800 * K, VX_TK_REPLY, 1, SERVER2, 7, 0x2001);
  span(5200 * K, 7 * M, APP, VX_SPAN_FRAME_DRAW, vx_frame_flow(1, 1));
  span(8200 * K, 8400 * K, WIN, VX_SPAN_FRAME_LATCH, vx_frame_flow(1, 1));
  span(8400 * K, 8900 * K, WIN, VX_SPAN_FRAME_COMPOSE, vx_frame_flow(0, 1));
  for (uint32_t i = 1; i < nrecs; i++) // in time, as /proc/trace/events has them
    for (uint32_t k = i; k > 0 && recs[k].time < recs[k - 1].time; k--) {
      vx_trace_record t = recs[k];
      recs[k] = recs[k - 1], recs[k - 1] = t;
    }
  vx_fd fd = vx_create(VX_STR("/tmp/timeline.trace"), VX_OWRITE, 0644);
  if (fd < 0 ||
      vx_write(fd, (vx_str){(const char *)recs, nrecs * sizeof recs[0]}) != (int64_t)(nrecs * sizeof recs[0]))
    return "cannot write the trace";
  vx_close(fd);
  vx_printf("tlgen: %u records written\n", nrecs);
  vx_str args[] = {VX_STR("dbg"), VX_STR("-t"), VX_STR("/tmp/timeline.trace")};
  vx_spawn_req req = {.path = VX_STR("/boot/bin/dbg"), .args = {args, 3}};
  vx_proc kid = {};
  if (vx_proc_spawn(&req, &kid) != VX_OK) return "cannot run dbg";
  vx_arena *a = vx_arena_new(1 << 16);
  vx_str why = {};
  vx_proc_wait(kid, VX_INFINITE, a, &why);
  vx_printf("tlgen: dbg exited: %.*s\n", VX_FMT(why));
  return nullptr;
}
