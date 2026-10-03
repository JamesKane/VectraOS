// ptyd: pseudo-terminals (docs/01 §9), posted as /srv/ptyd and mounted on
// /dev by the POSIX template (/lib/ns/posix).
//
//   ptmx        opening it makes a new terminal: the fid becomes its master
//   pts/N       terminal N's slave: what the program on it reads and writes
//   pts/N.ctl   its settings as an ndb record: reading gives them, writing
//               changes those it names (the musl back end's tcgetattr,
//               tcsetattr, TIOCGWINSZ, tcsetpgrp and the rest)
//
// The line discipline is here, as Linux's: input typed at the master is
// edited in canonical mode (erase, kill, ^D), echoed, and turned into signals
// (^C, ^Z, ^\) to the terminal's foreground process group: a note written to
// the group's notepg in /proc (ADR-0011), "interrupt" for ^C as in Plan 9;
// the slave's output has NL made CR NL (ONLCR). A read with nothing to give
// is held until there is (the ring server's SHOULD_WAIT). A signal ptyd sends
// ends the slave reads it holds, as "interrupted", so ^C at a prompt is seen
// at once. The termios numbers are Linux's: the POSIX personality's.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-ns/spawn.c"
#include "../../lib/vx-posix/posix.h"

static constexpr uint32_t PTYS = 16, BUF = 4096, NCCS = 32;
enum : uint64_t {
  ROOT = 1,
  PTMX = 2,
  PTS = 3,
  MASTER = 0x100,
  SLAVE = 0x200,
  CTL = 0x300
}; // + pty for the last three

// Linux's termios bits and control characters, as far as ptyd acts on them.
enum : uint32_t {
  T_ICRNL = 0400,
  T_IUTF8 = 040000,
  T_OPOST = 01,
  T_ONLCR = 04,
  T_ISIG = 01,
  T_ICANON = 02,
  T_ECHO = 010
};
enum : uint32_t { T_ECHOE = 020, T_ECHOK = 040 };
enum : uint32_t { V_INTR = 0, V_QUIT = 1, V_ERASE = 2, V_KILL = 3, V_EOF = 4, V_MIN = 6, V_SUSP = 10 };
static constexpr int64_t SIGINT = 2, SIGQUIT = 3, SIGTSTP = 20, SIGWINCH = 28;

typedef struct ring {
  uint8_t b[BUF];
  uint32_t head, len;
} ring;

typedef struct pty {
  bool used, master_gone;
  uint32_t masters, slaves; // opens of each side
  uint32_t iflag, oflag, cflag, lflag;
  uint8_t cc[NCCS];
  uint16_t rows, cols;
  int64_t pgrp; // the foreground process group, 0 for none
  ring in;      // ended lines (canonical) or bytes, for the slave to read
  // Where a read of `in` must stop though no newline came: after a line a
  // ^D sent as it was, or, where nothing came since, the end of the file (a
  // read of 0). Positions count the bytes ever put in `in`.
  uint64_t in_put, in_taken;
  uint64_t breaks[16];
  uint32_t nbreaks;
  uint8_t line[BUF]; // the line being typed (canonical)
  uint32_t line_len;
  ring out;         // for the master to read: the slave's output and echo
  bool reading;     // a slave read is held, waiting for input
  bool interrupted; // a signal was sent while one was: it ends
} pty;

static pty ptys[PTYS];
static vx_ns ns;          // /proc, to signal process groups
static bool proc_mounted; // it is there

static void ring_put(ring *r, uint8_t c) {
  if (r->len == BUF) return; // full: dropped, as a terminal does
  r->b[(r->head + r->len++) % BUF] = c;
}

static uint32_t ring_take(ring *r, uint8_t *out, uint32_t n) {
  if (n > r->len) n = r->len;
  for (uint32_t i = 0; i < n; i++) out[i] = r->b[(r->head + i) % BUF];
  r->head = (r->head + n) % BUF;
  r->len -= n;
  return n;
}

static struct p9_ring_server server; // below

// Input, counted, for the breaks' positions.
static void in_put(pty *p, uint8_t c) {
  if (p->in.len == BUF) return; // full: dropped, as a terminal does
  ring_put(&p->in, c);
  p->in_put++;
}

static uint32_t in_take(pty *p, uint8_t *out, uint32_t n) {
  n = ring_take(&p->in, out, n);
  p->in_taken += n;
  while (p->nbreaks && p->breaks[0] < p->in_taken) // passed (a read not canonical): forgotten
    memmove(p->breaks, p->breaks + 1, --p->nbreaks * sizeof p->breaks[0]);
  return n;
}

