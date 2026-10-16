// Ports and object_bind: the ABI shared by the kernel and user space
// (user/include/croi/syscall.h includes it). VectraOS's, not Zircon's:
// object_bind replaced object_wait_async, interrupt_bind,
// counter_wait_async, thread_bind_overrun_port and
// account_bind_pressure_port (docs/syscall-audit.md, D20).
//
// object_bind(port, croi_bind_item_t *items, count) binds up to
// CROI_BIND_MAX_ITEMS event sources to a port with WRITE, in order. It stops
// at the first item that fails, and returns how many succeeded; each item
// it processed has its status written back. A bad port, pointer or count
// fails the whole call (a negative status) before anything is bound.
//
// port_cancel(port, source, key) undoes a binding of any kind. Closing the
// handle a SIGNALS, VALUE or CHANGE binding was made through also does.
//
// port_queue(port, const croi_port_packet_t *packets, count) (D40) queues
// up to CROI_PORT_MAX_PACKETS user packets, in order, stopping at the
// first that can't be (SHOULD_WAIT: the port holds too many). It returns
// how many it queued, or the first packet's status if that one failed.
//
// port_wait(port, deadline, croi_port_packet_t *packets, count, leeway)
// (D40): up to `count` packets (at most CROI_PORT_MAX_PACKETS), returning
// how many; it waits only while the port is empty, and returns TIMED_OUT
// if it still is at the deadline. The wait may end up to `leeway` ns
// after the deadline, never before it (principle 10), so that timers
// coalesce; a thread with a deadline profile always gets zero leeway. A
// wait on a port nothing is bound to is the one sleep (V1 cut nanosleep
// and timer objects, D25). croi_port_queue and croi_port_wait in syscall.h
// take one packet.
//
// Ports as rings (D19, D44). port_create(CROI_PORT_RING, uint32_t out[2])
// makes a port whose packets the kernel writes into the one ring
// (lib/ring/ring.h): out[0] is the port, out[1] its ring's VMO (READ,
// WRITE, MAP; one page, CROI_PORT_RING_SLOTS slots of croi_port_packet_t,
// format CROI_PORT_RING_FORMAT). The reader maps it read-write, attaches
// as the consumer and drains it with no syscall; packets the ring has no
// room for wait in the port, and go in as the reader frees slots (at the
// next packet, or port_wait). port_wait(port, deadline, nullptr, 0,
// leeway) is the reader's sleep: it returns 0 once the ring isn't empty,
// and BAD_STATE once the reader has broken it. A ring port refuses
// port_wait with a count; any other port refuses a count of 0. A packet
// in the ring is the reader's: port_cancel no longer reaches it.
#pragma once
#include <stdint.h>

enum : uint32_t {
  // croi_bind_item_t.options: one kind...
  CROI_BIND_SIGNALS = 0,    // trigger: signals. ONCE: one packet when any is asserted (Zircon's
                            // wait_async). PERSISTENT: a packet each time one rises (EDGE: not
                            // for one already set at binding), coalesced while it waits to be read (payload[1] counts);
                            // the reader drains until the object would block.
  CROI_BIND_VALUE = 1,      // a counter, ONCE: trigger is the value (int64) to reach (a fence)
  CROI_BIND_CHANGE = 2,     // a counter, PERSISTENT: every add (a ring's doorbell)
  CROI_BIND_INTERRUPT = 3,  // an interrupt, PERSISTENT; the port made with CROI_PORT_BIND_TO_INTERRUPT
  CROI_BIND_OVERRUN = 4,    // a thread or interrupt with a deadline profile, PERSISTENT
  CROI_BIND_PRESSURE = 5,   // a memory account, PERSISTENT
  CROI_BIND_KIND_MASK = 0xff,
  // ...and flags. CHANGE, INTERRUPT, OVERRUN and PRESSURE need PERSISTENT
  // and a trigger of 0; VALUE refuses it.
  CROI_BIND_PERSISTENT = 1u << 8,
  CROI_BIND_EDGE = 1u << 9,       // SIGNALS: not at once if one is already asserted
  CROI_BIND_TIMESTAMP = 1u << 10, // SIGNALS: payload[2] is the time of the event

  CROI_BIND_MAX_ITEMS = 64,
  CROI_PORT_MAX_PACKETS = 64,  // port_queue and port_wait at once (D40)
  CROI_PORT_RING = 1u << 1,    // port_create: deliver into a ring (D44)
  CROI_PORT_RING_SLOTS = 64,   // its packets: 384 + 64 * 48 bytes, one page

  // Port packet types (croi_port_packet_t.type). The kernel events' are in
  // their headers: CROI_PKT_TYPE_INTERRUPT, _COUNTER, _BUDGET_OVERRUN,
  // _MEMORY_PRESSURE, _PAGE_REQUEST.
  CROI_PKT_TYPE_USER = 0,    // port_queue's
  CROI_PKT_TYPE_SIGNAL = 1,  // SIGNALS: payload[0] trigger | observed << 32, [1] count, [2] time
  CROI_PKT_TYPE_COUNTER_CHANGE = 0x83,  // CHANGE: [1] the value, [2] count, [3] time
};

enum : uint64_t {
  CROI_PORT_RING_FORMAT = 0x54524f50,  // "PORT": a ring of croi_port_packet_t (D44)
};

typedef struct {
  uint32_t handle;    // the event source
  uint32_t options;   // a kind | flags
  uint64_t key;       // the packets' key
  uint64_t trigger;   // SIGNALS: the signals; VALUE: the value; else 0
  int32_t status;     // out: 0, or why this item failed
  uint32_t reserved;  // 0
} croi_bind_item_t;

// A packet (Zircon's zx_port_packet_t): what port_queue takes and
// port_wait and a ring port deliver. The kernel events' payloads are in
// their headers.
typedef struct {
  uint64_t key;
  uint32_t type;
  int32_t status;
  uint64_t payload[4];  // signal packets: trigger | observed << 32, count, timestamp
} croi_port_packet_t;

static_assert(sizeof(croi_port_packet_t) == 48);
