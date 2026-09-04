#+build riscv64
package libthread

/*
A thread's saved state on riscv64, in the order `thread_riscv64.S` stores
it: s0..s11, the return address, the stack pointer, and fs0..fs11.

A new thread's label names `thread_launch` as its return address, so the
first switch into it returns there. s0 is the frame pointer and starts at
zero, so a backtrace from a thread ends at its first procedure.
*/
Label :: struct {
	s:  [12]u64,
	ra: u64,
	sp: u64,
	fs: [12]u64,
}

label_init :: proc "contextless" (l: ^Label, stack: []u8, entry: rawptr) {
	l^ = {}
	l.sp = u64(stack_top(stack))
	l.ra = u64(uintptr(entry))
}