static void in_break(pty *p) {
  if (p->nbreaks == sizeof p->breaks / sizeof p->breaks[0]) return; // so many unread: the rest run on
  p->breaks[p->nbreaks++] = p->in_put;
}

static void in_flush(pty *p) {
  p->in = (ring){};
  p->in_taken = p->in_put = 0;
  p->nbreaks = 0;
  p->line_len = 0;
}

static void echo(pty *p, uint8_t c) {
  if (!(p->lflag & T_ECHO)) return;
  if (c == '\n' && (p->oflag & T_OPOST) && (p->oflag & T_ONLCR)) ring_put(&p->out, '\r');
  if (c < 0x20 && c != '\n' && c != '\t') { // ^C and the rest echo as Linux's do
    ring_put(&p->out, '^');
    c = (uint8_t)(c + '@');
  }
  ring_put(&p->out, c);
}

// Signals the foreground group: the signal's note, written to the notepg of
// the group's leader, whose pid names the group (lib/vx-posix/posix.h).
static void signal_group(pty *p, int64_t sig) {
  if (p->reading) p->interrupted = true;
  if (!proc_mounted || p->pgrp <= 0) return;
  char path[48], note[VX_ERRMAX];
  vx_note_buf b = {path, 0, sizeof path};
  vx_note_put(&b, VX_STR("/proc/"));
  vx_note_dec(&b, (uint64_t)p->pgrp);
  vx_note_put(&b, VX_STR("/notepg"));
  vx_ns_file f;
  if (vx_ns_open(&ns, (vx_str){path, b.len}, P9_OWRITE, &f) != VX_OK) return; // the group has gone
  vx_ns_write(&f, note, (uint32_t)posix_note(sig, 0, note));
  vx_ns_close(&f);
}

// Takes back the last character typed: with IUTF8, a whole rune (ADR-0013),
// echoed as one character erased; without it, a byte.
static void erase(pty *p) {
  p->line_len =
      p->iflag & T_IUTF8 ? (uint32_t)vx_utf_back((const char *)p->line, p->line_len) : p->line_len - 1;
  if (p->lflag & T_ECHO) ring_put(&p->out, '\b'), ring_put(&p->out, ' '), ring_put(&p->out, '\b');
}

// The line is full: it ends, at the last whole rune that fits (with IUTF8;
// at the last byte without). A rune it would have split starts the next line.
static void full(pty *p) {
  uint32_t end = p->line_len;
  if (p->iflag & T_IUTF8) {
    uint32_t start = end, back = 0;
    while (start > 0 && back < VX_UTFMAX && (p->line[start - 1] & 0xc0) == 0x80) start--, back++;
    if (start > 0 && p->line[start - 1] >= 0xc0) start--; // the lead byte of the last rune
    if (start < end && !vx_fullrune((const char *)p->line + start, end - start)) end = start;
  }
  for (uint32_t i = 0; i < end; i++) in_put(p, p->line[i]);
  memmove(p->line, p->line + end, p->line_len - end);
  p->line_len -= end;
}

// One byte typed at the master, through the line discipline.
static void typed(pty *p, uint8_t c) {
  if ((p->iflag & T_ICRNL) && c == '\r') c = '\n';
  if (p->lflag & T_ISIG) {
    int64_t sig = 0;
    if (c == p->cc[V_INTR]) sig = SIGINT;
    if (c == p->cc[V_QUIT]) sig = SIGQUIT;
    if (c == p->cc[V_SUSP]) sig = SIGTSTP;
    if (sig) {
      echo(p, c);
      echo(p, '\n');
      p->line_len = 0; // the line is thrown away
      signal_group(p, sig);
      return;
    }
  }
  if (!(p->lflag & T_ICANON)) {
    in_put(p, c);
    echo(p, c);
    return;
  }
  if (c == p->cc[V_ERASE] || c == 0x08) {
    if (p->line_len) erase(p);
    return;
  }
  if (c == p->cc[V_KILL]) {
    while (p->line_len) erase(p);
    return;
  }
  if (c == p->cc[V_EOF]) { // the line as it is, or on an empty one the end of the file
    for (uint32_t i = 0; i < p->line_len; i++) in_put(p, p->line[i]);
    in_break(p);
    p->line_len = 0;
    return;
  }
  echo(p, c);
  if (p->line_len == BUF) full(p);
  p->line[p->line_len++] = c;
  if (c == '\n') {
    for (uint32_t i = 0; i < p->line_len; i++) in_put(p, p->line[i]);
    p->line_len = 0;
  }
}

