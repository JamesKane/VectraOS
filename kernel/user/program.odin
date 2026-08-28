/*
The programs -- short blobs of machine code baked into the image.

The first thing ever to run in ring 3 had to come from somewhere the kernel
already had. There was no loader and no file to load from. The assembler
emits these the same way it emits the interrupt stubs. `user.load` copies the
bytes into a frame it maps into a program's space. `image.odin` wraps the two
that stand alone in the file format the loader reads.

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
MARK_NAMER :: u64(0x4E41_4D45_4E41_4D45) // NAMENAME
MARK_READER :: u64(0x5245_4144_5245_4144) // READREAD
MARK_BINDER :: u64(0x4249_4E44_4249_4E44) // BINDBIND
MARK_PARENT :: u64(0x5052_4E54_5052_4E54) // PRNTPRNT
MARK_CHILD :: u64(0x4348_4C44_4348_4C44) // CHLDCHLD
MARK_POSTER :: u64(0x504F_5354_504F_5354) // POSTPOST
MARK_NINER :: u64(0x4E49_4E45_4E49_4E45) // NINENINE
MARK_NOTER :: u64(0x4E4F_5452_4E4F_5452) // NOTRNOTR

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

/*
The four places a program looks for something the kernel put there.

Sixty-four bytes apart, past every cell, and named rather than numbered because
each program uses them for different things. `namer` finds a path in the first
and a path that is not there in the fourth. `binder` finds two paths and a line
to print.

`MESSAGE_OFFSET` is the first slot under its older name, which is what `hello`
still calls it.
*/
SLOT_A :: 128
SLOT_B :: 192
SLOT_C :: 256
SLOT_D :: 320

MESSAGE_OFFSET :: SLOT_A

/*
Where the three programs that open files keep their answers.

One cell per call, in the order the program makes them. A wrong answer names
the call rather than the program, which is the only reason to spend five cells
where one would do.
*/
NAMER_OPENED :: 1
NAMER_WROTE :: 2
NAMER_CLOSED :: 3
NAMER_AFTER_CLOSE :: 4
NAMER_MISSING :: 5

READER_OPENED :: 1
READER_READ :: 2
READER_REFUSED :: 3
READER_CLOSED :: 4
READER_BUFFER :: 8 // Byte offset 64, which is where the read lands

BINDER_BOUND :: 1
BINDER_OPENED :: 2
BINDER_WROTE :: 3
BINDER_CLOSED :: 4
BINDER_AGAIN :: 5

/*
Where the two programs that reproduce keep their answers.

`child` and `parent` are the first blobs that carry their own strings, in
their own text, reached relative to the instruction pointer. Nothing stages a
path into their data pages, because nothing could. The kernel does not start
them, another program does. A file has no side channel. The cells below are
therefore answers only -- one per call, in call order, as always.
*/
CHILD_OPENED :: 1
CHILD_WROTE :: 2
CHILD_CLOSED :: 3

PARENT_SPAWN_A :: 1
PARENT_WAIT_A :: 2
PARENT_AGAIN :: 3
PARENT_BOUND :: 4
PARENT_SPAWN_B :: 5
PARENT_WAIT_B :: 6
PARENT_MISSING :: 7

/*
Where `poster` keeps its answers -- one cell per call, in call order.

The story the cells tell, in one pass. Open a connection, and reserve a name
in `/srv`. Write the descriptor into it, and mount the name. Reach the
console through the mount. Take the name away, and show the mount survives
it.

The descriptor it writes is the digit `3` in its own text. The first cell is
the check that 3 is what the open really returned.
*/
POSTER_OPENED :: 1
POSTER_CREATED :: 2
POSTER_WROTE_FD :: 3
POSTER_REWROTE :: 4
POSTER_CLOSED :: 5
POSTER_MOUNTED :: 6
POSTER_VIA :: 7
POSTER_WROTE :: 8
POSTER_REMOVED :: 9
POSTER_GONE :: 10
POSTER_AGAIN :: 11
POSTER_WROTE_AGAIN :: 12

// The line `poster` sends through the service it published, written twice in
// the blob's own text like every string a spawned program carries.
POSTER_LINE :: "-- this line went through a posted service"

