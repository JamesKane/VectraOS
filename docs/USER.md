# Userland: ring 3, the door back in, and a process

`kernel/user/`, and what the GDT, the IDT, the scheduler and `GS` grew to go
with it.

Everything before this ran at the privilege the loader handed over. The
scheduler switched stacks, the address spaces switched page tables, and all of
it was one program with many threads. This is where that stops being true.

**A program is bytes. A process is what runs them.** A process is an address
space, a namespace and a set of open files. It can open a file by name, read
it, write it, and rearrange its own view of the tree. It can also start
another process from a file it names:

    -- a program in ring 3 wrote this line
    -- a process opened this file by name
    -- this line went to /dev/null
    -- a process started this one

Four milestones live in this document, because they live in the same
directory. `docs/SPACE.md` built the piece under all four:

    ring 3        a thread can run somewhere it cannot damage the kernel
    a syscall     it can ask for something anyway
    a process     what it asks for belongs to it rather than to the kernel
    a spawn       and what it starts inherits the world it arranged

The third line is the one Plan 9 is about. Two processes hand the kernel the
same path and get different files, because the mount table belongs to the
process rather than to the machine. The fourth is what makes that
compositional: the namespace a process arranged is the namespace its children
resolve in.

## Three things make it ring 3 rather than a jump

Each of them fails in a way that looks like something else, and each has a
control below that shows exactly how.

**The selectors in the frame.** `arch.thread_user_init` puts `USER_CODE_SEL|3`
in CS and `USER_DATA_SEL|3` in SS. The RPL in those low two bits is what turns
the trap tail's `iretq` into a privilege change. With RPL 0 the same `iretq`
runs the same bytes at ring 0.

**A stack the CPU can push onto.** A trap from ring 3 loads RSP out of the TSS
before it pushes anything at all. `sched.reschedule` writes the incoming
thread's own kernel stack into that slot on every switch. A stale value is not
a fault, because the report of the problem is the push with nowhere to go.

**Somewhere for the fault to go.** A fault in the kernel is a failure to
report. A fault in a program is an ordinary outcome, and something has to end
the program and carry on. `arch.set_user_trap_handler` is a second table for
exactly that reason.

## There is still one resume path

**A thread whose first instruction is in ring 3 is laid out the same way as
every other thread.** `thread_user_init` writes a `Trap_Frame` and an FXSAVE
image onto the thread's kernel stack, in the place the trap tail would have left
them. The only difference from `thread_resume_init` is the selectors.

Nothing dispatches a user thread specially. The scheduler picks it and the tail
reloads `rsp` from its frame. The `iretq` at the end of that tail is the
instruction that enters ring 3. The CPU learns about the privilege change when
it reads CS out of the frame, and not before.

That was worth insisting on. A second entry path would be a second thing to get
right, and it would run once per program rather than once per preemption. The
path that runs rarely is the path that drifts.

## What the scheduler grew

Two stores, both on the incoming thread and both before it can run:

```odin
if next.space != prev_space(prev) { ... }   // the address space
if next.kstack_top != 0 { arch.set_kernel_stack(next.kstack_top) }
```

The first came with `docs/SPACE.md`. The second is new. It runs for every
thread that owns a stack, rather than only for the ones that will reach ring 3.
**The scheduler does not know which those are, and the cost of guessing wrong
is not a fault.**

`kstack_top` is cached on the thread rather than recomputed. `reschedule` runs
with interrupts off, and must not do arithmetic on a slice that could be nil.
`arch.kernel_stack_top` is the one definition of the number, and both
`thread_user_init` and `spawn_user` ask it.

The boot thread carries zero and the store is skipped. Its stack is the
loader's, and it will never be in ring 3 to come back from.

## A fault in a program ends the program

`arch.User_Trap_Handler` takes a `Trap` and a `Resume` and returns a `Resume`.
That signature is the whole difference from `Trap_Handler`, which returns a
bool. Only a user fault needs to change *where* execution resumes.

