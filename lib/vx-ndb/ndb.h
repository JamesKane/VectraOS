// vx-ndb: the one text format (docs/02-namespace-swarm.md §4.1).
//
// A record is one line of tuples plus the indented lines that follow it. A tuple
// is key=value or a bare key (a flag). Values are bare, "quoted" ("" is one
// quote), or x"hex" for bytes that are not printable UTF-8.
//
// The parser is strict: a record with a duplicate key, bad quoting, a control
// character, invalid UTF-8 or more than 64 KiB is rejected whole, never repaired.
//
// The writer chooses each value's form itself: bare when it can, quoted when it
// has spaces or quotes, and x"hex" when it is not printable UTF-8. Nothing that
// comes from another program can forge a tuple or a record (02 §4.1), so no
// server formats ndb by hand.
#pragma once

#include "../../abi/vx/abi.h"

static constexpr size_t VX_NDB_MAX_RECORD = (size_t)64 * 1024;
static constexpr int VX_NDB_MAX_TUPLES = 128;

typedef struct vx_ndb_tuple {
  vx_str key;
  vx_str value; // ptr is nullptr for a flag
} vx_ndb_tuple;

typedef struct vx_ndb_record {
  vx_ndb_tuple tuples[VX_NDB_MAX_TUPLES];
  int count;
  size_t line; // where the record starts, 1-based
} vx_ndb_record;

// Decoded quoted and hex values are written to scratch, which the caller owns.
// Values point into the source or into scratch, so both must outlive them.
typedef struct vx_ndb_reader {
  vx_str src;
  size_t pos;
  size_t line;
  char *scratch;
  size_t scratch_cap;
  size_t scratch_used;
  const char *error; // set when vx_ndb_next returns VX_NDB_ERROR,
  size_t error_line; // with the line it refers to
} vx_ndb_reader;

typedef enum vx_ndb_result : int32_t {
  VX_NDB_RECORD = 0,
  VX_NDB_END = 1,
  VX_NDB_ERROR = -1,
} vx_ndb_result;

// Reads the next record into rec. At the end of the input, and on an error,
// rec is left empty.
[[maybe_unused]] static vx_ndb_result vx_ndb_next(vx_ndb_reader *r, vx_ndb_record *rec);

// The library is compiled into each component that includes it (unity builds), so
// its API is marked maybe_unused.

// The value of key, or a zero vx_str if the record lacks it. A flag gives a
// zero-length value with a nullptr pointer, so test vx_ndb_has for flags.
[[maybe_unused]] static vx_str vx_ndb_get(const vx_ndb_record *rec, const char *key);
[[maybe_unused]] static bool vx_ndb_has(const vx_ndb_record *rec, const char *key);

// A record being written into a caller's buffer. Writing past the end, or a
// key that could not be read back, sets `failed`, and the record must not be
// used; nothing is ever written that would read back differently.
typedef struct vx_ndb_writer {
  char *buf;
  size_t cap, len;
  bool failed;
} vx_ndb_writer;

// key=value, in whichever form the value needs.
[[maybe_unused]] static void vx_ndb_put(vx_ndb_writer *w, const char *key, vx_str value);
[[maybe_unused]] static void vx_ndb_put_u64(vx_ndb_writer *w, const char *key, uint64_t value);
[[maybe_unused]] static void vx_ndb_put_i64(vx_ndb_writer *w, const char *key, int64_t value);
// A bare key: a flag that is set.
[[maybe_unused]] static void vx_ndb_flag(vx_ndb_writer *w, const char *key);
// Ends the record with a newline. Returns false if the record failed.
[[maybe_unused]] static bool vx_ndb_end(vx_ndb_writer *w);