// --- The file system ---

static pty *pty_of(uint64_t node) {
  uint64_t i = node & 0xff;
  if (node < MASTER || i >= PTYS || !ptys[i].used) return nullptr;
  return &ptys[i];
}

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = ROOT;
  return VX_OK;
}

static size_t put_u(char *out, uint64_t v) {
  char d[20];
  size_t n = 0, k = 0;
  do d[n++] = (char)('0' + v % 10);
  while ((v /= 10));
  while (n) out[k++] = d[--n];
  return k;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  if (dir == ROOT && name.len == 4 && memcmp(name.ptr, "ptmx", 4) == 0) return *child = PTMX, VX_OK;
  if (dir == ROOT && name.len == 3 && memcmp(name.ptr, "pts", 3) == 0) return *child = PTS, VX_OK;
  if (dir != PTS) return VX_ERR_NOT_FOUND;
  for (uint32_t i = 0; i < PTYS; i++) {
    if (!ptys[i].used) continue;
    char n[24];
    size_t len = put_u(n, i);
    if (name.len == len && memcmp(name.ptr, n, len) == 0) return *child = SLAVE + i, VX_OK;
    static const vx_str ctl = VX_STR(".ctl"); // a vx_str: no terminator
    memcpy(n + len, ctl.ptr, ctl.len);
    if (name.len == len + 4 && memcmp(name.ptr, n, len + 4) == 0) return *child = CTL + i, VX_OK;
  }
  return VX_ERR_NOT_FOUND;
}

static vx_status fs_parent(void *ctx, uint64_t node, uint64_t *parent) {
  (void)ctx;
  *parent = node == ROOT || node == PTS || node == PTMX || (node >= MASTER && node < SLAVE) ? ROOT : PTS;
  return VX_OK;
}

static char stat_name[24];

// A terminal's sides are devices (9P2000.u's DMDEVICE), which the back end
// takes for terminals; each is named by its number.
static vx_status fs_stat(void *ctx, uint64_t node, p9_stat *out) {
  (void)ctx;
  bool dir = node == ROOT || node == PTS;
  vx_str name = VX_STR("ptmx");
  if (node == ROOT) name = VX_STR("/");
  if (node == PTS) name = VX_STR("pts");
  uint32_t mode = dir ? P9_DMDIR | 0555 : 0666;
  if (node >= MASTER) {
    if (!pty_of(node)) return VX_ERR_NOT_FOUND;
    size_t len = put_u(stat_name, node & 0xff);
    static const vx_str ctl = VX_STR(".ctl");
    if (node >= CTL) memcpy(stat_name + len, ctl.ptr, ctl.len), len += ctl.len;
    name = (vx_str){stat_name, len};
    if (node < CTL) mode = P9_DMDEVICE | 0620;
  }
  *out = (p9_stat){.qid = {dir ? P9_QTDIR : P9_QTFILE, 0, node},
                   .mode = mode,
                   .name = name,
                   .uid = VX_STR("sys"),
                   .gid = VX_STR("sys"),
                   .muid = VX_STR("sys")};
  return VX_OK;
}

static vx_status fs_open(void *ctx, uint64_t node, uint8_t mode) {
  (void)ctx, (void)mode;
  if (node == ROOT || node == PTS) return (mode & 3) == P9_OREAD ? VX_OK : VX_ERR_ACCESS;
  if (node == PTMX) return VX_OK;
  pty *p = pty_of(node);
  if (!p) return VX_ERR_NOT_FOUND;
  if (node >= SLAVE && node < CTL) {
    if (p->master_gone) return VX_ERR_PEER_CLOSED;
    p->slaves++;
  }
  if (node < SLAVE) { // another fid for the master (Tjoin: a fork's, poll's): one more to close
    if (p->master_gone) return VX_ERR_PEER_CLOSED;
    p->masters++;
  }
  return VX_OK;
}

