// vx-ns at start-up: builds a process's namespace from its spawn message
// (abi.h). A child that shares its parent's namespace group (ADR-0009) is
// given a channel to nsd for it ("nsgroup"), and builds its table from the
// group's text; one with a namespace of its own is given mount= and bind=
// records, what its parent's template or table made (02 §2). A mount record
// names a connector handle in the message; each one gets its own ring
// connection to the server behind it. A mount record with dial=ADDRESS
// instead is a 9P server over TCP, which the process dials itself (dial.c),
// through the /net its earlier records gave it.

#pragma once

#include "../vx-9p/ring.c"
#include "ns.c"
#include "newns.c"
#include "dial.c"
#include "nsd.h"

// The process's connections: a slot is free while its end is 0. Each has the
// connector handle's name it came through, so mount records naming one
// connector share one connection.
static p9_conn vx_ns_conns[VX_NS_MAX_CONNS];
static char vx_ns_conn_names[VX_NS_MAX_CONNS][8];

static uint8_t vx_ns_flags(vx_str f) {
  uint8_t flags = 0;
  for (size_t i = 0; i < f.len; i++) {
    if (f.ptr[i] == 'a')
      flags |= VX_NS_AFTER;
    else if (f.ptr[i] == 'b')
      flags |= VX_NS_BEFORE;
    else if (f.ptr[i] == 'c')
      flags |= VX_NS_CREATE;
    else
      return 0xff;
  }
  return (flags & VX_NS_AFTER) && (flags & VX_NS_BEFORE) ? 0xff : flags;
}

// The namespace let a connection go (unmount): disconnect it, and its slot is free.
static void vx_ns_release(p9_client *c, vx_handle connector) {
  if (vx_ns_dial_release(c)) return; // a TCP connection: no connector
  for (uint32_t i = 0; i < VX_NS_MAX_CONNS; i++)
    if (&vx_ns_conns[i].c == c) {
      p9_ring_disconnect(&vx_ns_conns[i]);
      vx_ns_conns[i].end = VX_HANDLE_NONE;
      vx_ns_conn_names[i][0] = 0;
    }
  if (connector) vx_handle_close(connector);
}

// Where records' handles come from: the spawn message's, or a list of a
// process's own (after a fork). A handle taken is the namespace's.
typedef struct vx_ns_handles {
  const vx_str *names;
  vx_handle *handles;
  uint32_t count;
} vx_ns_handles;

static vx_handle vx_ns_take(const vx_ns_handles *from, const char *name) {
  if (!from) return vx_spawn_take(name);
  size_t len = vx_cstr(name).len;
  for (uint32_t i = 0; i < from->count; i++) {
    if (!from->handles[i] || from->names[i].len != len || memcmp(from->names[i].ptr, name, len) != 0)
      continue;
    vx_handle h = from->handles[i];
    from->handles[i] = VX_HANDLE_NONE;
    return h;
  }
  return VX_HANDLE_NONE;
}

// The connection through the connector `name` names: the one already made
// through it, or a new one. nullptr if there is none.
static p9_client *vx_ns_connect(const vx_ns_handles *from, vx_str name, vx_handle *connector, vx_status *st) {
  uint32_t free_slot = VX_NS_MAX_CONNS;
  for (uint32_t i = 0; i < VX_NS_MAX_CONNS; i++) {
    if (vx_ns_conns[i].end && vx_ns_conn_names[i][0] && vx_cstr(vx_ns_conn_names[i]).len == name.len &&
        memcmp(vx_ns_conn_names[i], name.ptr, name.len) == 0) {
      *connector = VX_HANDLE_NONE; // the namespace has it already
      return &vx_ns_conns[i].c;
    }
    if (!vx_ns_conns[i].end && free_slot == VX_NS_MAX_CONNS) free_slot = i;
  }
  char cname[8] = {};
  if (name.len >= sizeof cname || free_slot == VX_NS_MAX_CONNS) {
    *st = VX_ERR_NO_MEMORY;
    return nullptr;
  }
  memcpy(cname, name.ptr, name.len);
  *connector = vx_ns_take(from, cname);
  *st = *connector ? p9_ring_connect(*connector, &vx_ns_conns[free_slot]) : VX_ERR_NOT_FOUND;
  if (*st != VX_OK) {
    if (*connector) vx_handle_close(*connector);
    p9_conn_clear(&vx_ns_conns[free_slot], false);
    return nullptr;
  }
  memcpy(vx_ns_conn_names[free_slot], cname, sizeof cname);
  return &vx_ns_conns[free_slot].c;
}

// A connection through a connector handle (which the namespace takes, if it
// succeeds), in a free slot. nullptr if there is none.
static p9_client *vx_ns_connect_handle(vx_handle connector, vx_status *st) {
  for (uint32_t i = 0; i < VX_NS_MAX_CONNS; i++) {
    if (vx_ns_conns[i].end) continue;
    *st = p9_ring_connect(connector, &vx_ns_conns[i]);
    if (*st != VX_OK) {
      p9_conn_clear(&vx_ns_conns[i], false);
      return nullptr;
    }
    vx_ns_conn_names[i][0] = 0;
    return &vx_ns_conns[i].c;
  }
  *st = VX_ERR_NO_MEMORY;
  return nullptr;
}

