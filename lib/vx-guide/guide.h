// vx-guide: the manual's format, guide (docs/12-manual.md §4, ADR-0028;
// guide(6)). The one parser: man, lookman, sig, hv and build all read pages
// through it, and nothing else parses one.
//
// A page is UTF-8: an optional `@guide=1` line, a header of ndb (one record,
// its first tuple page=) ended by the first blank line, then a body whose
// lines are typed by how they begin. vx_guide_open reads the header;
// vx_guide_next gives the body a block at a time; vx_guide_span_next splits
// a block's text into its inline spans. Every value points into the page or
// into the vx_guide, so the page must outlive what they return. Nothing is
// allocated, and nothing recurses.
//
// The parser is strict: what it does not know, it refuses with a message and
// a line, and never guesses (12 §4.7).
#pragma once

#include "../../abi/vx/abi.h"

typedef struct vx_guide_header {
  vx_str page, summary, names, src, lang, keys; // names, src and keys: comma-separated lists
  int sect;                                     // 1 to 8
  uint64_t level;                               // 0: none given
  bool host;
} vx_guide_header;

typedef enum vx_guide_kind : int32_t {
  VX_GUIDE_END = 0,
  VX_GUIDE_NODE = 1,       // @node=: node, title, keys
  VX_GUIDE_HEADING = 2,    // "# ": text
  VX_GUIDE_SUBHEADING = 3, // "## ": text
  VX_GUIDE_PARA = 4,       // text: the paragraph's lines, newlines and all
  VX_GUIDE_ITEM = 5,       // "- ": text, with its continuation lines
  VX_GUIDE_DEF = 6,        // ": ": text is the term, body its description
  VX_GUIDE_ROW = 7,        // "|": text is the row after the first |; cells by vx_guide_cell_next
  VX_GUIDE_FENCE = 8,      // text is the lines inside, each with its newline; fence its kind ("" for none)
  VX_GUIDE_ERROR = -1,
} vx_guide_kind;

typedef struct vx_guide_block {
  vx_guide_kind kind;
  vx_str text, body, fence;
  vx_str node, title, keys;
  size_t line; // where it starts, 1-based
} vx_guide_block;

static constexpr int VX_GUIDE_MAX_NODES = 64;

typedef struct vx_guide {
  vx_str src;
  size_t pos, line; // the next line's start, and the lines consumed
  vx_guide_header h;
  vx_str nodes[VX_GUIDE_MAX_NODES]; // the ids seen, to refuse a repeat
  int nnodes;
  char hscratch[2048], lscratch[1024]; // decoded header values; the last @ line's
  const char *error;                   // set when a call fails,
  size_t error_line;                   // with the line it refers to
} vx_guide;

// Reads the page's version line and header. False on an error (g->error).
[[maybe_unused]] static bool vx_guide_open(vx_guide *g, vx_str page);
// The next block of the body: VX_GUIDE_END after the last, VX_GUIDE_ERROR on an error.
[[maybe_unused]] static vx_guide_kind vx_guide_next(vx_guide *g, vx_guide_block *b);

typedef enum vx_guide_span_kind : int32_t {
  VX_SPAN_END = 0,
  VX_SPAN_TEXT = 1,    // text: words, never whitespace
  VX_SPAN_SPACE = 2,   // a run of whitespace, newlines and continuation indents included
  VX_SPAN_LITERAL = 3, // text: between the backticks (one space trimmed from each end when both have one)
  VX_SPAN_PARAM = 4,   // text: <name>, brackets included
  VX_SPAN_REF = 5,     // text: name(N), as written; name and sect
  VX_SPAN_LINK = 6,    // {label|target} or {target}: label (the target when none) and target
  VX_SPAN_ERROR = -1,
} vx_guide_span_kind;

typedef struct vx_guide_span {
  vx_guide_span_kind kind;
  vx_str text, name, label, target;
  int sect;
} vx_guide_span;

typedef struct vx_guide_inline {
  vx_str s;
  size_t pos;
  const char *error;
} vx_guide_inline;

// The next span of it->s. VX_SPAN_ERROR, with it->error, on an unclosed
// literal or a bad link.
[[maybe_unused]] static vx_guide_span_kind vx_guide_span_next(vx_guide_inline *it, vx_guide_span *sp);

// The next item of a comma-separated list, consumed from *list; false at its end.
[[maybe_unused]] static bool vx_guide_item_next(vx_str *list, vx_str *item);
// The next cell of a row (VX_GUIDE_ROW's text), consumed from *row, trimmed;
// a | inside backticks is the cell's. False at the row's end.
[[maybe_unused]] static bool vx_guide_cell_next(vx_str *row, vx_str *cell);

// Rendering for a terminal (12 §6.1): the page refilled to `width` columns,
// NAME made from the header and SOURCE from src=, indented as Plan 9's.
typedef struct vx_guide_out {
  void (*write)(void *ctx, const char *s, size_t n);
  void *ctx;
  uint32_t width; // 0: 80
} vx_guide_out;

// The whole page, or (node not nullptr) that node alone. False on an error,
// with *error and *line set; what was written before it stands.
[[maybe_unused]] static bool vx_guide_render(vx_str page, const char *node, const vx_guide_out *out,
                                             const char **error, size_t *line);
