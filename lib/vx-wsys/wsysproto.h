// The window protocol (docs/proto/wsys.md; M7 step 7d1b): the records on a
// window's channel, between winsrv and the app that drew it. The channel is
// what opening the window's surface file gives (/wsys/self/surface, with
// 9Px's srv extension, docs/proto/srv.md). Rings come when the records'
// rate needs them (03 §4 names them); version 1 is a channel.
//
// Its model is Flatland's (21 §2 item 2): a present costs a credit, a client
// starts with one and is granted more by each frame event, so a client can
// never queue unbounded frames and winsrv never blocks. Release is at
// composite (21 §2 item 3): winsrv copies the damage into the window's own
// backing and signals the buffer's release point at once.

#pragma once

#include "../../abi/vx/abi.h"
#include "../vx-buffer/buffer.h"
#include "../vx-driver/inputproto.h"

static constexpr uint32_t VX_WSYS_VERSION = 1;
static constexpr uint32_t VX_WSYS_BUFFERS = 4; // attached to a window at once, at most
static constexpr uint32_t VX_WSYS_DAMAGE = 8;  // rectangles in a present, at most

enum : uint32_t { // winsrv to the app, unasked (txid 0)
  VX_WSYS_CONFIGURE = 1,
  VX_WSYS_FRAME = 2,
  VX_WSYS_FEEDBACK = 3,
  VX_WSYS_KEY = 4,     // 7d1c: to the focused window
  VX_WSYS_POINTER = 5, // to the window under the pointer, or the one a press latched
  VX_WSYS_PREEDIT = 6, // 7d2b: text being composed, not yet the window's
  VX_WSYS_COMMIT = 7,  // text, the window's now
  VX_WSYS_DELETE_SURROUNDING = 8,
  VX_WSYS_KEYMAP = 9, // the layout changed
};

// The input method's side (7d2b): /wsys/ime's channel, between winsrv and
// the one input method that holds it.
enum : uint32_t {
  VX_WSYS_IME_KEY = 32,    // winsrv to the IME: a key of the focused window, its IME on
  VX_WSYS_IME_ANSWER = 33, // the IME to winsrv: what became of it
};
enum : uint32_t {       // the app to winsrv
  VX_WSYS_ATTACH = 16,  // a call: the reply's flags 0 or a status
  VX_WSYS_DETACH = 17,  // a call
  VX_WSYS_PRESENT = 18, // one way: its answer is a FEEDBACK
};

typedef struct vx_wsys_rect {
  int32_t x, y;
  uint32_t width, height;
} vx_wsys_rect;

enum : uint8_t { VX_WSYS_VISIBLE = 0, VX_WSYS_PARTIAL = 1, VX_WSYS_OCCLUDED = 2, VX_WSYS_HIDDEN = 3 };
enum : uint32_t { VX_WSYS_FOCUSED = 1, VX_WSYS_INTERACTIVE = 2 }; // a configure's flags

// CONFIGURE: the window as it now is. A present drawn for an older seq is
// clipped or padded for at most a frame, never stretched (03 §4, F-208).
typedef struct vx_wsys_configure {
  vx_msg_header h;
  uint64_t seq;             // config_seq
  uint32_t width, height;   // logical
  uint32_t pwidth, pheight; // in pixels: the buffer's size to draw
  uint32_t scale;           // over 120: 120 is 1x
  uint8_t visibility;
  uint8_t reserved[3];
  uint32_t flags;  // FOCUSED, INTERACTIVE
  uint32_t window; // its number in /wsys (7e2): where its files are
} vx_wsys_configure;

// FRAME: draw now for target. credits: presents the app may make more
// (each composited present is given back by the next FRAME).
typedef struct vx_wsys_frame {
  vx_msg_header h;
  uint64_t seq;            // the frame clock's count
  uint64_t target;         // vx_clock's ns: the vblank a present made now is meant for
  uint64_t prev_presented; // when the app's last present reached the screen; 0 before any
  uint64_t refresh;        // ns between vblanks
  uint32_t credits;
  uint32_t reserved;
} vx_wsys_frame;

// FEEDBACK: what became of a present.
typedef struct vx_wsys_feedback {
  vx_msg_header h;
  uint64_t seq;       // the present's own
  uint64_t actual;    // vx_clock's ns: the vblank that showed it; 0 if dropped
  uint32_t dropped;   // 1: never shown (no credit, a detached buffer, its acquire point never came)
  uint32_t zero_copy; // 1: scanned out as it is; 0: composited (M7 always composites)
} vx_wsys_feedback;

