// crt1: vx-rt's start file (M6 step 6e2a, os-requirements R1-R5): where the
// kernel enters a native program, and how it ends. rt.c includes it, as a
// first-party program's unity build has it; the native target's toolchain
// (6e2b) links the same code as its crt1.o.
//
//   - _start, with the bootstrap channel, or a dynamic program's with the
//     loader's handover (ADR-0047: the spawn message as read, the loaded
//     objects): vx_start reads or takes the spawn message,
//     seeds the process's random generator from its entropy= (vx_random,
//     which also gives each child a seed), and makes the stack protector's
//     guard from it, per process;
//   - .preinit_array and .init_array walked before vx_main, .fini_array
//     after it, in reverse, by vx-rt itself (first-party programs link no C
//     library: ADR-0033 §4); a dynamic program's libraries' before its own,
//     dependencies first, and after it, in reverse;
//   - vx_argc and vx_argv, a C argv made once from the spawn message's
//     slices, NUL-terminated;
//   - vx_exit(n): the empty exit string for 0, n in decimal otherwise, as the
//     POSIX personality's (decided 2026-10-05), after .fini_array;
//   - vx_abort: standard error flushed, then a trap, which ends the task as
//     a fault does, so procfs writes a crash directory (05 §5).

#pragma once

#include "rt.h" // and vx-mem's mem.c before it, which has no guard: rt.c includes it once
#include "base.c"
#include "stdio.c"
#include "note.c"
#include "thread.c"
#include "../vx-rand/drbg.c"

// The guard compiled code checks its frames against: a constant until
// vx_start draws a random one, before vx_main or any constructor runs.
uintptr_t __stack_chk_guard = 0x2e0f5b3c9d81a647;

// A smashed stack ends the task: the trap is reported by the kernel.
[[noreturn]] void __stack_chk_fail(void) { __builtin_trap(); }

// The linker's bounds of the constructor and destructor arrays (lld defines
// them for a static link); weak, so a program with none still links.
[[gnu::weak, gnu::visibility("hidden")]] extern void (*const __preinit_array_start[])(void);
[[gnu::weak, gnu::visibility("hidden")]] extern void (*const __preinit_array_end[])(void);
[[gnu::weak, gnu::visibility("hidden")]] extern void (*const __init_array_start[])(void);
[[gnu::weak, gnu::visibility("hidden")]] extern void (*const __init_array_end[])(void);
[[gnu::weak, gnu::visibility("hidden")]] extern void (*const __fini_array_start[])(void);
[[gnu::weak, gnu::visibility("hidden")]] extern void (*const __fini_array_end[])(void);

// The process's random generator: seeded from its spawn message's entropy=
// (svcd's, or its parent's vx_random), its task id and the clock mixed in.
static vx_drbg vx_random;

// n random bytes into out, from the process's generator.
VX_API void vx_random_bytes(void *out, size_t n) { vx_drbg_read(&vx_random, out, n); }

static void vx_random_seed(void) {
  vx_ndb_record rec;
  vx_str seed = vx_spawn_record("entropy", &rec) ? vx_ndb_get(&rec, "entropy") : (vx_str){};
  vx_task_summary me = {};
  vx_task_info(vx_self, &me);
  vx_instant now = vx_clock_read();
  vx_drbg_mix(&vx_random, seed.ptr, seed.len, true);
  vx_drbg_mix(&vx_random, &me.id, sizeof me.id, false); // two children of one seed go apart
  vx_drbg_mix(&vx_random, &now, sizeof now, false);
}

// A dynamic program's loaded objects (ADR-0047), the executable first; null
// in a static program. 6f2a's unwinder and dbg read the list.
[[maybe_unused]] static const vx_dl_handover *vx_dl;

static bool vx_fini_done;

// An object's array of functions: count of them at addr.
static void vx_run_array(uint64_t addr, uint64_t count, bool reverse) {
  void (*const *fns)(void) = (void (*const *)(void))addr;
  for (uint64_t i = 0; i < count; i++) fns[reverse ? count - 1 - i : i]();
}

// .fini_array, last to first, once; then the libraries', in load order. In
// a dynamic program the program's own come from the loader's list, since
// the linker's bounds here would be libvx.so's when vx-rt is in it (6f1b1).
static void vx_run_fini(void) {
  if (vx_fini_done) return;
  vx_fini_done = true;
  if (vx_dl)
    vx_run_array(vx_dl->objects[0].fini_array, vx_dl->objects[0].fini_count, true);
  else
    for (size_t i = (size_t)(__fini_array_end - __fini_array_start); __fini_array_start && i-- > 0;)
      __fini_array_start[i]();
  for (uint32_t i = 1; vx_dl && i < vx_dl->object_count; i++)
    vx_run_array(vx_dl->objects[i].fini_array, vx_dl->objects[i].fini_count, true);
}

// Ends the program with msg as its exit string (empty: success), as Plan 9's
// exits does. What it printed goes out first, and its pipes close, so a
// reader sees the end of its input before the exit is seen.
[[noreturn]] static void vx_exit_now(vx_str msg) {
  // Held: no other thread prints over the last lines. Not for ever: a note's
  // default ends the program here, and a note can come while this thread is
  // printing, holding the lock already (the Odin port's finding).
  vx_lock_until(&vx_stdio_lock, vx_clock_read() + 100'000'000);
  if (vx_print_hook == vx_stdout_print)
    vx_stdout_flush();
  else if (vx_print_hook)
    vx_console_flush();
  vx_stderr_flush();
  if (vx_console.len) vx_console_flush();
  if (vx_stdio.out) vx_handle_close(vx_stdio.out);
  if (vx_stdio.err) vx_handle_close(vx_stdio.err);
  msg.len = vx_utf_cut(msg.ptr, msg.len, VX_ERRMAX); // whole runes (ADR-0013)
  vx_task_kill(vx_self, msg);                        // every thread: the program ends, not just this one
  vx_thread_exit();
}

