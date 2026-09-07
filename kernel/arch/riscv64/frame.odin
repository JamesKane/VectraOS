/*
What the portable kernel may read out of a trap frame, and what it may put in.

The same five questions `amd64/frame.odin` answers, for this register file. A
program's system call arrives with the number in `a7` and the arguments in
`a0` to `a5`, and the answer goes back in `a0`. `sys/libuser/sys_riscv64.odin`
is the other side of that agreement.
*/
package riscv64

import "kernel:arch/neutral"

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

/*
The debugger's questions of a frame, as `amd64/frame.odin` answers them.

`HAS_STEP` is false: the base architecture has no single step, and
`docs/DEVTOOLS.md` section 5 steps this port with a breakpoint on the next
instruction instead. `frame_set_step` is therefore nothing here, and
`/proc/n/ctl` answers `step` with EOPNOTSUPP.
*/
HAS_STEP :: false
FRAME_REGS_SIZE :: size_of(Trap_Frame)

frame_set_step :: proc "contextless" (f: ^Trap_Frame, on: bool) {
	_, _ = f, on
}

// frame_set_ip moves where the frame resumes, for a `regs` write that a
// self-test makes from the kernel side.
frame_set_ip :: proc "contextless" (f: ^Trap_Frame, ip: uintptr) {
	f.sepc = u64(ip)
}

// sync_text makes instructions written through `/proc/n/mem` visible to
// this hart's fetch: `fence.i`. Another hart that runs them fetches through
// its own cache, which QEMU does not model and a board driver's `sfence`
// hook will.
sync_text :: proc "contextless" (at: rawptr, n: int) {
	_, _ = at, n
	asm() [#volatile, #clobber memory] { #byte 0x0F, 0x10, 0x00, 0x00 }()
}

// The breakpoint a debugger writes through `mem`, and how far past it the
// trap leaves the program counter. The four-byte `ebreak`, because the
// trap entry steps `sepc` past a four-byte instruction, for its own
// `ebreak` and a program's alike. The hart itself leaves the counter on it.
BREAKPOINT_CODE :: [4]u8{0x73, 0x00, 0x10, 0x00}
BREAKPOINT_ADVANCE :: 4

// fpu_image_sanitise rebuilds what a program must not choose in a float
// image a debugger wrote. Nothing here is reserved.
fpu_image_sanitise :: proc "contextless" (area: rawptr) {
	_ = area
}

// What the CPU said about a fault, in `kernel/arch/neutral`'s words: the
// cause says fetch, read or write, and the mode says who. Whether the page
// was there is the VMM's to answer, and `kernel/user` asks it.
Fault_Bit :: neutral.Fault_Bit
Fault_Bits :: neutral.Fault_Bits

fault_bits :: proc "contextless" (kind: Trap_Kind, vector: u64, code: u64, user: bool) -> Fault_Bits {
	_ = code
	bits: Fault_Bits
	if kind != .Page_Fault {
		return bits
	}
	if user {
		bits += {.User}
	}
	switch vector {
	case CAUSE_INSN_PAGE:  bits += {.Fetch}
	case CAUSE_STORE_PAGE: bits += {.Write}
	}
	return bits
}