// Opening ptmx makes a terminal, with Linux's defaults: cooked, echoing,
// signals on, 80 by 24.
static vx_status fs_clone(void *ctx, uint64_t node, uint8_t mode, uint64_t *opened) {
  (void)ctx, (void)mode;
  if (node != PTMX) return VX_ERR_NOT_FOUND;
  for (uint32_t i = 0; i < PTYS; i++) {
    if (ptys[i].used) continue;
    pty *p = &ptys[i];
    *p = (pty){.used = true,
               .masters = 1,
               .iflag = T_ICRNL | T_IUTF8, // UTF-8 input, as Linux terminals have it (ADR-0013)
               .oflag = T_OPOST | T_ONLCR,
               .cflag = 0277, // CS8 | CREAD | B38400, as Linux reports them
               .lflag = T_ISIG | T_ICANON | T_ECHO | T_ECHOE | T_ECHOK,
               .rows = 24,
               .cols = 80};
    p->cc[V_INTR] = 3, p->cc[V_QUIT] = 0x1c, p->cc[V_ERASE] = 0x7f, p->cc[V_KILL] = 0x15;
    p->cc[V_EOF] = 4, p->cc[V_MIN] = 1, p->cc[V_SUSP] = 0x1a;
    *opened = MASTER + i;
    return VX_OK;
  }
  return VX_ERR_NO_MEMORY;
}

static void fs_clunk(void *ctx, uint64_t node, bool opened) {
  (void)ctx;
  pty *p = opened ? pty_of(node) : nullptr;
  if (!p) return;
  if (node < SLAVE && p->masters) {
    p->masters--;
    if (!p->masters) p->master_gone = true; // a hang-up: the slave reads its end
  }
  if (node >= SLAVE && node < CTL && p->slaves) p->slaves--;
  if (p->master_gone && !p->slaves) *p = (pty){};
}

// The settings, as one record.
static size_t settings(const pty *p, char *buf, size_t cap) {
  vx_ndb_writer w = {.buf = buf, .cap = cap};
  vx_ndb_put_u64(&w, "iflag", p->iflag);
  vx_ndb_put_u64(&w, "oflag", p->oflag);
  vx_ndb_put_u64(&w, "cflag", p->cflag);
  vx_ndb_put_u64(&w, "lflag", p->lflag);
  vx_ndb_put(&w, "cc", (vx_str){(const char *)p->cc, NCCS});
  vx_ndb_put_u64(&w, "rows", p->rows);
  vx_ndb_put_u64(&w, "cols", p->cols);
  vx_ndb_put_u64(&w, "pgrp", (uint64_t)p->pgrp);
  vx_ndb_put_u64(&w, "avail", p->in.len);
  vx_ndb_end(&w);
  return w.failed ? 0 : w.len;
}

static vx_status fs_read(void *ctx, uint64_t node, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  pty *p = pty_of(node);
  if (!p) return VX_ERR_NOT_FOUND;
  if (node >= CTL) {
    static char text[512];
    size_t n = settings(p, text, sizeof text);
    uint64_t left = offset < n ? n - offset : 0;
    if (*count > left) *count = (uint32_t)left;
    memcpy(buf, text + offset, *count);
    return VX_OK;
  }
  if (node < SLAVE) { // the master: what the slave wrote, and echo
    if (!p->out.len) return VX_ERR_SHOULD_WAIT;
    *count = ring_take(&p->out, buf, *count);
    server.again = true; // room for a slave write held for it
    return VX_OK;
  }
  // A signal ptyd sent while a read waited ends it; but not one that finds
  // input here (the read it was for may have been given up since).
  if (p->interrupted && !p->in.len) {
    p->interrupted = p->reading = false;
    return VX_ERR_INTERRUPTED;
  }
  p->interrupted = false;
  bool canonical = p->lflag & T_ICANON;
  if (canonical && p->nbreaks && p->breaks[0] == p->in_taken) { // a ^D on an empty line: the end of the file
    memmove(p->breaks, p->breaks + 1, --p->nbreaks * sizeof p->breaks[0]);
    p->reading = false;
    return *count = 0, VX_OK;
  }
  if (!p->in.len) {
    if (p->master_gone) return *count = 0, VX_OK; // the end of the file: hung up
    p->reading = true;
    return VX_ERR_SHOULD_WAIT;
  }
  p->reading = false;
  if (!canonical) {
    *count = in_take(p, buf, *count);
    return VX_OK;
  }
  // One line at most: to its newline, or to where a ^D sent it.
  uint32_t n = 0;
  while (n < *count && p->in.len) {
    uint8_t c = p->in.b[p->in.head];
    in_take(p, &buf[n++], 1);
    if (c == '\n') break; // a break here too is the next read's: the end of the file
    if (p->nbreaks && p->breaks[0] == p->in_taken) {
      memmove(p->breaks, p->breaks + 1, --p->nbreaks * sizeof p->breaks[0]);
      break;
    }
  }
  *count = n;
  return VX_OK;
}

