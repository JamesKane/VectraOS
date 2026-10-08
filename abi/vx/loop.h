// vx/loop.h: the loop and its events (09 §4.7, §5.4; ADR-0004 libvx v0).
// A loop is a port plus the bookkeeping that turns packets into events: one
// wait for everything a thread waits on. vx_post may be called from any
// thread; the rest of a loop's calls are its own thread's.

#pragma once

#include "api.h"
#include "proc.h"
#include "thread.h"

typedef struct vx_loop vx_loop;
typedef uint64_t vx_timer; // 0: none

// The kinds of event (09 §5.4). Level 0 delivers POST, TIMER, EXIT and NOTE;
// the rest come with the calls that make them (files, a later step; memory
// budgets, a later level), their numbers fixed now.
typedef enum vx_event_kind : uint32_t {
  VX_EV_POST = 1, // vx_post: post.a and post.b
  VX_EV_TIMER,    // vx_timer_at: timer.id, timer.late
  VX_EV_IO,       // a file request completed
  VX_EV_CHANGED,  // a watched file changed
  VX_EV_READY,    // a file has data to read
  VX_EV_EXIT,     // a watched process or thread ended: exit.msg, "" for success; source its pid or thread
  VX_EV_NOTE,     // a note, once vx_notes_to_loop: note.text
  VX_EV_PRESSURE, // the memory budget changed
  VX_EV_HUNGUP,   // a connection to a server dropped for good
} vx_event_kind;

// One record for every event, 64 bytes. A slice in it (an exit string, a
// note) points into the loop's own memory and holds until its next wait.
typedef struct vx_event {
  uint32_t kind; // vx_event_kind
  uint32_t flags;
  uint64_t source; // a process's pid, a thread's record, a timer: what it came from
  vx_instant time; // when the loop took it
  uint64_t key;    // the program's, given when it was watched, posted or set
  union {
    struct {
      uint64_t a, b;
    } post;
    struct {
      vx_timer id;
      vx_duration late; // how long after its time it fired
    } timer;
    struct {
      vx_str msg;
    } exit;
    struct {
      vx_str text;
    } note;
    uint8_t payload[32];
  };
} vx_event;
static_assert(sizeof(vx_event) == 64);

// A new loop, or nullptr (vx_errstr says why); vx_loop_free ends it, its
// watches and timers with it.
VX_API vx_loop *vx_loop_new(void);
VX_API void vx_loop_free(vx_loop *l);
// Up to cap events into evs, waiting until deadline (0, or one already
// past: a poll) for the first; leeway lets the wake be that late. How many,
// 0 if the deadline came first, or a negative vx_status.
VX_API int64_t vx_loop_wait(vx_loop *l, vx_instant deadline, vx_duration leeway, vx_event *evs, size_t cap);
// A VX_EV_POST of a and b, from any thread; its key is a.
VX_API vx_status vx_post(vx_loop *l, uint64_t a, uint64_t b);
// A VX_EV_TIMER at at, then every every after it (0: once); 0 if the loop
// has no room for another.
VX_API vx_timer vx_timer_at(vx_loop *l, vx_instant at, vx_duration leeway, vx_duration every, uint64_t key);
VX_API void vx_timer_stop(vx_loop *l, vx_timer t);
// A VX_EV_EXIT with key when p, or t, ends (at once if it has); once. A
// thread is still joined after (vx_thread_join returns at once).
VX_API vx_status vx_proc_watch(vx_loop *l, vx_proc p, uint64_t key);
VX_API vx_status vx_thread_watch(vx_loop *l, vx_thread *t, uint64_t key);
// The process's notes as VX_EV_NOTE on l from now on, rather than
// interrupting it (ADR-0010); a trap ("sys: ...") still ends the program.
VX_API vx_status vx_notes_to_loop(vx_loop *l);
