/*
The generic interrupt controller, version 3 -- the one the OrangePi's GIC-700
is, and the one QEMU's `virt` board gives with `gic-version=3`.

Version 3 moves two things off the shared page version 2 kept them on. The CPU
interface is now *system registers* -- `ICC_*_EL1`, reached by `mrs`/`msr`
rather than a load or store to a mapped page -- so a core acknowledges and ends
an interrupt without touching memory at all. And each core has its own
*redistributor*, a page pair that owns that core's private lines: the sixteen
software-generated interrupts and the timer. The distributor keeps only the
shared peripheral lines, and routes each by a target core's affinity rather than
a bitmask of eight.

That is the whole of the difference a driver sees. A device's line is still a
shared line in the distributor, masked and unmasked and made level exactly as
version 2 does it. What changed is the plumbing under the acknowledge, the
per-core bring-up, and how one core interrupts another.

The base is assumed, as version 2's is: `0x0800_0000` for the distributor on
`virt`, the redistributors `0xA_0000` above it, one `0x2_0000` frame pair a
core. `gic_select.odin` says how the version is chosen, and `docs/HARDWARE.md`
section 5 has the board's real bases, which a tree read will hand over there.
*/
package arm64

import "base:intrinsics"

// The distributor is at the same base version 2 uses; the redistributors sit
// `0xA_0000` above it on `virt`, a `0x2_0000` frame pair to a core. One mapping
// covers the distributor and up to eight redistributors.
GICV3_DIST_PHYS :: uintptr(0x0800_0000)
GICV3_MMIO_SIZE :: u64(0x1A_0000)
@(private = "file") GICV3_REDIST_OFFSET :: uintptr(0xA_0000)
@(private = "file") GICV3_REDIST_STRIDE :: uintptr(0x2_0000)
@(private = "file") GICV3_SGI_FRAME :: uintptr(0x1_0000)

// Distributor registers. The shared ones -- enable, priority, config -- are at
// version 2's offsets. What is new is group selection by bit, and routing by a
// sixty-four-bit affinity rather than a byte of core mask.
@(private = "file") GICD_CTLR :: uintptr(0x0000)
@(private = "file") GICD_TYPER :: uintptr(0x0004)
@(private = "file") GICD_IGROUPR :: uintptr(0x0080)
@(private = "file") GICD_ISENABLER :: uintptr(0x0100)
@(private = "file") GICD_ICENABLER :: uintptr(0x0180)
@(private = "file") GICD_ICPENDR :: uintptr(0x0280)
@(private = "file") GICD_IPRIORITYR :: uintptr(0x0400)
@(private = "file") GICD_ICFGR :: uintptr(0x0C00)
@(private = "file") GICD_IROUTER :: uintptr(0x6000)

// Redistributor registers, split across the two frames. The first frame owns
// the core's wake state; the second owns its private lines.
@(private = "file") GICR_CTLR :: uintptr(0x0000)
@(private = "file") GICR_TYPER :: uintptr(0x0008)
@(private = "file") GICR_WAKER :: uintptr(0x0014)
@(private = "file") GICR_IGROUPR0 :: uintptr(0x0080) // in the SGI frame
@(private = "file") GICR_ISENABLER0 :: uintptr(0x0100)
@(private = "file") GICR_ICENABLER0 :: uintptr(0x0180)
@(private = "file") GICR_IPRIORITYR :: uintptr(0x0400)

// GICD_CTLR: affinity routing on, and the two interrupt groups enabled. On a
// part with one security state, which is `virt` with no EL3, these are the bits.
@(private = "file") CTLR_ARE :: u32(1) << 4
@(private = "file") CTLR_GRP1 :: u32(1) << 1
@(private = "file") CTLR_GRP0 :: u32(1) << 0
@(private = "file") CTLR_RWP :: u32(1) << 31

// GICR_WAKER: the core says it is awake, and the redistributor says its lines
// are live once its children are no longer asleep.
@(private = "file") WAKER_PROCESSOR_SLEEP :: u32(1) << 1
@(private = "file") WAKER_CHILDREN_ASLEEP :: u32(1) << 2
@(private = "file") GICR_CTLR_RWP :: u32(1) << 3

@(private = "file") PRIORITY_DEFAULT :: u8(0xA0)
@(private = "file") PMR_UNMASK :: u64(0xF0)

// ICC_SGI1R_EL1 fields: the target core by affinity and a bit in its list, the
// interrupt id, and the mode bit that means "every core but the writer".
@(private = "file") SGI1R_IRM_ALL_BUT_SELF :: u64(1) << 40

