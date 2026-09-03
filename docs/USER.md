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

```
-- a program in ring 3 wrote this line
-- a process opened this file by name
-- this line went to /dev/null
-- a process started this one
-- this line went through a posted service
-- a process answered this line
```

Ten milestones live in this document, because they live in the same
directory. `docs/SPACE.md` built the piece under all of them:

    ring 3        a thread can run somewhere it cannot damage the kernel
    a syscall     it can ask for something anyway
    a process     what it asks for belongs to it rather than to the kernel
    a spawn       and what it starts inherits the world it arranged
    a posting     and what it holds open, it can publish by name
    a service     and what it publishes, it can answer -- the kernel as client
    a runtime     and the server can be a program a compiler built
    a note        and what will not stop can be stopped, from outside
    an rfork      and one process can become two, sharing what they choose
    a handler     and a note it catches is a signal, not only a kill
    an exec       and a process can become another program, in place

The third line is the one Plan 9 is about. Two processes hand the kernel the
same path and get different files, because the mount table belongs to the
process rather than to the machine. The fourth makes that compositional: the
namespace a process arranged is the namespace its children resolve in. The
fifth closes the circle -- names are not only consumed from ring 3 but made
there, and `/srv` is where they change hands.

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
ring 3 comes from the kernel's own image. `kernel/user/program.odin` embeds
the blobs `build.odin` made out of `kernel/user/programs`, one Odin package
compiled once per program for whichever architecture the kernel is built
for. They were assembly until the ports made that three suites.

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
run between them. On a second core the scheduler lock is held across the
switch, and `docs/SMP.md` says why that closes the same window.

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

Seven more.

| Mutation | Result |
|---|---|
| `copy_out` does not demand a page the program could write | **#PF in the kernel at `0x400000`**, from a program's argument |
| a process shares the kernel's namespace | 2 checks, first `and reaches the console, so one process changed only its own namespace` |
| `open` resolves in the kernel's namespace | 1 check, `and exactly one of the two reached the console` |
| a descriptor comes from the highest free slot | 9 checks, first `the write it asked for reported every byte` |
| a close forgets the file rather than closes it | 1 check, `and every namespace and open file with it (leaked 5)` |
| the standard descriptors open in the kernel's namespace | **not caught**, and the mutation is inert |
| `fd_seek` stores zero whatever it was asked | 3 checks, first `the first pixel is on the screen where the offset says` |

The seek control is the counter lesson yet again, from a new side. `sys_seek`
answers the offset it was *asked*, so the cell `painter` records it in agreed
with the mutation. What disagreed was the screen: `fb.get_raw` at the pixel
the offset names, which no bookkeeping of the door's can fake.

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

### The controls for the note handler

Four, and `catcher` is what most of them fail through. It is a process that
catches two notes and survives, with a magic number a handler trashes and
`noted` restores.

| Mutation | First failure |
|---|---|
| the tick delivers no handler and ends the program | `the tick hands the handler the frame it interrupted` |
| `deliver_note` never sets `notified`, so `noted` cannot confirm | `and the process is still alive` (6 checks) |
| `NCONT` resumes without restoring the saved frame | `and the process is still alive` (5 checks) |
| the door delivers no handler on a parked program's note | `and the program comes back from both` -- the second note, at the door, never lands |

The last is the one that names the door's own boundary. `catcher`'s first
note arrives at the tick, mid loop. Its second arrives while the program is
parked in `sleep`, where the tick cannot reach it. The door is the only way
in, and a door that ignores the handler hangs the program on a note that
never delivers.

**Two guards an honest handler cannot reach are left uncaught by name.**
`noted` rebuilds the selectors and masks the resume flags against a handler
that hands back a kernel CS or a cleared IF. `catcher` hands back the frame
it was given, already a legal ring 3 frame, so neither guard fires. Reaching
them needs a hostile handler, which is a POSIX signal test's job the day
there is one. `docs/TESTING.md` calls a control that cannot be expressed a
different thing from one that fails to fire.

### The controls for exec and the orphan

Five. `execer` replaces itself with `/bin/child`, and `nowaiter` forks a
child no parent waits for. The console moving and a record collected are what
the mutations break.

| Mutation | First failure |
|---|---|
| exec does not rewrite the syscall frame | `the mark is the new program's, not the old one's` (5 checks) |
| exec skips the CR3 switch after the space swap | `the mark is the new program's` -- the process faults into the space it no longer has |
| `RFNOWAIT` does not detach the child | `the child stands alone, detached to the kernel` (leaked 13) |
| a dying parent does not reparent its children | `the parent's going reparented the child to the kernel` |
| `reap_orphans` collects nothing | `reap_orphans collects it -- the orphan leak retired` (leaked 8) |

The two leaks in that table are the point being made in one number. A child
nothing detaches, or nothing reaps, stays in `stats().live`, and the run's
own heap bracket counts it. The leak was the milestone's whole reason, and
its retirement is a count that goes back to where it started.

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

These are the mechanism's first calls. The interface grew past them since,
and each later call is written up where its milestone lives. Only `stat` is
still absent, and it is the same shape as the calls above rather than a
design question.

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
A sibling that shares the page could unmap it in between -- and `rfork` means
the sibling exists now. What does not exist, still, is any way to unmap: no
call takes a mapping away, so the window stays unreachable. The first unmap
reaches it, and the answer then is the one every kernel reaches for: fault
the read and recover from it.

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

### Spawn is fork and exec, and both halves are cut now

Plan 9 starts a process with `rfork` then `exec`, and the seam between them
is where a shell rearranges the child before replacing the program. `spawn`
is still the whole arc as one call, for a caller that wants it whole. But the
two halves it fused both stand on their own now. `rfork` is the creating half
-- two processes from one call. `exec` is the replacing half -- one program
becomes another, in place.

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

`wait` parks on the exit rendezvous now, and every path out of a process
wakes it. The wake from a fault turned out to be legal after all.
`sync.wakeup_all` masks rather than enables, which is the argument the
keyboard's top half already ran on. The note section below has the story.

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

## A process that publishes a service

The fifth milestone, and the small one: three system calls and a program.
Everything hard about it was already built on one side or the other.
`docs/SRV.md` owns the design: the pending entry, the decimal write, and the
confused deputy the fd resolver answers. What lives here is the door's side
of it.

`create` makes a file where a path says and returns a descriptor on it.
Behind it is `vfs.create_path`, the `Tlcreate` client path that retired one
of the named gaps. It is a separate call rather than a flag on `open`, which
is Plan 9's split and 9P's. Two messages, two calls, and the folding is a
translation layer's job.

`mount` attaches a posted service by its `/srv` path and binds it in the
caller's own namespace. It is the pair to `bind`,
with the descriptor elided the way `srv.mount` documents. `remove` takes a
name away, and is mostly `Tremove` reaching ring 3.

The resolver `kernel/user` registers is the piece worth knowing about. When
a program writes a descriptor number into a `/srv` entry, the handler asks
this package what the number means *for the current process*. It can ask,
because `#s` is synchronous and its handler runs on the writing thread.
Descriptor tables belong here, so the answer does too. A kernel thread gets
nil and the write gets EBADF.

