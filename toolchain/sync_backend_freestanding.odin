#+build freestanding
package sync

// Freestanding backend for `core:sync`.
//
// `core:crypto/x509` imports `core:sync` transitively, and `core:sync`'s futex
// and thread-id primitives are per-OS. Freestanding has no backend, so those
// symbols are undeclared and x509 will not compile for Vectra's targets.
//
// A ring 3 program that verifies a certificate never contends a futex or reads
// a thread id, so these stubs are never reached on the crypto path. They exist
// only to satisfy the linker. `_current_thread_id` returns 0 (there is one
// thread of interest here), and the futex operations behave as if the wait
// condition already changed: a wait returns immediately, a wake is a no-op.
//
// `build.odin` copies this file into `<odin-root>/core/sync/` before it
// compiles. The source of truth is `toolchain/` in the Vectra tree.

import "core:time"

@(private)
_current_thread_id :: proc "contextless" () -> int {
	return 0
}

@(private)
_futex_wait :: proc "contextless" (futex: ^Futex, expected: u32) -> bool {
	return true
}

@(private)
_futex_wait_with_timeout :: proc "contextless" (futex: ^Futex, expected: u32, duration: time.Duration) -> bool {
	return true
}

@(private)
_futex_signal :: proc "contextless" (futex: ^Futex) {}

@(private)
_futex_broadcast :: proc "contextless" (futex: ^Futex) {}