@(private = "file") gicd: rawptr
@(private = "file") redist_region: rawptr
@(private = "file") lines: int
// The affinity a shared line is routed to: the boot core's, in `GICD_IROUTER`
// layout. On `virt` that is zero, but the boot core need not be affinity zero
// on a real part, so this is read rather than assumed.
@(private = "file") route_target: u64

// -- Memory-mapped register access -------------------------------------------

@(private = "file")
gicd_read :: proc "contextless" (off: uintptr) -> u32 {
	return intrinsics.volatile_load(cast(^u32)(uintptr(gicd) + off))
}

@(private = "file")
gicd_write :: proc "contextless" (off: uintptr, v: u32) {
	intrinsics.volatile_store(cast(^u32)(uintptr(gicd) + off), v)
}

@(private = "file")
gicd_write_byte :: proc "contextless" (off: uintptr, v: u8) {
	intrinsics.volatile_store(cast(^u8)(uintptr(gicd) + off), v)
}

@(private = "file")
gicd_write64 :: proc "contextless" (off: uintptr, v: u64) {
	intrinsics.volatile_store(cast(^u64)(uintptr(gicd) + off), v)
}

@(private = "file")
mmio_read :: proc "contextless" (base: uintptr, off: uintptr) -> u32 {
	return intrinsics.volatile_load(cast(^u32)(base + off))
}

@(private = "file")
mmio_write :: proc "contextless" (base: uintptr, off: uintptr, v: u32) {
	intrinsics.volatile_store(cast(^u32)(base + off), v)
}

@(private = "file")
mmio_write_byte :: proc "contextless" (base: uintptr, off: uintptr, v: u8) {
	intrinsics.volatile_store(cast(^u8)(base + off), v)
}

@(private = "file")
mmio_read64 :: proc "contextless" (base: uintptr, off: uintptr) -> u64 {
	return intrinsics.volatile_load(cast(^u64)(base + off))
}

@(private = "file")
gicd_wait_rwp :: proc "contextless" () {
	for gicd_read(GICD_CTLR) & CTLR_RWP != 0 {}
}

// -- The CPU interface, in system registers ----------------------------------
//
// Each is one `mrs` or `msr` on an `ICC_*_EL1` register with `x0`, as its
// bytes, the way `cpu.odin` keeps every other system register. The encodings
// are what `~/.swiftly/bin/clang` assembles for the named registers.

@(private = "file")
read_icc_sre :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0xA0, 0xCC, 0x38, 0xD5 }()
}

@(private = "file")
write_icc_sre :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0xA0, 0xCC, 0x18, 0xD5 }(v)
}

@(private = "file")
write_icc_pmr :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x00, 0x46, 0x18, 0xD5 }(v)
}

@(private = "file")
write_icc_bpr1 :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x60, 0xCC, 0x18, 0xD5 }(v)
}

@(private = "file")
write_icc_ctlr :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x80, 0xCC, 0x18, 0xD5 }(v)
}

@(private = "file")
write_icc_igrpen1 :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0xE0, 0xCC, 0x18, 0xD5 }(v)
}

@(private = "file")
read_icc_iar1 :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x00, 0xCC, 0x38, 0xD5 }()
}

@(private = "file")
write_icc_eoir1 :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x20, 0xCC, 0x18, 0xD5 }(v)
}

@(private = "file")
write_icc_sgi1r :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0xA0, 0xCB, 0x18, 0xD5 }(v)
}

// -- Affinity ----------------------------------------------------------------

// affinity_of packs the four affinity bytes of an MPIDR into one word, the
// layout `GICR_TYPER` reports its owner in and the token `gicv3_cpu_number`
// hands the scheduler to name a core.
@(private = "file")
affinity_of :: proc "contextless" (mpidr: u64) -> u32 {
	return u32(mpidr & 0xFF | (mpidr >> 8 & 0xFF) << 8 | (mpidr >> 16 & 0xFF) << 16 | (mpidr >> 32 & 0xFF) << 24)
}

// route_value is the same affinity in `GICD_IROUTER`'s layout: the low three
// bytes at their places and the fourth at bit 32, mode bit clear for a specific
// core.
@(private = "file")
route_value :: proc "contextless" (mpidr: u64) -> u64 {
	return mpidr & 0xFF | (mpidr >> 8 & 0xFF) << 8 | (mpidr >> 16 & 0xFF) << 16 | (mpidr >> 32 & 0xFF) << 32
}