// Replays the spawn message's namespace records in order. Stops at the first
// that fails, and says which.
static vx_status vx_ns_replay(vx_ns *ns, vx_str records, const vx_ns_handles *from) {
  static char scratch[VX_CHANNEL_MAX_BYTES];
  vx_ndb_reader r = {.src = records, .scratch = scratch, .scratch_cap = sizeof scratch};
  vx_ndb_record rec;
  ns->release = vx_ns_release;
  while (vx_ndb_next(&r, &rec) == VX_NDB_RECORD) {
    bool mount = vx_ndb_has(&rec, "mount");
    if (!mount && !vx_ndb_has(&rec, "bind")) continue;
    uint8_t flags = vx_ns_flags(vx_ndb_get(&rec, "flags"));
    vx_status st = flags == 0xff ? VX_ERR_INVALID : VX_OK;
    if (st == VX_OK && mount && vx_ndb_has(&rec, "dial")) {
      p9_client *c;
      vx_str src;
      st = vx_ns_dial(ns, vx_ndb_get(&rec, "dial"), &c, &src);
      if (st == VX_OK)
        st = vx_ns_mount(ns, c, VX_HANDLE_NONE, src, vx_ndb_get(&rec, "aname"), vx_ndb_get(&rec, "mount"),
                         flags);
    } else if (st == VX_OK && mount) {
      vx_handle connector;
      p9_client *c = vx_ns_connect(from, vx_ndb_get(&rec, "handle"), &connector, &st);
      if (c)
        st = vx_ns_mount(ns, c, connector, vx_ndb_get(&rec, "src"), vx_ndb_get(&rec, "aname"),
                         vx_ndb_get(&rec, "mount"), flags);
    } else if (st == VX_OK) {
      st = vx_ns_bind(ns, vx_ndb_get(&rec, "new"), vx_ndb_get(&rec, "bind"), flags);
    }
    if (st != VX_OK) {
      vx_print(VX_STR("vx-ns: cannot replay the record on line "));
      vx_print_u64(rec.line);
      vx_print(from ? VX_STR(" of the namespace after a fork: ") : VX_STR(" of the spawn message: "));
      vx_print(p9_error_text(st));
      vx_print(VX_STR("\n"));
      return st;
    }
  }
  return VX_OK;
}

// --- Namespace groups (ADR-0009; nsd's protocol is lib/vx-ns/nsd.h) ---
//
// A member keeps its own table, built from the group's text, which it maps
// read-only from nsd: before a name is resolved, if the text's sequence has
// moved, the table is emptied and the text replayed (refresh). A change made
// to the table is sent to nsd as the table's new text (publish).

typedef struct vx_ns_group_state {
  vx_handle chan;       // this process's channel to nsd for its group, or none: a namespace of its own
  vx_handle srv;        // a connector to nsd's post, to make a group with, or none
  const nsd_page *page; // the group's text, mapped read-only
  uint64_t seq;         // the sequence the table was last built from
} vx_ns_group_state;
static vx_ns_group_state vx_ns_group;

static constexpr uint64_t VX_NS_PAGE_SIZE = (sizeof(nsd_page) + 4095) & ~4095ull;
alignas(nsd_msg) static uint8_t vx_ns_msg[VX_CHANNEL_MAX_BYTES];

// One call to nsd on ch: args, then text and names, giving handles; the
// reply in *rep, its handles in got (up to got_cap). Returns the channel's
// status, or the reply's.
static vx_status vx_ns_nsd(vx_handle ch, uint32_t call, nsd_args a, vx_str text, vx_str names,
                           const vx_handle *give, uint32_t ngive, nsd_msg *rep, vx_handle *got,
                           uint32_t got_cap) {
  nsd_msg *m = (nsd_msg *)vx_ns_msg;
  a.text_len = (uint32_t)text.len;
  if (sizeof *m + text.len + names.len > sizeof vx_ns_msg) return VX_ERR_RANGE;
  *m = (nsd_msg){.h = {.ordinal = call}, .a = a};
  memcpy(vx_ns_msg + sizeof *m, text.ptr, text.len);
  memcpy(vx_ns_msg + sizeof *m + text.len, names.ptr, names.len);
  *rep = (nsd_msg){};
  vx_call c = {.wr_bytes = vx_ns_msg,
               .wr_len = (uint32_t)(sizeof *m + text.len + names.len),
               .wr_handles = ngive ? give : nullptr,
               .wr_count = ngive,
               .rd_bytes = rep,
               .rd_cap = sizeof *rep,
               .rd_handles = got,
               .rd_count_cap = got_cap};
  vx_status st = vx_channel_call(ch, &c, VX_INFINITE);
  if (st == VX_OK && c.actual.bytes < sizeof *rep) st = VX_ERR_INVALID;
  if (st == VX_OK && rep->h.flags) st = (vx_status)(int32_t)rep->h.flags;
  if (st != VX_OK && got)
    for (uint32_t i = 0; i < c.actual.handles && i < got_cap; i++) vx_handle_close(got[i]);
  return st;
}

