// vx-rt: the user runtime for first-party programs (docs/04 §2): the entry
// point, syscall stubs, the spawn message, console output and the stack
// protector. A program includes this file, as its unity build, and defines
// vx_main.
//
// Programs are built with -mgeneral-regs-only: the kernel does not save
// FP/SIMD state across context switches yet.

#pragma once

#include "base.c"
#include "../vx-9p/ring.c"

// --- The console: /srv/cons, the file "cons" ---
//
// Output goes out a line at a time (or when the buffer fills), so lines from
// different programs do not interleave. If the connection breaks, which it
// does when svcd restarts the console driver, the next write connects again
// through the connector, once; if that fails too, output goes back to the
// kernel log.

static struct {
  vx_handle connector;
  p9_conn conn;
  uint32_t fid;
  bool open;
  size_t len;
  char line[512];
} vx_console;

static vx_status vx_console_open(void) {
  if (vx_console.conn.end) p9_ring_disconnect(&vx_console.conn);
  vx_console.open = false;
  uint32_t root = 0;
  vx_status st = p9_ring_connect(vx_console.connector, &vx_console.conn);
  if (st == VX_OK) st = p9c_attach(&vx_console.conn.c, VX_STR(""), &root);
  if (st == VX_OK) {
    st = p9c_walk(&vx_console.conn.c, root, VX_STR("cons"), &vx_console.fid);
    p9c_clunk(&vx_console.conn.c, root);
  }
  if (st == VX_OK) st = p9c_open(&vx_console.conn.c, vx_console.fid, P9_ORDWR);
  vx_console.open = st == VX_OK;
  return st;
}

static bool vx_console_put(const char *p, size_t n) {
  while (n) {
    int64_t w = vx_console.open ? p9c_write(&vx_console.conn.c, vx_console.fid, 0, p, (uint32_t)n) : -1;
    if (w <= 0) return false;
    p += w;
    n -= (size_t)w;
  }
  return true;
}

static void vx_console_flush(void) {
  size_t n = vx_console.len;
  vx_console.len = 0;
  if (!n || vx_console_put(vx_console.line, n)) return;
  if (vx_console_open() == VX_OK && vx_console_put(vx_console.line, n)) return; // the driver restarted
  vx_print_hook = nullptr;
  vx_debug_write((vx_str){vx_console.line, n});
}

static void vx_console_print(vx_str s) {
  for (size_t i = 0; i < s.len; i++) {
    vx_console.line[vx_console.len++] = s.ptr[i];
    if (s.ptr[i] == '\n' || vx_console.len == sizeof vx_console.line) vx_console_flush();
  }
}

// Sends output to the console server behind `connector` (a /srv/cons
// connector, which this keeps). Programs get one in their spawn message;
// svcd calls this itself once it has started the console driver.
[[maybe_unused]] static vx_status vx_console_attach(vx_handle connector) {
  vx_console.connector = connector;
  vx_status st = vx_console_open();
  if (st == VX_OK) vx_print_hook = vx_console_print;
  return st;
}

// Reads what the console has: a line, in its cooked mode. 0 at end of file.
[[maybe_unused]] static int64_t vx_console_read(void *buf, uint32_t count) {
  if (vx_console.len) vx_console_flush(); // a prompt goes out before the wait
  if (!vx_console.open) return VX_ERR_BAD_STATE;
  int64_t n = p9c_read(&vx_console.conn.c, vx_console.fid, 0, buf, count);
  if (n < 0 && vx_console_open() == VX_OK) n = p9c_read(&vx_console.conn.c, vx_console.fid, 0, buf, count);
  return n;
}

// Called by _start with the bootstrap channel. The thread ends with vx_main's
// return value as its exit status; what it printed without a newline goes out
// first.
[[noreturn]] void vx_start(vx_handle bootstrap) {
  vx_read_spawn(bootstrap);
  vx_handle console = vx_spawn_take("console");
  if (console && vx_console_attach(console) != VX_OK) vx_print(VX_STR("vx-rt: cannot open the console\n"));
  int status = vx_main();
  if (vx_print_hook) vx_console_flush();
  vx_thread_exit(status);
}

#ifdef __x86_64__
[[gnu::naked, noreturn]] void _start(void) {
  __asm__("endbr64\n\t"
          "xorl %ebp, %ebp\n\t"
          "andq $-16, %rsp\n\t"
          "call vx_start\n\t" // the argument is already in rdi
          "ud2");
}
#else
[[gnu::naked, noreturn]] void _start(void) {
  __asm__("hint #34\n\t" // bti c
          "mov x29, xzr\n\t"
          "mov x30, xzr\n\t"
          "bl vx_start\n\t" // the argument is already in x0
          "brk #0");
}
#endif
