/*
amd64 CPU primitives.

Everything here is `contextless` and allocation-free: these run before the
runtime is up and from interrupt context. Inline assembly uses LLVM's AT&T
dialect with explicit register constraints so the operand order is fixed
regardless of how the optimiser feels about it that day.
*/
package amd64

// -- Port I/O ----------------------------------------------------------------

outb :: proc "contextless" (port: u16, value: u8) {
	asm(u16, u8){"outb %al, %dx", "{dx},{al}"}(port, value)
}

outw :: proc "contextless" (port: u16, value: u16) {
	asm(u16, u16){"outw %ax, %dx", "{dx},{ax}"}(port, value)
}

outl :: proc "contextless" (port: u16, value: u32) {
	asm(u16, u32){"outl %eax, %dx", "{dx},{eax}"}(port, value)
}

inb :: proc "contextless" (port: u16) -> u8 {
	return asm(u16) -> u8 {"inb %dx, %al", "={al},{dx}"}(port)
}

inw :: proc "contextless" (port: u16) -> u16 {
	return asm(u16) -> u16 {"inw %dx, %ax", "={ax},{dx}"}(port)
}

inl :: proc "contextless" (port: u16) -> u32 {
	return asm(u16) -> u32 {"inl %dx, %eax", "={eax},{dx}"}(port)
}

// io_wait burns one I/O cycle on the unused POST diagnostic port. Legacy PIC
// and PIT programming need the delay between consecutive writes.
io_wait :: proc "contextless" () {
	outb(0x80, 0)
}

// -- Interrupt / halt state --------------------------------------------------

cli :: proc "contextless" () {
	asm(){"cli", ""}()
}

sti :: proc "contextless" () {
	asm(){"sti", ""}()
}

hlt :: proc "contextless" () {
	asm(){"hlt", ""}()
}

pause :: proc "contextless" () {
	asm(){"pause", ""}()
}

// halt_forever parks the CPU with interrupts masked. This is the terminal
// state for a panic: nothing short of a reset gets us out.
halt_forever :: proc "contextless" () -> ! {
	for {
		cli()
		hlt()
	}
}

// -- Model-specific registers ------------------------------------------------

// rdmsr splits its result across edx:eax, so the asm block returns both halves
// and we recombine here.
MSR_Pair :: struct {
	lo: u32,
	hi: u32,
}

read_msr :: proc "contextless" (msr: u32) -> u64 {
	pair := asm(u32) -> MSR_Pair {"rdmsr", "={eax},={edx},{ecx}"}(msr)
	return u64(pair.hi) << 32 | u64(pair.lo)
}

write_msr :: proc "contextless" (msr: u32, value: u64) {
	asm(u32, u32, u32){"wrmsr", "{ecx},{eax},{edx}"}(msr, u32(value), u32(value >> 32))
}

// -- Control registers -------------------------------------------------------

read_cr0 :: proc "contextless" () -> u64 {
	return asm() -> u64 {"movq %cr0, $0", "=r"}()
}

write_cr0 :: proc "contextless" (value: u64) {
	asm(u64){"movq $0, %cr0", "r"}(value)
}

read_cr3 :: proc "contextless" () -> u64 {
	return asm() -> u64 {"movq %cr3, $0", "=r"}()
}

write_cr3 :: proc "contextless" (value: u64) {
	asm(u64){"movq $0, %cr3", "r"}(value)
}

read_cr4 :: proc "contextless" () -> u64 {
	return asm() -> u64 {"movq %cr4, $0", "=r"}()
}

write_cr4 :: proc "contextless" (value: u64) {
	asm(u64){"movq $0, %cr4", "r"}(value)
}

CR0_MP :: u64(1) << 1   // Monitor coprocessor
CR0_EM :: u64(1) << 2   // Emulation -- must be clear for SSE
CR0_WP :: u64(1) << 16  // Supervisor writes obey the read-only page bit

CR4_PSE        :: u64(1) << 4   // 4 MiB pages in 32-bit paging; always on in long mode
CR4_PGE        :: u64(1) << 7   // Global pages survive a CR3 reload
CR4_OSFXSR     :: u64(1) << 9   // FXSAVE/FXRSTOR and SSE enabled
CR4_OSXMMEXCPT :: u64(1) << 10  // Unmasked SSE exceptions raise #XF