`/bin/poster` is the milestone as a program. It opens `/dev/cons`, creates
`/srv/cons2`, and writes the digit `3` from its own text. Then it mounts the
name it just published at `/mnt` in its own namespace. The line it writes
through `/mnt/cons` lands on the screen -- a process reaching hardware
through a name no kernel put anywhere. Then it removes the name, shows
`/srv/cons2` is gone, and opens `/mnt/null` through the mount that survives
it. Removal ends the name, not the service, which is Plan 9's rule and now a
check.

## A process that answers 9P

The sixth milestone, and the one the layout in `docs/HANDOFF.md` waited on:
a transport whose far side is a process. One system call and one program
live here. The transport itself is `kernel/mnt`'s wire over `kernel/pipe`,
and those documents own it. What this package added is the descriptor shape
of it, and the first program that is a server.

`pipe` makes a pipe and answers with both ends, packed as two descriptors.
End 0 sits in the low byte and end 1 in the next, which is the packing
`child`'s exit status already uses. From there nothing about the ends is
special. They travel to children through `spawn`, they close through `close`,
and either one can go into a `/srv` entry. That write is what makes the far
side of a pipe a *service*, and it changed nothing in the posting path.
Posting always took the chan behind the descriptor, and a pipe end is a chan.

`/bin/niner` is the milestone as a program, and it is the first blob that is
a server rather than a client. It makes a pipe, posts end 1 as `/srv/niner`,
and closes both spent descriptors, because the posting owns its reference
now. Then it serves end 0: read a frame, look at the kind, answer under the
same tag. It echoes `Tversion` and cans `Rattach`, `Rwalk` and `Rlopen`. It
forwards a `Twrite`'s payload to the console, answers a `Tread` from its own
text, and exits on `Tremove`. No codec and no tables: a 9P frame is small
enough to build byte by byte over the request.

The kernel is the client for all of it. The self-test mounts `/srv/niner`,
and the mount's handshake is the first 9P message a process ever answered. It
resolves a path through walks the program serves, and writes a line that
comes back out on the console. Then it reads bytes the program's text
carries, and sends the remove that stops it. Every message crosses ring 3
twice as bytes.

The teardown taught the one lesson worth recording here. The process goes
down *first*, so the wire notices the hangup, and only then does the mount
come down. The mount's close clunks a fid on the wire. A clunk to a poisoned
wire fails at once, where a clunk to a merely silent server would wait for
ever. A server that dies fails its clients fast. A server that goes quiet
holds them, and the note is what ends that, not the wire.

## A program a compiler built

The seventh milestone moved the ceiling rather than the walls, and it lives
in its own document: `docs/RUNTIME.md`. What this package contributed is the
loader's second format and the split it forced.

`load_program` asks the file which shape the process gets. A VECTRA01 blob
still gets the three named pages the blobs were written against. A VECTRA02
image gets a page span per segment, each mapped with the permissions its row
asked for. Under those go a four-page stack, and a stack pointer tilted the
eight bytes the SysV ABI assumes. `servers/ramfs` -- an Odin program with
`sys/vectra9` linked in -- loads through it, posts a service, and serves a
file tree the kernel reads, writes and lists.

Two of this package's rules moved with it. `sys_exit` closes the process's
descriptors before it ends, in thread context where a clunk is legal. A
control found that an exited server otherwise holds its pipe open and its
clients park for ever. And `load` split into `load_held` and `launch`,
because a flake caught the self-tests staging a data page while the thread
already ran. Both stories are told in full in `docs/RUNTIME.md`.

## The note

The eighth milestone, and the one every gap in this file pointed at. A
process could end itself or fault, and nothing could end it from outside. A
runaway loop held its core, a hung server held its clients, and `wait` polled
because no ending could wake anybody. One mechanism retires all of it, and it
is Plan 9's, minus the half a program registers. `post_note` marks the
target's thread, and delivery is an ending at the next kernel boundary the
thread crosses.

Three boundaries, because a process can be doing three things:

    running in ring 3    the next tick catches it -- `note_trap`, interrupt
                         context, the fault path's twin
    entering the door    the dispatch check ends it before the call runs --
                         `note_exit`, thread context, so its descriptors
                         close with it
    parked in a sleep    `sync.sleep_noted` returns false, EINTR unwinds to
                         ring 3, and the door finishes the job

The third is the one with reach. A pipe's flows wait interruptibly now, so a
server parked with nothing to serve dies of a note within a tick. A read that
waits on a device -- the console -- becomes a loop of bounded waits, with the
note checked between. The transport's flush already knew how to pay for that.
A kernel thread is never noted, so every one of these paths costs it nothing.

The endings meet in one place: an exit rendezvous every path out of a process
wakes. `wait` and `wait_pid` park on it, which is the polling retired, and
the self-test's promptness check is what keeps the wake a wake. A noted child
answers its parent's `wait` with EINTR, distinct from a fault's EIO on
purpose. A parent that noted its own child expects the one and not the other.
`SYS_NOTE` grants ring 3 the same power over its own children only. A pid
that is nobody's child answers ECHILD, exactly like a pid that never existed,
so noting teaches nothing about the table.

A faulting process gives its descriptors back too, and that took a thread.
Both of its ways of dying are in interrupt context, where nothing may close a
file, so the release could not happen where the death does. See **The hangup a
fault could not perform** below.

## The note handler

The other half of Plan 9's notify, and the thing that turns a note from a
kill into a signal. A process registers a handler with `notify`. Delivery
then does not end it. The kernel pushes the interrupted frame and the note's
text onto the user stack and redirects the program into the handler. The
handler ends with `noted` -- `NCONT` to resume the frame it was handed,
`NDFLT` to take the death the note always was. An alarm, a hangup, or an
interrupt a program means to catch stop being spelled the same as a kill.

**Delivery reuses the two boundaries that delivered the ending.** The tick
redirects the frame it interrupted, in interrupt context. So `deliver_note`
takes no lock and checks every stack page before it writes. The mappings it
writes through are live, because it delivers to the thread running right
now. The door aborts the call and hands the handler the frame, EINTR in
`rax`, so `NCONT` resumes into the answer Plan 9 promises. A stack too small
for the frame is the one case delivery cannot survive, and there the process
ends, noted, as before.

**`noted` trusts nothing the handler hands back.** The frame returns through
`copy_in`, and the parts a program must not choose are rebuilt from the
kernel's own constants. The selectors go back to ring 3's, the flags keep
only the arithmetic bits, and the resume point must sit in the program's
half. A handler that hands back garbage dies exactly as a
program that faulted, one syscall removed. The `iretq` would refuse a bad CS
anyway, but a guard that leans on the hardware refusing fails later, with
less to say.

One delivery runs at a time, and `notified` on the process is the interlock.
A note posted while the handler runs stays flagged on the thread and lands
at the first boundary after `noted` finishes. `notify` refuses to swap the
handler mid-delivery, because the frame on the stack belongs to the running
handler. The self-test's `catcher` takes two notes across two boundaries and
lives, a register the handler trashes restored each time -- the frame
round-trip proven, not asserted.