A handler that returned the state it was given would `iretq` back to the
faulting instruction and take the same fault for ever. So `user.on_trap`
records what happened and calls `sched.kill_current`, which marks the thread
dead and returns some other thread's state. That is the only way to end a
thread that is not cooperating.

**The handler runs in interrupt context and behaves like it.** Nothing
allocates, nothing takes a lock, and nothing logs. The report goes into the
program's own record, and whoever waits for it reads that in thread context,
where a console is safe to touch.

Finding the program is one load. `Thread.user` carries the record and the
scheduler never looks at it. A table searched by thread pointer would be the
same answer with a loop in a fault handler.

With no handler installed a user fault falls through to `kernel/panic.odin`,
which now says `in a program, at ring 3` on its first line. That is the right
default for a privilege level nothing claimed.

## Five programs, baked into the image

There is no loader and no file to load from, so the first thing ever to run in
ring 3 comes from the assembler. `kernel/user/program.odin` emits five blobs
the same way `kernel/arch/amd64/idt.odin` emits its 256 interrupt stubs.

**The copy into a frame is not an accident of having no filesystem.** No `User`
bit sits anywhere on the path to the kernel image, so a program could not
execute those bytes where they lie. A loader would have to copy them into pages
a program may reach, whatever the source was.

| Program | What it does | How it ends |
|---|---|---|
| `spin` | counts in its data page until the kernel says stop | `ud2`, on purpose |
| `poke` | writes to the address it was handed | a page fault |
| `peek` | reads from the address it was handed | a page fault |
| `priv` | executes `cli` | a general protection fault |
| `jump` | jumps into its own data page | a page fault on a fetch |
| `hello` | writes a line to `/dev/cons`, then exits with a status | `SYS_EXIT` |
| `probe` | makes six calls, keeps every answer, then runs on | `SYS_EXIT` |
| `shadow` | asks the kernel to read a page it may not read itself | `SYS_EXIT` |
| `namer` | opens a file by name, writes, closes, then gets two refusals | `SYS_EXIT` |
| `reader` | opens `/dev/zero`, reads into its page, then into its text | `SYS_EXIT` |
| `binder` | binds over `/dev/cons` in its own namespace, then writes twice | `SYS_EXIT` |

Every blob is position-independent, because a copy lands wherever the space
maps it. Every one writes a mark to its data page first, which is how the
kernel knows the program reached its first instruction at all.

`poke` runs twice, against two different addresses. Which address a blob
receives is what makes one run a test of the kernel half and another a test of
a read-only page.

The first five end in `ud2`, which was the only way out of ring 3 before there
was a system call. The last three end by asking.

## Three pages, and what each one refuses

    text    read and execute, and not write     0x00400000
    data    read and write, and not execute     0x00401000
    stack   read and write, and not execute     below 0x7ffff000

Every one of those is a fault the self-test provokes on purpose. A permission
nothing tests is a permission that may not be there. `mem.map_user` adds `User`
to all three, which is the bit that lets ring 3 reach them at all.

The data page is shared in the honest sense. The same frame carries two
mappings at two privilege levels, and neither is a copy. `spin` counts in it
while the kernel reads the count through the direct map, and the kernel writes
a stop word the program then reads.

## The self-test

**A program runs, the kernel keeps running under it, and everything the program
tries that it may not do is refused.** Every check is one of those three
sentences.

`spin` comes first because it is the only one that proves ring 3 *works* rather
than that it is enforced. A machine where the `iretq` never took the privilege
change still passes four of the five refusal tests, by faulting for the wrong
reason.

**The preemption check is progress on both sides, not a counter.** The
program's count moves while the boot thread also runs, and on one core that is
the definition of preemption. Both cannot make progress in the same ticks
otherwise.

