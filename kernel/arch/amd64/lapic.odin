/*
The local APIC, and the timer that drives preemption.

One per CPU, which is the reason it and not the PIT is what a scheduler runs on:
the interrupt is delivered to the core that owns the timer, so there is no
cross-CPU wakeup and no arbitration for a single shared counter. Everything
about this file that looks like extra work compared to the PIT -- the MMIO
mapping, the calibration, the spurious vector -- is that property being paid
for.

Registers are 32 bits wide, aligned to 16, and must be accessed as whole
32-bit loads and stores. They go through `volatile_load`/`volatile_store`
because the compiler is otherwise entitled to notice that nothing reads back
what it wrote to EOI and delete it.

The MMIO page is not mapped by anything else. `arch` sits below `kernel/mem` and
cannot map it itself, so the sequence is: ask this file where the APIC is, map
it in the caller, hand the virtual address back through `lapic_attach`.
*/
package amd64

import "base:intrinsics"

MSR_APIC_BASE :: u32(0x1B)

APIC_BASE_BSP :: u64(1) << 8 // This core is the bootstrap processor
APIC_BASE_ENABLE :: u64(1) << 11 // The hardware global enable, below the SVR one
APIC_BASE_ADDRESS :: u64(0xF_FFFF_F000)

// One page, though the register file only spans 0x400 of it.
LAPIC_MMIO_SIZE :: 0x1000

LAPIC_ID :: uintptr(0x020)
LAPIC_VERSION :: uintptr(0x030)
LAPIC_TPR :: uintptr(0x080)
LAPIC_EOI :: uintptr(0x0B0)
LAPIC_SPURIOUS :: uintptr(0x0F0)
LAPIC_LVT_TIMER :: uintptr(0x320)
LAPIC_LVT_LINT0 :: uintptr(0x350)
LAPIC_LVT_LINT1 :: uintptr(0x360)
LAPIC_LVT_ERROR :: uintptr(0x370)
LAPIC_TIMER_INITIAL :: uintptr(0x380)
LAPIC_TIMER_CURRENT :: uintptr(0x390)
LAPIC_TIMER_DIVIDE :: uintptr(0x3E0)

LVT_MASKED :: u32(1) << 16
LVT_PERIODIC :: u32(1) << 17

SPURIOUS_ENABLE :: u32(1) << 8

// The divide configuration is not a plain number: bit 2 is skipped, so the
// encoding for "divide by 16" is 0b0011 and for "by 1" is 0b1011. Sixteen keeps
// a millisecond comfortably inside 32 bits on any plausible bus clock while
// still leaving the counter fine-grained.
TIMER_DIVIDE_16 :: u32(0b0011)
TIMER_DIVISOR :: 16

@(private = "file")
mmio: rawptr

lapic_write :: proc "contextless" (offset: uintptr, value: u32) {
	intrinsics.volatile_store(cast(^u32)(uintptr(mmio) + offset), value)
}

lapic_read :: proc "contextless" (offset: uintptr) -> u32 {
	return intrinsics.volatile_load(cast(^u32)(uintptr(mmio) + offset))
}

// lapic_available reports CPUID.1:EDX[9]. Every 64-bit CPU has one, so a false
// here means something stranger than an old machine.
lapic_available :: proc "contextless" () -> bool {
	return has_feature(CPUID_FEATURES, .EDX, 9)
}

// lapic_physical_base is where the register page lives, from the MSR rather
// than from the architectural default -- firmware is allowed to move it, and
// occasionally does.
lapic_physical_base :: proc "contextless" () -> uintptr {
	return uintptr(read_msr(MSR_APIC_BASE) & APIC_BASE_ADDRESS)
}

lapic_is_bsp :: proc "contextless" () -> bool {
	return read_msr(MSR_APIC_BASE) & APIC_BASE_BSP != 0
}

