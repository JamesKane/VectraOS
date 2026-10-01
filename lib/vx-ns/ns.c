// vx-ns: a process's namespace, in its own address space (docs/02 §2, D4).
// Builds for the target and the host; it sees servers only as p9_clients.
//
// The table maps paths to unions: each entry is an absolute path and an
// ordered list of members, each a directory on some connection (a fid this
// table owns, never opened, only cloned). `mount` attaches a connection and
// adds its root; `bind` resolves a path and adds what it finds. Flags say
// where the new member goes: replacing the union (none), after it (-a), or
// before it (-b); -c marks the member that takes creates.
//
// Resolution cleans the path lexically first, so `..` never climbs out of a
// bind (Plan 9's rule), then takes the entry with the longest matching
// prefix and walks the rest from each member in order until one has it.
// Confinement is not this table's job: it is the connections' (02 §2).
//
// `ns` output (vx_ns_print) replays: one `mount` or `bind` line per member,
// the first of each union without -a, the rest with it.

#pragma once

#if __STDC_HOSTED__
#include <string.h> // host tests
#else
#include "../vx-mem/mem.h"
#endif

#include "../vx-9p/client.c"

static constexpr uint32_t VX_NS_MAX_PATH = 256;
static constexpr uint32_t VX_NS_MAX_ENTRIES = 32;
static constexpr uint32_t VX_NS_MAX_MEMBERS = 8;
static constexpr uint32_t VX_NS_MAX_CONNS = 8;
static constexpr uint32_t VX_NS_MAX_SRC = 64;

enum : uint8_t {
  VX_NS_REPLACE = 0,
  VX_NS_AFTER = 1,  // -a
  VX_NS_BEFORE = 2, // -b
  VX_NS_CREATE = 4, // -c
};

typedef struct vx_ns_conn {
  p9_client *client;       // nullptr: the slot is free
  vx_handle connector;     // where it came from, to give children their own (or VX_HANDLE_NONE)
  char src[VX_NS_MAX_SRC]; // "/srv/bootfs", for ns output
  uint8_t src_len;
} vx_ns_conn;

typedef struct vx_ns_member {
  uint8_t conn;
  uint8_t flags; // VX_NS_CREATE
  bool mounted;  // a mount (src and aname) rather than a bind (the path it came from)
  uint32_t fid;
  char from[VX_NS_MAX_PATH]; // bind: the path; mount: the aname
  uint16_t from_len;
  uint32_t seq; // when it was added: ns output and children replay members in this order
} vx_ns_member;

typedef struct vx_ns_entry {
  char path[VX_NS_MAX_PATH];
  uint16_t path_len; // 0: the slot is free
  uint32_t count;
  vx_ns_member members[VX_NS_MAX_MEMBERS];
} vx_ns_entry;

typedef struct vx_ns {
  vx_ns_conn conns[VX_NS_MAX_CONNS];
  vx_ns_entry entries[VX_NS_MAX_ENTRIES];
  uint32_t next_seq;
  // Called when unmount leaves a connection with no members, after its fids
  // are clunked; the connection's slot is free once it returns. May be null.
  void (*release)(p9_client *c, vx_handle connector);
} vx_ns;

// Cleans an absolute path lexically: no empty, "." or ".." components, and
// ".." above the root is the root. Returns its length, or 0 for a relative
// path or one that does not fit.
[[maybe_unused]] static size_t vx_ns_clean(vx_str in, char *out, size_t cap) {
  if (in.len == 0 || in.ptr[0] != '/' || cap < 2) return 0;
  size_t len = 0;
  out[len++] = '/';
  size_t i = 0;
  while (i < in.len) {
    while (i < in.len && in.ptr[i] == '/') i++;
    size_t start = i;
    while (i < in.len && in.ptr[i] != '/') i++;
    size_t n = i - start;
    if (n == 0 || (n == 1 && in.ptr[start] == '.')) continue;
    if (n == 2 && in.ptr[start] == '.' && in.ptr[start + 1] == '.') {
      while (len > 1 && out[len - 1] != '/') len--;
      if (len > 1) len--; // the slash before the component
      continue;
    }
    if (len > 1) {
      if (len == cap) return 0;
      out[len++] = '/';
    }
    if (n > cap - len) return 0;
    memcpy(out + len, in.ptr + start, n);
    len += n;
  }
  return len;
}

