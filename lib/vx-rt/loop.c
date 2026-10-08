// vx-rt's loop (09 §4.7, §5.4; ADR-0004 libvx v0, M6 step 6e4c4): one port
// and the bookkeeping that turns its packets into events. Included by rt.c,
// after proc.c.
//
// What arrives, and how:
//   - vx_post: port_post's USER packets, the program's two words. The loop
//     never posts itself, so every USER packet is the program's.
//   - a process's end: an EXIT binding on its task, keyed by a watch slot.
//   - a thread's end: a counter the thread signals as it finishes (proc.c),
//     bound COUNTER_GE, keyed by a watch slot.
//   - notes: the process's note handler queues each one and signals the
//     loop's note counter, bound again after each packet.
//   - timers: no kernel object (port(2)); the wait's deadline is the earliest
//     timer's, and timers due are fired after it.
// A watch's key carries its slot's generation, so a packet for a watch
// already gone (vx_loop_free's cancel racing it) finds nothing.

#pragma once

#include "../../abi/vx/loop.h"
#include "arena.c"
#include "base.c"
#include "heap.c"
#include "note.c"
#include "proc.c"

static constexpr uint32_t VX_LOOP_WATCHES = 64;
static constexpr uint32_t VX_LOOP_TIMERS = 64;
static constexpr uint32_t VX_LOOP_NOTES = 16;       // queued notes not yet taken; more are dropped
static constexpr uint64_t VX_LOOP_NOTE_KEY = ~0ull; // the note counter's binding
static constexpr size_t VX_LOOP_ARENA = 1ull << 20; // a wait's exit strings and notes

typedef enum : uint8_t { VX_WATCH_FREE, VX_WATCH_PROC, VX_WATCH_THREAD } vx_loop_watch_kind;

typedef struct vx_loop_watch {
  vx_loop_watch_kind kind;
  uint32_t gen;
  uint64_t key, source;
  vx_handle object; // the task (a duplicate), or the thread's counter
  vx_thread *thread;
} vx_loop_watch;

typedef struct vx_timer_slot {
  bool live;
  uint32_t gen;
  vx_instant at;
  vx_duration leeway, every;
  uint64_t key;
} vx_timer_slot;

struct vx_loop {
  vx_handle port;
  vx_arena *arena; // what events' slices point at, emptied at each wait
  vx_loop_watch watch[VX_LOOP_WATCHES];
  vx_timer_slot timer[VX_LOOP_TIMERS];
  // Notes (vx_notes_to_loop): the handler writes at tail, the loop reads at
  // head; the counter is signalled with tail.
  vx_handle notes;
  _Atomic uint64_t note_head, note_tail;
  struct {
    uint32_t len;
    char text[VX_ERRMAX];
  } note[VX_LOOP_NOTES];
};

VX_API vx_loop *vx_loop_new(void) {
  vx_loop *l = vx_heap_alloc(vx_heap_process(), sizeof *l);
  if (!l) {
    vx_err_set(VX_STR("loop: no memory for it"));
    return nullptr;
  }
  memset(l, 0, sizeof *l);
  l->arena = vx_arena_new(VX_LOOP_ARENA);
  if (vx_arena_error(l->arena) != VX_OK || vx_port_create(0, &l->port) != VX_OK) {
    vx_arena_free(l->arena);
    vx_heap_free(vx_heap_process(), l);
    vx_err_set(VX_STR("loop: cannot make its port"));
    return nullptr;
  }
  return l;
}

static vx_loop *_Atomic vx_note_loop; // the loop notes go to, if any

VX_API void vx_loop_free(vx_loop *l) {
  if (!l) return;
  if (atomic_load(&vx_note_loop) == l) {
    vx_notify(nullptr);
    atomic_store(&vx_note_loop, nullptr);
  }
  for (uint32_t i = 0; i < VX_LOOP_WATCHES; i++) // a watched thread keeps its own handle to its counter
    if (l->watch[i].kind != VX_WATCH_FREE) vx_handle_close(l->watch[i].object);
  if (l->notes) vx_handle_close(l->notes);
  vx_handle_close(l->port); // its bindings go with it
  vx_arena_free(l->arena);
  vx_heap_free(vx_heap_process(), l);
}

