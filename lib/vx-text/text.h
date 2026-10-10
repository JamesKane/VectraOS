// vx-text: the editor's text (08 §4, §5, §16; M7 step 7g1a). One library,
// host-tested and fuzzed, for hx (M8) and dbg's source view: a buffer as a
// piece tree, anchors, the undo tree, and sam's command language with dot as
// many selections.
//
// The buffer. The file's bytes are the original, never copied (the caller
// keeps them, as a mapped file); what is typed goes into an append-only add
// buffer, in blocks that never move. Every insertion has an id (the
// original's is 0), and the text is a sequence of fragments, each a range of
// one insertion: Zed's buffer (08 §17), which collaboration needs later. A
// deleted fragment stays in the sequence as a tombstone, so an anchor into
// deleted text still finds its place and an undo only flips visibility. The
// sequence is a treap, each node summing its subtree's visible bytes,
// newlines and runes, so a byte, line or rune offset is a walk down it,
// O(log n); a second treap over the same nodes, keyed by insertion and
// offset, finds an anchor's fragment. Fragments hold at most VX_TEXT_CHUNK
// bytes, so what a walk scans inside one is bounded.
//
// Positions are byte offsets. Bytes are never checked (00 §1): a rune is
// counted at each byte that is not a UTF-8 continuation byte, which is the
// decoder's count for valid UTF-8; in invalid text a stray continuation byte
// belongs to the rune before it (sam's #n addresses, vx_text_rune_of).
//
// Undo is a tree (08 §4). Every change is in a group: the edits between
// vx_text_begin and vx_text_end, or one edit made outside them. A group
// records its source ("user", "agent", a script's name) and its parent, the
// group the buffer was at when it was made, so undoing and then editing
// starts a branch and loses nothing. vx_text_undo takes back the current
// group and moves to its parent; vx_text_redo goes down to the child last
// made or undone. vx_text_revert takes back one group of the current path
// on its own, an outside change say, as a new group, itself undoable.
//
// sam's language (08 §5; sam(1) as 9front's sam/cmd.c, xec.c, address.c and
// regexp.c have it). Addresses: #n, n, /re/, ?re?, ., $, 0, +, -, ',', ';',
// juxtaposition. Commands: a c i d s m t p = x y g v { } u, and | < > through
// a shell the caller gives. A command runs against the text as it was when
// it started; its changes are collected, must not overlap ("changes not in
// sequence"), and are made together at its end, as sam's are. Evolved for
// many selections: dot is a list of ranges and a command runs once for each,
// all in one group; x, y, g and v without a command select (sam prints), so
// "x/re/" makes a selection of every match; a command's new dot is the union
// of what each run left. File commands (b e f r w q X Y ! cd) are hx's.
// Regular expressions are sam's (regexp(7)): literal runes, . [] [^] * + ?
// | () ^ $ and \n, leftmost-longest, . and [^] never matching a newline,
// with \1-\9 and & in s's replacement; an empty one is the last one used.

#pragma once

#include <stddef.h>
#include <stdint.h>

#include "../../abi/vx/abi.h"
#include "../../abi/vx/utf.h"

typedef struct vx_text vx_text;

enum : uint32_t {
  VX_TEXT_CHUNK = 8192, // the most bytes in one fragment
};

// A range of bytes, p0 <= p1.
typedef struct vx_text_range {
  uint64_t p0, p1;
} vx_text_range;

// A place that survives edits: an insertion and an offset into it. Left
// bias sticks to the byte before the place, right to the byte after; text
// inserted at the place goes after a left anchor and before a right one.
typedef struct vx_text_anchor {
  uint32_t insertion; // VX_TEXT_START or VX_TEXT_END for the text's ends
  uint32_t bias;      // VX_TEXT_LEFT or VX_TEXT_RIGHT
  uint64_t offset;
} vx_text_anchor;

enum : uint32_t {
  VX_TEXT_LEFT = 0,
  VX_TEXT_RIGHT = 1,
  VX_TEXT_START = 0xffff'fffe,
  VX_TEXT_END = 0xffff'ffff,
};

