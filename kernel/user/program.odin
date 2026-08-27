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
MARK_HELLO :: u64(0x4845_4C4C_4845_4C4C) // HELLHELL
MARK_PROBE :: u64(0x5052_4F42_5052_4F42) // PROBPROB
MARK_SHADOW :: u64(0x5348_4144_5348_4144) // SHADSHAD

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
Where the two programs that make system calls put their answers, and where
`hello` finds the line it prints.

One cell per call, in the order the program makes them, so a wrong answer names
the call rather than the program. The message starts at `MESSAGE_OFFSET`, past
every cell. A program hands the kernel that address, and the kernel has to
check it like any other.
*/
CELL_WROTE :: 1
CELL_NOP :: 1
CELL_ARGS :: 2
CELL_UNKNOWN :: 3
CELL_BAD_ADDRESS :: 4
CELL_SLEPT :: 5
CELL_HANDOFF :: 2
CELL_R8 :: 6
CELL_R12 :: 7
CELL_XMM :: 8
CELL_SPUN :: 9

MESSAGE_OFFSET :: 128

// What `probe` adds up and sends to `SYS_ARGS`. Six powers of two, so a lost
// or duplicated argument register changes the sum rather than hides in it.
ARGS_SUM :: u64(1 + 2 + 4 + 8 + 16 + 32)

// What `hello` asks to exit with. Any number that is not zero and not a
// plausible byte count.
HELLO_STATUS :: u64(0x2A)

/*
Three values `probe` puts in registers a system call promises not to touch.

`r8` is caller-saved under the System V C ABI and preserved under this one,
which makes it the interesting one. The dispatcher is a compiled procedure and
is entitled to destroy it. The frame the stub builds is what stops it.

`r12` is callee-saved either way and would survive a lax stub by accident.
`xmm0` would not survive anything: Odin uses SSE registers for ordinary struct
assignment, so the first line of the dispatcher writes over it. Only the
`fxsave` in the stub brings it back.
*/
KEEP_R8 :: u64(0x1234)
KEEP_R12 :: u64(0x5678)
KEEP_XMM :: u64(0x9ABC)

/*
How long `probe` runs in ring 3 after its last `sysretq`, and why it runs at
all.

**`sysret` does not validate the selectors it loads.** It writes CS and SS from
`STAR` and sets the hidden descriptor caches to fixed values. Nothing checks
that the GDT entries behind those numbers mean anything. So a wrong user base
in `STAR` produces a program that keeps running, correctly, with nonsense in
CS.

The first thing that reads CS is an interrupt, which pushes it. So a program
that returns from a call and exits at once never gives anything the chance to
notice. This loop is long enough for the timer to preempt it several times,
which is what makes the return path observable. A control found the gap by
passing.

Twenty million rounds is about fifty ticks.
*/
PROBE_SPIN :: 20_000_000

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
	vectra_user_hello: byte
	vectra_user_hello_end: byte
	vectra_user_probe: byte
	vectra_user_probe_end: byte
	vectra_user_shadow: byte
	vectra_user_shadow_end: byte
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

// The two that ask the kernel for something rather than have it refuse them.
program_hello :: proc "contextless" () -> []u8 {return blob(&vectra_user_hello, &vectra_user_hello_end)}
program_probe :: proc "contextless" () -> []u8 {return blob(&vectra_user_probe, &vectra_user_probe_end)}
program_shadow :: proc "contextless" () -> []u8 {return blob(&vectra_user_shadow, &vectra_user_shadow_end)}

/*
The five programs, emitted by the assembler.

`proc "naked"` for the same reason the interrupt stubs are: this is a container
for symbols, not a procedure. Nothing calls it. The `retq` the compiler puts
after it is unreachable, and would be ring 0 code in any case.

The first five end in `ud2`, which was the only way out of ring 3 the milestone
before this one had. A program could not ask to stop, so it did something the
CPU refuses. `ud2` is the one instruction whose whole purpose is to be refused.
Four of the five never reach it, because the instruction before it is the fault
the test is about.

`hello`, `probe` and `shadow` end with `SYS_EXIT` instead, and their `ud2` is
unreachable padding rather than a plan. Each keeps the data page in `rbx` and
the second argument in `rbp`, because those two survive a call and the argument
registers do not.

`shadow` waits for the kernel to publish an address into its data page before
it asks for anything. That handshake is the same one `spin` uses in the other
direction. It exists because the kernel has to map that address after the
program is already running. The wait is bounded, and a program that runs out
exits with a status that says so.

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

.balign 16
.globl vectra_user_hello
vectra_user_hello:
	movq %rdi, %rbx
	movq %rsi, %rbp
	movabsq $$0x48454C4C48454C4C, %rax
	movq %rax, (%rbx)

	movq $$1, %rdi
	leaq 128(%rbx), %rsi
	movq %rbp, %rdx
	movq $$2, %rax
	syscall
	movq %rax, 8(%rbx)

	movq $$0x2A, %rdi
	movq $$4, %rax
	syscall
	ud2
.globl vectra_user_hello_end
vectra_user_hello_end:

.balign 16
.globl vectra_user_probe
vectra_user_probe:
	movq %rdi, %rbx
	movq %rsi, %rbp
	movabsq $$0x50524F4250524F42, %rax
	movq %rax, (%rbx)

	xorl %edi, %edi
	movq $$0, %rax
	syscall
	movq %rax, 8(%rbx)

	movq $$1, %rdi
	movq $$2, %rsi
	movq $$4, %rdx
	movq $$8, %r10
	movq $$16, %r8
	movq $$32, %r9
	movq $$1, %rax
	syscall
	movq %rax, 16(%rbx)

	movq $$9999, %rax
	syscall
	movq %rax, 24(%rbx)

	movq $$1, %rdi
	movq %rbp, %rsi
	movq $$8, %rdx
	movq $$2, %rax
	syscall
	movq %rax, 32(%rbx)

	movq $$4, %rdi
	movq $$3, %rax
	syscall
	movq %rax, 40(%rbx)

	movq $$0x1234, %r8
	movq $$0x5678, %r12
	movq $$0x9ABC, %rax
	movq %rax, %xmm0
	xorl %edi, %edi
	movq $$0, %rax
	syscall
	movq %r8, 48(%rbx)
	movq %r12, 56(%rbx)
	movq %xmm0, %rax
	movq %rax, 64(%rbx)

	xorl %eax, %eax
	movq $$20000000, %rcx
3:
	incq %rax
	decq %rcx
	jnz 3b
	movq %rax, 72(%rbx)

	xorl %edi, %edi
	movq $$4, %rax
	syscall
	ud2
.globl vectra_user_probe_end
vectra_user_probe_end:

.balign 16
.globl vectra_user_shadow
vectra_user_shadow:
	movq %rdi, %rbx
	movabsq $$0x5348414453484144, %rax
	movq %rax, (%rbx)
	movq $$100000000, %rcx
1:
	movq 16(%rbx), %rsi
	testq %rsi, %rsi
	jnz 2f
	decq %rcx
	jnz 1b
	movq $$1, %rdi
	movq $$4, %rax
	syscall
	ud2
2:
	movq $$1, %rdi
	movq $$8, %rdx
	movq $$2, %rax
	syscall
	movq %rax, 8(%rbx)
	xorl %edi, %edi
	movq $$4, %rax
	syscall
	ud2
.globl vectra_user_shadow_end
vectra_user_shadow_end:
`, "~{memory}"}()
}
