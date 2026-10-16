// Counters (K10a): the ABI shared by the kernel and user space
// (user/include/croi/syscall.h includes it). Zircon's counter object (type
// 34: counter_create, add, read; the POSITIVE / NON_POSITIVE signals;
// default rights BASIC | READ | WRITE | SIGNAL) plus croi's extension,
// Todhchai's item 15: waiting until a counter reaches a value. V1 cut
// counter_write (an add of the difference) and counter_wait (D25).
//
// object_bind VALUE (port.h) queues one CROI_PKT_TYPE_COUNTER packet once
// the counter's value is at least the trigger (signed; at once if it
// already is); port_cancel(port, counter, key) or closing the handle it
// was bound through drops it. object_bind CHANGE is the doorbell: a
// CROI_PKT_TYPE_COUNTER_CHANGE packet at every add. A counter with a
// deadline profile (profile.h) lends it to the thread each packet wakes.
// Both need WAIT and READ (the result reveals the value, as add's does). These
// are the desktop's acquire fences and release values, and Vulkan's
// timeline semaphores later: counters used that way only grow.
#pragma once
#include <stdint.h>

enum : uint32_t {
  CROI_COUNTER_POSITIVE = 1u << 4,      // value > 0
  CROI_COUNTER_NON_POSITIVE = 1u << 5,  // value <= 0

  // Port packet type: payload[0] the value waited for, [1] the counter's
  // value when it was reached, [2] the time (ns).
  CROI_PKT_TYPE_COUNTER = 0x82,
};

// counter_add(croi_counter_add_item_t *items, count) (D40) adds each
// item's amount to its counter (READ and WRITE). It goes on past an item
// that fails, writing each item's status back (OUT_OF_RANGE, unchanged,
// on overflow), and returns how many succeeded: a service ringing every
// client's doorbell rings the rest when one client has gone. A bad
// pointer or count fails the whole call (a negative status) before any
// add. croi_counter_add in syscall.h is the one-counter form.
enum : uint32_t { CROI_COUNTER_ADD_MAX_ITEMS = 64 };

typedef struct {
  uint32_t counter;  // the counter's handle
  int32_t status;    // out: 0, or why this item failed
  int64_t amount;
} croi_counter_add_item_t;

_Static_assert(sizeof(croi_counter_add_item_t) == 16);
