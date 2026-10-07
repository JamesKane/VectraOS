// ktest: the kernel's tests, run from user space as the root task when the
// kernel command line says vx.root=ktest (tests/qemu/ktest.ndb). Each check
// prints a line only when it fails; the last line counts them.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ring/ring.c"
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
  vx_thread_exit();
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

  // A call that times out takes back the request nobody read: the server
  // never sees it.
  request rq = {.n = 5}, reply = {};
  vx_call call = {.wr_bytes = &rq, .wr_len = sizeof rq, .rd_bytes = &reply, .rd_cap = sizeof reply};
  CHECK(vx_channel_call(ch[0], &call, after_ms(5)) == VX_ERR_TIMED_OUT);
  vx_msg_size size;
  CHECK(vx_channel_read(ch[1], &rq, sizeof rq, nullptr, 0, &size) == VX_ERR_SHOULD_WAIT);
  vx_handle_close(ch[0]);
  vx_handle_close(ch[1]);
}

// --- Child tasks ---
//
// Without an ELF loader in user space yet (M2, step 4), a child runs a few
// instructions written here for each architecture.

typedef enum child_code {
  EXIT_7,
  SPIN,
  BLOCK,
  PORT_BLOCK,
  USE_SIMD,
  READ_LOOP,
  FAULT_LOAD,
  BREAK_STEP,
  BREAK_SYSCALL, // a breakpoint, then a syscall (clock_read), then exit 7: a stepped syscall
  ROBUST_HOLD    // registers a robust list at CHILD_DATA (owner 0x1234), then as BLOCK
} child_code;

static constexpr uint64_t CHILD_DATA = 0x30'0000; // FAULT_LOAD's page, which nothing maps at first

