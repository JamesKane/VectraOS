// vx-ns: a process's namespace, in its own address space (docs/02 §2, D4).
// Builds for the target and the host; it sees servers only as p9_clients.
//
// The table holds mount points, each a union: an ordered list of members,
// each a directory on some connection (a fid this table owns, never opened,
// only cloned). `mount` attaches a connection and adds its root; `bind`
// resolves a path and adds what it finds. Flags say where the new member
// goes: replacing the union (none), after it (-a), or before it (-b); -c
// marks the member that takes creates.
//
// A mount point is found by identity, as in Plan 9 (9front's findmount,
// ADR-0009), not by the path it was made at: the connection and qid of the
// directory it was made on, so it shows through every name that reaches that
// directory. Resolution cleans the path lexically first, so `..` never climbs
// out of a bind (Plan 9's rule), then walks from the root, a Twalk of the
// names left at a time; each Twalk returns a qid per name, and where one is a
// mount point's, the walk goes on from that union with the names after it.
// A mount point may also be a new name in a directory (/n/host, which Plan
// 9's mntgen would provide): it is found by that directory and the name.
// Confinement is not this table's job: it is the connections' (02 §2).
//
// `ns` output (vx_ns_print) is namespace(6), and replays: one `mount` or
// `bind` line per member, in the order they were added, the first of each
// union without -a, the rest with it.

#pragma once

#if __STDC_HOSTED__
#include <string.h> // host tests
#else
#include "../vx-mem/mem.h"
#endif

#include "../vx-9p/client.c"
#include "../vx-utf/utf.h"

static constexpr uint32_t VX_NS_MAX_PATH = 256;
static constexpr uint32_t VX_NS_MAX_ENTRIES = 32;
static constexpr uint32_t VX_NS_MAX_MEMBERS = 8;
static constexpr uint32_t VX_NS_MAX_CONNS = 16; // the POSIX template has 7, and fsd's branches come on top
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
  uint64_t qid; // the qid path of the directory its fid is: walks from it check mount points against it
  char from[VX_NS_MAX_PATH]; // bind: the path; mount: the aname
  uint16_t from_len;
  uint32_t seq; // when it was added: ns output and children replay members in this order
} vx_ns_member;

// What a mount point is: the root, a directory (a connection and its qid),
// or a new name in a directory (that directory, and the last component of the
// entry's path). In a union directory, the directory is its first member.
enum vx_ns_id : uint8_t { VX_NS_ID_ROOT, VX_NS_ID_OBJECT, VX_NS_ID_NAME };

typedef struct vx_ns_entry {
  char path[VX_NS_MAX_PATH]; // where it was made, for ns output
  uint16_t path_len;         // 0: the slot is free
  uint8_t id;                // enum vx_ns_id
  uint8_t id_conn;           // OBJECT, NAME: the connection
  uint64_t id_qid;           // OBJECT: the directory's qid path; NAME: the directory the name is in
  uint32_t count;
  vx_ns_member members[VX_NS_MAX_MEMBERS];
} vx_ns_entry;

typedef struct vx_ns vx_ns;
struct vx_ns {
  vx_ns_conn conns[VX_NS_MAX_CONNS];
  vx_ns_entry entries[VX_NS_MAX_ENTRIES];
  uint32_t next_seq;
  // Called when unmount leaves a connection with no members, after its fids
  // are clunked; the connection's slot is free once it returns. May be null.
  void (*release)(p9_client *c, vx_handle connector);
  // A namespace group's (ADR-0009; lib/vx-ns/spawn.c and nsd), or null for a
  // namespace of its own. refresh brings the table up to the group's, before a
  // name is resolved; publish tells the group the table has changed, adding
  // connection new_conn if it is not VX_NS_MAX_CONNS, and answers BAD_STATE if
  // the group moved on meanwhile: the change is then made again, after a refresh.
  void (*refresh)(vx_ns *ns);
  vx_status (*publish)(vx_ns *ns, uint8_t new_conn);
  bool quiet; // a refresh is replaying the group's table: no hooks
};

static void ns_catch_up(vx_ns *ns) {
  if (ns->refresh && !ns->quiet) ns->refresh(ns);
}

