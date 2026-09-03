/*
What the portable kernel may read out of a trap frame, and what it may put in.

`Trap_Frame` is this architecture's register file, laid out the way the entry
stubs push it. Nothing outside `kernel/arch` names a register in it. A program's
system call arrives in `rax` and `rdi` here and in `x8` and `x0` on arm64, and
`kernel/user` has to dispatch the same call on both. So the accessors below are
the frame's whole public face: where the interrupted code was, what it asked
for, what to answer, and the two rewrites a note delivery needs.
*/
package amd64

// frame_ip and frame_sp are where the interrupted code was, and what stack it
// stood on. What a process record keeps when a program ends.
frame_ip :: proc "contextless" (f: ^Trap_Frame) -> uintptr {
	return uintptr(f.rip)
}

frame_sp :: proc "contextless" (f: ^Trap_Frame) -> uintptr {
	return uintptr(f.rsp)
}

// frame_vector is the number the frame arrived on. `VECTOR_SYSCALL` for a
// frame the door built, a fault's vector otherwise.
frame_vector :: proc "contextless" (f: ^Trap_Frame) -> u64 {
	return f.vector
}

/*
syscall_request reads the call a program made out of its frame.

The System V syscall convention: the number in `rax`, the arguments in `rdi`,
`rsi`, `rdx`, `r10`, `r8` and `r9`. Six, because that is how many the
convention has, and the sixth reaches only the self-test that adds them all up.
`sys/libuser/sys_amd64.odin` is the other half of this agreement.
*/
syscall_request :: proc "contextless" (f: ^Trap_Frame) -> (number: u64, args: [6]u64) {
	return f.rax, {f.rdi, f.rsi, f.rdx, f.r10, f.r8, f.r9}
}

// set_syscall_result writes the answer the pops at the end of the entry stub
// deliver back to the program, and syscall_result reads it back.
set_syscall_result :: proc "contextless" (f: ^Trap_Frame, result: i64) {
	f.rax = u64(result)
}

syscall_result :: proc "contextless" (f: ^Trap_Frame) -> i64 {
	return i64(f.rax)
}

/*
frame_call_handler redirects a program's frame into a handler of its own.

The next return to ring 3 lands at `handler`, on the stack `sp`, with `arg0`
and `arg1` in the first two argument registers. Everything else stays as the
program left it, because the handler is expected to hand the frame back
through `noted`, and what it hands back is what the program had.
*/
frame_call_handler :: proc "contextless" (f: ^Trap_Frame, handler, sp, arg0, arg1: uintptr) {
	f.rip = u64(handler)
	f.rsp = u64(sp)
	f.rdi = u64(arg0)
	f.rsi = u64(arg1)
}

/*
frame_sanitise_user rebuilds the parts of a frame a program must not choose.

A frame a program handed back through `noted` was bytes on its stack, and the
program could write anything there. The selectors come from the kernel's own
constants. The flags keep only the arithmetic bits a program owns: IF stays
on, because a program that could resume with interrupts masked would own the
machine, and IOPL stays zero. `iretq` would fault on a bad CS anyway, but a
check that leans on the hardware refusing fails elsewhere, later, with less to
say.
*/
frame_sanitise_user :: proc "contextless" (f: ^Trap_Frame) {
	f.cs = u64(USER_CODE_RING3)
	f.ss = u64(USER_DATA_RING3)
	f.rflags = f.rflags & 0x0000_0000_0000_0CD5 | 0x202
}

/*
What the CPU said about a fault, in words the self-test can compare across
architectures. amd64's page fault error code carries all four bits; a
protection fault carries a selector, which is none of them.
*/
Fault_Bit :: enum {
	Present, // The page was mapped, and refused the access
	Write,
	User,
	Fetch,
}

Fault_Bits :: bit_set[Fault_Bit]

fault_bits :: proc "contextless" (kind: Trap_Kind, vector: u64, code: u64, user: bool) -> Fault_Bits {
	_, _ = vector, user
	bits: Fault_Bits
	if kind != .Page_Fault {
		return bits
	}
	if code & 1 != 0 {
		bits += {.Present}
	}
	if code & 2 != 0 {
		bits += {.Write}
	}
	if code & 4 != 0 {
		bits += {.User}
	}
	if code & 16 != 0 {
		bits += {.Fetch}
	}
	return bits
}