// KEY: a key, as inputd's record has it (its held set the keyboard's), and
// its unmodified rune (03 §5; 0 for none). A window gets a key's UP only
// after its DOWN; one losing focus gets an UP for each key it holds, with
// the SYNTHETIC flag.
enum : uint32_t {
  VX_WSYS_SYNTHETIC = 1,
  VX_WSYS_IMEPASS = 2, // the IME was on and passed it on: its text, if any, came as a COMMIT before it
};
typedef struct vx_wsys_key {
  vx_msg_header h;
  vx_input_key key;
  uint32_t rune;
  uint32_t flags; // SYNTHETIC
} vx_wsys_key;

// POINTER: the pointer, in the window's coordinates (outside it while a
// press latches it there), the buttons held after it (bit n-1 for button
// n), relative motion and the wheels as the device gave them.
enum : uint32_t { VX_WSYS_LATCHED = 1 }; // delivered by a press's latch, not by where it is
typedef struct vx_wsys_pointer {
  vx_msg_header h;
  uint64_t time;
  int32_t x, y;
  int32_t dx, dy, wheel, hwheel;
  uint32_t buttons;
  uint32_t flags; // LATCHED
} vx_wsys_pointer;

// Text: UTF-8 (ADR-0013), at most VX_WSYS_TEXT bytes a record.
static constexpr uint32_t VX_WSYS_TEXT = 116;

// PREEDIT: what is being composed (a dead key's accent, a compose
// sequence, an IME's candidate), drawn by the app at its text cursor until
// a COMMIT or an empty PREEDIT replaces it; cursor is a byte offset in it.
typedef struct vx_wsys_preedit {
  vx_msg_header h;
  uint32_t len;
  int32_t cursor;
  char text[VX_WSYS_TEXT];
} vx_wsys_preedit;

typedef struct vx_wsys_commit {
  vx_msg_header h;
  uint32_t len;
  uint32_t reserved;
  char text[VX_WSYS_TEXT];
} vx_wsys_commit;

// DELETE_SURROUNDING: bytes to delete before and after the text cursor, as
// the window's ime file's surrounding text has them, before the next COMMIT.
typedef struct vx_wsys_delete {
  vx_msg_header h;
  uint32_t before, after;
} vx_wsys_delete;

typedef struct vx_wsys_keymap {
  vx_msg_header h;
  char name[16]; // NUL-padded: "us", "us-intl"
} vx_wsys_keymap;

// IME_KEY: a DOWN or a repeat, the window it is for and what its text field
// holds (the purpose its ime file was given: text, password, number, url,
// email, terminal), with a sequence number its answer gives back.
typedef struct vx_wsys_ime_key {
  vx_msg_header h;
  uint64_t seq;
  uint32_t window;
  char purpose[12];
  vx_input_key key;
} vx_wsys_ime_key;

// IME_ANSWER: PASS (the key goes to the window as a KEY with IMEPASS), or
// consumed; either way bytes deleted around the cursor, text committed and
// a new preedit (commit_len bytes of text, then preedit_len), applied in
// that order.
enum : uint32_t { VX_WSYS_IME_PASS = 1 };
typedef struct vx_wsys_ime_answer {
  vx_msg_header h;
  uint64_t seq;
  uint32_t flags;
  uint32_t delete_before, delete_after;
  uint32_t commit_len, preedit_len;
  int32_t cursor;
  char text[2 * VX_WSYS_TEXT];
} vx_wsys_ime_answer;

// ATTACH: a vx-buffer, as the app's buffer id; its memory and timeline are
// the message's two handles.
typedef struct vx_wsys_attach {
  vx_msg_header h;
  uint32_t id; // 1 to VX_WSYS_BUFFERS
  uint32_t reserved;
  vx_buffer_desc desc;
} vx_wsys_attach;

typedef struct vx_wsys_detach {
  vx_msg_header h;
  uint32_t id;
  uint32_t reserved;
} vx_wsys_detach;

// PRESENT: the buffer, when it may be read (its timeline at acquire), the
// point winsrv signals once it has copied it (release), the configure it was
// drawn for, and what changed since the app's last present (none: all of it).
typedef struct vx_wsys_present {
  vx_msg_header h;
  uint64_t seq; // the app's own, rising: its FEEDBACK names it
  uint32_t id;
  uint32_t ndamage;
  uint64_t acquire, release;
  uint64_t config_seq;
  vx_wsys_rect damage[VX_WSYS_DAMAGE];
} vx_wsys_present;

// A call's reply.
typedef struct vx_wsys_reply {
  vx_msg_header h;
} vx_wsys_reply;
