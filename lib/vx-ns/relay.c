// vx-ns relays and posts (M6 step 6d4d2c), as 9front shares a mounted
// channel: a 9P server over TCP is mounted through a relay (servers/relay,
// relay(4)), so every process the namespace reaches shares its one session
// rather than dialing its own, and a post in srvfs's /srv is opened for the
// connector it holds. For programs that mount by name: rc's mount, srv(1).
// A program without this file dials for itself still (dial.c).
//
// The relay is spawned with a copy of the namespace, not as a member of its
// group: its /net is the spawner's, and a mount of the relay itself, which
// the group's text soon has, is never replayed into it.

#pragma once

#include "../vx-rt/spawn.c"
#include "../vx-proc/proc.h"
#include "spawn.c"

static constexpr uint64_t VX_NS_RELAY_IMAGE_MAX = 8ull << 20;

// The program at path read into a VMO of the caller's, mapped at *va (size
// bytes of it); unmapped by the caller.
static vx_status vx_ns_read_image(vx_ns *ns, vx_str path, uint64_t *va, size_t *size) {
  vx_ns_file f;
  vx_status st = vx_ns_open(ns, path, P9_OREAD, &f);
  if (st != VX_OK) return st;
  vx_handle vmo;
  *va = 0, *size = 0;
  st = vx_vmo_create(VX_NS_RELAY_IMAGE_MAX, 0, &vmo);
  if (st == VX_OK) {
    st = vx_as_map(vx_self, vmo, 0, VX_NS_RELAY_IMAGE_MAX, VX_MAP_WRITE, va);
    vx_handle_close(vmo); // the mapping keeps it
  }
  int64_t n = 0;
  while (st == VX_OK && *size < VX_NS_RELAY_IMAGE_MAX &&
         (n = vx_ns_read(&f, (uint8_t *)*va + *size, 65536)) > 0)
    *size += (size_t)n;
  vx_ns_close(&f);
  if (st == VX_OK && n < 0) st = (vx_status)n;
  if (st == VX_OK && (!*size || *size == VX_NS_RELAY_IMAGE_MAX)) st = VX_ERR_INVALID;
  if (st != VX_OK && *va) vx_as_unmap(vx_self, *va, VX_NS_RELAY_IMAGE_MAX);
  return st;
}

// A relay for addr (as dial.c spells it, tcp!HOST!PORT), connected through
// once to see that it dialed: the connection in *c, through *connector (the
// namespace's once it is mounted). It runs as long as anything holds a
// connector, in a session and note group of its own, so the spawner's
// interrupts leave it be; its own messages go to the console.
[[maybe_unused]] static vx_status vx_ns_relay(vx_ns *ns, vx_str addr, p9_client **c, vx_handle *connector) {
  uint64_t va;
  size_t size;
  vx_status st = vx_ns_read_image(ns, VX_STR("/boot/bin/relay"), &va, &size);
  if (st != VX_OK) return st;
  static char records[8 * 1024];
  vx_ndb_writer w = {.buf = records, .cap = sizeof records};
  vx_ndb_put(&w, "arg", addr);
  vx_ndb_end(&w);
  vx_handle handles[VX_CHANNEL_MAX_HANDLES - 1], ch[2] = {};
  vx_str names[VX_CHANNEL_MAX_HANDLES - 1];
  uint32_t count = 0;
  st = vx_channel_create(0, ch);
  if (st == VX_OK) st = vx_ns_copy_records(ns, &w, handles, names, &count, VX_CHANNEL_MAX_HANDLES - 4);
  if (st == VX_OK) {
    handles[count] = ch[1], names[count++] = VX_STR("listen");
    ch[1] = VX_HANDLE_NONE; // the child's, whatever happens
    if (vx_console.connector && vx_handle_dup(vx_console.connector, VX_RIGHTS_SAME, &handles[count]) == VX_OK)
      names[count++] = VX_STR("console");
    vx_spawn_args a = {.name = VX_STR("relay"),
                       .image = (const uint8_t *)va,
                       .image_size = size,
                       .handles = handles,
                       .handle_names = names,
                       .handle_count = count,
                       .records = {records, w.len},
                       .proc = vx_ns_connector(ns, VX_STR("/proc")),
                       .proc_flags = PROC_NOWAIT | PROC_SETSID};
    vx_handle task;
    st = vx_spawn_elf(&a, &task);
    if (st == VX_OK) vx_handle_close(task);
  }
  vx_as_unmap(vx_self, va, VX_NS_RELAY_IMAGE_MAX);
  if (ch[1]) vx_handle_close(ch[1]);
  *c = st == VX_OK ? vx_ns_connect_handle(ch[0], &st) : nullptr; // fails if it could not dial: it has gone
  if (*c) {
    *connector = ch[0];
    return VX_OK;
  }
  if (ch[0]) vx_handle_close(ch[0]);
  return st == VX_OK ? VX_ERR_PEER_CLOSED : st;
}