// Writes the child's code into `code`; returns its length in bytes.
static uint32_t write_child(uint8_t *code, child_code what) {
  uint32_t n = 0;
#ifdef __x86_64__
#define EMIT(b)   (code[n++] = (uint8_t)(b))
#define EMIT32(v) (EMIT(v), EMIT((v) >> 8), EMIT((v) >> 16), EMIT((v) >> 24))
  if (what == USE_SIMD) {
    EMIT(0x66), EMIT(0x0f), EMIT(0xef), EMIT(0xc0); // pxor %xmm0, %xmm0
    EMIT(0xc5), EMIT(0xfd), EMIT(0xef), EMIT(0xc0); // vpxor %ymm0, %ymm0, %ymm0: AVX too (XSAVE), then exit 7
    what = EXIT_7;
  }
  if (what == BREAK_STEP) {
    EMIT(0xcc); // int3: a breakpoint, then exit 7
    what = EXIT_7;
  }
  if (what == BREAK_SYSCALL) {
    EMIT(0xb8), EMIT32(VX_SYS_clock_read); // mov $clock_read, %eax
    EMIT(0xcc);                            // int3
    EMIT(0x0f), EMIT(0x05);                // syscall, then exit 7
    what = EXIT_7;
  }
  if (what == ROBUST_HOLD) {
    EMIT(0xbf), EMIT32(CHILD_DATA);               // mov $CHILD_DATA, %edi: the list's head
    EMIT(0xbe), EMIT32(24);                       // mov $24, %esi
    EMIT(0xba), EMIT32(0x1234);                   // mov $0x1234, %edx: its owner value
    EMIT(0xb8), EMIT32(VX_SYS_thread_set_robust); // mov $thread_set_robust, %eax
    EMIT(0x0f), EMIT(0x05);                       // syscall, then wait for ever
    what = BLOCK;
  }
  if (what == EXIT_7) {
    EMIT(0xbf), EMIT32(7);                  // mov $7, %edi
    EMIT(0xb8), EMIT32(VX_SYS_thread_exit); // mov $thread_exit, %eax
    EMIT(0x0f), EMIT(0x05);                 // syscall
  } else if (what == SPIN) {
    EMIT(0xeb), EMIT(0xfe); // jmp .
  } else if (what == READ_LOOP) {
    EMIT(0x48), EMIT(0x8b), EMIT(0x44), EMIT(0x24),
        EMIT(0xf8);         // 1: mov -8(%rsp), %rax: a load from its stack
    EMIT(0xeb), EMIT(0xf9); // jmp 1b, with no system call
  } else if (what == FAULT_LOAD) {
    EMIT(0x48), EMIT(0xb8), EMIT32(CHILD_DATA), EMIT32(0); // movabs $CHILD_DATA, %rax
    EMIT(0x48), EMIT(0x8b), EMIT(0x10);                    // mov (%rax), %rdx: faults until it is mapped
    EMIT(0x48), EMIT(0x89), EMIT(0xc6);                    // mov %rax, %rsi: what it loaded,
    EMIT(0xba), EMIT32(1);                                 // mov $1, %edx: its first byte,
    EMIT(0x45), EMIT(0x31), EMIT(0xd2);                    // xor %r10d, %r10d
    EMIT(0xb8), EMIT32(VX_SYS_task_kill);                  // mov $task_kill, %eax: is its exit string
    EMIT(0x0f), EMIT(0x05);                                // syscall (%rdi: its handle to itself)
    EMIT(0xeb), EMIT(0xfe);                                // jmp ., until the kill takes it
  } else if (what == PORT_BLOCK) {
    EMIT(0x48), EMIT(0x8d), EMIT(0x74), EMIT(0x24), EMIT(0xf0);     // lea -16(%rsp), %rsi: the handle's place
    EMIT(0x31), EMIT(0xff);                                         // xor %edi, %edi: no options
    EMIT(0xb8), EMIT32(VX_SYS_port_create);                         // mov $port_create, %eax
    EMIT(0x0f), EMIT(0x05);                                         // syscall
    EMIT(0x8b), EMIT(0x7c), EMIT(0x24), EMIT(0xf0);                 // mov -16(%rsp), %edi: the port
    EMIT(0x48), EMIT(0xbe), EMIT32(0xffffffff), EMIT32(0x7fffffff); // mov $INT64_MAX, %rsi: no deadline
    EMIT(0x31), EMIT(0xd2);                                         // xor %edx, %edx: no leeway
    EMIT(0x4c), EMIT(0x8d), EMIT(0x54), EMIT(0x24), EMIT(0xc0);     // lea -64(%rsp), %r10: a packet's place
    EMIT(0x41), EMIT(0xb8), EMIT32(1);                              // mov $1, %r8d
    EMIT(0xb8), EMIT32(VX_SYS_port_wait);                           // mov $port_wait, %eax
    EMIT(0x0f), EMIT(0x05);                                         // syscall
    EMIT(0xeb), EMIT(0xfe);                                         // jmp .
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
  if (what == USE_SIMD) {
    EMIT(0x9e6703e0u); // fmov d0, xzr, then exit 7
    what = EXIT_7;
  }
  if (what == BREAK_STEP) {
    EMIT(0xd4200020u); // brk #1: a breakpoint, then exit 7
    what = EXIT_7;
  }
  if (what == BREAK_SYSCALL) {
    EMIT(0xd2800008u | (uint32_t)VX_SYS_clock_read << 5); // movz x8, #clock_read
    EMIT(0xd4200020u);                                    // brk #1
    EMIT(0xd4000001u);                                    // svc #0, then exit 7
    what = EXIT_7;
  }
  if (what == ROBUST_HOLD) {
    EMIT(0xd2a00000u | (uint32_t)(CHILD_DATA >> 16) << 5);       // movz x0, #CHILD_DATA >> 16, lsl #16
    EMIT(0xd2800001u | 24u << 5);                                // movz x1, #24
    EMIT(0xd2800002u | 0x1234u << 5);                            // movz x2, #0x1234: its owner value
    EMIT(0xd2800008u | (uint32_t)VX_SYS_thread_set_robust << 5); // movz x8, #thread_set_robust
    EMIT(0xd4000001u);                                           // svc #0, then wait for ever
    what = BLOCK;
  }
  if (what == EXIT_7) {
    EMIT(0xd2800000u | 7u << 5);                           // movz x0, #7
    EMIT(0xd2800008u | (uint32_t)VX_SYS_thread_exit << 5); // movz x8, #thread_exit
    EMIT(0xd4000001u);                                     // svc #0
  } else if (what == SPIN) {
    EMIT(0x14000000u); // b .
  } else if (what == READ_LOOP) {
    EMIT(0xf85f83e0u); // 1: ldur x0, [sp, #-8]: a load from its stack
    EMIT(0x17ffffffu); // b 1b, with no system call
  } else if (what == FAULT_LOAD) {
    EMIT(0xd2a00001u | (uint32_t)(CHILD_DATA >> 16) << 5); // movz x1, #CHILD_DATA >> 16, lsl #16
    EMIT(0xf9400022u);                                     // ldr x2, [x1]: faults until it is mapped
    EMIT(0xd2800022u);                                     // movz x2, #1: what it loaded, its first byte,
    EMIT(0xd2800003u);                                     // movz x3, #0
    EMIT(0xd2800008u | (uint32_t)VX_SYS_task_kill << 5);   // movz x8, #task_kill: is its exit string
    EMIT(0xd4000001u);                                     // svc #0 (x0: its handle to itself)
    EMIT(0x14000000u);                                     // b ., until the kill takes it
  } else if (what == PORT_BLOCK) {
    EMIT(0xd10043e1u);                                     // sub x1, sp, #16: the handle's place
    EMIT(0xd2800000u);                                     // movz x0, #0: no options
    EMIT(0xd2800008u | (uint32_t)VX_SYS_port_create << 5); // movz x8, #port_create
    EMIT(0xd4000001u);                                     // svc #0
    EMIT(0xb85f03e0u);                                     // ldur w0, [sp, #-16]: the port
    EMIT(0x92800001u);                                     // movn x1, #0
    EMIT(0xd341fc21u);                                     // lsr x1, x1, #1: INT64_MAX, no deadline
    EMIT(0xd2800002u);                                     // movz x2, #0: no leeway
    EMIT(0xd10103e3u);                                     // sub x3, sp, #64: a packet's place
    EMIT(0xd2800024u);                                     // movz x4, #1
    EMIT(0xd2800008u | (uint32_t)VX_SYS_port_wait << 5);   // movz x8, #port_wait
    EMIT(0xd4000001u);                                     // svc #0
    EMIT(0x14000000u);                                     // b .
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

// Waits until every thread of the task is blocked in the kernel (task_info
// counts them). False if it has not happened within a second.
static bool wait_blocked(vx_handle task) {
  for (int i = 0; i < 1000; i++) {
    vx_task_summary info;
    if (vx_task_info(task, &info) == VX_OK && info.threads && info.blocked == info.threads) return true;
    static _Atomic uint32_t never;
    vx_futex_wait(&never, 0, after_ms(1)); // a millisecond's nap
  }
  return false;
}

// A child task running `what`, started, with its faults going to exc_port if
// that is not 0 (bound before it starts), data's first page mapped at
// CHILD_DATA if data is not 0, and a handle to itself as its first argument.
// *task gets a handle to it.
static bool start_child_mapped(child_code what, vx_handle exc_port, uint32_t options, vx_handle data,
                               vx_handle *task) {
  uint8_t code[64] = {};
  uint32_t len = write_child(code, what);
  vx_handle text = 0, stack = 0, th = 0, itself = 0; // closing 0 is a harmless BAD_HANDLE
  uint64_t text_at = CHILD_CODE, stack_at = CHILD_STACK_TOP - 4096, data_at = CHILD_DATA;
  bool ok =
      vx_task_create(VX_STR("child"), task) == VX_OK && vx_vmo_create(4096, 0, &text) == VX_OK &&
      vx_vmo_rw(text, VX_VMO_WRITE, 0, code, len) == VX_OK &&
      vx_as_map(*task, text, 0, 4096, VX_MAP_EXEC, &text_at) == VX_OK &&
      vx_vmo_create(4096, 0, &stack) == VX_OK &&
      vx_as_map(*task, stack, 0, 4096, VX_MAP_WRITE, &stack_at) == VX_OK &&
      (!data || vx_as_map(*task, data, 0, 4096, what == ROBUST_HOLD ? VX_MAP_WRITE : 0, &data_at) == VX_OK) &&
      (!exc_port || vx_exception_bind(*task, exc_port, 5, options) == VX_OK) &&
      vx_thread_create(*task, &th) == VX_OK && vx_handle_dup(*task, VX_RIGHTS_SAME, &itself) == VX_OK &&
      vx_thread_start(th, CHILD_CODE, CHILD_STACK_TOP, itself, 0) == VX_OK;
  if (!ok) vx_handle_close(itself); // otherwise the child's
  vx_handle_close(text);
  vx_handle_close(stack);
  vx_handle_close(th);
  return ok;
}

static bool start_child_bound(child_code what, vx_handle exc_port, uint32_t options, vx_handle *task) {
  return start_child_mapped(what, exc_port, options, 0, task);
}

static bool start_child(child_code what, vx_handle *task) { return start_child_bound(what, 0, 0, task); }

// Waits for a task's EXIT binding; returns its exit string (ADR-0010), or
// nullptr if it did not end. The string lasts until the next call.
static const char *wait_exit(vx_handle port, vx_handle task) {
  static char exit[VX_ERRMAX + 1];
  vx_packet pk;
  vx_task_summary info;
  if (vx_port_bind(port, task, VX_TRIGGER_EXIT, 99, 0) != VX_OK) return nullptr;
  if (vx_port_wait(port, after_ms(2000), 0, &pk, 1) != 1 || pk.key != 99) return nullptr;
  if (vx_task_info(task, &info) != VX_OK || info.exit_len != pk.value) return nullptr;
  memcpy(exit, info.exit, info.exit_len);
  exit[info.exit_len] = 0;
  return exit;
}

// Whether s begins with prefix (both C strings; s may be null).
static bool starts(const char *s, const char *prefix) {
  if (!s) return false;
  size_t n = vx_cstr(prefix).len;
  return vx_cstr(s).len >= n && memcmp(s, prefix, n) == 0;
}

// Whether s is want.
static bool is(const char *s, const char *want) {
  return starts(s, want) && vx_cstr(s).len == vx_cstr(want).len;
}

static void test_tasks(void) {
  vx_handle port, child;
  vx_task_summary info;
  CHECK(vx_port_create(0, &port) == VX_OK);

  // A child whose thread exits on its own ends with the empty exit string
  // (success), and is torn down.
  CHECK(start_child(EXIT_7, &child));
  CHECK(is(wait_exit(port, child), ""));
  CHECK(vx_task_info(child, &info) == VX_OK);
  CHECK(info.state == VX_TASK_EXITED && info.exit_len == 0 && info.threads == 0 && info.mapped == 0);
  vx_handle late;
  CHECK(vx_thread_create(child, &late) == VX_ERR_BAD_STATE); // an ended task takes no threads
  vx_handle_close(child);

  // A child spinning in user mode, perhaps on another CPU, is killed.
  CHECK(start_child(SPIN, &child));
  CHECK(vx_task_info(child, &info) == VX_OK && info.state == VX_TASK_RUNNING && info.threads == 1);
  CHECK(vx_task_kill(child, VX_STR("killed while spinning")) == VX_OK);
  CHECK(is(wait_exit(port, child), "killed while spinning"));
  vx_handle_close(child);

  // A child blocked in the kernel is killed too: its wait ends with KILLED.
  CHECK(start_child(BLOCK, &child));
  CHECK(wait_blocked(child)); // in futex_wait, so the kill is of a blocked thread
  CHECK(vx_task_kill(child, VX_STR("killed while blocked")) == VX_OK);
  CHECK(is(wait_exit(port, child), "killed while blocked"));
  vx_handle_close(child);

  // A task that never ran ends at once when killed, and its binding fires.
  CHECK(vx_task_create(VX_STR("idle"), &child) == VX_OK);
  CHECK(vx_task_kill(child, VX_STR("killed before it ran")) == VX_OK);
  CHECK(is(wait_exit(port, child), "killed before it ran"));
  vx_handle_close(child);

  // An exit string is at most VX_ERRMAX bytes.
  CHECK(vx_task_create(VX_STR("idle"), &child) == VX_OK);
  static const char long_msg[VX_ERRMAX + 1] = {};
  CHECK(vx_task_kill(child, (vx_str){long_msg, sizeof long_msg}) == VX_ERR_RANGE);
  CHECK(vx_task_kill(child, VX_STR("")) == VX_OK && is(wait_exit(port, child), ""));
  vx_handle_close(child);

  // A note to a task with no note handler ends it, with the note as its exit
  // string, as in Plan 9 (ADR-0010).
  CHECK(start_child(SPIN, &child));
  CHECK(vx_thread_interrupt(child, 0, VX_STR("")) == VX_ERR_INVALID);
  CHECK(vx_thread_interrupt(child, 0, (vx_str){long_msg, sizeof long_msg}) == VX_ERR_INVALID);
  CHECK(vx_thread_interrupt(child, 0, VX_STR("interrupt")) == VX_OK);
  CHECK(is(wait_exit(port, child), "interrupt"));
  CHECK(vx_thread_interrupt(child, 0, VX_STR("again")) == VX_ERR_BAD_STATE); // it has ended
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

// --- Rings ---

// Sleeps about a millisecond: a futex wait on a word that never changes.
static void nap(void) {
  static _Atomic uint32_t never;
  vx_futex_wait(&never, 0, after_ms(1));
}

// Sleeps until this end's doorbell rings, unless an entry arrived while it was
// getting ready (the protocol vx-check proves; tests/host/ring_model_test.c).
static void ring_sleep(vx_ring *r, vx_handle end, vx_handle port) {
  int64_t seen = vx_counter_read(end);
  if (vx_ring_prepare_sleep(r)) {
    vx_packet pk;
    vx_port_bind(port, end, VX_TRIGGER_COUNTER_GE, 1, (uint64_t)seen + 1);
    vx_port_wait(port, after_ms(2000), 0, &pk, 1);
  }
  vx_ring_end_sleep(r);
}

enum { OP_DOUBLE = 1, OP_COUNTER = 2, OP_STOP = 3 };

typedef struct ring_shared {
  vx_ring server;
  vx_handle end;
  _Atomic uint32_t stage;
} ring_shared;

// The server: answers OP_DOUBLE with twice its target, OP_COUNTER with the
// value of the counter whose handle came in the entry's slot, and stops at OP_STOP.
[[noreturn]] static void ring_server(vx_handle unused, uint64_t arg) {
  (void)unused;
  ring_shared *s = (ring_shared *)arg;
  vx_handle port;
  vx_port_create(0, &port);
  for (bool stop = false; !stop;) {
    vx_sqe in;
    if (vx_ring_consume(&s->server, &in) != VX_OK) {
      ring_sleep(&s->server, s->end, port);
      continue;
    }
    vx_cqe out = {.user_data = in.user_data};
    if (in.opcode == OP_DOUBLE) {
      out.result = (int64_t)in.target * 2;
    } else if (in.opcode == OP_COUNTER && (in.flags & VX_SQE_HANDLES)) {
      vx_handle got = 0;
      out.result = vx_ring_take_handles(s->end, in.handle_slot, &got, 1) == 1 ? vx_counter_read(got) : -1;
      vx_handle_close(got);
    } else {
      stop = true;
    }
    vx_cqe *slot;
    while (!(slot = vx_ring_produce_slot(&s->server))) nap(); // CQ full: let the client drain it
    *slot = out;
    if (vx_ring_produce(&s->server)) vx_ring_notify(s->end);
  }
  vx_handle_close(port);
  atomic_store(&s->stage, 1);
  vx_futex_wake(&s->stage, 1);
  vx_thread_exit();
}

// Submits an entry, waiting for room if the SQ is full.
static void ring_submit(vx_ring *r, vx_handle end, const vx_sqe *e) {
  vx_sqe *slot;
  while (!(slot = vx_ring_produce_slot(r))) nap(); // SQ full: let the server drain it
  *slot = *e;
  if (vx_ring_produce(r)) vx_ring_notify(end);
}

static void test_rings(void) {
  vx_ring_handles h;
  CHECK(vx_ring_create(&(vx_ring_params){3, 16, 64, 32, 0, 0}, &h) == VX_ERR_INVALID);
  static const vx_ring_params params = {16, 16, 64, 32, 4096, 4096};
  CHECK(vx_ring_create(&params, &h) == VX_OK);
  uint64_t base = 0, size;
  vx_ring_header layout;
  vx_ring_layout(&params, &layout);
  size = layout.size;
  CHECK(vx_as_map(self, h.memory, 0, size, VX_MAP_WRITE, &base) == VX_OK);

  static ring_shared s;
  vx_ring client;
  CHECK(vx_ring_attach(&client, (void *)base, size, true, &params) == VX_OK);
  CHECK(vx_ring_attach(&s.server, (void *)base, size, false, &params) == VX_OK);
  s.end = h.server;
  vx_handle th;
  CHECK(vx_thread_create(self, &th) == VX_OK);
  CHECK(vx_thread_start(th, (uint64_t)ring_server, new_stack(), 0, (uint64_t)&s) == VX_OK);

  // 200 requests through 16-entry queues: both sides wrap, and both sleep and wake.
  vx_handle port;
  vx_port_create(0, &port);
  uint64_t sent = 0, done = 0;
  bool right = true;
  while (done < 200) {
    if (sent < 200 && sent - done < 16) {
      ring_submit(&client, h.client, &(vx_sqe){.opcode = OP_DOUBLE, .user_data = sent, .target = sent});
      sent++;
      continue;
    }
    vx_cqe c;
    if (vx_ring_consume(&client, &c) == VX_OK) {
      right = right && c.user_data == done && c.result == (int64_t)done * 2;
      done++;
    } else {
      ring_sleep(&client, h.client, port);
    }
  }
  CHECK(right);

  // A handle through the side channel.
  vx_handle counter;
  CHECK(vx_counter_create(33, &counter) == VX_OK);
  int64_t slot = vx_ring_put_handles(h.client, &counter, 1);
  CHECK(slot >= 0);
  CHECK(vx_counter_read(counter) == VX_ERR_BAD_HANDLE); // it left our table
  ring_submit(
      &client, h.client,
      &(vx_sqe){
          .opcode = OP_COUNTER, .flags = VX_SQE_HANDLES, .user_data = 500, .handle_slot = (uint32_t)slot});
  vx_cqe c = {};
  while (vx_ring_consume(&client, &c) != VX_OK) ring_sleep(&client, h.client, port);
  CHECK(c.user_data == 500 && c.result == 33);
  CHECK(vx_ring_take_handles(h.server, 15, &counter, 1) == VX_ERR_INVALID); // an empty slot

  // Stop the server, then its end goes: the client sees PEER_CLOSED.
  ring_submit(&client, h.client, &(vx_sqe){.opcode = OP_STOP});
  while (atomic_load(&s.stage) != 1) vx_futex_wait(&s.stage, 0, after_ms(100));
  vx_handle_close(th);
  CHECK(vx_handle_close(h.server) == VX_OK);
  vx_packet pk;
  CHECK(vx_port_bind(port, h.client, VX_TRIGGER_PEER_CLOSED, 7, 0) == VX_OK);
  CHECK(vx_port_wait(port, after_ms(100), 0, &pk, 1) == 1 && pk.key == 7);
  CHECK(vx_ring_notify(h.client) == VX_ERR_PEER_CLOSED);
  vx_handle_close(h.client);
  vx_handle_close(h.memory);
  vx_handle_close(port);
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

// What svcd checked at M1 (04 §5): a port wait ends at its deadline and not
// before, a self-posted packet is the next thing a wait returns, and a VMO
// mapped where the kernel chooses is zeroed, writable, and stays mapped after
// its handle closes.
static void test_m1_basics(void) {
  vx_handle port;
  CHECK(vx_port_create(0, &port) == VX_OK);
  vx_packet got[4];
  vx_instant start = vx_clock_read(), deadline = start + 10'000'000;
  CHECK(vx_port_wait(port, deadline, 0, got, 4) == VX_ERR_TIMED_OUT);
  CHECK(vx_clock_read() >= deadline);
  CHECK(vx_port_post(port, &(vx_packet){.key = 42, .value = 7}) == VX_OK);
  CHECK(vx_port_wait(port, VX_INFINITE, 0, got, 4) == 1 && got[0].key == 42 && got[0].value == 7 &&
        got[0].trigger == VX_TRIGGER_USER);
  vx_handle_close(port);

  vx_handle vmo;
  uint64_t addr = 0;
  CHECK(vx_vmo_create(64ull * 1024, 0, &vmo) == VX_OK);
  CHECK(vx_as_map(self, vmo, 0, 64ull * 1024, VX_MAP_WRITE, &addr) == VX_OK);
  volatile uint64_t *words = (volatile uint64_t *)addr;
  CHECK(words[0] == 0 && words[8191] == 0);
  words[0] = 0x5678;
  words[8191] = 0x1234;
  CHECK(vx_handle_close(vmo) == VX_OK); // the mapping keeps it
  CHECK(words[0] == 0x5678 && words[8191] == 0x1234);
}

// The kernel's spawn message for the root task (root.c): its name, a handle
// to itself, the boot image, and the command line that chose ktest.
static void test_spawn_message(void) {
  CHECK(vx_self != VX_HANDLE_NONE);
  CHECK(vx_spawn.name.len == 5 && memcmp(vx_spawn.name.ptr, "ktest", 5) == 0);
  bool found = false;
  for (size_t i = 0; i + 13 <= vx_spawn.cmdline.len; i++)
    if (memcmp(vx_spawn.cmdline.ptr + i, "vx.root=ktest", 13) == 0) found = true;
  CHECK(found);
  vx_handle image = vx_spawn_take("bootimage");
  CHECK(image != VX_HANDLE_NONE && vx_spawn_take("bootimage") == VX_HANDLE_NONE);
  uint8_t magic[6] = {};
  CHECK(vx_vmo_rw(image, VX_VMO_READ, 257, magic, 5) == VX_OK && memcmp(magic, "ustar", 5) == 0);
  CHECK(vx_vmo_rw(image, VX_VMO_WRITE, 0, magic, 1) == VX_ERR_ACCESS); // read-only
  vx_handle_close(image);
}

// Device objects from the root Resource (01 §7.1). ktest stays away from the
// console's own device, which would take the console from the kernel.
static void test_devices(void) {
  vx_handle res = vx_spawn_take("resource"), weak, h, h2;
  CHECK(res != VX_HANDLE_NONE);
  CHECK(vx_handle_dup(res, VX_RIGHT_DUPLICATE | VX_RIGHT_INSPECT, &weak) == VX_OK);
#ifdef __x86_64__
  static constexpr uint32_t SPARE_LINE = 3;                        // ISA IRQ 3: COM2, which nothing uses
  static constexpr uint64_t DEVICE = 0xfed0'0000, RAM = 0x10'0000; // the HPET; RAM at 1 MiB
#else
  static constexpr uint32_t SPARE_LINE = 40;                         // an SPI no device has
  static constexpr uint64_t DEVICE = 0x0901'0000, RAM = 0x4000'0000; // the PL031 RTC; the start of RAM
#endif

  CHECK(vx_irq_create(weak, SPARE_LINE, &h) == VX_ERR_ACCESS); // no MANAGE
  CHECK(vx_irq_create(res, 5000, &h) == VX_ERR_RANGE);
#ifdef __aarch64__
  CHECK(vx_irq_create(res, 27, &h) == VX_ERR_RANGE); // a PPI: the kernel's timer
#endif
  CHECK(vx_irq_create(res, SPARE_LINE, &h) == VX_OK);
  CHECK(vx_irq_create(res, SPARE_LINE, &h2) == VX_ERR_EXISTS); // one Irq a line
  vx_handle port;
  vx_packet pk;
  CHECK(vx_port_create(0, &port) == VX_OK);
  CHECK(vx_port_bind(port, h, VX_TRIGGER_COUNTER_GE, 1, 1) == VX_ERR_INVALID);
  CHECK(vx_port_bind(port, h, VX_TRIGGER_IRQ, 1, 0) == VX_OK);
  CHECK(vx_port_wait(port, after_ms(2), 0, &pk, 1) == VX_ERR_TIMED_OUT); // nothing raises the line
  CHECK(vx_irq_ack(h) == VX_OK);
  CHECK(vx_irq_ack(port) == VX_ERR_BAD_HANDLE); // not an Irq
  vx_handle_close(port);
  vx_handle_close(h);
  CHECK(vx_irq_create(res, SPARE_LINE, &h) == VX_OK); // free again once its Irq is gone
  vx_handle_close(h);

  CHECK(vx_vmo_create_physical(res, RAM, 4096, &h) == VX_ERR_ACCESS); // never RAM
  CHECK(vx_vmo_create_physical(res, DEVICE + 1, 4096, &h) == VX_ERR_RANGE);
  CHECK(vx_vmo_create_physical(weak, DEVICE, 4096, &h) == VX_ERR_ACCESS);
  CHECK(vx_vmo_create_physical(res, DEVICE, 4096, &h) == VX_OK);
  uint32_t word = 0;
  CHECK(vx_vmo_rw(h, VX_VMO_READ, 0, &word, 4) == VX_ERR_UNSUPPORTED); // map it instead
  uint64_t at = 0;
  CHECK(vx_as_map(self, h, 0, 4096, 0, &at) == VX_OK);
  word = ((volatile uint32_t *)at)[0]; // HPET: capabilities and revision; PL031: the time
  CHECK(word != 0 && word != 0xffff'ffff);
  // A futex in device memory: refused (the kernel has no direct mapping of it to read).
  CHECK(vx_futex_wait((const _Atomic uint32_t *)at, word, after_ms(1)) == VX_ERR_INVALID);
  vx_handle_close(h);

#ifdef __x86_64__
  CHECK(vx_iorange_create(res, 0xfff0, 0x20, &h) == VX_ERR_RANGE);
  CHECK(vx_iorange_create(res, 0x2f8, 8, &h) == VX_OK); // COM2's ports
  CHECK(vx_as_map(self, h, 0, 4096, 0, &at) == VX_ERR_INVALID);
  CHECK(vx_as_map(self, h, 0, 0, 0, &at) == VX_OK);
  uint8_t lsr;
  __asm__ volatile("inb %1, %0" : "=a"(lsr) : "Nd"((uint16_t)0x2fd)); // faults unless the port is ours
  CHECK(true);
  vx_handle_close(h);
#else
  CHECK(vx_iorange_create(res, 0x2f8, 8, &h) == VX_ERR_UNSUPPORTED);
#endif
  // MSIs: picked by the kernel, for a PCI function (00:03.0 here, by requester ID).
  vx_msi msi, msi2;
  vx_handle m1, m2;
  CHECK(vx_irq_create_msi(weak, 0x18, &h, &msi) == VX_ERR_ACCESS);
  CHECK(vx_irq_create_msi(res, 0x18, &m1, &msi) == VX_OK && msi.address != 0);
  CHECK(vx_irq_create_msi(res, 0x18, &m2, &msi2) == VX_OK);
  CHECK(msi2.address == msi.address && msi2.data != msi.data); // one target; another vector or event
#ifdef __x86_64__
  CHECK((msi.address & 0xfff0'0000) == 0xfee0'0000);
#endif
  CHECK(vx_port_create(0, &port) == VX_OK);
  CHECK(vx_port_bind(port, m1, VX_TRIGGER_IRQ, 1, 0) == VX_OK);
  CHECK(vx_port_wait(port, after_ms(2), 0, &pk, 1) == VX_ERR_TIMED_OUT); // no device writes it
  vx_handle_close(port);
  vx_handle_close(m1);
  vx_handle_close(m2);
  CHECK(vx_irq_create_msi(res, 0x18, &m1, &msi2) == VX_OK && msi2.data == msi.data); // freed, so given again
  vx_handle_close(m1);

  // A DMA domain (pass-through), for one function: device addresses for a
  // VMO's pages, a mapping for each range, what the device may do as the
  // VMO handle allows.
  vx_handle dom, mem, ro, map1, map2, user;
  uint64_t addrs[4] = {};
  CHECK(vx_dma_domain_create(weak, 0x18, &dom) == VX_ERR_ACCESS);
  CHECK(vx_dma_domain_create(res, 0x1'0000, &dom) == VX_ERR_INVALID); // no such requester ID
  CHECK(vx_dma_domain_create(res, 0x18, &dom) == VX_OK);
  CHECK(vx_vmo_create(16ull * 1024, 0, &mem) == VX_OK);
  CHECK(vx_dma_map(dom, mem, 4096, 16ull * 1024, VX_DMA_READ, addrs, &map1) == VX_ERR_RANGE);
  CHECK(vx_dma_map(dom, mem, 0, 4096, 0, addrs, &map1) == VX_ERR_INVALID); // the device must do something
  CHECK(vx_handle_dup(mem, VX_RIGHT_READ | VX_RIGHT_MAP, &ro) == VX_OK);
  CHECK(vx_dma_map(dom, ro, 0, 4096, VX_DMA_WRITE, addrs, &map1) == VX_ERR_ACCESS); // a read-only handle
  CHECK(vx_dma_map(dom, ro, 0, 4096, VX_DMA_READ, addrs, &map1) == VX_OK); // the device reads it: fine
  CHECK(vx_dma_unmap(map1) == VX_OK);
  vx_handle_close(ro);
  CHECK(vx_dma_map(dom, mem, 0, 16ull * 1024, VX_DMA_READ | VX_DMA_WRITE, addrs, &map1) == VX_OK);
  CHECK(addrs[0] && addrs[3] && !(addrs[0] & 4095) && addrs[0] != addrs[1]);
  // Through the IOMMU (QEMU's intel-iommu or SMMUv3, always): the domain's
  // own addresses, contiguous, from 4 GiB.
  CHECK(addrs[1] == addrs[0] + 4096 && addrs[3] == addrs[0] + 3ull * 4096 && addrs[0] >= 1ull << 32);
  CHECK(vx_vmo_create_physical(res, DEVICE, 4096, &h) == VX_OK);
  CHECK(vx_dma_map(dom, h, 0, 4096, VX_DMA_READ, addrs, &map2) == VX_ERR_UNSUPPORTED); // not RAM, yet
  vx_handle_close(h);
  CHECK(vx_syscall(VX_SYS_dma_unmap, map1, 0, 0, 0, 0, 0) == VX_OK);
  CHECK(vx_syscall(VX_SYS_dma_unmap, map1, 0, 0, 0, 0, 0) == VX_ERR_BAD_STATE); // once
  vx_handle_close(map1);
  // A driver's duplicate maps, and sees faults; it cannot revoke.
  CHECK(vx_handle_dup(dom, VX_RIGHT_MAP | VX_RIGHT_WAIT | VX_RIGHT_INSPECT, &user) == VX_OK);
  CHECK(vx_dma_map(user, mem, 0, 8192, VX_DMA_READ | VX_DMA_WRITE, addrs, &map1) == VX_OK);
  CHECK(vx_dma_map(user, mem, 8192, 4096, VX_DMA_WRITE, addrs, &map2) == VX_OK);
  CHECK(vx_dma_domain_op(user, VX_DMA_REVOKE) == VX_ERR_ACCESS);
  CHECK(vx_dma_domain_op(user, VX_DMA_FAULTS) == 0);
  CHECK(vx_port_create(0, &port) == VX_OK);
  CHECK(vx_port_bind(port, user, VX_TRIGGER_DMA_FAULT, 9, 0) == VX_OK);
  CHECK(vx_port_wait(port, after_ms(2), 0, &pk, 1) == VX_ERR_TIMED_OUT); // pass-through: no faults
  vx_handle_close(port);
  // Its owner revokes: the driver can unmap nothing now (its pages are kept
  // for the device), until the owner says the device is quiet.
  vx_handle_close(map2); // closed without an unmap: kept for the device
  CHECK(vx_dma_domain_op(dom, VX_DMA_REVOKE) == VX_OK);
  CHECK(vx_syscall(VX_SYS_dma_unmap, map1, 0, 0, 0, 0, 0) == VX_ERR_BAD_STATE);
  CHECK(vx_dma_domain_op(dom, VX_DMA_QUIESCED) == VX_OK); // both let go
  CHECK(vx_syscall(VX_SYS_dma_unmap, map1, 0, 0, 0, 0, 0) == VX_ERR_BAD_STATE);
  vx_handle_close(map1);
  CHECK(vx_dma_map(user, mem, 0, 4096, VX_DMA_READ, addrs, &map1) == VX_OK); // the domain goes on
  vx_handle_close(user);
  vx_handle_close(mem);
  vx_handle_close(dom); // the mapping keeps it, and is kept until QUIESCED: a leak no one can see but this
  vx_handle_close(map1);

  vx_handle_close(weak);
  vx_handle_close(res);
}

// Review fixes (M3): a killed task's freed tables are never used, and a
// mapping that collides with another fails without taking a page from it.
static void test_torn_down(void) {
  vx_handle port, child, th, vmo, ch[2];
  CHECK(vx_port_create(0, &port) == VX_OK);
  CHECK(vx_task_create(VX_STR("doomed"), &child) == VX_OK);
  CHECK(vx_thread_create(child, &th) == VX_OK); // made before the kill, started after
  CHECK(vx_task_kill(child, VX_STR("doomed")) == VX_OK);
  CHECK(is(wait_exit(port, child), "doomed")); // torn down: no threads ever ran
  CHECK(vx_vmo_create(4096, 0, &vmo) == VX_OK);
  uint64_t at = 0;
  CHECK(vx_as_map(child, vmo, 0, 4096, 0, &at) == VX_ERR_BAD_STATE); // its mapping table is gone
  CHECK(vx_channel_create(0, ch) == VX_OK);
  CHECK(vx_thread_start(th, 0x40'0000, 0x50'0000, ch[0], 0) != VX_OK); // and its handle table
  vx_handle_close(ch[1]);
  vx_handle_close(th);
  vx_handle_close(child);

  // A thread's entry and stack must be user addresses: a non-canonical entry
  // would fault in the kernel on its way to user mode.
  CHECK(vx_task_create(VX_STR("bad entry"), &child) == VX_OK);
  CHECK(vx_thread_create(child, &th) == VX_OK);
  CHECK(vx_thread_start(th, 0x8000'0000'0000'0000, 0x50'0000, 0, 0) == VX_ERR_INVALID);
  CHECK(vx_thread_start(th, 0x40'0000, 0xffff'8000'0000'0000, 0, 0) == VX_ERR_INVALID);
  CHECK(vx_thread_start(th, 0x0000'8000'0000'0000, 0x50'0000, 0, 0) == VX_ERR_INVALID); // just past the top
  vx_task_kill(child, VX_STR(""));
  vx_handle_close(th);
  vx_handle_close(child);

  // vmo (one page) where the kernel puts it; then two pages ending on it:
  // refused, and the first page is still there.
  uint64_t a = 0;
  vx_handle two;
  CHECK(vx_as_map(self, vmo, 0, 4096, VX_MAP_WRITE, &a) == VX_OK);
  volatile uint64_t *spot = (volatile uint64_t *)a;
  *spot = 0x1234;
  uint64_t b = a - 4096; // free: the kernel leaves a guard page before what it places
  CHECK(vx_vmo_create(8192, 0, &two) == VX_OK);
  CHECK(vx_as_map(self, two, 0, 8192, VX_MAP_WRITE, &b) != VX_OK);
  CHECK(*spot == 0x1234); // would fault if the failed map took the page
  b = a - 4096;
  CHECK(vx_as_map(self, two, 0, 4096, VX_MAP_WRITE, &b) == VX_OK); // the page it did map was taken back
  vx_handle_close(two);
  vx_handle_close(vmo);
  vx_handle_close(port);
}

// Review fixes (M3): port waiters. A waiter that times out does not cut off
// the waiter behind it, and a kill ends a task waiting on a port.
typedef struct port_pair {
  vx_handle port;
  _Atomic uint32_t stage;
  int64_t got; // what the second waiter's port_wait returned
} port_pair;

[[noreturn]] static void second_waiter(vx_handle unused, uint64_t arg) {
  (void)unused;
  port_pair *pp = (port_pair *)arg;
  while (atomic_load(&pp->stage) != 1) vx_futex_wait(&pp->stage, 0, after_ms(100));
  vx_packet pk;
  pp->got = vx_port_wait(pp->port, after_ms(2000), 0, &pk, 1); // queued behind the first waiter
  atomic_store(&pp->stage, 2);
  vx_futex_wake(&pp->stage, 1);
  vx_thread_exit();
}

static void test_port_waiters(void) {
  static port_pair pp;
  vx_handle th;
  vx_packet pk;
  CHECK(vx_port_create(0, &pp.port) == VX_OK);
  CHECK(vx_thread_create(self, &th) == VX_OK);
  CHECK(vx_thread_start(th, (uint64_t)second_waiter, new_stack(), 0, (uint64_t)&pp) == VX_OK);
  atomic_store(&pp.stage, 1);
  vx_futex_wake(&pp.stage, 1);
  CHECK(vx_port_wait(pp.port, after_ms(30), 0, &pk, 1) == VX_ERR_TIMED_OUT); // first in line, gives up
  CHECK(vx_port_post(pp.port, &(vx_packet){.key = 5}) == VX_OK);
  for (int i = 0; i < 100 && atomic_load(&pp.stage) != 2; i++) vx_futex_wait(&pp.stage, 1, after_ms(10));
  CHECK(pp.got == 1); // woken by the post, not by its 2 s deadline
  vx_handle_close(th);
  vx_handle_close(pp.port);

  // A port closed with fired bindings in it, many times over: the path that
  // used to leak each port (its fired binding kept it alive). A leak itself
  // does not show from here: ktest cannot see the kernel's free memory.
  vx_handle counter;
  CHECK(vx_counter_create(1, &counter) == VX_OK);
  bool all = true;
  for (int i = 0; i < 2000 && all; i++) {
    vx_handle p;
    all = vx_port_create(0, &p) == VX_OK && vx_port_bind(p, counter, VX_TRIGGER_COUNTER_GE, 1, 0) == VX_OK &&
          vx_handle_close(p) == VX_OK;
  }
  CHECK(all);
  vx_handle_close(counter);

  vx_handle port, child;
  CHECK(vx_port_create(0, &port) == VX_OK);
  // FP/SIMD runs in user tasks (test_fp: each thread keeps its own).
  CHECK(start_child(USE_SIMD, &child));
  CHECK(is(wait_exit(port, child), ""));
  vx_handle_close(child);
  CHECK(start_child(PORT_BLOCK, &child));
  CHECK(wait_blocked(child)); // in port_wait
  CHECK(vx_task_kill(child, VX_STR("killed in port_wait")) == VX_OK);
  CHECK(is(wait_exit(port, child), "killed in port_wait")); // the kill ends the wait
  vx_handle_close(child);
  vx_handle_close(port);
}

// as_unmap: whole mappings and parts of them, the hole mapped again, and the
// pages gone for the kernel's copies too.
static void test_unmap(void) {
  static constexpr uint64_t PAGE = 4096;
  vx_handle v;
  uint64_t at = 0;
  bool mapped =
      vx_vmo_create(4 * PAGE, 0, &v) == VX_OK && vx_as_map(self, v, 0, 4 * PAGE, VX_MAP_WRITE, &at) == VX_OK;
  CHECK(mapped);
  if (!mapped || !at) return;
  for (int p = 0; p < 4; p++) ((volatile uint8_t *)at)[p * PAGE] = (uint8_t)(p + 1);
  CHECK(vx_as_unmap(self, at + PAGE, PAGE + 1) == VX_ERR_RANGE); // pages only
  CHECK(vx_as_unmap(self, at + PAGE, 2 * PAGE) == VX_OK);        // the middle: two mappings now
  uint8_t byte;
  CHECK(vx_vmo_rw(v, VX_VMO_READ, 0, (void *)(at + PAGE), 1) == VX_ERR_INVALID); // gone for the kernel too
  CHECK(vx_vmo_rw(v, VX_VMO_READ, 0, (void *)(at + 2 * PAGE + 100), 1) == VX_ERR_INVALID);
  CHECK(((volatile uint8_t *)at)[0] == 1 && ((volatile uint8_t *)at)[3 * PAGE] == 4); // the ends stay
  CHECK(vx_as_unmap(self, at + PAGE, 2 * PAGE) == VX_OK);                             // nothing there: fine
  uint64_t hole = at + PAGE;
  CHECK(vx_as_map(self, v, 4096, 2 * PAGE, VX_MAP_WRITE, &hole) == VX_OK && hole == at + PAGE);
  CHECK(((volatile uint8_t *)hole)[0] == 2 && ((volatile uint8_t *)hole)[PAGE] == 3); // the VMO kept them
  CHECK(vx_vmo_rw(v, VX_VMO_READ, 0, &byte, 1) == VX_OK && byte == 1);
  CHECK(vx_as_unmap(self, at, 4 * PAGE) == VX_OK); // all three mappings at once
  CHECK(vx_vmo_rw(v, VX_VMO_READ, 0, (void *)at, 1) == VX_ERR_INVALID);
  vx_handle_close(v);

  // Every CPU loses the translations: a child spinning on loads from its stack
  // page, with no system call to switch its tables, faults once the page is
  // unmapped. Without the shootdown it would read on, from a cached entry; that
  // shows under TCG (and so always on aarch64), as KVM flushes a guest's TLB
  // on its own often enough to hide it.
  vx_handle port, child;
  CHECK(vx_port_create(0, &port) == VX_OK);
  CHECK(start_child(READ_LOOP, &child));
  static _Atomic uint32_t never;
  vx_futex_wait(&never, 0, after_ms(50)); // it is spinning, on another CPU
  CHECK(vx_as_unmap(child, CHILD_STACK_TOP - 4096, 4096) == VX_OK);
  CHECK(starts(wait_exit(port, child), "sys: trap: fault read addr=0x1ffff")); // killed by the fault
  vx_handle_close(child);
  vx_handle_close(port);
}

// Kernel copies that lose their page part-way fail, and the kernel goes on: one
// thread unmaps and maps a page again and again while another copies into it.
typedef struct copy_race {
  _Atomic bool stop;
  vx_handle vmo;
  uint64_t page;
  _Atomic uint32_t ok, invalid, other;
} copy_race;

static void copy_racer(uint64_t arg, uint64_t arg2) {
  (void)arg;
  copy_race *r = (copy_race *)arg2;
  static uint8_t src[4096];
  while (!atomic_load(&r->stop)) {
    vx_status st = vx_vmo_rw(r->vmo, VX_VMO_READ, 0, (void *)r->page, sizeof src);
    if (st == VX_OK)
      atomic_fetch_add(&r->ok, 1);
    else if (st == VX_ERR_INVALID)
      atomic_fetch_add(&r->invalid, 1);
    else
      atomic_fetch_add(&r->other, 1);
  }
  vx_thread_exit();
}

static void test_copy_race(void) {
  static copy_race r;
  vx_handle target = 0;
  r.page = 0;
  CHECK(vx_vmo_create(4096, 0, &r.vmo) == VX_OK && vx_vmo_create(4096, 0, &target) == VX_OK);
  CHECK(vx_as_map(self, target, 0, 4096, VX_MAP_WRITE, &r.page) == VX_OK);
  vx_handle th;
  CHECK(vx_thread_create(self, &th) == VX_OK);
  CHECK(vx_thread_start(th, (uint64_t)copy_racer, new_stack(), 0, (uint64_t)&r) == VX_OK);
  bool mapped = true, all = true;
  for (int i = 0; i < 20000; i++) {
    uint64_t at = r.page;
    if (mapped)
      all = all && vx_as_unmap(self, at, 4096) == VX_OK;
    else
      all = all && vx_as_map(self, target, 0, 4096, VX_MAP_WRITE, &at) == VX_OK && at == r.page;
    mapped = !mapped;
  }
  CHECK(all);
  atomic_store(&r.stop, true);
  static _Atomic uint32_t never;
  vx_futex_wait(&never, 0, after_ms(20));
  CHECK(atomic_load(&r.other) == 0 && atomic_load(&r.ok) + atomic_load(&r.invalid) > 0);
  if (!mapped) vx_as_map(self, target, 0, 4096, VX_MAP_WRITE, &r.page);
  vx_handle_close(th);
}

// --- Exceptions (obj/exception.c) ---

// A page at a child's address, holding one word.
static bool map_child_word(vx_handle child, uint64_t at, uint64_t value) {
  vx_handle v = 0;
  bool ok = vx_vmo_create(4096, 0, &v) == VX_OK &&
            vx_vmo_rw(v, VX_VMO_WRITE, 0, &value, sizeof value) == VX_OK &&
            vx_as_map(child, v, 0, 4096, 0, &at) == VX_OK;
  vx_handle_close(v);
  return ok;
}

// The packet for a child's fault, at its exception port.
static bool child_stopped(vx_handle port) {
  vx_packet pk;
  return vx_port_wait(port, after_ms(2000), 0, &pk, 1) == 1 && pk.trigger == VX_TRIGGER_EXCEPTION &&
         pk.key == 5 && pk.value == 1;
}

static void test_exception_port(void) {
  vx_handle port, child;
  CHECK(vx_port_create(0, &port) == VX_OK);
  // A child's fault stops it at its port; the port's holder reads what
  // happened, maps the page it missed, and continues it: the load is retried.
  CHECK(start_child_bound(FAULT_LOAD, port, 0, &child));
  CHECK(child_stopped(port));
  vx_exception e = {};
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_EXCEPTION, &e, sizeof e) == VX_OK);
  CHECK(e.kind == VX_EXCEPTION_PAGE_FAULT && e.address == CHILD_DATA && e.code == 0 && e.thread == 1);
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_EXCEPTION, &e, 8) == VX_ERR_TOO_SMALL);
  CHECK(vx_thread_state(child, 2, VX_STATE_GET_EXCEPTION, &e, sizeof e) == VX_ERR_NOT_FOUND);
  CHECK(map_child_word(child, CHILD_DATA, 7));
  CHECK(vx_exception_resume(child, 1, VX_RESUME_CONTINUE, nullptr) == VX_OK);
  CHECK(vx_exception_resume(child, 1, VX_RESUME_CONTINUE, nullptr) != VX_OK); // once
  CHECK(is(wait_exit(port, child), "\x07"));                                  // it exits with what it loaded
  vx_handle_close(child);

  // Its registers can be changed before it continues: the load goes elsewhere.
  CHECK(start_child_bound(FAULT_LOAD, port, 0, &child));
  CHECK(child_stopped(port));
  vx_regs regs;
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_REGS, &regs, sizeof regs) == VX_OK);
#ifdef __x86_64__
  CHECK(regs.rax == CHILD_DATA);
  regs.rax = CHILD_DATA + 4096;
  vx_regs bad = regs;
  bad.rip = 0xffff'8000'0000'0000; // a kernel address: refused
#else
  CHECK(regs.x[1] == CHILD_DATA);
  regs.x[1] = CHILD_DATA + 4096;
  vx_regs bad = regs;
  bad.pc = 0xffff'8000'0000'0000;
#endif
  CHECK(vx_thread_state(child, 1, VX_STATE_SET_REGS, &bad, sizeof bad) == VX_ERR_INVALID);
  CHECK(vx_thread_state(child, 1, VX_STATE_SET_REGS, &regs, sizeof regs) == VX_OK);
  CHECK(map_child_word(child, CHILD_DATA + 4096, 9));
  CHECK(vx_exception_resume(child, 1, VX_RESUME_CONTINUE, nullptr) == VX_OK);
  CHECK(is(wait_exit(port, child), "\x09"));
  vx_handle_close(child);

  // Or it can be killed. (STEP and PASS are a debugger's, from its own port.)
  CHECK(start_child_bound(FAULT_LOAD, port, 0, &child));
  CHECK(child_stopped(port));
  CHECK(vx_exception_resume(child, 1, VX_RESUME_STEP, nullptr) == VX_ERR_BAD_STATE);
  CHECK(vx_exception_resume(child, 1, VX_RESUME_PASS, nullptr) == VX_ERR_BAD_STATE);
  CHECK(vx_exception_resume(child, 1, VX_RESUME_KILL, nullptr) == VX_OK);
  CHECK(starts(wait_exit(port, child), "sys: trap: fault read addr=0x300000 pc=")); // the fault's default
  vx_handle_close(child);

  // A kill reaches a thread stopped at its port.
  CHECK(start_child_bound(FAULT_LOAD, port, 0, &child));
  CHECK(child_stopped(port));
  CHECK(vx_task_kill(child, VX_STR("killed at its port")) == VX_OK);
  CHECK(is(wait_exit(port, child), "killed at its port"));
  vx_handle_close(child);
  vx_handle_close(port);
}

static vx_handle missing; // what the in-task handler maps where a fault was
static _Atomic uint32_t handled[VX_EXCEPTION_REVOKED + 1], interrupted_thread;
static char interrupt_note[VX_ERRMAX + 1]; // the note the last interrupt carried

static vx_handle late_pager, late_vmo, late_src; // what the handler supplies a late page from
static _Atomic uint32_t pager_timeouts;
static _Atomic uint32_t key_faults, key_fault_key, key_fault_code; // PROTECTION_KEY's, test_keys

static uint64_t guard_at; // a no-access page the handler opens when touched (test_address_space)
static _Atomic uint32_t guard_faults;
static vx_handle revoked_spare; // what the handler maps where a revoked lease was (test_leases)
static _Atomic uint64_t revoked_at;

static void handler(vx_exception *e) {
  if (e->kind <= VX_EXCEPTION_REVOKED) atomic_fetch_add(&handled[e->kind], 1);
  if (e->kind == VX_EXCEPTION_PROTECTION_KEY) { // seen, then the key given: the access made again
    atomic_fetch_add(&key_faults, 1);
    atomic_store(&key_fault_key, e->key);
    atomic_store(&key_fault_code, e->code);
    e->rights &= ~(3ull << (2 * e->key));
  } else if (e->kind ==
             VX_EXCEPTION_PAGER_TIMEOUT) { // the page, late: supplied now, and the access made again
    atomic_fetch_add(&pager_timeouts, 1);
    vx_pager_supply(late_pager, late_vmo, 0, 4096, late_src, 0);
  } else if (e->kind == VX_EXCEPTION_REVOKED) { // the lease's page swapped for a spare: the load made again
    uint64_t at = e->address & ~4095ull;
    atomic_store(&revoked_at, e->address);
    vx_as_unmap(vx_self, at, 4096);
    vx_as_map(vx_self, revoked_spare, 0, 4096, 0, &at);
  } else if (e->kind == VX_EXCEPTION_PAGE_FAULT && guard_at && (e->address & ~4095ull) == guard_at) {
    atomic_fetch_add(&guard_faults, 1); // a no-access page touched: opened, and the access made again
    vx_as_protect(vx_self, guard_at, 4096, VX_MAP_WRITE);
  } else if (e->kind == VX_EXCEPTION_PAGE_FAULT) {
    uint64_t at = e->address & ~4095ull;
    vx_as_map(vx_self, missing, 0, 4096, 0, &at); // then the load is retried
  } else if (e->kind == VX_EXCEPTION_BREAKPOINT) {
#ifdef __aarch64__
    e->regs.pc += 4; // brk stops at itself; int3 has already been stepped past
#endif
  } else if (e->kind == VX_EXCEPTION_INTERRUPT) {
    memcpy(interrupt_note, e->note, e->code < VX_ERRMAX ? e->code : VX_ERRMAX);
    interrupt_note[e->code < VX_ERRMAX ? e->code : VX_ERRMAX] = 0;
    atomic_store(&interrupted_thread, e->thread);
  }
  vx_rights_set(e->rights); // the kernel opened key 0 for the handler (ADR-0035): the thread's own, back
  vx_exception_resume(vx_self, 0, VX_RESUME_CONTINUE, &e->regs);
}

typedef struct waiter {
  _Atomic uint32_t word;
  _Atomic int64_t result;
  _Atomic bool done;
} waiter;

static void interrupted_waiter(uint64_t arg, uint64_t arg2) {
  (void)arg;
  waiter *w = (waiter *)arg2;
  atomic_store(&w->result, vx_futex_wait(&w->word, 0, VX_INFINITE)); // no deadline: only an interrupt ends it
  atomic_store(&w->done, true);
  vx_thread_exit();
}

static void test_in_task(void) {
  static _Atomic uint32_t never;
  CHECK(vx_exception_bind(self, 0, (uint64_t)handler, VX_EXCEPTION_IN_TASK) == VX_OK);
  // A page fault, handled by mapping the page: the load is retried, and sees it.
  uint64_t value = 0x1234'5678, at = 0;
  vx_handle probe;
  CHECK(vx_vmo_create(4096, 0, &missing) == VX_OK && vx_vmo_rw(missing, VX_VMO_WRITE, 0, &value, 8) == VX_OK);
  CHECK(vx_vmo_create(4096, 0, &probe) == VX_OK && vx_as_map(self, probe, 0, 4096, 0, &at) == VX_OK);
  CHECK(vx_as_unmap(self, at, 4096) == VX_OK); // an address nothing maps now
  vx_handle_close(probe);
  CHECK(at && *(volatile uint64_t *)at == 0x1234'5678);
  CHECK(atomic_load(&handled[VX_EXCEPTION_PAGE_FAULT]) == 1);
  CHECK(vx_as_unmap(self, at, 4096) == VX_OK);
  vx_handle_close(missing);
  // A breakpoint, stepped past.
#ifdef __x86_64__
  __asm__ volatile("int3");
#else
  __asm__ volatile("brk #7");
#endif
  CHECK(atomic_load(&handled[VX_EXCEPTION_BREAKPOINT]) == 1);
  // An interrupt wakes a call that would wait for ever, and goes to the handler
  // on the way out.
  static waiter w;
  vx_handle th;
  uint32_t id = 0;
  CHECK(vx_thread_create_id(self, &th, &id) == VX_OK && id > 1);
  CHECK(vx_thread_start(th, (uint64_t)interrupted_waiter, new_stack(), 0, (uint64_t)&w) == VX_OK);
  vx_futex_wait(&never, 0, after_ms(30)); // it is waiting
  CHECK(vx_thread_interrupt(self, id, VX_STR("wake up")) == VX_OK);
  for (int i = 0; i < 1000 && !atomic_load(&w.done); i++) vx_futex_wait(&never, 0, after_ms(1));
  CHECK(atomic_load(&w.done) && atomic_load(&w.result) == VX_ERR_INTERRUPTED);
  CHECK(atomic_load(&handled[VX_EXCEPTION_INTERRUPT]) == 1 && atomic_load(&interrupted_thread) == id &&
        is(interrupt_note, "wake up"));
  CHECK(vx_thread_interrupt(self, 999, VX_STR("nobody")) == VX_ERR_NOT_FOUND);
  vx_handle_close(th);
  CHECK(vx_exception_bind(self, 0, 0, VX_EXCEPTION_IN_TASK) == VX_OK); // unbound: a note would end ktest now
}

// --- Robust futexes (ADR-0037) ---

static vx_handle root_resource(void); // below, with the pagers

typedef struct robust_head {
  uint64_t next;
  int64_t offset;
  uint64_t pending;
} robust_head;

typedef struct robust_entry {
  uint64_t next;
  _Atomic uint32_t word;
} robust_entry;

static robust_head exit_head;
static robust_entry exit_held, exit_other; // the thread's lock, and one another owner holds

static void robust_exiter(uint64_t arg, uint64_t arg2) {
  (void)arg, (void)arg2;
  vx_thread_set_robust(&exit_head, sizeof exit_head, 77);
  vx_thread_exit(); // holding exit_held
}

typedef struct robust_waiter {
  const _Atomic uint32_t *word;
  uint32_t expected;
  _Atomic int64_t result;
  _Atomic bool done;
} robust_waiter;

static void robust_wait(uint64_t arg, uint64_t arg2) {
  (void)arg;
  robust_waiter *w = (robust_waiter *)arg2;
  atomic_store(&w->result, vx_futex_wait(w->word, w->expected, after_ms(3000)));
  atomic_store(&w->done, true);
  vx_thread_exit();
}

static bool robust_waited(robust_waiter *w) {
  static _Atomic uint32_t never;
  for (int i = 0; i < 3000 && !atomic_load(&w->done); i++) vx_futex_wait(&never, 0, after_ms(1));
  return atomic_load(&w->done);
}

static void test_robust(void) {
  static _Atomic uint32_t never;
  constexpr uint32_t W = VX_FUTEX_WAITERS, DIED = VX_FUTEX_OWNER_DIED;
  // Refusals.
  CHECK(vx_thread_set_robust(&exit_head, 16, 77) == VX_ERR_INVALID);
  CHECK(vx_thread_set_robust(&exit_head, 24, 0) == VX_ERR_INVALID);
  CHECK(vx_thread_set_robust((const uint8_t *)&exit_head + 4, 24, 77) == VX_ERR_INVALID);
  CHECK(vx_thread_set_robust(nullptr, 0, 0) == VX_OK);

  // A thread that exits holding a lock: OWNER_DIED, waiters kept; a lock it
  // lists but another owns is left alone.
  exit_head = (robust_head){.next = (uint64_t)&exit_held, .offset = offsetof(robust_entry, word)};
  exit_held.next = (uint64_t)&exit_other;
  exit_other.next = (uint64_t)&exit_head;
  atomic_store(&exit_held.word, 77 | W);
  atomic_store(&exit_other.word, 78);
  vx_handle th = 0;
  CHECK(vx_thread_create(self, &th) == VX_OK &&
        vx_thread_start(th, (uint64_t)robust_exiter, new_stack(), 0, 0) == VX_OK);
  vx_status st = vx_futex_wait(&exit_held.word, 77 | W, after_ms(3000));
  CHECK(st == VX_OK || st == VX_ERR_BAD_STATE); // woken, or it had gone already
  CHECK(atomic_load(&exit_held.word) == (W | DIED) && atomic_load(&exit_other.word) == 78);
  vx_handle_close(th);

  // A task killed holding a lock in a VMO it shares: the waiter here, on the
  // same word through its own mapping, is woken (one futex: keyed by VMO).
  vx_handle shared = 0, child = 0;
  uint64_t at = 0;
  CHECK(vx_vmo_create(4096, 0, &shared) == VX_OK &&
        vx_as_map(self, shared, 0, 4096, VX_MAP_WRITE, &at) == VX_OK);
  if (!at) return;
  robust_head *h = (robust_head *)at;
  robust_entry *e = (robust_entry *)(at + 64);
  *h =
      (robust_head){.next = CHILD_DATA + 64, .offset = offsetof(robust_entry, word)}; // the child's addresses
  e->next = CHILD_DATA;
  atomic_store(&e->word, 0x1234 | W);
  static robust_waiter w;
  w = (robust_waiter){.word = &e->word, .expected = 0x1234 | W};
  CHECK(vx_thread_create(self, &th) == VX_OK &&
        vx_thread_start(th, (uint64_t)robust_wait, new_stack(), 0, (uint64_t)&w) == VX_OK);
  CHECK(start_child_mapped(ROBUST_HOLD, 0, 0, shared, &child) && wait_blocked(child)); // registered
  vx_futex_wait(&never, 0, after_ms(30));                                              // the waiter waits
  CHECK(!atomic_load(&w.done));
  CHECK(vx_task_kill(child, VX_STR("killed holding a lock")) == VX_OK);
  CHECK(robust_waited(&w) && atomic_load(&w.result) == VX_OK && atomic_load(&e->word) == (W | DIED));
  vx_handle_close(th);
  vx_handle_close(child);
  vx_as_unmap(self, at, 4096);
  vx_handle_close(shared);

  // A waiter on a pager's page that is evicted and supplied again, in another
  // physical page: the wake still finds it (keyed by VMO and offset).
  vx_handle res = root_resource(), port = 0, pager = 0, vmo = 0, src = 0, weak = 0;
  CHECK(vx_port_create(0, &port) == VX_OK &&
        vx_handle_dup(res, VX_RIGHT_PAGER | VX_RIGHT_DUPLICATE, &weak) == VX_OK &&
        vx_pager_create(weak, port, 1, 2'000'000'000, &pager) == VX_OK);
  vx_handle_close(weak);
  uint32_t five = 5;
  CHECK(vx_vmo_create_pager(pager, 9, 4096, &vmo) == VX_OK && vx_vmo_create(4096, 0, &src) == VX_OK &&
        vx_vmo_rw(src, VX_VMO_WRITE, 0, &five, 4) == VX_OK &&
        vx_pager_supply(pager, vmo, 0, 4096, src, 0) == VX_OK);
  at = 0;
  CHECK(vx_as_map(self, vmo, 0, 4096, VX_MAP_WRITE, &at) == VX_OK);
  w = (robust_waiter){.word = (const _Atomic uint32_t *)at, .expected = 5};
  CHECK(vx_thread_create(self, &th) == VX_OK &&
        vx_thread_start(th, (uint64_t)robust_wait, new_stack(), 0, (uint64_t)&w) == VX_OK);
  vx_futex_wait(&never, 0, after_ms(30)); // waiting on the page
  CHECK(!atomic_load(&w.done));
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_EVICT, 0, 4096, nullptr) == VX_OK);
  CHECK(vx_futex_wait((const _Atomic uint32_t *)at, 5, after_ms(10)) ==
        VX_ERR_BAD_STATE); // absent: load, ask again
  // The freed page taken by something else first, so the supply's is another.
  vx_handle taker = 0;
  uint64_t junk = 1;
  CHECK(vx_vmo_create(4096, 0, &taker) == VX_OK && vx_vmo_rw(taker, VX_VMO_WRITE, 0, &junk, 8) == VX_OK);
  CHECK(vx_pager_supply(pager, vmo, 0, 4096, src, 0) == VX_OK); // a new page
  atomic_store((_Atomic uint32_t *)at, 6);
  CHECK(vx_futex_wake((const _Atomic uint32_t *)at, 1) == 1);
  CHECK(robust_waited(&w) && atomic_load(&w.result) == VX_OK);
  vx_handle_close(th);
  vx_as_unmap(self, at, 4096);
  vx_handle_close(vmo);
  vx_handle_close(src);
  vx_handle_close(taker);
  vx_handle_close(pager);
  vx_handle_close(port);
}

// --- Note stacks (ADR-0036) ---

static alignas(16) uint8_t note_stack[16384];
static _Atomic uint64_t note_handler_at, note_fault_at, note_rest_sp;
static _Atomic bool note_finished;
static _Atomic int64_t note_get, note_small;

static void note_finish(void) {
  atomic_store(&note_finished, true);
  vx_thread_exit();
}

// Where it ran, and the thread sent on to note_finish on a stack that works.
static void note_handler(vx_exception *e) {
  volatile uint8_t here = 0;
  atomic_store(&note_handler_at, (uint64_t)&here);
  atomic_store(&note_fault_at, e->address);
#ifdef __x86_64__
  e->regs.rip = (uint64_t)note_finish;
  e->regs.rsp = atomic_load(&note_rest_sp) - 8; // as a call leaves it
#else
  e->regs.pc = (uint64_t)note_finish;
  e->regs.sp = atomic_load(&note_rest_sp);
#endif
  vx_rights_set(e->rights);
  vx_exception_resume(vx_self, 0, VX_RESUME_CONTINUE, &e->regs);
}

// Its stack pointer moved to memory nothing maps, then a push: the fault has
// nowhere on that stack to go, and goes to the note stack.
static void note_overflow(uint64_t arg, uint64_t bad) {
  (void)arg;
  vx_note_stack small = {(uint64_t)note_stack, VX_NOTE_STACK_MIN - 16},
                ns = {(uint64_t)note_stack, sizeof note_stack};
  atomic_store(&note_small, vx_thread_state(self, 0, VX_STATE_SET_NOTE_STACK, &small, sizeof small));
  vx_thread_state(self, 0, VX_STATE_SET_NOTE_STACK, &ns, sizeof ns);
  vx_note_stack got = {};
  atomic_store(&note_get, vx_thread_state(self, 0, VX_STATE_GET_NOTE_STACK, &got, sizeof got) == VX_OK &&
                              got.base == ns.base && got.size == ns.size);
#ifdef __x86_64__
  __asm__ volatile("mov %0, %%rsp\n\tpush %%rax" : : "r"(bad) : "memory");
#else
  __asm__ volatile("mov sp, %0\n\tstr x0, [sp, #-16]!" : : "r"(bad) : "memory");
#endif
  __builtin_unreachable();
}

static void test_note_stack(void) {
  static _Atomic uint32_t never;
  uint64_t bad = 0;
  vx_handle probe, th;
  CHECK(vx_vmo_create(4096, 0, &probe) == VX_OK &&
        vx_as_map(self, probe, 0, 4096, VX_MAP_WRITE, &bad) == VX_OK);
  CHECK(vx_as_unmap(self, bad, 4096) == VX_OK); // nothing there now
  vx_handle_close(probe);
  atomic_store(&note_rest_sp, new_stack());
  CHECK(vx_exception_bind(self, 0, (uint64_t)note_handler, VX_EXCEPTION_IN_TASK) == VX_OK);
  CHECK(vx_thread_create(self, &th) == VX_OK &&
        vx_thread_start(th, (uint64_t)note_overflow, new_stack(), 0, bad + 4096) == VX_OK);
  for (int i = 0; i < 1000 && !atomic_load(&note_finished); i++) vx_futex_wait(&never, 0, after_ms(1));
  CHECK(atomic_load(&note_finished));
  uint64_t at = atomic_load(&note_handler_at);
  CHECK(at >= (uint64_t)note_stack && at < (uint64_t)note_stack + sizeof note_stack); // on the note stack
  CHECK((atomic_load(&note_fault_at) & ~4095ull) == bad);
  CHECK(atomic_load(&note_get) == 1 && atomic_load(&note_small) == VX_ERR_RANGE);
  vx_note_stack big = {UINT64_MAX - 4096, 8192}; // past user memory
  CHECK(vx_thread_state(self, 0, VX_STATE_SET_NOTE_STACK, &big, sizeof big) == VX_ERR_RANGE);
  CHECK(vx_thread_state(self, 1, VX_STATE_GET_NOTE_STACK, &big, sizeof big) ==
        VX_ERR_INVALID); // the caller's only
  vx_handle_close(th);
  CHECK(vx_exception_bind(self, 0, 0, VX_EXCEPTION_IN_TASK) == VX_OK);
}

// --- Pagers (01 §5, docs/11 §8) ---

typedef struct toucher {
  volatile uint64_t *at;
  _Atomic uint64_t seen;
  _Atomic bool done;
} toucher;

static void touch_page(uint64_t arg, uint64_t arg2) {
  (void)arg;
  toucher *t = (toucher *)arg2;
  atomic_store(&t->seen, *t->at); // waits for the pager
  atomic_store(&t->done, true);
  vx_thread_exit();
}

// The root Resource, looked at but left in the spawn message for test_devices.
static vx_handle root_resource(void) {
  for (uint32_t i = 0; i < vx_spawn.handle_count; i++)
    if (vx_spawn.handle_names[i].len == 8 && memcmp(vx_spawn.handle_names[i].ptr, "resource", 8) == 0)
      return vx_spawn.handles[i];
  return VX_HANDLE_NONE;
}

static void test_pager(void) {
  static _Atomic uint32_t never;
  vx_handle res = root_resource(), port = VX_HANDLE_NONE, pager, vmo, src, weak;
  CHECK(res != VX_HANDLE_NONE && vx_port_create(0, &port) == VX_OK);
  // Only a Resource handle with PAGER (or the root one) makes a pager.
  CHECK(vx_handle_dup(res, VX_RIGHT_INSPECT, &weak) == VX_OK);
  CHECK(vx_pager_create(weak, port, 1, 1'000'000'000, &pager) == VX_ERR_ACCESS);
  vx_handle_close(weak);
  CHECK(vx_handle_dup(res, VX_RIGHT_PAGER | VX_RIGHT_DUPLICATE, &weak) == VX_OK);
  CHECK(vx_pager_create(weak, port, 42, 2'000'000'000, &pager) == VX_OK);
  vx_handle_close(weak);
  CHECK(vx_vmo_create_pager(pager, 77, 16384, &vmo) == VX_OK);
  CHECK(vx_vmo_create(16384, 0, &src) == VX_OK);
  uint64_t pattern[4] = {0x1111, 0x2222, 0x3333, 0x4444};
  for (int i = 0; i < 4; i++)
    CHECK(vx_vmo_rw(src, VX_VMO_WRITE, (uint64_t)i * 4096, &pattern[i], 8) == VX_OK);
  uint64_t got = 0;
  CHECK(vx_vmo_rw(vmo, VX_VMO_READ, 0, &got, 8) == VX_ERR_SHOULD_WAIT); // nothing supplied yet
  // Page 0 supplied before it is mapped: there at once.
  CHECK(vx_pager_supply(pager, vmo, 0, 4096, src, 0) == VX_OK);
  uint64_t at = 0;
  CHECK(vx_as_map(self, vmo, 0, 16384, VX_MAP_WRITE, &at) == VX_OK);
  CHECK(*(volatile uint64_t *)at == 0x1111);
  // Page 1, touched by a thread: the pager is asked, once, and the thread waits until it supplies.
  static toucher t;
  t = (toucher){.at = (volatile uint64_t *)(at + 4096)};
  vx_handle th;
  CHECK(vx_thread_create(self, &th) == VX_OK);
  CHECK(vx_thread_start(th, (uint64_t)touch_page, new_stack(), 0, (uint64_t)&t) == VX_OK);
  vx_packet pk = {};
  CHECK(vx_port_wait(port, after_ms(2000), 0, &pk, 1) == 1);
  CHECK(pk.key == 42 && pk.trigger == VX_TRIGGER_PAGER && pk.source == 77 &&
        vx_pager_offset(pk.value) == 4096 && vx_pager_pages(pk.value) == 1);
  vx_futex_wait(&never, 0, after_ms(20));
  CHECK(!atomic_load(&t.done)); // waiting, not failed
  CHECK(vx_pager_supply(pager, vmo, 4096, 4096, src, 4096) == VX_OK);
  for (int i = 0; i < 1000 && !atomic_load(&t.done); i++) vx_futex_wait(&never, 0, after_ms(1));
  CHECK(atomic_load(&t.done) && atomic_load(&t.seen) == 0x2222);
  vx_handle_close(th);
  // A page supplied twice keeps the first; a write goes to the page and stays.
  CHECK(vx_pager_supply(pager, vmo, 0, 4096, src, 4096) == VX_OK && *(volatile uint64_t *)at == 0x1111);
  *(volatile uint64_t *)(at + 8) = 0x5555;
  CHECK(vx_vmo_rw(vmo, VX_VMO_READ, 8, &got, 8) == VX_OK && got == 0x5555);
  // Refusals: a range past the end, a supply from another pager's VMO, a clone.
  CHECK(vx_pager_supply(pager, vmo, 16384, 4096, src, 0) == VX_ERR_RANGE);
  CHECK(vx_pager_supply(pager, vmo, 8192, 4096, vmo, 0) == VX_ERR_UNSUPPORTED);
  vx_handle clone;
  CHECK(vx_vmo_clone(vmo, 0, 4096, &clone) == VX_ERR_UNSUPPORTED);
  // Dirty pages: a write marks one, CLEAN clears it (and the next write
  // marks it again), and what was written stays.
  vx_pager_range ranges[VX_PAGER_RANGES];
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_CLEAN, 0, 16384, nullptr) == VX_OK);
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_DIRTY, 0, 16384, ranges) == 0);
  CHECK(*(volatile uint64_t *)(at + 4096) == 0x2222); // a read dirties nothing
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_DIRTY, 0, 16384, ranges) == 0);
  *(volatile uint64_t *)(at + 4096 + 16) = 0x6666;
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_DIRTY, 0, 16384, ranges) == 1 && ranges[0].offset == 4096 &&
        ranges[0].size == 4096);
  *(volatile uint64_t *)(at + 24) = 0x7777; // page 0 too: two pages, one range
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_DIRTY, 0, 16384, ranges) == 1 && ranges[0].offset == 0 &&
        ranges[0].size == 8192);
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_CLEAN, 4096, 4096, nullptr) == VX_OK);
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_DIRTY, 0, 16384, ranges) == 1 && ranges[0].offset == 0 &&
        ranges[0].size == 4096);
  CHECK(*(volatile uint64_t *)(at + 4096 + 16) == 0x6666); // cleaned, not lost
  *(volatile uint64_t *)(at + 4096 + 32) = 0x8888;         // and written again: dirty again
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_DIRTY, 4096, 4096, ranges) == 1);
  // EVICT frees clean pages, never dirty ones: page 1 cleaned and evicted
  // is asked for again when touched; page 0, dirty, stays.
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_CLEAN, 4096, 4096, nullptr) == VX_OK);
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_EVICT, 0, 16384, nullptr) == VX_OK);
  CHECK(vx_vmo_rw(vmo, VX_VMO_READ, 4096, &got, 8) == VX_ERR_SHOULD_WAIT);
  CHECK(vx_vmo_rw(vmo, VX_VMO_READ, 24, &got, 8) == VX_OK && got == 0x7777);
  t = (toucher){.at = (volatile uint64_t *)(at + 4096)};
  CHECK(vx_thread_create(self, &th) == VX_OK);
  CHECK(vx_thread_start(th, (uint64_t)touch_page, new_stack(), 0, (uint64_t)&t) == VX_OK);
  CHECK(vx_port_wait(port, after_ms(2000), 0, &pk, 1) == 1 && vx_pager_offset(pk.value) == 4096);
  CHECK(vx_pager_supply(pager, vmo, 4096, 4096, src, 4096) == VX_OK);
  for (int i = 0; i < 1000 && !atomic_load(&t.done); i++) vx_futex_wait(&never, 0, after_ms(1));
  CHECK(atomic_load(&t.done) && atomic_load(&t.seen) == 0x2222); // as supplied again
  vx_handle_close(th);
  // Resizing: grown, the new pages absent; shrunk, the pages past the end gone.
  CHECK(vx_vmo_resize(vmo, 32768) == VX_ERR_ACCESS); // the pager's to resize, not a writer's
  CHECK(vx_pager_resize(pager, vmo, 32768) == VX_OK &&
        vx_vmo_rw(vmo, VX_VMO_READ, 20480, &got, 8) == VX_ERR_SHOULD_WAIT);
  CHECK(vx_pager_supply(pager, vmo, 20480, 4096, src, 0) == VX_OK);
  CHECK(vx_vmo_rw(vmo, VX_VMO_READ, 20480, &got, 8) == VX_OK && got == 0x1111);
  CHECK(vx_pager_resize(pager, vmo, 8192) == VX_OK &&
        vx_vmo_rw(vmo, VX_VMO_READ, 8192, &got, 8) == VX_ERR_RANGE);
  uint64_t past = 0; // a mapping past the new end is refused
  CHECK(vx_as_map(self, vmo, 8192, 4096, 0, &past) == VX_ERR_RANGE);
  CHECK(vx_vmo_rw(vmo, VX_VMO_READ, 24, &got, 8) == VX_OK && got == 0x7777);         // what is kept, kept
  CHECK(vx_vmo_resize(src, 8192) == VX_ERR_UNSUPPORTED);                             // anonymous: not yet
  CHECK(vx_pager_op(pager, src, VX_PAGER_DIRTY, 0, 4096, ranges) == VX_ERR_INVALID); // not its VMO
  // A request the port has no room for is not lost: asked again once there is.
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_CLEAN, 4096, 4096, nullptr) == VX_OK);
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_EVICT, 4096, 4096, nullptr) == VX_OK);
  uint32_t filled = 0;
  while (filled < 1000 && vx_port_post(port, &(vx_packet){.key = 999}) == VX_OK) filled++;
  CHECK(filled > 0 && filled < 1000);
  t = (toucher){.at = (volatile uint64_t *)(at + 4096)};
  CHECK(vx_thread_create(self, &th) == VX_OK);
  CHECK(vx_thread_start(th, (uint64_t)touch_page, new_stack(), 0, (uint64_t)&t) == VX_OK);
  vx_futex_wait(&never, 0, after_ms(20)); // its request refused, and tried again
  uint32_t drained = 0;
  while (drained < filled && vx_port_wait(port, after_ms(100), 0, &pk, 1) == 1 && pk.key == 999) drained++;
  CHECK(drained == filled);
  CHECK(vx_port_wait(port, after_ms(2000), 0, &pk, 1) == 1 && pk.key == 42 &&
        vx_pager_offset(pk.value) == 4096);
  CHECK(vx_pager_supply(pager, vmo, 4096, 4096, src, 4096) == VX_OK);
  for (int i = 0; i < 1000 && !atomic_load(&t.done); i++) vx_futex_wait(&never, 0, after_ms(1));
  CHECK(atomic_load(&t.done) && atomic_load(&t.seen) == 0x2222);
  vx_handle_close(th);
  // vmo_rw writes dirty a page as a store does.
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_CLEAN, 0, 8192, nullptr) == VX_OK);
  got = 0x9999;
  CHECK(vx_vmo_rw(vmo, VX_VMO_WRITE, 4096 + 40, &got, 8) == VX_OK);
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_DIRTY, 0, 8192, ranges) == 1 && ranges[0].offset == 4096);
  // IDLE: not while it is mapped, nor while another handle has it; then yes.
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_IDLE, 0, 0, nullptr) == 0);
  CHECK(vx_as_unmap(self, at, 16384) == VX_OK);
  vx_handle other;
  CHECK(vx_handle_dup(vmo, VX_RIGHTS_SAME, &other) == VX_OK);
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_IDLE, 0, 0, nullptr) == 0);
  vx_handle_close(other);
  CHECK(vx_pager_op(pager, vmo, VX_PAGER_IDLE, 0, 0, nullptr) == 1);
  vx_handle_close(vmo);

  // A deadline missed: the thread takes PAGER_TIMEOUT, its handler supplies
  // the page late, and the access is made again.
  vx_handle quick;
  CHECK(vx_pager_create(res, port, 43, 30'000'000, &quick) == VX_OK); // 30 ms
  CHECK(vx_vmo_create_pager(quick, 78, 4096, &late_vmo) == VX_OK);
  late_pager = quick, late_src = src;
  at = 0;
  CHECK(vx_as_map(self, late_vmo, 0, 4096, 0, &at) == VX_OK);
  CHECK(vx_exception_bind(self, 0, (uint64_t)handler, VX_EXCEPTION_IN_TASK) == VX_OK);
  CHECK(*(volatile uint64_t *)at == 0x1111); // after the timeout, from the handler's supply
  CHECK(vx_exception_bind(self, 0, 0, VX_EXCEPTION_IN_TASK) == VX_OK);
  CHECK(atomic_load(&pager_timeouts) == 1);
  CHECK(vx_port_wait(port, after_ms(100), 0, &pk, 1) == 1 && pk.key == 43 && pk.source == 78);
  CHECK(vx_as_unmap(self, at, 4096) == VX_OK);
  vx_handle_close(late_vmo);
  // A deadline missed with no one to handle it: the task ends with the
  // timeout's words, not the page fault's (the Odin port's finding), so a
  // POSIX parent sees SIGBUS.
  vx_handle never_vmo, child, exits;
  CHECK(vx_port_create(0, &exits) == VX_OK); // apart from the pager's port, which gets the request
  CHECK(vx_vmo_create_pager(quick, 79, 4096, &never_vmo) == VX_OK);
  CHECK(start_child_mapped(FAULT_LOAD, 0, 0, never_vmo, &child));
  CHECK(starts(wait_exit(exits, child), "sys: trap: page not supplied addr=0x300000 pc="));
  vx_handle_close(child);
  vx_handle_close(exits);
  vx_handle_close(never_vmo);
  while (vx_port_wait(port, 0, 0, &pk, 1) == 1) {} // its request, never answered
  vx_handle_close(quick);
  vx_handle_close(pager);
  vx_handle_close(src);
  vx_handle_close(port);
}

