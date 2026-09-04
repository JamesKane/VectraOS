#+build arm64
package libthread

/*
A thread's saved state on arm64, in the order `thread_arm64.S` stores it.
That is x19..x28, the frame pointer, the link register, the stack pointer,
and the low halves of d8..d15.

A new thread's label names `thread_launch` as its link register, so the
first switch into it returns there. The frame pointer is zero, so a
backtrace from a thread ends at its first procedure.
*/
Label :: struct {
	x:  [12]u64, // x19..x28, then x29 and x30
	sp: u64,
	d:  [8]u64,
}

label_init :: proc "contextless" (l: ^Label, stack: []u8, entry: rawptr) {
	l^ = {}
	l.sp = u64(stack_top(stack))
	l.x[11] = u64(uintptr(entry))
}
