// ktest: the kernel's tests, run from user space as the root task when the
// kernel command line says vx.root=ktest (tests/qemu/ktest.ndb). Each check
// prints a line only when it fails; the last line counts them.

#include "../../lib/vx-rt/rt.c"
#include <stdatomic.h>

static uint32_t checks, failures;

static void check_at(bool ok, const char *what, int line) {
  checks++;
  if (ok) return;
  failures++;
  size_t n = 0;
  while (what[n]) n++;
  vx_print(VX_STR("ktest: FAILED line "));
  vx_print_u64((uint64_t)line);
  vx_print(VX_STR(": "));
  vx_print((vx_str){what, n});
  vx_print(VX_STR("\n"));
}

#define CHECK(cond) check_at((cond), #cond, __LINE__)

static vx_handle self;

static vx_instant after_ms(int64_t ms) { return vx_clock_read() + ms * 1'000'000; }

// --- Messages ---

typedef struct note {
  vx_msg_header h;
  char text[16];
} note;

static void test_channel_basics(void) {
  vx_handle ch[2];
  CHECK(vx_channel_create(0, ch) == VX_OK);
  note out = {.h = {.ordinal = 7}, .text = "hello"};
  CHECK(vx_channel_write(ch[0], &out, sizeof out, nullptr, 0) == VX_OK);

  vx_msg_size size;
  char tiny[8];
  CHECK(vx_channel_read(ch[1], tiny, sizeof tiny, nullptr, 0, &size) == VX_ERR_TOO_SMALL);
  CHECK(size.bytes == sizeof(note) && size.handles == 0);

  note in = {};
  CHECK(vx_channel_read(ch[1], &in, sizeof in, nullptr, 0, &size) == VX_OK);
  CHECK(size.bytes == sizeof(note));
  CHECK(in.h.ordinal == 7 && in.text[0] == 'h' && in.text[4] == 'o');
  CHECK(in.h.sender_intent == VX_INTENT_INTERACTIVE); // the kernel's, not the sender's
  CHECK(vx_channel_read(ch[1], &in, sizeof in, nullptr, 0, &size) == VX_ERR_SHOULD_WAIT);

  // A message shorter than a header, or a channel end sent through itself, is refused.
  CHECK(vx_channel_write(ch[0], &out, 4, nullptr, 0) == VX_ERR_INVALID);
  CHECK(vx_channel_write(ch[0], &out, sizeof out, &ch[0], 1) == VX_ERR_INVALID);

  // Closing one end: the other reads PEER_CLOSED and cannot write.
  CHECK(vx_handle_close(ch[0]) == VX_OK);
  CHECK(vx_channel_read(ch[1], &in, sizeof in, nullptr, 0, &size) == VX_ERR_PEER_CLOSED);
  CHECK(vx_channel_write(ch[1], &out, sizeof out, nullptr, 0) == VX_ERR_PEER_CLOSED);
  CHECK(vx_handle_close(ch[1]) == VX_OK);
}

static void test_handle_transfer(void) {
  vx_handle ch[2], c;
  CHECK(vx_channel_create(0, ch) == VX_OK);
  CHECK(vx_counter_create(5, &c) == VX_OK);
  note out = {.h = {.ordinal = 1}};
  CHECK(vx_channel_write(ch[0], &out, sizeof out, &c, 1) == VX_OK);
  CHECK(vx_counter_read(c) == VX_ERR_BAD_HANDLE); // it left the table

  note in;
  vx_handle got = 0;
  vx_msg_size size;
  CHECK(vx_channel_read(ch[1], &in, sizeof in, &got, 0, &size) == VX_ERR_TOO_SMALL && size.handles == 1);
  CHECK(vx_channel_read(ch[1], &in, sizeof in, &got, 1, &size) == VX_OK && size.handles == 1);
  CHECK(got != 0 && vx_counter_read(got) == 5);

  // A handle can be duplicated with fewer rights, never more.
  vx_handle weak;
  CHECK(vx_handle_dup(got, VX_RIGHT_READ, &weak) == VX_OK);
  CHECK(vx_counter_read(weak) == 5);
  CHECK(vx_counter_signal(weak, 9) == VX_ERR_ACCESS);
  vx_handle strong;
  CHECK(vx_handle_dup(weak, VX_RIGHT_READ | VX_RIGHT_SIGNAL, &strong) == VX_ERR_ACCESS);
  vx_handle_close(weak);
  vx_handle_close(got);
  vx_handle_close(ch[0]);
  vx_handle_close(ch[1]);
}