// Replays a group's text onto an empty table: a mount's source is a
// connection the table has from it already, a connector nsd keeps for the
// group (/srv/NAME), or an address to dial.
static vx_status vx_ns_group_apply(vx_ns *ns, vx_str text) {
  static vx_ns_script script;
  script = (vx_ns_script){.text = text};
  vx_ns_op op;
  vx_status st, first = VX_OK;
  while ((st = vx_ns_script_next(&script, &op)) == VX_OK) {
    if (op.kind == VX_NS_OP_MOUNT) {
      vx_str aname = op.argc > 2 ? op.args[2] : (vx_str){};
      st = vx_ns_mount_srv(ns, op.args[0], aname, op.args[1], op.flags);
      bool post = op.args[0].len > 5 && memcmp(op.args[0].ptr, "/srv/", 5) == 0;
      if (st == VX_ERR_NOT_FOUND) { // a post, or an address mounted through a relay (relay.c): nsd has it
        nsd_msg rep;
        vx_handle connector = VX_HANDLE_NONE;
        st = vx_ns_nsd(vx_ns_group.chan, NSD_CONNECTOR, (nsd_args){}, op.args[0], (vx_str){}, nullptr, 0,
                       &rep, &connector, 1);
        p9_client *c = st == VX_OK ? vx_ns_connect_handle(connector, &st) : nullptr;
        if (c)
          st = vx_ns_mount(ns, c, connector, op.args[0], aname, op.args[1], op.flags);
        else if (connector)
          vx_handle_close(connector);
      }
      if (st == VX_ERR_NOT_FOUND && !post) { // an address dialed by its first member: dialed
        p9_client *c;
        vx_str src;
        st = vx_ns_dial(ns, op.args[0], &c, &src);
        if (st == VX_OK) st = vx_ns_mount(ns, c, VX_HANDLE_NONE, src, aname, op.args[1], op.flags);
      }
    } else if (op.kind == VX_NS_OP_BIND) {
      st = vx_ns_bind(ns, op.args[0], op.args[1], op.flags);
    } else if (op.kind == VX_NS_OP_UNMOUNT) {
      st = vx_ns_unmount(ns, op.argc == 2 ? op.args[0] : (vx_str){}, op.args[op.argc - 1]);
    }
    if (st != VX_OK) { // said, and the rest replayed: one line lost, not all after it
      vx_print(VX_STR("vx-ns: cannot replay line "));
      vx_print_u64(op.line);
      vx_print(VX_STR(" of the namespace group's: "));
      vx_print(p9_error_text(st));
      vx_print(VX_STR("\n"));
      if (first == VX_OK) first = st;
    }
  }
  if (st != VX_ERR_NOT_FOUND) return st; // the text itself is bad
  return first;
}

// The table, brought up to the group's: emptied and built again from its
// text, if that has changed since the table was last built.
static void vx_ns_group_refresh(vx_ns *ns) {
  const nsd_page *page = vx_ns_group.page;
  if (!page || __atomic_load_n(&page->seq, __ATOMIC_ACQUIRE) == vx_ns_group.seq) return;
  static char text[NSD_TEXT_MAX];
  uint64_t seq;
  uint32_t len;
  for (;;) { // a copy nsd was not writing: the same even sequence before and after
    seq = __atomic_load_n(&page->seq, __ATOMIC_ACQUIRE);
    if (seq & 1) continue;
    len = page->len < NSD_TEXT_MAX ? page->len : NSD_TEXT_MAX;
    memcpy(text, page->text, len);
    __atomic_thread_fence(__ATOMIC_ACQUIRE);
    if (__atomic_load_n(&page->seq, __ATOMIC_RELAXED) == seq) break;
  }
  ns->quiet = true;
  vx_ns_reset(ns);
  vx_ns_group_apply(ns, (vx_str){text, len});
  ns->quiet = false;
  vx_ns_group.seq = seq;
}

// The table has changed: its text, to nsd, from the sequence it was built
// on, with the connector of a connection the change added. BAD_STATE if
// another member changed the group first.
static vx_status vx_ns_group_publish(vx_ns *ns, uint8_t new_conn) {
  static char text[NSD_TEXT_MAX];
  size_t len = vx_ns_print(ns, text, sizeof text);
  bool empty = true;
  for (uint32_t i = 0; i < VX_NS_MAX_ENTRIES && empty; i++) empty = !ns->entries[i].path_len;
  if (!len && !empty) return VX_ERR_RANGE; // too long to send: never an empty text in its place
  char names[VX_NS_MAX_SRC + 1];
  vx_str line = {};
  vx_handle give = VX_HANDLE_NONE;
  if (new_conn < VX_NS_MAX_CONNS && ns->conns[new_conn].connector &&
      vx_handle_dup(ns->conns[new_conn].connector, VX_RIGHTS_SAME, &give) == VX_OK) {
    memcpy(names, ns->conns[new_conn].src, ns->conns[new_conn].src_len);
    names[ns->conns[new_conn].src_len] = '\n';
    line = (vx_str){names, ns->conns[new_conn].src_len + 1u};
  }
  nsd_msg rep;
  vx_status st =
      vx_ns_nsd(vx_ns_group.chan, NSD_UPDATE, (nsd_args){.seq = vx_ns_group.seq, .count = give ? 1 : 0},
                (vx_str){text, len}, line, &give, give ? 1 : 0, &rep, nullptr, 0);
  if (st == VX_OK) vx_ns_group.seq = rep.a.seq;
  return st;
}