// The same, after .fini_array: the program's own end, as C's exit.
[[noreturn]] static void vx_exit_str(vx_str msg) {
  vx_run_fini();
  vx_exit_now(msg);
}

// The same with a C string; nullptr is success too.
[[noreturn]] VX_API void vx_exits(const char *msg) { vx_exit_str(msg ? vx_cstr(msg) : (vx_str){}); }

// C's exit(n): the empty exit string for 0, else n in decimal, as the POSIX
// personality ends (decided 2026-10-05).
[[noreturn]] VX_API void vx_exit(int n) {
  char text[12];
  size_t len = 0;
  uint32_t v = n < 0 ? (uint32_t)-(int64_t)n : (uint32_t)n;
  char digits[11];
  size_t k = 0;
  do digits[k++] = (char)('0' + v % 10);
  while (v /= 10);
  if (n < 0) text[len++] = '-';
  while (k) text[len++] = digits[--k];
  vx_exit_str(n ? (vx_str){text, len} : (vx_str){});
}

// C's abort: standard error flushed, then a trap, which ends the task as a
// fault does, so procfs saves a crash directory (05 §5). No destructors.
[[noreturn]] VX_API void vx_abort(void) {
  vx_stderr_flush();
  __builtin_trap();
}

// A C argv from the spawn message's slices, made once: argv[0] the program's
// name (argv0=, else spawn=), then its arguments, and a null after.
static char *vx_argv_list[VX_SPAWN_MAX_ARGS + 2];
static char vx_argv_text[16 * 1024];
static int vx_argv_count = -1;

static void vx_argv_make(void) {
  size_t used = 0;
  vx_argv_count = 0;
  for (uint32_t i = 0; i <= vx_spawn.argc; i++) {
    vx_str a = vx_spawn.argv0.len ? vx_spawn.argv0 : vx_spawn.name;
    if (i) a = vx_spawn.args[i - 1];
    if (used + a.len + 1 > sizeof vx_argv_text) break; // more than fits: cut here, never mid-word
    memcpy(vx_argv_text + used, a.ptr, a.len);
    vx_argv_text[used + a.len] = 0;
    vx_argv_list[vx_argv_count++] = vx_argv_text + used;
    used += a.len + 1;
  }
  vx_argv_list[vx_argv_count] = nullptr;
}

[[maybe_unused]] static int vx_argc(void) {
  if (vx_argv_count < 0) vx_argv_make();
  return vx_argv_count;
}

[[maybe_unused]] static char **vx_argv(void) {
  if (vx_argv_count < 0) vx_argv_make();
  return vx_argv_list;
}

// Called by _start with the bootstrap channel, or in a dynamic program none
// and the loader's handover (ADR-0047; a static program's is 0). The program
// ends with vx_main's exit string.
[[noreturn]] void vx_start(vx_handle bootstrap, const vx_dl_handover *dl) {
  if (dl && (dl->magic != VX_DL_MAGIC || dl->version != VX_DL_VERSION)) {
    vx_print(VX_STR("vx-rt: the loader's handover is not a version this program knows\n"));
    vx_exit_now(VX_STR("vx-rt: unknown loader handover"));
  }
  if (dl) {
    vx_dl = dl;
    vx_spawn_from(dl->spawn, dl->spawn_bytes, dl->handles, dl->handle_count);
    vx_tls_from(dl);
  } else {
    vx_read_spawn(bootstrap);
  }
  vx_random_seed();
  // Its own guard, before any constructor or vx_main: the frames below this
  // one have returned, and this one never does, so none is checked against
  // the old value.
  uintptr_t guard = 0;
  while (!guard) vx_random_bytes(&guard, sizeof guard);
  __stack_chk_guard = guard;
  vx_thread_main_init(); // its TLS, before anything may use thread_local
  vx_args_make();
  vx_span_begin_hook = vx_prof_span_begin, vx_span_end_hook = vx_prof_span_end; // 9Px's spans (20 §5)
  vx_intent_from_spawn();
  vx_handle console = vx_spawn_take("console");
  if (console && vx_console_attach(console) != VX_OK) vx_print(VX_STR("vx-rt: cannot open the console\n"));
  vx_stdio.in = vx_spawn_take("stdin");
  vx_stdio.out = vx_spawn_take("stdout");
  vx_stdio.err = vx_spawn_take("stderr");
  vx_fds_from_spawn(); // 3 to 9 (ADR-0040)
  if (vx_stdio.out) vx_print_hook = vx_stdout_print;
  vx_note_exit = vx_exit_now; // a note the program's handler does not take ends it at once: no destructors
  for (uint32_t i = vx_dl ? vx_dl->object_count : 0; i-- > 1;) // libraries, dependencies first
    vx_run_array(vx_dl->objects[i].init_array, vx_dl->objects[i].init_count, false);
  if (vx_dl) { // the program's, from the loader's list (see vx_run_fini)
    vx_run_array(vx_dl->objects[0].init_array, vx_dl->objects[0].init_count, false);
  } else {
    for (size_t i = 0; __preinit_array_start && i < (size_t)(__preinit_array_end - __preinit_array_start);
         i++)
      __preinit_array_start[i]();
    for (size_t i = 0; __init_array_start && i < (size_t)(__init_array_end - __init_array_start); i++)
      __init_array_start[i]();
  }
  vx_exits(vx_main());
}

// The entry: the sysroot's crt1.o is this file alone (6e2b), whose libvx.a
// has the rest, built without it (VX_RT_LIBC).
#ifndef VX_RT_LIBC
#include "start.c"
#endif
