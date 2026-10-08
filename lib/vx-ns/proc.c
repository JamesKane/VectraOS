// vx-ns's process calls as 09 has them (§5.1, §5.8; ADR-0004 libvx v0, M6
// step 6e4c3): the environment read from /env, and programs spawned, run in
// place, waited for and sent notes, all through the process's namespace
// (vx_ns_process, under its lock). A program that has these includes this
// file; libvx has it.

#pragma once

#include "../vx-rt/spawn.c"
#include "spawn.c"

// --- The environment (09 §5.1, ADR-0044) ---

// The bytes of /env/NAME into buf (at most cap), or -1 if /env has no such
// variable, -2 if there is no /env; under vx_ns_proc_lock.
[[maybe_unused]] static int64_t vx_env_read(vx_str name, char *buf, uint32_t cap) {
  char path[80] = "/env/";
  if (name.len > sizeof path - 6) return -1;
  memcpy(path + 5, name.ptr, name.len);
  vx_ns *ns = vx_ns_process();
  vx_ns_file f;
  vx_status st = vx_ns_open(ns, (vx_str){path, 5 + name.len}, P9_OREAD, &f);
  if (st != VX_OK) {
    p9_client *c = nullptr;
    uint32_t fid = 0;
    bool env = vx_ns_walk(ns, VX_STR("/env"), &c, &fid) == VX_OK;
    if (env) p9c_clunk(c, fid);
    return env ? -1 : -2;
  }
  int64_t n = 0;
  while (n < cap) {
    int64_t got = vx_ns_read(&f, buf + n, cap - (uint32_t)n);
    if (got <= 0) break;
    n += got;
  }
  vx_ns_close(&f);
  return n;
}

// A variable's value (09 §5.1): /env/NAME as Plan 9's getenv reads it, an
// rc list's words joined by spaces; without /env, what the spawn message gave
// (env=). Copied into a; the zero slice if it is not set (or a is full).
VX_API vx_str vx_env_get(vx_str name, vx_arena *a) {
  static constexpr uint32_t CAP = 16 * 1024;
  vx_arena *tmp = vx_scratch(&a, 1);
  vx_mark m = vx_arena_mark(tmp);
  char *buf = vx_push(tmp, CAP, 1);
  bool bad = !name.len;
  for (size_t i = 0; i < name.len; i++) bad = bad || name.ptr[i] == '/';
  vx_str v = {};
  if (buf && !bad) {
    vx_lock(&vx_ns_proc_lock);
    int64_t n = vx_env_read(name, buf, CAP);
    vx_unlock(&vx_ns_proc_lock);
    if (n >= 0) v = (vx_str){buf, (size_t)n};
    if (n == -2) v = vx_getenv(name);
  }
  vx_str out = {};
  char *p = v.ptr ? vx_push(a, v.len + 1, 1) : nullptr;
  if (p) {
    memcpy(p, v.ptr, v.len);
    while (v.len && !p[v.len - 1]) v.len--; // an rc list's words each end in NUL
    for (size_t i = 0; i < v.len; i++)
      if (!p[i]) p[i] = ' ';
    p[v.len] = 0;
    out = (vx_str){p, v.len};
  }
  vx_arena_pop(tmp, m);
  return out;
}

// Sets a variable (Plan 9's putenv): /env/NAME made or emptied, then value
// written; seen by every process of the environment group (ADR-0044).
VX_API vx_status vx_env_set(vx_str name, vx_str value) {
  char path[80] = "/env/";
  bool bad = !name.len || name.len > sizeof path - 6 || value.len > UINT32_MAX;
  for (size_t i = 0; i < name.len && !bad; i++) bad = name.ptr[i] == '/';
  if (bad) return VX_ERR_INVALID;
  memcpy(path + 5, name.ptr, name.len);
  vx_lock(&vx_ns_proc_lock);
  vx_ns_file f;
  vx_status st = vx_ns_create(vx_ns_process(), (vx_str){path, 5 + name.len}, 0664, P9_OWRITE | P9_OTRUNC, &f);
  if (st == VX_OK) {
    int64_t w = value.len ? vx_ns_write(&f, value.ptr, (uint32_t)value.len) : 0;
    if (w >= 0 && (size_t)w != value.len) w = VX_ERR_IO;
    if (w < 0) st = (vx_status)w;
    vx_ns_close(&f);
  }
  vx_unlock(&vx_ns_proc_lock);
  return st;
}

