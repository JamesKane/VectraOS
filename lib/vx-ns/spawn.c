// vx-ns at start-up: builds a process's namespace from its spawn message
// (abi.h), whose mount= and bind= records are what its parent's template made
// (02 §2). A mount record names a connector handle in the message; each one
// gets its own ring connection to the server behind it. A mount record with
// dial=ADDRESS instead is a 9P server over TCP, which the process dials
// itself (dial.c), through the /net its earlier records gave it.

#pragma once

#include "../vx-9p/ring.c"
#include "ns.c"
#include "dial.c"

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
    vx_ns_conns[free_slot] = (p9_conn){};
    return nullptr;
  }
  memcpy(vx_ns_conn_names[free_slot], cname, sizeof cname);
  return &vx_ns_conns[free_slot].c;
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

[[maybe_unused]] static vx_status vx_ns_from_spawn(vx_ns *ns) {
  return vx_ns_replay(ns, vx_spawn.text, nullptr);
}

// Writes the namespace as spawn records for a child (02 §2: a child gets a
// copy of its parent's namespace), in the order the members were added (as
// vx_ns_print writes them): a mount record for each mounted member, naming a
// duplicate of its connection's connector, added to handles (one "ns.N" for
// each connection, however many mounts use it); a bind record for the rest.
// The child connects to each server itself. Adds to *count; on failure the
// handles it added are closed and *count is as it was.
[[maybe_unused]] static vx_status vx_ns_spawn_records(const vx_ns *ns, vx_ndb_writer *w, vx_handle *handles,
                                                      vx_str *names, uint32_t *count, uint32_t cap) {
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

// After a fork (01 §9): the namespace's rings were not copied into this
// process, so its connections are let go, here only (the parent keeps its
// own), and the namespace is built again from its own records over new
// connections, through the connectors it kept. A dialed mount is dialed
// again; the old TCP connection's state is left behind.
[[maybe_unused]] static vx_status vx_ns_after_fork(vx_ns *ns) {
  static char records[16 * 1024];
  vx_handle handles[VX_CHANNEL_MAX_HANDLES];
  vx_str names[VX_CHANNEL_MAX_HANDLES];
  uint32_t count = 0;
  vx_ndb_writer w = {.buf = records, .cap = sizeof records};
  vx_status st = vx_ns_spawn_records(ns, &w, handles, names, &count, VX_CHANNEL_MAX_HANDLES);
  for (uint32_t i = 0; i < VX_NS_MAX_CONNS; i++) {
    if (vx_ns_conns[i].end) p9_ring_disconnect(&vx_ns_conns[i]);
    vx_ns_conns[i] = (p9_conn){};
    vx_ns_conn_names[i][0] = 0;
    if (ns->conns[i].connector) vx_handle_close(ns->conns[i].connector);
  }
  *ns = (vx_ns){};
  if (st != VX_OK) return st;
  vx_ns_handles from = {.names = names, .handles = handles, .count = count};
  ns->release = vx_ns_release;
  st = vx_ns_replay(ns, (vx_str){records, w.len}, &from);
  for (uint32_t i = 0; i < count; i++)
    if (handles[i]) vx_handle_close(handles[i]); // one the records did not use
  return st;
}
