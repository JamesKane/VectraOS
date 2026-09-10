/*
What the self-tests share, and nothing else does.

A counter a worker moves and the boot thread reads is volatile in every
self-test. Five files carried the same two lines under four names.
*/
package kernel

import "base:intrinsics"

// bump adds one to a counter another thread reads. Volatile, so the
// compiler keeps every load and store. Not atomic, on purpose: the counters
// this serves have one writer at a time, or a reader that tolerates a lost
// increment.
bump :: proc "contextless" (p: ^int) {
	intrinsics.volatile_store(p, intrinsics.volatile_load(p) + 1)
}

// unbump takes one off, the same way.
unbump :: proc "contextless" (p: ^int) {
	intrinsics.volatile_store(p, intrinsics.volatile_load(p) - 1)
}
