/*
The time-stamp counter, the fast clock `/dev/time` hands to programs.

`rdtsc` reads a free-running 64-bit counter that ticks with the core, the
same shape as arm64's generic timer and riscv64's `time` CSR. It has no rate
of its own to read -- unlike those two, whose rate is a register or the device
tree -- so `tsc_calibrate` measures it against the PIT exactly as the LAPIC
timer is measured, and the scheduler asks once at boot.

Invariant-TSC (the counter runs at a constant rate regardless of the core's
power state) has held on every part since Nehalem, and QEMU's is constant. A
part without it would drift, and there is no board here that has one.
*/
package amd64

// rdtsc reads the time-stamp counter. Like `rdmsr`, the result is split across
// `edx:eax`, so the block returns both halves and this joins them.
rdtsc :: proc "contextless" () -> u64 {
	lo, hi := asm() -> (lo: u32, hi: u32) [lo = %eax, hi = %edx, #volatile] { #byte 0x0F, 0x31 }()
	return u64(hi) << 32 | u64(lo)
}

/*
tsc_calibrate measures the counter's rate against the PIT and returns it in
ticks per second.

Reads the counter across a known interval the PIT gates, the same reference and
the same window `lapic_calibrate` uses, and divides the delta by the interval.
Interrupts must be off: a tick landing in the middle would be counted as part of
the window with no way to tell afterwards. Returns zero if the counter did not
move, rather than a rate the caller would divide by.
*/
tsc_calibrate :: proc "contextless" (micros: u64 = 10_000) -> u64 {
	pit_gate_arm(pit_count_for_micros(micros))
	start := rdtsc()
	pit_gate_start()

	for !pit_gate_expired() {
		pause()
	}

	elapsed := rdtsc() - start
	pit_gate_stop()

	if elapsed == 0 {
		return 0
	}
	return (elapsed * 1_000_000) / micros
}
