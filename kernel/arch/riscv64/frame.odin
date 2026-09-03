/*
What the portable kernel may read out of a trap frame, and what it may put in.

The same five questions `amd64/frame.odin` answers, for this register file. A
program's system call arrives with the number in `a7` and the arguments in
`a0` to `a5`, and the answer goes back in `a0`. `sys/libuser/sys_riscv64.odin`
is the other side of that agreement.
*/
package riscv64

// Register numbers, for the frame's array.
REG_RA :: 1
REG_SP :: 2
REG_TP :: 4
REG_A0 :: 10
REG_A7 :: 17

frame_ip :: proc "contextless" (f: ^Trap_Frame) -> uintptr {
	return uintptr(f.sepc)
}

frame_sp :: proc "contextless" (f: ^Trap_Frame) -> uintptr {
	return uintptr(f.x[REG_SP])
}

frame_vector :: proc "contextless" (f: ^Trap_Frame) -> u64 {
	return f.vector
}

syscall_request :: proc "contextless" (f: ^Trap_Frame) -> (number: u64, args: [6]u64) {
	return f.x[REG_A7], {f.x[REG_A0], f.x[REG_A0 + 1], f.x[REG_A0 + 2], f.x[REG_A0 + 3], f.x[REG_A0 + 4], f.x[REG_A0 + 5]}
}

set_syscall_result :: proc "contextless" (f: ^Trap_Frame, result: i64) {
	f.x[REG_A0] = u64(result)
}

syscall_result :: proc "contextless" (f: ^Trap_Frame) -> i64 {
	return i64(f.x[REG_A0])
}

frame_call_handler :: proc "contextless" (f: ^Trap_Frame, handler, sp, arg0, arg1: uintptr) {
	f.sepc = u64(handler)
	f.x[REG_SP] = u64(sp)
	f.x[REG_A0] = u64(arg0)
	f.x[REG_A0 + 1] = u64(arg1)
}

// frame_sanitise_user rebuilds the status a program handed back: user mode,
// interrupts on after the return, the float unit as it was.
frame_sanitise_user :: proc "contextless" (f: ^Trap_Frame) {
	f.sstatus = SSTATUS_USER
}
