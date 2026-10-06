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

[[maybe_unused]] static vx_status vx_ns_from_spawn(vx_ns *ns) {
  p9c_user = vx_spawn.user; // its attaches name its user (docs/11 §9)
  vx_ns_group.srv = vx_spawn_take("srv:nsd");
  vx_handle chan = vx_spawn_take("nsgroup");
  if (chan) return vx_ns_group_join(ns, chan);
  return vx_ns_replay(ns, vx_spawn.text, nullptr);
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

// The namespace for a child, as spawn records and handles (02 §2). As Plan
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
  return st;
}

// After a fork (01 §9): the namespace's rings were not copied into this
// process, so its connections are let go, here only (the parent keeps its
// own), and the namespace is built again from its own records over new
// connections, through the connectors it kept. A dialed mount is dialed
// again; the old TCP connection's state is left behind.
[[maybe_unused]] static vx_status vx_ns_after_fork(vx_ns *ns) {
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