// Cleans an absolute path lexically: no empty, "." or ".." components, and
// ".." above the root is the root. Returns its length, or 0 for a relative
// path, one that does not fit, or one holding a name ADR-0013 refuses (not
// UTF-8, or with a control character).
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
    if (!vx_utf_name(in.ptr + start, n)) return 0; // UTF-8, no control characters (ADR-0013)
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

static vx_ns_entry *ns_exact(vx_ns *ns, vx_str path) {
  for (uint32_t i = 0; i < VX_NS_MAX_ENTRIES; i++)
    if (ns->entries[i].path_len == path.len && memcmp(ns->entries[i].path, path.ptr, path.len) == 0)
      return &ns->entries[i];
  return nullptr;
}

// The last component of a cleaned path ("" for "/").
static vx_str ns_last(vx_str path) {
  size_t at = path.len;
  while (at > 0 && path.ptr[at - 1] != '/') at--;
  return (vx_str){path.ptr + at, path.len - at};
}

static vx_ns_entry *ns_root(vx_ns *ns) {
  for (uint32_t i = 0; i < VX_NS_MAX_ENTRIES; i++)
    if (ns->entries[i].path_len && ns->entries[i].id == VX_NS_ID_ROOT) return &ns->entries[i];
  return nullptr;
}

// The mount point that is directory `qid` on connection `conn`, if any.
static vx_ns_entry *ns_find_object(vx_ns *ns, uint8_t conn, uint64_t qid) {
  for (uint32_t i = 0; i < VX_NS_MAX_ENTRIES; i++) {
    vx_ns_entry *e = &ns->entries[i];
    if (e->path_len && e->id == VX_NS_ID_OBJECT && e->id_conn == conn && e->id_qid == qid) return e;
  }
  return nullptr;
}

static bool ns_str_eq(vx_str a, vx_str b) { return a.len == b.len && memcmp(a.ptr, b.ptr, a.len) == 0; }

// The mount point that is the new name `name` in directory (conn, qid), if any.
static vx_ns_entry *ns_find_name(vx_ns *ns, uint8_t conn, uint64_t qid, vx_str name) {
  for (uint32_t i = 0; i < VX_NS_MAX_ENTRIES; i++) {
    vx_ns_entry *e = &ns->entries[i];
    if (e->path_len && e->id == VX_NS_ID_NAME && e->id_conn == conn && e->id_qid == qid &&
        ns_str_eq(ns_last((vx_str){e->path, e->path_len}), name))
      return e;
  }
  return nullptr;
}

static constexpr uint32_t VX_NS_MAX_DEPTH = 64; // names in a path

// A cleaned path's names. Returns how many, or -1 if there are too many.
static int ns_split(vx_str path, vx_str *names) {
  int n = 0;
  for (size_t i = 0; i < path.len;) {
    while (i < path.len && path.ptr[i] == '/') i++;
    size_t start = i;
    while (i < path.len && path.ptr[i] != '/') i++;
    if (i == start) continue;
    if (n == (int)VX_NS_MAX_DEPTH) return -1;
    names[n++] = (vx_str){path.ptr + start, i - start};
  }
  return n;
}

// Where a resolution ended: a fid (the caller's to clunk) on a connection,
// with the qid path of what it reached; and the mount point it is, if it is
// one (the walk ended exactly on it).
typedef struct vx_ns_at {
  uint8_t conn;
  uint32_t fid;
  uint64_t qid;
  vx_ns_entry *entry;
} vx_ns_at;