// --- Processes (09 §5.8) ---

static constexpr size_t VX_PROC_IMAGE_MAX =
    224ull << 20; // a program's image, read whole: with the rest, under a VMO's 256 MiB
static constexpr size_t VX_PROC_INTERP_MAX = 16ull << 20; // and its interpreter's

static vx_status vx_proc_registered(void *ctx, uint64_t pid) {
  *(uint64_t *)ctx = pid;
  return VX_OK;
}

// One of the caller's handles for the child under name, unless the request
// gives one of that name.
static void vx_proc_give(const vx_spawn_req *r, vx_handle h, const char *name, vx_handle *handles,
                         vx_str *names, uint32_t *count, uint32_t max) {
  vx_str n = vx_cstr(name);
  for (size_t i = 0; i < r->nhandles; i++)
    if (r->handle_names && vx_str_eq(r->handle_names[i], n)) return;
  if (h && *count < max && vx_handle_dup(h, VX_RIGHTS_SAME, &handles[*count]) == VX_OK) names[(*count)++] = n;
}

// Spawns, or with exec runs in the caller's place, the program r names.
static vx_status vx_proc_start(const vx_spawn_req *r, bool exec, vx_proc *out) {
  if (out) *out = (vx_proc){};
  vx_handle handles[VX_CHANNEL_MAX_HANDLES - 1];
  vx_str names[VX_CHANNEL_MAX_HANDLES - 1];
  uint32_t count = 0, max = VX_CHANNEL_MAX_HANDLES - 1;
  vx_status st = VX_OK;
  if (r->ns.len) st = VX_ERR_UNSUPPORTED; // a namespace(6) template: a later step (gap)
  if (r->nhandles > max - 3) st = VX_ERR_RANGE;
  for (size_t i = 0; i < r->nhandles; i++) { // they leave the caller, whatever happens
    if (st == VX_OK) {
      handles[count] = r->handles[i];
      names[count++] = r->handle_names ? r->handle_names[i] : VX_STR("handle");
    } else {
      vx_handle_close(r->handles[i]);
    }
  }
  if (st != VX_OK) {
    for (uint32_t i = 0; i < count; i++) vx_handle_close(handles[i]);
    return st;
  }
  vx_proc_give(r, vx_stdio.out, "stdout", handles, names, &count, max);
  vx_proc_give(r, vx_stdio.err, "stderr", handles, names, &count, max);
  vx_proc_give(r, vx_console.connector, "console", handles, names, &count, max);

  // The image, its interpreter and the records, in an arena of their own:
  // lazy memory, given back whole when the spawn is done.
  vx_arena *a = vx_arena_new(VX_PROC_IMAGE_MAX + VX_PROC_INTERP_MAX + (1 << 20));
  uint8_t *image = vx_push(a, VX_PROC_IMAGE_MAX, 4096);
  uint8_t *interp = vx_push(a, VX_PROC_INTERP_MAX, 4096);
  char *records = vx_push(a, VX_CHANNEL_MAX_BYTES - 4096, 1); // room left for spawn's own records
  size_t size = 0, interp_size = 0;
  if (!image || !interp || !records) st = VX_ERR_NO_MEMORY;
  vx_ndb_writer rec = {.buf = records, .cap = VX_CHANNEL_MAX_BYTES - 4096};
  vx_lock(&vx_ns_proc_lock);
  vx_ns *ns = vx_ns_process();
  if (st == VX_OK) st = vx_ns_read_all(ns, r->path, image, VX_PROC_IMAGE_MAX, &size);
  if (st == VX_OK && !size) st = VX_ERR_INVALID;
  vx_str ip = {};
  if (st == VX_OK && vx_elf_interp(image, size, &ip))
    st = vx_ns_read_all(ns, ip, interp, VX_PROC_INTERP_MAX, &interp_size);
  vx_str base = r->path; // the task's name: the program's, without its directory
  for (size_t i = base.len; i-- > 0;)
    if (base.ptr[i] == '/') base = (vx_str){base.ptr + i + 1, base.len - i - 1};
  if (st == VX_OK && r->args.len > VX_SPAWN_MAX_ARGS + 1) st = VX_ERR_RANGE;
  if (st == VX_OK && r->args.len && !vx_str_eq(r->args.ptr[0], base)) {
    vx_ndb_put(&rec, "argv0", r->args.ptr[0]);
    vx_ndb_end(&rec);
  }
  for (size_t i = 1; st == VX_OK && i < r->args.len; i++) {
    vx_ndb_put(&rec, "arg", r->args.ptr[i]);
    vx_ndb_end(&rec);
  }
  if (st == VX_OK && r->intent) {
    vx_ndb_put_u64(&rec, "intent", r->intent);
    vx_ndb_end(&rec);
  }
  if (st == VX_OK && rec.failed) st = VX_ERR_RANGE;
  if (st == VX_OK) st = vx_ns_spawn_records(ns, &rec, handles, names, &count, max - 1);
  vx_handle proc = vx_ns_connector(ns, VX_STR("/proc"));
  vx_unlock(&vx_ns_proc_lock);
  if (st != VX_OK) {
    for (uint32_t i = 0; i < count; i++) vx_handle_close(handles[i]);
    vx_arena_free(a);
    return st;
  }
  uint64_t pid = 0;
  vx_handle task = VX_HANDLE_NONE;
  vx_spawn_args sa = {.name = {base.ptr, vx_utf_cut(base.ptr, base.len, 23)}, // whole runes (ADR-0013)
                      .path = r->path,
                      .image = image,
                      .image_size = size,
                      .interp = interp_size ? interp : nullptr,
                      .interp_size = interp_size,
                      .handles = handles,
                      .handle_names = names,
                      .handle_count = count,
                      .records = {records, rec.len},
                      .proc = proc,
                      // The caller has the task and watches it itself: no wait record.
                      .proc_flags = PROC_NOWAIT | (r->flags & VX_PROC_NEWGROUP ? PROC_NOTEG : 0),
                      .registered = vx_proc_registered,
                      .ctx = &pid,
                      .exec = exec};
  st = vx_spawn_elf(&sa, &task);
  vx_arena_free(a);
  if (st != VX_OK) return st;
  if (!pid) { // no procfs: the kernel's id
    vx_task_summary s;
    if (vx_task_info(task, &s) == VX_OK) pid = s.id;
  }
  if (out) *out = (vx_proc){.task = task, .pid = pid};
  return VX_OK;
}