// this_redist finds the calling core's redistributor by matching its
// `GICR_TYPER` affinity to the core's own, walking the frames until the match
// or the one flagged last.
@(private = "file")
this_redist :: proc "contextless" () -> uintptr {
	want := affinity_of(read_mpidr())
	p := uintptr(redist_region)
	for {
		typer := mmio_read64(p, GICR_TYPER)
		if u32(typer >> 32) == want {
			return p
		}
		if typer & (1 << 4) != 0 { // Last
			return 0
		}
		p += GICV3_REDIST_STRIDE
	}
}

// -- Bring-up ----------------------------------------------------------------

gicv3_physical_base :: proc "contextless" () -> uintptr {
	return GICV3_DIST_PHYS
}

/*
gicv3_attach brings the distributor up on the boot core: every shared line
disabled, put in group one, given the one priority, made level and routed at
this core. Affinity routing comes on first, because a route means nothing until
it does, and the groups come on last, once every line is configured behind them.
Then this core's own redistributor and CPU interface.
*/
gicv3_attach :: proc "contextless" (virt: rawptr) {
	gicd = virt
	redist_region = rawptr(uintptr(virt) + GICV3_REDIST_OFFSET)
	route_target = route_value(read_mpidr())

	typer := gicd_read(GICD_TYPER)
	if typer == 0xFFFF_FFFF {
		gicd = nil
		return
	}
	lines = int(typer & 0x1F + 1) * 32
	if lines > 1020 {
		lines = 1020
	}

	gicd_write(GICD_CTLR, 0)
	gicd_wait_rwp()
	gicd_write(GICD_CTLR, CTLR_ARE)
	gicd_wait_rwp()

	for id := 32; id < lines; id += 1 {
		// Group one, so the interrupt is the kind `ICC_IAR1_EL1` acknowledges.
		gicd_write(GICD_IGROUPR + uintptr(id / 32 * 4), 0xFFFF_FFFF)
		gicd_write_byte(GICD_IPRIORITYR + uintptr(id), PRIORITY_DEFAULT)
		// Level-sensitive, as the `irq` handshake wants: clear the config high
		// bit for this line. Two bits a line, sixteen a word.
		cfg := GICD_ICFGR + uintptr(id / 16 * 4)
		shift := u32((id % 16) * 2)
		gicd_write(cfg, gicd_read(cfg) & ~(u32(0b10) << shift))
		// Aimed at the boot core, and disabled until a driver unmasks it.
		gicd_write64(GICD_IROUTER + uintptr(id * 8), route_target)
		gicd_write(GICD_ICENABLER + uintptr(id / 32 * 4), u32(1) << u32(id % 32))
	}

	gicd_write(GICD_CTLR, CTLR_ARE | CTLR_GRP1 | CTLR_GRP0)
	gicd_wait_rwp()

	gicv3_attach_here()
}

/*
gicv3_attach_here wakes this core's redistributor, lets its private lines
through -- the sixteen software interrupts and the timer -- and turns on its CPU
interface. Every core does this for itself, the boot core from `gicv3_attach`
and the rest as they come up.
*/
gicv3_attach_here :: proc "contextless" () {
	if gicd == nil {
		return
	}
	rd := this_redist()
	if rd == 0 {
		return
	}

	// Tell the redistributor this core is awake, and wait until its lines are.
	waker := mmio_read(rd, GICR_WAKER) & ~WAKER_PROCESSOR_SLEEP
	mmio_write(rd, GICR_WAKER, waker)
	for mmio_read(rd, GICR_WAKER) & WAKER_CHILDREN_ASLEEP != 0 {}

	// The private lines live in the second frame. Group one, the one priority,
	// then enable the software interrupts and the timer.
	sgi := rd + GICV3_SGI_FRAME
	mmio_write(sgi, GICR_IGROUPR0, 0xFFFF_FFFF)
	for id in uintptr(0) ..< 32 {
		mmio_write_byte(sgi, GICR_IPRIORITYR + id, PRIORITY_DEFAULT)
	}
	mmio_write(sgi, GICR_ISENABLER0, 0x0000_FFFF | u32(1) << VECTOR_TIMER)

	// The CPU interface. System-register access first, because every line below
	// it is a system register and would fault without it.
	if read_icc_sre() & 1 == 0 {
		write_icc_sre(read_icc_sre() | 1)
		isb()
	}
	write_icc_pmr(PMR_UNMASK)
	write_icc_bpr1(0)
	write_icc_ctlr(0)
	write_icc_igrpen1(1)
	isb()
}