VX_API vx_status vx_post(vx_loop *l, uint64_t a, uint64_t b) {
  vx_packet p = {.key = a, .value = b};
  return vx_port_post(l->port, &p);
}

// --- Timers ---

VX_API vx_timer vx_timer_at(vx_loop *l, vx_instant at, vx_duration leeway, vx_duration every, uint64_t key) {
  for (uint32_t i = 0; i < VX_LOOP_TIMERS; i++) {
    vx_timer_slot *t = &l->timer[i];
    if (t->live) continue;
    uint32_t gen = t->gen + 1;
    *t = (vx_timer_slot){.live = true, .gen = gen, .at = at, .leeway = leeway, .every = every, .key = key};
    return (vx_timer)gen << 32 | (i + 1);
  }
  vx_err_set(VX_STR("loop: no room for another timer"));
  return 0;
}

static vx_timer_slot *vx_timer_find(vx_loop *l, vx_timer id) {
  uint32_t i = (uint32_t)id;
  if (!i || i > VX_LOOP_TIMERS) return nullptr;
  vx_timer_slot *t = &l->timer[i - 1];
  return t->live && t->gen == (uint32_t)(id >> 32) ? t : nullptr;
}

VX_API void vx_timer_stop(vx_loop *l, vx_timer t) {
  vx_timer_slot *slot = vx_timer_find(l, t);
  if (slot) slot->live = false;
}

// The earliest timer's time, and the leeway it allows, if any is set.
static bool vx_timer_next(const vx_loop *l, vx_instant *at, vx_duration *leeway) {
  bool any = false;
  for (uint32_t i = 0; i < VX_LOOP_TIMERS; i++) {
    const vx_timer_slot *t = &l->timer[i];
    if (t->live && (!any || t->at < *at)) *at = t->at, *leeway = t->leeway, any = true;
  }
  return any;
}

// Timers due by now, as events, up to cap; a periodic one set for its next
// time after now (missed periods are not each delivered: late says how far).
static size_t vx_timers_fire(vx_loop *l, vx_instant now, vx_event *evs, size_t cap) {
  size_t n = 0;
  for (uint32_t i = 0; i < VX_LOOP_TIMERS && n < cap; i++) {
    vx_timer_slot *t = &l->timer[i];
    if (!t->live || t->at > now) continue;
    vx_timer id = (vx_timer)t->gen << 32 | (i + 1);
    evs[n++] = (vx_event){.kind = VX_EV_TIMER,
                          .source = id,
                          .time = now,
                          .key = t->key,
                          .timer = {.id = id, .late = now - t->at}};
    if (t->every > 0) {
      uint64_t periods = (uint64_t)(now - t->at) / (uint64_t)t->every + 1;
      t->at += (vx_instant)(periods * (uint64_t)t->every);
    } else {
      t->live = false;
    }
  }
  return n;
}

// --- Watches ---

static vx_loop_watch *vx_loop_watch_new(vx_loop *l, uint64_t *bind_key) {
  for (uint32_t i = 0; i < VX_LOOP_WATCHES; i++) {
    vx_loop_watch *w = &l->watch[i];
    if (w->kind != VX_WATCH_FREE) continue;
    w->gen++;
    *bind_key = (uint64_t)w->gen << 32 | i;
    return w;
  }
  vx_err_set(VX_STR("loop: no room for another watch"));
  return nullptr;
}

static vx_loop_watch *vx_loop_watch_find(vx_loop *l, uint64_t bind_key) {
  uint32_t i = (uint32_t)bind_key;
  if (i >= VX_LOOP_WATCHES) return nullptr;
  vx_loop_watch *w = &l->watch[i];
  return w->kind != VX_WATCH_FREE && w->gen == (uint32_t)(bind_key >> 32) ? w : nullptr;
}