// Maps the group's text, given a handle to its VMO (which the mapping keeps).
static vx_status vx_ns_group_map(vx_handle vmo) {
  uint64_t va = 0;
  vx_status st = vx_as_map(vx_self, vmo, 0, VX_NS_PAGE_SIZE, 0, &va);
  vx_handle_close(vmo);
  if (st == VX_OK) vx_ns_group.page = (const nsd_page *)va;
  return st;
}

static void vx_ns_group_hooks(vx_ns *ns) {
  ns->release = vx_ns_release;
  ns->refresh = vx_ns_group_refresh;
  ns->publish = vx_ns_group_publish;
}

// Joins the group chan is a channel for: maps its text, and builds the table from it.
static vx_status vx_ns_group_join(vx_ns *ns, vx_handle chan) {
  vx_task_summary me;
  nsd_msg rep;
  vx_handle vmo = VX_HANDLE_NONE;
  vx_ns_group.chan = chan;
  vx_status st =
      vx_ns_nsd(chan, NSD_HELLO, (nsd_args){.task = vx_task_info(vx_self, &me) == VX_OK ? me.id : 0},
                (vx_str){}, (vx_str){}, nullptr, 0, &rep, &vmo, 1);
  if (st == VX_OK) st = vx_ns_group_map(vmo);
  if (st != VX_OK) return st;
  vx_ns_group.seq = ~0ull; // never a sequence: the first refresh builds the table
  vx_ns_group_hooks(ns);
  vx_ns_group_refresh(ns);
  return VX_OK;
}

// Leaves the namespace group (rc's rfork n, 6d7b3, as RFNAMEG): the table, as
// it is, a copy of this process's own; the group's later changes are not
// seen, nor are this one's by the group. A child shares it in a group made
// for it (vx_ns_spawn_records). Nothing to do without a group.
[[maybe_unused]] static void vx_ns_group_leave(vx_ns *ns) {
  if (!vx_ns_group.chan) return;
  ns_catch_up(ns); // the group's table as it is now
  ns->refresh = nullptr, ns->publish = nullptr;
  vx_handle_close(vx_ns_group.chan);
  if (vx_ns_group.page) vx_as_unmap(vx_self, (uint64_t)vx_ns_group.page, VX_NS_PAGE_SIZE);
  vx_ns_group.chan = VX_HANDLE_NONE, vx_ns_group.page = nullptr, vx_ns_group.seq = 0;
}

// Makes a group of this process's namespace, with it as the first member, so
// a child can share it. NOT_FOUND without nsd.
static vx_status vx_ns_group_make(vx_ns *ns) {
  if (!vx_ns_group.srv) return VX_ERR_NOT_FOUND;
  static char text[NSD_TEXT_MAX], names[VX_NS_MAX_CONNS * (VX_NS_MAX_SRC + 1)];
  size_t len = vx_ns_print(ns, text, sizeof text), nl = 0;
  bool empty = true;
  for (uint32_t i = 0; i < VX_NS_MAX_ENTRIES && empty; i++) empty = !ns->entries[i].path_len;
  if (!len && !empty) return VX_ERR_RANGE; // too long to send: never a group with an empty text
  vx_handle give[VX_NS_MAX_CONNS];
  uint32_t n = 0;
  for (uint32_t i = 0; i < VX_NS_MAX_CONNS; i++) {
    const vx_ns_conn *c = &ns->conns[i];
    if (!c->client || !c->connector || vx_handle_dup(c->connector, VX_RIGHTS_SAME, &give[n]) != VX_OK)
      continue;
    memcpy(names + nl, c->src, c->src_len);
    nl += c->src_len;
    names[nl++] = '\n';
    n++;
  }
  nsd_msg rep;
  vx_handle got[2] = {};
  vx_task_summary me;
  nsd_args a = {.task = vx_task_info(vx_self, &me) == VX_OK ? me.id : 0, .count = n};
  vx_status st =
      vx_ns_nsd(vx_ns_group.srv, NSD_NEW, a, (vx_str){text, len}, (vx_str){names, nl}, give, n, &rep, got, 2);
  if (st != VX_OK) return st;
  vx_ns_group.chan = got[0];
  st = vx_ns_group_map(got[1]);
  if (st != VX_OK) return st;
  vx_ns_group.seq = rep.a.seq; // the table is the text already
  vx_ns_group_hooks(ns);
  return VX_OK;
}

// --- /fd (ADR-0040): the process's own descriptors, as 9front's devdup ---
//
// /fd/N opened is a copy of descriptor N (vx-rt's vx_fd): a pipe end, read
// or written with the pipe protocol. Not listed, and not in the namespace.

typedef struct vx_fd_opened { // an open /fd/N's state
  bool used;
  vx_pipe_in in; // a reading end's
  vx_handle out; // a writing end
} vx_fd_opened;

static vx_fd_opened vx_fd_opens[8];
static vx_lock_t vx_fd_opens_lock;