// The entry whose path is the longest prefix of `path` at a component
// boundary; *rest is what follows it, without a leading '/'.
static vx_ns_entry *ns_lookup(vx_ns *ns, vx_str path, vx_str *rest) {
  vx_ns_entry *best = nullptr;
  for (uint32_t i = 0; i < VX_NS_MAX_ENTRIES; i++) {
    vx_ns_entry *e = &ns->entries[i];
    size_t n = e->path_len;
    if (!n || n > path.len || memcmp(e->path, path.ptr, n) != 0) continue;
    if (n > 1 && n < path.len && path.ptr[n] != '/') continue; // "/bin" is not a prefix of "/binary"
    if (!best || n > best->path_len) best = e;
  }
  if (best) {
    size_t skip = best->path_len == 1 ? 1 : best->path_len + (path.len > best->path_len);
    *rest = (vx_str){path.ptr + skip, path.len - skip};
  }
  return best;
}

static vx_ns_entry *ns_exact(vx_ns *ns, vx_str path) {
  for (uint32_t i = 0; i < VX_NS_MAX_ENTRIES; i++)
    if (ns->entries[i].path_len == path.len && memcmp(ns->entries[i].path, path.ptr, path.len) == 0)
      return &ns->entries[i];
  return nullptr;
}

// Resolves a path to a new fid on one of the namespace's connections: the
// caller owns it and clunks it. Members of a union are tried in order.
[[maybe_unused]] static vx_status vx_ns_walk(vx_ns *ns, vx_str path, p9_client **c, uint32_t *fid) {
  char clean[VX_NS_MAX_PATH];
  size_t n = vx_ns_clean(path, clean, sizeof clean);
  if (!n) return VX_ERR_INVALID;
  vx_str rest;
  vx_ns_entry *e = ns_lookup(ns, (vx_str){clean, n}, &rest);
  if (!e) return VX_ERR_NOT_FOUND;
  vx_status st = VX_ERR_NOT_FOUND;
  for (uint32_t i = 0; i < e->count; i++) {
    p9_client *client = ns->conns[e->members[i].conn].client;
    st = p9c_walk(client, e->members[i].fid, rest, fid);
    if (st == VX_OK) {
      *c = client;
      return VX_OK;
    }
  }
  return st;
}

static void ns_drop_member(vx_ns *ns, const vx_ns_member *m) { p9c_clunk(ns->conns[m->conn].client, m->fid); }

// Adds m at the cleaned path `old`, which must name something already, or
// (to replace, not to join a union) be a new name in a directory that exists:
// /n/host for a mount needs only /n, as Plan 9's mntgen gives it. "/" may be
// mounted on in an empty namespace.
static vx_status ns_add(vx_ns *ns, vx_str old, vx_ns_member m, uint8_t flags) {
  vx_ns_entry *e = ns_exact(ns, old);
  if (!e) {
    vx_ns_member base = {.conn = 0};
    bool union_with_old = flags & (VX_NS_AFTER | VX_NS_BEFORE);
    p9_client *bc = nullptr;
    vx_status st = vx_ns_walk(ns, old, &bc, &base.fid);
    if (st == VX_ERR_NOT_FOUND && !union_with_old && old.len > 1) { // a new name: its directory must exist
      size_t up = old.len;
      while (up > 1 && old.ptr[up - 1] != '/') up--;
      uint32_t pfid;
      p9_client *pc = nullptr;
      vx_status ps = vx_ns_walk(ns, (vx_str){old.ptr, up > 1 ? up - 1 : 1}, &pc, &pfid);
      if (ps != VX_OK) return st;
      p9c_clunk(pc, pfid);
    } else if (st != VX_OK && !(old.len == 1 && !union_with_old)) {
      return st;
    }
    if (st == VX_OK && !union_with_old) p9c_clunk(bc, base.fid); // it only had to exist
    for (uint32_t i = 0; i < VX_NS_MAX_ENTRIES && !e; i++)
      if (!ns->entries[i].path_len) e = &ns->entries[i];
    if (!e) {
      if (st == VX_OK && union_with_old) p9c_clunk(bc, base.fid);
      return VX_ERR_NO_MEMORY;
    }
    memcpy(e->path, old.ptr, old.len);
    e->path_len = (uint16_t)old.len;
    e->count = 0;
    if (union_with_old) { // the union starts with what was there: a bind of the path onto itself
      for (uint8_t i = 0; i < VX_NS_MAX_CONNS; i++)
        if (ns->conns[i].client == bc) base.conn = i;
      memcpy(base.from, old.ptr, old.len);
      base.from_len = (uint16_t)old.len;
      base.seq = ns->next_seq++;
      e->members[e->count++] = base;
    }
  }
  if (!(flags & (VX_NS_AFTER | VX_NS_BEFORE))) {
    for (uint32_t i = 0; i < e->count; i++) ns_drop_member(ns, &e->members[i]);
    e->count = 0;
  }
  if (e->count == VX_NS_MAX_MEMBERS) return VX_ERR_NO_MEMORY;
  m.flags = flags & VX_NS_CREATE;
  m.seq = ns->next_seq++;
  if (flags & VX_NS_BEFORE) {
    memmove(&e->members[1], &e->members[0], e->count * sizeof e->members[0]);
    e->members[0] = m;
  } else {
    e->members[e->count] = m;
  }
  e->count++;
  return VX_OK;
}