VX_API vx_status vx_proc_watch(vx_loop *l, vx_proc p, uint64_t key) {
  uint64_t bind_key;
  vx_loop_watch *w = vx_loop_watch_new(l, &bind_key);
  if (!w) return VX_ERR_NO_MEMORY;
  vx_handle task;
  vx_status st = vx_handle_dup(p.task, VX_RIGHTS_SAME, &task);
  if (st == VX_OK) st = vx_port_bind(l->port, task, VX_TRIGGER_EXIT, bind_key, 0);
  if (st != VX_OK) {
    if (task) vx_handle_close(task);
    return st;
  }
  *w = (vx_loop_watch){.kind = VX_WATCH_PROC, .gen = w->gen, .key = key, .source = p.pid, .object = task};
  return VX_OK;
}

VX_API vx_status vx_thread_watch(vx_loop *l, vx_thread *t, uint64_t key) {
  uint64_t bind_key;
  vx_loop_watch *w = vx_loop_watch_new(l, &bind_key);
  if (!w) return VX_ERR_NO_MEMORY;
  vx_handle counter, theirs = VX_HANDLE_NONE;
  vx_status st = vx_counter_create(0, &counter);
  if (st == VX_OK) st = vx_port_bind(l->port, counter, VX_TRIGGER_COUNTER_GE, bind_key, 1);
  if (st == VX_OK) st = vx_handle_dup(counter, VX_RIGHTS_SAME, &theirs);
  if (st != VX_OK) {
    if (counter) vx_handle_close(counter);
    return st;
  }
  vx_lock(&t->lock);
  if (t->ended)
    vx_counter_signal(theirs, 1), vx_handle_close(theirs);
  else if (t->watch)
    st = VX_ERR_EXISTS, vx_handle_close(theirs); // one watch for a thread
  else
    t->watch = theirs;
  vx_unlock(&t->lock);
  if (st != VX_OK) {
    vx_handle_close(counter);
    return st;
  }
  *w = (vx_loop_watch){.kind = VX_WATCH_THREAD,
                       .gen = w->gen,
                       .key = key,
                       .source = (uint64_t)(uintptr_t)t,
                       .object = counter,
                       .thread = t};
  return VX_OK;
}

// A watch's packet as its event: the exit string into the loop's arena.
static bool vx_loop_watch_event(vx_loop *l, const vx_packet *pk, vx_instant now, vx_event *ev) {
  vx_loop_watch *w = vx_loop_watch_find(l, pk->key);
  if (!w) return false;
  const char *text = "";
  size_t len = 0;
  vx_task_summary s;
  if (w->kind == VX_WATCH_PROC && vx_task_info(w->object, &s) == VX_OK)
    text = s.exit, len = s.exit_len < VX_ERRMAX ? s.exit_len : VX_ERRMAX;
  if (w->kind == VX_WATCH_THREAD) text = w->thread->exit, len = w->thread->exit_len;
  vx_str msg = VX_STR("");
  if (len) {
    char *p = vx_push(l->arena, len, 1);
    if (p) memcpy(p, text, len), msg = (vx_str){p, len};
  }
  *ev = (vx_event){.kind = VX_EV_EXIT, .source = w->source, .time = now, .key = w->key, .exit = {.msg = msg}};
  vx_handle_close(w->object);
  w->kind = VX_WATCH_FREE;
  return true;
}

// --- Notes ---

static vx_noted vx_loop_note(vx_exception *e, vx_str note, void *fp) {
  (void)e, (void)fp;
  vx_loop *l = atomic_load(&vx_note_loop);
  if (!l || vx_str_prefix(note, VX_STR("sys: "))) return VX_NDFLT; // a trap: the program cannot go on
  uint64_t tail = atomic_load(&l->note_tail);
  if (tail - atomic_load(&l->note_head) < VX_LOOP_NOTES) {
    size_t len = vx_utf_cut(note.ptr, note.len, VX_ERRMAX);
    memcpy(l->note[tail % VX_LOOP_NOTES].text, note.ptr, len);
    l->note[tail % VX_LOOP_NOTES].len = (uint32_t)len;
    atomic_store(&l->note_tail, tail + 1);
    vx_counter_signal(l->notes, tail + 1);
  }
  return VX_NCONT;
}