static int64_t vx_fd_read(vx_ns_file *f, void *buf, uint32_t count) {
  vx_fd_opened *x = f->dev_ctx;
  return x->in.end ? vx_pipe_read(&x->in, buf, count) : VX_ERR_ACCESS;
}

static int64_t vx_fd_write(vx_ns_file *f, const void *buf, uint32_t count) {
  vx_fd_opened *x = f->dev_ctx;
  if (!x->out) return VX_ERR_ACCESS;
  // On the stack: thread_local would give the POSIX back end, which has this,
  // a TLS block musl's dynamic linker does not lay out for libc.so (6f1b2).
  alignas(vx_msg_header) uint8_t msg[sizeof(vx_msg_header) + 4096];
  for (uint32_t done = 0; done < count;) {
    uint32_t n = count - done > 4096 ? 4096 : count - done;
    memcpy(msg + sizeof(vx_msg_header), (const uint8_t *)buf + done, n);
    vx_pipe_write(x->out, msg, n);
    done += n;
  }
  return count;
}

static void vx_fd_close(vx_ns_file *f) {
  vx_fd_opened *x = f->dev_ctx;
  if (x->in.end) vx_handle_close(x->in.end);
  if (x->in.port) vx_handle_close(x->in.port);
  if (x->out) vx_handle_close(x->out);
  vx_lock(&vx_fd_opens_lock);
  *x = (vx_fd_opened){};
  vx_unlock(&vx_fd_opens_lock);
  f->dev = nullptr;
}

static const vx_ns_dev vx_fd_dev = {.read = vx_fd_read, .write = vx_fd_write, .close = vx_fd_close};

// An open file given as a descriptor: joined by its token, the first time,
// as the open file the parent had; else opened again by its name, at the
// offset it was at.
static vx_status vx_fd_open_file(vx_ns *ns, vx_fd_entry *e, uint8_t mode, vx_ns_file *f) {
  vx_str path = {e->path, e->path_len};
  if (e->has_token) {
    e->has_token = false;
    p9_client *c;
    uint32_t fid, joined;
    size_t dir = path.len; // the file's connection, or its directory's if it has gone since
    while (dir > 1 && path.ptr[dir - 1] != '/') dir--;
    if (vx_ns_walk(ns, path, &c, &fid) == VX_OK ||
        vx_ns_walk(ns, (vx_str){path.ptr, dir}, &c, &fid) == VX_OK) {
      p9c_clunk(c, fid);
      if (p9c_join(c, e->token, &joined) == VX_OK) {
        *f = (vx_ns_file){.ns = ns, .c = c, .fid = joined, .offset = e->offset};
        return VX_OK;
      }
    }
  }
  vx_status st = vx_ns_open(ns, path, mode, f);
  if (st == VX_OK) f->offset = e->offset;
  return st;
}

// vx_ns's open_dev: /fd/N, for a descriptor this process has, opened the
// way it goes (ACCESS otherwise); NOT_FOUND for any other name.
static vx_status vx_fd_open(vx_ns *ns, vx_str path, uint8_t mode, vx_ns_file *f) {
  (void)ns;
  if (path.len != 5 || memcmp(path.ptr, "/fd/", 4) != 0 || path.ptr[4] < '0' || path.ptr[4] > '9')
    return VX_ERR_NOT_FOUND;
  vx_fd_entry *file = vx_fd_file((uint32_t)(path.ptr[4] - '0'));
  if (file) return vx_fd_open_file(ns, file, mode, f);
  bool reader;
  vx_handle h = vx_fd((uint32_t)(path.ptr[4] - '0'), &reader);
  if (!h) return VX_ERR_NOT_FOUND;
  if ((mode & 3) != (reader ? P9_OREAD : P9_OWRITE)) return VX_ERR_ACCESS;
  vx_handle copy;
  vx_status st = vx_handle_dup(h, VX_RIGHTS_SAME, &copy);
  if (st != VX_OK) return st;
  vx_lock(&vx_fd_opens_lock);
  vx_fd_opened *x = nullptr;
  for (uint32_t i = 0; i < sizeof vx_fd_opens / sizeof vx_fd_opens[0] && !x; i++)
    if (!vx_fd_opens[i].used) x = &vx_fd_opens[i];
  if (x)
    *x =
        (vx_fd_opened){.used = true, .in = {.end = reader ? copy : VX_HANDLE_NONE}, .out = reader ? 0 : copy};
  vx_unlock(&vx_fd_opens_lock);
  if (!x) return vx_handle_close(copy), VX_ERR_NO_MEMORY;
  f->dev = &vx_fd_dev, f->dev_ctx = x;
  return VX_OK;
}

// --- /env (ADR-0044) ---
//
// The process's environment group, on envd, through a connection of its
// own: the group its parent named (envgroup=TOKEN), or after a fork the
// parent's, or else a new one filled from the spawn message's env= records.
// Attached on first use: a process that never touches /env and starts no
// child never connects.

static struct {
  vx_handle connector; // "srv:env", kept for children
  p9_conn conn;
  uint64_t token; // its group's (the root's qid path); 0 before the first attach
  bool failed;    // no envd, or it refused: /env is the namespace table's
} vx_env;

static void vx_env_hex(uint64_t v, char out[17]) {
  for (int i = 15; i >= 0; i--) out[15 - i] = "0123456789abcdef"[(v >> (4 * i)) & 15];
  out[16] = 0;
}