**The group fan-out is `notepg`**, a post to every process in a note group
but the poster. That is a write to Plan 9's `/proc/n/notepg`, and its
`postnotepg` to the line: the poster is skipped, and so would a kernel
process be. A pid names the group, under the authority rule `note` and `wait` share.
Zero is the caller's own group, and a child's pid is that child's. `RFNOTEG` stopped being a recorded flag the same day.

`grouper` forks one child into its own group and one into a group of one,
notes its own group, and exactly one of them ends. Three controls, each on
a real boot:

| Mutation | Result |
|---|---|
| the poster is noted too | 14 checks, first `a note to its own group reached exactly one process`, and the parent's leak |
| the group is ignored, and every child hears it | 2 checks, first the same |
| the note reaches nobody | 10 checks, first `and comes back`, because the parent waits for a child that never ends |

And no FPU state crosses a delivery. A handler that computes in
XMM clobbers what the interrupted code had there. That is `Ureg`'s edge in
Plan 9 too, named here for the day a program mixes floating point and notes.

## rfork

The ninth milestone, and the seam cut from one side. `spawn` was fork and
exec as one arc. `rfork(RFPROC)` is the fork half on its own: two
processes return from one call. The parent gets the child's pid and the
child gets zero, both at the instruction after the `syscall`. `rfork.odin`
owns the mechanism, and three new objects carry it:

    a segment       the frames behind one mapping, refcounted -- the owner
                    `mem/space.odin`'s file comment always pointed at.
                    `segment.odin`
    a descriptor    the fd table as a refcounted group, so a fork can share
    group           it, which is Plan 9's default. `fdtable.odin`
    a cloned frame  `arch.thread_user_clone`: the door already saved every
                    register in the resumable layout, so continuing from
                    the call site is a copy with rax answered zero

Per segment, Plan 9's copy rule. Text and read-only segments are shared
always -- nothing can write them, so a copy would buy nothing. Writable
data is copied unless `RFMEM` shares it. **The stack is copied always,
whatever the flags say.** The child continues at the parent's stack
addresses. The child's own frames must therefore stand behind those
addresses, or two threads unwind one stack.

This is also why the child of an `RFMEM` fork can share every global with
its parent and still return from the function that forked.

The descriptor group made two exit rules explicit, both stated in
`fdtable.odin` as invariants rather than habits. A system call *takes* a
chan: a reference of its own, under the table's lock, never a borrowed
slot. A sibling's close can spend a slot while a read is parked on it. And
an exit *releases* the group rather than closing descriptors, because a
child's death must not close its sibling's files. The exit paths detach
the table before publishing the exit record. `unload` releases only what
is still attached, and the chans close when the last holder leaves.

The flag word is Plan 9's bit for bit. The unimplemented bits -- `RFREND`,
`RFNOMNT` -- are refused with EINVAL rather than skipped, so each can come
to mean its whole self later. `RFNOTEG` is accepted and recorded.
`RFNOWAIT` is implemented now, below. `RFENVG` and `RFCENVG` do to the
environment group what `RFFDG` and `RFCFDG` do to the descriptor table;
`docs/ENV.md` has the group. Without `RFPROC` the namespace, descriptor
and environment flags act on the caller in place, which is how a process
unshares later than it forked.

**`copy_in`'s check-then-read window is still unreachable.** Two processes
can now share writable pages, but the window needs the *page* to go away
mid-copy, and nothing -- still -- can unmap anything. The answer stays the
same for the day something can: fault the read and recover.

`servers/consrv` is the milestone as a program, and `docs/RUNTIME.md` owns
it. A proto console server: the `RFMEM` child parks reading `/dev/cons`,
the parent serves 9P, and they meet in a producer-consumer ring in the
shared bss. It is the sentence the handoff kept for three milestones: a
server that waits on two things at once. Its teardown is the note doing
the job it was built for. The parent notes its reader out of a parked
device read, collects EINTR, and exits zero only if it heard it.

## exec, and the orphan the seam left

`exec` is the replacing half of the seam `rfork` cut. A process names a
file, and the program running becomes that file's: same pid, same
descriptors, same namespace, new text, new data, new stack. Before it, a
shell arranges the child -- a redirect, a bind -- and then replaces the
program under everything it arranged.
Keeping the descriptors and the namespace is the whole reason the two are
separate calls. The one piece of process state exec must drop is the note
handler, an address in text that no longer exists.

**The correctness is all in the order.** The new image is built in a *fresh*
space first, before anything of the old one is touched. A file that is not a
program then leaves the caller running, unharmed, with the errno.
`load_program` writes its space, segments and aliases into whatever record
it is handed. A stack-local scratch then holds exactly what a commit moves
and a failure releases.

Only once the new image is whole does exec commit, and past that point
nothing may fail. It releases the old segments, moves the new space in,
loads its CR3, frees the old space, and rewrites the syscall frame.

That last step is the milestone's one new piece of machinery,
`arch.frame_enter_user`. The call crossed the door, so the door's return is
a `sysretq`, which reads `rip`, `rflags` and `rsp` back out of the frame.
Setting those three to the new program's entry is what makes the return land
in a new image rather than back in the old one. Every other register is
cleared, so nothing of the old program leaks across. `exec` therefore
returns only on failure, exactly as `SYS_EXIT` and `SYS_RFORK` take the
frame and do not return the ordinary way.

The self-test's `execer` writes its own mark, execs `/bin/child`, and the
console moving is the proof. `execer` never opened `/dev/cons`. The standard
descriptors it was born with are what `child` writes through, which is the
redirect a shell sets up before it execs.

## The orphan, collected at last

An rfork child whose parent exits first was an honest leak for a milestone.
No `wait` could reach it, because pids never reuse and nothing reparented.
Two mechanisms retire it, and both end at `reap_orphans`.

`RFNOWAIT` is the flag that chooses it up front. A child forked with it is
the kernel's from birth, parent zero and `detached` set. Its own parent
cannot `wait` for it, and hears ECHILD like a stranger's pid. Plan 9's
detached child, exactly.

Reparenting is the safety net for the child that did not choose it.
`reparent_children` runs in `unload`, before the dying process's pid is
zeroed, and hands every live child of it to the kernel with `detached` set.
That is Plan 9's reparent-to-init, with the kernel standing in for init. A
child that outlives its parent stops being a dangling pointer to a pid nobody
holds.

`reap_orphans` is where a detached process's record finally comes back. It
collects every detached process whose `exit.done` is set, and leaves the
still-running ones for a later pass. The reaper thread calls it at every
ending now, so a detached process goes back the moment it ends. A fork that
wants a slot and a `segbrk` about to believe a count still call it first. A kernel-launched process is never `detached`, so the reaper leaves
the self-test's own processes for it to destroy by name. See the reaper's
own section below.

## Memory a program asks for

`SYS_SEGALLOC`, and `Segment_Kind.Anon` behind it. A program hands over a byte
count and gets back an address. `docs/DRAW.md` section 10 named this call a
milestone before it existed, and named it correctly as a memory question rather
than a graphics one:

- A 640 by 800 window is 2 MB.
- `MAX_PROGRAM_FRAMES` is 64, so one segment was at most 256 KB.
- `MAX_PROC_SEGS` is 6, so a whole process was at most 1.5 MB.

Static `bss` was all a program had, and the image format bounds it. So a
compositor could not hold one window's pixels. Neither could anything else that
wanted memory in proportion to its work rather than to its source.