// --- Ports and bindings ---

static void test_bindings(void) {
  vx_handle port, ch[2], c;
  vx_packet pk[4];
  CHECK(vx_port_create(0, &port) == VX_OK);
  CHECK(vx_channel_create(0, ch) == VX_OK);

  // READABLE fires when a message arrives, once.
  CHECK(vx_port_bind(port, ch[1], VX_TRIGGER_READABLE, 11, 0) == VX_OK);
  CHECK(vx_port_wait(port, after_ms(1), 0, pk, 4) == VX_ERR_TIMED_OUT);
  note out = {};
  CHECK(vx_channel_write(ch[0], &out, sizeof out, nullptr, 0) == VX_OK);
  CHECK(vx_port_wait(port, after_ms(100), 0, pk, 4) == 1);
  CHECK(pk[0].key == 11 && pk[0].trigger == VX_TRIGGER_READABLE && pk[0].source == ch[1]);
  CHECK(vx_channel_write(ch[0], &out, sizeof out, nullptr, 0) == VX_OK);
  CHECK(vx_port_wait(port, after_ms(1), 0, pk, 4) == VX_ERR_TIMED_OUT); // one-shot

  // A binding whose condition already holds fires at once.
  CHECK(vx_port_bind(port, ch[1], VX_TRIGGER_READABLE, 12, 0) == VX_OK);
  CHECK(vx_port_wait(port, after_ms(100), 0, pk, 4) == 1 && pk[0].key == 12 && pk[0].value == 2);

  // PEER_CLOSED.
  CHECK(vx_port_bind(port, ch[1], VX_TRIGGER_PEER_CLOSED, 13, 0) == VX_OK);
  vx_handle_close(ch[0]);
  CHECK(vx_port_wait(port, after_ms(100), 0, pk, 4) == 1 && pk[0].key == 13);
  vx_handle_close(ch[1]);

  // COUNTER_GE fires when the counter reaches the threshold, with its value.
  CHECK(vx_counter_create(0, &c) == VX_OK);
  CHECK(vx_port_bind(port, c, VX_TRIGGER_COUNTER_GE, 14, 5) == VX_OK);
  CHECK(vx_counter_signal(c, 3) == VX_OK);
  CHECK(vx_port_wait(port, after_ms(1), 0, pk, 4) == VX_ERR_TIMED_OUT);
  CHECK(vx_counter_signal(c, 7) == VX_OK);
  CHECK(vx_port_wait(port, after_ms(100), 0, pk, 4) == 1 && pk[0].key == 14 && pk[0].value == 7);
  CHECK(vx_counter_signal(c, 6) == VX_OK && vx_counter_read(c) == 7); // never backwards

  // A trigger that does not fit the source is refused.
  CHECK(vx_port_bind(port, c, VX_TRIGGER_READABLE, 15, 0) == VX_ERR_INVALID);
  vx_handle_close(c);
  vx_handle_close(port);
}

// --- Threads, futexes and calls ---

// A stack for a thread in this task: a mapped VMO, returned as its top.
static uint64_t new_stack(void) {
  vx_handle vmo;
  uint64_t base = 0;
  if (vx_vmo_create(16ull * 1024, 0, &vmo) != VX_OK) return 0;
  if (vx_as_map(self, vmo, 0, 16ull * 1024, VX_MAP_WRITE, &base) != VX_OK) return 0;
  vx_handle_close(vmo); // the mapping keeps it
  return base + 16ull * 1024;
}

typedef struct shared {
  _Atomic uint32_t stage; // the main thread and the worker take turns through it
  vx_handle server_end;   // the worker serves calls on this channel end
} shared;