/*
Where `niner` keeps its answers -- one cell per call, then a count that moves.

The story the cells tell. Make a pipe, and hold both ends. Reserve a name in
`/srv`, and write the client end's digit into it. Give both spent
descriptors back. Then serve: read a 9P request off the pipe, answer it, and
count it. The count is the one cell that changes while the kernel watches,
because the kernel is the client this time.
*/
NINER_PIPE :: 1
NINER_CREATED :: 2
NINER_POSTED :: 3
NINER_CLOSED_SRV :: 4
NINER_CLOSED_END :: 5
NINER_SERVED :: 6

// What `sys_pipe` answers `niner`: the serve end on 3 and the client end on
// 4, packed the way `child` packs its status. Descriptors 0 through 2 arrived
// occupied, which this number also proves.
NINER_FDS :: u64(4 << 8 | 3)

// What `niner` exits with when its byte stream ends before a Tremove does.
// Any number a deliberate exit never uses.
NINER_TORN :: u64(0x77)

/*
The line `niner` answers a Tread with, written twice like every string a
spawned program carries. Once here for the check, once as `.ascii` bytes in
the blob. Its length is hard-coded twice more, as immediates in the Rread
the blob builds. All four have to agree, and the check fails loudly when
they drift.
*/
NINER_READ_LINE :: "these bytes came from ring 3"

/*
Where `noter` keeps its answers -- one cell per call, in call order.

The story is the note's arc from ring 3. Spawn a child that loops for ever,
note it, and collect an ending the child never chose. The wait answers
EINTR, which is the kernel saying a note did this. Then note a pid that is
nobody's child, and hear ECHILD, which is the wall between one process's
authority and the table.
*/
NOTER_SPAWNED :: 1
NOTER_NOTED :: 2
NOTER_WAITED :: 3
NOTER_STRANGER :: 4

// The line the kernel writes through a mounted `/srv/niner`, which `niner`
// forwards to the console. It lives here rather than in the blob: the payload
// of a Twrite is the client's to choose, and the client is the kernel.
NINER_ECHO_LINE :: "-- a process answered this line"

/*
The line `child` writes, and the paths the two blobs open.

**Each of these is written twice**: once here for the checks, and once as
`.ascii` bytes inside the blob that uses it. The pairs have to agree.
There is no way to share them: the assembler consumes one at build time and
Odin the other at run time. That is `SPIN_LIMIT`'s problem again, with the
same answer: the copies live in the same file, and a check fails loudly when
they drift. The blobs also hard-code each string's length as an immediate,
which is a third copy of one fact about it.
*/
CHILD_LINE :: "-- a process started this one"

/*
What `child` exits with: its descriptor in the high byte, the bytes it wrote
in the low. One number that says the open landed on 3 -- so descriptors 0
through 2 were inherited, occupied -- and the write reported the whole line.
Both children exit with it: the one whose line reached the screen, and the
one whose line went to `/dev/null`. That is the point. The two runs differ
only in what the namespace did with the bytes.
*/
CHILD_STATUS :: u64(3 << 8 | len(CHILD_LINE))

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
	vectra_user_namer: byte
	vectra_user_namer_end: byte
	vectra_user_reader: byte
	vectra_user_reader_end: byte
	vectra_user_binder: byte
	vectra_user_binder_end: byte
	vectra_user_parent: byte
	vectra_user_parent_end: byte
	vectra_user_child: byte
	vectra_user_child_end: byte
	vectra_user_poster: byte
	vectra_user_poster_end: byte
	vectra_user_niner: byte
	vectra_user_niner_end: byte
	vectra_user_noter: byte
	vectra_user_noter_end: byte
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

// The three that open files by name, in a namespace of their own.
program_namer :: proc "contextless" () -> []u8 {return blob(&vectra_user_namer, &vectra_user_namer_end)}
program_reader :: proc "contextless" () -> []u8 {return blob(&vectra_user_reader, &vectra_user_reader_end)}
program_binder :: proc "contextless" () -> []u8 {return blob(&vectra_user_binder, &vectra_user_binder_end)}

// And the four that stand alone -- the blobs `/bin` publishes as files.
// Two reproduce, one publishes a service, and one *answers* one. See
// `image.odin`.
program_parent :: proc "contextless" () -> []u8 {return blob(&vectra_user_parent, &vectra_user_parent_end)}
program_child :: proc "contextless" () -> []u8 {return blob(&vectra_user_child, &vectra_user_child_end)}
program_poster :: proc "contextless" () -> []u8 {return blob(&vectra_user_poster, &vectra_user_poster_end)}
program_niner :: proc "contextless" () -> []u8 {return blob(&vectra_user_niner, &vectra_user_niner_end)}
program_noter :: proc "contextless" () -> []u8 {return blob(&vectra_user_noter, &vectra_user_noter_end)}