// Attaches aname on the env connection: the root fid in *fid, the group's token in *token.
static vx_status vx_env_attach_as(vx_str aname, uint32_t *fid, uint64_t *token) {
  p9_qid q = {};
  vx_status st = p9c_attach_qid(&vx_env.conn.c, aname, fid, &q);
  if (st == VX_OK) *token = q.path;
  return st;
}

// A new group's variables: this process's environment as it was given.
static void vx_env_seed(uint32_t root) {
  for (uint32_t i = 0; i < vx_spawn.envc; i++) {
    vx_str e = vx_spawn.envs[i];
    size_t eq = 0;
    while (eq < e.len && e.ptr[eq] != '=') eq++;
    if (!eq || eq == e.len) continue;
    uint32_t fid;
    if (p9c_walk(&vx_env.conn.c, root, (vx_str){}, &fid) != VX_OK) return;
    if (p9c_create(&vx_env.conn.c, fid, (vx_str){e.ptr, eq}, 0664, P9_OWRITE) == VX_OK)
      p9c_write(&vx_env.conn.c, fid, 0, e.ptr + eq + 1, (uint32_t)(e.len - eq - 1));
    p9c_clunk(&vx_env.conn.c, fid);
  }
}

static bool vx_env_attach(vx_ns *ns) {
  if (ns->conns[VX_NS_ENV_CONN].client) return true;
  if (vx_env.failed) return false;
  if (!vx_env.connector) vx_env.connector = vx_spawn_take("srv:env");
  if (!vx_env.connector || p9_ring_connect(vx_env.connector, &vx_env.conn) != VX_OK) {
    vx_env.failed = true;
    return false;
  }
  char hex[17] = {};
  vx_ndb_record rec;
  if (vx_env.token) // after a fork: the parent's group, as 9front's fork shares its Egrp
    vx_env_hex(vx_env.token, hex);
  else if (vx_spawn_record("envgroup", &rec) && vx_ndb_get(&rec, "envgroup").len == 16)
    memcpy(hex, vx_ndb_get(&rec, "envgroup").ptr, 16);
  uint32_t root = 0;
  vx_status st = hex[0] ? vx_env_attach_as(vx_cstr(hex), &root, &vx_env.token) : VX_ERR_NOT_FOUND;
  if (st != VX_OK) { // none named, or its last holder is gone: a new one, from what this process was given
    st = vx_env_attach_as(VX_STR("new"), &root, &vx_env.token);
    if (st == VX_OK) vx_env_seed(root);
  }
  if (st != VX_OK) {
    p9_ring_disconnect(&vx_env.conn);
    p9_conn_clear(&vx_env.conn, false);
    vx_env.failed = true;
    return false;
  }
  ns->conns[VX_NS_ENV_CONN].client = &vx_env.conn.c;
  ns->env_root = root;
  return true;
}

// rfork e (copy) and E (empty) for /env: a new group for this process and the
// children it starts from now on; the old one goes on for those sharing it.
[[maybe_unused]] static vx_status vx_ns_env_fork(vx_ns *ns, bool copy) {
  if (!vx_env_attach(ns)) return VX_ERR_NOT_FOUND;
  char aname[18] = "+";
  vx_env_hex(vx_env.token, aname + 1);
  uint32_t root;
  uint64_t token;
  vx_status st = vx_env_attach_as(copy ? vx_cstr(aname) : VX_STR("new"), &root, &token);
  if (st != VX_OK) return st;
  p9c_clunk(&vx_env.conn.c, ns->env_root);
  ns->env_root = root, vx_env.token = token;
  return VX_OK;
}

// A child's share of this process's group: its token, and envd's connector.
static vx_status vx_env_records(vx_ns *ns, vx_ndb_writer *w, vx_handle *handles, vx_str *names,
                                uint32_t *count, uint32_t cap) {
  if (*count >= cap || !vx_env_attach(ns)) return VX_OK; // none: the child's env= records are all it has
  if (vx_handle_dup(vx_env.connector, VX_RIGHTS_SAME, &handles[*count]) != VX_OK) return VX_OK;
  names[(*count)++] = VX_STR("srv:env");
  char hex[17];
  vx_env_hex(vx_env.token, hex);
  vx_ndb_put(w, "envgroup", vx_cstr(hex));
  vx_ndb_end(w);
  return VX_OK;
}

[[maybe_unused]] static vx_status vx_ns_from_spawn(vx_ns *ns) {
  p9c_user = vx_spawn.user;       // its attaches name its user (docs/11 §9)
  ns->getwd = vx_getwd;           // relative names from the current directory (ADR-0039)
  ns->open_dev = vx_fd_open;      // and /fd/N, its descriptors (ADR-0040)
  ns->env_attach = vx_env_attach; // and /env, its environment group (ADR-0044)
  vx_ns_group.srv = vx_spawn_take("srv:nsd");
  vx_handle chan = vx_spawn_take("nsgroup");
  vx_status st = chan ? vx_ns_group_join(ns, chan) : vx_ns_replay(ns, vx_spawn.text, nullptr);
  ns->nomount =
      vx_spawn_record("nomount", &(vx_ndb_record){}); // its parent's rfork m (RFNOMNT), after what it
                                                      // was given is in place
  return st;
}