**The kind is the device's shape with the ownership put back.** A device
segment already carried a base and an extent, because a thousand frames do not
fit a frame list of sixty-four. An anonymous segment is the same description of
memory this allocator *did* hand out, so the last release hands it in.
`segment_is_run` is the one predicate that separates the two shapes from the
five kinds. Three places care: `segment_frame`, `segment_release` and
`fork_segments`. Each asks in one word, and a sixth kind joins the right shape
in one edit.

**One search over both calls, and that is what makes them disjoint.**
`segattach` and `segalloc` both take their addresses from `map_reserve`, which
searches the process's own segment list for the lowest free span. The list is
the record of what is taken, so a range `segdetach` freed is a hole the next
call lands in. Two regions with two searches would need an argument about which
one grows into the other, and one region has none to make.

A child inherits its parent's runs as its own list along with its address
space. So its first `segalloc` searches those and lands clear of them. There is
no mark to carry over: the list is the map, and the child has a copy of it the
moment `fork_segments` returns.

**`rfork` treats it as data, because that is what it is.** Text is shared,
device memory is shared unconditionally, and a run of anonymous memory answers
`RFMEM` the way a writable data segment does. A private copy is one allocation
and one walk rather than a page at a time, because a run is contiguous at both
ends. The only thing that made it not a `.Data` segment was the shape it is
described in.

The pages are zero, writable and never executable. Zero because the frames came
back from a program that ended, which `mem.alloc_pages_zeroed` is now the one
place to say. Never executable for the reason a framebuffer is not: memory a
program fills is memory a program can be tricked into jumping into.

**There is a bound, and there had to be.** `SEGALLOC_MAX` is 4 MB, which is two
of that window. `MAX_PROC_SEGS` limits how many segments a process may hold,
and this limits how large each one is. A resource with only one of those two is
not a bounded resource. Both are caps to raise rather than designs.

Nothing releases a run before the process ends. The reason is `segattach`'s
own: a program that asks for a backing store holds it until it exits. The
subsection below names what Plan 9 has there and Vectra does not.

### Where this leaves Plan 9

Read against 9front's `sys/src/9/port/segment.c` and `sysproc.c`, because the
call above is the first one in this kernel that answers with memory rather than
with bytes.

**The fork rule is Plan 9's, to the line.** `dupseg` puts `SG_TEXT`,
`SG_SHARED` and `SG_PHYSICAL` in the group that increments a reference and
shares. `SG_STACK` always makes a new segment. `SG_BSS` reads:

    case SG_BSS:            /* Just copy on write */
        if(share) goto sameseg;
        n = newseg(s->type, s->base, s->size);

That is `.Anon` under `RFMEM`, and it is where the rule in `fork_segments`
came from. Two more agree without an edit. `mapphys` addresses a physical
segment as `s->pseg->pa + (addr - s->base)`, which is `segment_frame`'s
`.Device` arithmetic. And a faulted `SG_BSS` page is `fillpage(new, 0)`, so
zeroed anonymous memory is Plan 9's promise too. Vectra zeroes at the call and
Plan 9 zeroes at the fault. That is one machine's answer about paging, rather
than a difference about what a program may read.

**`segalloc` exists as the price of the descriptor.** In Plan 9 there is one
call for this. `segattach(attr, class, va, len)` looks `class` up in a fixed
kernel table. The table is seeded with `"shared"` and `"memory"`, and drivers
extend it at run time. `addvgaseg` registers the framebuffer as a named class
carrying `SG_PHYSICAL|SG_DEVICE|SG_NOEXEC`. So anonymous memory is `"memory"`,
the screen is `"vgascreen"`, and both go through one door.

`docs/DRAW.md` section 7 refused that table and gave the reason. A kernel table
of class names is a permission story a namespace cannot overrule, and this
kernel already has a better one. **That refusal is the more Plan 9 answer, and
it has a bill, which is this call.** A descriptor names a device because a
device is a file, and nothing is the file for memory that no server has.

So a second call was the only way to ask for it. Anyone reading `segalloc` as
an independent design decision has it backwards. It is the second half of one
decision made a milestone earlier.

**Three calls Plan 9 has here. Vectra has one of them now.**

| Plan 9 | What it does | Here |
|---|---|---|
| `segbrk(addr, top)` | grows or shrinks a segment in place | **built** -- see below |
| `segfree(va, len)` | frees the pages under a range, keeps the segment | **deferred** -- see `segdetach` below |
| `segdetach(addr)` | takes the whole segment out of the process | **built** -- see below |

`segbrk` is the interesting one. `syssegbrk` refuses `SG_TEXT`, `SG_DATA`,
`SG_STACK`, `SG_PHYSICAL`, `SG_FIXED` and `SG_STICKY` by name, and answers for
`SG_BSS` and `SG_SHARED` alone. So Plan 9 says out loud that in-place resize is
a question only anonymous memory may be asked. `docs/DRAW.md` section 10 names
a resize as a thing a backing store makes cheap, and `segbrk` is the call that
sentence needs.

## segbrk, and the unmap nothing had

**Nothing in this kernel could unmap a page.** `map_user` installed and
`space_destroy` tore down a whole tree at exit, and in between there was no way
to take one translation away -- `kernel/user/syscall.odin` said so out loud
while explaining why a window a client gave back stayed unreachable rather than
reused.

`mem.unmap_at` is `map_at`'s inverse to the line: the same walk, and a clear
where the other installs. A page that was never mapped is not an error, and the
tables themselves stay -- freeing an empty one means proving no other entry in
it is live, which is a walk of its own. `space_destroy` was always where a
process's tables were going to go.

The flush is unconditional. A translation cached for a frame that has gone back
to the allocator is the one thing this must not leave behind.

**Unreachable before freed, always.** A shrink unmaps and then frees, in that
order, so there is no instant where ring 3 can reach a frame somebody else
owns.

### What Plan 9 refuses, and what this refuses on top

`syssegbrk` refuses every segment type but `SG_BSS` and `SG_SHARED`, by name.
This answers for `.Anon` alone, which is the same sentence: in-place resize is
a question only anonymous memory may be asked. A `.Device` run is the
framebuffer, whose extent is the hardware's.

A `top` of zero answers the run's base rather than moving anything, which is
`ibrk`'s query form.

**A shared run shrinks in every holder at once.** It used to refuse, which is
`ibrk`'s `Einuse`: another process mapped the same frames, and the ones about
to go back could be somewhere in that process's kernel, past the point where
an address was checked. The shrink reaches every holder's tables now, and
every core running one of them, before a frame goes back. The section on a
run that is shared as it evolves says how.

### A run is a list of pieces now, and that was forced

The first cut grew a run by allocating a bigger block, copying, and releasing
the old one. That is correct for a run one process holds and **wrong for one
shared under `RFMEM`**: the sharer maps the old frames in its own space, and
nothing reachable from the growing process can remap that space.

It is not a theoretical case. `servers/intuition` forks a reader child for the
keyboard, so every window run it holds is shared, and a moving grow refused
every single one -- which is to say it refused the only caller the milestone
was built for.

