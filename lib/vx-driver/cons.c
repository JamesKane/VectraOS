// vx-driver cons: the console file server that serial drivers share (docs/01
// §7.3, the serial class). The driver supplies the device: how much it can
// take now, how to send a byte, and whether to interrupt when it can take
// more; it feeds cons the bytes that arrive, and pumps output from its
// interrupt handler.
//
// The tree is one file, /cons. Reads are cooked, as Plan 9's cons is: typed
// bytes are echoed and gathered into a line, with backspace (BS or DEL) and
// kill-line (^U), and a read returns at most one line, once it is ended (by
// return) or sent (^D). ^D on an empty line makes one read return 0, the end
// of the file. Writes go out with each newline as CR LF. A read with nothing
// typed, or a write with no room, waits (p9_serve's P9_DEFER) until the
// driver's next interrupt makes progress. (Raw mode, through consctl, comes
// with the line editor that needs it.)

#pragma once

#include "../vx-9p/ring_server.c"

typedef struct vx_cons {
  void *dev;
  uint32_t (*tx_room)(void *dev);        // bytes the device can take now
  void (*tx_byte)(void *dev, uint8_t b); // one of them
  void (*tx_wanted)(void *dev, bool on); // interrupt when it can take more
  uint8_t out[8192];                     // output not yet sent; free-running indices
  uint32_t out_head, out_tail;
  uint8_t in[4096]; // finished lines, for reads
  uint32_t in_head, in_tail;
  char line[256]; // the line being typed
  uint32_t line_len;
  uint32_t eofs; // ^D on an empty line: reads that return 0
} vx_cons;

enum : uint64_t { CONS_ROOT = 1, CONS_FILE = 2 };

static uint32_t cons_out_room(const vx_cons *c) {
  return (uint32_t)sizeof c->out - (c->out_tail - c->out_head);
}

static void cons_out(vx_cons *c, uint8_t b) {
  if (cons_out_room(c)) c->out[c->out_tail++ % sizeof c->out] = b;
}

// Sends what the device will take, and asks for an interrupt if more is waiting.
[[maybe_unused]] static void vx_cons_pump(vx_cons *c) {
  for (uint32_t room = c->tx_room(c->dev); room && c->out_head != c->out_tail; room--)
    c->tx_byte(c->dev, c->out[c->out_head++ % sizeof c->out]);
  c->tx_wanted(c->dev, c->out_head != c->out_tail);
}

static void cons_echo(vx_cons *c, uint8_t b) {
  if (b == '\n') cons_out(c, '\r');
  cons_out(c, b);
}

static void cons_finish_line(vx_cons *c) {
  uint32_t room = (uint32_t)sizeof c->in - (c->in_tail - c->in_head);
  for (uint32_t i = 0; i < c->line_len && i < room; i++)
    c->in[c->in_tail++ % sizeof c->in] = (uint8_t)c->line[i];
  c->line_len = 0;
}

// A byte from the device, through the line discipline.
[[maybe_unused]] static void vx_cons_input(vx_cons *c, uint8_t b) {
  if (b == '\r') b = '\n';
  if (b == 0x08 || b == 0x7f) { // erase
    if (c->line_len) {
      c->line_len--;
      cons_out(c, '\b'), cons_out(c, ' '), cons_out(c, '\b');
    }
  } else if (b == 0x15) { // ^U: kill the line
    for (; c->line_len; c->line_len--) cons_out(c, '\b'), cons_out(c, ' '), cons_out(c, '\b');
  } else if (b == 0x04) { // ^D: send the line, or end the file
    if (c->line_len)
      cons_finish_line(c);
    else
      c->eofs++;
  } else if (b == '\n' || b >= 0x20 || b == '\t') {
    if (c->line_len < sizeof c->line - 1 || b == '\n') { // a full line keeps room for its newline
      c->line[c->line_len++] = (char)b;
      cons_echo(c, b);
    }
    if (b == '\n') cons_finish_line(c);
  }
}

// --- The file system ---

static vx_status cons_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = CONS_ROOT;
  return VX_OK;
}

static vx_status cons_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  if (dir != CONS_ROOT || name.len != 4 || memcmp(name.ptr, "cons", 4) != 0) return VX_ERR_NOT_FOUND;
  *child = CONS_FILE;
  return VX_OK;
}

static vx_status cons_parent(void *ctx, uint64_t node, uint64_t *parent) {
  (void)ctx, (void)node;
  *parent = CONS_ROOT;
  return VX_OK;
}

static vx_status cons_stat(void *ctx, uint64_t node, p9_stat *out) {
  (void)ctx;
  bool dir = node == CONS_ROOT;
  *out = (p9_stat){.qid = {dir ? P9_QTDIR : P9_QTFILE, 0, node},
                   .mode = dir ? P9_DMDIR | 0555 : 0666,
                   .name = dir ? VX_STR("/") : VX_STR("cons"),
                   .uid = VX_STR("cons"),
                   .gid = VX_STR("cons"),
                   .muid = VX_STR("cons")};
  return VX_OK;
}

static vx_status cons_open(void *ctx, uint64_t node, uint8_t mode) {
  (void)ctx, (void)node;
  return mode & (P9_OTRUNC | P9_ORCLOSE) ? VX_ERR_ACCESS : VX_OK;
}

static vx_status cons_read(void *ctx, uint64_t node, uint64_t offset, uint8_t *buf, uint32_t *count) {
  vx_cons *c = ctx;
  (void)node, (void)offset; // a stream: offsets mean nothing
  if (c->in_head == c->in_tail) {
    if (!c->eofs) return VX_ERR_SHOULD_WAIT;
    c->eofs--;
    *count = 0;
    return VX_OK;
  }
  uint32_t n = 0;
  while (n < *count && c->in_head != c->in_tail) {
    uint8_t b = c->in[c->in_head++ % sizeof c->in];
    buf[n++] = b;
    if (b == '\n') break; // one line at a time
  }
  *count = n;
  return VX_OK;
}

static vx_status cons_write(void *ctx, uint64_t node, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  vx_cons *c = ctx;
  (void)node, (void)offset;
  uint32_t n = 0;
  while (n < *count && cons_out_room(c) >= 2) { // room for a newline's CR LF
    cons_echo(c, buf[n]);
    n++;
  }
  vx_cons_pump(c);
  if (!n && *count) return VX_ERR_SHOULD_WAIT;
  *count = n;
  return VX_OK;
}

static vx_status cons_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx, (void)dir;
  if (index) return VX_ERR_NOT_FOUND;
  *child = CONS_FILE;
  return VX_OK;
}

// The file server for a console, to put in a p9_ring_server.
[[maybe_unused]] static p9_fs vx_cons_fs(vx_cons *c) {
  return (p9_fs){.ctx = c,
                 .attach = cons_attach,
                 .walk = cons_walk,
                 .parent = cons_parent,
                 .stat = cons_stat,
                 .open = cons_open,
                 .read = cons_read,
                 .readdir = cons_readdir,
                 .write = cons_write};
}

// The driver's own output goes straight to its device's queue.
static vx_cons *vx_cons_self;

static void cons_print_self(vx_str s) {
  for (size_t i = 0; i < s.len; i++) cons_echo(vx_cons_self, (uint8_t)s.ptr[i]);
  vx_cons_pump(vx_cons_self);
}

[[maybe_unused]] static void vx_cons_print_here(vx_cons *c) {
  vx_cons_self = c;
  vx_print_hook = cons_print_self;
}