// A copy of the namespace as spawn records for a child, in the order the
// members were added (as vx_ns_print writes them): a mount record for each
// mounted member, naming a duplicate of its connection's connector, added to
// handles (one "ns.N" for each connection, however many mounts use it); a
// bind record for the rest. The child connects to each server itself. Adds to
// *count; on failure the handles it added are closed and *count is as it was.
static vx_status vx_ns_copy_records(const vx_ns *ns, vx_ndb_writer *w, vx_handle *handles, vx_str *names,
                                    uint32_t *count, uint32_t cap) {
  static char name_buf[VX_CHANNEL_MAX_HANDLES][8];
  static vx_ns_step steps[VX_NS_MAX_ENTRIES * VX_NS_MAX_MEMBERS];
  int32_t handle_of[VX_NS_MAX_CONNS]; // each connection's handle in this message, or -1
  for (uint32_t i = 0; i < VX_NS_MAX_CONNS; i++) handle_of[i] = -1;
  uint32_t first = *count, n = ns_order(ns, steps);
  for (uint32_t s = 0; s < n; s++) {
    const vx_ns_entry *e = &ns->entries[steps[s].entry];
    const vx_ns_member *m = &e->members[steps[s].member];
    vx_str path = {e->path, e->path_len}, from = {m->from, m->from_len};
    char flags[3];
    size_t nf = ns_step_flags(ns, steps, s, flags);
    const vx_ns_conn *c = &ns->conns[m->conn];
    if (m->mounted && !c->connector) { // dialed: the child dials it too
      vx_ndb_put(w, "mount", path);
      vx_ndb_put(w, "dial", (vx_str){c->src, c->src_len});
      if (from.len) vx_ndb_put(w, "aname", from);
    } else if (m->mounted) {
      if (handle_of[m->conn] < 0) {
        if (*count == cap || *count >= VX_CHANNEL_MAX_HANDLES ||
            vx_handle_dup(c->connector, VX_RIGHTS_SAME, &handles[*count]) != VX_OK) {
          for (uint32_t j = first; j < *count; j++) vx_handle_close(handles[j]);
          *count = first;
          return VX_ERR_NO_MEMORY;
        }
        char *nm = name_buf[*count];
        nm[0] = 'n', nm[1] = 's', nm[2] = '.', nm[3] = (char)('0' + *count / 10),
        nm[4] = (char)('0' + *count % 10);
        names[*count] = (vx_str){nm, 5};
        handle_of[m->conn] = (int32_t)(*count)++;
      }
      vx_ndb_put(w, "mount", path);
      vx_ndb_put(w, "handle", names[handle_of[m->conn]]);
      if (from.len) vx_ndb_put(w, "aname", from);
      vx_ndb_put(w, "src", (vx_str){c->src, c->src_len});
    } else {
      vx_ndb_put(w, "bind", path);
      vx_ndb_put(w, "new", from);
    }
    if (nf) vx_ndb_put(w, "flags", (vx_str){flags, nf});
    vx_ndb_end(w);
  }
  if (!w->failed) return VX_OK;
  for (uint32_t j = first; j < *count; j++) vx_handle_close(handles[j]);
  *count = first;
  return VX_ERR_RANGE;
}

// The namespace for a child, as spawn records and handles (02 §2), and the
// current directory it starts in (cwd=, ADR-0039). As Plan
// 9's rfork shares a namespace unless asked not to, the child joins this
// process's namespace group (ADR-0009), made now if this is the first child
// to share it: a channel to nsd for it ("nsgroup"). Without nsd, a copy
// (vx_ns_copy_records). Either way the child gets nsd's post too ("srv:nsd"),
// to make a group of its own. Adds to *count; on failure the handles it added
// are closed and *count is as it was.
[[maybe_unused]] static vx_status vx_ns_spawn_records(vx_ns *ns, vx_ndb_writer *w, vx_handle *handles,
                                                      vx_str *names, uint32_t *count, uint32_t cap) {
  if (cap > VX_CHANNEL_MAX_HANDLES) cap = VX_CHANNEL_MAX_HANDLES;
  if (*count + 2 > cap) return VX_ERR_NO_MEMORY;
  char wd[VX_WD_MAX]; // the child starts where this process is (ADR-0039)
  size_t wn = vx_getwd(wd, sizeof wd);
  if (wn) vx_ndb_put(w, "cwd", (vx_str){wd, wn}), vx_ndb_end(w);
  if (ns->nomount) vx_ndb_flag(w, "nomount"), vx_ndb_end(w); // RFNOMNT, inherited
  vx_status st = VX_ERR_NOT_FOUND;
  if (!vx_ns_group.chan) vx_ns_group_make(ns); // NOT_FOUND without nsd: a copy, below
  if (vx_ns_group.chan) {
    nsd_msg rep;
    vx_handle chan = VX_HANDLE_NONE;
    st = vx_ns_nsd(vx_ns_group.chan, NSD_SHARE, (nsd_args){}, (vx_str){}, (vx_str){}, nullptr, 0, &rep, &chan,
                   1);
    if (st == VX_OK) handles[*count] = chan, names[(*count)++] = VX_STR("nsgroup");
  }
  if (st != VX_OK) st = vx_ns_copy_records(ns, w, handles, names, count, cap - 1);
  if (st == VX_OK && vx_ns_group.srv &&
      vx_handle_dup(vx_ns_group.srv, VX_RIGHTS_SAME, &handles[*count]) == VX_OK)
    names[(*count)++] = VX_STR("srv:nsd");
  if (st == VX_OK) vx_env_records(ns, w, handles, names, count, cap); // its environment group (ADR-0044)
  return st;
}