/*
The programs, emitted by the assembler.

`parent` and `child` are the two with `.ascii` bytes after their code. Their
strings ride in their own text, reached relative to the instruction pointer,
because nothing stages their data pages: a file has no side channel. The text
page is mapped readable, so a string in it is a buffer a system call may
copy in like any other.

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

.balign 16
.globl vectra_user_namer
vectra_user_namer:
	movq %rdi, %rbx
	movq %rsi, %rbp
	movq %rdx, %r12
	movabsq $$0x4E414D454E414D45, %rax
	movq %rax, (%rbx)

	leaq 128(%rbx), %rdi
	movq %rbp, %rsi
	movq $$1, %rdx
	movq $$5, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	leaq 256(%rbx), %rsi
	movq %r12, %rdx
	movq $$2, %rax
	syscall
	movq %rax, 16(%rbx)

	movq %r13, %rdi
	movq $$6, %rax
	syscall
	movq %rax, 24(%rbx)

	movq %r13, %rdi
	leaq 256(%rbx), %rsi
	movq %r12, %rdx
	movq $$2, %rax
	syscall
	movq %rax, 32(%rbx)

	leaq 320(%rbx), %rdi
	movq %rbp, %rsi
	xorl %edx, %edx
	movq $$5, %rax
	syscall
	movq %rax, 40(%rbx)

	xorl %edi, %edi
	movq $$4, %rax
	syscall
	ud2
.globl vectra_user_namer_end
vectra_user_namer_end:

.balign 16
.globl vectra_user_reader
vectra_user_reader:
	movq %rdi, %rbx
	movq %rsi, %rbp
	movabsq $$0x5245414452454144, %rax
	movq %rax, (%rbx)
	movq $$-1, %rax
	movq %rax, 64(%rbx)

	leaq 128(%rbx), %rdi
	movq %rbp, %rsi
	xorl %edx, %edx
	movq $$5, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	leaq 64(%rbx), %rsi
	movq $$8, %rdx
	movq $$7, %rax
	syscall
	movq %rax, 16(%rbx)

	movq %r13, %rdi
	movq $$0x400000, %rsi
	movq $$8, %rdx
	movq $$7, %rax
	syscall
	movq %rax, 24(%rbx)

	movq %r13, %rdi
	movq $$6, %rax
	syscall
	movq %rax, 32(%rbx)

	xorl %edi, %edi
	movq $$4, %rax
	syscall
	ud2
.globl vectra_user_reader_end
vectra_user_reader_end:

.balign 16
.globl vectra_user_binder
vectra_user_binder:
	movq %rdi, %rbx
	movq %rsi, %rbp
	movq %rdx, %r12
	movabsq $$0x42494E4442494E44, %rax
	movq %rax, (%rbx)

	leaq 128(%rbx), %rdi
	movq %rbp, %rsi
	leaq 192(%rbx), %rdx
	movq %rbp, %r10
	xorl %r8d, %r8d
	movq $$8, %rax
	syscall
	movq %rax, 8(%rbx)

	leaq 192(%rbx), %rdi
	movq %rbp, %rsi
	movq $$1, %rdx
	movq $$5, %rax
	syscall
	movq %rax, 16(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	leaq 256(%rbx), %rsi
	movq %r12, %rdx
	movq $$2, %rax
	syscall
	movq %rax, 24(%rbx)

	movq %r13, %rdi
	movq $$6, %rax
	syscall
	movq %rax, 32(%rbx)

	movq $$1, %rdi
	leaq 256(%rbx), %rsi
	movq %r12, %rdx
	movq $$2, %rax
	syscall
	movq %rax, 40(%rbx)

	xorl %edi, %edi
	movq $$4, %rax
	syscall
	ud2
.globl vectra_user_binder_end
vectra_user_binder_end:

.balign 16
.globl vectra_user_parent
vectra_user_parent:
	movq %rdi, %rbx
	movabsq $$0x50524E5450524E54, %rax
	movq %rax, (%rbx)

	leaq 4f(%rip), %rdi
	movq $$10, %rsi
	movq $$1, %rdx
	movq $$10, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	movq $$11, %rax
	syscall
	movq %rax, 16(%rbx)

	movq %r13, %rdi
	movq $$11, %rax
	syscall
	movq %rax, 24(%rbx)

	leaq 5f(%rip), %rdi
	movq $$9, %rsi
	leaq 6f(%rip), %rdx
	movq $$9, %r10
	xorl %r8d, %r8d
	movq $$8, %rax
	syscall
	movq %rax, 32(%rbx)

	leaq 4f(%rip), %rdi
	movq $$10, %rsi
	movq $$1, %rdx
	movq $$10, %rax
	syscall
	movq %rax, 40(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	movq $$11, %rax
	syscall
	movq %rax, 48(%rbx)

	leaq 7f(%rip), %rdi
	movq $$12, %rsi
	movq $$1, %rdx
	movq $$10, %rax
	syscall
	movq %rax, 56(%rbx)

	xorl %edi, %edi
	movq $$4, %rax
	syscall
	ud2
4:
	.ascii "/bin/child"
5:
	.ascii "/dev/null"
6:
	.ascii "/dev/cons"
7:
	.ascii "/bin/no-such"
.globl vectra_user_parent_end
vectra_user_parent_end:

.balign 16
.globl vectra_user_child
vectra_user_child:
	movq %rdi, %rbx
	movabsq $$0x43484C4443484C44, %rax
	movq %rax, (%rbx)

	leaq 8f(%rip), %rdi
	movq $$9, %rsi
	movq $$1, %rdx
	movq $$5, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	leaq 9f(%rip), %rsi
	movq $$29, %rdx
	movq $$2, %rax
	syscall
	movq %rax, 16(%rbx)

	movq %r13, %rdi
	movq $$6, %rax
	syscall
	movq %rax, 24(%rbx)

	movq %r13, %rdi
	shlq $$8, %rdi
	orq 16(%rbx), %rdi
	movq $$4, %rax
	syscall
	ud2
8:
	.ascii "/dev/cons"
9:
	.ascii "-- a process started this one"
.globl vectra_user_child_end
vectra_user_child_end:

.balign 16
.globl vectra_user_poster
vectra_user_poster:
	movq %rdi, %rbx
	movabsq $$0x504F5354504F5354, %rax
	movq %rax, (%rbx)

	leaq 10f(%rip), %rdi
	movq $$9, %rsi
	movq $$1, %rdx
	movq $$5, %rax
	syscall
	movq %rax, 8(%rbx)

	leaq 11f(%rip), %rdi
	movq $$10, %rsi
	movq $$1, %rdx
	movq $$384, %r10
	movq $$12, %rax
	syscall
	movq %rax, 16(%rbx)
	movq %rax, %r14

	movq %r14, %rdi
	leaq 14f(%rip), %rsi
	movq $$1, %rdx
	movq $$2, %rax
	syscall
	movq %rax, 24(%rbx)

	movq %r14, %rdi
	leaq 14f(%rip), %rsi
	movq $$1, %rdx
	movq $$2, %rax
	syscall
	movq %rax, 32(%rbx)

	movq %r14, %rdi
	movq $$6, %rax
	syscall
	movq %rax, 40(%rbx)

	leaq 11f(%rip), %rdi
	movq $$10, %rsi
	leaq 12f(%rip), %rdx
	movq $$4, %r10
	xorl %r8d, %r8d
	movq $$13, %rax
	syscall
	movq %rax, 48(%rbx)

	leaq 13f(%rip), %rdi
	movq $$9, %rsi
	movq $$1, %rdx
	movq $$5, %rax
	syscall
	movq %rax, 56(%rbx)
	movq %rax, %r15

	movq %r15, %rdi
	leaq 15f(%rip), %rsi
	movq $$42, %rdx
	movq $$2, %rax
	syscall
	movq %rax, 64(%rbx)

	leaq 11f(%rip), %rdi
	movq $$10, %rsi
	movq $$14, %rax
	syscall
	movq %rax, 72(%rbx)

	leaq 11f(%rip), %rdi
	movq $$10, %rsi
	movq $$1, %rdx
	movq $$5, %rax
	syscall
	movq %rax, 80(%rbx)

	leaq 16f(%rip), %rdi
	movq $$9, %rsi
	movq $$1, %rdx
	movq $$5, %rax
	syscall
	movq %rax, 88(%rbx)
	movq %rax, %rdi
	leaq 15f(%rip), %rsi
	movq $$42, %rdx
	movq $$2, %rax
	syscall
	movq %rax, 96(%rbx)

	xorl %edi, %edi
	movq $$4, %rax
	syscall
	ud2
10:
	.ascii "/dev/cons"
11:
	.ascii "/srv/cons2"
12:
	.ascii "/mnt"
13:
	.ascii "/mnt/cons"
14:
	.ascii "3"
15:
	.ascii "-- this line went through a posted service"
16:
	.ascii "/mnt/null"
.globl vectra_user_poster_end
vectra_user_poster_end:

/*
niner -- the first 9P server that is a program.

It makes a pipe, posts the client end in /srv, and then answers requests it
reads off the serve end. It answers version, attach, walk and open, and
forwards a write's payload to the console. It answers a read from its own
text, and the remove tells it to stop. The replies are built byte by byte
over the request, because a program this small carries no codec. The frame
layout is the 9P2000.L wire format, and docs/VECTRA9.md is the reference.

Register roles, for reading the loop:

    rbx    the data page
    r12    the frame buffer, at rbx+256
    r13    the serve descriptor
    r14    the current frame's size
    r15    the served count
    rbp    the read cursor, and then the stop flag
    r8/r9  the send cursor and length, in registers a system call preserves
*/
.balign 16
.globl vectra_user_niner
vectra_user_niner:
	movq %rdi, %rbx
	movabsq $$0x4E494E454E494E45, %rax
	movq %rax, (%rbx)
	leaq 256(%rbx), %r12

	movq $$15, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r13
	andq $$255, %r13
	movq 8(%rbx), %r14
	shrq $$8, %r14
	andq $$255, %r14

	leaq 20f(%rip), %rdi
	movq $$10, %rsi
	movq $$1, %rdx
	movq $$384, %r10
	movq $$12, %rax
	syscall
	movq %rax, 16(%rbx)
	movq %rax, %r15

	movq %r15, %rdi
	leaq 21f(%rip), %rsi
	movq $$1, %rdx
	movq $$2, %rax
	syscall
	movq %rax, 24(%rbx)

	movq %r15, %rdi
	movq $$6, %rax
	syscall
	movq %rax, 32(%rbx)

	movq %r14, %rdi
	movq $$6, %rax
	syscall
	movq %rax, 40(%rbx)

	xorl %r15d, %r15d