// Walks names[i..n) from fid (conn, at qid) on, checking each name reached
// against the mount points. Returns VX_OK with *done set and *out filled when
// it reaches the last name; VX_OK with *jump set to a mount point and *i moved
// past what led there; or the error that stopped it. A fid this walk made is
// clunked unless returned.
static vx_status ns_walk_on(vx_ns *ns, uint8_t conn, uint32_t fid, uint64_t qid, const vx_str *names, int n,
                            int *i, vx_ns_entry **jump, bool *done, vx_ns_at *out) {
  p9_client *c = ns->conns[conn].client;
  uint32_t cur = fid;
  bool owned = false; // cur is a fid this walk made
  *jump = nullptr;
  *done = false;
  for (;;) {
    vx_ns_entry *hit = ns_find_name(ns, conn, qid, names[*i]); // a new name mounted here
    if (hit) {
      *i += 1;
      *jump = hit;
      break;
    }
    uint16_t count = (uint16_t)(n - *i < (int)P9_MAXWELEM ? n - *i : (int)P9_MAXWELEM), got = 0;
    p9_qid qids[P9_MAXWELEM];
    uint32_t next = P9_NOFID;
    vx_status st = p9c_walk_names(c, cur, &names[*i], count, &next, qids, &got);
    if (st != VX_OK || got == 0) {
      if (owned) p9c_clunk(c, cur);
      return st != VX_OK ? st : VX_ERR_NOT_FOUND;
    }
    for (uint16_t j = 0; j < got && !hit; j++) { // a mount point among the names reached, or just past one?
      int after = *i + j + 1;                    // the names used up once qids[j] is reached
      if ((hit = ns_find_object(ns, conn, qids[j].path)))
        *i = after;
      else if (after < n && (hit = ns_find_name(ns, conn, qids[j].path, names[after])))
        *i = after + 1;
    }
    if (hit) {
      if (next != P9_NOFID) p9c_clunk(c, next);
      *jump = hit;
      break;
    }
    if (got < count) { // stopped partway, at no mount point
      if (owned) p9c_clunk(c, cur);
      return VX_ERR_NOT_FOUND;
    }
    if (owned) p9c_clunk(c, cur);
    cur = next;
    owned = true;
    qid = qids[got - 1].path;
    *i += count;
    if (*i == n) {
      *out = (vx_ns_at){.conn = conn, .fid = cur, .qid = qid};
      *done = true;
      return VX_OK;
    }
  }
  if (owned) p9c_clunk(c, cur);
  return VX_OK;
}

// Resolves a cleaned path from the root, crossing mount points by identity.
static vx_status ns_resolve(vx_ns *ns, vx_str path, vx_ns_at *out) {
  vx_str names[VX_NS_MAX_DEPTH];
  int n = ns_split(path, names);
  vx_ns_entry *e = ns_root(ns);
  if (n < 0) return VX_ERR_RANGE;
  if (!e) return VX_ERR_NOT_FOUND;
  int i = 0;
  for (uint32_t hops = 0; hops <= VX_NS_MAX_DEPTH; hops++) {
    if (i == n) { // exactly at a mount point: its first member
      const vx_ns_member *m = &e->members[0];
      vx_status st = p9c_walk(ns->conns[m->conn].client, m->fid, (vx_str){}, &out->fid);
      if (st != VX_OK) return st;
      out->conn = m->conn, out->qid = m->qid, out->entry = e;
      return VX_OK;
    }
    vx_status st = VX_ERR_NOT_FOUND;
    vx_ns_entry *jump = nullptr;
    for (uint32_t k = 0; k < e->count && !jump; k++) { // a union: each member in turn
      const vx_ns_member *m = &e->members[k];
      int at = i;
      bool done = false;
      st = ns_walk_on(ns, m->conn, m->fid, m->qid, names, n, &at, &jump, &done, out);
      if (st == VX_OK && done) {
        out->entry = nullptr;
        return VX_OK;
      }
      if (jump) i = at;
    }
    if (!jump) return st;
    e = jump;
  }
  return VX_ERR_RANGE; // mount points in a loop
}

// Resolves a path to a new fid on one of the namespace's connections: the
// caller owns it and clunks it. Members of a union are tried in order.
[[maybe_unused]] static vx_status vx_ns_walk(vx_ns *ns, vx_str path, p9_client **c, uint32_t *fid) {
  ns_catch_up(ns);
  char clean[VX_NS_MAX_PATH];
  size_t n = vx_ns_clean(path, clean, sizeof clean);
  if (!n) return VX_ERR_INVALID;
  vx_ns_at at;
  vx_status st = ns_resolve(ns, (vx_str){clean, n}, &at);
  if (st != VX_OK) return st;
  *c = ns->conns[at.conn].client;
  *fid = at.fid;
  return VX_OK;
}