// Changes the current directory to path (ADR-0039): resolved, walked and
// found to be a directory, else refused (INVALID if it is not one) and left
// as it was. libvx's (6e1), until libvx.
// The machine's name (M6 step 6e1c3, R17): /sys/name, as 9front's
// /dev/sysname, into buf; its length, or vectra's where there is no /sys.
[[maybe_unused]] static size_t vx_hostname(vx_ns *ns, char *buf, size_t cap) {
  size_t len = 0;
  if (vx_ns_read_all(ns, VX_STR("/sys/name"), buf, cap, &len) == VX_OK && len) return len;
  len = cap < 6 ? cap : 6;
  memcpy(buf, "vectra", len);
  return len;
}

[[maybe_unused]] static vx_status vx_chdir(vx_ns *ns, vx_str path) {
  char clean[VX_NS_MAX_PATH];
  size_t len;
  vx_status st = vx_ns_dir_check(ns, path, clean, &len);
  if (st == VX_OK && !vx_wd_set((vx_str){clean, len})) st = VX_ERR_RANGE;
  return st;
}

// After a fork (01 §9): the namespace's rings were not copied into this
// process, so its connections are let go, here only (the parent keeps its
// own), and the namespace is built again from its own records over new
// connections, through the connectors it kept. A dialed mount is dialed
// again; the old TCP connection's state is left behind.
static vx_status vx_ns_after_fork_table(vx_ns *ns); // below

[[maybe_unused]] static vx_status vx_ns_after_fork(vx_ns *ns) {
  // The env connection's ring was not copied either: let go here, and
  // attached again on first use, to the same group (its token is kept).
  if (vx_env.conn.end) p9_ring_disconnect(&vx_env.conn);
  p9_conn_clear(&vx_env.conn, false);
  vx_env.failed = false;
  vx_status st = vx_ns_after_fork_table(ns);
  ns->env_attach = vx_env_attach;
  return st;
}

static vx_status vx_ns_after_fork_table(vx_ns *ns) {
  if (vx_ns_group.chan) {
    // In a group: the channel to nsd and the mapping of its text were copied
    // from the parent's; this process gets a channel of its own, maps the
    // text again, and builds its table from it over new connections.
    nsd_msg rep;
    vx_handle chan = VX_HANDLE_NONE;
    vx_status st = vx_ns_nsd(vx_ns_group.chan, NSD_SHARE, (nsd_args){}, (vx_str){}, (vx_str){}, nullptr, 0,
                             &rep, &chan, 1);
    vx_handle_close(vx_ns_group.chan);
    vx_as_unmap(vx_self, (uint64_t)vx_ns_group.page, VX_NS_PAGE_SIZE);
    for (uint32_t i = 0; i < VX_NS_MAX_CONNS; i++) {
      if (vx_ns_conns[i].end) p9_ring_disconnect(&vx_ns_conns[i]);
      p9_conn_clear(&vx_ns_conns[i], false);
      vx_ns_conn_names[i][0] = 0;
      if (ns->conns[i].connector) vx_handle_close(ns->conns[i].connector);
    }
    memset(ns, 0, sizeof *ns); // not a compound literal: too big to build on the stack first
    vx_ns_group = (vx_ns_group_state){.srv = vx_ns_group.srv};
    return st == VX_OK ? vx_ns_group_join(ns, chan) : st;
  }
  static char records[16 * 1024];
  vx_handle handles[VX_CHANNEL_MAX_HANDLES];
  vx_str names[VX_CHANNEL_MAX_HANDLES];
  uint32_t count = 0;
  vx_ndb_writer w = {.buf = records, .cap = sizeof records};
  vx_status st = vx_ns_copy_records(ns, &w, handles, names, &count, VX_CHANNEL_MAX_HANDLES);
  for (uint32_t i = 0; i < VX_NS_MAX_CONNS; i++) {
    if (vx_ns_conns[i].end) p9_ring_disconnect(&vx_ns_conns[i]);
    p9_conn_clear(&vx_ns_conns[i], false);
    vx_ns_conn_names[i][0] = 0;
    if (ns->conns[i].connector) vx_handle_close(ns->conns[i].connector);
  }
  memset(ns, 0, sizeof *ns); // not a compound literal: too big to build on the stack first
  if (st != VX_OK) return st;
  vx_ns_handles from = {.names = names, .handles = handles, .count = count};
  ns->release = vx_ns_release;
  st = vx_ns_replay(ns, (vx_str){records, w.len}, &from);
  for (uint32_t i = 0; i < count; i++)
    if (handles[i]) vx_handle_close(handles[i]); // one the records did not use
  return st;
}
