// vx-rt's program-level calls as 09 has them (§5.1, §5.7; ADR-0004 libvx
// v0, M6 step 6e4c3): the arguments as slices, and threads that end with an
// exit string. Included by rt.c, after heap.c and arena.c.

#pragma once

#include "arena.c"
#include "base.c"
#include "heap.c"
#include "thread.c"

// --- The arguments (09 §5.1) ---
//
// The program's name (argv0=, else spawn=) and its arguments, made once at
// start-up from the spawn message, before vx_main or any constructor.

static vx_str vx_args_list[VX_SPAWN_MAX_ARGS + 1];
static size_t vx_args_count;

static void vx_args_make(void) {
  vx_args_list[0] = vx_spawn.argv0.len ? vx_spawn.argv0 : vx_spawn.name;
  for (uint32_t i = 0; i < vx_spawn.argc; i++) vx_args_list[i + 1] = vx_spawn.args[i];
  vx_args_count = vx_spawn.argc + 1;
}

VX_API vx_strs vx_args(void) { return (vx_strs){vx_args_list, vx_args_count}; }

// Argument i (0, the program's name), or the zero slice past the last.
VX_API vx_str vx_arg(size_t i) { return i < vx_args_count ? vx_args_list[i] : (vx_str){}; }

// The first thread's intent, from the spawn message's intent= (a spawning
// program's vx_spawn_req.intent): none leaves it interactive.
static void vx_intent_from_spawn(void) {
  vx_ndb_record rec;
  uint64_t intent;
  if (vx_spawn_record("intent", &rec) && vx_ndb_get_u64(&rec, "intent", &intent) && intent &&
      intent != VX_INTENT_INTERACTIVE)
    vx_intent_set((uint32_t)intent);
}

// --- Threads (09 §5.7) ---
//
// A worker (thread.c) in a record on the process heap, which keeps its
// intent and, once it ends, its exit string, cut at a rune to VX_ERRMAX.

struct vx_thread {
  vx_worker w;
  const char *(*fn)(void *);
  void *arg;
  uint32_t intent;
  size_t exit_len;
  char exit[VX_ERRMAX];
};

static void vx_thread_body(void *p) {
  vx_thread *t = p;
  if (t->intent && t->intent != VX_INTENT_INTERACTIVE) vx_intent_set(t->intent);
  const char *e = t->fn(t->arg);
  if (e && *e) {
    vx_str s = vx_cstr(e);
    t->exit_len = vx_utf_cut(s.ptr, s.len, VX_ERRMAX);
    memcpy(t->exit, s.ptr, t->exit_len);
  }
}

VX_API vx_thread *vx_thread_spawn(const char *(*fn)(void *), void *arg, uint32_t intent, size_t stack) {
  vx_thread *t = vx_heap_alloc(vx_heap_process(), sizeof *t);
  if (!t) {
    vx_err_set(VX_STR("thread: no memory for its record"));
    return nullptr;
  }
  *t = (vx_thread){.fn = fn, .arg = arg, .intent = intent};
  if (vx_worker_start(&t->w, vx_thread_body, t, stack) != VX_OK) {
    vx_heap_free(vx_heap_process(), t);
    vx_err_set(VX_STR("thread: cannot make its stack or start it"));
    return nullptr;
  }
  return t;
}

// Copies an exit string into a for a caller: "" is the zero-length slice.
[[maybe_unused]] static vx_status vx_exit_copy(vx_arena *a, const char *text, size_t len, vx_str *exit) {
  if (!exit) return VX_OK;
  *exit = VX_STR("");
  if (!len) return VX_OK;
  char *p = vx_push(a, len + 1, 1);
  if (!p) return VX_ERR_NO_MEMORY;
  memcpy(p, text, len);
  *exit = (vx_str){p, len};
  return VX_OK;
}

VX_API vx_status vx_thread_join(vx_thread *t, vx_arena *a, vx_str *exit) {
  if (!t) return VX_ERR_INVALID;
  vx_worker_join(&t->w);
  vx_status st = vx_exit_copy(a, t->exit, t->exit_len, exit);
  vx_heap_free(vx_heap_process(), t);
  return st;
}
