/*
riscv64 CPU primitives.

Everything here is `contextless` and allocation-free: these run before the
runtime is up and from interrupt context.

The template checker behind `asm` knows the control and status register
instructions by number, so `csrrs r, 0x100, %zero` is `csrr r, sstatus` and
the names are written beside each number. What it does not know -- `ecall`,
`ebreak`, `wfi` as anything but a dead end, `sfence.vma`, `pause`, and a
read of `sp` -- is written as bytes, with clang as the oracle and the
mnemonic beside each. The register in every byte sequence is `a0`, and the
binding beside it is what makes that so.
*/
package riscv64

// The supervisor status register's bits this package reads and writes.
SSTATUS_SIE :: u64(1) << 1  // Supervisor interrupts enabled
SSTATUS_SPIE :: u64(1) << 5 // What SIE becomes on `sret`
SSTATUS_SPP :: u64(1) << 8  // The mode `sret` returns to: 1 supervisor, 0 user
SSTATUS_FS_INITIAL :: u64(1) << 13 // The float unit on, state clean
SSTATUS_FS_MASK :: u64(3) << 13
SSTATUS_SUM :: u64(1) << 18 // Supervisor may touch user pages

// The CSR numbers.
CSR_SSTATUS :: 0x100
CSR_SIE :: 0x104
CSR_STVEC :: 0x105
CSR_SSCRATCH :: 0x140
CSR_SEPC :: 0x141
CSR_SCAUSE :: 0x142
CSR_STVAL :: 0x143
CSR_SIP :: 0x144
CSR_SATP :: 0x180
CSR_TIME :: 0xC01

// -- Interrupt masking ------------------------------------------------------

read_sstatus :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [#volatile] { csrrs r, 0x100, %zero }()
}

write_sstatus :: proc "contextless" (v: u64) {
	asm(v: u64) [#volatile, #clobber memory] { csrrw %zero, 0x100, v }(v)
}

// cli masks supervisor interrupts. `csrci sstatus, 2`.
cli :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { csrrci %zero, 0x100, 2 }()
}

// sti unmasks them. `csrsi sstatus, 2`.
sti :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { csrrsi %zero, 0x100, 2 }()
}

// wfi parks the hart until an interrupt is pending, masked or not.
wfi :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { #byte 0x73, 0x00, 0x50, 0x10 }()
}