**The TSS check watches its effect.** The fault record carries the address of
the frame the CPU pushed, and that address has to fall inside the faulting
thread's own kernel stack. A read of `arch.kernel_stack()` would agree with
whatever the scheduler last wrote, which is the field the code under test also
maintains.

The frame check names frames rather than totals them. Every program spawns a
thread, a thread's stack comes from the heap, and the heap never returns frames.
So the question goes to `mem.frame_is_free` about the three frames the last
program held, and the answer does not care what else allocated.

### `spin` gives up on its own, and that is load-bearing

The kernel normally stops `spin` by writing a word into its data page. The
program also stops itself after four hundred million rounds, and that safety
net is not decoration.

**A program entered with interrupts masked cannot be preempted.** Nothing else
on the core ever runs, so no bound the observer holds can help. The observer is
not scheduled. A loop that ends on its own is the only thing that survives it,
and the control below is exactly that mutation.

The limit is written twice, once as an Odin constant and once as an immediate
in the blob. There is no way to share it, for the same reason
`vector_has_error_code` cannot share its list with the assembler. They live in
the same file, and a check says the counter came back *below* the limit, so a
disagreement fails rather than hides.

### The controls for ring 3

Ten mutations, one at a time, each observed on a real boot.

| Mutation | Result |
|---|---|
| the user frame names the kernel's code selector | **#DF**, on a 4 KiB stack the panic handler ran off |
| the scheduler never writes the TSS stack slot | **the boot stops**, with nothing printed |
| nothing claims the user fault path | **#UD in a program, at ring 3**, named on the panic screen |
| the fault handler resumes instead of ending | 9 checks, first `having reached its first instruction` |
| the text page carries no user bit | 16 checks, first `and runs, which is the first instruction ever executed in ring 3` |
| the text page is writable | 4 checks, first `and faults on a page it can read and execute` |
| the data page is executable | 4 checks, first `on the stack it was given, in its own space` |
| a program is entered with interrupts masked | 3 checks, first `its counter moves, so it is running rather than parked` |
| the kernel takes down a running program | 4 checks, first `and the kernel will not take it down while it is still running` |
| the program record reaches the thread after the enqueue | **not caught** |

**Three of those are machine failures rather than failed checks**, and each is
the failure mode its section above predicted. The selector control runs the
program at ring 0, where its `ud2` is a kernel fault on a four-kilobyte stack.
The TSS control is a triple fault, which is exactly what `set_kernel_stack`
says it would be. The push that reports the problem is the push with nowhere to
go. The unclaimed-fault control produces the most readable panic screen in the
tree, naming a ring 3 address and a ring 3 stack.

**The uncaught one is the familiar shape.** `spawn_user` writes `Thread.user`
before it enqueues the thread, and the mutation moves that write after. The
window is one instruction wide, on a core where the enqueue holds a spinlock
until the line after it. It joins the cluster in `docs/TESTING.md`, and only a
second CPU makes it easy to reach.

### What a control found that the checks did not

The mutation that resumes instead of killing passed **the whole of `verify_spin`
first**, and that is worth knowing about.

`on_trap` records the exit and then ends the thread. A reader that sees
`exit.done` therefore learns the program stopped, one interrupt-disabled region
before the thread actually leaves the core. With the kill removed, `done` was
set and the thread carried on, so `destroy` freed the space the thread was
still translating through.

**On one core that ordering is safe and the argument is narrow.** The store and
the switch are inside the same handler, with interrupts off, so no observer can
run between them. It stops being safe on a second core, and it goes on the same
list as `Chan.refs`.

`SYS_EXIT` arrived one milestone later with the same shape and none of the
protection, because a dispatcher runs with interrupts on. It masks by hand. The
control below shows that the masking is not testable, which is the honest
reason to reason about it rather than trust a green line.

### The controls for the door

Eight more, the same way.

