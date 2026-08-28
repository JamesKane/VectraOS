/*
The system call ABI -- the one file both sides of the door include.

Until this package, the call numbers lived in `kernel/user/syscall.odin` and
every program in ring 3 wrote them again as immediates. That was the honest
arrangement while every program was assembler. An assembler consumes one
copy at build time and Odin the other at run time, and nothing can share
them.

An Odin program in ring 3 ends that excuse. The kernel's dispatcher and the
userland library now read the same constants from here, so the two sides of
a system call cannot drift apart. The assembler blobs still carry their own
immediates, with the same defence as always: the checks fail loudly when a
number moves.

What belongs here is exactly what crosses the door: call numbers, the flag
words calls take, and the packings calls answer with. What does not belong
here is behaviour. This package imports nothing and decides nothing.
*/
package abi

SYS_NOP :: u64(0)
SYS_ARGS :: u64(1)
SYS_WRITE :: u64(2)
SYS_SLEEP :: u64(3)
SYS_EXIT :: u64(4)
SYS_OPEN :: u64(5)
SYS_CLOSE :: u64(6)
SYS_READ :: u64(7)
SYS_BIND :: u64(8)
SYS_SEEK :: u64(9)
SYS_SPAWN :: u64(10)
SYS_WAIT :: u64(11)
SYS_CREATE :: u64(12)
SYS_MOUNT :: u64(13)
SYS_REMOVE :: u64(14)
SYS_PIPE :: u64(15)

// The open flags `open` and `create` take, as 9P2000.L carries them.
O_RDONLY :: u64(0)
O_WRONLY :: u64(1)
O_RDWR :: u64(2)

// What `bind` and `mount` mean by their order argument. Any other value is
// Replace, which the kernel decides rather than this file.
ORDER_REPLACE :: u64(0)
ORDER_BEFORE :: u64(1)
ORDER_AFTER :: u64(2)

// What a child may inherit, as bits `spawn` takes. Zero shares the namespace
// and copies the descriptors, which is Plan 9's default and Vectra's.
SPAWN_NS_COPY :: u64(1)
SPAWN_NS_CLEAN :: u64(2)
SPAWN_FD_CLEAN :: u64(4)

// How `pipe` packs its two descriptors into one answer: end 0 in the low
// byte, end 1 in the next. A descriptor table holds sixteen, so a byte is
// roomy.
pipe_ends :: proc "contextless" (packed: i64) -> (end0: int, end1: int) {
	return int(packed & 0xFF), int(packed >> 8 & 0xFF)
}