VX_API vx_status vx_notes_to_loop(vx_loop *l) {
  if (!l->notes) {
    vx_status st = vx_counter_create(0, &l->notes);
    if (st == VX_OK) st = vx_port_bind(l->port, l->notes, VX_TRIGGER_COUNTER_GE, VX_LOOP_NOTE_KEY, 1);
    if (st != VX_OK) {
      if (l->notes) vx_handle_close(l->notes), l->notes = VX_HANDLE_NONE;
      return st;
    }
  }
  atomic_store(&vx_note_loop, l);
  return vx_notify(vx_loop_note);
}

// The queued notes as events, up to cap. Once its binding has fired
// (rebind), the counter is bound again past what was taken: at once, then,
// if more are queued than cap took.
static size_t vx_notes_take(vx_loop *l, vx_instant now, vx_event *evs, size_t cap, bool rebind) {
  size_t n = 0;
  uint64_t head = atomic_load(&l->note_head), tail = atomic_load(&l->note_tail);
  for (; head < tail && n < cap; head++) {
    uint32_t len = l->note[head % VX_LOOP_NOTES].len;
    char *p = vx_push(l->arena, len ? len : 1, 1);
    vx_str text = {};
    if (p) memcpy(p, l->note[head % VX_LOOP_NOTES].text, len), text = (vx_str){p, len};
    evs[n++] = (vx_event){.kind = VX_EV_NOTE, .time = now, .note = {.text = text}};
  }
  atomic_store(&l->note_head, head);
  if (rebind) vx_port_bind(l->port, l->notes, VX_TRIGGER_COUNTER_GE, VX_LOOP_NOTE_KEY, head + 1);
  return n;
}

// --- The wait ---

VX_API int64_t vx_loop_wait(vx_loop *l, vx_instant deadline, vx_duration leeway, vx_event *evs, size_t cap) {
  if (!cap) return VX_ERR_INVALID;
  vx_arena_pop(l->arena, (vx_mark){0});
  size_t n = vx_timers_fire(l, vx_now(), evs, cap);
  vx_packet pk[16];
  for (;;) {
    vx_instant until = deadline, t_at;
    vx_duration t_leeway, wait_leeway = leeway;
    if (n) until = 0; // events already: only what is queued
    if (!n && vx_timer_next(l, &t_at, &t_leeway) && t_at < until) until = t_at, wait_leeway = t_leeway;
    size_t want = cap - n < 16 ? cap - n : 16;
    int64_t got = want ? vx_port_wait(l->port, until, wait_leeway, pk, want) : 0;
    if (got == VX_ERR_INTERRUPTED) continue; // a note diverted the wait: wait again
    if (got == VX_ERR_TIMED_OUT) got = 0;
    if (got < 0) return n ? (int64_t)n : got;
    vx_instant now = vx_now();
    bool notes = false;
    for (int64_t i = 0; i < got; i++) {
      if (pk[i].trigger == VX_TRIGGER_USER)
        evs[n++] = (vx_event){
            .kind = VX_EV_POST, .time = now, .key = pk[i].key, .post = {.a = pk[i].key, .b = pk[i].value}};
      else if (pk[i].key == VX_LOOP_NOTE_KEY)
        notes = true;
      else if (vx_loop_watch_event(l, &pk[i], now, &evs[n]))
        n++;
    }
    if (notes || (l->notes && atomic_load(&l->note_head) < atomic_load(&l->note_tail)))
      n += vx_notes_take(l, now, evs + n, cap - n, notes);
    n += vx_timers_fire(l, now, evs + n, cap - n);
    if (n || until == 0 || now >= deadline) return (int64_t)n;
  }
}