// Adds a connection (attached at its aname) at `old`. The namespace takes c:
// it is used until the namespace drops it. `connector` and `src` say where it
// came from, for children and for ns output.
[[maybe_unused]] static vx_status vx_ns_mount(vx_ns *ns, p9_client *c, vx_handle connector, vx_str src,
                                              vx_str aname, vx_str old, uint8_t flags) {
  char clean[VX_NS_MAX_PATH];
  size_t n = vx_ns_clean(old, clean, sizeof clean);
  if (!n || src.len > VX_NS_MAX_SRC || aname.len > VX_NS_MAX_PATH) return VX_ERR_INVALID;
  uint8_t slot = VX_NS_MAX_CONNS;
  for (uint8_t i = 0; i < VX_NS_MAX_CONNS; i++) {
    if (ns->conns[i].client == c) slot = i; // the same connection again: one more attach
    if (slot == VX_NS_MAX_CONNS && !ns->conns[i].client) slot = i;
  }
  if (slot == VX_NS_MAX_CONNS) return VX_ERR_NO_MEMORY;
  vx_ns_member m = {.conn = slot, .mounted = true, .from_len = (uint16_t)aname.len};
  if (aname.len) memcpy(m.from, aname.ptr, aname.len); // an empty aname may have no pointer
  vx_status st = p9c_attach(c, aname, &m.fid);
  if (st != VX_OK) return st;
  bool fresh = !ns->conns[slot].client;
  if (fresh) {
    ns->conns[slot] = (vx_ns_conn){.client = c, .connector = connector, .src_len = (uint8_t)src.len};
    if (src.len) memcpy(ns->conns[slot].src, src.ptr, src.len);
  }
  st = ns_add(ns, (vx_str){clean, n}, m, flags);
  if (st != VX_OK) {
    p9c_clunk(c, m.fid);
    if (fresh) ns->conns[slot] = (vx_ns_conn){};
  }
  return st;
}

// Makes `old` show what `new` names now.
[[maybe_unused]] static vx_status vx_ns_bind(vx_ns *ns, vx_str new, vx_str old, uint8_t flags) {
  char from[VX_NS_MAX_PATH], to[VX_NS_MAX_PATH];
  size_t fn = vx_ns_clean(new, from, sizeof from), tn = vx_ns_clean(old, to, sizeof to);
  if (!fn || !tn) return VX_ERR_INVALID;
  p9_client *c;
  vx_ns_member m = {.from_len = (uint16_t)fn};
  memcpy(m.from, from, fn);
  vx_status st = vx_ns_walk(ns, (vx_str){from, fn}, &c, &m.fid);
  if (st != VX_OK) return st;
  for (uint8_t i = 0; i < VX_NS_MAX_CONNS; i++)
    if (ns->conns[i].client == c) m.conn = i;
  st = ns_add(ns, (vx_str){to, tn}, m, flags);
  if (st != VX_OK) p9c_clunk(c, m.fid);
  return st;
}

