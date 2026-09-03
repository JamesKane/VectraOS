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

/*
What the CPU said about a fault, in words the self-test can compare across
architectures. The cause says fetch, read or write. It does not say whether
the page was there -- a missing page and a refused one raise the same
cause -- so the dispatcher walks the tables the hart was translating
through at the time and leaves the answer in the code's top bit, above any
address `stval` can hold.
*/

FAULT_PRESENT :: u64(1) << 63
Fault_Bit :: enum {
	Present,
	Write,
	User,
	Fetch,
}

Fault_Bits :: bit_set[Fault_Bit]

fault_bits :: proc "contextless" (kind: Trap_Kind, vector: u64, code: u64, user: bool) -> Fault_Bits {
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
	if code & FAULT_PRESENT != 0 {
		bits += {.Present}
	}
	return bits
}

// mapped walks the current tables for `virt` and reports whether a leaf
// covers it. Through the direct map, whose offset `serial_console` kept.
mapped :: proc "contextless" (virt: uintptr) -> bool #no_bounds_check {
	if hhdm_offset() == 0 || !is_canonical(virt) {
		return false
	}
	table := (^Page_Table)(uintptr(hhdm_offset()) + current_address_space())
	for level := TABLE_LEVELS; level >= 1; level -= 1 {
		e := table[table_index(virt, level)]
		if !entry_present(e) {
			return false
		}
		if entry_is_leaf(e, level) {
			return true
		}
		table = (^Page_Table)(uintptr(hhdm_offset()) + entry_address(e))
	}
	return false
}