// --- Protection keys and as_protect (ADR-0035) ---

static _Atomic uint32_t keys_worker_ok;

// A thread of the same task starts with its creator's rights, and its own
// change of them is its own.
static void keys_worker(vx_handle unused, uint64_t key) {
  (void)unused;
  bool ok = vx_keys_get((uint32_t)key) == (VX_KEY_READ | VX_KEY_WRITE); // inherited
  ok = ok && vx_keys_set((uint32_t)key, 0) == VX_OK && vx_keys_get((uint32_t)key) == 0;
  atomic_store(&keys_worker_ok, ok ? 1 : 2);
  vx_thread_exit();
}

static void test_keys(void) {
  // as_protect, on every CPU: a range's rights changed within what the
  // mapping's handle gave, a mapping cut in three.
  vx_handle v, ro;
  uint64_t at = 0;
  vx_map_info mi;
  CHECK(vx_vmo_create(3ull * 4096, 0, &v) == VX_OK &&
        vx_as_map(self, v, 0, 3ull * 4096, VX_MAP_WRITE, &at) == VX_OK);
  if (!at) return;
  CHECK(vx_as_protect(self, at + 4096, 4096, 0) == VX_OK); // the middle page read-only
  CHECK(vx_as_query(self, at, &mi) == VX_OK && mi.base == at && mi.size == 4096 && (mi.flags & VX_MAP_WRITE));
  CHECK(vx_as_query(self, at + 4096, &mi) == VX_OK && mi.base == at + 4096 && mi.size == 4096 &&
        !(mi.flags & VX_MAP_WRITE));
  CHECK(vx_as_query(self, at + 8192, &mi) == VX_OK && mi.base == at + 8192 && (mi.flags & VX_MAP_WRITE));
  *(volatile uint64_t *)at = 1, *(volatile uint64_t *)(at + 8192) = 3; // the ends still write
  CHECK(vx_as_protect(self, at, 3ull * 4096, VX_MAP_WRITE) == VX_OK);  // and the middle again
  *(volatile uint64_t *)(at + 4096) = 2;
  CHECK(vx_as_protect(self, at, 4096, VX_MAP_WRITE | VX_MAP_EXEC) == VX_ERR_ACCESS); // W^X
  CHECK(vx_as_protect(self, at, 4096, VX_MAP_EXEC) == VX_OK &&
        vx_as_protect(self, at, 4096, VX_MAP_WRITE) ==
            VX_OK); // written, then run, as a JIT does: W^X, in turn
  CHECK(vx_as_protect(self, at, 4ull * 4096, 0) == VX_ERR_NOT_FOUND); // past it: a hole
  CHECK(vx_as_protect(self, at + 1, 4096, 0) == VX_ERR_RANGE);
  CHECK(vx_handle_dup(v, VX_RIGHT_MAP | VX_RIGHT_READ, &ro) == VX_OK); // a handle that cannot write
  uint64_t at2 = 0;
  CHECK(vx_as_map(self, ro, 0, 4096, 0, &at2) == VX_OK);
  CHECK(vx_as_protect(self, at2, 4096, VX_MAP_WRITE) == VX_ERR_ACCESS); // more than its handle gave
  CHECK(vx_as_unmap(self, at2, 4096) == VX_OK);
  vx_handle_close(ro);

  vx_cpu_info ci = {};
  CHECK(vx_thread_state(self, 0, VX_STATE_GET_CPU, &ci, sizeof ci) == VX_OK);
  uint32_t key = 0;
  vx_print(VX_STR("ktest: protection keys: "));
  vx_print_u64(ci.keys);
  vx_print(VX_STR("\n"));
  if (!ci.keys) { // aarch64 (no FEAT_S1POE: 6c5), or an x86 without PKU
    CHECK(vx_as_key_alloc(self, &key) == VX_ERR_UNSUPPORTED &&
          vx_keys_set(1, VX_KEY_READ) == VX_ERR_UNSUPPORTED);
    CHECK(vx_as_unmap(self, at, 3ull * 4096) == VX_OK);
    vx_handle_close(v);
    return;
  }
  // Keys, each once, 1 to 15; then none.
  uint32_t keys[15], n = 0;
  while (n < 15 && vx_as_key_alloc(self, &keys[n]) == VX_OK) n++;
  CHECK(n == ci.keys && ci.keys == 15 && keys[0] == 1 && keys[14] == 15);
  CHECK(vx_as_key_alloc(self, &key) == VX_ERR_NO_SPACE);
  for (uint32_t i = 1; i < n; i++) CHECK(vx_as_key_free(self, keys[i]) == VX_OK);
  CHECK(vx_as_key_free(self, keys[1]) == VX_ERR_INVALID && vx_as_key_free(self, 0) == VX_ERR_INVALID);
  key = keys[0];
  CHECK(vx_as_map(self, v, 0, 4096, VX_MAP_WRITE | VX_MAP_KEY(9), &at2) == VX_ERR_INVALID); // not allocated
  // The middle page under the key: this thread, a new task's first, has every key but 0 closed.
  CHECK(vx_as_protect(self, at + 4096, 4096, VX_MAP_WRITE | VX_MAP_KEY(key)) == VX_OK);
  CHECK(vx_as_query(self, at + 4096, &mi) == VX_OK && (mi.flags & VX_MAP_KEY_MASK) == VX_MAP_KEY(key));
  CHECK(vx_keys_get(key) == 0);
  CHECK(vx_keys_set(key, VX_KEY_READ) == VX_OK && vx_keys_get(key) == VX_KEY_READ);
  CHECK(*(volatile uint64_t *)(at + 4096) == 2); // read
  // A write faults, as PROTECTION_KEY with the key; the handler gives the
  // key, and the write is made again.
  CHECK(vx_exception_bind(self, 0, (uint64_t)handler, VX_EXCEPTION_IN_TASK) == VX_OK);
  *(volatile uint64_t *)(at + 4096) = 4;
  CHECK(vx_exception_bind(self, 0, 0, VX_EXCEPTION_IN_TASK) == VX_OK);
  CHECK(atomic_load(&key_faults) == 1 && atomic_load(&key_fault_key) == key &&
        atomic_load(&key_fault_code) == 1);
  CHECK(*(volatile uint64_t *)(at + 4096) == 4 && vx_keys_get(key) == (VX_KEY_READ | VX_KEY_WRITE));
  // The kernel's copies obey the caller's rights: ACCESS, not a fault.
  uint64_t word = 5;
  CHECK(vx_keys_set(key, VX_KEY_READ) == VX_OK);
  CHECK(vx_vmo_rw(v, VX_VMO_READ, 0, (void *)(at + 4096), 8) ==
        VX_ERR_ACCESS); // into a page it may not write
  CHECK(vx_keys_set(key, 0) == VX_OK);
  CHECK(vx_vmo_rw(v, VX_VMO_WRITE, 0, (void *)(at + 4096), 8) == VX_ERR_ACCESS); // from one it may not read
  CHECK(vx_vmo_rw(v, VX_VMO_WRITE, 0, &word, 8) == VX_OK);                       // its own pages: as ever
  // Another thread's rights are its own, from its creator's at its start.
  CHECK(vx_keys_set(key, VX_KEY_READ | VX_KEY_WRITE) == VX_OK);
  vx_handle th = 0; // closing 0 is a harmless BAD_HANDLE
  uint64_t sp = new_stack();
  CHECK(sp && vx_thread_create(self, &th) == VX_OK &&
        vx_thread_start(th, (uint64_t)keys_worker, sp, 0, key) == VX_OK);
  for (int i = 0; i < 1000 && !atomic_load(&keys_worker_ok); i++) {
    _Atomic uint32_t never = 0;
    vx_futex_wait(&never, 0, after_ms(1)); // switches, on this CPU or another
  }
  CHECK(atomic_load(&keys_worker_ok) == 1 && vx_keys_get(key) == (VX_KEY_READ | VX_KEY_WRITE));
  vx_handle_close(th);
  // A key a mapping uses is not freed; once unmapped, it is.
  CHECK(vx_as_key_free(self, key) == VX_ERR_BAD_STATE);
  CHECK(vx_as_unmap(self, at, 3ull * 4096) == VX_OK && vx_as_key_free(self, key) == VX_OK);
  vx_handle_close(v);
}

