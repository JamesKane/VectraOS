// vx-plumb: plumb messages and the plumber's rules (07 §7; plumb(6); M7
// step 7g3a), as 9front has them (libplumb/mesg.c, cmd/plumb/rules.c and
// match.c): the message's packed form, its attributes, and the rule
// language, parsed, matched and expanded. What a match does with a port or
// a program is the plumber's (servers/plumber); the files a rule names are
// the caller's, through vx_plumb_fs, so the library is host-tested.
//
// A message packed, 9front's form:
//
//   src\n dst\n wdir\n type\n attr\n ndata\n and ndata bytes of data
//
// each field a line, attr a list of name=value, a value quoted with '' when
// it holds a blank, a quote or an =.

#pragma once

#include <stddef.h>
#include <stdint.h>

typedef struct vx_plumb_attr vx_plumb_attr;
struct vx_plumb_attr {
  char *name, *value;
  vx_plumb_attr *next;
};

typedef struct vx_plumb_msg {
  char *src, *dst, *wdir, *type; // each a string, "" for none
  vx_plumb_attr *attr;
  size_t ndata;
  char *data; // ndata bytes and a NUL
} vx_plumb_msg;

// --- Messages ---

// The message packed (*n bytes and a NUL), or nullptr out of memory;
// vx_plumb_dealloc frees it.
char *vx_plumb_pack(const vx_plumb_msg *m, size_t *n);
// The message in buf, or nullptr: *more is then how many more bytes it
// needs, or 0 when it is malformed (or memory ran out). more may be null.
vx_plumb_msg *vx_plumb_unpack(const char *buf, size_t n, size_t *more);
vx_plumb_msg *vx_plumb_msg_new(const char *src, const char *dst, const char *wdir, const char *type,
                               const char *data, size_t ndata);
void vx_plumb_free(vx_plumb_msg *m);
void vx_plumb_dealloc(void *p);

// Attributes: packed as one line (nullptr for none); unpacked to the end of
// s or its first newline, a malformed one ending the list.
char *vx_plumb_pack_attr(const vx_plumb_attr *a);
vx_plumb_attr *vx_plumb_unpack_attr(const char *s);
vx_plumb_attr *vx_plumb_add_attr(vx_plumb_attr *a, vx_plumb_attr *more); // more at the end
vx_plumb_attr *vx_plumb_del_attr(vx_plumb_attr *a, const char *name);    // the first so named
const char *vx_plumb_lookup(const vx_plumb_attr *a, const char *name);
void vx_plumb_free_attr(vx_plumb_attr *a);

// --- Rules ---

enum : int { VX_PLUMB_NONE, VX_PLUMB_FILE, VX_PLUMB_DIR };

// The files rules name: what path is (isfile, isdir), and a whole file
// (include), allocated with the library's allocator (vx_plumb_alloc), or
// nullptr.
typedef struct vx_plumb_fs {
  int (*kind)(void *ctx, const char *path);
  char *(*read)(void *ctx, const char *path, size_t *n);
  void *ctx;
} vx_plumb_fs;

typedef struct vx_plumb_rules vx_plumb_rules;
typedef struct vx_plumb_exec vx_plumb_exec;

void *vx_plumb_alloc(size_t n);

vx_plumb_rules *vx_plumb_rules_new(const vx_plumb_fs *fs);
void vx_plumb_rules_free(vx_plumb_rules *r);
// A whole rules file, its name for errors: false, and vx_plumb_rules_error
// says where and why, at the first error (the rules before it kept).
bool vx_plumb_rules_read(vx_plumb_rules *r, const char *name, const char *text, size_t n);
// Writes to the rules file: each ruleset ended by a blank line is added as
// it comes; done (its close) adds the rest. False at an error, as above.
bool vx_plumb_rules_write(vx_plumb_rules *r, const char *text, size_t n, bool done);
// Opening the rules file with OTRUNC: no rules (variables and ports stay).
void vx_plumb_rules_clear(vx_plumb_rules *r);
const char *vx_plumb_rules_error(const vx_plumb_rules *r);
// The rules file's contents: variables, ports, then each ruleset.
char *vx_plumb_rules_print(vx_plumb_rules *r, size_t *n);
// Ports, every destination of a `plumb to` ever read, never removed.
uint32_t vx_plumb_port_count(const vx_plumb_rules *r);
const char *vx_plumb_port(const vx_plumb_rules *r, uint32_t i);

// The first ruleset m matches, its rewriting of m done (dst set to its
// port, data to what a click selected), or nullptr for none.
vx_plumb_exec *vx_plumb_match(vx_plumb_rules *r, vx_plumb_msg *m);
// The match's start or client action: the program and its arguments,
// expanded (vx_plumb_argv_free), and whether the message is held for the
// port's opening (client); nullptr, or why not ("no start action for plumb
// message"). e may be nullptr: a message no rule matched.
const char *vx_plumb_startup(vx_plumb_rules *r, vx_plumb_exec *e, char ***argv, bool *hold);
void vx_plumb_exec_free(vx_plumb_exec *e);
void vx_plumb_argv_free(char **argv);

// Plan 9's cleanname, in place: no empty, "." or ".." elements but the
// leading ".."s of a relative name; "" becomes ".".
char *vx_plumb_clean(char *name);