// Removes what was bound or mounted from `new` at `old`, or, with an empty
// `new`, everything at `old`.
[[maybe_unused]] static vx_status vx_ns_unmount(vx_ns *ns, vx_str new, vx_str old) {
  char to[VX_NS_MAX_PATH], from[VX_NS_MAX_PATH];
  size_t tn = vx_ns_clean(old, to, sizeof to), fn = new.len ? vx_ns_clean(new, from, sizeof from) : 0;
  if (!tn || (new.len && !fn)) return VX_ERR_INVALID;
  vx_ns_entry *e = ns_exact(ns, (vx_str){to, tn});
  if (!e) return VX_ERR_NOT_FOUND;
  uint32_t kept = 0;
  bool removed = false;
  for (uint32_t i = 0; i < e->count; i++) {
    vx_ns_member *m = &e->members[i];
    vx_str src = m->mounted ? (vx_str){ns->conns[m->conn].src, ns->conns[m->conn].src_len}
                            : (vx_str){m->from, m->from_len};
    if (!new.len || (src.len == fn && memcmp(src.ptr, from, fn) == 0)) {
      ns_drop_member(ns, m);
      removed = true;
    } else {
      e->members[kept++] = *m;
    }
  }
  e->count = kept;
  if (!kept) e->path_len = 0;
  for (uint8_t c = 0; c < VX_NS_MAX_CONNS; c++) { // a connection no member uses any more is let go
    bool used = !ns->conns[c].client;
    for (uint32_t i = 0; i < VX_NS_MAX_ENTRIES && !used; i++)
      for (uint32_t k = 0; ns->entries[i].path_len && k < ns->entries[i].count && !used; k++)
        used = ns->entries[i].members[k].mounted && ns->entries[i].members[k].conn == c;
    if (used) continue;
    if (ns->release) ns->release(ns->conns[c].client, ns->conns[c].connector);
    ns->conns[c] = (vx_ns_conn){};
  }
  return removed ? VX_OK : VX_ERR_NOT_FOUND;
}

// --- ns output ---

typedef struct ns_text {
  char *buf;
  size_t cap, len;
  bool failed;
} ns_text;

static void ns_put(ns_text *t, vx_str s) {
  if (t->failed || s.len > t->cap - t->len) {
    t->failed = true;
    return;
  }
  memcpy(t->buf + t->len, s.ptr, s.len);
  t->len += s.len;
}

// Every member, as (entry, member) pairs, in the order they were added: the
// order a script or a child must replay them in, since each may resolve paths
// that earlier ones made. Returns how many.
typedef struct vx_ns_step {
  uint8_t entry, member;
} vx_ns_step;

static uint32_t ns_order(const vx_ns *ns, vx_ns_step *steps) {
  uint32_t n = 0;
  for (uint32_t i = 0; i < VX_NS_MAX_ENTRIES; i++)
    for (uint32_t k = 0; ns->entries[i].path_len && k < ns->entries[i].count; k++) {
      uint32_t seq = ns->entries[i].members[k].seq, at = n++;
      for (; at > 0 && ns->entries[steps[at - 1].entry].members[steps[at - 1].member].seq > seq; at--)
        steps[at] = steps[at - 1]; // insertion sort: a few hundred members at most
      steps[at] = (vx_ns_step){(uint8_t)i, (uint8_t)k};
    }
  return n;
}

// The flags that replay step s: none for the first member of its entry to be
// replayed; -b if it comes before every member replayed so far, else -a; and
// -c if it takes creates. Writes them into flags (at most 3 bytes).
static size_t ns_step_flags(const vx_ns *ns, const vx_ns_step *steps, uint32_t s, char *flags) {
  const vx_ns_entry *e = &ns->entries[steps[s].entry];
  bool earlier = false, before_all = true;
  for (uint32_t i = 0; i < s; i++) {
    if (steps[i].entry != steps[s].entry) continue;
    earlier = true;
    if (steps[i].member < steps[s].member) before_all = false;
  }
  size_t n = 0;
  if (earlier) flags[n++] = before_all ? 'b' : 'a';
  if (e->members[steps[s].member].flags & VX_NS_CREATE) flags[n++] = 'c';
  return n;
}

// Writes the namespace as a script of mount and bind lines, in the order they
// would rebuild it. Returns its length, or 0 if it does not fit.
[[maybe_unused]] static size_t vx_ns_print(const vx_ns *ns, char *buf, size_t cap) {
  ns_text t = {.buf = buf, .cap = cap};
  static vx_ns_step steps[VX_NS_MAX_ENTRIES * VX_NS_MAX_MEMBERS];
  uint32_t n = ns_order(ns, steps);
  for (uint32_t s = 0; s < n; s++) {
    const vx_ns_entry *e = &ns->entries[steps[s].entry];
    const vx_ns_member *m = &e->members[steps[s].member];
    char flags[3];
    size_t nf = ns_step_flags(ns, steps, s, flags);
    ns_put(&t, m->mounted ? VX_STR("mount ") : VX_STR("bind "));
    if (nf) {
      ns_put(&t, VX_STR("-"));
      ns_put(&t, (vx_str){flags, nf});
      ns_put(&t, VX_STR(" "));
    }
    vx_str from = m->mounted ? (vx_str){ns->conns[m->conn].src, ns->conns[m->conn].src_len}
                             : (vx_str){m->from, m->from_len};
    ns_put(&t, from);
    ns_put(&t, VX_STR(" "));
    ns_put(&t, (vx_str){e->path, e->path_len});
    if (m->mounted && m->from_len) {
      ns_put(&t, VX_STR(" "));
      ns_put(&t, (vx_str){m->from, m->from_len});
    }
    ns_put(&t, VX_STR("\n"));
  }
  return t.failed ? 0 : t.len;
}