// The connector of a post in srvfs's /srv, by its path there (/srv/NAME).
[[maybe_unused]] static vx_status vx_ns_open_post(vx_ns *ns, vx_str path, vx_handle *connector) {
  p9_client *c;
  uint32_t fid;
  *connector = VX_HANDLE_NONE;
  vx_status st = vx_ns_walk(ns, path, &c, &fid);
  if (st != VX_OK) return st;
  st = p9c_open_handle(c, fid, P9_ORDWR, connector);
  p9c_clunk(c, fid);
  if (st == VX_OK && !*connector) st = VX_ERR_INVALID; // a file with no connector: not a post
  return st;
}

// Mounts, at old, through a connector: its connection made, and the
// connector the namespace's if the mount is made.
static vx_status vx_ns_mount_connector(vx_ns *ns, vx_handle connector, vx_str src, vx_str aname, vx_str old,
                                       uint8_t flags) {
  vx_status st;
  p9_client *c = vx_ns_connect_handle(connector, &st);
  if (!c) {
    vx_handle_close(connector);
    return st;
  }
  return vx_ns_mount(ns, c, connector, src, aname, old, flags);
}

// Mounts the post /srv/NAME at old: through a connection this namespace has
// from it already, or the connector srvfs gives for it (made at run time,
// by srv(1), say).
[[maybe_unused]] static vx_status vx_ns_mount_post(vx_ns *ns, vx_str src, vx_str aname, vx_str old,
                                                   uint8_t flags) {
  vx_status st = vx_ns_mount_srv(ns, src, aname, old, flags);
  if (st != VX_ERR_NOT_FOUND) return st;
  vx_handle connector;
  st = vx_ns_open_post(ns, src, &connector);
  if (st != VX_OK) return st;
  return vx_ns_mount_connector(ns, connector, src, aname, old, flags);
}

// Mounts the 9P server at addr (tcp!HOST!PORT, 9p://HOST:PORT) at old,
// through a relay: the one this namespace, or its group, has for it
// already, or a new one.
[[maybe_unused]] static vx_status vx_ns_mount_addr(vx_ns *ns, vx_str addr, vx_str aname, vx_str old,
                                                   uint8_t flags) {
  char want[VX_NS_MAX_SRC];
  size_t n = dial_address(addr, want, sizeof want);
  if (!n) return VX_ERR_INVALID;
  vx_str src = {want, n};
  vx_status st = vx_ns_mount_srv(ns, src, aname, old, flags);
  if (st != VX_ERR_NOT_FOUND) return st;
  if (vx_ns_group.chan) { // a member's relay, given to nsd with its mount
    nsd_msg rep;
    vx_handle connector = VX_HANDLE_NONE;
    if (vx_ns_nsd(vx_ns_group.chan, NSD_CONNECTOR, (nsd_args){}, src, (vx_str){}, nullptr, 0, &rep,
                  &connector, 1) == VX_OK)
      return vx_ns_mount_connector(ns, connector, src, aname, old, flags);
  }
  p9_client *c;
  vx_handle connector;
  st = vx_ns_relay(ns, src, &c, &connector);
  if (st != VX_OK) return st;
  return vx_ns_mount(ns, c, connector, src, aname, old, flags);
}
