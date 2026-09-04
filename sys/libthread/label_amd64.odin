#+build amd64
package libthread

/*
A thread's saved state on amd64: the six callee-saved registers and the
stack pointer, in the order `thread_amd64.S` stores them.

A new thread's label points at a stack whose top word is the address of
`thread_launch`. The first switch into it returns there, which is how a
thread starts without a special case in the switch. The stack pointer
sits where a `call` would have left it, eight below a sixteen-byte
boundary. That is what every compiled procedure assumes on entry.
*/
Label :: struct {
	rbx, rbp, r12, r13, r14, r15: u64,
	rsp:                          u64,
}

label_init :: proc "contextless" (l: ^Label, stack: []u8, entry: rawptr) {
	top := stack_top(stack)
	sp := top - 16
	(^uintptr)(sp)^ = uintptr(entry)
	(^uintptr)(sp + 8)^ = 0
	l^ = {}
	l.rsp = u64(sp)
}
