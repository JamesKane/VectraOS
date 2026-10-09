// tracetest: the kernel's trace through /proc/trace (M7 step 7a1b, ADR-0049),
// the trace scenario's (tests/qemu/trace.ndb). As adm it starts a trace,
// spawns itself as a child that writes to it through a pipe, maps a file on
// fsd and touches it, stops, and checks the records: its wake by the child,
// the pager's fault at the address, the spawn's syscalls, and that every
// wake's waker is a thread the trace saw. And flows (7a2): a write and its
// sync, followed span by span from this process through fsd to the disk
// driver, and the disk's interrupt within the driver's span. Then sampling
// (7a3a): a busy loop in one small function, found in most of the samples.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/nsapi.c"

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  vx_printf("tracetest: FAILED line %d: %s\n", line, what);
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static vx_status ctl(const char *cmd) { return vx_ctl(VX_STR("/proc/trace/ctl"), "%s", cmd); }

static uint32_t tid_task(uint32_t tid) { return tid >> 12; }

static uint64_t span_end(const vx_trace_record *s) { return s->time + (s->b & 0xffff'ffff'ffff); }

// Whether an interrupt came during span s.
static bool irq_within(const vx_trace_record *r, size_t n, const vx_trace_record *s) {
  for (size_t k = 0; k < n; k++)
    if (r[k].kind == VX_TK_IRQ_IN && r[k].time >= s->time && r[k].time <= span_end(s)) return true;
  return false;
}

// How deep the chains from this task's spans go, level by level: a span's
// server side, then the spans its task made meanwhile (its own requests,
// another flow each), and theirs. *irq: an interrupt came during a span of
// the deepest level. at holds 2n indices: this level's and the next's.
static int chains(const vx_trace_record *r, size_t n, uint32_t self, size_t *at, bool *irq) {
  size_t *cur = at, *nxt = at + n;
  size_t level = 0; // the requests of this level: indices of their client spans, cur[0..level)
  for (size_t i = 0; i < n; i++)
    if (r[i].kind == VX_TK_SPAN && tid_task(r[i].tid) == self) cur[level++] = i;
  int depth = 0;
  for (int d = 1; d < 8 && level; d++) {
    size_t next = 0;
    bool any = false, with_irq = false;
    for (size_t l = 0; l < level; l++) {
      const vx_trace_record *c = &r[cur[l]];
      for (size_t i = 0; i < n; i++) { // the server side: the flow's span in another task
        if (r[i].kind != VX_TK_SPAN || r[i].a != c->a || r[i].tid == c->tid) continue;
        any = true;
        with_irq = with_irq || irq_within(r, n, &r[i]);
        for (size_t j = 0; j < n && next < n; j++) // its task's own requests meanwhile
          if (r[j].kind == VX_TK_SPAN && tid_task(r[j].tid) == tid_task(r[i].tid) && r[j].a != r[i].a &&
              r[j].time >= r[i].time && span_end(&r[j]) <= span_end(&r[i]))
            nxt[next++] = j;
      }
    }
    if (!any) break;
    depth = d, *irq = with_irq;
    level = next;
    size_t *t = cur;
    cur = nxt, nxt = t;
  }
  return depth;
}