VX_API vx_status vx_proc_spawn(const vx_spawn_req *r, vx_proc *out) { return vx_proc_start(r, false, out); }

// Runs the program in the caller's place (ADR-0012); returns only on failure.
VX_API vx_status vx_proc_exec(const vx_spawn_req *r) { return vx_proc_start(r, true, nullptr); }

VX_API vx_status vx_proc_wait(vx_proc p, vx_instant deadline, vx_arena *a, vx_str *exit) {
  vx_task_summary s;
  vx_status st = vx_task_info(p.task, &s);
  if (st == VX_OK && s.state != VX_TASK_EXITED) {
    vx_handle port;
    st = vx_port_create(0, &port);
    if (st == VX_OK) st = vx_port_bind(port, p.task, VX_TRIGGER_EXIT, 0, 0);
    vx_packet pk;
    int64_t n = st == VX_OK ? vx_port_wait(port, deadline, 0, &pk, 1) : 0;
    if (st == VX_OK && n < 0) st = (vx_status)n;
    if (port) vx_handle_close(port);
    if (st == VX_OK) st = vx_task_info(p.task, &s);
  }
  if (st != VX_OK) return st;
  return vx_exit_copy(a, s.exit, s.exit_len < VX_ERRMAX ? s.exit_len : VX_ERRMAX, exit);
}

VX_API void vx_proc_close(vx_proc p) {
  if (p.task) vx_handle_close(p.task);
}

// Writes note to /proc/N/note (ADR-0010), as Plan 9's postnote does.
VX_API vx_status vx_postnote(vx_proc p, vx_str note) {
  if (!note.len || note.len > VX_ERRMAX) return VX_ERR_INVALID;
  char path[40];
  size_t n = vx_bfmt((vx_bytes){(uint8_t *)path, sizeof path}, "/proc/%llu/note", (unsigned long long)p.pid);
  vx_lock(&vx_ns_proc_lock);
  vx_ns_file f;
  vx_status st = vx_ns_open(vx_ns_process(), (vx_str){path, n}, P9_OWRITE, &f);
  if (st == VX_OK) {
    int64_t w = vx_ns_write(&f, note.ptr, (uint32_t)note.len);
    if (w < 0) st = (vx_status)w;
    vx_ns_close(&f);
  }
  vx_unlock(&vx_ns_proc_lock);
  return st;
}
