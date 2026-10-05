// vx-man: the installed manual, as man, lookman and sig read it (docs/12 §5,
// §6.1): pages at /lib/man/<sect>/<page>, and the index, /lib/man/index/, a
// directory of ndb files (base, one per package, home) whose union is the
// index. One record per name a page documents, and per node:
//
//   name=vx_create page=open sect=2 summary="open, create or close a file"
//   name=quoting page=rc sect=1 node=quoting title="Quoting"
//
// Pages are parsed by lib/vx-guide; this only finds them.

#pragma once

#include "../vx-ndb/ndb.c"
#include "../vx-ns/ns.c"

static bool vx_man_eq(vx_str a, vx_str b) { return a.len == b.len && memcmp(a.ptr, b.ptr, a.len) == 0; }

// /lib/man/<sect>/<name>, NUL-terminated, into path; false if it does not fit.
[[maybe_unused]] static bool vx_man_path(char *path, size_t cap, int sect, vx_str name) {
  static const char lib[] = "/lib/man/";
  size_t n = sizeof lib - 1;
  if (n + 2 + name.len >= cap || sect < 1 || sect > 8) return false;
  memcpy(path, lib, n);
  path[n++] = (char)('0' + sect), path[n++] = '/';
  memcpy(path + n, name.ptr, name.len);
  path[n + name.len] = 0;
  return true;
}

// Calls each(arg, rec) for every record of every file in the index, until it
// returns false. False if the index cannot be read.
[[maybe_unused]] static bool vx_man_index(vx_ns *ns, bool (*each)(void *arg, const vx_ndb_record *rec),
                                          void *arg) {
  vx_ns_file dir;
  if (vx_ns_open(ns, VX_STR("/lib/man/index"), P9_OREAD, &dir) != VX_OK) return false;
  static uint8_t ents[4096];
  static char text[256 * 1024], scratch[4096];
  bool go = true;
  int64_t n;
  while (go && (n = vx_ns_read(&dir, ents, sizeof ents)) > 0) {
    p9_stat e;
    for (size_t off = 0; go && p9_dir_next(ents, (size_t)n, &off, &e);) {
      char path[96] = "/lib/man/index/";
      size_t at = sizeof "/lib/man/index/" - 1, len;
      if (e.name.len + at >= sizeof path) continue;
      memcpy(path + at, e.name.ptr, e.name.len);
      path[at + e.name.len] = 0;
      if (vx_ns_read_all(ns, (vx_str){path, at + e.name.len}, text, sizeof text, &len) != VX_OK) continue;
      vx_ndb_reader r = {.src = {text, len}, .scratch = scratch, .scratch_cap = sizeof scratch};
      vx_ndb_record rec;
      while (go && vx_ndb_next(&r, &rec) == VX_NDB_RECORD) {
        r.scratch_used = 0;
        go = each(arg, &rec);
      }
    }
  }
  vx_ns_close(&dir);
  return true;
}

typedef struct vx_man_find {
  vx_ns *ns;
  vx_str title;
  const int *sects;
  int nsect;
  char *buf, *path;
  size_t cap, pathcap, len;
  int sect; // where it was found
} vx_man_find;

static bool vx_man_wanted(const vx_man_find *f, int sect) {
  for (int k = 0; k < f->nsect; k++)
    if (f->sects[k] == sect) return true;
  return false;
}

static bool vx_man_by_name(void *arg, const vx_ndb_record *rec) {
  vx_man_find *f = arg;
  uint64_t sect = 0;
  if (vx_ndb_has(rec, "node") || !vx_man_eq(vx_ndb_get(rec, "name"), f->title) ||
      !vx_ndb_get_u64(rec, "sect", &sect) || sect > 8 || !vx_man_wanted(f, (int)sect))
    return true;
  if (vx_man_path(f->path, f->pathcap, (int)sect, vx_ndb_get(rec, "page")) &&
      vx_ns_read_all(f->ns, vx_cstr(f->path), f->buf, f->cap, &f->len) == VX_OK) {
    f->sect = (int)sect;
    return false;
  }
  f->len = 0;
  return true;
}

// The page `title` from the first of `sects` that has it, read into buf, its
// path in path: by its own file, else through the index (a name it documents).
// Its length, or 0.
[[maybe_unused]] static size_t vx_man_read(vx_ns *ns, vx_str title, const int *sects, int nsect, char *buf,
                                           size_t cap, char *path, size_t pathcap) {
  vx_man_find f = {.ns = ns,
                   .title = title,
                   .sects = sects,
                   .nsect = nsect,
                   .buf = buf,
                   .path = path,
                   .cap = cap,
                   .pathcap = pathcap};
  for (int k = 0; k < nsect; k++)
    if (vx_man_path(path, pathcap, sects[k], title) &&
        vx_ns_read_all(ns, vx_cstr(path), buf, cap, &f.len) == VX_OK)
      return f.len;
  f.len = 0;
  vx_man_index(ns, vx_man_by_name, &f);
  return f.len;
}
