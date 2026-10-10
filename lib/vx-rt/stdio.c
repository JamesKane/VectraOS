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

// Connects (again), waiting at most `wait`. After a failure it does not try
// for a second, so a console that is gone for good costs each line nothing,
// not a connect's wait.
static constexpr vx_duration VX_CONSOLE_AGAIN = 100'000'000; // a reconnect's wait

static vx_status vx_console_open(vx_duration wait) {
  if (vx_console.conn.end) p9_ring_disconnect(&vx_console.conn);
  vx_console.open = false;
  if (vx_clock_read() < vx_console.retry_at) return VX_ERR_PEER_CLOSED;
  uint32_t root = 0;
  vx_status st = p9_ring_connect_within(vx_console.connector, &vx_console.conn, wait);
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
  // Again, after a failure, waiting a tenth of a second, not a connect's 5:
  // while the console's driver restarts each line would wait that long
  // (svcd's, the system's: the Rust port's finding); it goes to the
  // kernel's log instead.
  if (vx_console_open(VX_CONSOLE_AGAIN) == VX_OK && vx_console_put(vx_console.line, n)) return;
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
  vx_status st = vx_console_open(5'000'000'000); // the first: a console server starting may take a while
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
    if (vx_console_open(VX_CONSOLE_AGAIN) == VX_OK) continue;
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

// A pipe's reading end, read as a stream: its messages' bytes in turn.
typedef struct vx_pipe_in {
  vx_handle end, port;
  alignas(vx_msg_header) uint8_t msg[sizeof(vx_msg_header) + 4096]; // the current message,
  uint32_t msg_len, msg_pos;                                        // and how much of it has been read
  bool ended;
  bool closed_bound; // PEER_CLOSED is bound once; it fires once
} vx_pipe_in;

static struct {
  vx_handle in, out, err;
  vx_pipe_in reader; // stdin's
  size_t len;
  alignas(vx_msg_header) uint8_t line[sizeof(vx_msg_header) + 4096]; // stdout's lines, after a header
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
  vx_lock(&vx_stdio_lock);
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
  vx_unlock(&vx_stdio_lock);
}

// Whole lines go out at once, as many as a message holds (4096 bytes, what
// every pipe reader takes); a line not yet ended waits for its end, or for
// a read of stdin (M7 step 7f1: a message a line was the terminal's
// bottleneck).
[[maybe_unused]] static void vx_stdout_print(vx_str s) {
  uint8_t *buf = vx_stdio.line + sizeof(vx_msg_header);
  size_t cap = sizeof vx_stdio.line - sizeof(vx_msg_header);
  for (size_t i = 0; i < s.len;) {
    size_t take = s.len - i < cap - vx_stdio.len ? s.len - i : cap - vx_stdio.len;
    memcpy(buf + vx_stdio.len, s.ptr + i, take);
    vx_stdio.len += take, i += take;
    if (vx_stdio.len == cap) vx_stdout_flush();
  }
  size_t end = vx_stdio.len;
  while (end && buf[end - 1] != '\n') end--;
  if (!end || !vx_stdio.out) return;
  vx_pipe_write(vx_stdio.out, vx_stdio.line, end);
  memmove(buf, buf + end, vx_stdio.len - end);
  vx_stdio.len -= end;
}

// Reads up to count bytes from a pipe: 0 at its end, or a negative vx_status.
static int64_t vx_pipe_read(vx_pipe_in *p, void *buf, uint32_t count) {
  while (p->msg_pos == p->msg_len && !p->ended) {
    vx_msg_size size;
    vx_status st = vx_channel_read(p->end, p->msg, sizeof p->msg, nullptr, 0, &size);
    if (st == VX_OK && size.bytes >= sizeof(vx_msg_header)) {
      p->msg_len = size.bytes;
      p->msg_pos = sizeof(vx_msg_header);
    } else if (st == VX_ERR_SHOULD_WAIT) {
      vx_packet pk;
      if (!p->port && vx_port_create(0, &p->port) != VX_OK) return VX_ERR_NO_MEMORY;
      vx_port_bind(p->port, p->end, VX_TRIGGER_READABLE, 0, 0);
      if (!p->closed_bound) // once: binding it each time would leave one per read behind
        p->closed_bound = vx_port_bind(p->port, p->end, VX_TRIGGER_PEER_CLOSED, 1, 0) == VX_OK;
      vx_port_wait(p->port, VX_INFINITE, 0, &pk, 1);
    } else if (st != VX_OK) {
      p->ended = true; // the writer has gone (or sent what we cannot read)
    }
  }
  uint32_t n = p->msg_len - p->msg_pos;
  if (n > count) n = count;
  memcpy(buf, p->msg + p->msg_pos, n);
  p->msg_pos += n;
  return n;
}

// Reads up to count bytes of standard input: 0 at its end, or a negative vx_status.
[[maybe_unused]] static int64_t vx_stdin_read(void *buf, uint32_t count) {
  if (!vx_stdio.in) return vx_console_read(buf, count);
  if (vx_stdio.len) vx_stdout_flush();
  if (vx_stdio.err_len) vx_stderr_flush(); // a prompt (rc's, on stderr) before the wait for its answer
  vx_stdio.reader.end = vx_stdio.in;
  return vx_pipe_read(&vx_stdio.reader, buf, count);
}

// --- Descriptors 3 to 9 (M6 step 6d7b2, ADR-0040) ---
//
// The spawn message's fd= records (musl's back end's format): fd=N
// pipe=read|write end=NAME, a channel end carrying the pipe protocol; or fd=N
// file=PATH flags=F offset=O [token=T], an open file, which a token joins.
// A program passes them on to its own children (rc) and opens them as /fd/N
// (vx-ns).

static constexpr uint32_t VX_FDS = 10;

typedef struct vx_fd_entry {
  vx_handle end; // a pipe's
  bool reader;   // the reading end
  bool file;     // an open file instead: where it is, how it was opened, and where it was at
  uint32_t flags;
  uint64_t offset;
  size_t path_len;
  char path[256];
  bool has_token; // a token to join it by, good once
  uint8_t token[16];
} vx_fd_entry;

static vx_fd_entry vx_fds[VX_FDS];

// Descriptor fd's open-file record, 3 to 9; nullptr if it is not one.
[[maybe_unused]] static vx_fd_entry *vx_fd_file(uint32_t fd) {
  return fd >= 3 && fd < VX_FDS && vx_fds[fd].file ? &vx_fds[fd] : nullptr;
}

// Descriptor fd's channel end, and whether it is a reading end (0 to 2 are
// stdin, stdout and stderr); VX_HANDLE_NONE if the process has none.
[[maybe_unused]] static vx_handle vx_fd_channel(uint32_t fd, bool *reader) {
  *reader = fd == 0;
  if (fd == 0) return vx_stdio.in;
  if (fd == 1 || fd == 2) return fd == 1 ? vx_stdio.out : vx_stdio.err;
  if (fd >= VX_FDS) return VX_HANDLE_NONE;
  *reader = vx_fds[fd].reader;
  return vx_fds[fd].end;
}

[[maybe_unused]] static void vx_fds_from_spawn(void) { // vx-rt's start; musl's back end reads them itself
  static char scratch[VX_CHANNEL_MAX_BYTES];
  vx_ndb_reader r = {.src = vx_spawn.text, .scratch = scratch, .scratch_cap = sizeof scratch};
  vx_ndb_record rec;
  while (vx_ndb_next(&r, &rec) == VX_NDB_RECORD) {
    uint64_t fd;
    if (!vx_ndb_get_u64(&rec, "fd", &fd) || fd < 3 || fd >= VX_FDS) continue;
    if (vx_ndb_has(&rec, "file")) { // an open file: opened, or joined, when /fd/N is
      vx_str path = vx_ndb_get(&rec, "file"), token = vx_ndb_get(&rec, "token");
      uint64_t flags = 0, offset = 0;
      if (path.len >= sizeof vx_fds[fd].path) continue;
      vx_ndb_get_u64(&rec, "flags", &flags), vx_ndb_get_u64(&rec, "offset", &offset);
      vx_fds[fd] =
          (vx_fd_entry){.file = true, .flags = (uint32_t)flags, .offset = offset, .path_len = path.len};
      memcpy(vx_fds[fd].path, path.ptr, path.len);
      if (token.len == 16) memcpy(vx_fds[fd].token, token.ptr, 16), vx_fds[fd].has_token = true;
      continue;
    }
    if (!vx_ndb_has(&rec, "pipe")) continue;
    char name[16] = {};
    vx_str h = vx_ndb_get(&rec, "end");
    if (h.len >= sizeof name) continue;
    memcpy(name, h.ptr, h.len);
    vx_handle end = vx_spawn_take(name);
    if (!end) continue;
    if (vx_fds[fd].end) vx_handle_close(vx_fds[fd].end);
    vx_fds[fd].end = end, vx_fds[fd].reader = vx_ndb_get(&rec, "pipe").len == 4; // "read"
  }
}