// --- Debugging (05 §2) ---

static void test_debugger(void) {
  vx_handle port, child, weak;
  vx_exception e = {};
  vx_regs regs;
  CHECK(vx_port_create(0, &port) == VX_OK);
  // A breakpoint goes first to a debugger's port; it steps one instruction,
  // sees what that did, and continues.
  CHECK(start_child_bound(BREAK_STEP, port, VX_EXCEPTION_FIRST_CHANCE, &child));
  CHECK(child_stopped(port));
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_EXCEPTION, &e, sizeof e) == VX_OK &&
        e.kind == VX_EXCEPTION_BREAKPOINT);
#ifdef __aarch64__
  e.regs.pc += 4; // past the brk
  CHECK(vx_thread_state(child, 1, VX_STATE_SET_REGS, &e.regs, sizeof e.regs) == VX_OK);
#endif
  CHECK(vx_exception_resume(child, 1, VX_RESUME_STEP, nullptr) == VX_OK);
  CHECK(child_stopped(port));
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_EXCEPTION, &e, sizeof e) == VX_OK &&
        e.kind == VX_EXCEPTION_STEP);
#ifdef __x86_64__
  CHECK(e.regs.rdi == 7 && e.regs.rip == CHILD_CODE + 1 + 5); // int3, then mov $7, %edi
