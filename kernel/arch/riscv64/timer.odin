/*
The timer, the software interrupt, and the acknowledge that serves both.

The clock is `time`, one counter every hart reads, at the rate the device
tree names. A hart cannot arm its own comparator from supervisor mode; it
asks the firmware, which fires one supervisor timer interrupt when the
counter passes the value asked for. Periodic means asking again in the
acknowledge, for the deadline after the last one rather than after now, so
the tick does not drift by however long the handler took.

Another hart is reached the same way. The firmware raises a software
interrupt on the harts named, and since that interrupt carries no number,
the sender leaves the vector in the receiver's per-CPU record first.
*/
package riscv64

TIMER_MMIO_SIZE :: u64(0)

@(private = "file") tick_count: u64
@(private = "file") attached: bool

timer_available :: proc "contextless" () -> bool {
	return timebase() != 0
}

timer_physical_base :: proc "contextless" () -> uintptr {
	return 0
}

timer_attach :: proc "contextless" (virt: rawptr) {
	_ = virt
	attached = true
	timer_attach_here()
}

// timer_attach_here lets this hart take the three supervisor interrupts:
// software, timer, external.
timer_attach_here :: proc "contextless" () {
	write_sie(read_sie() | SIE_SSIE | SIE_STIE | SIE_SEIE)
}

timer_attached :: proc "contextless" () -> bool {
	return attached
}

timer_calibrate :: proc "contextless" (micros: u64 = 0) -> u64 {
	_ = micros
	return timebase()
}

// timer_periodic starts the tick, `count` counts from now and then from
// each deadline. The vector is the timer's own and cannot be chosen.
timer_periodic :: proc "contextless" (vector: u8, initial: u32) {
	_ = vector
	tick_count = u64(initial)
	this_cpu_deadline = read_time() + tick_count
	sbi_set_timer(this_cpu_deadline)
}

// One deadline per hart would be right; one for the boot hart is what the
// scheduler asks for until the other harts come up, and then each keeps
// its own in the same word by being the only writer between its ticks.
@(private = "file") this_cpu_deadline: u64

timer_rearm :: proc "contextless" () {
	if tick_count == 0 {
		return
	}
	next := this_cpu_deadline + tick_count
	now := read_time()
	if next <= now {
		next = now + tick_count
	}
	this_cpu_deadline = next
	sbi_set_timer(next)
}

// timer_stop masks the tick. The firmware has no cancel, so the comparator
// is pushed as far into the future as it goes.
timer_stop :: proc "contextless" () {
	write_sie(read_sie() &~ SIE_STIE)
	sbi_set_timer(~u64(0))
}

/*
timer_ack retires whatever this hart is servicing: the tick is re-armed,
a PLIC source is completed, and a software interrupt was retired when it
was taken.
*/
timer_ack :: proc "contextless" () {
	p := this_cpu()
	switch {
	case p.irq == VECTOR_TIMER:
		timer_rearm()
	case p.irq >= VECTOR_IRQ_BASE:
		plic_complete(p.irq - VECTOR_IRQ_BASE)
	}
	p.irq = 0
}

// -- Interprocessor interrupts ------------------------------------------------------

// The software vectors are 0x80 and up, and the mailbox holds one bit per
// vector above that base.
IPI_VECTOR_BASE :: 0x80

// ipi_send raises `vector` on the hart named, which is a core's id in the
// firmware's terms.
ipi_send :: proc "contextless" (hart: u32, vector: u8) {
	if vector < IPI_VECTOR_BASE {
		return
	}
	for id in 0 ..< PERCPU_MAX {
		p := percpu_record(id)
		if p.self != 0 && p.hart == u64(hart) {
			_ = intrinsics_or(&p.ipi, u64(1) << (vector - IPI_VECTOR_BASE))
			sbi_send_ipi(1, u64(hart))
			return
		}
	}
}

// ipi_stop_others sends the stop to every hart but this one.
ipi_stop_others :: proc "contextless" () {
	me := percpu_hart()
	mask := u64(0)
	for id in 0 ..< PERCPU_MAX {
		p := percpu_record(id)
		if p.self != 0 && p.hart != me {
			_ = intrinsics_or(&p.ipi, u64(1) << (VECTOR_NMI - IPI_VECTOR_BASE))
			mask |= u64(1) << p.hart
		}
	}
	if mask != 0 {
		sbi_send_ipi(mask, 0)
	}
}