| Mutation | Result |
|---|---|
| the syscall stub does not swap `GS` | **a fault inside the panic handler**, and a halt |
| the interrupt tail does not swap `GS` | **a fault inside the panic handler**, and a halt |
| `STAR` names the wrong user base | **#GP**, once a program runs long enough after a `sysretq` |
| the stub does not save the floating-point state | 1 check, `the floating-point register the dispatcher writes over first` |
| the frame does not hold `r8` | 1 check, `one that adds its arguments gets all six of them` |
| `copy_in` does not require the `User` bit | 1 check, `the kernel refuses, because the page is not one the program may reach` |
| `SYS_EXIT` records the exit with interrupts on | **not caught** |
| `SFMASK` leaves IF set | **not caught** |

**Three of the eight are the checks doing their best work.** Each fails exactly
one check, and each names the property it broke. That is what a check aimed at
the effect rather than at a counter buys.

**Two came back clean, and both are windows a few instructions wide.** The
`SYS_EXIT` one is a store and a switch against a one-millisecond tick. The
`SFMASK` one is four instructions on a program's stack, in ring 0, waiting for
an interrupt that almost never arrives there. Neither is a weak check. Both are
races closed by reasoning, and the reasoning is above.

### The controls for a process

Six more.

| Mutation | Result |
|---|---|
| `copy_out` does not demand a page the program could write | **#PF in the kernel at `0x400000`**, from a program's argument |
| a process shares the kernel's namespace | 2 checks, first `and reaches the console, so one process changed only its own namespace` |
| `open` resolves in the kernel's namespace | 1 check, `and exactly one of the two reached the console` |
| a descriptor comes from the highest free slot | 9 checks, first `the write it asked for reported every byte` |
| a close forgets the file rather than closes it | 1 check, `and every namespace and open file with it (leaked 5)` |
| the standard descriptors open in the kernel's namespace | **not caught**, and the mutation is inert |

**The first one is the most alarming thing in this document.** Without the
`Write` demand in `copy_out`, a program names its own text page as a
destination and the kernel writes there. `CR0.WP` turns that into a page fault
**in the kernel**, so a program stops the machine with an address. The graceful
answer the check wanted is `EFAULT`, and the guard is what produces it. The
ungraceful one is what the hardware produces without it.

**The inert one is inert for a stated reason.** The standard descriptors open
through the process's fork rather than the kernel's namespace, and today the
fork is a faithful copy at that moment. Nothing rearranges it in between, so
the two are the same table. It becomes a real mutation the first time something
binds before a process starts, and `load`'s comment says so.

### Two controls changed the test rather than confirmed it

**The `User` bit had no test.** The mutation that removed it passed everything.
The only bad address the test handed over was a kernel one, and the range check
refused those first. The `shadow` program exists because of that, and it is now
the sharpest check in the file.

**The return path had no test either.** `sysret` writes CS and SS without
checking them, so a wrong `STAR` produced a program that ran correctly with
nonsense in CS. The first thing that reads CS is an interrupt, and every
program ended within a few instructions of its last call. `probe` now runs
twenty million rounds after the last `sysretq` returns, and the same mutation
is a #GP.

Both are the same lesson from opposite directions. **A control that passes is
asking whether the test ever reaches the code**, and twice here the answer was
no.

## The door: SYSCALL and SYSRET

An interrupt is the expensive way in. The CPU reads a descriptor, switches
stacks out of the TSS, and pushes five words. A fault needs all of that,
because a fault can arrive anywhere. A program asking for something does not.

**`syscall` changes almost nothing.** RIP goes to RCX and RFLAGS goes to R11.
CS and SS come from `STAR`, the bits in `SFMASK` come out of RFLAGS, and control
goes to `LSTAR`. It does not switch stacks. It does not push. RSP still points
wherever the program left it.

So the entry stub has to find a kernel stack with no register to trust and no
memory to name. `%gs:8` is what it finds one with, and that is the whole
argument for per-CPU state arriving in this milestone rather than an earlier
one.

### `STAR` is the register that cannot be fixed later