#else
  CHECK(e.regs.x[0] == 7 && e.regs.pc == CHILD_CODE + 8); // brk, then movz x0, #7
#endif
  CHECK(vx_exception_resume(child, 1, VX_RESUME_CONTINUE, nullptr) == VX_OK);
  CHECK(is(wait_exit(port, child), ""));
  vx_handle_close(child);

  // A stepped syscall stops right after it, not an instruction later (on
  // x86_64, FMASK clears TF as it enters: the Rust port's finding).
  CHECK(start_child_bound(BREAK_SYSCALL, port, VX_EXCEPTION_FIRST_CHANCE, &child));
  CHECK(child_stopped(port));
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_EXCEPTION, &e, sizeof e) == VX_OK &&
        e.kind == VX_EXCEPTION_BREAKPOINT);
#ifdef __aarch64__
  e.regs.pc += 4; // past the brk
  CHECK(vx_thread_state(child, 1, VX_STATE_SET_REGS, &e.regs, sizeof e.regs) == VX_OK);
#endif
  CHECK(vx_exception_resume(child, 1, VX_RESUME_STEP, nullptr) == VX_OK);
  CHECK(child_stopped(port));
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_EXCEPTION, &e, sizeof e) == VX_OK &&
        e.kind == VX_EXCEPTION_STEP);
#ifdef __x86_64__
  CHECK(e.regs.rip == CHILD_CODE + 5 + 1 + 2 && e.regs.rdi != 7); // mov, int3, syscall: not the mov after
#else
  CHECK(e.regs.pc == CHILD_CODE + 12 && e.regs.x[0] != 7); // movz, brk, svc: not the movz after