/*
lapic_attach takes the mapped register page and brings the APIC up.

Two enables, and both are needed. The MSR bit is the hardware one: with it
clear the register page does not respond at all. The SVR bit is the software
one, and it also carries the vector a spurious interrupt is delivered on --
which is not optional, and is why `VECTOR_SPURIOUS` has its low four bits set.
Some steppings ignore those bits entirely and deliver on 0xFF regardless, so
picking anything else means occasionally receiving an interrupt on a vector
nothing claimed.

The task priority register is cleared because firmware may leave it high enough
to block everything we are about to ask for.
*/
lapic_attach :: proc "contextless" (virt: rawptr) {
	mmio = virt

	write_msr(MSR_APIC_BASE, read_msr(MSR_APIC_BASE) | APIC_BASE_ENABLE)

	lapic_write(LAPIC_TPR, 0)
	lapic_write(LAPIC_SPURIOUS, SPURIOUS_ENABLE | u32(VECTOR_SPURIOUS))

	// Nothing is wired to the local pins and nothing handles APIC errors yet.
	// Masked rather than left as firmware set them, which on some machines is
	// "deliver NMI on LINT1".
	lapic_write(LAPIC_LVT_TIMER, LVT_MASKED)
	lapic_write(LAPIC_LVT_LINT0, LVT_MASKED)
	lapic_write(LAPIC_LVT_LINT1, LVT_MASKED)
	lapic_write(LAPIC_LVT_ERROR, LVT_MASKED)
}

lapic_attached :: proc "contextless" () -> bool {
	return mmio != nil
}

lapic_id :: proc "contextless" () -> u32 {
	return lapic_read(LAPIC_ID) >> 24
}

/*
lapic_eoi acknowledges the interrupt currently being serviced.

Must happen before the handler returns and must happen exactly once. Skip it and
the APIC never delivers another interrupt at or below that priority -- which
looks exactly like a timer that stopped, with no error anywhere to say why.
*/
lapic_eoi :: proc "contextless" () {
	lapic_write(LAPIC_EOI, 0)
}

/*
lapic_calibrate measures the timer against the PIT and returns its frequency.

Counts down from all-ones for a known interval and reports how far it got. The
LAPIC is started fractionally *before* the PIT gate rises, so the answer is
biased high by the couple of microseconds between two port writes -- about two
parts in ten thousand at the default interval, and in the direction that makes
the scheduler tick slightly fast rather than slightly slow.

Interrupts must be off. A tick that landed in the middle of this would be
measured as part of the interval and there is no way to notice afterwards.

Returns zero if the measurement is not believable -- a counter that did not
move, or one that ran out entirely -- rather than a number the caller would go
on to divide by.
*/
lapic_calibrate :: proc "contextless" (micros: u64 = 10_000) -> u64 {
	lapic_write(LAPIC_TIMER_DIVIDE, TIMER_DIVIDE_16)
	lapic_write(LAPIC_LVT_TIMER, LVT_MASKED) // Count, but tell nobody

	pit_gate_arm(pit_count_for_micros(micros))
	lapic_write(LAPIC_TIMER_INITIAL, 0xFFFF_FFFF)
	pit_gate_start()

	for !pit_gate_expired() {
		pause()
	}

	remaining := lapic_read(LAPIC_TIMER_CURRENT)
	lapic_write(LAPIC_TIMER_INITIAL, 0)
	pit_gate_stop()

	if remaining == 0 || remaining == 0xFFFF_FFFF {
		return 0
	}

	elapsed := u64(0xFFFF_FFFF - remaining)
	return (elapsed * 1_000_000) / micros
}

/*
lapic_timer_periodic starts the tick.

The LVT is written before the initial count, because the count is what starts
the timer and a timer that started while its vector said "masked" would deliver
its first interrupt a whole period late.
*/
lapic_timer_periodic :: proc "contextless" (vector: u8, initial: u32) {
	lapic_write(LAPIC_TIMER_DIVIDE, TIMER_DIVIDE_16)
	lapic_write(LAPIC_LVT_TIMER, u32(vector) | LVT_PERIODIC)
	lapic_write(LAPIC_TIMER_INITIAL, initial)
}

lapic_timer_stop :: proc "contextless" () {
	lapic_write(LAPIC_TIMER_INITIAL, 0)
	lapic_write(LAPIC_LVT_TIMER, LVT_MASKED)
}
