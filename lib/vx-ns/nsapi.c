// vx-ns's namespace calls as 09 has them (§5.9; ADR-0004 libvx v0): bind,
// mount, unmount and a new namespace, on the process's namespace
// (vx_ns_process), under its lock. A change reaches the process's namespace
// group as every change of vx-ns's does (ADR-0009).

#pragma once

#include "../../abi/vx/ns.h"
#include "file.c"
#include "relay.c"

static vx_status vx_ns_api_fail(const char *what, vx_str path, vx_status st) {
  return st == VX_OK ? VX_OK : vx_file_fail(what, path, st);
}

VX_API vx_status vx_bind(vx_str new_path, vx_str old, uint32_t flags) {
  vx_lock(&vx_ns_proc_lock);
  vx_status st = vx_ns_bind(vx_ns_process(), new_path, old, (uint8_t)flags);
  vx_unlock(&vx_ns_proc_lock);
  return vx_ns_api_fail("bind", new_path, st);
}

// A post, which this namespace or srvfs has, or an address through a relay,
// as rc's mount takes them.
static vx_status vx_ns_api_mount(vx_ns *ns, vx_str srv, vx_str spec, vx_str at, uint8_t flags) {
  if (srv.len > 5 && memcmp(srv.ptr, "/srv/", 5) == 0) return vx_ns_mount_post(ns, srv, spec, at, flags);
  return vx_ns_mount_addr(ns, srv, spec, at, flags);
}

VX_API vx_status vx_mount(vx_str srv, vx_str spec, vx_str at, uint32_t flags) {
  vx_lock(&vx_ns_proc_lock);
  vx_status st = vx_ns_api_mount(vx_ns_process(), srv, spec, at, (uint8_t)flags);
  vx_unlock(&vx_ns_proc_lock);
  return vx_ns_api_fail("mount", srv, st);
}

VX_API vx_status vx_unmount(vx_str from, vx_str at) {
  vx_lock(&vx_ns_proc_lock);
  vx_status st = vx_ns_unmount(vx_ns_process(), from, at);
  vx_unlock(&vx_ns_proc_lock);
  return vx_ns_api_fail("unmount", at, st);
}

// $NAME in a template: the environment's.
static vx_str vx_ns_api_var(void *ctx, vx_str name) {
  vx_arena *a = ctx;
  vx_str v = vx_env_get(name, a);
  return v.ptr ? v : VX_STR("");
}

VX_API vx_status vx_newns(vx_str tmpl) {
  char path[VX_NS_MAX_PATH];
  vx_str file = tmpl;
  if (!tmpl.len || tmpl.ptr[0] != '/') { // a name: /lib/ns/NAME
    size_t n = vx_bfmt((vx_bytes){(uint8_t *)path, sizeof path}, "/lib/ns/%.*s", VX_FMT(tmpl));
    file = (vx_str){path, n};
  }
  vx_arena *a = vx_scratch(nullptr, 0);
  vx_mark m = vx_arena_mark(a);
  static constexpr size_t CAP = 64 * 1024;
  char *text = vx_push(a, CAP, 1);
  size_t len = 0;
  vx_status st = text ? VX_OK : VX_ERR_NO_MEMORY;
  vx_lock(&vx_ns_proc_lock);
  vx_ns *ns = vx_ns_process();
  if (st == VX_OK) st = vx_ns_read_all(ns, file, text, CAP, &len);
  if (st != VX_OK) {
    vx_unlock(&vx_ns_proc_lock);
    vx_arena_pop(a, m);
    return vx_ns_api_fail("newns", file, st);
  }
  // Its own namespace: out of the group, then what the template says alone.
  // The connections stay open while the table is rebuilt, so a mount of a
  // post it had finds it again (vx_ns_mount_srv).
  vx_ns_group_leave(ns);
  vx_ns_reset(ns);
  static vx_ns_script script;
  script = (vx_ns_script){.text = {text, len}, .var = vx_ns_api_var, .ctx = a};
  vx_ns_op op;
  vx_status first = VX_OK;
  while ((st = vx_ns_script_next(&script, &op)) == VX_OK) {
    vx_status e = VX_OK;
    if (op.kind == VX_NS_OP_MOUNT) {
      vx_str spec = op.argc > 2 ? op.args[2] : (vx_str){};
      e = vx_ns_mount_srv(ns, op.args[0], spec, op.args[1], op.flags);
      if (e == VX_ERR_NOT_FOUND) e = vx_ns_api_mount(ns, op.args[0], spec, op.args[1], op.flags);
    } else if (op.kind == VX_NS_OP_BIND) {
      e = vx_ns_bind(ns, op.args[0], op.args[1], op.flags);
    } else if (op.kind == VX_NS_OP_UNMOUNT) {
      e = vx_ns_unmount(ns, op.argc == 2 ? op.args[0] : (vx_str){}, op.args[op.argc - 1]);
    } else if (op.kind == VX_NS_OP_CLEAR) {
      vx_ns_reset(ns);
    } else if (op.kind == VX_NS_OP_CD) {
      e = vx_chdir(ns, op.args[0]);
    } // `. FILE` includes: a later level; the system's templates do not use them
    if (e != VX_OK && first == VX_OK) first = e;
  }
  vx_unlock(&vx_ns_proc_lock);
  vx_arena_pop(a, m);
  if (st != VX_ERR_NOT_FOUND) return vx_ns_api_fail("newns", file, st); // the template itself is bad
  return vx_ns_api_fail("newns", file, first);
}