// A group of the undo tree, as vx_text_group reports it.
typedef struct vx_text_group_info {
  uint32_t id, parent; // 0 is the root: the text as it was opened
  uint32_t reverts;    // a revert's: the group it takes back, else 0
  bool applied;
  vx_str source;
} vx_text_group_info;

// The buffer. vx_text_new keeps original (len bytes), never copying it, and
// fails (nullptr) only out of memory.
vx_text *vx_text_new(const char *original, uint64_t len);
void vx_text_free(vx_text *t);
// Sticky: once out of memory, every edit fails, and this says so.
bool vx_text_failed(const vx_text *t);

uint64_t vx_text_len(const vx_text *t);
uint64_t vx_text_lines(const vx_text *t); // newlines
uint64_t vx_text_runes(const vx_text *t);
// Copies the bytes at off, at most n, into buf; returns how many.
uint64_t vx_text_read(const vx_text *t, uint64_t off, char *buf, uint64_t n);
// Line n's first byte (lines from 0: the byte after the n-th newline), or
// the length if there is no such line; the line holding byte off.
uint64_t vx_text_line_start(const vx_text *t, uint64_t line);
uint64_t vx_text_line_of(const vx_text *t, uint64_t off);
// The byte where rune n starts (the length past the last); the rune at off.
uint64_t vx_text_rune_start(const vx_text *t, uint64_t rune);
uint64_t vx_text_rune_of(const vx_text *t, uint64_t off);

// Edits. Outside begin and end each is a group of its own; begin's nest.
// An offset past the end is clamped to it. False out of memory.
bool vx_text_begin(vx_text *t, vx_str source);
void vx_text_end(vx_text *t);
bool vx_text_insert(vx_text *t, uint64_t off, const char *bytes, uint64_t n);
bool vx_text_delete(vx_text *t, uint64_t p0, uint64_t p1);
bool vx_text_replace(vx_text *t, uint64_t p0, uint64_t p1, const char *bytes, uint64_t n);

vx_text_anchor vx_text_anchor_at(vx_text *t, uint64_t off, uint32_t bias);
uint64_t vx_text_resolve(vx_text *t, vx_text_anchor a);

// The undo tree. Each is false when there is nothing to do, or while a
// group is open.
bool vx_text_undo(vx_text *t);
bool vx_text_redo(vx_text *t);
bool vx_text_revert(vx_text *t, uint32_t group, vx_str source);
uint32_t vx_text_head(const vx_text *t); // the current group
uint32_t vx_text_groups(const vx_text *t);
bool vx_text_group(const vx_text *t, uint32_t id, vx_text_group_info *out);
// Counts every change to the visible text: edits, undos and redos.
uint64_t vx_text_version(const vx_text *t);

// Dot: the selections, sorted, never overlapping (touching empty ones may
// sit together). It grows by the text's allocator; vx_text_dot_free frees it.
typedef struct vx_text_dot {
  vx_text_range *r;
  size_t n, cap;
} vx_text_dot;

bool vx_text_dot_set(vx_text_dot *d, uint64_t p0, uint64_t p1);
void vx_text_dot_free(vx_text_dot *d);

// What a command reaches outside the text. print takes p's text and ='s
// positions. shell runs a command for | (in is dot's text; *out replaces
// it), < (*out replaces dot) and > (in is dot's text); *out must stay valid
// until the next call. Either may be null: p prints nothing, and | < >
// fail with "no shell".
typedef struct vx_text_io {
  void *arg;
  void (*print)(void *arg, const char *p, size_t n);
  bool (*shell)(void *arg, char kind, vx_str command, vx_str in, vx_str *out);
} vx_text_io;

// Runs sam's commands in cmd, one a line (a, c and i may take lines up to
// one holding only "."), all in one group with source, against dot, which
// it moves. False on an error, which leaves the text as it was before the
// failing command and puts sam's words in error (at most errlen bytes, NUL
// terminated).
bool vx_text_run(vx_text *t, vx_str cmd, vx_text_dot *dot, const vx_text_io *io, vx_str source, char *error,
                 size_t errlen);