#endif
  CHECK(vx_exception_resume(child, 1, VX_RESUME_CONTINUE, nullptr) == VX_OK);
  CHECK(is(wait_exit(port, child), ""));
  vx_handle_close(child);

  // Passed on, the breakpoint reaches nobody else: the default kills it. A
  // handle without DEBUG cannot answer the debugger's stop, whatever it does.
  CHECK(start_child_bound(BREAK_STEP, port, VX_EXCEPTION_FIRST_CHANCE, &child));
  CHECK(child_stopped(port));
  CHECK(vx_handle_dup(child, ((1u << VX_RIGHT_BIT_COUNT) - 1) & ~(uint32_t)VX_RIGHT_DEBUG, &weak) == VX_OK);
  CHECK(vx_exception_resume(weak, 1, VX_RESUME_CONTINUE, nullptr) == VX_ERR_ACCESS &&
        vx_exception_resume(weak, 1, VX_RESUME_PASS, nullptr) == VX_ERR_ACCESS);
  vx_handle_close(weak);
  CHECK(vx_exception_resume(child, 1, VX_RESUME_PASS, nullptr) == VX_OK);
  CHECK(starts(wait_exit(port, child), "sys: breakpoint pc="));
  vx_handle_close(child);

  // Suspended, a spinning child holds still: its code is patched (a private
  // copy, as its mapping is not writable), its pc moved there, and it exits.
  CHECK(start_child(SPIN, &child));
  CHECK(vx_handle_dup(child, ((1u << VX_RIGHT_BIT_COUNT) - 1) & ~(uint32_t)VX_RIGHT_DEBUG, &weak) == VX_OK);
  CHECK(vx_thread_suspend(weak, 1) == VX_ERR_ACCESS &&
        vx_exception_bind(weak, port, 1, VX_EXCEPTION_FIRST_CHANCE) == VX_ERR_ACCESS);
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_REGS, &regs, sizeof regs) == VX_ERR_BAD_STATE); // running
  CHECK(vx_thread_suspend(child, 1) == VX_OK);
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_REGS, &regs, sizeof regs) == VX_OK);
  CHECK(vx_thread_state(weak, 1, VX_STATE_GET_REGS, &regs, sizeof regs) == VX_ERR_BAD_STATE); // DEBUG needed
  // Its threads, listed; its FP registers, read and written back (a bad
  // MXCSR made safe); its mappings, from the code page on.
  vx_thread_info ti = {};
  CHECK(vx_thread_state(child, 0, VX_STATE_NEXT_THREAD, &ti, sizeof ti) == VX_OK && ti.id == 1 &&
        ti.state == VX_THREAD_SUSPENDED && ti.suspend_count == 1);
  CHECK(vx_thread_state(child, 1, VX_STATE_NEXT_THREAD, &ti, sizeof ti) == VX_ERR_NOT_FOUND);
  vx_fpregs fp;
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_FPREGS, &fp, sizeof fp) == VX_OK);
#ifdef __x86_64__
  uint32_t mxcsr;
  memcpy(&mxcsr, fp.fxsave + 24, sizeof mxcsr);
  CHECK(mxcsr == 0x1f80); // the reset value: every exception masked
  mxcsr = 0xffff'1f80;    // reserved bits: FXRSTOR would fault on them
  memcpy(fp.fxsave + 24, &mxcsr, sizeof mxcsr);
  fp.fxsave[160] = 0x5a; // XMM0's first byte
  CHECK(vx_thread_state(child, 1, VX_STATE_SET_FPREGS, &fp, sizeof fp) == VX_OK);
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_FPREGS, &fp, sizeof fp) == VX_OK);
  memcpy(&mxcsr, fp.fxsave + 24, sizeof mxcsr);
  CHECK(mxcsr == 0x1f80 && fp.fxsave[160] == 0x5a);
#else
  fp.v[0][0] = 0x5a;
  fp.fpcr = ~0ull;
  CHECK(vx_thread_state(child, 1, VX_STATE_SET_FPREGS, &fp, sizeof fp) == VX_OK);
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_FPREGS, &fp, sizeof fp) == VX_OK);
  CHECK(fp.v[0][0] == 0x5a && fp.fpcr == 0x07ff9f00);
#endif
  CHECK(vx_thread_state(weak, 1, VX_STATE_GET_FPREGS, &fp, sizeof fp) == VX_ERR_BAD_STATE); // DEBUG needed
  // Its whole FP/SIMD state, and what the kernel saves (ADR-0035).
  vx_cpu_info ci = {};
  CHECK(vx_thread_state(child, 0, VX_STATE_GET_CPU, &ci, sizeof ci) == VX_OK);
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_CPU, &ci, sizeof ci) == VX_ERR_INVALID); // thread 0's
  static uint8_t xs[4096];
  CHECK(ci.xstate_size >= sizeof(vx_fpregs) && ci.xstate_size <= sizeof xs);
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_XSTATE, xs, ci.xstate_size - 1) == VX_ERR_TOO_SMALL);
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_XSTATE, xs, sizeof xs) == VX_OK);
#ifdef __x86_64__
  CHECK((ci.xfeatures & 7) == 7 && ci.mxcsr_mask != 0); // x87, SSE and AVX at least: x86-64-v3
  uint64_t bv;
  memcpy(&bv, xs + 512, sizeof bv);
  CHECK(bv == ci.xfeatures && xs[160] == 0x5a); // every component written out; XMM0 as SET_FPREGS left it
  uint32_t a, b, c, d;
  __asm__ volatile("cpuid" : "=a"(a), "=b"(b), "=c"(c), "=d"(d) : "a"(0xd), "c"(2)); // AVX's place
  CHECK(b + 16 <= ci.xstate_size);
  xs[b] = 0xa7; // YMM0's upper half, its first byte
  CHECK(vx_thread_state(child, 1, VX_STATE_SET_XSTATE, xs, sizeof xs) == VX_OK);
  memset(xs, 0, sizeof xs);
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_XSTATE, xs, sizeof xs) == VX_OK && xs[b] == 0xa7 &&
        xs[160] == 0x5a);
  xs[512 + 20] = 1; // a reserved header byte
  CHECK(vx_thread_state(child, 1, VX_STATE_SET_XSTATE, xs, sizeof xs) == VX_ERR_INVALID);
  xs[512 + 20] = 0, xs[512 + 7] = 0x80; // XSTATE_BV bit 63: no such component
  CHECK(vx_thread_state(child, 1, VX_STATE_SET_XSTATE, xs, sizeof xs) == VX_ERR_INVALID);
#else
  CHECK(ci.xstate_size == sizeof(vx_fpregs) && memcmp(xs, &fp, sizeof fp) == 0); // the same image
  vx_fpregs bad = fp;
  bad.fpcr = ~0ull;
  CHECK(vx_thread_state(child, 1, VX_STATE_SET_XSTATE, &bad, sizeof bad) == VX_ERR_INVALID);
