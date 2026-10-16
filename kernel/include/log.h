// The debuglog (K8a; a ring since D38): the ABI shared by the kernel and
// user space (user/include/croi/syscall.h includes it). Zircon's record
// layout and values (zircon/syscalls/log.h); the ring is croi's.
#pragma once
#include <stdint.h>

enum : uint32_t {
  CROI_LOG_RECORD_MAX = 256,      // a whole record, header included: one ring slot
  CROI_LOG_RECORD_DATA_MAX = 216, // CROI_LOG_RECORD_MAX less the header
  // debuglog_write options (stored in the record's flags).
  CROI_LOG_LOCAL = 0x10,
  CROI_LOG_FLAGS_MASK = 0x10,
  // Severities.
  CROI_LOG_TRACE = 0x10,
  CROI_LOG_DEBUG = 0x20,
  CROI_LOG_INFO = 0x30,
  CROI_LOG_WARNING = 0x40,
  CROI_LOG_ERROR = 0x50,
  CROI_LOG_FATAL = 0x60,
  // The ring (D38): the one ring (lib/ring/ring.h) in OVERWRITE mode, of
  // CROI_LOG_RING_SLOTS slots of CROI_LOG_RECORD_MAX bytes, each a record.
  // Readers map it read only (CROI_PA_VMO_DEBUGLOG) and keep their own
  // cursors; its counter (CROI_PA_DEBUGLOG_COUNTER) holds the producer
  // cursor, so a caught-up reader binds VALUE at its cursor plus one.
  CROI_LOG_RING_SLOTS = 512,
};

enum : uint64_t {
  CROI_LOG_RING_FORMAT = 0x474f4c44,  // "DLOG": the ring's format descriptor
};

// zx_log_record_t: a ring slot (header, then datalen bytes of text, no
// terminator; zeros to the slot's end). The sequence is the ring's.
typedef struct {
  uint64_t sequence;   // one more than the record before it
  uint8_t padding1[4];
  uint16_t datalen;
  uint8_t severity;
  uint8_t flags;
  int64_t timestamp;   // monotonic ns
  uint64_t pid;        // the writer's process koid (0: the kernel)
  uint64_t tid;        // and thread koid
} croi_log_record_t;

static_assert(sizeof(croi_log_record_t) + CROI_LOG_RECORD_DATA_MAX == CROI_LOG_RECORD_MAX);

// object_get_info(log, CROI_INFO_DEBUGLOG) (croi's, K10d; any log handle):
// how far the console dumper has got, for writers that pace themselves to
// it (a trace export through the debuglog). Records are numbered from 0
// in write order; `printed` counts those the dumper has finished with
// (printed, or overwritten before it got to them).
enum : uint32_t {
  CROI_INFO_DEBUGLOG = 0x10002,
};

typedef struct {
  uint64_t written;  // records written so far (the next record's number)
  uint64_t printed;
} croi_info_debuglog_t;

static_assert(sizeof(croi_info_debuglog_t) == 16);