23:
	xorl %ebp, %ebp
24:
	movq %r13, %rdi
	leaq (%r12,%rbp), %rsi
	movq $$7, %rdx
	subq %rbp, %rdx
	movq $$7, %rax
	syscall
	testq %rax, %rax
	jle 38f
	addq %rax, %rbp
	cmpq $$7, %rbp
	jb 24b

	movl (%r12), %r14d
	cmpq $$256, %r14
	ja 38f
	cmpq $$7, %r14
	jb 38f
25:
	cmpq %r14, %rbp
	jae 26f
	movq %r13, %rdi
	leaq (%r12,%rbp), %rsi
	movq %r14, %rdx
	subq %rbp, %rdx
	movq $$7, %rax
	syscall
	testq %rax, %rax
	jle 38f
	addq %rax, %rbp
	jmp 25b
26:
	xorl %ebp, %ebp
	movzbl 4(%r12), %eax
	cmpl $$100, %eax
	je 27f
	cmpl $$104, %eax
	je 28f
	cmpl $$110, %eax
	je 29f
	cmpl $$12, %eax
	je 31f
	cmpl $$118, %eax
	je 32f
	cmpl $$116, %eax
	je 33f
	cmpl $$120, %eax
	je 35f
	cmpl $$122, %eax
	je 36f
	movl $$11, (%r12)
	movb $$7, 4(%r12)
	movl $$95, 7(%r12)
	movq $$11, %rdx
	jmp 37f
