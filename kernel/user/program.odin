/*
The programs, which are five short blobs of machine code baked into the image.

There is no loader yet and no file to load from. So the first thing ever to run
in ring 3 has to come from somewhere the kernel already has. The assembler emits
these the same way it emits the interrupt stubs. `user.load` then copies the
bytes into a frame it maps into a program's space.

**The copy is not an accident of having no filesystem.** No `User` bit sits
anywhere on the path to the kernel image, so a program cannot execute it where
it lies. A loader would have to copy it into pages a program may reach, whatever
the source was. That is what this does, minus the part that reads a file.

Every blob is position-independent, because a copy lands at whatever virtual
address the space maps it to. No blob names an absolute address, and the only
branches are relative. The two arguments arrive in the registers the frame was
built with:

    rdi   the program's data page, which the kernel can also read
    rsi   whatever the test wanted this program to touch

Each writes a mark to `rdi` before it does anything else. That mark proves the
program reached its first instruction. It is a different claim from the fault
that follows, which is about the instruction meant to fault.
*/
package user

/*
The mark each program writes to the first word of its data page.

Eight readable bytes rather than a counter. A kernel reads this out of a frame,
and it has no other way to know a program started. A wrong value in a hex dump
should say which program wrote it.
*/
MARK_SPIN :: u64(0x5350_494E_5350_494E) // SPINSPIN
MARK_POKE :: u64(0x504F_4B45_504F_4B45) // POKEPOKE
MARK_PEEK :: u64(0x5045_454B_5045_454B) // PEEKPEEK
MARK_PRIV :: u64(0x5052_4956_5052_4956) // PRIVPRIV
MARK_JUMP :: u64(0x4A55_4D50_4A55_4D50) // JUMPJUMP

/*
Where `spin` keeps its two words, in units of eight bytes from the data page.

`COUNTER` is what the program adds to and the kernel watches. `STOP` is what
the kernel writes and the program reads. Both directions of the same page,
which is the cheapest demonstration that a mapping is shared rather than
copied.
*/
CELL_MARK :: 0
CELL_COUNTER :: 1
CELL_STOP :: 2

/*
How many times `spin` goes round before it gives up on being told to stop.

A safety net rather than the mechanism. The kernel normally writes `STOP` once
the counter moves, and the loop ends within a few instructions. The limit is
what stops the machine when it does not.

That case is not hypothetical. A program entered with interrupts masked cannot
be preempted, so nothing else on the core ever runs. No bound the observer holds
can help, because the observer is not scheduled. A loop that ends on its own is
the only thing that survives it. See `docs/TESTING.md`.

**The number is written twice**, once here and once as an immediate in the blob
below, and the two have to agree. There is no way to share it. The assembler
consumes one at build time and Odin consumes the other at run time. That is the
problem `vector_has_error_code` has in `kernel/arch/amd64/idt.odin`, and this is
the same answer: they live in the same file, next to each other.

They also disagree loudly rather than quietly. `verify_spin` checks that the
counter came back *below* this, which is the claim that the kernel is what
stopped the program. A limit smaller than the blob's would fail that check, and
a limit the program can actually reach fails it too.

Four hundred million rounds is about a second of emulated ring 3. That is about
fifty times what the program reaches before the kernel tells it to stop.
*/
SPIN_LIMIT :: 400_000_000

/*
The blobs, and the symbols that bracket each one.

`foreign` with no library, the same way `vectra_isr_stubs` is declared: these
have an address and no storage, and the address is the value. A start and an
end for each, because `load` copies a range and nothing else knows how long a
blob is.
*/
@(private)
foreign {
	vectra_user_spin: byte
	vectra_user_spin_end: byte
	vectra_user_poke: byte
	vectra_user_poke_end: byte
	vectra_user_peek: byte
	vectra_user_peek_end: byte
	vectra_user_priv: byte
	vectra_user_priv_end: byte
	vectra_user_jump: byte
	vectra_user_jump_end: byte
}

@(private)
blob :: proc "contextless" (start, end: ^byte) -> []u8 {
	from := uintptr(start)
	to := uintptr(end)
	if to <= from {
		return nil
	}
	return (cast([^]u8)from)[:to - from]
}

// The five programs, each as the bytes to copy into a text page.
program_spin :: proc "contextless" () -> []u8 {return blob(&vectra_user_spin, &vectra_user_spin_end)}
program_poke :: proc "contextless" () -> []u8 {return blob(&vectra_user_poke, &vectra_user_poke_end)}
program_peek :: proc "contextless" () -> []u8 {return blob(&vectra_user_peek, &vectra_user_peek_end)}
program_priv :: proc "contextless" () -> []u8 {return blob(&vectra_user_priv, &vectra_user_priv_end)}
program_jump :: proc "contextless" () -> []u8 {return blob(&vectra_user_jump, &vectra_user_jump_end)}

/*
The five programs, emitted by the assembler.

`proc "naked"` for the same reason the interrupt stubs are: this is a container
for symbols, not a procedure. Nothing calls it. The `retq` the compiler puts
after it is unreachable, and would be ring 0 code in any case.

Each ends in `ud2`, which is the only way out of ring 3 that this milestone
has. There is no system call yet, so a program cannot ask to stop. It can only
do something the CPU refuses, and `ud2` is the one instruction whose whole
purpose is to be refused. Four of the five never reach it, because the
instruction before it is the fault the test is about.

`.balign 16` between them is for readability in a disassembly rather than for
correctness. Unlike the interrupt stubs, nothing indexes these by multiplying.
*/
@(export)
vectra_user_blob :: proc "naked" () {
	asm(){`
.balign 16
.globl vectra_user_spin
vectra_user_spin:
	movabsq $$0x5350494E5350494E, %rax
	movq %rax, (%rdi)
	movq $$400000000, %rcx
1:
	incq 8(%rdi)
	cmpq $$0, 16(%rdi)
	jne 2f
	decq %rcx
	jnz 1b
2:
	ud2
.globl vectra_user_spin_end
vectra_user_spin_end:

.balign 16
.globl vectra_user_poke
vectra_user_poke:
	movabsq $$0x504F4B45504F4B45, %rax
	movq %rax, (%rdi)
	movq $$1, (%rsi)
	ud2
.globl vectra_user_poke_end
vectra_user_poke_end:

.balign 16
.globl vectra_user_peek
vectra_user_peek:
	movabsq $$0x5045454B5045454B, %rax
	movq %rax, (%rdi)
	movq (%rsi), %rax
	movq %rax, 8(%rdi)
	ud2
.globl vectra_user_peek_end
vectra_user_peek_end:

.balign 16
.globl vectra_user_priv
vectra_user_priv:
	movabsq $$0x5052495650524956, %rax
	movq %rax, (%rdi)
	cli
	ud2
.globl vectra_user_priv_end
vectra_user_priv_end:

.balign 16
.globl vectra_user_jump
vectra_user_jump:
	movabsq $$0x4A554D504A554D50, %rax
	movq %rax, (%rdi)
	jmpq *%rsi
.globl vectra_user_jump_end
vectra_user_jump_end:
`, "~{memory}"}()
}