static void wait_for_stage(shared *s, uint32_t want) {
  for (uint32_t now; (now = atomic_load(&s->stage)) != want;) vx_futex_wait(&s->stage, now, after_ms(1000));
}

static void set_stage(shared *s, uint32_t to) {
  atomic_store(&s->stage, to);
  vx_futex_wake(&s->stage, 1);
}

typedef struct request {
  vx_msg_header h;
  uint64_t n;
} request;

// The second thread: a futex handshake, then a server answering two calls on
// its channel end (doubling the number), then an exit.
[[noreturn]] static void worker(vx_handle unused, uint64_t arg) {
  (void)unused;
  shared *s = (shared *)arg;
  wait_for_stage(s, 1);
  set_stage(s, 2);

  vx_handle port;
  vx_port_create(0, &port);
  for (int served = 0; served < 2;) {
    vx_packet pk;
    vx_port_bind(port, s->server_end, VX_TRIGGER_READABLE, 1, 0);
    if (vx_port_wait(port, after_ms(2000), 0, &pk, 1) != 1) break;
    request rq;
    vx_msg_size size;
    while (vx_channel_read(s->server_end, &rq, sizeof rq, nullptr, 0, &size) == VX_OK) {
      rq.n *= 2;
      vx_channel_write(s->server_end, &rq, sizeof rq, nullptr, 0); // the txid comes back as it came
      served++;
    }
  }
  vx_handle_close(port);
  set_stage(s, 3);
  vx_thread_exit(0);
}