// Runs trace ARG, its standard output a pipe read here: true if it ended
// well, having printed both needles (each within one write).
static bool run_trace(vx_arena *a, vx_str arg, vx_str one, vx_str two) {
  vx_handle out[2];
  if (vx_channel_create(0, out) != VX_OK) return false;
  vx_str targs[] = {VX_STR("trace"), arg};
  vx_str names[] = {VX_STR("stdout")};
  vx_spawn_req treq = {.path = VX_STR("/boot/bin/trace"),
                       .args = {targs, 2},
                       .handles = &out[1],
                       .handle_names = names,
                       .nhandles = 1};
  vx_proc tp = {};
  if (vx_proc_spawn(&treq, &tp) != VX_OK) return false;
  bool got_one = false, got_two = false;
  static uint8_t msg[sizeof(vx_msg_header) + 4096];
  for (;;) {
    vx_msg_size size;
    vx_status rs = vx_channel_read(out[0], msg, sizeof msg, nullptr, 0, &size);
    if (rs == VX_ERR_SHOULD_WAIT) {
      vx_handle wait_port;
      vx_packet pk;
      vx_port_create(0, &wait_port);
      vx_port_bind(wait_port, out[0], VX_TRIGGER_READABLE, 1, 0);
      vx_port_bind(wait_port, out[0], VX_TRIGGER_PEER_CLOSED, 2, 0);
      vx_port_wait(wait_port, vx_now() + 10'000'000'000, 0, &pk, 1);
      vx_handle_close(wait_port);
      continue;
    }
    if (rs != VX_OK) break; // trace has ended
    vx_str text = {(const char *)msg + sizeof(vx_msg_header), size.bytes - sizeof(vx_msg_header)};
    got_one = got_one || vx_str_find(text, one) >= 0;
    got_two = got_two || vx_str_find(text, two) >= 0;
  }
  vx_handle_close(out[0]);
  vx_str exit = VX_STR("unset");
  return vx_proc_wait(tp, VX_INFINITE, a, &exit) == VX_OK && exit.len == 0 && got_one && got_two;
}

// Spins until `until`, its time read only now and then: what samples find.
[[gnu::noinline]] static uint64_t busy(vx_instant until) {
  volatile uint64_t x = 1;
  while (vx_now() < until)
    for (uint32_t i = 0; i < 100'000; i++) x = x * 6'364'136'223'846'793'005ull + 1;
  return x;
}

// The sampling test (7a3a): of this task's user-mode samples during a busy
// loop, how many land in busy (its code, a few hundred bytes from its
// start), and whether those walked a frame back to their caller.
static void sampling(uint32_t self_task) {
  vx_arena *a = vx_arena_new(40 << 20); // its own: the first capture's buffer fills the other
  CHECK(ctl("start sample rate 2000 size 4M") == VX_OK);
  busy(vx_now() + 200'000'000);
  CHECK(ctl("stop") == VX_OK);
  vx_fd ev = vx_open(VX_STR("/proc/trace/events"), VX_OREAD);
  vx_trace_record *r = vx_push(a, 32 << 20, 32);
  size_t bytes = 0;
  int64_t got;
  while (ev >= 0 && r && (got = vx_read(ev, (vx_bytes){(uint8_t *)r + bytes, (32 << 20) - bytes})) > 0)
    bytes += (size_t)got;
  vx_close(ev);
  uint64_t from = (uint64_t)(uintptr_t)&busy;
  uint32_t mine = 0, inside = 0, walked = 0;
  for (size_t i = 0; i < bytes / sizeof *r; i++) {
    if (r[i].kind != VX_TK_SAMPLE || tid_task(r[i].tid) != self_task || !(r[i].b >> 63)) continue;
    mine++;
    if (r[i].a >= from && r[i].a < from + 512) inside++, walked += (r[i].b & 0xff) > 0;
  }
  vx_printf("tracetest: %u samples, %u in busy\n", mine, inside);
  CHECK(mine >= 100);          // 2 kHz for 200 ms: 400, less what QEMU's timers lose
  CHECK(inside * 2 >= mine);   // most of them in busy
  CHECK(walked * 2 >= inside); // with its caller's frame
  vx_arena_free(a);
}

const char *vx_main(void) {
  if (vx_str_eq(vx_arg(1), VX_STR("child"))) { // the child: a line down its stdout, a pipe
    vx_sleep_until(vx_now() + 50'000'000, 0);  // after its parent waits: its write is the wake
    vx_printf("from the child\n");
    return nullptr;
  }
  vx_arena *a = vx_arena_new(64 << 20);
  vx_dir d;
  CHECK(vx_stat(VX_STR("/proc/trace/status"), a, &d) == VX_OK); // adm sees it
  CHECK(ctl("start sched,ipc,irq,vm,syscall,mark,span size 1M") == VX_OK);

  // A spawn and a pipe: the child writes, this process waits on its end.
  vx_handle pipe[2];
  CHECK(vx_channel_create(0, pipe) == VX_OK);
  vx_str args[] = {VX_STR("tracetest"), VX_STR("child")};
  vx_str names[] = {VX_STR("stdout")};
  vx_spawn_req req = {
      .path = vx_exe_path(), .args = {args, 2}, .handles = &pipe[1], .handle_names = names, .nhandles = 1};
  vx_proc kid = {};
  CHECK(vx_proc_spawn(&req, &kid) == VX_OK);
  vx_handle port;
  CHECK(vx_port_create(0, &port) == VX_OK && vx_port_bind(port, pipe[0], VX_TRIGGER_READABLE, 1, 0) == VX_OK);
  vx_packet pk;
  CHECK(vx_port_wait(port, vx_now() + 10'000'000'000, 0, &pk, 1) == 1);
  vx_proc_wait(kid, VX_INFINITE, a, nullptr);

  // A page fault on fsd: a file of the volume, mapped read-only and touched.
  vx_fd f = vx_open(VX_STR("/n/home/hello.txt"), VX_OREAD);
  void *m = nullptr;
  CHECK(f >= 0 && vx_map(f, 0, 4096, 0, &m) == VX_OK && m);
  uint64_t touched = (uint64_t)m;
  char first = m ? ((volatile char *)m)[0] : 0;
  CHECK(first != 0);
  char readback[16];
  CHECK(vx_pread(f, (vx_bytes){(uint8_t *)readback, sizeof readback}, 0) >
        0); // a 9Px read: fsd's span and ours
  // A write committed to the disk (a read may not reach it: fsd holds
  // the whole of this small volume), in the branch adm owns: through fsd
  // to the driver.
  vx_fd made = vx_create(VX_STR("/n/adm/traced"), VX_OWRITE, 0644);
  static char block[64 * 1024];
  memset(block, 'x', sizeof block);
  size_t wrote = 0; // one request each: fewer than asked is no error (file(2))
  for (int64_t w = 1; made >= 0 && wrote < sizeof block && w > 0; wrote += w > 0 ? (size_t)w : 0)
    w = vx_write(made, (vx_str){block + wrote, sizeof block - wrote});
  CHECK(wrote == sizeof block);
  CHECK(vx_sync(made) == VX_OK);
  vx_close(made);
  CHECK(ctl("mark tracetest end") == VX_OK);
  CHECK(ctl("stop") == VX_OK);

  // The records.
  vx_fd ev = vx_open(VX_STR("/proc/trace/events"), VX_OREAD);
  vx_trace_record *r = vx_push(a, 32 << 20, 32);
  size_t n = 0;
  int64_t got;
  size_t bytes = 0; // a read need not end on a record: counted in bytes
  while (ev >= 0 && r && (got = vx_read(ev, (vx_bytes){(uint8_t *)r + bytes, (32 << 20) - bytes})) > 0)
    bytes += (size_t)got;
  n = bytes / sizeof *r;
  vx_close(ev);
  vx_task_summary me;
  vx_task_info(vx_task_self(), &me);
  uint32_t self_task = (uint32_t)me.id, kid_task = (uint32_t)kid.pid;
  bool sw = false, wake_by_kid = false, blocked = false, fault = false, mark = false, kid_ran = false,
       spawned = false;
  for (size_t i = 0; i < n; i++) {
    sw = sw || r[i].kind == VX_TK_SWITCH;
    kid_ran = kid_ran || tid_task(r[i].tid) == kid_task;
    wake_by_kid = wake_by_kid || (r[i].kind == VX_TK_WAKE && tid_task((uint32_t)r[i].a) == self_task &&
                                  tid_task((uint32_t)r[i].b) == kid_task);
    blocked =
        blocked || (r[i].kind == VX_TK_BLOCK && tid_task(r[i].tid) == self_task && r[i].a == VX_TB_PORT);
    fault = fault || (r[i].kind == VX_TK_FAULT && r[i].a == touched && r[i].b == VX_TF_PAGER);
    mark = mark || (r[i].kind == VX_TK_MARK && memcmp(&r[i].a, "tracetest end", 13) == 0);
    spawned = spawned ||
              (r[i].kind == VX_TK_SYS_IN && r[i].a == VX_SYS_task_create && tid_task(r[i].tid) == self_task);
  }
  CHECK(n > 0 && sw && kid_ran && spawned);
  CHECK(blocked && wake_by_kid);
  CHECK(fault && mark);
  // Every wake's waker is 0 (a deadline) or a thread the trace saw run.
  bool wakers = true;
  for (size_t i = 0; i < n && wakers; i++) {
    if (r[i].kind != VX_TK_WAKE || !r[i].b) continue;
    bool seen = false;
    for (size_t j = 0; j < n && !seen; j++) seen = r[j].tid == (uint32_t)r[i].b;
    wakers = seen;
  }
  CHECK(wakers);
  // Flows (7a2): a 9Px request's span here and fsd's for it, by one flow;
  // a channel call's CALL and REPLY, by one flow.
  bool span_pair = false, call_pair = false;
  for (size_t i = 0; i < n && !span_pair; i++) {
    if (r[i].kind != VX_TK_SPAN || tid_task(r[i].tid) != self_task) continue;
    for (size_t j = 0; j < n && !span_pair; j++)
      span_pair = r[j].kind == VX_TK_SPAN && r[j].a == r[i].a && tid_task(r[j].tid) != self_task;
  }
  for (size_t i = 0; i < n && !call_pair; i++) {
    if (r[i].kind != VX_TK_CALL || !r[i].b) continue;
    for (size_t j = i + 1; j < n && !call_pair; j++) call_pair = r[j].kind == VX_TK_REPLY && r[j].b == r[i].b;
  }
  CHECK(span_pair);
  CHECK(call_pair);
  // The chain: this process, fsd (1), the driver (2: partd hands fsd the
  // driver's session, and is not on the way), and the disk's interrupt
  // within the driver's span.
  bool irq = false;
  size_t *at = vx_push(a, 2 * n * sizeof(size_t), alignof(size_t));
  int deepest = at ? chains(r, n, self_task, at, &irq) : 0;
  CHECK(deepest >= 2);
  CHECK(irq);
  // Ordered by time, and status says what ran.
  bool ordered = true;
  for (size_t i = 1; i < n; i++) ordered = ordered && r[i].time >= r[i - 1].time;
  CHECK(ordered);
  vx_fd st = vx_open(VX_STR("/proc/trace/status"), VX_OREAD);
  char text[4096];
  int64_t sl = st >= 0 ? vx_read(st, (vx_bytes){(uint8_t *)text, sizeof text}) : -1;
  CHECK(sl > 0 && vx_str_find((vx_str){text, (size_t)sl}, VX_STR("trace=off")) >= 0 &&
        vx_str_find((vx_str){text, (size_t)sl}, VX_STR("dropped=0")) >= 0);
  // trace(1) prints the same events as text, the mark among them; and
  // summarizes them (7a2c): the slowest flows and the longest blocks.
  CHECK(run_trace(a, VX_STR("-p"), VX_STR("kind=mark text=\"tracetest end\""), VX_STR("kind=switch")));
  CHECK(run_trace(a, VX_STR("-s"), VX_STR("slowest=flow flow=0x"), VX_STR("longest=block task=")));
  sampling(self_task);
  vx_printf("tracetest: %zu records\n", n);
  vx_printf("tracetest: %u checks, %u failed\n", checks, failures);
  return failures ? "failed" : nullptr;
}
