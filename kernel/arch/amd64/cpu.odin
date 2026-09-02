/*
amd64 CPU primitives.

Everything here is `contextless` and allocation-free: these run before the
runtime is up and from interrupt context. Inline assembly uses LLVM's AT&T
dialect, with explicit register constraints. The operand order is then fixed,
whatever the optimiser thinks of it that day.
*/
package amd64

// -- Port I/O ----------------------------------------------------------------

/*
Port I/O, six widths, and every one is the encoding written out in bytes.

The assembler behind `asm` knows `in` and `out` only in their bare forms,
which name no width. Its def-use check does not see a bare `in` write the
register it is bound to. The instructions are one or two bytes each, and
were on the 8086. So the bytes are written here, with the register bindings
that give them meaning. `%dx` is the port, and `%al`, `%ax` or `%eax` is
the value. `0x66` is the operand-size prefix that makes `0xED` and
`0xEF` sixteen bits wide instead of thirty-two.

Every input is tied to an output the caller drops. The checker counts a use
per instruction and sees none in a byte. A tie is the one use that costs no
instruction. The output shares the input's register and carries whatever it
holds when the bytes are done.
*/
outb :: proc "contextless" (port: u16, value: u8) {
	_, _ = asm(p: u16, v: u8) -> (q: u16, w: u8) [p -> q = %dx, v -> w = %al, #volatile] { #byte 0xEE }(port, value)
}

outw :: proc "contextless" (port: u16, value: u16) {
	_, _ = asm(p: u16, v: u16) -> (q: u16, w: u16) [p -> q = %dx, v -> w = %ax, #volatile] { #byte 0x66, 0xEF }(port, value)
}

outl :: proc "contextless" (port: u16, value: u32) {
	_, _ = asm(p: u16, v: u32) -> (q: u16, w: u32) [p -> q = %dx, v -> w = %eax, #volatile] { #byte 0xEF }(port, value)
}

inb :: proc "contextless" (port: u16) -> u8 {
	r, _ := asm(p: u16) -> (r: u8, q: u16) [p -> q = %dx, r = %al, #volatile] { #byte 0xEC }(port)
	return r
}

inw :: proc "contextless" (port: u16) -> u16 {
	r, _ := asm(p: u16) -> (r: u16, q: u16) [p -> q = %dx, r = %ax, #volatile] { #byte 0x66, 0xED }(port)
	return r
}

inl :: proc "contextless" (port: u16) -> u32 {
	r, _ := asm(p: u16) -> (r: u32, q: u16) [p -> q = %dx, r = %eax, #volatile] { #byte 0xED }(port)
	return r
}

// io_wait burns one I/O cycle on the unused POST diagnostic port. Legacy PIC
// and PIT programming need the delay between consecutive writes.
io_wait :: proc "contextless" () {
	outb(0x80, 0)
}

// -- Interrupt / halt state --------------------------------------------------

cli :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { cli }()
}

sti :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { sti }()
}

// hlt is its one byte rather than its mnemonic. The checker models `hlt` as
// an instruction nothing falls through, and a template with no way out is
// refused unless it is declared diverging. This one returns at the next
// interrupt, which is the whole point of it, so the byte says so.
hlt :: proc "contextless" () {
	asm() [#volatile, #clobber memory] { #byte 0xF4 }()
}

pause :: proc "contextless" () {
	asm() [#volatile] { pause }()
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
	lo, hi, _ := asm(m: u32) -> (lo, hi, m2: u32) [m -> m2 = %ecx, lo = %eax, hi = %edx, #volatile] { rdmsr }(msr)
	return u64(hi) << 32 | u64(lo)
}

write_msr :: proc "contextless" (msr: u32, value: u64) {
	// The same ties as the port writes above: `wrmsr` names no operands.
	_, _, _ = asm(m, lo, hi: u32) -> (m2, lo2, hi2: u32) [m -> m2 = %ecx, lo -> lo2 = %eax, hi -> hi2 = %edx, #volatile, #clobber memory] { wrmsr }(msr, u32(value), u32(value >> 32))
}

// -- Control registers -------------------------------------------------------

read_cr0 :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [#volatile] { mov r, %cr0 }()
}

write_cr0 :: proc "contextless" (value: u64) {
	asm(v: u64) [#volatile, #clobber memory] { mov %cr0, v }(value)
}

read_cr3 :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [#volatile] { mov r, %cr3 }()
}

write_cr3 :: proc "contextless" (value: u64) {
	asm(v: u64) [#volatile, #clobber memory] { mov %cr3, v }(value)
}

read_cr4 :: proc "contextless" () -> u64 {
	return asm() -> (r: u64) [#volatile] { mov r, %cr4 }()
}

write_cr4 :: proc "contextless" (value: u64) {
	asm(v: u64) [#volatile, #clobber memory] { mov %cr4, v }(value)
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

`cpuid` clobbers `rbx`. On x86-64, LLVM handles that with a save around the
block. On i386 it does not, because `ebx` is the PIC base, and the same
constraint is a trap. Callers must check `max_leaf` before they trust a leaf's
contents. An unimplemented leaf does not fault. It returns whatever the highest
implemented one does, and nothing tells that apart from a real answer.
*/
cpuid :: proc "contextless" (leaf: u32, subleaf: u32 = 0) -> CPUID_Result {
	a, b, c, d := asm(l, s: u32) -> (a, b, c, d: u32) [l -> a = %eax, s -> c = %ecx, b = %ebx, d = %edx] { cpuid }(leaf, subleaf)
	return CPUID_Result{eax = a, ebx = b, ecx = c, edx = d}
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
	return asm() -> (r: u64) [#volatile, #clobber memory] {
		pushfq
		pop r
	}()
}

/*
irq_save masks interrupts and reports whether they were on.

The uniprocessor lock. With one CPU, and no preemption other than the timer,
`nothing else can run` and `interrupts are off` are the same statement. A
critical section is therefore this and its matching restore. It stays correct
on SMP, as the *inner* half of a spinlock. What changes is that a lock word is
needed too. This does not stop being necessary.

Returns the previous state, rather than unconditionally enables on the way out,
because these nest. A handler that ran with interrupts already masked must not
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