// --- Files ---

typedef struct vx_ns_file {
  vx_ns *ns;
  p9_client *c;
  uint32_t fid;
  uint64_t offset;
  const vx_ns_entry *u; // a union directory being read member by member, or nullptr
  uint32_t member;
} vx_ns_file;

// Opens a path. A directory that is a union reads as each member in turn.
[[maybe_unused]] static vx_status vx_ns_open(vx_ns *ns, vx_str path, uint8_t mode, vx_ns_file *f) {
  *f = (vx_ns_file){.ns = ns};
  char clean[VX_NS_MAX_PATH];
  size_t n = vx_ns_clean(path, clean, sizeof clean);
  if (!n) return VX_ERR_INVALID;
  vx_ns_entry *e = ns_exact(ns, (vx_str){clean, n});
  vx_status st;
  if (e && e->count > 1 && (mode & 3) == P9_OREAD) {
    f->u = e;
    f->c = ns->conns[e->members[0].conn].client;
    st = p9c_walk(f->c, e->members[0].fid, (vx_str){}, &f->fid);
  } else {
    st = vx_ns_walk(ns, (vx_str){clean, n}, &f->c, &f->fid);
  }
  if (st != VX_OK) return st;
  st = p9c_open(f->c, f->fid, mode);
  if (st != VX_OK) p9c_clunk(f->c, f->fid);
  if (st != VX_OK) *f = (vx_ns_file){};
  return st;
}

// Creates the file at path (in the directory its last '/' names), open in
// `mode`, with permissions perm.
[[maybe_unused]] static vx_status vx_ns_create(vx_ns *ns, vx_str path, uint32_t perm, uint8_t mode,
                                               vx_ns_file *f) {
  *f = (vx_ns_file){.ns = ns};
  char clean[VX_NS_MAX_PATH];
  size_t n = vx_ns_clean(path, clean, sizeof clean), slash = n;
  while (slash > 0 && clean[slash - 1] != '/') slash--;
  if (!n || slash == n) return VX_ERR_INVALID; // "/" itself
  vx_str dir = {clean, slash > 1 ? slash - 1 : 1}, name = {clean + slash, n - slash};
  vx_status st = vx_ns_walk(ns, dir, &f->c, &f->fid);
  if (st != VX_OK) return st;
  st = p9c_create(f->c, f->fid, name, perm, mode);
  if (st != VX_OK) {
    p9c_clunk(f->c, f->fid);
    *f = (vx_ns_file){};
  }
  return st;
}

// Reads at the file's offset and moves it on. Returns the count, 0 at the
// end, or a negative vx_status.
[[maybe_unused]] static int64_t vx_ns_read(vx_ns_file *f, void *buf, uint32_t count) {
  if (!f->c) return VX_ERR_BAD_HANDLE; // not open
  for (;;) {
    int64_t n = p9c_read(f->c, f->fid, f->offset, buf, count);
    if (n != 0 || !f->u || f->member + 1 >= f->u->count) {
      if (n > 0) f->offset += (uint64_t)n;
      return n;
    }
    // This member is done: on to the next member of the union.
    p9c_clunk(f->c, f->fid);
    const vx_ns_member *m = &f->u->members[++f->member];
    f->c = f->ns->conns[m->conn].client;
    f->offset = 0;
    vx_status st = p9c_walk(f->c, m->fid, (vx_str){}, &f->fid);
    if (st == VX_OK && (st = p9c_open(f->c, f->fid, P9_OREAD)) != VX_OK) p9c_clunk(f->c, f->fid);
    if (st != VX_OK) {
      *f = (vx_ns_file){}; // nothing open: close has nothing to do
      return st;
    }
  }
}

[[maybe_unused]] static int64_t vx_ns_write(vx_ns_file *f, const void *buf, uint32_t count) {
  if (!f->c) return VX_ERR_BAD_HANDLE;
  int64_t n = p9c_write(f->c, f->fid, f->offset, buf, count);
  if (n > 0) f->offset += (uint64_t)n;
  return n;
}

[[maybe_unused]] static void vx_ns_close(vx_ns_file *f) {
  if (f->c) p9c_clunk(f->c, f->fid);
  *f = (vx_ns_file){};
}
