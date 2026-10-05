// vx-rt stdio: the console and the standard input and output pipes, which
// vx_print and vx_read reach. Defines no external symbol (base.c).

#pragma once

#include "base.c"
#include "../vx-9p/ring.c"

// --- The console: /srv/cons, the file "cons" ---
//
// Output goes out a line at a time (or when the buffer fills), so lines from
// different programs do not interleave. If the connection breaks, which it
// does when svcd restarts the console driver, the next write connects again
// through the connector; if that fails too, that line goes to the kernel log,
// and the next one tries again.

static struct {
  vx_handle connector;
  p9_conn conn;
  uint32_t fid;
  bool open;
  size_t len;
  char line[512];
  vx_instant retry_at; // no reconnecting before this, after a failure
} vx_console;

// Connects (again). After a failure it does not try for a second, so a
// console that is gone for good costs each line nothing, not a connect's wait.
static vx_status vx_console_open(void) {
  if (vx_console.conn.end) p9_ring_disconnect(&vx_console.conn);
  vx_console.open = false;
  if (vx_clock_read() < vx_console.retry_at) return VX_ERR_PEER_CLOSED;
  uint32_t root = 0;
  vx_status st = p9_ring_connect(vx_console.connector, &vx_console.conn);
  if (st == VX_OK) st = p9c_attach(&vx_console.conn.c, VX_STR(""), &root);
  if (st == VX_OK) {
    st = p9c_walk(&vx_console.conn.c, root, VX_STR("cons"), &vx_console.fid);
    p9c_clunk(&vx_console.conn.c, root);
  }
  if (st == VX_OK) st = p9c_open(&vx_console.conn.c, vx_console.fid, P9_ORDWR);
  vx_console.open = st == VX_OK;
  if (!vx_console.open) vx_console.retry_at = vx_clock_read() + 1'000'000'000;
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
  if (!vx_console.connector) return VX_ERR_BAD_STATE;
  // Until the console is back (the driver restarting), wait for it rather
  // than fail: a reader takes an error for the end of its input.
  for (;;) {
    int64_t n = vx_console.open ? p9c_read(&vx_console.conn.c, vx_console.fid, 0, buf, count) : -1;
    if (n >= 0) return n;
    if (vx_console_open() == VX_OK) continue;
    static _Atomic uint32_t never;
    vx_futex_wait(&never, 0, vx_console.retry_at); // a second, then try again
  }
}

// --- Standard input, output and error: pipes ---
//
// A spawn message may carry "stdin", "stdout" and "stderr", channel ends that
// the parent (a shell) joins into pipes. Each message on one is a header and
// some bytes; the writer closing its end is the end of the file. Output goes
// a line at a time, as to the console. Without stdout, output goes to the
// console; without stderr, errors (vx_eprint) go to the console, even when
// stdout is a pipe, so they never reach the next program as data. Without
// stdin, vx_read reads the console.

static struct {
  vx_handle in, out, err, port;
  alignas(vx_msg_header) uint8_t msg[sizeof(vx_msg_header) + 4096]; // stdin's current message,
  uint32_t msg_len, msg_pos;                                        // and how much of it has been read
  bool in_ended;
  bool closed_bound; // PEER_CLOSED on stdin is bound once; it fires once
  size_t len;
  alignas(vx_msg_header) uint8_t line[sizeof(vx_msg_header) + 512]; // stdout's line, after a header
  size_t err_len;
  alignas(vx_msg_header) uint8_t err_line[sizeof(vx_msg_header) + 512]; // stderr's
} vx_stdio;