Bits 47:32 are the kernel pair, and SS comes from that plus 8. Bits 63:48 are
the user base, and a 64-bit `sysretq` takes CS from that plus 16 and SS from
that plus 8. That is why the user side of the GDT reads [code32, data, code64],
with a 32-bit descriptor nothing will ever load. It has since the milestone
that built the table.

**`sysret` does not check either selector.** It writes the numbers and sets the
hidden descriptor caches to fixed values. A wrong user base therefore produces a
program that keeps running, correctly, with nonsense in CS. The first thing that
reads CS is an interrupt. A control found that gap by passing, and the section
on controls says what closed it.

### The stub builds a `Trap_Frame`, and that buys three things

Fifteen pushes for the general-purpose registers, seven for the half an
interrupt would have pushed, and 512 bytes for the FXSAVE image.

**Every register survives, by construction.** A system call can promise a
program that only RAX, RCX and R11 change. It keeps that promise without
counting which registers a dispatcher might touch. The FXSAVE is not optional
either: Odin uses SSE registers for ordinary struct assignment, so the first
line of the dispatcher writes over `xmm0`.

**A system call can block.** The dispatcher is ordinary Odin on the thread's
own kernel stack, with interrupts back on. A lock that parks parks, and the
yield builds its own frame below this one. `SYS_SLEEP` is the proof, and the
check is the thread's wake-up count rather than the clock.

**A fault inside a system call reports like any other**, because the state is
already in the shape the reporting code reads.

The FXSAVE area needs no realignment, and that is arithmetic rather than luck.
A kernel stack top is 16-byte aligned, `Trap_Frame` is 176 bytes, and the seven
words above it are 56. The `#assert` on the frame size is what keeps it true.

### `GS`, and the one hazard it leaves

    in ring 0     GS_BASE = this core's record, KERNEL_GS_BASE = the program's
    in ring 3     GS_BASE = the program's,      KERNEL_GS_BASE = this core's

`swapgs` exchanges them, and every crossing does exactly one. The syscall stub
swaps on entry and before `sysretq`. **The interrupt tail had to learn the same
trick.** It decides from the CS the CPU pushed. That is offset 24 on the way
in, and offset 8 once the vector and the error code come off.

An NMI between the syscall stub's `swapgs` and its next instruction finds a
frame that says ring 3. Its tail swaps again, and the kernel runs with the
program's base. Nothing in Vectra reads `GS` inside a handler, so the two swaps
cancel and nothing is damaged. This stops being true the day a handler wants
per-CPU state, and the answer then is what Linux calls a paranoid entry.

`Percpu.kernel_rsp` holds the same number as the TSS, and `set_kernel_stack`
writes both. One writer, so they cannot drift. The TSS is what an interrupt
from ring 3 uses. This is what `syscall` uses, because `syscall` never looks at
the TSS.

## The five calls, and which of them are real

    rax           which call
    rdi rsi rdx   the first three arguments
    r10 r8 r9     the next three
    rax           the answer, or a negative errno out of sys/vectra9

`r10` rather than `rcx` in the fourth slot, because `syscall` puts the return
address in `rcx` before the stub can save it. Linux made the same substitution
for the same reason.

| Call | What it does |
|---|---|
| `exit` | ends the process with a status |
| `sleep` | parks the thread for a number of ticks |
| `open` | resolves a path **in this process's namespace** and returns the lowest free number |
| `close` | gives the number back |
| `read` | fills a program's buffer from one of its descriptors |
| `write` | empties one into a descriptor |
| `bind` | rearranges this process's view of the tree, and nobody else's |
| `seek` | moves a descriptor's cursor |
| `nop`, `args` | the door's own self-test |

**`exit` is what ring 3 lacked.** Before it, a program ended by doing something
the CPU refused, and `user.destroy` had to refuse a program that was still
running. Now a program can say so.