static void test_threads_and_calls(void) {
  static shared s;
  vx_handle ch[2], th;
  CHECK(vx_channel_create(0, ch) == VX_OK);
  s.server_end = ch[1];
  uint64_t sp = new_stack();
  CHECK(sp != 0);
  CHECK(vx_thread_create(self, &th) == VX_OK);
  CHECK(vx_thread_start(th, (uint64_t)worker, sp, 0, (uint64_t)&s) == VX_OK);
  CHECK(vx_thread_start(th, (uint64_t)worker, sp, 0, (uint64_t)&s) == VX_ERR_BAD_STATE); // only once

  set_stage(&s, 1);
  wait_for_stage(&s, 2);
  CHECK(atomic_load(&s.stage) == 2);

  // A futex whose word already changed does not sleep.
  CHECK(vx_futex_wait(&s.stage, 99, after_ms(100)) == VX_ERR_BAD_STATE);

  for (uint64_t n = 21; n <= 22; n++) {
    request rq = {.n = n}, reply = {};
    vx_call call = {.wr_bytes = &rq, .wr_len = sizeof rq, .rd_bytes = &reply, .rd_cap = sizeof reply};
    CHECK(vx_channel_call(ch[0], &call, after_ms(2000)) == VX_OK);
    CHECK(reply.n == n * 2 && call.actual.bytes == sizeof reply);
    CHECK(reply.h.txid != 0 && (reply.h.txid & 0x8000'0000)); // the kernel's txid came back
  }
  wait_for_stage(&s, 3);
  CHECK(atomic_load(&s.stage) == 3);
  vx_handle_close(th);
  vx_handle_close(ch[0]);
  vx_handle_close(ch[1]);
}

// --- Child tasks ---
//
// Without an ELF loader in user space yet (M2, step 4), a child runs a few
// instructions written here for each architecture.

typedef enum child_code { EXIT_7, SPIN, BLOCK } child_code;

// Writes the child's code into `code`; returns its length in bytes.
static uint32_t write_child(uint8_t *code, child_code what) {
  uint32_t n = 0;
#ifdef __x86_64__
#define EMIT(b)   (code[n++] = (uint8_t)(b))
#define EMIT32(v) (EMIT(v), EMIT((v) >> 8), EMIT((v) >> 16), EMIT((v) >> 24))
  if (what == EXIT_7) {
    EMIT(0xbf), EMIT32(7);                  // mov $7, %edi
    EMIT(0xb8), EMIT32(VX_SYS_thread_exit); // mov $thread_exit, %eax
    EMIT(0x0f), EMIT(0x05);                 // syscall
  } else if (what == SPIN) {
    EMIT(0xeb), EMIT(0xfe); // jmp .
  } else {
    EMIT(0x48), EMIT(0x8d), EMIT(0x7c), EMIT(0x24), EMIT(0xf0);     // lea -16(%rsp), %rdi: a zero word
    EMIT(0x31), EMIT(0xf6);                                         // xor %esi, %esi: expect 0
    EMIT(0x48), EMIT(0xba), EMIT32(0xffffffff), EMIT32(0x7fffffff); // mov $INT64_MAX, %rdx
    EMIT(0xb8), EMIT32(VX_SYS_futex_wait);                          // mov $futex_wait, %eax
    EMIT(0x0f), EMIT(0x05);                                         // syscall
    EMIT(0xeb), EMIT(0xfe);                                         // jmp .
  }
#undef EMIT32
#undef EMIT
#else
#define EMIT(w)                                                                                              \
  (code[n] = (uint8_t)(w), code[n + 1] = (uint8_t)((w) >> 8), code[n + 2] = (uint8_t)((w) >> 16),            \
   code[n + 3] = (uint8_t)((w) >> 24), n += 4)
  if (what == EXIT_7) {
    EMIT(0xd2800000u | 7u << 5);                           // movz x0, #7
    EMIT(0xd2800008u | (uint32_t)VX_SYS_thread_exit << 5); // movz x8, #thread_exit
    EMIT(0xd4000001u);                                     // svc #0
  } else if (what == SPIN) {
    EMIT(0x14000000u); // b .
  } else {
    EMIT(0xd10043e0u);                                    // sub x0, sp, #16: a zero word
    EMIT(0xd2800001u);                                    // movz x1, #0: expect 0
    EMIT(0x92800002u);                                    // movn x2, #0: all ones
    EMIT(0xd341fc42u);                                    // lsr x2, x2, #1: INT64_MAX
    EMIT(0xd2800008u | (uint32_t)VX_SYS_futex_wait << 5); // movz x8, #futex_wait
    EMIT(0xd4000001u);                                    // svc #0
    EMIT(0x14000000u);                                    // b .
  }
#undef EMIT
#endif
  return n;
}

static constexpr uint64_t CHILD_CODE = 0x10'0000;
static constexpr uint64_t CHILD_STACK_TOP = 0x20'0000;

// A child task running `what`, started. *task gets a handle to it.
static bool start_child(child_code what, vx_handle *task) {
  uint8_t code[64] = {};
  uint32_t len = write_child(code, what);
  vx_handle text = 0, stack = 0, th = 0; // closing 0 is a harmless BAD_HANDLE
  uint64_t text_at = CHILD_CODE, stack_at = CHILD_STACK_TOP - 4096;
  bool ok = vx_task_create(VX_STR("child"), task) == VX_OK && vx_vmo_create(4096, 0, &text) == VX_OK &&
            vx_vmo_rw(text, VX_VMO_WRITE, 0, code, len) == VX_OK &&
            vx_as_map(*task, text, 0, 4096, VX_MAP_EXEC, &text_at) == VX_OK &&
            vx_vmo_create(4096, 0, &stack) == VX_OK &&
            vx_as_map(*task, stack, 0, 4096, VX_MAP_WRITE, &stack_at) == VX_OK &&
            vx_thread_create(*task, &th) == VX_OK &&
            vx_thread_start(th, CHILD_CODE, CHILD_STACK_TOP, 0, 0) == VX_OK;
  vx_handle_close(text);
  vx_handle_close(stack);
  vx_handle_close(th);
  return ok;
}

// Waits for a task's EXIT binding; returns its exit status, or INT64_MIN.
static int64_t wait_exit(vx_handle port, vx_handle task) {
  vx_packet pk;
  if (vx_port_bind(port, task, VX_TRIGGER_EXIT, 99, 0) != VX_OK) return INT64_MIN;
  if (vx_port_wait(port, after_ms(2000), 0, &pk, 1) != 1 || pk.key != 99) return INT64_MIN;
  return (int64_t)pk.value;
}

static void test_tasks(void) {
  vx_handle port, child;
  vx_task_summary info;
  CHECK(vx_port_create(0, &port) == VX_OK);

  // A child that exits on its own: its status is the task's, and it is torn down.
  CHECK(start_child(EXIT_7, &child));
  CHECK(wait_exit(port, child) == 7);
  CHECK(vx_task_info(child, &info) == VX_OK);
  CHECK(info.state == VX_TASK_EXITED && info.exit_status == 7 && info.threads == 0 && info.mapped == 0);
  vx_handle late;
  CHECK(vx_thread_create(child, &late) == VX_ERR_BAD_STATE); // an ended task takes no threads
  vx_handle_close(child);

  // A child spinning in user mode, perhaps on another CPU, is killed.
  CHECK(start_child(SPIN, &child));
  CHECK(vx_task_info(child, &info) == VX_OK && info.state == VX_TASK_RUNNING && info.threads == 1);
  CHECK(vx_task_kill(child, 99) == VX_OK);
  CHECK(wait_exit(port, child) == 99);
  vx_handle_close(child);

  // A child blocked in the kernel is killed too: its wait ends with KILLED.
  CHECK(start_child(BLOCK, &child));
  vx_instant later = after_ms(20);
  vx_packet pk;
  vx_port_wait(port, later, 0, &pk, 1); // give it time to block
  CHECK(vx_task_kill(child, 55) == VX_OK);
  CHECK(wait_exit(port, child) == 55);
  vx_handle_close(child);

  // A task that never ran ends at once when killed, and its binding fires.
  CHECK(vx_task_create(VX_STR("idle"), &child) == VX_OK);
  CHECK(vx_task_kill(child, 3) == VX_OK);
  CHECK(wait_exit(port, child) == 3);
  vx_handle_close(child);
  vx_handle_close(port);
}

// A chain of channel ends, each queued in a message on the next, closed from
// the top: the kernel destroys it one end at a time, never recursing, so no
// depth can overflow its stack.
static void test_nested_channels(void) {
  vx_handle chain = 0;
  bool built = true;
  for (int i = 0; i < 1000 && built; i++) {
    vx_handle ch[2];
    note n = {};
    built = vx_channel_create(0, ch) == VX_OK;
    if (built && chain) built = vx_channel_write(ch[0], &n, sizeof n, &chain, 1) == VX_OK;
    vx_handle_close(ch[0]); // ch[1] keeps the queue, and the rest of the chain with it
    chain = ch[1];
  }
  CHECK(built);
  CHECK(vx_handle_close(chain) == VX_OK);
}

static void test_vmo_rw(void) {
  vx_handle vmo;
  char in[8] = "abcdefg", out[8] = {};
  CHECK(vx_vmo_create(8192, 0, &vmo) == VX_OK);
  CHECK(vx_vmo_rw(vmo, VX_VMO_WRITE, 4092, in, 8) == VX_OK); // across a page boundary
  CHECK(vx_vmo_rw(vmo, VX_VMO_READ, 4092, out, 8) == VX_OK);
  CHECK(out[0] == 'a' && out[6] == 'g');
  CHECK(vx_vmo_rw(vmo, VX_VMO_READ, 8190, out, 8) == VX_ERR_RANGE);
  vx_handle_close(vmo);
}

int vx_main(vx_handle task) {
  self = task;
  test_channel_basics();
  test_handle_transfer();
  test_bindings();
  test_threads_and_calls();
  test_tasks();
  test_nested_channels();
  test_vmo_rw();
  vx_print(VX_STR("ktest: "));
  vx_print_u64(checks);
  vx_print(VX_STR(" checks, "));
  vx_print_u64(failures);
  if (failures)
    vx_print(VX_STR(" FAILED\n"));
  else
    vx_print(VX_STR(" failed\n"));
  vx_handle port;
  vx_port_create(0, &port);
  for (;;) {
    vx_packet pk;
    vx_port_wait(port, VX_INFINITE, 0, &pk, 1);
  }
}