// The connector of the first mount at the path `path` was made at (a spawner
// registers its children with whatever serves /proc: lib/vx-proc/proc.h), or
// VX_HANDLE_NONE. The namespace keeps it: the caller does not close it.
[[maybe_unused]] static vx_handle vx_ns_connector(vx_ns *ns, vx_str path) {
  ns_catch_up(ns);
  vx_ns_entry *e = ns_exact(ns, path);
  for (uint32_t i = 0; e && i < e->count; i++)
    if (e->members[i].mounted && ns->conns[e->members[i].conn].connector)
      return ns->conns[e->members[i].conn].connector;
  return VX_HANDLE_NONE;
}

static void ns_drop_member(vx_ns *ns, const vx_ns_member *m) { p9c_clunk(ns->conns[m->conn].client, m->fid); }

static vx_status ns_insert(vx_ns *ns, vx_ns_entry *e, vx_ns_member m, uint8_t flags, uint32_t at) {
  if (e->count == VX_NS_MAX_MEMBERS) return VX_ERR_NO_MEMORY;
  m.flags = flags & VX_NS_CREATE;
  m.seq = ns->next_seq++;
  memmove(&e->members[at + 1], &e->members[at], (e->count - at) * sizeof e->members[0]);
  e->members[at] = m;
  e->count++;
  return VX_OK;
}

// The mount point at the cleaned path `old`, found or made: what `old`
// resolves to now, as 9front's cmount finds the mount head by what it is
// mounted on: a mount point already (joined), or a directory; or, to replace
// rather than join, a new name in a directory that exists (/n/host for a
// mount needs only /n). "/" may be mounted on in an empty namespace. To join
// a union with what was there, the union starts with it.
static vx_status ns_point(vx_ns *ns, vx_str old, uint8_t flags, vx_ns_entry **out) {
  bool union_with_old = flags & (VX_NS_AFTER | VX_NS_BEFORE);
  vx_ns_entry *fresh = nullptr;
  for (uint32_t i = 0; i < VX_NS_MAX_ENTRIES && !fresh; i++)
    if (!ns->entries[i].path_len) fresh = &ns->entries[i];
  vx_ns_at at;
  vx_status st = ns_root(ns) ? ns_resolve(ns, old, &at) : VX_ERR_NOT_FOUND;
  if (st == VX_OK && at.entry) { // a mount point already: the same one, by whatever name
    p9c_clunk(ns->conns[at.conn].client, at.fid);
    *out = at.entry;
    return VX_OK;
  }
  vx_ns_entry e = {.path_len = (uint16_t)old.len};
  memcpy(e.path, old.ptr, old.len);
  if (st == VX_OK) {
    e.id = VX_NS_ID_OBJECT, e.id_conn = at.conn, e.id_qid = at.qid;
    if (union_with_old) {
      e.members[e.count++] = (vx_ns_member){.conn = at.conn,
                                            .fid = at.fid,
                                            .qid = at.qid,
                                            .from_len = (uint16_t)old.len,
                                            .seq = ns->next_seq++};
      memcpy(e.members[0].from, old.ptr, old.len);
    } else {
      p9c_clunk(ns->conns[at.conn].client, at.fid); // it only had to exist
    }
  } else if (old.len == 1 && !union_with_old && !ns_root(ns)) {
    e.id = VX_NS_ID_ROOT;
  } else if (st == VX_ERR_NOT_FOUND && !union_with_old &&
             old.len > 1) { // a new name: its directory must exist
    size_t up = old.len - ns_last(old).len;
    vx_ns_at dir;
    if (ns_resolve(ns, (vx_str){old.ptr, up > 1 ? up - 1 : 1}, &dir) != VX_OK) return st;
    p9c_clunk(ns->conns[dir.conn].client, dir.fid);
    e.id = VX_NS_ID_NAME, e.id_conn = dir.conn, e.id_qid = dir.qid; // a union's: its first member's
  } else {
    return st;
  }
  if (!fresh) {
    if (e.count) p9c_clunk(ns->conns[e.members[0].conn].client, e.members[0].fid);
    return VX_ERR_NO_MEMORY;
  }
  *fresh = e;
  *out = fresh;
  return VX_OK;
}

