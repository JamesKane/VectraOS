/*
Per-CPU state, and the register that finds it.

`TPIDR_EL1` is the thread-pointer register a kernel owns. A program at EL0
cannot read or write it, and nothing in compiled EL1 code uses it, because
`-no-thread-local` leaves no thread-local storage to point at. So it holds
the address of this core's record, and every question of the form `which
core is this` is one read of it. amd64 needs `swapgs` because its base
register is shared with programs; this one is not, and there is no swap.
*/
package arm64

/*
What one core keeps behind `TPIDR_EL1`.

`self` is at offset zero and holds this record's own address, so a readback
can say the base took. `kernel_sp` is the top of the current thread's kernel
stack, kept so a self-test can read it back: the hardware finds the stack
itself, through SP_EL1, because the trap tail leaves SP_EL1 at the top of
whatever frame it just returned from. The two depths are the core's answer
to `may the code running here park`. `irq` is the interrupt acknowledge the
GIC handed this core and has not yet been told is done.
*/
Percpu :: struct {
	self:            u64,
	kernel_sp:       u64,
	cpu_id:          u64,
	interrupt_depth: i64,
	critical_depth:  i64,
	irq:             u32,
}

PERCPU_MAX :: 8

@(private = "file")
percpu: [PERCPU_MAX]Percpu

@(private = "file")
ready: bool

// percpu_init points this core's `TPIDR_EL1` at its own record. Safe before
// `kernel/mem`, because the storage is static.
percpu_init :: proc "contextless" (id: int) #no_bounds_check {
	if id < 0 || id >= PERCPU_MAX {
		return
	}
	p := &percpu[id]
	p.self = u64(uintptr(p))
	p.cpu_id = u64(id)
	write_tpidr(p.self)
	isb()
	ready = true
}

percpu_ready :: proc "contextless" () -> bool {
	return ready
}

// this_cpu reads the record back through the register rather than indexing
// the table, so the answer is what the CPU thinks and not what this file
// remembers.
this_cpu :: proc "contextless" () -> ^Percpu {
	return (^Percpu)(uintptr(read_tpidr()))
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
