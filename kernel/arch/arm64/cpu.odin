/*
arm64 CPU primitives.

Everything here is `contextless` and allocation-free: these run before the
runtime is up and from interrupt context.

Nearly every instruction in this file is written as its four bytes. The
template checker behind `asm` knows the general-purpose instruction set, but
not the system instructions a kernel lives on: `msr daifset`, the barriers,
`tlbi`, `brk`, `svc` and `wfi` either have no operand form it accepts or are
modelled as never falling through. A byte sequence says the instruction
without the claim. Each sequence is annotated with the mnemonic clang
assembles it from, and clang was the oracle that produced it. The register
in every sequence is `x0`, and the binding beside it is what makes that so.

System registers that the checker does name (`%daif`, `%tpidr_el1` and a
few others) still go through bytes here, so that every accessor in this file
has the same shape and the same proof.
*/
package arm64

// -- Interrupt masking ------------------------------------------------------
//
// PSTATE.I is the IRQ mask, bit 7 in the DAIF view. FIQ and SError stay masked
// from the moment the bootloader handed over: nothing here routes a FIQ, and
// an SError with nothing to handle it is better reported at the next IRQ
// than taken asynchronously.

DAIF_I :: u64(1) << 7

read_daif :: proc "contextless" () -> u64 {
	// mrs x0, daif
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x20, 0x42, 0x3B, 0xD5 }()
}

// cli masks IRQs. `msr daifset, #2`.
cli :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { #byte 0xDF, 0x42, 0x03, 0xD5 }()
}

// sti unmasks IRQs. `msr daifclr, #2`.
sti :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { #byte 0xFF, 0x42, 0x03, 0xD5 }()
}

// wfi parks the core until the next interrupt, masked or not. Bytes, because
// the checker models the mnemonic as an instruction nothing falls through.
wfi :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { #byte 0x7F, 0x20, 0x03, 0xD5 }()
}

// yield is the spin-loop hint, the architecture's `pause`.
yield :: proc "contextless" () {
	asm() [#volatile] { yield }()
}

// halt_forever parks the CPU with every interrupt masked. The terminal state
// for a panic: nothing short of a reset gets us out.
halt_forever :: proc "contextless" () -> ! {
	for {
		// msr daifset, #0xf
		asm() [#volatile, #clobber memory] { #byte 0xDF, 0x4F, 0x03, 0xD5 }()
		wfi()
	}
}

/*
irq_save masks interrupts and reports whether they were on.

The uniprocessor lock, and the inner half of every spinlock. See the amd64
file of the same name for the argument; it does not change with the
architecture. Returns the previous state rather than unconditionally
enabling on the way out, because these nest.
*/
irq_save :: proc "contextless" () -> bool {
	was_on := read_daif() & DAIF_I == 0
	cli()
	return was_on
}

irq_restore :: proc "contextless" (was_on: bool) {
	if was_on {
		sti()
	}
}

interrupts_enabled :: proc "contextless" () -> bool {
	return read_daif() & DAIF_I == 0
}

// -- Barriers ---------------------------------------------------------------

// isb: the instruction stream sees every system register write before it.
isb :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { #byte 0xDF, 0x3F, 0x03, 0xD5 }()
}

// dsb_sy: every memory access before it completes before anything after it.
dsb_sy :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { #byte 0x9F, 0x3F, 0x03, 0xD5 }()
}

// dsb_ish: the same, for the inner shareable domain, which is every core.
dsb_ish :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { #byte 0x9F, 0x3B, 0x03, 0xD5 }()
}

// -- The stack and the exception level ----------------------------------------

// current_sp is this frame's stack pointer, where the panic screen's stack
// scan starts. `mov x0, sp`, in bytes, because the checker wants an input
// pinned to `sp` before it will read it.
current_sp :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0xE0, 0x03, 0x00, 0x91 }()
}

// current_el is the exception level, 1 or 2, out of CurrentEL bits 3:2.
current_el :: proc "contextless" () -> u64 {
	// mrs x0, currentel
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x40, 0x42, 0x38, 0xD5 }() >> 2 & 3
}

/*
use_kernel_stack_register moves this core onto SP_EL1.

The protocol enters the kernel with PSTATE.SP clear, so `sp` names SP_EL0 --
the register a program will own. A trap from EL1 on SP_EL0 lands on the
first group of vectors, and a program's stack pointer would be the
kernel's. Three instructions put the kernel where it belongs: copy the
stack pointer out, select SP_EL1, copy it back in. Nothing between them
touches the stack.

    mov x0, sp
    msr spsel, #1
    mov sp, x0
*/
use_kernel_stack_register :: proc "contextless" () {
	_ = asm() -> (r: u64) [r = %x0, #volatile, #clobber memory] {
		#byte 0xE0, 0x03, 0x00, 0x91
		#byte 0xBF, 0x41, 0x00, 0xD5
		#byte 0x1F, 0x00, 0x00, 0x91
	}()
}

/*
enable_fp turns the vector unit on for EL1 and EL0.

Base revision 6 hands over `CPACR_EL1` cleared, so the first NEON instruction
traps. Odin's codegen uses vector registers for ordinary struct moves, so
that first instruction is very close. `FPEN` is bits 21:20, and 0b11 means
no trap at either level.
*/
enable_fp :: proc "contextless" () {
	write_cpacr(read_cpacr() | (u64(3) << 20))
	isb()
}