// Adds m at the cleaned path `old`, as flags say: replacing the union, or
// after it (-a), or before it (-b).
static vx_status ns_add(vx_ns *ns, vx_str old, vx_ns_member m, uint8_t flags) {
  vx_ns_entry *e;
  vx_status st = ns_point(ns, old, flags, &e);
  if (st != VX_OK) return st;
  if (!(flags & (VX_NS_AFTER | VX_NS_BEFORE))) {
    for (uint32_t i = 0; i < e->count; i++) ns_drop_member(ns, &e->members[i]);
    e->count = 0;
  }
  return ns_insert(ns, e, m, flags, flags & VX_NS_BEFORE ? 0 : e->count);
}

// vx_ns_mount's change, to this table alone.
static vx_status ns_mount_raw(vx_ns *ns, p9_client *c, vx_handle connector, vx_str src, vx_str aname,
                              vx_str old, uint8_t flags) {
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
  p9_qid qid;
  vx_status st = p9c_attach_qid(c, aname, &m.fid, &qid);
  if (st != VX_OK) return st;
  m.qid = qid.path;
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

// vx_ns_bind's change, to this table alone.
static vx_status ns_bind_raw(vx_ns *ns, vx_str new, vx_str old, uint8_t flags) {
  char from[VX_NS_MAX_PATH], to[VX_NS_MAX_PATH];
  size_t fn = vx_ns_clean(new, from, sizeof from), tn = vx_ns_clean(old, to, sizeof to);
  if (!fn || !tn) return VX_ERR_INVALID;
  vx_ns_at src;
  vx_status st = ns_resolve(ns, (vx_str){from, fn}, &src);
  if (st != VX_OK) return st;
  vx_ns_member m = {.conn = src.conn, .fid = src.fid, .qid = src.qid, .from_len = (uint16_t)fn};
  memcpy(m.from, from, fn);
  vx_ns_entry *e;
  st = ns_point(ns, (vx_str){to, tn}, flags, &e);
  if (st == VX_OK && src.entry == e) st = VX_ERR_INVALID; // a union onto itself
  if (st != VX_OK) {
    p9c_clunk(ns->conns[src.conn].client, src.fid);
    return st;
  }
  if (!(flags & (VX_NS_AFTER | VX_NS_BEFORE))) {
    for (uint32_t i = 0; i < e->count; i++) ns_drop_member(ns, &e->members[i]);
    e->count = 0;
  }
  uint32_t at = flags & VX_NS_BEFORE ? 0 : e->count;
  st = ns_insert(ns, e, m, flags, at);
  if (st != VX_OK) p9c_clunk(ns->conns[src.conn].client, src.fid);
  for (uint32_t k = 1; st == VX_OK && src.entry && k < src.entry->count; k++) { // the rest of a union
    const vx_ns_member *u = &src.entry->members[k];
    vx_ns_member more = *u;
    st = p9c_walk(ns->conns[u->conn].client, u->fid, (vx_str){}, &more.fid);
    if (st == VX_OK) st = ns_insert(ns, e, more, (uint8_t)(u->flags & VX_NS_CREATE), ++at);
  }
  return st;
}

// vx_ns_unmount's change, to this table alone.
static vx_status ns_unmount_raw(vx_ns *ns, vx_str new, vx_str old) {
  char to[VX_NS_MAX_PATH], from[VX_NS_MAX_PATH];
  size_t tn = vx_ns_clean(old, to, sizeof to), fn = new.len ? vx_ns_clean(new, from, sizeof from) : 0;
  if (!tn || (new.len && !fn)) return VX_ERR_INVALID;
  vx_ns_at at; // the mount point there, by identity, or by the path it was made at
  vx_ns_entry *e = nullptr;
  if (ns_resolve(ns, (vx_str){to, tn}, &at) == VX_OK) {
    e = at.entry;
    p9c_clunk(ns->conns[at.conn].client, at.fid);
  }
  if (!e) e = ns_exact(ns, (vx_str){to, tn});
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
  // A connection no member uses any more is let go: no member, mounted or
  // bound (a bind of something under a mount walks on its connection too, and
  // outlives the mount: mount; bind /n/x/bin /bin; unmount /n/x).
  for (uint8_t c = 0; c < VX_NS_MAX_CONNS; c++) {
    bool used = !ns->conns[c].client;
    for (uint32_t i = 0; i < VX_NS_MAX_ENTRIES && !used; i++)
      for (uint32_t k = 0; ns->entries[i].path_len && k < ns->entries[i].count && !used; k++)
        used = ns->entries[i].members[k].conn == c;
    if (used) continue;
    if (ns->release) ns->release(ns->conns[c].client, ns->conns[c].connector);
    ns->conns[c] = (vx_ns_conn){};
  }
  return removed ? VX_OK : VX_ERR_NOT_FOUND;
}

// The table, emptied: every member's fid clunked, every mount point gone. Its
// connections stay, for a refresh to use again.
[[maybe_unused]] static void vx_ns_reset(vx_ns *ns) {
  for (uint32_t i = 0; i < VX_NS_MAX_ENTRIES; i++) {
    vx_ns_entry *e = &ns->entries[i];
    for (uint32_t k = 0; e->path_len && k < e->count; k++) ns_drop_member(ns, &e->members[k]);
    *e = (vx_ns_entry){};
  }
}

// A change to the table, and the group told of it: made again after catching
// up, if the group moved on meanwhile (ADR-0009).
static vx_status ns_publish(vx_ns *ns, vx_status st, uint8_t new_conn, bool *again) {
  *again = false;
  if (st != VX_OK || !ns->publish || ns->quiet) return st;
  st = ns->publish(ns, new_conn);
  *again = st == VX_ERR_BAD_STATE;
  return st;
}

static uint8_t ns_conn_of(const vx_ns *ns, const p9_client *c) {
  for (uint8_t i = 0; i < VX_NS_MAX_CONNS; i++)
    if (ns->conns[i].client == c) return i;
  return VX_NS_MAX_CONNS;
}

// Adds a connection (attached at its aname) at `old`. The namespace takes c:
// it is used until the namespace drops it. `connector` and `src` say where it
// came from, for children and for ns output.
[[maybe_unused]] static vx_status vx_ns_mount(vx_ns *ns, p9_client *c, vx_handle connector, vx_str src,
                                              vx_str aname, vx_str old, uint8_t flags) {
  vx_status st = VX_ERR_BAD_STATE;
  bool again = true;
  // New to this namespace or not, as it was before the first try: a try made
  // again finds c among the connections (vx_ns_reset keeps them), and the
  // group must still be given its connector.
  bool fresh = ns_conn_of(ns, c) == VX_NS_MAX_CONNS;
  for (int tries = 0; again && tries < 8; tries++) {
    ns_catch_up(ns);
    st = ns_mount_raw(ns, c, connector, src, aname, old, flags);
    st = ns_publish(ns, st, fresh ? ns_conn_of(ns, c) : VX_NS_MAX_CONNS, &again);
  }
  return st;
}

// Makes `old` show what `new` names now. A union bound on a directory is
// copied whole, as 9front's cmount copies one: its members in order.
[[maybe_unused]] static vx_status vx_ns_bind(vx_ns *ns, vx_str new, vx_str old, uint8_t flags) {
  vx_status st = VX_ERR_BAD_STATE;
  bool again = true;
  for (int tries = 0; again && tries < 8; tries++) {
    ns_catch_up(ns);
    st = ns_publish(ns, ns_bind_raw(ns, new, old, flags), VX_NS_MAX_CONNS, &again);
  }
  return st;
}

// Removes what was bound or mounted from `new` at `old`, or, with an empty
// `new`, everything at `old`.
[[maybe_unused]] static vx_status vx_ns_unmount(vx_ns *ns, vx_str new, vx_str old) {
  vx_status st = VX_ERR_BAD_STATE;
  bool again = true;
  for (int tries = 0; again && tries < 8; tries++) {
    ns_catch_up(ns);
    st = ns_publish(ns, ns_unmount_raw(ns, new, old), VX_NS_MAX_CONNS, &again);
  }
  return st;
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

// A word as namespace(6) reads it: in single quotes ('' for a quote) if it
// holds white space, a quote, a '$' or a '#', or is empty.
static void ns_put_word(ns_text *t, vx_str s) {
  bool quote = s.len == 0;
  for (size_t i = 0; i < s.len && !quote; i++)
    quote = s.ptr[i] == ' ' || s.ptr[i] == '\t' || s.ptr[i] == '\'' || s.ptr[i] == '$' || s.ptr[i] == '#';
  if (!quote) {
    ns_put(t, s);
    return;
  }
  ns_put(t, (vx_str){"'", 1});
  for (size_t i = 0; i < s.len; i++) ns_put(t, s.ptr[i] == '\'' ? (vx_str){"''", 2} : (vx_str){s.ptr + i, 1});
  ns_put(t, (vx_str){"'", 1});
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

// Writes the namespace as namespace(6): mount and bind lines, in the order
// they would rebuild it. Returns its length, or 0 if it does not fit.
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
    ns_put_word(&t, from);
    ns_put(&t, VX_STR(" "));
    ns_put_word(&t, (vx_str){e->path, e->path_len});
    if (m->mounted && m->from_len) {
      ns_put(&t, VX_STR(" "));
      ns_put_word(&t, (vx_str){m->from, m->from_len});
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
  ns_catch_up(ns);
  *f = (vx_ns_file){.ns = ns};
  char clean[VX_NS_MAX_PATH];
  size_t n = vx_ns_clean(path, clean, sizeof clean);
  if (!n) return VX_ERR_INVALID;
  vx_ns_at at;
  vx_status st = ns_resolve(ns, (vx_str){clean, n}, &at);
  if (st != VX_OK) return st;
  f->c = ns->conns[at.conn].client;
  f->fid = at.fid; // a union's first member, if it is a union
  if (at.entry && at.entry->count > 1 && (mode & 3) == P9_OREAD) f->u = at.entry;
  st = p9c_open(f->c, f->fid, mode);
  if (st != VX_OK) p9c_clunk(f->c, f->fid);
  if (st != VX_OK) *f = (vx_ns_file){};
  return st;
}

// Creates the file at path (in the directory its last '/' names), open in
// `mode`, with permissions perm.
[[maybe_unused]] static vx_status vx_ns_create(vx_ns *ns, vx_str path, uint32_t perm, uint8_t mode,
                                               vx_ns_file *f) {
  ns_catch_up(ns);
  *f = (vx_ns_file){.ns = ns};
  char clean[VX_NS_MAX_PATH];
  size_t n = vx_ns_clean(path, clean, sizeof clean), slash = n;
  while (slash > 0 && clean[slash - 1] != '/') slash--;
  if (!n || slash == n) return VX_ERR_INVALID; // "/" itself
  vx_str dir = {clean, slash > 1 ? slash - 1 : 1}, name = {clean + slash, n - slash};
  vx_ns_at at;
  vx_status st = ns_resolve(ns, dir, &at);
  if (st != VX_OK) return st;
  f->c = ns->conns[at.conn].client;
  f->fid = at.fid;
  if (at.entry &&
      at.entry->count > 1) { // a union: the first member bound with -c, or none (9front's createdir)
    const vx_ns_member *m = nullptr;
    for (uint32_t i = 0; i < at.entry->count && !m; i++)
      if (at.entry->members[i].flags & VX_NS_CREATE) m = &at.entry->members[i];
    p9c_clunk(f->c, f->fid);
    st = m ? p9c_walk(ns->conns[m->conn].client, m->fid, (vx_str){}, &f->fid) : VX_ERR_ACCESS;
    if (st != VX_OK) {
      *f = (vx_ns_file){};
      return st;
    }
    f->c = ns->conns[m->conn].client;
  }
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

// A whole file into buf, its length in *len. RANGE if it holds more than cap
// bytes (what fitted is in buf); otherwise the open's or a read's error.
[[maybe_unused]] static vx_status vx_ns_read_all(vx_ns *ns, vx_str path, void *buf, size_t cap, size_t *len) {
  vx_ns_file f;
  *len = 0;
  vx_status st = vx_ns_open(ns, path, P9_OREAD, &f);
  if (st != VX_OK) return st;
  int64_t n = 0;
  while (*len < cap) {
    uint32_t want = cap - *len > 65536 ? 65536 : (uint32_t)(cap - *len);
    if ((n = vx_ns_read(&f, (uint8_t *)buf + *len, want)) <= 0) break;
    *len += (size_t)n;
  }
  uint8_t more;
  if (n >= 0 && *len == cap && vx_ns_read(&f, &more, 1) > 0) n = VX_ERR_RANGE;
  vx_ns_close(&f);
  return n < 0 ? (vx_status)n : VX_OK;
}