27:
	movb $$101, 4(%r12)
	movq %r14, %rdx
	jmp 37f
28:
	movl $$20, (%r12)
	movb $$105, 4(%r12)
	movb $$0x80, 7(%r12)
	movl $$0, 8(%r12)
	movq $$1, 12(%r12)
	movq $$20, %rdx
	jmp 37f
29:
	movzwl 15(%r12), %ecx
	movb $$111, 4(%r12)
	movw %cx, 7(%r12)
	leaq 9(%r12), %rsi
30:
	testl %ecx, %ecx
	jz 39f
	movb $$0, (%rsi)
	movl $$0, 1(%rsi)
	movq $$2, 5(%rsi)
	addq $$13, %rsi
	decl %ecx
	jmp 30b
39:
	movzwl 7(%r12), %eax
	imull $$13, %eax, %eax
	addl $$9, %eax
	movl %eax, (%r12)
	movl %eax, %edx
	jmp 37f
31:
	movl $$24, (%r12)
	movb $$13, 4(%r12)
	movb $$0, 7(%r12)
	movl $$0, 8(%r12)
	movq $$2, 12(%r12)
	movl $$0, 20(%r12)
	movq $$24, %rdx
	jmp 37f
32:
	movl 19(%r12), %edx
	movq $$1, %rdi
	leaq 23(%r12), %rsi
	movq $$2, %rax
	syscall
	movl 19(%r12), %eax
	movl %eax, 7(%r12)
	movl $$11, (%r12)
	movb $$119, 4(%r12)
	movq $$11, %rdx
	jmp 37f
