// nsd: namespace groups (ADR-0009), posted as /srv/nsd. The protocol is
// lib/vx-ns/nsd.h.
//
// A group is the namespace(6) text its members share, the connectors its
// mount lines name, and a VMO holding the text, which nsd writes and each
// member maps read-only. Each member has its own channel here; nsd waits on
// one port for its listen channel and every member channel, and a group goes
// when its last member does. It keeps no other state: a member resolves names
// from its own copy, made from the text.
//
// nsd is not restarted: the groups live only in it (docs/milestones/known-gaps.md).

#include "../../lib/vx-rt/rt.c"
#include "../../lib/vx-ns/nsd.h"

static constexpr uint32_t MAX_GROUPS = 32;
static constexpr uint32_t MAX_MEMBERS = 128;
static constexpr uint32_t MAX_CONNECTORS = 8; // as a namespace's connections (VX_NS_MAX_CONNS)
static constexpr uint32_t SRC_MAX = 64;

typedef struct group {
  bool used;
  vx_handle vmo;
  nsd_page *page;
  uint32_t members;
  struct {
    char src[SRC_MAX];
    uint8_t len; // 0: the slot is free
    vx_handle connector;
  } conns[MAX_CONNECTORS];
} group;

typedef struct member {
  bool used;
  uint32_t gen;
  vx_handle chan;
  group *g;
  uint64_t task; // as it said (HELLO), for /proc/N/ns
} member;

static group groups[MAX_GROUPS];
static member members[MAX_MEMBERS];
static vx_handle port, listen_ch;

enum : uint64_t { KEY_LISTEN = 1, KEY_READABLE = 2, KEY_CLOSED = 3 };
static uint64_t member_key(uint64_t kind, const member *m) {
  return kind | (uint64_t)(m - members) << 8 | (uint64_t)m->gen << 32;
}

alignas(nsd_msg) static uint8_t msg_buf[VX_CHANNEL_MAX_BYTES];
static vx_handle msg_handles[VX_CHANNEL_MAX_HANDLES];

static bool str_eq(vx_str a, vx_str b) { return a.len == b.len && memcmp(a.ptr, b.ptr, a.len) == 0; }

// Writes the group's text, as its members read it: the sequence odd while it
// changes, even again after (lib/vx-ns/spawn.c reads it so).
static void publish(group *g, vx_str text) {
  uint64_t seq = __atomic_load_n(&g->page->seq, __ATOMIC_RELAXED);
  __atomic_store_n(&g->page->seq, seq + 1, __ATOMIC_RELAXED);
  __atomic_thread_fence(__ATOMIC_RELEASE);
  memcpy(g->page->text, text.ptr, text.len);
  g->page->len = (uint32_t)text.len;
  __atomic_store_n(&g->page->seq, seq + 2, __ATOMIC_RELEASE);
}

// Adds the connectors a NEW or UPDATE carried, named by the lines after its
// text; a source the group has already keeps its connector, and the new
// handle is closed. All or nothing: false (and nothing taken, the caller
// closing every handle) if the names do not match or there is no room.
static bool add_connectors(group *g, vx_str names, const vx_handle *handles, uint32_t count) {
  vx_str srcs[VX_CHANNEL_MAX_HANDLES];
  bool known[VX_CHANNEL_MAX_HANDLES];
  if (count > VX_CHANNEL_MAX_HANDLES) return false;
  uint32_t free_slots = 0, needed = 0;
  for (uint32_t k = 0; k < MAX_CONNECTORS; k++) free_slots += !g->conns[k].len;
  size_t at = 0;
  for (uint32_t i = 0; i < count; i++) { // first, every name checked and the room counted
    size_t start = at;
    while (at < names.len && names.ptr[at] != '\n') at++;
    srcs[i] = (vx_str){names.ptr + start, at - start};
    at++;
    if (!srcs[i].len || srcs[i].len >= SRC_MAX) return false;
    known[i] = false;
    for (uint32_t k = 0; k < MAX_CONNECTORS && !known[i]; k++)
      known[i] = g->conns[k].len && str_eq((vx_str){g->conns[k].src, g->conns[k].len}, srcs[i]);
    for (uint32_t j = 0; j < i && !known[i]; j++) known[i] = str_eq(srcs[j], srcs[i]); // named twice
    needed += !known[i];
  }
  if (needed > free_slots) return false;
  for (uint32_t i = 0; i < count; i++) { // then taken
    if (known[i]) {
      vx_handle_close(handles[i]);
      continue;
    }
    uint32_t k = 0;
    while (g->conns[k].len) k++;
    memcpy(g->conns[k].src, srcs[i].ptr, srcs[i].len);
    g->conns[k].len = (uint8_t)srcs[i].len;
    g->conns[k].connector = handles[i];
  }
  return true;
}

static void forget_group(group *g) {
  for (uint32_t k = 0; k < MAX_CONNECTORS; k++)
    if (g->conns[k].len) vx_handle_close(g->conns[k].connector);
  if (g->page) vx_as_unmap(vx_self, (uint64_t)g->page, sizeof(nsd_page) + 4095 & ~4095ull);
  if (g->vmo) vx_handle_close(g->vmo);
  *g = (group){};
}