#endif
  // Its watchpoints: as many as the hardware has, each checked when set.
  vx_watches w = {};
  CHECK(vx_thread_state(child, 0, VX_STATE_GET_WATCH, &w, sizeof w) == VX_OK && w.count >= 2 &&
        w.count <= VX_WATCH_MAX && w.slot[0].kind == VX_WATCH_OFF);
  w.slot[0] = (vx_watch){.address = 0x40'0000, .len = 8, .kind = VX_WATCH_WRITE};
  CHECK(vx_thread_state(child, 0, VX_STATE_SET_WATCH, &w, sizeof w) == VX_OK);
  CHECK(vx_thread_state(weak, 0, VX_STATE_SET_WATCH, &w, sizeof w) == VX_ERR_ACCESS); // DEBUG needed
  CHECK(vx_thread_state(child, 1, VX_STATE_SET_WATCH, &w, sizeof w) ==
        VX_ERR_INVALID);                                                       // the task's, thread 0
  w.slot[1] = (vx_watch){.address = 0x40'0004, .len = 8, .kind = VX_WATCH_RW}; // not aligned
  CHECK(vx_thread_state(child, 0, VX_STATE_SET_WATCH, &w, sizeof w) == VX_ERR_INVALID);
  w.slot[1] = (vx_watch){.address = 0x40'0004, .len = 3, .kind = VX_WATCH_RW}; // no such length
  CHECK(vx_thread_state(child, 0, VX_STATE_SET_WATCH, &w, sizeof w) == VX_ERR_INVALID);
  w.slot[1] = (vx_watch){.address = ~0ull - 7, .len = 8, .kind = VX_WATCH_RW}; // not user space
  CHECK(vx_thread_state(child, 0, VX_STATE_SET_WATCH, &w, sizeof w) == VX_ERR_INVALID);
  w = (vx_watches){};
  CHECK(vx_thread_state(child, 0, VX_STATE_GET_WATCH, &w, sizeof w) == VX_OK &&
        w.slot[0].address == 0x40'0000 && w.slot[0].kind == VX_WATCH_WRITE && w.slot[1].kind == VX_WATCH_OFF);
  w.slot[0].kind = VX_WATCH_OFF;
  CHECK(vx_thread_state(child, 0, VX_STATE_SET_WATCH, &w, sizeof w) == VX_OK);
  vx_map_info mi = {};
  CHECK(vx_as_query(child, 0, &mi) == VX_OK && mi.base <= CHILD_CODE && mi.base + mi.size > CHILD_CODE &&
        (mi.flags & VX_MAP_EXEC) && !(mi.flags & VX_MAP_WRITE));
  CHECK(vx_as_query(child, ~0ull - 4096, &mi) == VX_ERR_NOT_FOUND);
#ifdef __x86_64__
  CHECK(regs.rip == CHILD_CODE);
  regs.rip = CHILD_CODE + 64;
#else
  CHECK(regs.pc == CHILD_CODE);
  regs.pc = CHILD_CODE + 64;
#endif
  uint8_t code[64] = {}, back[64] = {};
  uint32_t len = write_child(code, EXIT_7);
  uint64_t word = 0;
  vx_mem_op ops[3] = {
      {.address = CHILD_CODE + 64, .buffer = (uint64_t)code, .size = len, .write = 1},
      {.address = CHILD_CODE + 64, .buffer = (uint64_t)back, .size = len},
      {.address = CHILD_DATA, .buffer = (uint64_t)&word, .size = 8}, // nothing mapped there
  };
  CHECK(vx_task_mem_rw(child, ops, 3) == VX_OK);
  CHECK(ops[0].status == VX_OK && ops[1].status == VX_OK && memcmp(code, back, len) == 0);
  CHECK(ops[2].status == VX_ERR_INVALID);
  CHECK(vx_task_mem_rw(weak, ops, 1) == VX_ERR_ACCESS);
  CHECK(vx_thread_state(child, 1, VX_STATE_SET_REGS, &regs, sizeof regs) == VX_OK);
  CHECK(vx_thread_resume(child, 1) == VX_OK);
  vx_status again = vx_thread_resume(child, 1);                  // counted: not suspended any more, or
  CHECK(again == VX_ERR_BAD_STATE || again == VX_ERR_NOT_FOUND); // already run on to its end
  CHECK(is(wait_exit(port, child), ""));
  CHECK(vx_as_query(child, 0, &mi) ==
        VX_ERR_BAD_STATE); // an ended task: refused, not a fault (M6 step 6b, wave B)
  vx_handle_close(weak);
  vx_handle_close(child);

  // A thread blocked in a call holds still too, and goes on waiting once resumed.
  CHECK(start_child(BLOCK, &child));
  CHECK(wait_blocked(child));
  CHECK(vx_thread_suspend(child, 1) == VX_OK && vx_thread_suspend(child, 1) == VX_OK); // counted
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_REGS, &regs, sizeof regs) == VX_OK);
  CHECK(vx_thread_resume(child, 1) == VX_OK && vx_thread_resume(child, 1) == VX_OK);
  CHECK(wait_blocked(child));
  // Thread 0: every thread of the task, as a process stops as a whole.
  CHECK(vx_thread_suspend(child, 0) == VX_OK && vx_thread_resume(child, 0) == VX_OK);
  CHECK(vx_thread_resume(child, 0) == VX_ERR_BAD_STATE); // counted: not suspended any more
  CHECK(wait_blocked(child));
  CHECK(vx_task_kill(child, VX_STR("killed")) == VX_OK && is(wait_exit(port, child), "killed"));
  vx_handle_close(child);
  vx_handle_close(port);
}

// --- fork (01 §9) ---

static uint64_t fork_page[512];
static uint64_t fork_shared; // a VX_MAP_SHARED mapping the child writes to (test_address_space)
static uint64_t fork_ring;   // where a ring's memory is mapped, in the parent

// The forked child's first thread. Its exit string says what it found: "ok"
// if all is well, or "wrong N", N the bits of what was not.
[[noreturn]] static void fork_child(vx_handle unused, uint64_t my_id) {
  (void)unused;
  int64_t wrong = 0;
  if (fork_page[7] != 0x1234) wrong |= 1; // memory as it was at the fork
  fork_page[7] = 0x9999;                  // and its own: the parent never sees this
  vx_task_summary me;
  if (vx_task_info(self, &me) != VX_OK || me.id != my_id) wrong |= 2; // "self" is itself
  if (fork_ring) (void)*(volatile uint64_t *)fork_ring;               // not there: a fault ends it
  if (fork_shared) *(volatile uint64_t *)fork_shared = 0x7777;        // the same VMO: the parent sees it
  char msg[] = "wrong 0";
  msg[6] = (char)('0' + wrong);
  vx_task_kill(self, wrong ? (vx_str){msg, 7} : VX_STR("ok"));
  vx_thread_exit();
}

static const char *run_fork(uint64_t sp, vx_handle port) {
  vx_handle child, th;
  vx_task_summary info;
  if (vx_task_fork(VX_STR("forked"), &child) != VX_OK) return nullptr;
  fork_page[7] = 0x5555; // after the fork: not the child's
  const char *status = nullptr;
  if (vx_task_info(child, &info) == VX_OK && vx_thread_create(child, &th) == VX_OK) {
    if (vx_thread_start(th, (uint64_t)fork_child, sp, 0, info.id) == VX_OK) status = wait_exit(port, child);
    vx_handle_close(th);
  }
  vx_handle_close(child);
  return status;
}

static void test_fork(void) {
  vx_handle port;
  CHECK(vx_port_create(0, &port) == VX_OK);
  uint64_t sp = new_stack(); // mapped before the fork, so the child has it too
  CHECK(sp != 0);
  fork_page[7] = 0x1234;
  CHECK(is(run_fork(sp, port), "ok"));
  CHECK(fork_page[7] == 0x5555); // the child's write stayed in the child

  // A ring's memory is not copied: the child faults where the parent has it.
  vx_ring_handles h;
  static const vx_ring_params params = {16, 16, 64, 32, 4096, 4096};
  vx_ring_header layout;
  vx_ring_layout(&params, &layout);
  CHECK(vx_ring_create(&params, &h) == VX_OK);
  CHECK(vx_as_map(self, h.memory, 0, layout.size, VX_MAP_WRITE, &fork_ring) == VX_OK);
  fork_page[7] = 0x1234;
  CHECK(*(volatile uint64_t *)fork_ring != 0x5a5a);      // the parent reads it
  CHECK(starts(run_fork(sp, port), "sys: trap: fault")); // the child is killed by the fault
  CHECK(vx_as_unmap(self, fork_ring, layout.size) == VX_OK);
  vx_handle_close(h.memory);
  vx_handle_close(h.client);
  vx_handle_close(h.server);
  vx_handle none = VX_HANDLE_NONE;
  CHECK(vx_syscall(VX_SYS_task_create, (uint64_t)"x", 1, (uint64_t)&none, 2, 0, 0) == VX_ERR_INVALID);
  vx_handle_close(port);
}

// --- Reservations, no-access, resizable and shared VMOs (ADR-0042) ---

static bool inside(uint64_t a, uint64_t base, uint64_t size) { return a >= base && a < base + size; }

static void test_address_space(void) {
  // Reservations: random, aligned, distinct; nothing placed lands in one.
  uint64_t r1 = 0, r2 = 0, at = 0, in_way = 0;
  CHECK(vx_as_reserve(self, 1 << 20, 1 << 16, 0, &r1) == VX_OK && r1 && !(r1 & 0xffff));
  CHECK(vx_as_reserve(self, 1 << 20, 1 << 16, 0, &r2) == VX_OK && r2 != r1);
  vx_handle v;
  CHECK(vx_vmo_create(16ull * 4096, 0, &v) == VX_OK);
  for (int i = 0; i < 4; i++) {
    uint64_t placed = 0;
    CHECK(vx_as_map(self, v, 0, 16ull * 4096, VX_MAP_WRITE, &placed) == VX_OK);
    CHECK(!inside(placed, r1, 1 << 20) && !inside(placed, r2, 1 << 20));
    CHECK(vx_as_unmap(self, placed, 16ull * 4096) == VX_OK);
  }
  // A mapping at an address inside it; one across its edge refused; an
  // unmap there leaves it reserved.
  at = r1 + 4096;
  CHECK(vx_as_map(self, v, 0, 4096, VX_MAP_WRITE, &at) == VX_OK && at == r1 + 4096);
  *(volatile uint64_t *)at = 42;
  uint64_t edge = r1 + (1 << 20) - 4096;
  CHECK(vx_as_map(self, v, 0, 8192, VX_MAP_WRITE, &edge) == VX_ERR_RANGE);
  CHECK(vx_as_unmap(self, at, 4096) == VX_OK);
  in_way = r1;
  CHECK(vx_as_reserve(self, 4096, 0, VX_AS_FIXED, &in_way) == VX_ERR_EXISTS && in_way == r1); // still there
  // AS_FIXED where a mapping is: EXISTS, naming where it starts.
  uint64_t placed = 0;
  CHECK(vx_as_map(self, v, 0, 4096, 0, &placed) == VX_OK);
  in_way = placed - 4096;
  CHECK(vx_as_reserve(self, 8192, 0, VX_AS_FIXED, &in_way) == VX_ERR_EXISTS && in_way == placed);
  CHECK(vx_as_unmap(self, placed, 4096) == VX_OK);
  // Released: what is mapped in it goes, and its range is free again.
  at = r2;
  CHECK(vx_as_map(self, v, 0, 4096, 0, &at) == VX_OK);
  uint64_t gone = r2;
  CHECK(vx_as_reserve(self, 1 << 20, 0, VX_AS_RELEASE, &gone) == VX_OK);
  vx_map_info mi;
  CHECK(vx_as_query(self, r2, &mi) != VX_OK || mi.base >= r2 + (1 << 20));
  CHECK(vx_as_reserve(self, 1 << 20, 0, VX_AS_RELEASE, &gone) == VX_ERR_NOT_FOUND);
  in_way = r2;
  CHECK(vx_as_reserve(self, 1 << 20, 1 << 16, VX_AS_FIXED, &in_way) == VX_OK && in_way == r2);
  CHECK(vx_as_reserve(self, 1 << 20, 0, VX_AS_RELEASE, &in_way) == VX_OK);
  CHECK(vx_as_reserve(self, 1 << 20, 0, VX_AS_RELEASE, &r1) == VX_OK);
  CHECK(vx_as_reserve(self, 4096, 3ull * 4096, 0, &in_way) == VX_ERR_RANGE); // not a power of two

  // No access: a guard page between two writable ones. A touch faults; the
  // handler opens it, and the write is made again.
  uint64_t g = 0;
  CHECK(vx_as_map(self, v, 0, 3ull * 4096, VX_MAP_WRITE, &g) == VX_OK);
  CHECK(vx_as_protect(self, g + 4096, 4096, VX_MAP_NOACCESS) == VX_OK);
  CHECK(vx_as_query(self, g + 4096, &mi) == VX_OK && (mi.flags & VX_MAP_NOACCESS));
  CHECK(vx_as_protect(self, g, 4096, VX_MAP_NOACCESS | VX_MAP_WRITE) == VX_ERR_INVALID);
  *(volatile uint64_t *)g = 1, *(volatile uint64_t *)(g + 8192) = 3;
  guard_at = g + 4096;
  CHECK(vx_exception_bind(self, 0, (uint64_t)handler, VX_EXCEPTION_IN_TASK) == VX_OK);
  *(volatile uint64_t *)(g + 4096) = 2;
  CHECK(vx_exception_bind(self, 0, 0, VX_EXCEPTION_IN_TASK) == VX_OK);
  guard_at = 0;
  CHECK(atomic_load(&guard_faults) == 1 && *(volatile uint64_t *)(g + 4096) == 2);
  CHECK(vx_as_unmap(self, g, 3ull * 4096) == VX_OK);
  uint64_t none = 0; // mapped no-access from the start: a reservation's placeholder
  CHECK(vx_as_map(self, v, 0, 4096, VX_MAP_NOACCESS, &none) == VX_OK &&
        vx_as_unmap(self, none, 4096) == VX_OK);
  vx_handle_close(v);

  // A resizable VMO: grown with zero pages, shrunk back; one made without it
  // is not resized.
  vx_handle rv, fixed;
  uint64_t value = 0x77, got = 1;
  CHECK(vx_vmo_create(4096, VX_VMO_RESIZABLE, &rv) == VX_OK &&
        vx_vmo_rw(rv, VX_VMO_WRITE, 0, &value, 8) == VX_OK);
  CHECK(vx_vmo_resize(rv, 3ull * 4096) == VX_OK);
  uint64_t ra = 0;
  CHECK(vx_as_map(self, rv, 0, 3ull * 4096, VX_MAP_WRITE, &ra) == VX_OK);
  CHECK(*(volatile uint64_t *)ra == 0x77 && *(volatile uint64_t *)(ra + 8192) == 0);
  *(volatile uint64_t *)(ra + 8192) = 9;
  CHECK(vx_vmo_rw(rv, VX_VMO_READ, 8192, &got, 8) == VX_OK && got == 9);
  CHECK(vx_as_unmap(self, ra, 3ull * 4096) == VX_OK);
  CHECK(vx_vmo_resize(rv, 4096) == VX_OK);
  CHECK(vx_vmo_rw(rv, VX_VMO_READ, 8192, &got, 8) == VX_ERR_RANGE);
  CHECK(vx_vmo_rw(rv, VX_VMO_READ, 0, &got, 8) == VX_OK && got == 0x77);
  CHECK(vx_vmo_create(4096, 0, &fixed) == VX_OK && vx_vmo_resize(fixed, 8192) == VX_ERR_UNSUPPORTED);
  CHECK(vx_vmo_create(4096, VX_VMO_RESIZABLE | VX_VMO_PAGER, &v) == VX_ERR_INVALID);
  vx_handle_close(fixed);
  vx_handle_close(rv);

  // VX_MAP_SHARED: a forked child maps the same VMO, and its write is seen.
  vx_handle sv = 0, port = 0;
  uint64_t sa = 0, sp = new_stack();
  CHECK(sp && vx_port_create(0, &port) == VX_OK && vx_vmo_create(4096, 0, &sv) == VX_OK &&
        vx_as_map(self, sv, 0, 4096, VX_MAP_WRITE | VX_MAP_SHARED, &sa) == VX_OK);
  fork_shared = sa;
  fork_page[7] = 0x1234;
  CHECK(is(run_fork(sp, port), "ok"));
  fork_shared = 0;
  CHECK(*(volatile uint64_t *)sa == 0x7777);
  CHECK(vx_as_protect(self, sa, 4096, VX_MAP_SHARED) == VX_ERR_INVALID); // as_map's alone
  CHECK(vx_as_unmap(self, sa, 4096) == VX_OK);
  vx_handle_close(sv);
  vx_handle_close(port);
}

// --- Seals and leases (ADR-0043) ---

static void test_leases(void) {
  // A seal: refused while mapped writable, then no write by anyone.
  vx_handle v, rv;
  uint64_t value = 0x5eed, got = 0, at = 0;
  CHECK(vx_vmo_create(4096, 0, &v) == VX_OK && vx_vmo_rw(v, VX_VMO_WRITE, 0, &value, 8) == VX_OK);
  CHECK(vx_as_map(self, v, 0, 4096, VX_MAP_WRITE, &at) == VX_OK);
  CHECK(vx_vmo_seal(v) == VX_ERR_BAD_STATE); // a writable mapping: as memfd's F_SEAL_WRITE
  CHECK(vx_as_unmap(self, at, 4096) == VX_OK && vx_vmo_seal(v) == VX_OK && vx_vmo_seal(v) == VX_OK);
  CHECK(vx_vmo_rw(v, VX_VMO_WRITE, 0, &value, 8) == VX_ERR_ACCESS);
  at = 0;
  CHECK(vx_as_map(self, v, 0, 4096, VX_MAP_WRITE, &at) == VX_ERR_ACCESS);
  CHECK(vx_as_map(self, v, 0, 4096, 0, &at) == VX_OK && *(volatile uint64_t *)at == 0x5eed);
  CHECK(vx_as_protect(self, at, 4096, VX_MAP_WRITE) == VX_ERR_ACCESS && vx_as_unmap(self, at, 4096) == VX_OK);
  CHECK(vx_vmo_create(4096, VX_VMO_RESIZABLE, &rv) == VX_OK && vx_vmo_seal(rv) == VX_OK &&
        vx_vmo_resize(rv, 8192) == VX_ERR_ACCESS);
  vx_handle_close(rv);

  // A lease: the same pages, read through it; one without MANAGE cannot
  // revoke; revoked, a touch is REVOKED and every use of it too.
  vx_handle w, lease, given, again, copy;
  CHECK(vx_vmo_create(2ull * 4096, 0, &w) == VX_OK && vx_vmo_rw(w, VX_VMO_WRITE, 4096, &value, 8) == VX_OK);
  CHECK(vx_vmo_lease(w, &lease) == VX_OK);
  CHECK(vx_handle_dup(lease, VX_RIGHT_READ | VX_RIGHT_MAP, &given) == VX_OK); // what a reader is given
  uint64_t la = 0;
  CHECK(vx_as_map(self, given, 0, 2ull * 4096, 0, &la) == VX_OK &&
        *(volatile uint64_t *)(la + 4096) == 0x5eed);
  value = 0x1111;
  CHECK(vx_vmo_rw(w, VX_VMO_WRITE, 4096, &value, 8) == VX_OK && *(volatile uint64_t *)(la + 4096) == 0x1111);
  CHECK(vx_vmo_revoke(given) == VX_ERR_ACCESS && vx_vmo_lease(given, &again) == VX_ERR_INVALID);
  CHECK(vx_vmo_revoke(w) == VX_ERR_INVALID); // not a lease
  CHECK(vx_vmo_revoke(lease) == VX_OK && vx_vmo_revoke(lease) == VX_OK);
  CHECK(vx_vmo_create(4096, 0, &revoked_spare) == VX_OK);
  CHECK(vx_exception_bind(self, 0, (uint64_t)handler, VX_EXCEPTION_IN_TASK) == VX_OK);
  got = *(volatile uint64_t *)(la + 4096ull + 8); // revoked: the handler puts a spare there
  CHECK(vx_exception_bind(self, 0, 0, VX_EXCEPTION_IN_TASK) == VX_OK);
  CHECK(atomic_load(&handled[VX_EXCEPTION_REVOKED]) == 1 && atomic_load(&revoked_at) == la + 4096ull + 8 &&
        got == 0);
  CHECK(vx_vmo_rw(given, VX_VMO_READ, 0, &got, 8) == VX_ERR_REVOKED);
  uint64_t la2 = 0;
  CHECK(vx_as_map(self, given, 0, 4096, 0, &la2) == VX_ERR_REVOKED);
  CHECK(vx_vmo_clone(given, 0, 4096, &copy) == VX_ERR_REVOKED);
  CHECK(vx_vmo_rw(w, VX_VMO_READ, 4096, &got, 8) == VX_OK && got == 0x1111); // the parent's are its own
  CHECK(vx_as_unmap(self, la, 2ull * 4096) == VX_OK);
  vx_handle_close(given);
  vx_handle_close(lease);
  vx_handle_close(revoked_spare);
  // Only plain anonymous memory is leased.
  CHECK(vx_vmo_create(4096, VX_VMO_RESIZABLE, &rv) == VX_OK &&
        vx_vmo_lease(rv, &again) == VX_ERR_UNSUPPORTED);
  vx_handle_close(rv);
  vx_handle_close(w);
  vx_handle_close(v);
}

// --- The review of 2026-10-07: regressions ---

static _Atomic int64_t lease_wait_result = 1;

static void lease_waiter(uint64_t arg, uint64_t addr) { // waits on a word through the parent's mapping
  (void)arg;
  atomic_store(&lease_wait_result, vx_futex_wait((const _Atomic uint32_t *)addr, 0, after_ms(3000)));
  vx_thread_exit();
}

static void test_review_fixes(void) {
  // A debugger's write into a read-only mapping of a lease is refused, not a
  // privatize that left its release slot unset (a kernel crash).
  vx_handle w = 0, lease = 0;
  uint64_t la = 0, pa = 0, one = 1;
  CHECK(vx_vmo_create(4096, 0, &w) == VX_OK && vx_vmo_lease(w, &lease) == VX_OK);
  CHECK(vx_as_map(self, lease, 0, 4096, 0, &la) == VX_OK);
  vx_mem_op op = {.address = la, .buffer = (uint64_t)&one, .size = 8, .write = 1};
  vx_status rw = vx_task_mem_rw(self, &op, 1);
  CHECK(rw == VX_OK && op.status == VX_ERR_UNSUPPORTED); // refused: a lease is never privatized

  // A futex in lent memory is one futex through the parent and the lease.
  CHECK(vx_as_map(self, w, 0, 4096, VX_MAP_WRITE, &pa) == VX_OK);
  vx_handle th = 0;
  CHECK(vx_thread_create(self, &th) == VX_OK &&
        vx_thread_start(th, (uint64_t)lease_waiter, new_stack(), 0, pa) == VX_OK);
  static _Atomic uint32_t never;
  vx_futex_wait(&never, 0, after_ms(50));                     // it is waiting
  CHECK(vx_futex_wake((const _Atomic uint32_t *)la, 1) == 1); // through the lease
  for (int i = 0; i < 1000 && atomic_load(&lease_wait_result) == 1; i++)
    vx_futex_wait(&never, 0, after_ms(1));
  CHECK(atomic_load(&lease_wait_result) == VX_OK);
  vx_handle_close(th);
  CHECK(vx_as_unmap(self, la, 4096) == VX_OK && vx_as_unmap(self, pa, 4096) == VX_OK);
  vx_handle_close(lease);
  vx_handle_close(w);

  // A placed mapping steps over one mapped at an address where placement was
  // to go next (mremap's growth in place), rather than failing EXISTS.
  vx_handle v = 0;
  uint64_t p = 0, fixed, q = 0;
  CHECK(vx_vmo_create(4ull * 4096, 0, &v) == VX_OK && vx_as_map(self, v, 0, 4096, 0, &p) == VX_OK);
  fixed = p + 4096; // the guard page, and where the next placed one would go
  CHECK(vx_as_map(self, v, 0, 4ull * 4096, 0, &fixed) == VX_OK);
  CHECK(vx_as_map(self, v, 0, 4096, 0, &q) == VX_OK && (q >= fixed + 4ull * 4096 || q + 4096 <= p));
  CHECK(vx_as_unmap(self, p, 4096) == VX_OK && vx_as_unmap(self, fixed, 4ull * 4096) == VX_OK &&
        vx_as_unmap(self, q, 4096) == VX_OK);
  vx_handle_close(v);
}

// --- Leases lent for one call (ADR-0043) ---

enum lent_mode { LENT_REPLY, LENT_HANG, LENT_CLOSE };

typedef struct lent_server {
  vx_handle end;
  enum lent_mode mode;
  _Atomic uint64_t value; // what it read through the lent memory
  _Atomic uint32_t lease; // the lease it was sent
  _Atomic uint32_t done;
} lent_server;

// Reads one request, maps its handle and reads it; then replies, or never
// does, or closes its end without a reply.
[[noreturn]] static void lent_worker(vx_handle unused, uint64_t arg) {
  (void)unused;
  lent_server *s = (lent_server *)arg;
  vx_handle port, got = 0;
  vx_packet pk;
  request rq;
  vx_msg_size size;
  vx_port_create(0, &port);
  vx_port_bind(port, s->end, VX_TRIGGER_READABLE, 1, 0);
  if (vx_port_wait(port, after_ms(2000), 0, &pk, 1) == 1 &&
      vx_channel_read(s->end, &rq, sizeof rq, &got, 1, &size) == VX_OK && size.handles == 1) {
    uint64_t at = 0;
    if (vx_as_map(self, got, 0, 4096, 0, &at) == VX_OK) atomic_store(&s->value, *(volatile uint64_t *)at);
    atomic_store(&s->lease, got);
    if (s->mode == LENT_REPLY) vx_channel_write(s->end, &rq, sizeof rq, nullptr, 0);
    if (s->mode == LENT_CLOSE) vx_handle_close(s->end);
  }
  vx_handle_close(port);
  atomic_store(&s->done, 1);
  vx_thread_exit();
}

// One call lending mem to a server in mode: the call's status, and the
// server's lease after it.
static vx_status lend_once(vx_handle mem, enum lent_mode mode, lent_server *s, vx_instant deadline) {
  vx_handle ch[2], th;
  *s = (lent_server){.mode = mode};
  if (vx_channel_create(0, ch) != VX_OK) return VX_ERR_NO_MEMORY;
  s->end = ch[1];
  uint64_t sp = new_stack();
  if (!sp || vx_thread_create(self, &th) != VX_OK ||
      vx_thread_start(th, (uint64_t)lent_worker, sp, 0, (uint64_t)s) != VX_OK)
    return VX_ERR_NO_MEMORY;
  request rq = {.n = 1}, reply = {};
  vx_call call = {.wr_bytes = &rq,
                  .wr_len = sizeof rq,
                  .wr_handles = &mem,
                  .wr_count = 1,
                  .rd_bytes = &reply,
                  .rd_cap = sizeof reply,
                  .lent = 1};
  vx_status st = vx_channel_call(ch[0], &call, deadline);
  while (mode != LENT_HANG && !atomic_load(&s->done)) vx_futex_wait(&s->done, 0, after_ms(10));
  vx_handle_close(ch[0]);
  if (mode != LENT_CLOSE) vx_handle_close(ch[1]);
  vx_handle_close(th);
  return st;
}

static void test_lent(void) {
  vx_handle mem;
  uint64_t value = 0x1e47, got = 0;
  CHECK(vx_vmo_create(4096, 0, &mem) == VX_OK && vx_vmo_rw(mem, VX_VMO_WRITE, 0, &value, 8) == VX_OK);
  static lent_server s;
  // A reply: the server read it through its lease, which is gone once the call returns.
  CHECK(lend_once(mem, LENT_REPLY, &s, after_ms(2000)) == VX_OK);
  CHECK(atomic_load(&s.value) == 0x1e47 && atomic_load(&s.lease));
  CHECK(vx_vmo_rw(atomic_load(&s.lease), VX_VMO_READ, 0, &got, 8) == VX_ERR_REVOKED);
  uint64_t at = 0;
  CHECK(vx_as_map(self, atomic_load(&s.lease), 0, 4096, 0, &at) == VX_ERR_REVOKED);
  CHECK(vx_vmo_revoke(atomic_load(&s.lease)) == VX_ERR_ACCESS); // the server's has no MANAGE
  vx_handle_close(atomic_load(&s.lease));
  CHECK(vx_vmo_rw(mem, VX_VMO_READ, 0, &got, 8) == VX_OK && got == 0x1e47); // the caller's handle stays
  // The server's end closed with no reply: PEER_CLOSED, and revoked.
  CHECK(lend_once(mem, LENT_CLOSE, &s, after_ms(2000)) == VX_ERR_PEER_CLOSED);
  CHECK(atomic_load(&s.value) == 0x1e47 &&
        vx_vmo_rw(atomic_load(&s.lease), VX_VMO_READ, 0, &got, 8) == VX_ERR_REVOKED);
  vx_handle_close(atomic_load(&s.lease));
  // A server that never replies: the deadline ends the call, and the lease.
  CHECK(lend_once(mem, LENT_HANG, &s, after_ms(300)) == VX_ERR_TIMED_OUT);
  while (!atomic_load(&s.done)) vx_futex_wait(&s.done, 0, after_ms(10));
  CHECK(atomic_load(&s.value) == 0x1e47 &&
        vx_vmo_rw(atomic_load(&s.lease), VX_VMO_READ, 0, &got, 8) == VX_ERR_REVOKED);
  vx_handle_close(atomic_load(&s.lease));
  // A lent handle that is not a VMO, or a bit past the handles: refused before
  // anything is sent, and the caller's handles stay.
  vx_handle ch[2];
  CHECK(vx_channel_create(0, ch) == VX_OK);
  request rq = {.n = 1};
  vx_handle port;
  CHECK(vx_port_create(0, &port) == VX_OK);
  vx_call call = {.wr_bytes = &rq, .wr_len = sizeof rq, .wr_handles = &port, .wr_count = 1, .lent = 1};
  CHECK(vx_channel_call(ch[0], &call, after_ms(100)) == VX_ERR_BAD_HANDLE);
  call.wr_handles = &mem, call.lent = 2;
  CHECK(vx_channel_call(ch[0], &call, after_ms(100)) == VX_ERR_INVALID);
  vx_msg_size size;
  CHECK(vx_channel_read(ch[1], &rq, sizeof rq, nullptr, 0, &size) == VX_ERR_SHOULD_WAIT);
  CHECK(vx_vmo_rw(mem, VX_VMO_READ, 0, &got, 8) == VX_OK && vx_handle_close(port) == VX_OK);
  vx_handle_close(ch[0]);
  vx_handle_close(ch[1]);
  vx_handle_close(mem);
}

// --- task_exec (ADR-0012) ---

// The program a forked child execs: it closes `probe`, a handle the child
// held before the exec, and exits if that fails as a closed handle does, or
// traps if the handle was still there.
static uint32_t write_exec_probe(uint8_t *code, vx_handle probe) {
  uint32_t n = 0;
#ifdef __x86_64__
#define EMIT(b)   (code[n++] = (uint8_t)(b))
#define EMIT32(v) (EMIT(v), EMIT((v) >> 8), EMIT((v) >> 16), EMIT((v) >> 24))
  EMIT(0xbf), EMIT32(probe);                                   // mov $probe, %edi
  EMIT(0xb8), EMIT32(VX_SYS_handle_close);                     // mov $handle_close, %eax
  EMIT(0x0f), EMIT(0x05);                                      // syscall
  EMIT(0x48), EMIT(0x3d), EMIT32((uint32_t)VX_ERR_BAD_HANDLE); // cmp $BAD_HANDLE, %rax
  EMIT(0x75), EMIT(0x07);                                      // jne 1f
  EMIT(0xb8), EMIT32(VX_SYS_thread_exit);                      // mov $thread_exit, %eax
  EMIT(0x0f), EMIT(0x05);                                      // syscall
  EMIT(0x0f), EMIT(0x0b);                                      // 1: ud2
#undef EMIT32
#undef EMIT
#else
#define EMIT(w)                                                                                              \
  (code[n] = (uint8_t)(w), code[n + 1] = (uint8_t)((w) >> 8), code[n + 2] = (uint8_t)((w) >> 16),            \
   code[n + 3] = (uint8_t)((w) >> 24), n += 4)
  EMIT(0x52800000u | (probe & 0xffff) << 5);              // movz w0, #probe & 0xffff
  EMIT(0x72a00000u | (probe >> 16) << 5);                 // movk w0, #probe >> 16, lsl #16
  EMIT(0xd2800008u | (uint32_t)VX_SYS_handle_close << 5); // movz x8, #handle_close
  EMIT(0xd4000001u);                                      // svc #0
  EMIT(0xb100001fu | (uint32_t)-VX_ERR_BAD_HANDLE << 10); // cmn x0, #-BAD_HANDLE
  EMIT(0x54000061u);                                      // b.ne 1f
  EMIT(0xd2800008u | (uint32_t)VX_SYS_thread_exit << 5);  // movz x8, #thread_exit
  EMIT(0xd4000001u);                                      // svc #0
  EMIT(0x00000000u);                                      // 1: udf #0
#undef EMIT
#endif
  return n;
}

// A forked child's first thread: it builds the probe in a scratch task and
// execs it. Its exit string is the probe's, or why the exec failed.
[[noreturn]] static void exec_child(vx_handle unused, uint64_t arg2) {
  (void)unused, (void)arg2;
  uint8_t code[64] = {};
  vx_handle scratch = 0, text = 0, stack = 0, ch[2] = {};
  uint64_t text_at = CHILD_CODE, stack_at = CHILD_STACK_TOP - 4096;
  bool ok = vx_channel_create(0, ch) == VX_OK;
  uint32_t len = write_exec_probe(code, ch[0]); // still held at the exec: it must be closed by it
  ok = ok && vx_task_create(VX_STR("execd"), &scratch) == VX_OK && vx_vmo_create(4096, 0, &text) == VX_OK &&
       vx_vmo_rw(text, VX_VMO_WRITE, 0, code, len) == VX_OK &&
       vx_as_map(scratch, text, 0, 4096, VX_MAP_EXEC, &text_at) == VX_OK &&
       vx_vmo_create(4096, 0, &stack) == VX_OK &&
       vx_as_map(scratch, stack, 0, 4096, VX_MAP_WRITE, &stack_at) == VX_OK;
  vx_handle_close(text);
  vx_handle_close(stack);
  if (ok) vx_task_exec(scratch, ch[1], CHILD_CODE, CHILD_STACK_TOP); // returns only on a failure
  vx_task_kill(self, VX_STR("exec failed"));
  vx_thread_exit();
}

static void test_exec(void) {
  vx_handle port = 0, child = 0, th = 0, scratch = 0, ch[2] = {};
  CHECK(vx_port_create(0, &port) == VX_OK);
  uint64_t sp = new_stack();
  // A forked child execs: its task, so its id and its EXIT binding, carry on,
  // under the new program's name, with none of its old handles.
  vx_task_summary before = {}, after = {};
  CHECK(vx_task_fork(VX_STR("forked"), &child) == VX_OK && vx_task_info(child, &before) == VX_OK);
  CHECK(vx_port_bind(port, child, VX_TRIGGER_EXIT, 99, 0) == VX_OK); // bound before the exec
  CHECK(vx_thread_create(child, &th) == VX_OK &&
        vx_thread_start(th, (uint64_t)exec_child, sp, 0, 0) == VX_OK);
  vx_handle_close(th);
  vx_packet pk;
  CHECK(vx_port_wait(port, after_ms(2000), 0, &pk, 1) == 1 && pk.key == 99 &&
        pk.value == 0); // once, at the end
  CHECK(vx_task_info(child, &after) == VX_OK && after.id == before.id && after.exit_len == 0 &&
        memcmp(after.name, "execd", 6) == 0);
  vx_handle_close(child);

  // Refused: a task of its own, and a caller with another thread (ktest has
  // one waiting now), before anything changes.
  CHECK(vx_task_create(VX_STR("scratch"), &scratch) == VX_OK && vx_channel_create(0, ch) == VX_OK);
  CHECK(vx_task_exec(self, ch[1], CHILD_CODE, CHILD_STACK_TOP) == VX_ERR_INVALID);
  static waiter w;
  uint32_t id = 0;
  CHECK(vx_thread_create_id(self, &th, &id) == VX_OK &&
        vx_thread_start(th, (uint64_t)interrupted_waiter, new_stack(), 0, (uint64_t)&w) == VX_OK);
  static _Atomic uint32_t never;
  vx_futex_wait(&never, 0, after_ms(20)); // it is waiting
  CHECK(vx_task_exec(scratch, ch[1], CHILD_CODE, CHILD_STACK_TOP) == VX_ERR_BAD_STATE);
  CHECK(vx_task_exec(scratch, ch[1], 0x0000'8000'0000'0000, CHILD_STACK_TOP) == VX_ERR_INVALID);
  vx_exception_bind(self, 0, (uint64_t)handler, VX_EXCEPTION_IN_TASK);
  vx_thread_interrupt(self, id, VX_STR("done")); // the waiter's wait ends, and it exits
  for (int i = 0; i < 1000 && !atomic_load(&w.done); i++) vx_futex_wait(&never, 0, after_ms(1));
  vx_exception_bind(self, 0, 0, VX_EXCEPTION_IN_TASK);
  vx_handle_close(th);
  vx_task_kill(scratch, VX_STR(""));
  vx_handle_close(scratch);
  vx_handle_close(ch[0]);
  vx_handle_close(ch[1]);
  vx_handle_close(port);
}

// --- The thread pointer (musl's TLS) ---

// The word the thread pointer points at, read through it as musl does.
static uint64_t tls_word(void) {
  uint64_t v;
#ifdef __x86_64__
  __asm__ volatile("movq %%fs:0, %0" : "=r"(v));
#else
  uint64_t *p;
  __asm__ volatile("mrs %0, tpidr_el0" : "=r"(p));
  v = *p;
#endif
  return v;
}

static bool tls_set(uint64_t value) {
  return vx_thread_state(self, 0, VX_STATE_SET_TLS, &value, sizeof value) == VX_OK;
}
static uint64_t tls_get(void) {
  uint64_t v = 0;
  return vx_thread_state(self, 0, VX_STATE_GET_TLS, &v, sizeof v) == VX_OK ? v : 1;
}

static shared tls_shared;
static _Atomic uint32_t tls_worker_bad;

// Its own thread pointer, kept across the switches its sleeps cause.
[[noreturn]] static void tls_worker(vx_handle unused, uint64_t arg) {
  (void)unused, (void)arg;
  static uint64_t mine = 0xb0b0'b0b0;
  if (!tls_set((uint64_t)&mine)) atomic_fetch_add(&tls_worker_bad, 1);
  set_stage(&tls_shared, 1);
  for (int i = 0; i < 20; i++) {
    if (tls_word() != mine || tls_get() != (uint64_t)&mine) atomic_fetch_add(&tls_worker_bad, 1);
    _Atomic uint32_t never = 0;
    vx_futex_wait(&never, 0, after_ms(1));
  }
  set_stage(&tls_shared, 2);
  vx_thread_exit();
}

static void test_tls(void) {
  static uint64_t main_word = 0xa1a1'a1a1;
  vx_handle th, child, other;
  CHECK(tls_set((uint64_t)&main_word) && tls_get() == (uint64_t)&main_word && tls_word() == main_word);
  // Each thread keeps its own, though both sleep and run on whichever CPU.
  uint64_t sp = new_stack();
  CHECK(sp != 0);
  CHECK(vx_thread_create(self, &th) == VX_OK);
  CHECK(vx_thread_start(th, (uint64_t)tls_worker, sp, 0, 0) == VX_OK);
  wait_for_stage(&tls_shared, 1);
  for (int i = 0; i < 20; i++) {
    CHECK(tls_word() == main_word);
    _Atomic uint32_t never = 0;
    vx_futex_wait(&never, 0, after_ms(1));
  }
  wait_for_stage(&tls_shared, 2);
  CHECK(atomic_load(&tls_worker_bad) == 0);
  CHECK(tls_word() == main_word && tls_get() == (uint64_t)&main_word);
  vx_handle_close(th);

  // Only a user address, and thread 0 only of the caller's own task.
  uint64_t bad = 0xffff'8000'0000'0000; // the kernel half
  CHECK(vx_thread_state(self, 0, VX_STATE_SET_TLS, &bad, sizeof bad) == VX_ERR_RANGE);
  CHECK(vx_thread_state(self, 0, VX_STATE_SET_TLS, &bad, 4) == VX_ERR_TOO_SMALL);
  CHECK(start_child(SPIN, &child));
  CHECK(vx_thread_state(child, 0, VX_STATE_GET_TLS, &bad, sizeof bad) == VX_ERR_INVALID);
  // Another thread's, while it is suspended: read, set, read back.
  uint64_t v = 1;
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_TLS, &v, sizeof v) == VX_ERR_BAD_STATE); // running
  CHECK(vx_thread_suspend(child, 1) == VX_OK);
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_TLS, &v, sizeof v) == VX_OK && v == 0); // never set
  v = 0x1000;
  CHECK(vx_thread_state(child, 1, VX_STATE_SET_TLS, &v, sizeof v) == VX_OK);
  v = 0;
  CHECK(vx_thread_state(child, 1, VX_STATE_GET_TLS, &v, sizeof v) == VX_OK && v == 0x1000);
  CHECK(vx_handle_dup(child, ((1u << VX_RIGHT_BIT_COUNT) - 1) & ~(uint32_t)VX_RIGHT_DEBUG, &other) == VX_OK);
  CHECK(vx_thread_state(other, 1, VX_STATE_GET_TLS, &v, sizeof v) == VX_ERR_BAD_STATE); // DEBUG needed
  vx_handle_close(other);
  CHECK(vx_thread_resume(child, 1) == VX_OK);
  CHECK(vx_task_kill(child, VX_STR("killed")) == VX_OK);
  vx_handle_close(child);
  CHECK(tls_set(0));
}