**`bind` is what makes this a Plan 9 system.** Every other call has a Unix
twin. This one does not, because in Unix the mount table belongs to the machine.

Three are still missing. `create` waits on `vfs.chan_create`. `stat` waits on
something that needs it. `mount` waits on a descriptor that can carry a
connection. All three are the same shape as the eight above, and none of them
is a design question.

### The record is written with interrupts off, and that is not tidiness

`SYS_EXIT` fills the program's exit record and then leaves the core. The
observer polls that record and takes the program's space and frames down when
it sees it. Between the store and the moment the thread stops, the thread is
still translating through that space.

A fault gets this property free, because a fault handler already runs masked.
This path had to ask for it. `docs/TESTING.md` has the control that found the
shape of the problem one milestone before it could happen.

## A process, and the two things a program did not have

A process is an address space, a namespace and a set of open files. The space
came with `docs/SPACE.md`. The other two arrive here, and `kernel/vfs` was
built for one of them four milestones before anything could use it.

### The namespace is a copy

`ns_fork` with `.Copy` duplicates the mount table and shares the member chans
underneath. A process can therefore rearrange its own view of the tree, and
nothing else on the machine sees the change.

**That sentence is the milestone, and `binder` is it as a check.** The program
binds `/dev/null` over `/dev/cons` in its own namespace, opens `/dev/cons`, and
writes a line. Then it writes the same line again, through the descriptor it
started with. Both writes report every byte. **The console moves once.**

The check is a total rather than two readings, because nothing can read the
console's cursor between two instructions of a program. The total is the
sharper claim anyway. It fails if the redirected write shows, and it fails if
the other one does not.

A control that shares the kernel's namespace instead of forking one fails a
different check afterwards. The kernel opens the same path, writes, and the
line does not appear, because a program moved the kernel's own console.

### A descriptor already open is not affected by a bind

A bind changes what a *path* resolves to. A descriptor names a chan, and no
rearrangement reaches it. That is Plan 9's rule, and it is the first one a
program notices. It is also why `binder` writes twice: once through a name and
once through a number.

### The descriptors

    0, 1, 2     open on /dev/cons when a process starts
    lowest free is what `open` returns

Lowest free is the rule every system with a shell depends on. A program that
closes descriptor 1 and opens a file gets descriptor 1 back. That is how output
goes to a file with no call for it. A control that returns the highest free
slot fails nine checks.

**The cursor is the process's, not the file's.** 9P has no cursor on the wire,
because every `Tread` and `Twrite` carries an offset. Somebody above the
protocol has to keep one, and two descriptors on one file have to be able to
read it at different places.

### What a process gives back, and the check that noticed

`unload` closes the descriptors, then the namespace, then the space. The order
matters. A chan holds a reference to its server, and the mount table holds
references to the chans it was built from.

**A frame count says nothing about either.** A chan and a `Namespace` are heap
objects. A process that gave back its pages and kept its open files leaves the
frame count balanced and nothing else wrong. So the run brackets the heap's
live-object count. A control that forgets to close a chan fails that line and
no other.

That bracket needed one thing to be true first. `sched.reap` runs before the
opening reading, because threads that exited in an *earlier* self-test keep
their records until something asks for them back. Without it the number came
out as **minus four objects**, which is a run that gave back more than it took.
A bracket that can go negative is not measuring what it says.

## `copy_in`, and the confused deputy

**Check every page, then read.** The kernel is translating through the
program's space at that moment, so a program's address is directly readable.
An unchecked read of a bad one faults in the kernel, and a program would have a
way to stop the machine with a number.

The check demands what the hardware demands of ring 3. The range is inside the
half a program may name, every page in it is present, and every page carries
`User`.

**The `User` bit is the one that matters, and it took a control to make it
testable.** The first version of the test handed the kernel a kernel address.
The range check refused that before permissions was ever consulted, so a
mutation dropping the `User` requirement passed everything.

