/*
The generic timer, which drives preemption.

One per core, counting a clock whose rate is a register: `CNTFRQ_EL0` says
how many counts make a second, so there is nothing to calibrate against.
The EL1 physical timer fires when its down-counter reaches zero, once, and
its interrupt is a private peripheral interrupt on the GIC. Periodic means
reloading the counter in the acknowledge, which `gic_ack` does.

The timer has no registers in memory. What has to be mapped before the tick
can arrive is the interrupt controller, and `main.odin` maps that on its own
line. So `timer_physical_base` and its size say `nothing to map`, and
`timer_attach` takes nothing.
*/
package arm64

TIMER_MMIO_SIZE :: u64(0)

CNTP_CTL_ENABLE :: u64(1) << 0
CNTP_CTL_IMASK :: u64(1) << 1

@(private = "file") tick_count: u64

timer_available :: proc "contextless" () -> bool {
	return read_cntfrq() != 0
}

timer_physical_base :: proc "contextless" () -> uintptr {
	return 0
}

timer_attach :: proc "contextless" (virt: rawptr) {
	_ = virt
}

// timer_attach_here brings up this core's half of the interrupt path, the
// GIC CPU interface, on the pages the boot core mapped.
timer_attach_here :: proc "contextless" () {
	gic_attach_here()
}

timer_attached :: proc "contextless" () -> bool {
	return gic_attached()
}

// timer_calibrate is the counter's rate, read rather than measured.
timer_calibrate :: proc "contextless" (micros: u64 = 0) -> u64 {
	_ = micros
	return read_cntfrq()
}

// timer_periodic starts the tick: `count` counts from now, and again from
// each acknowledge. The vector is the timer's own and cannot be chosen.
timer_periodic :: proc "contextless" (vector: u8, initial: u32) {
	_ = vector
	tick_count = u64(initial)
	write_cntp_tval(tick_count)
	write_cntp_ctl(CNTP_CTL_ENABLE)
	isb()
}

timer_rearm :: proc "contextless" () {
	if tick_count != 0 {
		write_cntp_tval(tick_count)
	}
}

timer_stop :: proc "contextless" () {
	write_cntp_ctl(CNTP_CTL_IMASK)
	isb()
}