So a run is a base, an extent, and up to `MAX_RUN_PIECES` more of the same. A
grow bolts a piece on the end and takes pages nobody had. It used to leave a
sharer's mapping as it was, without the new tail. It reaches every holder's
tables now, which is the section below.

Plan 9 needs none of this. Its segments are a page map a fault fills in, so
`ibrk` extends the map and nothing moves. This is the same idea with the pieces
bigger, and the cap is on how many times one run may grow rather than on how
big it gets.

### What it bought

`servers/intuition`'s `window_size` refused anything taller than the window its
slot was born with, and `docs/DRAW.md` recorded that as this call's absence
speaking. A client asks for a client area and the server grows the run under
it now.

**Growing must work, and shrinking works too now.** A shared run could not
shrink, and that was a reason to keep the pages rather than to refuse the
client. It shrinks in every holder at once now, and the section below says
how. A window that gets smaller gives its pages back, and a window that cannot
get bigger is the cap this call exists to lift.

The server's runs stopped being shared when `segdetach` arrived and they
became the session's, and the first shrink was still refused. The runtime
forks a worker per parked request under `RFMEM`. A worker that answered and
exited keeps its segments until the next fork collects it. Three dead
workers from the keyboard's checks each still counted as a holder. So
`segbrk` collects the orphans before it walks the holders, the way `rfork`
does before it wants a slot. A dead holder is one fewer space to walk.

### A shared run is shared as it evolves

`RFMEM` shares the frames a run has at the fork, in the sharer's own tables.
Plan 9's segment is a page map a fault fills in.

A grow by one proc is faulted
in by every proc that shares the segment, and nothing has to walk anything.
Vectra's tables are eager, so a resize walks every holder. A grow maps the new
piece into each holder's space. A shrink takes the tail out of each holder's
tables, and tells every core running any of them to drop the translations. Only
then does it give the frames back. That order is what keeps a frame from being
reused while a core still translates through it.

The holders are found under the process-table lock, which also keeps a second
resize off the run while one is under way. Each space has a lock of its own
over its walks. A holder may be mapping something else on another core at the
same instant. The shootdown is sent after both are let go of, because it waits
for other cores. A wait under a spinlock is the hazard `sync.require_sleepable`
names.

The check is `sharer`, in `verify_rfork`. The parent grows a shared run and
writes a witness into the new page, and the child reads it through its own
tables. The parent then shrinks the run, and the child's next touch of that
page is a page fault, on whichever core the child is. The control whose
shrink reaches only the caller's tables leaves the child reading the page
after the shrink, and its exit status says so.

### The controls

| Mutation | Result |
|---|---|
| `segbrk` answers success without allocating | **breaks the machine** |
| the new pages are never mapped | **breaks the machine** |
| `segbrk` answers for any segment kind | 2 checks, first `and a card cannot be resized, because its extent is the hardware's` |
| a grown run reads every page out of its first piece | **breaks the machine**, on the third try -- see below |
| a shrink frees the tail and forgets to unmap it | 1 check, `every mapped page is inside a segment the process holds` |
| a grown window is not taller on the glass | 1 check, `and stands that much taller on the glass, which no frame count could say` |

The first two stop the boot rather than failing a check, and that is the shape
a grow has: the draw server asks for rows, is told it has them, and writes into
memory that is not there. A window that grows on a lie faults on its next
paint.

**The kind check has a caller now.** For two milestones nothing in ring 3
asked `segbrk` of a segment that was not anonymous. This file said the rule
was Plan 9's, written down, and watched by nothing. `mapper` asks it of
the card it attached, and the answer has to be `EINVAL`. A kernel that
answers instead shrinks the framebuffer, and the second failure is the
untracked free that follows.

**And a wrong mapping for a grown run is self-consistent, which is what the
sweep is for.** This was first written up as "the new pages are below the
screen, so nothing reads them back", and a window born shorter than the glass
was supposed to fix it. That landed -- a window is three quarters of the
screen now and a grown one is measured on the glass, which is a check no
frame count could make -- and the control stayed inert. The reason was the
other one.

`map_run` installs whatever `segment_frame` answers, and the server reads and
writes the same virtual addresses. A `segment_frame` that answers the wrong
frame answers it for the write *and* the read, so every pixel comes back from
exactly where it was put. The window looks right because it is internally
right.

What the mutation actually breaks is memory it does not own: the grown pages
land past the end of the first block, on frames the allocator gave to somebody
else. That is a safety fault rather than a functional one, and no readback can
see it. It wanted an invariant sweep, which is the shape of a leak check
rather than of a pixel check. The next section is that sweep.

### The sweep

**Every frame a process maps belongs to one of its segments.** `user.sweep`
walks a process's page tables through `mem.walk_user`, which is the
teardown's walk with the leaf case inverted. It judges every leaf it finds
against the segment records. Three numbers come back, each a different way
for the rule to be broken:

    stray      a leaf at an address no segment covers. A shrink that freed
               and forgot to unmap, or a mapping made behind the segments'
               back.
    borrowed   a leaf inside a segment's extent whose frame the segment does
               not own. A `segment_frame` that answered the wrong frame, or
               a copy at fork that mapped the parent's frames as the child's.
    short      a segment page with no leaf under it. A run mapped part-way,
               or a sharer that never received a grow.

**The question is ownership, and deliberately not position.** The sharper
check asks whether page n holds the frame `segment_frame` answers for page n.
It agrees with itself whatever `segment_frame` does, because `map_run`
installed exactly what `segment_frame` said. So the sweep reads `pieces` and `frames`
and never calls `segment_frame`. What the mutation cannot fake is the record.

**It runs five times a boot**, where a process holds something worth asking
about. `anon` after its runs grew and shrank. `mapper` with two attaches of
the card. The draw server after the window grew, and its reader child, which
shares the run and never received the grow. And the orphan in
`verify_rfork`, holding two shared segments and a stack of its own.

The reader child is `short` by exactly the pages the server's run gained,
read off the second piece of the server's record. `segment_grow` says why
the tail is the grower's alone.

**And twice more as the controls that run on every boot**, one per number a
mutation cannot reach alive. `verify_shadow` maps a page no segment covers,
on purpose, and the sweep there has to find exactly one stray leaf and
nothing borrowed. `verify_anon`, once its program ended, points one page of a
run at a frame the kernel holds, behind the record's back. The sweep has
to name exactly one borrowed frame, and then the page goes back. A sweep that
found nothing everywhere would be one that cannot fail. `docs/TESTING.md` has
the pattern.

**The first sweep of the `segment_frame` control came back clean, twice,
for two reasons that were not the check.** `docs/TESTING.md` says to ask
whether the test reaches the code before asking whether the check is weak,
and both answers were that kind.

The first is the allocator. `mem.alloc_pages` hands out adjacent runs. A grow
that follows the ask with nothing between lands on the frames right after
the run's block. A `segment_frame` that reads the tail out of the first piece
then answers the right frames by luck. The draw server's grow is one of
those, and stays one. Nothing takes the frame after a window's block between
its birth and the client's `size`.

So `anon` stops after its second ask and waits for the kernel's word. The
test takes one frame -- the one the allocator would have handed the grow --
and then says go. The grown piece cannot be adjacent now, and a check says
so. The wait is bounded the way `spin`'s is. A kernel that never answers ends
the program rather than the boot.