The `shadow` program is what closed that. The kernel maps the program's own
stack frame at a second address in the program's own half, with no `User` bit.
It then tells the program where it is. The program can name that address and
cannot read it. **That is the confused deputy, in three pages**, and the
kernel's check is all that stands between a program and memory it may not
have.

There is still a window between the check and the read, and nothing closes it.
A second thread in the same space could unmap the page in between. Nothing can
unmap anything yet and a program has one thread, so the window is not
reachable. The first program with two threads reaches it.

## A process that starts another one

The fourth milestone, and the one the handoff called the step before
`servers/` stops being empty. Three pieces arrived together: a format, a
loader, and a pair of calls. `image.odin` holds the first two and
`spawn.odin` the third.

### The format is four words, and it is not ELF

    +0   magic      "VECTRA01", as eight bytes
    +8   entry      the virtual address of the first instruction
    +16  text       how many bytes of code follow the header
    +24  reserved   zero, and refused when it is not

An ELF loader is program headers, relocation kinds, and a dozen decisions
about what to refuse. All of that is worth having the day a real toolchain
emits the input. Today the input is a page of position-bound code, and the
format says exactly that. The check compares the reserved word against zero
rather than skips it. A format that ignores what it does not understand can
never mean anything new by it. So this kernel refuses an image from the
future, and says why.

The test probes the refusals field by field, against headers it builds
itself. No file on the machine carries any of these defects, and none ever
should. A wrong magic, a nonzero reserved word, an entry outside the text, a
text bigger than the page, a text of nothing. Each is one clause of
`image_check`. Each clause has one check that would notice it gone.

### The programs are files, behind `#b` at `/bin`

The loader could have read the blobs straight out of the kernel image. Then
`a program is a file` would have been a sentence in a document rather than a
property of the machine. Instead `image.odin` wraps the two blobs that stand
alone in headers at init. It publishes them through an ordinary read-only
server, registered as `#b` and bound at `/bin`. The server is
`vfs.Static_Tree`, the implementation behind `#/`.

The loader then walks a path like any other client, **through the namespace
of whoever asked**. A process whose `/bin` is rebound loads something else.
That is not a hole. It is the namespace doing its job. It is also how a test
harness will one day substitute a program without the program knowing.

### Spawn is fork and exec with the seam not yet cut

Plan 9 starts a process with `rfork` then `exec`, and the seam between them
is where a shell rearranges the child before replacing the program. Vectra
will want the seam the day it has a shell. What it needs today is the whole
arc: a new process, running a named file, inheriting what its parent chose.
`spawn` is that arc as one call.

Cutting it in two later is removal rather than redesign. The namespace flags
are `vfs.ns_fork`'s three cases taken one for one. The descriptor rule is
already `rfork`'s default. What a separate `rfork` adds is a child that
continues from the call site, which is a copied trap frame and copied user
pages. That work is deferred, not decided against.

What a child inherits, each by its own rule:

    the namespace     shared, copied, or clean -- the caller says which
    the descriptors   copied: same chans, referenced again, own cursors
    the program       none of it -- text, data and stack are fresh

The copy goes number for number rather than lowest-free, because the numbers
are the convention. A child's descriptor 1 must be whatever its parent's 1
was, or inheriting is renaming. A control that hands the child nothing
instead fails the wait-status checks twice, once per child.

A clean namespace still loads, because the loader reads through the
*parent's* namespace -- an exec reads through the namespace of whoever asked.
The child then cannot open anything, and the check says so in two errnos.
The open is ENOENT, because an empty namespace has no names. The write is
EBADF, because descriptors come from names too.

### Wait, pids, and who reaps

`wait` collects one ended child by pid. It reports the status the child
handed to `SYS_EXIT`, or EIO when a fault ended it. Only then does it take
the record down. Collecting is destroying: a second wait on the same pid is
ECHILD, and the parent program checks exactly that.

