/*
The door a program knocks on, which on this architecture is the trap entry.

`ecall` from user mode is a trap like any other: it lands on `stvec` with
interrupts masked, and the entry finds the kernel stack through `sscratch`.
There is no instruction to arm and no register holding a second entry, so
what amd64 checks about its door is either always true here or answered by
the one table.
*/
package riscv64

syscall_available :: proc "contextless" () -> bool {
	return true
}

syscall_init :: proc "contextless" () -> bool {
	return true
}

syscall_armed :: proc "contextless" () -> bool {
	return read_stvec() == u64(uintptr(&vectra_vectors))
}

syscall_masks_interrupts :: proc "contextless" () -> bool {
	return true
}

syscall_entry_address :: proc "contextless" () -> uintptr {
	return uintptr(&vectra_vectors)
}