// --- FP/SIMD state, kept per thread ---

// A vector register and the FP control register (MXCSR; FPCR). The register
// is caller-saved (xmm7; v7), so declaring it clobbered makes no function save
// and restore it, and nothing between a put and a get uses it: the futex
// wrapper and after_ms use no SIMD.
#ifdef __x86_64__
// All of ymm7, its upper half AVX's (ADR-0035: XSAVE saves it): four lanes,
// v and three of its own, so a lane lost or mixed with another thread's shows.
static constexpr uint32_t FP_CTL_DEFAULT = 0x1f80, FP_CTL_ZERO = 0x7f80; // round toward zero
static void fp_lanes(uint64_t v, uint64_t lanes[4]) {
  lanes[0] = v, lanes[1] = ~v, lanes[2] = v ^ 0x5555'5555'5555'5555, lanes[3] = v + 1;
}
static void fp_put(uint64_t v, uint32_t ctl) {
  alignas(32) uint64_t lanes[4];
  fp_lanes(v, lanes);
  __asm__ volatile("vmovdqa %0, %%ymm7\n\tldmxcsr %1" : : "m"(lanes), "m"(ctl) : "xmm7");
}
static uint64_t fp_get(uint32_t *ctl) {
  alignas(32) uint64_t lanes[4], want[4];
  uint32_t c;
  __asm__ volatile("vmovdqa %%ymm7, %0\n\tstmxcsr %1" : "=m"(lanes), "=m"(c));
  *ctl = c;
  fp_lanes(lanes[0], want);
  bool whole = lanes[1] == want[1] && lanes[2] == want[2] && lanes[3] == want[3];
  bool clean = !lanes[0] && !lanes[1] && !lanes[2] && !lanes[3]; // a new thread's
  return whole || clean ? lanes[0] : 0xbad0'bad0'bad0'bad0;
}
#else
static constexpr uint32_t FP_CTL_DEFAULT = 0, FP_CTL_ZERO = 3u << 22; // FPCR.RMode: toward zero
static void fp_put(uint64_t v, uint32_t ctl) {
  __asm__ volatile("fmov d7, %0\n\tmsr fpcr, %1" : : "r"(v), "r"((uint64_t)ctl) : "v7");
}
static uint64_t fp_get(uint32_t *ctl) {
  uint64_t v, c;
  __asm__ volatile("fmov %0, d7\n\tmrs %1, fpcr" : "=&r"(v), "=r"(c));
  *ctl = (uint32_t)c;
  return v;
}
#endif

static shared fp_shared;
static _Atomic uint32_t fp_worker_bad;

// A new thread's registers are clean; then its own survive its sleeps.
[[noreturn]] static void fp_worker(vx_handle unused, uint64_t arg) {
  (void)unused, (void)arg;
  uint32_t ctl = 1;
  if (fp_get(&ctl) != 0 || ctl != FP_CTL_DEFAULT) atomic_fetch_add(&fp_worker_bad, 1);
  fp_put(0xb0b0'b0b0'b0b0'b0b0, FP_CTL_ZERO);
  set_stage(&fp_shared, 1);
  for (int i = 0; i < 20; i++) {
    _Atomic uint32_t never = 0;
    vx_futex_wait(&never, 0, after_ms(1));
    if (fp_get(&ctl) != 0xb0b0'b0b0'b0b0'b0b0 || ctl != FP_CTL_ZERO) atomic_fetch_add(&fp_worker_bad, 1);
  }
  set_stage(&fp_shared, 2);
  vx_thread_exit();
}

static void test_fp(void) {
  vx_handle th;
  uint32_t ctl = 0;
  fp_put(0xa1a1'a1a1'a1a1'a1a1, FP_CTL_DEFAULT);
  uint64_t sp = new_stack();
  CHECK(sp != 0);
  CHECK(vx_thread_create(self, &th) == VX_OK);
  CHECK(vx_thread_start(th, (uint64_t)fp_worker, sp, 0, 0) == VX_OK);
  wait_for_stage(&fp_shared, 1);
  bool kept = true;
  for (int i = 0; i < 20; i++) {
    _Atomic uint32_t never = 0;
    vx_futex_wait(&never, 0, after_ms(1));
    kept = kept && fp_get(&ctl) == 0xa1a1'a1a1'a1a1'a1a1 && ctl == FP_CTL_DEFAULT;
  }
  CHECK(kept);
  wait_for_stage(&fp_shared, 2);
  CHECK(atomic_load(&fp_worker_bad) == 0);
  vx_handle_close(th);
  // A call whose pages the kernel copies with its own SIMD (6c2: NEON on
  // aarch64, inside simd_begin) gives the caller back its registers.
  vx_handle v = 0, c = 0; // closing 0 is a harmless BAD_HANDLE
  fp_put(0xc3c3'c3c3'c3c3'c3c3, FP_CTL_ZERO);
  CHECK(vx_vmo_create(4ull * 4096, 0, &v) == VX_OK && vx_vmo_clone(v, 0, 4ull * 4096, &c) == VX_OK);
  CHECK(fp_get(&ctl) == 0xc3c3'c3c3'c3c3'c3c3 && ctl == FP_CTL_ZERO);
  fp_put(0, FP_CTL_DEFAULT);
  vx_handle_close(c);
  vx_handle_close(v);
  // What is above the baseline (6c3): AVX-512 runs where vx_cpu_has says so
  // (the kernel's XCR0 has its state: KVM on the Zen 5), and SVE is never
  // offered, as its state is not saved.
#ifdef __x86_64__
  if (vx_cpu_has(VX_CPU_AVX512)) {
    alignas(64) uint64_t z[8] = {1, 2, 3, 4, 5, 6, 7, 8};
    __asm__ volatile("vmovdqa64 %0, %%zmm16\n\tvpaddq %%zmm16, %%zmm16, %%zmm16\n\tvmovdqa64 %%zmm16, %0"
                     : "+m"(z));
    CHECK(z[0] == 2 && z[7] == 16);
  }
  CHECK(!vx_cpu_has(VX_CPU_AVX512) || (vx_cpu()->xfeatures & 0xe0) == 0xe0);
#else
  CHECK(!vx_cpu_has(VX_CPU_SVE));
#endif
  // And floating point itself, compiled: 1/3 rounds differently by mode.
  volatile double third = 1.0, three = 3.0;
  CHECK(third / three > 0.333 && third / three < 0.334);
}

static void test_vmo_clone(void) {
  vx_handle v, c;
  uint64_t words[2] = {11, 22}, got[2] = {};
  CHECK(vx_vmo_create(2ull * 4096, 0, &v) == VX_OK &&
        vx_vmo_rw(v, VX_VMO_WRITE, 4096, words, sizeof words) == VX_OK);
  CHECK(vx_vmo_clone(v, 4096, 4096, &c) == VX_OK); // its second page
  words[0] = 99;
  CHECK(vx_vmo_rw(v, VX_VMO_WRITE, 4096, words, sizeof words) ==
        VX_OK); // the original changes; the copy does not
  CHECK(vx_vmo_rw(c, VX_VMO_READ, 0, got, sizeof got) == VX_OK && got[0] == 11 && got[1] == 22);
  CHECK(vx_vmo_clone(v, 4096, 2ull * 4096, &c) == VX_ERR_RANGE &&
        vx_vmo_clone(v, 1, 4096, &c) == VX_ERR_RANGE);
  vx_handle_close(v);
}

const char *vx_main(void) {
  self = vx_self;
  test_spawn_message();
  test_m1_basics();
  test_channel_basics();
  test_handle_transfer();
  test_bindings();
  test_threads_and_calls();
  test_tasks();
  test_torn_down();
  test_port_waiters();
  test_unmap();
  test_copy_race();
  test_exception_port();
  test_in_task();
  test_note_stack();
  test_robust();
  test_vmo_clone();
  test_address_space();
  test_leases();
  test_lent();
  test_review_fixes();
  test_debugger();
  test_tls();
  test_fork();
  test_exec();
  test_fp();
  test_nested_channels();
  test_rings();
  test_vmo_rw();
  test_pager();
  test_keys();
  test_devices();
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