What the wedge buys is a run of two disjoint blocks. The ownership question
and the release by name are both asked over pieces rather than over one
span. The wedge frame is what the every-boot control above points a page at.

The second was the code. `segment_grow` mapped its new piece from the base it
had just allocated, and never asked `segment_frame` at all. Its own comment
said the mapping read the frames out of the accessor. A wrong answer for a
grown run's tail reached no mapping, because the one mapping of that tail
never asked.

`map_run` maps a grow now, from the first new page to the end.
So every mapping of a run reads the record through one accessor, and the
sweep is what checks the accessor.

**With both fixed, the control stops the boot.** The draw server's window
grow runs long before `anon` does. It maps the new rows onto the frames after
the window's block, which are somebody else's. The compositor writes
rows there, and the machine wedges with nothing printed.

That is the failure
`docs/USER.md` predicted when it first recorded this control as inert. The
sweep would name it in `anon`, with the wedge, and never gets the chance. So
the number it would have raised has the every-boot control above instead.

**A fifth control stops the boot before any sweep runs.** A copy at fork that
maps the parent's frames as the child's gives the two processes one stack.
`forker` is the first program to fork, and the boot ends there with nothing
printed. The sweep in `verify_rfork` would have named it, and never gets the
chance. That is the shape `docs/TESTING.md` calls a machine failure, and
records rather than counts.

**And one type, which is here now.** Plan 9's `"shared"` class is `SG_SHARED`,
which `dupseg` shares whatever the flags say and `exec` inherits. `.Shared` is
that class. `segalloc` takes a flag word, and `abi.SEGSHARED` asks for it. A
fork shares the run whether or not it shares anything else, and an exec adds
the run to the new image as one more holder before it commits. What frees it is
what frees an anonymous run: the last holder's release.

`verify_shared_class` seeds a shared page and a private one, forks with `RFPROC` alone, has the child
write into both, and execs. The shared page holds the child's witness
afterwards, and the private seed is untouched. The segment is there under a
program that never asked for it.

**Smaller divergences, each recorded rather than argued.**

- **A program cannot ask where its memory goes.** Plan 9's `segattach` takes a
  `va`. Zero means find a hole, which it does by searching *down* from the
  stack segment with `isoverlap` as the guard. Vectra bumps *up* from
  `MAPPING_BASE` and ignores the caller. Two consequences: no segment at an
  address two programs agreed on in advance, and a bump that never comes back
  down. Plan 9's search reuses freed space because it is a search.
- **`exec` drops everything.** Plan 9 detaches only the segments carrying
  `SG_CEXEC` and inherits the rest. Vectra's `exec` releases every segment a
  process holds, which is `SG_CEXEC` behaviour for all of them.
- **No `attr` argument at all.** `SG_RONLY` and `SG_CEXEC` are what Plan 9's
  first argument carries. A read-only run has no way to ask here.
- **The copy at fork was eager, and is not.** `dupseg`'s comment says copy on
  write and means it: it copies page table entries and lets the fault
  handler do the work. `fork_segments` copied the bytes for seven
  milestones. Since `docs/PROCS.md` step 2 it shares the frames read-only,
  the physical allocator counts their holders, and `fix_fault` copies a
  page on the first write to it -- `fixfault`'s job, in `user.odin`.
- **The bound is three orders of magnitude smaller.** `SEGMAXSIZE` is about
  1.94 GB per class. `SEGALLOC_MAX` is 4 MB.

**The deepest one is upstream of this file.** Plan 9 has no `.Data` and
`.Anon` split. `SG_BSS` is the loader's bss *and* the memory `segattach`
hands out, one type for both. `Segment` carries a growable `Pte **map` with a
`mapsize`, so one shape serves a four-kilobyte segment and a two-gigabyte one.

Vectra needed two kinds only because `MAX_PROGRAM_FRAMES` is a fixed array of
sixty-four. That is what forced the run shape, and `segment_is_run` is the seam
it left. A growable frame list would retire the predicate, the second kind, and
this paragraph.

### The self-test, and its controls

`verify_anon` loads a program that asks for half a megabyte. That is twice
`MAX_PROGRAM_FRAMES`, so a run that comes back whole is a claim about the shape
and not only about the call.

It reads the first word before it writes anything. Then it stores a pattern at
both ends and asks again. It waits for the kernel's word, grows that second
run by four pages, stores the last word of the tail, and gives two pages back.
Then it asks twice more with arithmetic the kernel must refuse, and forks. The
child asks for a run of its own. It checks that the one it inherited still
reads as its parent left it, writes over that copy, and exits.

The kernel sweeps the parent's tables before the teardown, and then walks the
frames of every piece of both runs by name after it.

Ten mutations, each on a real boot. Eight are caught.

| Mutation | Result |
|---|---|
| the teardown gives a run back the way it gives a device back | 2 checks, first `and every frame of both runs went back to the allocator, by name` |
| a run alone is handed out unzeroed | 1 check, `and arrived zero, because a page the last program wrote is not this one's to read` |
| a run is one page however much was asked for | 9 checks, first `a store half a megabyte in came back, so the run is mapped end to end` |
| `map_reserve` hands out a span a live run already holds | 3 checks, first `a second attach is a second address` |
| `map_reserve` bumps above every run instead of the lowest hole | 1 check, `and the next ask of that size lands back in the hole below a live run` |
| `rfork` shares a run the way it shares a card | 1 check, `and the parent's run still holds the parent's word` |
| a run answers the frame list rather than its base | 1 check, `and the parent's run still holds the parent's word` |
| there is no bound on what one call may ask for | 1 check, `a gigabyte is refused` |
| a child's list omits the runs it inherited | 1 check, `a forked child got a run of its own that did not land on one it inherited` |
| *every* fresh run is handed out unzeroed | **the boot stops**, on a page table |
| the run mapping drops every page but the first | **the boot stops**, for a reason that is not this code's |

**The two search controls are the interesting catches.** The first hands out a
taken span and fails `segattach`'s second-attach check and `segalloc`'s
second-ask check both, from one mutation across two callers. The second bumps
above every run rather than filling the lowest hole, which is the leak the old
`map_next` was. It reaches the reuse check alone, because that check detaches a
run with a live one above it. A bump steps over the run above and answers
higher, and only a search comes back for the hole.

**Two machine failures, and only one of them is about this code.** Removing the
zeroing from `mem.alloc_pages_zeroed` kills the machine long before ring 3.
Page tables are the other caller, and a page table that is not zero reads as
512 entries that are all present. The mutation had to narrow to `segment_run`
to say anything. Narrowed, one check catches it.

The other is a gap this milestone did not create. Truncating `map_run` breaks
the framebuffer's mapping as well as a run's. So `servers/intuition` faults
inside a `Twrite` and its client parks for ever. That was the hang
`docs/DRAW.md` section 8 found with a different mutation, and it is what the
reaper below retires: a faulted server hangs up now, so a client parked on it
is answered rather than left. The narrowed form, a run of one page, reaches the
checks and fails nine.