// A new member of g: a channel pair, nsd keeping one end. Returns the other.
static vx_handle add_member(group *g) {
  uint32_t slot = 0;
  while (slot < MAX_MEMBERS && members[slot].used) slot++;
  vx_handle ch[2];
  if (slot == MAX_MEMBERS || vx_channel_create(0, ch) != VX_OK) return VX_HANDLE_NONE;
  member *m = &members[slot];
  *m = (member){.used = true, .gen = m->gen + 1, .chan = ch[0], .g = g};
  g->members++;
  vx_port_bind(port, ch[0], VX_TRIGGER_READABLE, member_key(KEY_READABLE, m), 0);
  vx_port_bind(port, ch[0], VX_TRIGGER_PEER_CLOSED, member_key(KEY_CLOSED, m), 0);
  return ch[1];
}

static void drop_member(member *m) {
  group *g = m->g;
  vx_handle_close(m->chan);
  *m = (member){.gen = m->gen};
  if (g && --g->members == 0) forget_group(g);
}

static void reply(vx_handle ch, uint32_t txid, vx_status st, uint64_t seq, vx_str text, vx_handle *give,
                  uint32_t count) {
  nsd_msg *r = (nsd_msg *)msg_buf;
  *r = (nsd_msg){.h = {.txid = txid, .flags = (uint32_t)st},
                 .a = {.seq = seq, .text_len = (uint32_t)text.len}};
  memcpy(msg_buf + sizeof *r, text.ptr, text.len);
  if (vx_channel_write(ch, msg_buf, (uint32_t)(sizeof *r + text.len), count ? give : nullptr, count) != VX_OK)
    for (uint32_t i = 0; i < count; i++) vx_handle_close(give[i]); // the caller has gone
}

// A read-only handle to g's VMO, for a member to map.
static vx_handle page_for(const group *g) {
  vx_handle h = VX_HANDLE_NONE;
  vx_handle_dup(g->vmo, VX_RIGHT_READ | VX_RIGHT_MAP | VX_RIGHT_DUPLICATE | VX_RIGHT_TRANSFER, &h);
  return h;
}

// NEW, on the listen channel: a group, and its first member.
static void new_group(const nsd_msg *m, size_t len, uint32_t handles) {
  vx_status st = VX_ERR_NO_MEMORY;
  group *g = nullptr;
  for (uint32_t i = 0; i < MAX_GROUPS && !g; i++)
    if (!groups[i].used) g = &groups[i];
  vx_str text = {(const char *)(m + 1), m->a.text_len};
  vx_str names = {text.ptr + text.len, len - sizeof *m - text.len};
  uint64_t va = 0;
  size_t size = (sizeof(nsd_page) + 4095) & ~4095ull;
  if (m->a.text_len > NSD_TEXT_MAX || m->a.text_len > len - sizeof *m || m->a.count != handles) {
    st = VX_ERR_INVALID;
  } else if (g) {
    *g = (group){.used = true};
    st = vx_vmo_create(size, 0, &g->vmo);
    if (st == VX_OK) st = vx_as_map(vx_self, g->vmo, 0, size, VX_MAP_WRITE, &va);
    if (st == VX_OK) {
      g->page = (nsd_page *)va;
      st = add_connectors(g, names, msg_handles, handles) ? VX_OK : VX_ERR_INVALID;
      if (st == VX_OK) handles = 0; // add_connectors took them; else they are closed below
    }
  }
  vx_handle give[2] = {};
  if (st == VX_OK) {
    publish(g, text);
    give[0] = add_member(g);
    give[1] = page_for(g);
    for (uint32_t i = 0; i < MAX_MEMBERS; i++) // the member just made is the caller
      if (members[i].used && members[i].g == g) members[i].task = m->a.task;
    if (!give[0] || !give[1]) {
      st = VX_ERR_NO_MEMORY;
      for (int i = 0; i < 2; i++)
        if (give[i]) vx_handle_close(give[i]); // the reply gives none
    }
  }
  for (uint32_t i = 0; i < handles; i++) vx_handle_close(msg_handles[i]);
  if (st != VX_OK && g) {
    for (uint32_t i = 0; i < MAX_MEMBERS; i++)
      if (members[i].used && members[i].g == g) drop_member(&members[i]);
    if (g->used) forget_group(g);
  }
  reply(listen_ch, m->h.txid, st, st == VX_OK ? g->page->seq : 0, (vx_str){}, give, st == VX_OK ? 2 : 0);
}

// TEXT, on the listen channel: the namespace of the group a task is in.
static void text_of(const nsd_msg *m) {
  for (uint32_t i = 0; i < MAX_MEMBERS; i++) {
    const member *x = &members[i];
    if (!x->used || x->task != m->a.task) continue;
    reply(listen_ch, m->h.txid, VX_OK, x->g->page->seq, (vx_str){x->g->page->text, x->g->page->len}, nullptr,
          0);
    return;
  }
  reply(listen_ch, m->h.txid, VX_ERR_NOT_FOUND, 0, (vx_str){}, nullptr, 0);
}