/*
enable_sse must run before any Odin code that touches the runtime.

Odin's codegen uses SSE registers for ordinary struct moves and zero-inits --
including the implicit `context` setup -- so a kernel that skips this faults
on its very first Odin statement rather than somewhere informative.
*/
enable_sse :: proc "contextless" () {
	cr0 := read_cr0()
	cr0 &~= CR0_EM
	cr0 |= CR0_MP
	write_cr0(cr0)

	cr4 := read_cr4()
	cr4 |= CR4_OSFXSR | CR4_OSXMMEXCPT
	write_cr4(cr4)
}

// -- CPUID -------------------------------------------------------------------

CPUID_Result :: struct {
	eax, ebx, ecx, edx: u32,
}

/*
cpuid reads one leaf of the CPU feature identification.

`cpuid` clobbers `rbx`, which LLVM handles on x86-64 by saving it around the
block -- unlike i386, where `ebx` is the PIC base and the same constraint is a
trap. Callers should check `max_leaf` before trusting a leaf's contents: an
unimplemented leaf does not fault, it returns whatever the highest implemented
one does, which is indistinguishable from a real answer.
*/
cpuid :: proc "contextless" (leaf: u32, subleaf: u32 = 0) -> CPUID_Result {
	return asm(u32, u32) -> CPUID_Result{"cpuid", "={eax},={ebx},={ecx},={edx},{eax},{ecx}"}(leaf, subleaf)
}

CPUID_BASE :: u32(0x0000_0000)
CPUID_FEATURES :: u32(0x0000_0001)
CPUID_EXT_BASE :: u32(0x8000_0000)
CPUID_EXT_FEATURES :: u32(0x8000_0001)

// max_leaf returns the highest leaf the CPU implements in `leaf`'s range.
max_leaf :: proc "contextless" (leaf: u32) -> u32 {
	base := leaf >= CPUID_EXT_BASE ? CPUID_EXT_BASE : CPUID_BASE
	return cpuid(base).eax
}

// has_feature tests one bit of one CPUID register, returning false when the
// leaf itself is not implemented.
has_feature :: proc "contextless" (leaf: u32, reg: CPUID_Register, bit: uint) -> bool {
	if leaf > max_leaf(leaf) {
		return false
	}
	r := cpuid(leaf)
	word: u32
	switch reg {
	case .EAX: word = r.eax
	case .EBX: word = r.ebx
	case .ECX: word = r.ecx
	case .EDX: word = r.edx
	}
	return word & (u32(1) << bit) != 0
}

CPUID_Register :: enum {
	EAX,
	EBX,
	ECX,
	EDX,
}

// -- Extended feature enable register ----------------------------------------

MSR_EFER :: u32(0xC000_0080)

EFER_SCE  :: u64(1) << 0  // SYSCALL/SYSRET
EFER_LME  :: u64(1) << 8  // Long mode enable
EFER_LMA  :: u64(1) << 10 // Long mode active (read-only)
EFER_NXE  :: u64(1) << 11 // No-execute page bit is honoured rather than reserved

read_efer :: proc "contextless" () -> u64 {
	return read_msr(MSR_EFER)
}

write_efer :: proc "contextless" (value: u64) {
	write_msr(MSR_EFER, value)
}

// -- Interrupt flag ----------------------------------------------------------

RFLAGS_IF :: u64(1) << 9

read_rflags :: proc "contextless" () -> u64 {
	return asm() -> u64 {"pushfq; popq $0", "=r,~{memory}"}()
}

/*
irq_save masks interrupts and reports whether they were on.

The uniprocessor lock. With one CPU and no preemption other than the timer,
"nothing else can run" and "interrupts are off" are the same statement, so a
critical section is this and its matching restore. It stays correct on SMP as
the *inner* half of a spinlock -- what changes is that a lock word is needed
too, not that this stops being necessary.

Returns the previous state rather than unconditionally enabling on the way out,
because these nest: a handler that ran with interrupts already masked must not
turn them on when it finishes.
*/
irq_save :: proc "contextless" () -> bool {
	was_on := read_rflags() & RFLAGS_IF != 0
	cli()
	return was_on
}

irq_restore :: proc "contextless" (was_on: bool) {
	if was_on {
		sti()
	}
}

interrupts_enabled :: proc "contextless" () -> bool {
	return read_rflags() & RFLAGS_IF != 0
}
