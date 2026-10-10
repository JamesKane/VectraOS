// plumber: routes plumb messages between programs by the user's rules (07
// §7, plumber(4); M7 step 7g3b), 9front's plumber (cmd/plumb/fsys.c) on
// lib/vx-plumb, posted as /srv/plumb and mounted at /mnt/plumb:
//
//   send    a message written here is matched against the rules and sent
//           from its port, or its program started
//   rules   the rules, read as they stand; a write adds rulesets, an open
//           with OTRUNC clears them first; one writer at a time
//   PORT    one for each `plumb to` the rules have named: each open reads
//           every message sent from it after it was opened, one a read
//
// The rules are $home/lib/plumbing (/home/lib/plumbing on an installed
// system), else /lib/plumb/basic. A `start` or `client` action runs its
// command in the plumber's namespace, which holds /mnt/plumb too (mounted
// by the plumber once it serves); a
// `client`'s message waits for the next open of its port. A read with no
// message to give is held until one comes.

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-9p/ring_server.c"
#include "../../lib/vx-ns/nsapi.c"
#include "../../lib/vx-plumb/plumb.c"

static constexpr uint32_t PORTS = 64, OPENS = 128, HELD = 32;
static constexpr size_t MESSAGE_MAX = 1u << 20; // a message's bytes, written to send in parts
enum : uint64_t { ROOT = 1, RULES = 2, SEND = 3, PORT = 0x100, OPEN = 0x1'0000 }; // + port; + open
enum : uint8_t { O_FREE, O_SEND, O_RULES, O_PORT };

typedef struct queued queued;
struct queued {
  char *packed;
  size_t n;
  queued *next;
};

// An open of send, a writer's of rules, or a port's.
typedef struct opened {
  uint8_t kind;
  uint32_t port;
  char *buf; // send's: the message written so far
  size_t len;
  queued *head, *tail; // a port's: messages to read, the first from off
  size_t off;
} opened;

static opened opens[OPENS];
static queued *held[PORTS]; // client's messages, for a port's next open
static vx_plumb_rules *rules;
static bool rules_writer; // one at a time, as 9front's
static p9_ring_server server;
// Until its own tree is mounted at /mnt/plumb, writes to send and rules are
// held: they may need the namespace, whose lock the mount holds while it
// waits for this very server to answer.
static bool ready;
static vx_handle mounted; // a counter: 1 once the mount is done (or given up)

// --- The rules' files: through the plumber's namespace, but never its own
// tree, which it would be asking itself for while serving (a deadlock) ---

static bool own(const char *path) {
  static const char mnt[] = "/mnt/plumb";
  return vp_prefix(path, mnt) && (!path[sizeof mnt - 1] || path[sizeof mnt - 1] == '/');
}

static int file_kind(void *ctx, const char *path) {
  (void)ctx;
  if (own(path)) return VX_PLUMB_NONE;
  vx_arena *a = vx_arena_new(4096);
  vx_dir d;
  int k = VX_PLUMB_NONE;
  if (a && vx_stat(vx_cstr(path), a, &d) == VX_OK) k = d.qid.type & P9_QTDIR ? VX_PLUMB_DIR : VX_PLUMB_FILE;
  vx_arena_free(a);
  return k;
}

static char *read_file(void *ctx, const char *path, size_t *n) {
  (void)ctx;
  if (own(path)) return nullptr;
  vx_fd fd = vx_open(vx_cstr(path), VX_OREAD);
  if (fd < 0) return nullptr;
  size_t cap = 4096, len = 0;
  char *p = vx_plumb_alloc(cap + 1);
  int64_t got = 1;
  while (p && got > 0) {
    if (len == cap) {
      char *q = cap < MESSAGE_MAX ? vx_plumb_alloc(cap * 2 + 1) : nullptr;
      if (q) memcpy(q, p, len);
      vx_plumb_dealloc(p);
      p = q, cap *= 2;
      if (!p) break;
    }
    got = vx_read(fd, (vx_bytes){(uint8_t *)p + len, cap - len});
    if (got > 0) len += (size_t)got;
  }
  vx_close(fd);
  if (!p || got < 0) return vx_plumb_dealloc(p), nullptr;
  p[len] = 0, *n = len;
  return p;
}

static const vx_plumb_fs FS = {.kind = file_kind, .read = read_file};

static void say(const char *a, const char *b) { vx_printf("plumber: %s%s\n", a, b ? b : ""); }

// --- Ports and their opens ---

static int32_t port_of(const char *name) {
  for (uint32_t i = 0; i < vx_plumb_port_count(rules) && i < PORTS; i++)
    if (vp_eq(vx_plumb_port(rules, i), name)) return (int32_t)i;
  return -1;
}

static void enqueue(queued **head, queued **tail, char *packed, size_t n) {
  queued *q = vx_plumb_alloc(sizeof *q);
  if (!q) return vx_plumb_dealloc(packed);
  *q = (queued){.packed = packed, .n = n};
  if (*head)
    (*tail)->next = q;
  else
    *head = q;
  *tail = q;
}

static void free_queue(queued *q) {
  while (q) {
    queued *next = q->next;
    vx_plumb_dealloc(q->packed), vx_plumb_dealloc(q);
    q = next;
  }
}

static uint32_t port_opens(uint32_t port) {
  uint32_t n = 0;
  for (uint32_t i = 0; i < OPENS; i++) n += opens[i].kind == O_PORT && opens[i].port == port;
  return n;
}

// A copy of the message to every open of the port.
static void deliver(uint32_t port, const vx_plumb_msg *m) {
  for (uint32_t i = 0; i < OPENS; i++) {
    opened *o = &opens[i];
    if (o->kind != O_PORT || o->port != port) continue;
    size_t n = 0;
    char *packed = vx_plumb_pack(m, &n);
    if (packed) enqueue(&o->head, &o->tail, packed, n);
  }
  server.again = true; // a read held on one may go on
}

// Runs a start or client action's command: argv[0] as it is when it holds
// a slash, else from /bin, as 9front's plumber runs it; standard input
// none, standard output and error the plumber's.
static bool start(char **argv) {
  char path[256];
  size_t n = vp_len(argv[0]);
  bool named = vp_has(argv[0], '/');
  if (n + 6 > sizeof path) return false;
  memcpy(path, named ? "" : "/bin/", named ? 0 : 5);
  memcpy(path + (named ? 0 : 5), argv[0], n + 1);
  vx_str args[32];
  uint32_t argc = 0;
  while (argv[argc] && argc < 32) args[argc] = vx_cstr(argv[argc]), argc++;
  vx_spawn_req r = {.path = vx_cstr(path), .args = {args, argc}};
  vx_proc p;
  vx_status st = vx_proc_spawn(&r, &p);
  if (st != VX_OK) {
    say("cannot start ", path);
    return false;
  }
  vx_proc_close(p);
  return true;
}

// 9front's dispose: a matched message to its port's opens, or, with none,
// its program started (the message held for a client, else dropped); one
// with no port, its program started.
static vx_status dispatch(vx_plumb_msg *m) {
  vx_plumb_exec *e = vx_plumb_match(rules, m);
  vx_status st = VX_OK;
  int32_t port = m->dst[0] ? port_of(m->dst) : -1;
  if (!m->dst[0] || (port >= 0 && !port_opens((uint32_t)port))) {
    char **argv = nullptr;
    bool hold = false;
    const char *why = vx_plumb_startup(rules, e, &argv, &hold);
    if (why) {
      st = VX_ERR_NOT_FOUND; // 9front: "no start action for plumb message"
    } else if (!start(argv)) {
      st = VX_ERR_IO;
    } else if (hold && port >= 0) {
      uint32_t n = 0;
      for (queued *q = held[port]; q; q = q->next) n++;
      size_t len = 0;
      char *packed = n < HELD ? vx_plumb_pack(m, &len) : nullptr;
      queued *tail = held[port];
      while (tail && tail->next) tail = tail->next;
      if (packed) enqueue(&held[port], &tail, packed, len);
    }
    vx_plumb_argv_free(argv);
  } else if (port >= 0) {
    deliver((uint32_t)port, m);
  } else {
    st = VX_ERR_NOT_FOUND; // a dst that is no port
  }
  vx_plumb_exec_free(e);
  vx_plumb_free(m);
  return st;
}

// --- The tree ---

static opened *open_of(uint64_t node) {
  if (node < OPEN || node >= OPEN + OPENS) return nullptr;
  opened *o = &opens[node - OPEN];
  return o->kind == O_FREE ? nullptr : o;
}

static uint64_t file_of(const opened *o) {
  if (o->kind == O_SEND) return SEND;
  if (o->kind == O_RULES) return RULES;
  return PORT + o->port;
}

static vx_status fs_attach(void *ctx, vx_str aname, uint64_t *root) {
  (void)ctx;
  if (aname.len) return VX_ERR_NOT_FOUND;
  *root = ROOT;
  return VX_OK;
}

static vx_status fs_walk(void *ctx, uint64_t dir, vx_str name, uint64_t *child) {
  (void)ctx;
  if (dir != ROOT) return VX_ERR_NOT_FOUND;
  if (vx_str_eq(name, VX_STR("rules"))) return *child = RULES, VX_OK;
  if (vx_str_eq(name, VX_STR("send"))) return *child = SEND, VX_OK;
  for (uint32_t i = 0; i < vx_plumb_port_count(rules) && i < PORTS; i++)
    if (vx_str_eq(name, vx_cstr(vx_plumb_port(rules, i)))) return *child = PORT + i, VX_OK;
  return VX_ERR_NOT_FOUND;
}

static vx_status fs_parent(void *ctx, uint64_t node, uint64_t *parent) {
  (void)ctx, (void)node;
  *parent = ROOT;
  return VX_OK;
}

static vx_status fs_stat(void *ctx, uint64_t node, p9_stat *out) {
  (void)ctx;
  opened *o = open_of(node);
  if (o) node = file_of(o); // stat as the file it opened
  vx_str name;
  uint32_t mode;
  if (node == ROOT) {
    name = VX_STR("/"), mode = P9_DMDIR | 0500;
  } else if (node == RULES) {
    name = VX_STR("rules"), mode = 0600;
  } else if (node == SEND) {
    name = VX_STR("send"), mode = 0200;
  } else if (node >= PORT && node < PORT + PORTS && node - PORT < vx_plumb_port_count(rules)) {
    name = vx_cstr(vx_plumb_port(rules, (uint32_t)(node - PORT))), mode = 0400;
  } else {
    return VX_ERR_NOT_FOUND;
  }
  *out = (p9_stat){.qid = {node == ROOT ? P9_QTDIR : P9_QTFILE, 0, node},
                   .mode = mode,
                   .name = name,
                   .uid = VX_STR("plumb"),
                   .gid = VX_STR("plumb"),
                   .muid = VX_STR("plumb")};
  return VX_OK;
}

static vx_status fs_readdir(void *ctx, uint64_t dir, uint32_t index, uint64_t *child) {
  (void)ctx;
  if (dir != ROOT) return VX_ERR_NOT_FOUND;
  if (index < 2) return *child = index ? SEND : RULES, VX_OK;
  if (index - 2 >= vx_plumb_port_count(rules) || index - 2 >= PORTS) return VX_ERR_NOT_FOUND;
  *child = PORT + index - 2;
  return VX_OK;
}

// What each file may be opened for, as 9front's permissions say.
static vx_status fs_open(void *ctx, uint64_t node, uint8_t mode) {
  (void)ctx;
  uint8_t rw = mode & 3;
  bool reads = rw == P9_OREAD || rw == P9_ORDWR, writes = rw == P9_OWRITE || rw == P9_ORDWR;
  if ((mode & P9_OTRUNC) && node != RULES) return VX_ERR_ACCESS;
  if (node == ROOT || (node >= PORT && node < PORT + PORTS)) return writes ? VX_ERR_ACCESS : VX_OK;
  if (node == SEND) return reads ? VX_ERR_ACCESS : VX_OK;
  if (node == RULES) return writes && rules_writer ? VX_ERR_BAD_STATE : VX_OK; // 9front: "file already open"
  return open_of(node) ? VX_OK : VX_ERR_NOT_FOUND;
}

// Each open of send, of a port, and a writer's of rules, is a file of its
// own: its message being written, or the messages it has to read.
static vx_status fs_clone(void *ctx, uint64_t node, uint8_t mode, uint64_t *out) {
  (void)ctx;
  uint8_t rw = mode & 3;
  bool rules_write = node == RULES && (rw == P9_OWRITE || rw == P9_ORDWR);
  if (node == RULES && (mode & P9_OTRUNC))
    vx_plumb_rules_write(rules, nullptr, 0, true), vx_plumb_rules_clear(rules);
  if (node != SEND && !rules_write && !(node >= PORT && node < PORT + PORTS)) return VX_ERR_NOT_FOUND;
  for (uint32_t i = 0; i < OPENS; i++) {
    opened *o = &opens[i];
    if (o->kind != O_FREE) continue;
    *o = (opened){.kind = O_PORT};
    if (node == SEND) o->kind = O_SEND;
    if (rules_write) o->kind = O_RULES;
    if (o->kind == O_RULES) rules_writer = true;
    if (o->kind == O_PORT) { // what was held for a client, to this open
      o->port = (uint32_t)(node - PORT);
      o->head = held[o->port], held[o->port] = nullptr;
      for (o->tail = o->head; o->tail && o->tail->next;) o->tail = o->tail->next;
    }
    *out = OPEN + i;
    return VX_OK;
  }
  return VX_ERR_NO_MEMORY;
}

static void fs_clunk(void *ctx, uint64_t node, bool was_open) {
  (void)ctx;
  opened *o = was_open ? open_of(node) : nullptr;
  if (!o) return;
  if (o->kind == O_RULES) { // the last ruleset, though no blank line ended it
    if (!vx_plumb_rules_write(rules, nullptr, 0, true)) say("rules: ", vx_plumb_rules_error(rules));
    rules_writer = false;
  }
  vx_plumb_dealloc(o->buf);
  free_queue(o->head);
  *o = (opened){};
}

static vx_status fs_read(void *ctx, uint64_t node, uint64_t offset, uint8_t *buf, uint32_t *count) {
  (void)ctx;
  opened *o = open_of(node);
  if (node == RULES || (o && o->kind == O_RULES)) { // the listing, as it is now
    size_t n = 0;
    char *text = vx_plumb_rules_print(rules, &n);
    if (!text) return VX_ERR_NO_MEMORY;
    uint64_t left = offset < n ? n - offset : 0;
    if (*count > left) *count = (uint32_t)left;
    memcpy(buf, text + offset, *count);
    vx_plumb_dealloc(text);
    return VX_OK;
  }
  if (!o || o->kind != O_PORT) return VX_ERR_ACCESS;
  if (!o->head) return VX_ERR_SHOULD_WAIT; // held until a message comes
  queued *q = o->head;
  size_t n = q->n - o->off < *count ? q->n - o->off : *count; // one message a read, in parts if it must
  memcpy(buf, q->packed + o->off, n);
  *count = (uint32_t)n, o->off += n;
  if (o->off == q->n) {
    o->head = q->next, o->off = 0;
    if (!o->head) o->tail = nullptr;
    vx_plumb_dealloc(q->packed), vx_plumb_dealloc(q);
  }
  return VX_OK;
}

// NOLINTNEXTLINE(readability-non-const-parameter): p9_fs's signature
static vx_status fs_write(void *ctx, uint64_t node, uint64_t offset, const uint8_t *buf, uint32_t *count) {
  (void)ctx, (void)offset;
  opened *o = open_of(node);
  if (!ready && o && (o->kind == O_RULES || o->kind == O_SEND)) return VX_ERR_SHOULD_WAIT;
  if (o && o->kind == O_RULES) {
    if (vx_plumb_rules_write(rules, (const char *)buf, *count, false)) return VX_OK;
    say("rules: ", vx_plumb_rules_error(rules));
    return VX_ERR_INVALID;
  }
  if (!o || o->kind != O_SEND) return VX_ERR_ACCESS;
  // A message may come in several writes: what is written is added to what
  // came before until it is whole.
  if (o->len + *count > MESSAGE_MAX) {
    vx_plumb_dealloc(o->buf), o->buf = nullptr, o->len = 0;
    return VX_ERR_RANGE;
  }
  char *p = vx_plumb_alloc(o->len + *count + 1);
  if (!p) return VX_ERR_NO_MEMORY;
  if (o->len) memcpy(p, o->buf, o->len);
  memcpy(p + o->len, buf, *count);
  vx_plumb_dealloc(o->buf);
  o->buf = p, o->len += *count;
  size_t more = 0;
  vx_plumb_msg *m = vx_plumb_unpack(o->buf, o->len, &more);
  if (!m && more) return VX_OK; // the rest to come
  vx_plumb_dealloc(o->buf), o->buf = nullptr, o->len = 0;
  if (!m) return VX_ERR_INVALID; // 9front: "bad plumb message format"
  return dispatch(m);
}

static void event(void *ctx, const vx_packet *pk);

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
    .name = VX_STR("plumber"),
    .event = event,
};