static uint64_t field(const vx_ndb_record *r, const char *key, uint64_t was) {
  uint64_t v = was;
  vx_ndb_get_u64(r, key, &v);
  return v;
}

// NOLINTNEXTLINE(readability-non-const-parameter): p9_fs's signature
static vx_status fs_write(void *ctx, uint64_t node, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx, (void)offset;
  pty *p = pty_of(node);
  if (!p) return VX_ERR_NOT_FOUND;
  server.again = true; // what is written at one end may let a read held at the other go on
  if (node >= CTL) {   // set what the record names; `flush` throws away pending input
    static char scratch[1024];
    vx_ndb_reader r = {.src = {(const char *)buf, *count}, .scratch = scratch, .scratch_cap = sizeof scratch};
    vx_ndb_record rec;
    if (vx_ndb_next(&r, &rec) != VX_NDB_RECORD) return VX_ERR_INVALID;
    p->iflag = (uint32_t)field(&rec, "iflag", p->iflag);
    p->oflag = (uint32_t)field(&rec, "oflag", p->oflag);
    p->cflag = (uint32_t)field(&rec, "cflag", p->cflag);
    p->lflag = (uint32_t)field(&rec, "lflag", p->lflag);
    vx_str cc = vx_ndb_get(&rec, "cc");
    if (cc.len == NCCS) memcpy(p->cc, cc.ptr, NCCS);
    uint16_t rows = p->rows, cols = p->cols;
    p->rows = (uint16_t)field(&rec, "rows", p->rows);
    p->cols = (uint16_t)field(&rec, "cols", p->cols);
    p->pgrp = (int64_t)field(&rec, "pgrp", (uint64_t)p->pgrp);
    if (vx_ndb_has(&rec, "flush")) in_flush(p);
    if (rows != p->rows || cols != p->cols) {
      signal_group(p, SIGWINCH);
      p->interrupted = false; // a resize does not end reads
    }
    return VX_OK;
  }
  if (node < SLAVE) { // typed at the master
    for (uint32_t i = 0; i < *count; i++) typed(p, buf[i]);
    return VX_OK;
  }
  if (p->master_gone) return VX_ERR_PEER_CLOSED;
  // The program's output, to the master: as much as there is room for (a
  // newline may take two), the rest written again; none, and the write
  // waits for the master to read (held, as a read is).
  uint32_t taken = 0;
  for (; taken < *count; taken++) {
    bool crnl = buf[taken] == '\n' && (p->oflag & T_OPOST) && (p->oflag & T_ONLCR);
    if (BUF - p->out.len < (crnl ? 2u : 1u)) break;
    if (crnl) ring_put(&p->out, '\r');
    ring_put(&p->out, buf[taken]);
  }
  if (!taken && *count) return VX_ERR_SHOULD_WAIT;
  *count = taken;
  return VX_OK;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  if (dir == ROOT) {
    if (index > 1) return VX_ERR_NOT_FOUND;
    *child = index ? PTS : PTMX;
    return VX_OK;
  }
  for (uint32_t i = 0; dir == PTS && i < PTYS; i++) {
    if (!ptys[i].used || ptys[i].master_gone) continue;
    if (index < 2) return *child = (index ? CTL : SLAVE) + i, VX_OK;
    index -= 2;
  }
  return VX_ERR_NOT_FOUND;
}

static p9_ring_server server = {
    .fs = {.attach = fs_attach,
           .walk = fs_walk,
           .parent = fs_parent,
           .stat = fs_stat,
           .open = fs_open,
           .clone = fs_clone,
           .read = fs_read,
           .write = fs_write,
           .readdir = fs_readdir,
           .clunk = fs_clunk},
    .name = VX_STR("ptyd"),
    .supported = P9_EXT_XATTR | P9_EXT_POSIX,
};

const char *vx_main(void) {
  server.listen = vx_spawn_take("listen");
  if (!server.listen) {
    vx_print(VX_STR("ptyd: no listen channel\n"));
    return "no listen channel";
  }
  // /proc, to signal process groups through.
  proc_mounted = vx_ns_from_spawn(&ns) == VX_OK && vx_ns_connector(&ns, VX_STR("/proc")) != VX_HANDLE_NONE;
  vx_print(proc_mounted ? VX_STR("ptyd: serving /srv/ptyd\n")
                        : VX_STR("ptyd: serving /srv/ptyd, without /proc: no signals\n"));
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