// A call on a member's channel.
static void member_call(member *x, const nsd_msg *m, size_t len, uint32_t handles) {
  group *g = x->g;
  vx_status st = VX_OK;
  vx_handle give = VX_HANDLE_NONE;
  vx_str text = {(const char *)(m + 1), m->a.text_len};
  bool bad = m->a.text_len > len - sizeof *m;
  switch (m->h.ordinal) {
  case NSD_SHARE:
    give = add_member(g);
    st = give ? VX_OK : VX_ERR_NO_MEMORY;
    break;
  case NSD_HELLO:
    x->task = m->a.task;
    give = page_for(g);
    st = give ? VX_OK : VX_ERR_NO_MEMORY;
    break;
  case NSD_UPDATE: {
    vx_str names = {text.ptr + text.len, len - sizeof *m - text.len};
    if (bad || m->a.text_len > NSD_TEXT_MAX || m->a.count != handles)
      st = VX_ERR_INVALID;
    else if (m->a.seq != g->page->seq)
      st = VX_ERR_BAD_STATE; // stale: another member changed the group first
    else if (!add_connectors(g, names, msg_handles, handles))
      st = VX_ERR_NO_MEMORY;
    if (st == VX_OK) {
      handles = 0;
      publish(g, text);
    }
    break;
  }
  case NSD_CONNECTOR: {
    st = bad ? VX_ERR_INVALID : VX_ERR_NOT_FOUND;
    for (uint32_t k = 0; k < MAX_CONNECTORS && st == VX_ERR_NOT_FOUND; k++)
      if (g->conns[k].len && str_eq((vx_str){g->conns[k].src, g->conns[k].len}, text))
        st = vx_handle_dup(g->conns[k].connector, VX_RIGHTS_SAME, &give);
    break;
  }
  default: st = VX_ERR_INVALID; break;
  }
  for (uint32_t i = 0; i < handles; i++) vx_handle_close(msg_handles[i]);
  reply(x->chan, m->h.txid, st, g->page->seq, (vx_str){}, &give, give ? 1 : 0);
}

// Reads every message waiting on ch; x is its member, or null for the listen channel.
static void drain(vx_handle ch, member *x) {
  for (;;) {
    vx_msg_size size;
    vx_status st = vx_channel_read(ch, msg_buf, sizeof msg_buf, msg_handles, VX_CHANNEL_MAX_HANDLES, &size);
    if (st != VX_OK) return; // empty, or gone (PEER_CLOSED says so)
    const nsd_msg *m = (const nsd_msg *)msg_buf;
    if (size.bytes < sizeof *m) {
      for (uint32_t i = 0; i < size.handles; i++) vx_handle_close(msg_handles[i]);
      continue;
    }
    if (x)
      member_call(x, m, size.bytes, size.handles);
    else if (m->h.ordinal == NSD_NEW)
      new_group(m, size.bytes, size.handles);
    else if (m->h.ordinal == NSD_TEXT)
      text_of(m);
    else
      reply(listen_ch, m->h.txid, VX_ERR_INVALID, 0, (vx_str){}, nullptr, 0);
    if (x && !x->used) return; // a NEW's failure can drop members, but never the caller's
  }
}

const char *vx_main(void) {
  listen_ch = vx_spawn_take("listen");
  if (!listen_ch || vx_port_create(0, &port) != VX_OK) {
    vx_print(VX_STR("nsd: no listen channel\n"));
    return "no listen channel";
  }
  vx_port_bind(port, listen_ch, VX_TRIGGER_READABLE, KEY_LISTEN, 0);
  vx_print(VX_STR("nsd: serving /srv/nsd\n"));
  for (;;) {
    vx_packet pk[16];
    int64_t n = vx_port_wait(port, VX_INFINITE, 0, pk, 16);
    for (int64_t i = 0; i < n; i++) {
      uint64_t kind = pk[i].key & 0xff;
      if (kind == KEY_LISTEN) {
        drain(listen_ch, nullptr);
        vx_port_bind(port, listen_ch, VX_TRIGGER_READABLE, KEY_LISTEN, 0);
        continue;
      }
      uint32_t slot = (uint32_t)(pk[i].key >> 8 & 0xff'ffff), gen = (uint32_t)(pk[i].key >> 32);
      member *x = slot < MAX_MEMBERS ? &members[slot] : nullptr;
      if (!x || !x->used || x->gen != gen) continue; // an earlier member's
      if (kind == KEY_CLOSED) {
        drain(x->chan, x); // what it sent before it went
        if (x->used) drop_member(x);
      } else {
        drain(x->chan, x);
        if (x->used) vx_port_bind(port, x->chan, VX_TRIGGER_READABLE, member_key(KEY_READABLE, x), 0);
      }
    }
  }
}