// -- System register accessors ------------------------------------------------
//
// Each is one `mrs` or `msr` with `x0`, as its bytes.

read_cpacr :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x40, 0x10, 0x38, 0xD5 }()
}

write_cpacr :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x40, 0x10, 0x18, 0xD5 }(v)
}

read_mpidr :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x00, 0x00, 0x3B, 0xD5 }()
}

read_midr :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x00, 0x00, 0x38, 0xD5 }()
}

read_mmfr0 :: proc "contextless" () -> u64 {
	// mrs x0, id_aa64mmfr0_el1
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x00, 0x07, 0x38, 0xD5 }()
}

read_sctlr :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x00, 0x10, 0x38, 0xD5 }()
}

write_sctlr :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x00, 0x10, 0x18, 0xD5 }(v)
}

read_tcr :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x40, 0x20, 0x38, 0xD5 }()
}

write_tcr :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x40, 0x20, 0x18, 0xD5 }(v)
}

read_mair :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x00, 0xA2, 0x38, 0xD5 }()
}

write_mair :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x00, 0xA2, 0x18, 0xD5 }(v)
}

read_ttbr0 :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x00, 0x20, 0x38, 0xD5 }()
}

write_ttbr0 :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x00, 0x20, 0x18, 0xD5 }(v)
}

read_ttbr1 :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x20, 0x20, 0x38, 0xD5 }()
}

write_ttbr1 :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x20, 0x20, 0x18, 0xD5 }(v)
}

read_vbar :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x00, 0xC0, 0x38, 0xD5 }()
}

write_vbar :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x00, 0xC0, 0x18, 0xD5 }(v)
}

read_tpidr :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x80, 0xD0, 0x38, 0xD5 }()
}

write_tpidr :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x80, 0xD0, 0x18, 0xD5 }(v)
}

read_far :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x00, 0x60, 0x38, 0xD5 }()
}

read_esr :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x00, 0x52, 0x38, 0xD5 }()
}

read_cntfrq :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x00, 0xE0, 0x3B, 0xD5 }()
}

read_cntpct :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x20, 0xE0, 0x3B, 0xD5 }()
}

write_cntp_tval :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x00, 0xE2, 0x1B, 0xD5 }(v)
}

read_cntp_ctl :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %x0, #volatile] { #byte 0x20, 0xE2, 0x3B, 0xD5 }()
}

write_cntp_ctl :: proc "contextless" (v: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x20, 0xE2, 0x1B, 0xD5 }(v)
}

// -- TLB maintenance ----------------------------------------------------------

// tlbi_all drops every EL1 translation on every core. `tlbi vmalle1is`.
tlbi_all :: proc "contextless" () {
	dsb_ish()
	asm() [#volatile, #clobber memory] { #byte 0x1F, 0x83, 0x08, 0xD5 }()
	dsb_ish()
	isb()
}

// tlbi_page drops one page's translation, any ASID, on every core. `tlbi
// vaae1is, x0` takes the virtual page number in bits 43:0.
tlbi_page :: proc "contextless" (virt: uintptr) {
	dsb_ish()
	_ = asm(v: u64) -> (q: u64) [v -> q = %x0, #volatile, #clobber memory] { #byte 0x60, 0x83, 0x08, 0xD5 }(u64(virt) >> 12 & 0xFFF_FFFF_FFFF)
	dsb_ish()
	isb()
}

// -- Software traps -----------------------------------------------------------

// breakpoint raises a BRK exception. The one exception a kernel can raise
// deliberately and resume from, which makes it the end-to-end test of the
// vector table. `brk #0`.
breakpoint :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { #byte 0x00, 0x00, 0x20, 0xD4 }()
}

// yield_trap raises the supervisor call the scheduler listens on, so a
// voluntary switch takes the path a preemption does. `svc #0x401`.
yield_trap :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { #byte 0x21, 0x80, 0x00, 0xD4 }()
}

// raise_test_interrupt fires `VECTOR_TEST` synchronously, so a self-test can
// observe the interrupt bracket from inside a top half. `svc #0x402`.
raise_test_interrupt :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { #byte 0x41, 0x80, 0x00, 0xD4 }()
}

// -- Port I/O -----------------------------------------------------------------
//
// There is no port space on this architecture. A driver that probes one, the
// PS/2 keyboard's, reads all-ones, which is what an absent device answers on
// a PC too, and gives up the same way.

inb :: proc "contextless" (port: u16) -> u8 {
	_ = port
	return 0xFF
}

outb :: proc "contextless" (port: u16, value: u8) {
	_, _ = port, value
}

// -- What kind of core this is --------------------------------------------------

/*
Vectra schedules against a core's *class*, not its number.

One class for now, at full capacity. A big.LITTLE part reports its cores by
MIDR part number, and this is where that table will live. The scheduler
already knows the three tiers.
*/
Cpu_Class :: enum {
	Efficiency,
	Performance,
	Prime,
}

CAPACITY_FULL :: 1024

cpu_class :: proc "contextless" () -> (class: Cpu_Class, capacity: int) {
	return .Performance, CAPACITY_FULL
}