// pause is the spin-loop hint. A fence with no ordering on a hart that
// lacks the extension, which is harmless.
pause :: proc "contextless" () {
	asm() [#volatile] { #byte 0x0F, 0x00, 0x00, 0x01 }()
}

halt_forever :: proc "contextless" () -> ! {
	for {
		cli()
		wfi()
	}
}

irq_save :: proc "contextless" () -> bool {
	was_on := read_sstatus() & SSTATUS_SIE != 0
	cli()
	return was_on
}

irq_restore :: proc "contextless" (was_on: bool) {
	if was_on {
		sti()
	}
}

interrupts_enabled :: proc "contextless" () -> bool {
	return read_sstatus() & SSTATUS_SIE != 0
}

// -- Other control and status registers -----------------------------------------

read_sie :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [#volatile] { csrrs r, 0x104, %zero }()
}

write_sie :: proc "contextless" (v: u64) {
	asm(v: u64) [#volatile, #clobber memory] { csrrw %zero, 0x104, v }(v)
}

read_sip :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [#volatile] { csrrs r, 0x144, %zero }()
}

// clear_sip clears the bits of `v` in the pending register, which is how a
// software interrupt is retired.
clear_sip :: proc "contextless" (v: u64) {
	asm(v: u64) [#volatile, #clobber memory] { csrrc %zero, 0x144, v }(v)
}

read_stvec :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [#volatile] { csrrs r, 0x105, %zero }()
}

write_stvec :: proc "contextless" (v: u64) {
	asm(v: u64) [#volatile, #clobber memory] { csrrw %zero, 0x105, v }(v)
}

write_sscratch :: proc "contextless" (v: u64) {
	asm(v: u64) [#volatile, #clobber memory] { csrrw %zero, 0x140, v }(v)
}

read_satp :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [#volatile] { csrrs r, 0x180, %zero }()
}

write_satp :: proc "contextless" (v: u64) {
	asm(v: u64) [#volatile, #clobber memory] { csrrw %zero, 0x180, v }(v)
}

read_stval :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [#volatile] { csrrs r, 0x143, %zero }()
}

// read_time is the counter every hart shares, in ticks of the rate the
// device tree names.
read_time :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [#volatile] { csrrs r, 0xC01, %zero }()
}

// read_tp is the thread pointer, which holds this hart's per-CPU record.
read_tp :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [#volatile] { add r, %tp, %zero }()
}

write_tp :: proc "contextless" (v: u64) {
	asm(v: u64) [#volatile, #clobber memory] { add %tp, v, %zero }(v)
}

// current_sp is this frame's stack pointer. `mv a0, sp`, in bytes, because
// the checker wants an input pinned to `sp` before it will read it.
current_sp :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [r = %a0, #volatile] { #byte 0x0A, 0x85 }()
}

// enable_fp turns the float unit on. Base revision 6 hands over `sstatus`
// with FS clear, so the first float instruction traps, and Odin's codegen
// on this target keeps floats in float registers.
enable_fp :: proc "contextless" () {
	write_sstatus(read_sstatus() &~ SSTATUS_FS_MASK | SSTATUS_FS_INITIAL | SSTATUS_SUM)
}

// -- Fences ---------------------------------------------------------------------

// fence orders every memory access before it against every one after it.
// `fence rw, rw`.
fence :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { #byte 0x0F, 0x00, 0x30, 0x03 }()
}

// sfence_all drops every translation this hart has cached. `sfence.vma
// zero, zero`.
sfence_all :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { #byte 0x73, 0x00, 0x00, 0x12 }()
}

// sfence_page drops one page's translation. `sfence.vma a0, zero`.
sfence_page :: proc "contextless" (virt: uintptr) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %a0, #volatile, #clobber memory] { #byte 0x73, 0x00, 0x05, 0x12 }(u64(virt))
}

// -- Software traps ---------------------------------------------------------------
//
// The kernel has one instruction that traps into itself synchronously, and
// it is `ebreak`. An `ecall` from supervisor mode is the firmware's door
// and never reaches this kernel, whatever `medeleg` says, because that is
// how the SBI is called. So a breakpoint carries a number in `a7`: zero is
// a breakpoint, and the software vectors are themselves. `ebreak` is
// written as its four bytes rather than the two-byte compressed form, so
// stepping over it is one rule.

@(private = "file")
ebreak_vector :: proc "contextless" (vector: u64) {
	_ = asm(v: u64) -> (q: u64) [v -> q = %a7, #volatile, #clobber memory] { #byte 0x73, 0x00, 0x10, 0x00 }(vector)
}

// breakpoint raises the one exception a kernel can raise deliberately and
// resume from, which makes it the end-to-end test of the trap entry.
breakpoint :: proc "contextless" () {
	ebreak_vector(0)
}

// yield_trap raises the software trap the scheduler listens on, so a
// voluntary switch takes the path a preemption does.
yield_trap :: proc "contextless" () {
	ebreak_vector(VECTOR_YIELD)
}

raise_test_interrupt :: proc "contextless" () {
	ebreak_vector(VECTOR_TEST)
}

// -- Port I/O -----------------------------------------------------------------
//
// There is no port space on this architecture. A driver that probes one
// reads all-ones, which is what an absent device answers on a PC too.

inb :: proc "contextless" (port: u16) -> u8 {
	_ = port
	return 0xFF
}

outb :: proc "contextless" (port: u16, value: u8) {
	_, _ = port, value
}

// cpu_hart_number is this core's id in the firmware's terms, which is what
// the scheduler keeps to reach it with an interrupt.
cpu_hart_number :: proc "contextless" () -> u32 {
	return u32(percpu_hart())
}

// -- What kind of core this is ----------------------------------------------------

Cpu_Class :: enum {
	Efficiency,
	Performance,
	Prime,
}

CAPACITY_FULL :: 1024

cpu_class :: proc "contextless" () -> (class: Cpu_Class, capacity: int) {
	return .Performance, CAPACITY_FULL
}