**What a control found that the checks did not.** The frame-list mutation makes
every page of a run answer physical frame zero. The zero check and the far-end
check both still pass, because a run that is entirely one frame agrees with
itself. The pattern at the far end comes back from the frame it went to.

Only the fork catches it, and only because two processes then share what a copy
should have separated. A readback through one mapping cannot tell a correct
mapping from a constant one. That is worth knowing before the next test that
goes through a mapping.

## segdetach, and the run that goes back

**A process may detach what it attached and what it allocated, and not the
image it was born with.** `SYS_SEGDETACH` takes an address, finds the
segment covering it, unmaps the whole extent, takes the segment off the
process's list, and releases it. The last holder's release frees the frames.
A run shared under `RFMEM` is not freed by this at all. The release finds
another holder, which is Plan 9's `putseg` doing the same decrement.

### What Plan 9 refuses, and what this refuses on top

`syssegdetach` refuses one segment by name, the stack, and would let a
program detach its own text and die on its next instruction. Vectra refuses
the text and the data beside the stack as well, and the reason is the
kernel's rather than the program's. The kernel holds staging aliases to a
blob's three frames and reads the data page through the direct map for every
check in `verify.odin`. A data segment gone under those aliases is a kernel
that reads a frame the allocator handed on. So the rule is `segbrk`'s. Only
the run kinds may be asked, and `.Device` and `.Anon` are exactly the two a
program asked for by a call.

**The address comes back with the run.** `map_reserve` searches the segment
list, so the hole a detach leaves is one the next `segalloc` of that size or
less lands in. `Process.map_next` is gone: it was a bump that never came down,
and the search that replaced it reads the list rather than a high-water mark.
Memory goes back the same way, which was always the expensive half.

### segfree, deferred with its reason

The last of Plan 9's three frees the pages under a range and keeps the
segment. The pages read as zero on the next touch, which is demand paging,
and this kernel has none. Vectra zeroes at the call, and a run is a short
list of contiguous pieces with no page map. A fault in a program ends the
program, which this file argues at length above.

Two contracts were possible and neither was wanted. A hole a page fault
refills with a zeroed page is Plan 9's, and it changes the fault rule and the
run's shape both. A hole a touch faults on is cheap, and it is a promise no
caller would want to be given. Nothing calls `segfree`, on Plan 9 or here.
`segbrk` gives the tail back and `segdetach` gives the whole back, and
between them every give-back a caller today can act on is covered. So it
waits for a caller that needs the pages back and the addresses kept, and
that caller decides which contract it is.

### What it bought

`servers/intuition` bought every window's run once, at start. A run could
not go back, so it could not be tied to a session that comes and goes. That
was two megabytes apiece, held whether or not anyone was drawing. The runs
were also shared with the reader child forked after them, so no window could
ever shrink.

A run is the session's now. `Tlopen` buys it and the clunk detaches it, and a
slot between sessions holds no memory at all. Two things followed for free.

The run arrives zero from the kernel. The frame that clears a store is no
longer the only thing between one client's pixels and the next. And a run
bought after the fork is the server's alone. A `size` line that shrinks a
window gives its pages back, where every shrink was refused before.

The one thing that moved the wrong way is where a failure lands. A machine
with no run left refuses the `Tlopen` with `ENOMEM`, which is at least a
reason the client can report.

### The self-test, and its controls

`anon` asks for one page more and detaches it whole. Then it asks the call
to refuse two things: its own text, and an address no segment covers.
`mapper` detaches the second of its two attaches of the card.

Each half of a detach has a check that sees it alone. A detach that released
the segment and left the mapping is a stray leaf in the sweep. One that
unmapped and never released is a live segment after the teardown. And a card
detached the allocator's way is an untracked free.

Five mutations, each on a real boot. All five are caught, and the first
failure names a different check each time.

| Mutation | Result |
|---|---|
| a detach releases the segment and leaves the mapping | 5 checks, first `every page the server maps is inside a segment it holds` |
| a detach unmaps and takes the segment off the list, and never releases it | 4 checks, first `every segment it held was released` |
| a detach answers for any kind | 8 checks, first `a gigabyte is refused`, because `anon` detached its own text and died on the next instruction |
| the draw server keeps a run at the clunk | 1 check, `the command file opens again`, because the eighth segment is the last one a process may hold |
| a shrink believes a dead worker is a sharer | 1 check, `and the machine is richer for it, because a run nobody shares may shrink` |

The first is the sweep on a live server, which is the first time a sweep
caught a mutation nothing else saw. The fourth is `MAX_PROC_SEGS` speaking.
A server that never gives a run back holds eight segments after its fourth
session, and the fifth session is refused. The fifth was not a control but the
tree as first built, and `segbrk`'s section above records it.

## The hangup a fault could not perform

**`sys_exit` releases the descriptor group and `on_trap` cannot.** The
deliberate exit detaches the table and releases it before it publishes the exit
record, so a process that ends on purpose hangs up its pipes on the way out. A
fault runs in a trap handler with interrupts off, and `fdt_release` closes
chans, and a clunk is a message that may park. `fdtable.odin` states the rule:
thread context only, and a fault handler never touches a table.

So a process that *faulted* kept its descriptors until something called
`destroy`, and `destroy` ran only from `spawn_path`.

**The cost was a hang, not a leak.** A ring 3 server that faults mid-request
never hung up its pipe, so the client parked on it waited for a reply from a
process that no longer existed. `docs/TESTING.md` names a hang as the worst way
for a check to report, and this was the one gap in the tree that turned a
failed check into one. It stopped two boots in the session that fixed it.

### The reaper

A kernel thread parked on `exit_rendez` -- the rendezvous every ending already
wakes, the deliberate exit and the note and the fault alike. So the trigger
cost nothing and no death path grew a line. `hangup_dead` walks the table and
releases the descriptor group of anything whose thread has gone.

The deadline is a backstop rather than a schedule. Every ending wakes it, and a
wake that finds nothing goes back to sleep.

**The record stays for a parent, and only the descriptors go.** That is Plan
9's `pexit` closing the file group while the proc record waits for its
parent's `wait`. Releasing a process's files is not reaping the process, and
a collector that took both would answer a parent with nothing.

**A record nobody will wait for goes whole, and the moment it ends.** The
reaper calls `reap_orphans` after the hangup. So the kernel collects a
detached process when it ends, which is init reaping on Plan 9. It used to
wait for the next fork, because `reap_orphans` ran only where a slot was
wanted. That left every count a dead process still held standing until then,
and `segbrk` found it. Three dead workers of the draw server, forked
`RFNOWAIT` per parked read, each still counted as a sharer of every window
run.

`rfork` and `segbrk` still collect at the moment they are about to believe
a count. The reaper is a thread, and its turn can come later.

**One collector per record.** The reaper, a fork that wants a slot, and a
self-test that destroys by name can all reach one dead record. `unload` run
twice releases twice. `destroy` claims a record with a compare-and-swap
on `Process.collecting` before it unloads, and the loser walks away with
nothing released. That is the answer it would get from a record that was
already gone.

**And a slot is not an identity, so the claim names a pid.** A collector
reads a record, decides it is dead, and reaches for it. A tick between the
two lets the slot be freed and reborn. The claim then lands on a newborn
the collector never looked at, whose thread has not run. It passes the
"ended" test for the wrong reason.