// Its own tree at /mnt/plumb, once it serves, for the programs it starts:
// a mount before would attach to a server not yet answering.
static vx_handle self; // a connector to its own post (connect=plumb)

static const char *mount_self(void *arg) {
  (void)arg;
  vx_lock(&vx_ns_proc_lock);
  vx_status st = self ? vx_ns_mount_connector(vx_ns_process(), self, VX_STR("/srv/plumb"), VX_STR(""),
                                              VX_STR("/mnt/plumb"), VX_MREPL)
                      : VX_ERR_NOT_FOUND;
  vx_unlock(&vx_ns_proc_lock);
  if (st != VX_OK) vx_printf("plumber: cannot mount itself at /mnt/plumb: %.*s\n", VX_FMT(p9_error_text(st)));
  vx_counter_signal(mounted, 1); // the writes held go on, mounted or not
  return nullptr;
}

static void event(void *ctx, const vx_packet *pk) {
  (void)ctx, (void)pk;
  ready = server.again = true;
}

const char *vx_main(void) {
  server.listen = vx_spawn_take("listen");
  if (!server.listen) {
    vx_print(VX_STR("plumber: no listen channel\n"));
    return "no listen channel";
  }
  self = vx_spawn_take("srv:plumb");
  rules = vx_plumb_rules_new(&FS);
  if (!rules) return "no memory";
  static const char *const files[] = {"/home/lib/plumbing", "/lib/plumb/basic"}; // $home's, else the system's
  const char *from = "nowhere";
  for (size_t i = 0; i < 2 && from[0] == 'n'; i++) {
    size_t n = 0;
    char *text = read_file(nullptr, files[i], &n);
    if (!text) continue;
    if (!vx_plumb_rules_read(rules, files[i], text, n)) say("", vx_plumb_rules_error(rules));
    vx_plumb_dealloc(text);
    from = files[i];
  }
  vx_printf("plumber: serving /srv/plumb, rules from %s, %u ports\n", from, vx_plumb_port_count(rules));
  if (vx_port_create(0, &server.port) != VX_OK || vx_counter_create(0, &mounted) != VX_OK ||
      vx_port_bind(server.port, mounted, VX_TRIGGER_COUNTER_GE, P9_KEY_USER, 1) != VX_OK ||
      !vx_thread_spawn(mount_self, nullptr, 0, 0)) {
    say("cannot mount itself at /mnt/plumb", nullptr);
    ready = true;
  }
  return p9_ring_serve(&server) == VX_OK ? nullptr : "cannot serve";
}
