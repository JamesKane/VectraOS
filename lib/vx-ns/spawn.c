// vx-ns at start-up: builds a process's namespace from its spawn message
// (abi.h), whose mount= and bind= records are what its parent's template made
// (02 §2). A mount record names a connector handle in the message; each one
// gets its own ring connection to the server behind it.

#pragma once

#include "../vx-9p/ring.c"
#include "ns.c"

static p9_conn vx_ns_conns[VX_NS_MAX_CONNS];

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

// Replays the spawn message's namespace records in order. Stops at the first
// that fails, and says which.
[[maybe_unused]] static vx_status vx_ns_from_spawn(vx_ns *ns) {
  static char scratch[VX_CHANNEL_MAX_BYTES];
  vx_ndb_reader r = {.src = vx_spawn.text, .scratch = scratch, .scratch_cap = sizeof scratch};
  vx_ndb_record rec;
  uint32_t used = 0;
  while (vx_ndb_next(&r, &rec) == VX_NDB_RECORD) {
    bool mount = vx_ndb_has(&rec, "mount");
    if (!mount && !vx_ndb_has(&rec, "bind")) continue;
    uint8_t flags = vx_ns_flags(vx_ndb_get(&rec, "flags"));
    vx_status st = flags == 0xff ? VX_ERR_INVALID : VX_OK;
    if (st == VX_OK && mount) {
      vx_str name = vx_ndb_get(&rec, "handle");
      char cname[64] = {};
      if (name.len < sizeof cname) memcpy(cname, name.ptr, name.len);
      vx_handle connector = vx_spawn_take(cname);
      if (!connector || used == VX_NS_MAX_CONNS) st = VX_ERR_NOT_FOUND;
      if (st == VX_OK) st = p9_ring_connect(connector, &vx_ns_conns[used]);
      if (st == VX_OK)
        st = vx_ns_mount(ns, &vx_ns_conns[used].c, connector, vx_ndb_get(&rec, "src"),
                         vx_ndb_get(&rec, "aname"), vx_ndb_get(&rec, "mount"), flags);
      if (st == VX_OK) {
        used++;
      } else {
        if (used < VX_NS_MAX_CONNS && vx_ns_conns[used].end) p9_ring_disconnect(&vx_ns_conns[used]);
        if (connector) vx_handle_close(connector);
      }
    } else if (st == VX_OK) {
      st = vx_ns_bind(ns, vx_ndb_get(&rec, "new"), vx_ndb_get(&rec, "bind"), flags);
    }
    if (st != VX_OK) {
      vx_print(VX_STR("vx-ns: cannot replay the record on line "));
      vx_print_u64(rec.line);
      vx_print(VX_STR(" of the spawn message\n"));
      return st;
    }
  }
  return VX_OK;
}