`collect` takes the claim and then reads the pid again, and gives a claim
on a slot that changed tenants back untouched. The pid is the generation: monotonic, never reused, the
number `wait` already leans on. `hangup_dead` does its
exchange under the table lock now, and so does `collect`'s claim. The pid is
still the identity across the teardown that the lock cannot cover, and
`docs/SMP.md` records what the lock is for.

A self-test that wants to look at a detached process has to hold it alive to
do so. `nowaiter`'s child and `memfork`'s orphan both wait for a word from
the kernel. The checks watch the record go rather than read a status nobody
was left to collect.

**The exchange is atomic**, because three paths race for one pointer: the
reaper, `sys_exit` on another thread, and `unload` from a collector. Whoever
wins releases and the losers find nil. `unload` already claimed "one release
per holder, whichever paths ran", and this is what makes that true rather than
argued.

### The controls

| Mutation | Result |
|---|---|
| no reaper at all, which is where this started | 1 check, `and its descriptors come back with nothing asking, which is the hangup` |
| the reaper runs and releases nothing | 1 check, the same |
| the reaper takes the record as well as the descriptors | **breaks the machine** |
| the reaper leaves a detached record for the next fork, which is where this started | 5 checks, first `the kernel's write releases the orphan, and the reaper takes it back unasked` |
| two collectors may unload one record | **breaks the machine** |
| `segbrk` believes a count before the reaper's turn | **inert**, and see below |
| `collect` never reads the pid again after its claim | **inert**, the same window |
| `hangup_dead` keeps a table it took from a newborn | **inert**, the same window |

**The fifth is the claim earning its place.** Without it the boot stops with
nothing printed. The reaper and a collector at a fork or a check reach one
dead record within a tick of each other. The second `unload` releases what
the first already gave back. `docs/TESTING.md`'s cluster of narrow
windows has one member that is not narrow after all.

**The sixth is inert here, and stays.** With `segbrk`'s own collection
removed, every boot passed, because the reaper had its turn between a
worker's exit and the next request every time. That is a scheduling order
and not a rule. The collect at the count is what makes it a rule. A control
that comes back clean because the window did not open is the kind
`docs/TESTING.md` records rather than deletes.

**The seventh and eighth are the same window, from both sides.** `collect`
reads the pid again after its claim, and `hangup_dead` reads it again after
its exchange. The control that removes either read came back clean. A tick
has to land between a collector's check and its claim. In that tick another
thread has to collect the same dead process, and a fork has to move into
the slot. That never lined up.

It is the cluster `docs/TESTING.md` names: two or three instructions wide,
not at a lock boundary, and a second core's to reach. The re-read stays,
because the pid is what makes the claim mean a process rather than a slot.

The first run of the eighth did not compile, because the mutation left the
pid unread and `-vet` refused it. A control that does not build is not a
control, and this table says what the second run said.

**The third one is why a parent's record stays.** A collector that destroys
anything whose thread has gone takes the record a parent is parked in `wait`
on, and the boot stops rather than failing a check. The `p.live` check beside the hangup one
is written for that mutation and never gets to run, because the machine is gone
before it is reached. It is the same shape as `docs/DRAW.md` section 11's one
breaking mutation: a control that removes a property everything else stands on
does not report, it stops.

## Stopped from outside

**A note is a request a handler may decline, and `destroy` refuses a process
whose thread still runs.** So a process that caught every note and never
exited was the kernel's to keep for ever. `docs/HANDOFF.md` carried it as
the honest leak for four milestones. `end` is the kill the kernel did not
have, and `stop` is `end` and the collection.

**Plan 9's `killproc` is the shape, to the line.** It does two things. It
sets `procctl` to `Proc_exitme`, and it pushes a "sys: killed" note beside
it. The note is what wakes a parked process and what the exit record
carries. The word is what makes the ending unconditional. `procctl()` runs
before `notify` looks at any note or any handler, and answers
`pexit("Killed")`.

Here `Process.stopping` is the word and `sched.note_thread` is the wake. The
door and the tick both read the word before the handler. So a process ends
at its next boundary whether or not it registered one, and whether or not a
delivery is in flight.

The wait is bounded, the way every wait in this tree is. A process that
reaches no boundary inside the patience is still running when `end` returns
false, and is still the caller's to leave alone. A tick is a boundary, so
nothing runs that long.

### The self-test, and its controls

`verify_stop` loads `catcher`, the program `verify_handler` just showed
catching a note and surviving, and ends it while it spins with its handler
registered. The check that matters is the handler's own count, which stays
at zero: the process ended without its handler ever running. The record is
read before it is collected, which is why `end` and `stop` are two calls.

Three mutations, each on a real boot.

| Mutation | Result |
|---|---|
| the door looks at the handler before the word | 2 checks, first `noted, with the same word` |
| the tick looks at the handler before the word | 3 checks, first `the kernel ends it, and it is gone inside the patience` |
| `end` sets the word and wakes nothing | 11 checks, first the same, and 13 objects leaked |

**The first came back clean the first time.** The only target spun in ring
3, and the tick ended it before the door was ever asked. That is
`docs/TESTING.md`'s first question, whether the test reaches the code, and
the answer was no. A second target is past its first note and loops on
`sleep` now, so the door is the boundary it dies at. With the handler first,
that target caught the word as a note and answered NCONT. It exited on its
own terms two notes later, which is the deliberate ending the check refuses.

**The second is the tick's half of the same rule**, and it fails on the
patience. The handler catches the word and the program moves to its `sleep`
loop. The door then finds a thread whose note flag the delivery already
consumed. The word stays set and nothing reads it, so the process sleeps out
its two thousand rounds. That is why the door and the tick each read the
word themselves, rather than trusting the note flag to carry it.

**The third is the leak coming back.** A process nobody wakes never reaches
a boundary, so `end` runs out its patience and `destroy` refuses. The record
and everything it holds stay until the machine stops.

## What is missing, and named where it lives

- **`destroy` still refuses a running process**, and rightly: its thread is
  translating through the space. `stop` is the answer, and it is the arc
  `wait_pid` walks for parents, walked by the kernel for itself. See the
  section above.
- **No `stat` behind the door.** `vfs.chan_stat` exists and nothing in ring 3
  needs it yet. It is the same shape as every call above and not a design
  question. `create` and `mount` were on this line for four milestones, and
  posting is what pulled them through.
- **Nothing counts a process's calls against it.** `MAX_PROCESSES` bounds how
  many exist and `MAX_FDS` bounds what one holds. Nothing bounds what one asks
  for, and a single process can call `sleep` for ever. `segalloc` is bounded
  per call and per process and by nothing across processes, which is the same
  gap one table down.
- **`copy_in` and `copy_out` move one `IO_CHUNK` per pass**, on the calling
  thread's kernel stack, and `read` and `write` loop until the whole count is
  moved. A program that hands over a bad pointer part-way loses only the tail.
  It gets the count of what landed, which every write interface already makes a
  caller handle. A page the process pins would still beat the copy for the
  largest buffers if it ever matters.
- **`MAX_PROCESSES` is two hundred and fifty-six, from a fixed table**, and `docs/PROCS.md` says what would make it a pool. The same argument
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