// Writes msg (a header, then n bytes) to a pipe's channel end.
static void vx_pipe_write(vx_handle end, uint8_t *msg, size_t n) {
  *(vx_msg_header *)msg = (vx_msg_header){};
  for (int tries = 0;; tries++) {
    vx_status st = vx_channel_write(end, msg, (uint32_t)(sizeof(vx_msg_header) + n), nullptr, 0);
    if (st != VX_ERR_SHOULD_WAIT) return; // written, or no one is reading any more
    // The reader is behind: the channel's queue is full. Wait a little and try again.
    static _Atomic uint32_t never;
    vx_futex_wait(&never, 0, vx_clock_read() + (tries < 10 ? 100'000 : 1'000'000));
  }
}

static void vx_stdout_flush(void) {
  size_t n = vx_stdio.len;
  vx_stdio.len = 0;
  if (n && vx_stdio.out) vx_pipe_write(vx_stdio.out, vx_stdio.line, n);
}

static void vx_stderr_flush(void) {
  size_t n = vx_stdio.err_len;
  vx_stdio.err_len = 0;
  if (n && vx_stdio.err) vx_pipe_write(vx_stdio.err, vx_stdio.err_line, n);
}

// Prints an error: to stderr, or without one, to the console.
[[maybe_unused]] static void vx_eprint(vx_str s) {
  vx_mutex_lock(&vx_stdio_lock);
  if (!vx_stdio.err) {
    if (vx_console.connector)
      vx_console_print(s);
    else if (vx_print_hook)
      vx_print_hook(s); // vx_print's way, under the lock already held
    else
      vx_debug_write(s);
  } else {
    for (size_t i = 0; i < s.len; i++) {
      vx_stdio.err_line[sizeof(vx_msg_header) + vx_stdio.err_len++] = (uint8_t)s.ptr[i];
      if (s.ptr[i] == '\n' || vx_stdio.err_len == sizeof vx_stdio.err_line - sizeof(vx_msg_header))
        vx_stderr_flush();
    }
  }
  vx_mutex_unlock(&vx_stdio_lock);
}

[[maybe_unused]] static void vx_stdout_print(vx_str s) {
  for (size_t i = 0; i < s.len; i++) {
    vx_stdio.line[sizeof(vx_msg_header) + vx_stdio.len++] = (uint8_t)s.ptr[i];
    if (s.ptr[i] == '\n' || vx_stdio.len == sizeof vx_stdio.line - sizeof(vx_msg_header)) vx_stdout_flush();
  }
}

// Reads up to count bytes of standard input: 0 at its end, or a negative vx_status.
[[maybe_unused]] static int64_t vx_read(void *buf, uint32_t count) {
  if (!vx_stdio.in) return vx_console_read(buf, count);
  if (vx_stdio.len) vx_stdout_flush();
  while (vx_stdio.msg_pos == vx_stdio.msg_len && !vx_stdio.in_ended) {
    vx_msg_size size;
    vx_status st = vx_channel_read(vx_stdio.in, vx_stdio.msg, sizeof vx_stdio.msg, nullptr, 0, &size);
    if (st == VX_OK && size.bytes >= sizeof(vx_msg_header)) {
      vx_stdio.msg_len = size.bytes;
      vx_stdio.msg_pos = sizeof(vx_msg_header);
    } else if (st == VX_ERR_SHOULD_WAIT) {
      vx_packet pk;
      if (!vx_stdio.port && vx_port_create(0, &vx_stdio.port) != VX_OK) return VX_ERR_NO_MEMORY;
      vx_port_bind(vx_stdio.port, vx_stdio.in, VX_TRIGGER_READABLE, 0, 0);
      if (!vx_stdio.closed_bound) // once: binding it each time would leave one per read behind
        vx_stdio.closed_bound =
            vx_port_bind(vx_stdio.port, vx_stdio.in, VX_TRIGGER_PEER_CLOSED, 1, 0) == VX_OK;
      vx_port_wait(vx_stdio.port, VX_INFINITE, 0, &pk, 1);
    } else if (st != VX_OK) {
      vx_stdio.in_ended = true; // the writer has gone (or sent what we cannot read)
    }
  }
  uint32_t n = vx_stdio.msg_len - vx_stdio.msg_pos;
  if (n > count) n = count;
  memcpy(buf, vx_stdio.msg + vx_stdio.msg_pos, n);
  vx_stdio.msg_pos += n;
  return n;
}
