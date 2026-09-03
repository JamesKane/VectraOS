/*
What the portable kernel may read out of a trap frame, and what it may put in.

The same five questions `amd64/frame.odin` answers, for this register file. A
program's system call arrives with the number in `x8` and the arguments in
`x0` to `x5`, and the answer goes back in `x0`. `sys/libuser/sys_arm64.odin`
is the other side of that agreement.
*/
package arm64

frame_ip :: proc "contextless" (f: ^Trap_Frame) -> uintptr {
	return uintptr(f.elr)
}

frame_sp :: proc "contextless" (f: ^Trap_Frame) -> uintptr {
	return uintptr(f.sp)
}

frame_vector :: proc "contextless" (f: ^Trap_Frame) -> u64 {
	return f.vector
}

syscall_request :: proc "contextless" (f: ^Trap_Frame) -> (number: u64, args: [6]u64) {
	return f.x[8], {f.x[0], f.x[1], f.x[2], f.x[3], f.x[4], f.x[5]}
}

set_syscall_result :: proc "contextless" (f: ^Trap_Frame, result: i64) {
	f.x[0] = u64(result)
}

syscall_result :: proc "contextless" (f: ^Trap_Frame) -> i64 {
	return i64(f.x[0])
}

// frame_call_handler redirects a program's frame into a handler of its own:
// the next return to EL0 lands at `handler` on `sp` with two arguments.
frame_call_handler :: proc "contextless" (f: ^Trap_Frame, handler, sp, arg0, arg1: uintptr) {
	f.elr = u64(handler)
	f.sp = u64(sp)
	f.x[0] = u64(arg0)
	f.x[1] = u64(arg1)
}

// frame_sanitise_user rebuilds the PSTATE a program handed back: EL0, IRQs
// unmasked, and nothing else a program could have set.
frame_sanitise_user :: proc "contextless" (f: ^Trap_Frame) {
	f.spsr = SPSR_EL0
}
