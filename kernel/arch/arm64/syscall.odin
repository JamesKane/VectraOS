/*
The door a program knocks on, which on this architecture is not a separate
door.

`svc` from EL0 is a synchronous exception like any other: it takes the
kernel stack from SP_EL1, masks IRQs, and lands on the vector table. The
trap dispatcher recognises the class and calls `vectra_syscall_dispatch`
with the frame, with IRQs open. There is no instruction to arm, no register
holding the entry, and no window on a program's stack. What amd64 checks
about its `syscall` here is either always true or does not apply, and the
answers below say which.
*/
package arm64

syscall_available :: proc "contextless" () -> bool {
	return true
}

// syscall_init has nothing to arm. The vector table is the door.
syscall_init :: proc "contextless" () -> bool {
	return true
}

// syscall_armed reports whether the table a program's `svc` will reach is
// the kernel's.
syscall_armed :: proc "contextless" () -> bool {
	return read_vbar() == u64(uintptr(&vectra_vectors))
}

// An exception masks IRQs on entry, architecturally. Nothing lands on the
// program's stack in any case, because the exception takes SP_EL1.
syscall_masks_interrupts :: proc "contextless" () -> bool {
	return true
}

syscall_entry_address :: proc "contextless" () -> uintptr {
	return uintptr(&vectra_vectors)
}