A process that is not the parent gets ECHILD too, whether or not the pid
exists. Waiting therefore probes nothing about the table. The control that
drops the parentage clause fails one check, the one built for it.

Pids are monotonic and never reused, for the same reason `kernel/srv` keeps
an id rather than a slot. The process table reuses slots, and a parent must
not collect a stranger that moved in. Zero is the kernel, which is why a
kernel-launched process has no parent a program could claim to be.

`wait` polls, one parked tick per miss, on the same argument `user.wait`
makes. The exit record comes from a path where nothing may take a lock or
wake a sleeper. The rendezvous it should become wants a wake that is legal in
a fault handler.

### Two children, one line

The self-test's showpiece. The kernel launches `/bin/parent` and then only
watches. Everything after that happens because a program asked. The parent
spawns `/bin/child`, which opens `/dev/cons` by name, writes its line, and
exits with its descriptor number and byte count folded into one status. The
parent collects it, binds `/dev/null` over `/dev/cons` in its own namespace,
and spawns the same file again.

Both children run the same program, open the same path, report the same
status. **The console moves once.** The second child's line went where its
parent's namespace sent it, which is the whole milestone in one number --
`binder`'s demonstration again, one generation deeper.

The two programs carry their strings in their own text, reached relative to
the instruction pointer. Nothing stages their data pages, because a file has
no side channel. A string in a text page is a buffer a system call may copy
in like any other, since the page is mapped readable.

## What is missing, and named where it lives

- **A process cannot be stopped from outside.** It can end itself now, and the
  kernel still cannot end it. `destroy` refuses a running process rather than
  free the tables underneath it, and the leak is visible in
  `user.stats().live`. Plan 9 ends a process with a note. That is this missing
  piece by its proper name.
- **No `rfork` proper, and no `exec` in place.** `spawn` starts a process
  from a file, and the seam Plan 9 cuts between creating and replacing is
  still fused. A child that continues from the call site needs a copied trap
  frame and copied user pages. A program that replaces itself needs its
  syscall frame rewritten under it. Both are mechanism, not design -- the
  inheritance rules are settled and stay.
- **`wait` polls.** A parked tick per miss, bounded by `WAIT_PATIENCE`. The
  rendezvous it should become needs a wake that is legal in a fault handler.
  A fault is one of the two ways a child ends.
- **No `create`, no `stat`, no `mount`.** The first waits on
  `vfs.chan_create`, the second on something that needs it, and the third on a
  descriptor that can carry a connection. `docs/SRV.md` says which line that
  is.
- **Nothing counts a process's calls against it.** `MAX_PROCESSES` bounds how
  many exist and `MAX_FDS` bounds what one holds. Nothing bounds what one asks
  for, and a single process can call `sleep` for ever.
- **`copy_in` and `copy_out` bound a call at 256 bytes**, on the calling
  thread's kernel stack. A program that asks for more gets a short answer and
  the count, which every write interface already makes a caller handle. A page
  the process pins would be the answer if it ever matters.
- **`MAX_PROCESSES` is twelve, from a fixed table.** The same argument
  `mem.spaces` and `srv.MAX_SERVICES` make. This is also the first code in
  Vectra that anything untrusted reaches. A record a program can make the
  kernel allocate is a record a program can exhaust the machine through.
- **No SMAP and no SMEP.** Neither bit is set in CR4, so the kernel may still
  read and execute a user page. It has no reason to, and the day it does by
  accident these are what would say so.

## See also

- `docs/SPACE.md` — the address space this runs in, and the kernel half it
  cannot reach.
- `docs/NAMESPACE.md` — where a program's write goes after `copy_in`, and the
  operations the next milestone puts behind the same door.
- `docs/SCHED.md` — the switch, and the two stores a user thread costs it.
- `docs/BOOT.md` — the GDT, the TSS and the trap path this extends.
- `docs/TESTING.md` — the self-test discipline, and the cluster the one
  uncaught control joins.