33:
	movl $$39, (%r12)
	movb $$117, 4(%r12)
	movl $$28, 7(%r12)
	leaq 22f(%rip), %rsi
	leaq 11(%r12), %rdi
	movq $$28, %rcx
34:
	movb (%rsi), %al
	movb %al, (%rdi)
	incq %rsi
	incq %rdi
	decq %rcx
	jnz 34b
	movq $$39, %rdx
	jmp 37f
35:
	movl $$7, (%r12)
	movb $$121, 4(%r12)
	movq $$7, %rdx
	jmp 37f
36:
	movl $$7, (%r12)
	movb $$123, 4(%r12)
	movq $$7, %rdx
	movq $$1, %rbp
37:
	incq %r15
	movq %r15, 48(%rbx)
	movq %rdx, %r9
	xorl %r8d, %r8d
40:
	movq %r13, %rdi
	leaq (%r12,%r8), %rsi
	movq %r9, %rdx
	subq %r8, %rdx
	movq $$2, %rax
	syscall
	testq %rax, %rax
	jle 38f
	addq %rax, %r8
	cmpq %r9, %r8
	jb 40b
	testq %rbp, %rbp
	jnz 41f
	jmp 23b
38:
	movq $$0x77, %rdi
	movq $$4, %rax
	syscall
	ud2
41:
	xorl %edi, %edi
	movq $$4, %rax
	syscall
	ud2
20:
	.ascii "/srv/niner"
21:
	.ascii "4"
22:
	.ascii "these bytes came from ring 3"
.globl vectra_user_niner_end
vectra_user_niner_end:

/*
noter -- a process that ends another one.

Spawn /bin/spin, which never makes a system call and never stops on its
own. Note it, and wait: the answer is -EINTR, the kernel's word for a note
that ended a child. Then note pid 9999, which is nobody's child, and record
the ECHILD. Each answer lands in its cell, in call order, as always.
*/
.balign 16
.globl vectra_user_noter
vectra_user_noter:
	movq %rdi, %rbx
	movabsq $$0x4E4F54524E4F5452, %rax
	movq %rax, (%rbx)

	leaq 24f(%rip), %rdi
	movq $$9, %rsi
	movq $$1, %rdx
	movq $$10, %rax
	syscall
	movq %rax, 8(%rbx)
	movq %rax, %r13

	movq %r13, %rdi
	leaq 25f(%rip), %rsi
	movq $$4, %rdx
	movq $$16, %rax
	syscall
	movq %rax, 16(%rbx)

	movq %r13, %rdi
	movq $$11, %rax
	syscall
	movq %rax, 24(%rbx)

	movq $$9999, %rdi
	leaq 25f(%rip), %rsi
	movq $$4, %rdx
	movq $$16, %rax
	syscall
	movq %rax, 32(%rbx)

	xorl %edi, %edi
	movq $$4, %rax
	syscall
	ud2
24:
	.ascii "/bin/spin"
25:
	.ascii "stop"
.globl vectra_user_noter_end
vectra_user_noter_end:
`, "~{memory}"}()
}
