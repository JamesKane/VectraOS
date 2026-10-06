// vx-users: the users table, users(6): lines id:name:leader:members, as
// fsd reads /adm/users from its adm branch and distd reads it through fsd.
// Users are advisory until keyd (M10): a client names who it attaches as
// (Tattach's uname), and can name anyone (docs/11 §9). Administration is
// membership of the group whose id is 0.

#pragma once

#include "../../abi/vx/abi.h"

#if __STDC_HOSTED__
#include <string.h>
#else
#include "../vx-mem/mem.h"
#endif

static constexpr uint32_t VX_USERS_MAX = 127, VX_USERS_MEMBERS = 32;
static constexpr uint32_t VX_USERS_NONE_ID = 0xffff'fffe;            // none's id when the file has no none
static constexpr char VX_USERS_DEFAULT[] = "0:adm:adm:\n1:none::\n"; // when there is no file

typedef struct vx_user {
  uint32_t id, lead; // lead: the group's leader's id, or ~0 for none
  char name[32];
  uint8_t nname;
  uint32_t memb[VX_USERS_MEMBERS];
  uint32_t nmemb;
} vx_user;

typedef struct vx_users {
  vx_user user[VX_USERS_MAX + 1]; // and none, whether the file names it or not
  uint32_t n, none;               // none: none's index
} vx_users;

// The index of the user named name, or none's.
[[maybe_unused]] static uint32_t vx_users_named(const vx_users *t, vx_str name) {
  for (uint32_t i = 0; i < t->n; i++)
    if (t->user[i].nname == name.len && memcmp(t->user[i].name, name.ptr, name.len) == 0) return i;
  return t->none;
}

[[maybe_unused]] static const vx_user *vx_users_by_id(const vx_users *t, uint32_t id) {
  for (uint32_t i = 0; i < t->n; i++)
    if (t->user[i].id == id) return &t->user[i];
  return nullptr;
}

[[maybe_unused]] static bool vx_users_in_group(const vx_users *t, uint32_t uid, uint32_t gid) {
  const vx_user *g = vx_users_by_id(t, gid);
  if (!g) return false;
  if (g->id == uid) return true;
  for (uint32_t i = 0; i < g->nmemb; i++)
    if (g->memb[i] == uid) return true;
  return false;
}

[[maybe_unused]] static bool vx_users_leads(const vx_users *t, uint32_t uid, uint32_t gid) {
  const vx_user *g = vx_users_by_id(t, gid);
  if (!g) return false;
  if (g->lead != ~0u) return g->lead == uid;
  return vx_users_in_group(t, uid, gid); // no leader: every member leads
}

// Whether the user named name administers: is in group 0, and is not none.
[[maybe_unused]] static bool vx_users_adm(const vx_users *t, vx_str name) {
  uint32_t who = vx_users_named(t, name);
  return who != t->none && vx_users_in_group(t, t->user[who].id, 0);
}

static vx_str vx_users_field(vx_str *line, char sep) {
  size_t n = 0;
  while (n < line->len && line->ptr[n] != sep) n++;
  vx_str f = {line->ptr, n};
  size_t skip = n < line->len ? n + 1 : n;
  line->ptr += skip, line->len -= skip;
  return f;
}

static bool vx_users_number(vx_str s, uint32_t *v) {
  uint64_t n = 0;
  if (!s.len) return false;
  for (size_t i = 0; i < s.len; i++) {
    if (s.ptr[i] < '0' || s.ptr[i] > '9') return false;
    n = n * 10 + (uint64_t)(s.ptr[i] - '0');
    if (n > 0xffff'ffff) return false;
  }
  *v = (uint32_t)n;
  return true;
}

static uint32_t vx_users_index(const vx_user *u, uint32_t n, vx_str name) {
  uint32_t k = 0;
  while (k < n && !(u[k].nname == name.len && !memcmp(u[k].name, name.ptr, name.len))) k++;
  return k;
}

// The table from users(6) text. False if it is malformed: an id that is no
// number, a name missing or too long, a leader or member who is no user, too
// many users or members; t is then left as it was. A line may stop after its
// name, its leader and members then none.
[[maybe_unused]] static bool vx_users_parse(vx_users *t, vx_str text) {
  static vx_user next[VX_USERS_MAX];
  uint32_t n = 0;
  for (int pass = 0; pass < 2; pass++) { // names first, so leaders and members may come later
    vx_str rest = text;
    uint32_t i = 0;
    while (rest.len) {
      vx_str line = vx_users_field(&rest, '\n');
      if (!line.len || line.ptr[0] == '#') continue;
      vx_str id = vx_users_field(&line, ':'), name = vx_users_field(&line, ':'),
             lead = vx_users_field(&line, ':'), memb = line;
      if (pass == 0) {
        if (n == VX_USERS_MAX || !name.len || name.len > sizeof next[0].name ||
            !vx_users_number(id, &next[n].id))
          return false;
        memcpy(next[n].name, name.ptr, name.len);
        next[n].nname = (uint8_t)name.len, next[n].lead = ~0u, next[n].nmemb = 0;
        n++;
        continue;
      }
      vx_user *u = &next[i++];
      if (lead.len) {
        uint32_t k = vx_users_index(next, n, lead);
        if (k == n) return false;
        u->lead = next[k].id;
      }
      while (memb.len) {
        vx_str m = vx_users_field(&memb, ',');
        if (!m.len) continue;
        uint32_t k = vx_users_index(next, n, m);
        if (k == n || u->nmemb == VX_USERS_MEMBERS) return false;
        u->memb[u->nmemb++] = next[k].id;
      }
    }
  }
  memcpy(t->user, next, n * sizeof *t->user);
  t->n = n;
  t->none = vx_users_index(t->user, t->n, VX_STR("none"));
  if (t->none == t->n) { // none, whether the file says so or not
    t->user[t->n] = (vx_user){.id = VX_USERS_NONE_ID, .lead = ~0u, .name = "none", .nname = 4};
    t->none = t->n++;
  }
  return true;
}

// A user the file no longer has, kept in its place in a table (vx_users_merge).
static constexpr uint32_t VX_USERS_GONE_ID = 0xffff'fffd;

// t made fresh, each user t has still at the index it has in t, a user
// fresh adds where t has no one, and a user fresh no longer has left in
// its place as gone (VX_USERS_GONE_ID, no name), for an index handed out
// (fsd's nodes carry one) never to come to mean someone else (M6 step
// 6d5c). Users are the same user by id. False, and t as it was, if they do
// not fit.
[[maybe_unused]] static bool vx_users_merge(vx_users *t, const vx_users *fresh) {
  static vx_users out;
  bool placed[VX_USERS_MAX + 1] = {};
  out = (vx_users){};
  uint32_t n = t->n;
  for (uint32_t i = 0; i < t->n; i++) {
    uint32_t j = 0;
    while (j < fresh->n &&
           (placed[j] || fresh->user[j].id != t->user[i].id || t->user[i].id == VX_USERS_GONE_ID))
      j++;
    if (j < fresh->n)
      out.user[i] = fresh->user[j], placed[j] = true;
    else
      out.user[i] = (vx_user){.id = VX_USERS_GONE_ID, .lead = ~0u};
  }
  for (uint32_t j = 0; j < fresh->n; j++) {
    if (placed[j]) continue;
    if (n == VX_USERS_MAX + 1) return false;
    out.user[n++] = fresh->user[j];
  }
  out.n = n;
  out.none = vx_users_index(out.user, out.n, VX_STR("none"));
  *t = out;
  return true;
}
