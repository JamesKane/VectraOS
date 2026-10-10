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

// The kinds of event (09 §5.4). Level 0 delivers POST, TIMER, EXIT, NOTE,
// and IO, CHANGED and READY (<vx/file.h>'s vx_io_submit and vx_watch);
// PRESSURE and HUNGUP come later, their numbers fixed now.
typedef enum vx_event_kind : uint32_t {
  VX_EV_POST = 1, // vx_post: post.a and post.b
  VX_EV_TIMER,    // vx_timer_at: timer.id, timer.late
  VX_EV_IO,       // a vx_io request completed: io
  VX_EV_CHANGED,  // a watched file changed: changed.what, changed.name
  VX_EV_READY,    // a watched file has data to read: ready.fd
  VX_EV_EXIT,     // a watched process or thread ended: exit.msg, "" for success; source its pid or thread
  VX_EV_NOTE,     // a note, once vx_notes_to_loop: note.text
  VX_EV_PRESSURE, // the memory budget changed
  VX_EV_HUNGUP,   // a connection to a server dropped for good
} vx_event_kind;

// vxui's kinds (M7 step 7e2, 03 §6), from vx_wait: source is the vx_window.
enum : uint32_t {
  VX_NONE = 0,       // vx_wait's deadline came first
  VX_FRAME = 64,     // draw now: frame
  VX_KEY = 65,       // keyboard
  VX_POINTER = 66,   // pointer
  VX_TEXT = 67,      // text, committed: text.text
  VX_CONFIGURE = 68, // the window's size or focus changed: configure
  VX_CLOSE = 69,     // the window was closed
  VX_WAKE = 70,      // vx_app_wake, from another thread: source is the vx_app
};

// A frame event (03 §4, §6 item 4): when a frame drawn now is meant to be
// seen, when the window's last one was, and the time since the last frame
// event, so a game's interpolation needs no clock arithmetic.
typedef struct vx_frame_event {
  uint64_t seq;
  vx_instant target, prev_presented;
  vx_duration dt;
} vx_frame_event;

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
    struct {
      int64_t count; // bytes done, or a negative vx_status
      int32_t fd;    // the request's vx_fd
      uint32_t op;   // its vx_io_op
      uint64_t off;
    } io;
    struct {
      uint32_t what; // VX_CHANGED_ bits
      vx_str name;   // in a watched directory, the entry; "" for the file itself
    } changed;
    struct {
      int32_t fd;
    } ready;
    vx_frame_event frame; // vxui's, below
    struct {
      uint32_t usage; // a HID usage (VX_KEY_SPACE, ...)
      uint32_t rune;  // what it types unmodified, 0 for none
      uint32_t mods;  // VX_MOD_*
      bool down, repeat;
    } keyboard; // ("key" is the event's own: the program's)
    struct {
      float x, y; // in the window
      uint32_t buttons;
      int32_t wheel;
    } pointer;
    struct {
      vx_str text; // UTF-8, until the next vx_wait
    } text;
    struct {
      uint32_t width, height;
      bool focused;
    } configure;
    uint8_t payload[32];
  };
} vx_event;
static_assert(sizeof(vx_event) == 64);

// What changed, in VX_EV_CHANGED (9Px notify's kinds, docs/proto/notify.md).
enum : uint32_t {
  VX_CHANGED_CREATE = 1,      // a name made in the directory
  VX_CHANGED_REMOVE = 2,      // a name removed from it, or the file removed
  VX_CHANGED_MODIFY = 4,      // data written
  VX_CHANGED_ATTRIB = 8,      // attributes changed
  VX_CHANGED_MOVED_FROM = 16, // renamed away from here
  VX_CHANGED_MOVED_TO = 32,   // renamed to here
  VX_CHANGED_LOST = 128,      // changes were lost: read it again
};

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
