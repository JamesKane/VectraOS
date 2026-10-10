// frametest: frames in the trace (M7 step 7g1b1; tests/qemu/frames.ndb).
// As adm it starts a trace with spans, draws 20 frames in a window of its
// own, stops, and checks the records: a DRAW span for each frame, from this
// task; for each, winsrv's LATCH of that present on the same flow, starting
// after the DRAW did; and winsrv's COMPOSE spans, the screens it made. Then
// it leaves dbg's timeline (dbg -t) showing the trace.

#include <vxui.h>

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_printf("frametest: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static constexpr uint32_t FRAMES = 20;

static uint32_t span_type(const vx_trace_record *r) { return (uint32_t)(r->b >> 48); }

const char *vx_main(void) {
  vx_arena *a = vx_arena_new(64 << 20);
  CHECK(vx_ctl(VX_STR("/proc/trace/ctl"), "start sched,span size 4M") == VX_OK);
  vx_app *app = vx_app_open("org.vectra.frametest");
  vx_window *win = vx_window_open(app, "Frames", 200, 150);
  vx_window_animate(win, true);
  uint32_t frames = 0;
  vx_event ev;
  while (frames < FRAMES && vx_wait(app, &ev, VX_INFINITE)) {
    if (ev.kind != VX_FRAME) continue;
    vx_pixels px = vx_pixels_begin(win, &ev.frame);
    for (uint32_t y = 0; y < px.h; y++) {
      uint32_t *row = (uint32_t *)(px.data + (size_t)y * px.stride);
      for (uint32_t x = 0; x < px.w; x++) row[x] = (frames * 12) << 16 | x << 8 | y;
    }
    vx_pixels_present(win, &px);
    frames++;
  }
  vx_window_animate(win, false);
  for (vx_instant until = vx_now() + 300'000'000; vx_now() < until;) // the last presents latched
    vx_wait(app, &ev, until);
  CHECK(vx_ctl(VX_STR("/proc/trace/ctl"), "stop") == VX_OK);

  vx_fd fd = vx_open(VX_STR("/proc/trace/events"), VX_OREAD);
  vx_trace_record *r = vx_push(a, 32 << 20, 32);
  size_t bytes = 0;
  for (int64_t got;
       fd >= 0 && r && (got = vx_read(fd, (vx_bytes){(uint8_t *)r + bytes, (32 << 20) - bytes})) > 0;)
    bytes += (size_t)got;
  vx_close(fd);
  size_t n = bytes / sizeof *r;
  uint32_t me = (uint32_t)vx_pid(), draws = 0, latched = 0, composed = 0, server = 0;
  for (size_t i = 0; i < n; i++) {
    if (r[i].kind != VX_TK_SPAN || span_type(&r[i]) != VX_SPAN_FRAME_DRAW || r[i].tid >> 12 != me) continue;
    draws++;
    for (size_t k = 0; k < n; k++) // winsrv's latch of this present
      if (r[k].kind == VX_TK_SPAN && span_type(&r[k]) == VX_SPAN_FRAME_LATCH && r[k].a == r[i].a &&
          r[k].tid >> 12 != me && r[k].time >= r[i].time) {
        latched++;
        server = r[k].tid >> 12;
        break;
      }
  }
  for (size_t i = 0; i < n; i++)
    composed +=
        r[i].kind == VX_TK_SPAN && span_type(&r[i]) == VX_SPAN_FRAME_COMPOSE && r[i].tid >> 12 == server;
  vx_printf("frametest: %u frames, %u draws, %u latched, %u composed\n", frames, draws, latched, composed);
  CHECK(frames == FRAMES);
  CHECK(draws == FRAMES);
  CHECK(latched == draws);
  CHECK(server != 0 && server != me);
  CHECK(composed >= FRAMES / 2);
  vx_printf("frametest: %u checks, %u failed\n", checks, failures);
  // dbg's timeline over this trace (7g1b2): it reads the live events, and stays.
  vx_str args[] = {VX_STR("dbg"), VX_STR("-t")};
  vx_spawn_req req = {.path = VX_STR("/boot/bin/dbg"), .args = {args, 2}};
  vx_proc kid = {};
  if (vx_proc_spawn(&req, &kid) != VX_OK) vx_printf("frametest: cannot run dbg\n");
  return failures ? "failed" : nullptr;
}
