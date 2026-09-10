/*
What the portable kernel may read out of a trap frame, and what it may put in.

The same five questions `amd64/frame.odin` answers, for this register file. A
program's system call arrives with the number in `x8` and the arguments in
`x0` to `x5`, and the answer goes back in `x0`. `sys/libuser/sys_arm64.odin`
is the other side of that agreement.
*/
package arm64

import "kernel:arch/neutral"

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

/*
The debugger's questions of a frame, as `amd64/frame.odin` answers them.

`HAS_STEP` is false for now. A software step here is `PSTATE.SS` in the
saved frame *and* `MDSCR_EL1.SS` on the core that returns to it. The second
is a per-core register, and the scheduler would have to set it on every
switch to a stepping thread. `frame_set_step` sets the frame's half so the
day the scheduler learns the other, the door is already cut. Until then
`/proc/n/ctl` answers `step` with EOPNOTSUPP on this architecture.
*/
HAS_STEP :: false
FRAME_REGS_SIZE :: size_of(Trap_Frame)

frame_set_step :: proc "contextless" (f: ^Trap_Frame, on: bool) {
	if on {
		f.spsr |= 1 << 21
	} else {
		f.spsr &= ~u64(1 << 21)
	}
}

// frame_set_ip moves where the frame resumes, for a `regs` write that a
// self-test makes from the kernel side.
frame_set_ip :: proc "contextless" (f: ^Trap_Frame, ip: uintptr) {
	f.elr = u64(ip)
}

// The breakpoint a debugger writes through `mem`, and how far past it the
// trap leaves the program counter. `brk #0`, and the counter stays on it.
BREAKPOINT_CODE :: [4]u8{0x00, 0x00, 0x20, 0xD4}
BREAKPOINT_ADVANCE :: 0

// fpu_image_sanitise rebuilds what a program must not choose in a vector
// image a debugger wrote. Nothing in the image is reserved.
fpu_image_sanitise :: proc "contextless" (area: rawptr) {
	_ = area
}

// sync_text makes instructions written through `/proc/n/mem` visible to
// the instruction side. It cleans the data cache to the point of unification
// and invalidates the instruction cache, a line at a time, at the address
// the kernel wrote. `dc cvau`, `dsb ish`, `ic ivau`, `isb`.
sync_text :: proc "contextless" (at: rawptr, n: int) {
	line := uintptr(64)
	first := uintptr(at) & ~(line - 1)
	last := (uintptr(at) + uintptr(max(n, 1)) - 1) & ~(line - 1)
	for va := first; va <= last; va += line {
		_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x20, 0x7B, 0x0B, 0xD5 }(u64(va))
	}
	dsb_ish()
	for va := first; va <= last; va += line {
		_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x20, 0x75, 0x0B, 0xD5 }(u64(va))
	}
	dsb_ish()
	isb()
}

// What the CPU said about a fault, in `kernel/arch/neutral`'s words: the
// write bit is an abort's WnR, and the fetch is the exception class itself.
Fault_Bit :: neutral.Fault_Bit
Fault_Bits :: neutral.Fault_Bits

fault_bits :: proc "contextless" (kind: Trap_Kind, vector: u64, code: u64, user: bool) -> Fault_Bits {
	bits: Fault_Bits
	if kind != .Page_Fault {
		return bits
	}
	if user {
		bits += {.User}
	}
	switch vector {
	case EC_IABORT, EC_IABORT_LOWER:
		bits += {.Fetch}
	case EC_DABORT, EC_DABORT_LOWER:
		if code & (1 << 6) != 0 {
			bits += {.Write}
		}
	}
	return bits
}
