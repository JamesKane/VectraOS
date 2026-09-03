/*
Per-CPU state, and the register that finds it.

`tp` is the thread pointer, which the ABI reserves and compiled code never
touches, because `-no-thread-local` leaves nothing for it to point at. It
holds this hart's record while the kernel runs. While a program runs it is
the program's, and `sscratch` holds the record instead; the trap entry in
`vectors.S` swaps the two, which is the one place either is read by
assembly. `kernel_sp` and `user_sp` are at the offsets that entry uses.
*/
package riscv64

Percpu :: struct {
	self:            u64, // 0
	kernel_sp:       u64, // 8: where a trap from a program lands
	user_sp:         u64, // 16: the program's sp, held for a moment on entry
	cpu_id:          u64,
	interrupt_depth: i64,
	critical_depth:  i64,
	hart:            u64, // The hart id, which the firmware names harts by
	irq:             u32, // The PLIC source this hart is servicing, or zero
}

PERCPU_SELF :: 0
PERCPU_KERNEL_SP :: 8
PERCPU_USER_SP :: 16

#assert(offset_of(Percpu, self) == PERCPU_SELF)
#assert(offset_of(Percpu, kernel_sp) == PERCPU_KERNEL_SP)
#assert(offset_of(Percpu, user_sp) == PERCPU_USER_SP)

PERCPU_MAX :: 8

@(private = "file")
percpu: [PERCPU_MAX]Percpu

@(private = "file")
ready: bool

// percpu_init points this hart's `tp` at its own record, and clears
// `sscratch` to say the kernel is running.
percpu_init :: proc "contextless" (id: int, hart: u64) #no_bounds_check {
	if id < 0 || id >= PERCPU_MAX {
		return
	}
	p := &percpu[id]
	p.self = u64(uintptr(p))
	p.cpu_id = u64(id)
	p.hart = hart
	write_tp(p.self)
	write_sscratch(0)
	ipi_online(hart)
	ready = true
}

percpu_ready :: proc "contextless" () -> bool {
	return ready
}

this_cpu :: proc "contextless" () -> ^Percpu {
	return (^Percpu)(uintptr(read_tp()))
}

percpu_kernel_stack :: proc "contextless" () -> uintptr {
	return uintptr(this_cpu().kernel_sp)
}

percpu_id :: proc "contextless" () -> int {
	return int(this_cpu().cpu_id)
}

percpu_critical_depth :: proc "contextless" () -> ^i64 {
	return &this_cpu().critical_depth
}

// percpu_hart is the firmware's name for this core, which the IPI and the
// interrupt controller both use.
percpu_hart :: proc "contextless" () -> u64 {
	return this_cpu().hart
}