gicv3_attached :: proc "contextless" () -> bool {
	return gicd != nil
}

gicv3_available :: proc "contextless" () -> bool {
	return gicd != nil
}

gicv3_lines :: proc "contextless" () -> int {
	if gicd == nil || lines < 32 {
		return 0
	}
	return lines - 32
}

gicv3_version :: proc "contextless" () -> u32 {
	return 3
}

// -- Acknowledge and end -----------------------------------------------------

gicv3_acknowledge :: proc "contextless" () -> u32 {
	if gicd == nil {
		return 1023
	}
	iar := u32(read_icc_iar1())
	this_cpu().irq = iar
	return iar
}

gicv3_eoi :: proc "contextless" (iar: u32) {
	if gicd != nil && iar & 0xFF_FFFF < 1020 {
		write_icc_eoir1(u64(iar))
	}
}

// gicv3_ack retires the interrupt this core acknowledged last, rearming the
// timer if that is what it was, exactly as version 2 does through a different door.
gicv3_ack :: proc "contextless" () {
	iar := this_cpu().irq
	if iar & 0xFF_FFFF == VECTOR_TIMER {
		timer_rearm()
	}
	gicv3_eoi(iar)
	this_cpu().irq = 1023
}

// gicv3_cpu_number is this core's affinity, packed, which is the token the
// scheduler stores and hands back to `gicv3_send` to name a target.
gicv3_cpu_number :: proc "contextless" () -> u32 {
	if gicd == nil {
		return 0
	}
	return affinity_of(read_mpidr())
}

// -- Shared peripheral lines --------------------------------------------------

@(private = "file")
line_valid :: proc "contextless" (gsi: int) -> bool {
	return gicd != nil && gsi >= 0 && gsi < gicv3_lines()
}

// gicv3_route aims one shared line at the boot core and leaves it level and
// masked, so a driver can register its handler before the first interrupt.
gicv3_route :: proc "contextless" (gsi: int, vector: u8, cpu: u32) {
	_ = vector
	_ = cpu
	if !line_valid(gsi) {
		return
	}
	id := VECTOR_IRQ_BASE + gsi
	gicd_write64(GICD_IROUTER + uintptr(id * 8), route_target)
	cfg := GICD_ICFGR + uintptr(id / 16 * 4)
	shift := u32((id % 16) * 2)
	gicd_write(cfg, gicd_read(cfg) & ~(u32(0b10) << shift))
}

gicv3_set_mask :: proc "contextless" (gsi: int, masked: bool) {
	if !line_valid(gsi) {
		return
	}
	id := VECTOR_IRQ_BASE + gsi
	bit := u32(1) << u32(id % 32)
	if masked {
		gicd_write(GICD_ICENABLER + uintptr(id / 32 * 4), bit)
	} else {
		gicd_write(GICD_ISENABLER + uintptr(id / 32 * 4), bit)
	}
}

gicv3_masked :: proc "contextless" (gsi: int) -> bool {
	if !line_valid(gsi) {
		return true
	}
	id := VECTOR_IRQ_BASE + gsi
	return gicd_read(GICD_ISENABLER + uintptr(id / 32 * 4)) & (u32(1) << u32(id % 32)) == 0
}

gicv3_vector_of :: proc "contextless" (gsi: int) -> u8 {
	if !line_valid(gsi) {
		return 0
	}
	return u8(VECTOR_IRQ_BASE + gsi)
}

// -- Software-generated interrupts -------------------------------------------

// gicv3_send delivers software interrupt `vector` to the core whose packed
// affinity is `target`, through the system register that takes an affinity and
// a one-bit list within it.
gicv3_send :: proc "contextless" (target: u32, vector: u8) {
	if gicd == nil {
		return
	}
	aff0 := u64(target & 0xF)
	aff1 := u64(target >> 8 & 0xFF)
	aff2 := u64(target >> 16 & 0xFF)
	aff3 := u64(target >> 24 & 0xFF)
	sgi := aff3 << 48 | aff2 << 32 | aff1 << 16 | u64(vector & 0xF) << 24 | u64(1) << aff0
	dsb_ish()
	write_icc_sgi1r(sgi)
	isb()
}

// gicv3_stop_others sends the stop to every core but this one.
gicv3_stop_others :: proc "contextless" () {
	if gicd == nil {
		return
	}
	dsb_ish()
	write_icc_sgi1r(SGI1R_IRM_ALL_BUT_SELF | u64(VECTOR_NMI & 0xF) << 24)
	isb()
}
