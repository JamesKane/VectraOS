// vx-ns newns: namespace(6) files (ADR-0009), as Plan 9's newns reads them.
//
// One operation a line: mount [-abcC] SERVICE OLD [SPEC], bind [-abcC] NEW
// OLD, unmount [NEW] OLD, cd DIR, clear, and `. FILE`, which includes another
// namespace file. Words are separated by spaces and tabs; a word in single
// quotes may hold them ('' is a quote). $NAME is replaced by the variable's
// value, NAME ending at white space, a '/' or a '$'. A line whose first word
// starts with # is a comment. vx_ns_print writes the same form.
//
// This file parses; who applies an operation decides what a SERVICE is: svcd
// gives a mount the post /srv/NAME names, and a process the connection it
// already has from that service (vx_ns_mount_srv).

#pragma once

#include "ns.c"

typedef enum vx_ns_opkind : uint8_t {
  VX_NS_OP_MOUNT,
  VX_NS_OP_BIND,
  VX_NS_OP_UNMOUNT,
  VX_NS_OP_CD,
  VX_NS_OP_CLEAR,
  VX_NS_OP_INCLUDE,
} vx_ns_opkind;

typedef struct vx_ns_op {
  vx_ns_opkind kind;
  uint8_t flags;  // VX_NS_AFTER, VX_NS_BEFORE, VX_NS_CREATE
  uint32_t argc;  // the words after the operation and its flags
  vx_str args[3]; // mount: SERVICE OLD [SPEC]; bind: NEW OLD; unmount: [NEW] OLD; cd, .: one
  uint32_t line;  // its line in the file, from 1
} vx_ns_op;

static vx_str ns_cstr(const char *s) {
  size_t n = 0;
  while (s[n]) n++;
  return (vx_str){s, n};
}

typedef struct vx_ns_script {
  vx_str text;
  size_t pos;
  uint32_t line;
  // $NAME's value, or an empty string; may be null (no variables).
  vx_str (*var)(void *ctx, vx_str name);
  void *ctx;
  char words[VX_NS_MAX_PATH * 4]; // the expanded words of the line last read
} vx_ns_script;

// The next line's words, expanded into s->words. Returns how many, or -1 if
// a quote is not closed or the words do not fit.
static int ns_script_words(vx_ns_script *s, vx_str line, vx_str *words, int cap) {
  size_t used = 0, i = 0;
  int n = 0;
  while (i < line.len) {
    while (i < line.len && (line.ptr[i] == ' ' || line.ptr[i] == '\t')) i++;
    if (i == line.len) break;
    if (n == cap) return -1;
    size_t start = used;
    bool quoted = false;
    while (i < line.len && (quoted || (line.ptr[i] != ' ' && line.ptr[i] != '\t'))) {
      char c = line.ptr[i++];
      if (c == '\'') {
        if (quoted && i < line.len && line.ptr[i] == '\'') {
          i++; // '' inside quotes: one quote
        } else {
          quoted = !quoted;
          continue;
        }
      } else if (c == '$' && !quoted) {
        size_t name = i;
        while (i < line.len && line.ptr[i] != ' ' && line.ptr[i] != '\t' && line.ptr[i] != '/' &&
               line.ptr[i] != '$' && line.ptr[i] != '\'')
          i++;
        vx_str v = s->var ? s->var(s->ctx, (vx_str){line.ptr + name, i - name}) : (vx_str){};
        if (v.len > sizeof s->words - used) return -1;
        if (v.len) memcpy(s->words + used, v.ptr, v.len);
        used += v.len;
        continue;
      }
      if (used == sizeof s->words) return -1;
      s->words[used++] = c;
    }
    if (quoted) return -1;
    words[n++] = (vx_str){s->words + start, used - start};
  }
  return n;
}

// The next operation: VX_OK, NOT_FOUND at the end of the file, or INVALID for
// a line that is not one (op->line says which).
[[maybe_unused]] static vx_status vx_ns_script_next(vx_ns_script *s, vx_ns_op *op) {
  for (;;) {
    if (s->pos >= s->text.len) return VX_ERR_NOT_FOUND;
    size_t start = s->pos;
    while (s->pos < s->text.len && s->text.ptr[s->pos] != '\n') s->pos++;
    vx_str line = {s->text.ptr + start, s->pos - start};
    s->pos++;
    s->line++;
    *op = (vx_ns_op){.line = s->line};
    size_t first = 0;
    while (first < line.len && (line.ptr[first] == ' ' || line.ptr[first] == '\t')) first++;
    if (first < line.len && line.ptr[first] == '#') continue; // a comment, whatever it holds
    vx_str w[6];
    int n = ns_script_words(s, line, w, 6);
    if (n < 0) return VX_ERR_INVALID;
    if (n == 0) continue;
    static const struct {
      const char *name;
      vx_ns_opkind kind;
      uint32_t min, max;
      bool flags;
    } OPS[] = {{"mount", VX_NS_OP_MOUNT, 2, 3, true},      {"bind", VX_NS_OP_BIND, 2, 2, true},
               {"unmount", VX_NS_OP_UNMOUNT, 1, 2, false}, {"cd", VX_NS_OP_CD, 1, 1, false},
               {"clear", VX_NS_OP_CLEAR, 0, 0, false},     {".", VX_NS_OP_INCLUDE, 1, 1, false}};
    int k = 0;
    while (k < (int)(sizeof OPS / sizeof OPS[0]) && !ns_str_eq(w[0], ns_cstr(OPS[k].name))) k++;
    if (k == (int)(sizeof OPS / sizeof OPS[0])) return VX_ERR_INVALID;
    int at = 1;
    if (OPS[k].flags && n > 1 && w[1].len > 1 && w[1].ptr[0] == '-') {
      for (size_t i = 1; i < w[1].len; i++) {
        char f = w[1].ptr[i];
        if (f == 'a')
          op->flags |= VX_NS_AFTER;
        else if (f == 'b')
          op->flags |= VX_NS_BEFORE;
        else if (f == 'c')
          op->flags |= VX_NS_CREATE;
        else if (f != 'C') // caching: nothing to do here
          return VX_ERR_INVALID;
      }
      if ((op->flags & VX_NS_AFTER) && (op->flags & VX_NS_BEFORE)) return VX_ERR_INVALID;
      at = 2;
    }
    op->kind = OPS[k].kind;
    op->argc = (uint32_t)(n - at);
    if (op->argc < OPS[k].min || op->argc > OPS[k].max) return VX_ERR_INVALID;
    for (uint32_t i = 0; i < op->argc; i++) op->args[i] = w[at + (int)i];
    return VX_OK;
  }
}

// Mounts, at old, the service `src` a connection of this namespace already
// came from (another attach on it): how ns output replays in the process that
// wrote it, or a child that copied its namespace. NOT_FOUND if none did.
[[maybe_unused]] static vx_status vx_ns_mount_srv(vx_ns *ns, vx_str src, vx_str aname, vx_str old,
                                                  uint8_t flags) {
  for (uint32_t i = 0; i < VX_NS_MAX_CONNS; i++) {
    vx_ns_conn *c = &ns->conns[i];
    if (c->client && ns_str_eq((vx_str){c->src, c->src_len}, src))
      return vx_ns_mount(ns, c->client, c->connector, src, aname, old, flags);
  }
  return VX_ERR_NOT_FOUND;
}
