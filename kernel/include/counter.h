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
