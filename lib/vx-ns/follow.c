// follow.c: symbolic links followed in the client (docs/proto/posix.md):
// servers walk names only, so a path's links are resolved here, as the
// POSIX personality's back end does (ports/musl/vx/fd.c, fd_resolve, whose
// algorithm this is). libvx's file calls use it (M6 step 6e2e2: C++'s
// std::filesystem on the native target).
//
// A walk of the whole path that succeeds went through no link, as a link is
// no directory, and only its last component may be one; a walk that fails
// may have met one on the way, so its prefixes are looked at in turn. Only
// connections with the posix extension, or 9P2000.L, can hold links.

#pragma once

#include "ns.c"

static constexpr int VX_NS_MAX_LINKS = 40; // links followed for one path, as Linux's ELOOP

// Whether the path's last component is a link (1, its target in target),
// is not (0), or is not there (a negative vx_status).
static int ns_link_at(vx_ns *ns, vx_str path, char *target, size_t cap, size_t *tlen) {
  p9_client *c = nullptr;
  uint32_t fid = 0;
  vx_status st = vx_ns_walk(ns, path, &c, &fid);
  if (st != VX_OK) return st < 0 ? (int)st : (int)VX_ERR_INVALID; // never 1, which says a link
  int r = 0;
  p9_stat s;
  bool links = (c->extensions & P9_EXT_POSIX) || c->dialect == P9_2000L;
  if (links && p9c_stat(c, fid, &s, nullptr) == VX_OK && (s.mode & P9_DMSYMLINK)) {
    size_t n = 0;
    vx_status e = cap ? p9c_readlink(c, fid, target, cap - 1, &n) : VX_ERR_TOO_SMALL;
    r = e == VX_OK ? 1 : (int)VX_ERR_INVALID;
    if (e == VX_OK) *tlen = n;
  }
  p9c_clunk(c, fid);
  return r;
}

// out[0, at), a link to target, replaced by the target (from the link's
// directory if it is relative) with the rest of the path after it: the new
// length, or 0 if it is too long.
static size_t ns_link_splice(char *out, size_t n, size_t at, const char *target, size_t tlen) {
  char next[2 * VX_NS_MAX_PATH];
  size_t len = 0, dir = at;
  while (dir > 1 && out[dir - 1] != '/') dir--;
  if (target[0] != '/') {
    memcpy(next, out, dir);
    len = dir;
  }
  if (len + tlen + 1 + (n - at) > sizeof next) return 0;
  memcpy(next + len, target, tlen);
  len += tlen;
  next[len++] = '/';
  memcpy(next + len, out + at, n - at);
  len += n - at;
  return vx_ns_clean((vx_str){next, len}, out, VX_NS_MAX_PATH);
}

// The first link in out[0, limit), at a prefix of it: 1 with its end in *at
// and its target, 0 if there is none, or a negative vx_status if a
// component is missing.
static int ns_link_in(vx_ns *ns, const char *out, size_t limit, size_t *at, char *target, size_t cap,
                      size_t *tlen) {
  int r = ns_link_at(ns, (vx_str){out, limit}, target, cap, tlen);
  *at = limit;
  if (r >= 0) return r;
  // Not there: a link on the way, perhaps.
  for (size_t end = 1; end <= limit; end++) {
    while (end < limit && out[end] != '/') end++;
    r = ns_link_at(ns, (vx_str){out, end}, target, cap, tlen);
    if (r != 0) {
      *at = end;
      return r;
    }
  }
  return 0;
}

// path (absolute, or from the working directory) cleaned into out, with its
// links followed: every one, or with follow false all but the last
// component's. Returns its length; a path that is not there comes back as
// it is, for the caller to find so. A negative vx_status: RANGE for one too
// long or with more than VX_NS_MAX_LINKS links, INVALID for a bad name.
[[maybe_unused]] static int64_t vx_ns_follow(vx_ns *ns, vx_str path, bool follow, char *out) {
  size_t n = ns_clean(ns, path, out, VX_NS_MAX_PATH); // a relative one from the working directory
  if (!n) return VX_ERR_INVALID;
  for (int hops = 0; n > 1; hops++) {
    if (hops == VX_NS_MAX_LINKS) return VX_ERR_RANGE;
    size_t limit = n; // what may be followed: all, or up to the last component's parent
    if (!follow) {
      while (limit > 1 && out[limit - 1] != '/') limit--;
      if (limit > 1) limit--;
    }
    if (limit <= 1) return (int64_t)n;
    char target[VX_NS_MAX_PATH];
    size_t tlen = 0, at = limit;
    int r = ns_link_in(ns, out, limit, &at, target, sizeof target, &tlen);
    if (r <= 0) return (int64_t)n; // no link; or a component missing, which the caller finds
    n = ns_link_splice(out, n, at, target, tlen);
    if (!n) return VX_ERR_RANGE;
  }
  return (int64_t)n;
}
