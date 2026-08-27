# Ring 3, and the door back in

`kernel/user/`, and what the GDT, the IDT, the scheduler and `GS` grew to go
with it.

Everything before this ran at the privilege the loader handed over. The
scheduler switched stacks, the address spaces switched page tables, and all of
it was one program with many threads. This is where that stops being true.

A program is three mapped pages and a thread whose saved frame names a ring 3
code selector. It can ask the kernel for five things, and one of them puts its
own line in the boot log:

    -- a program in ring 3 wrote this line

`docs/SPACE.md` built the piece under all of it. Two milestones live in this
document, because they live in the same directory:

    ring 3        a thread can run somewhere it cannot damage the kernel
    a syscall     it can ask for something anyway
    a process     what it asks for belongs to it rather than to the kernel

The third is next, and the section at the end says what it needs.

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

| Call | What it does | Permanent |
|---|---|---|
| `exit` | ends the program with a status | yes |
| `sleep` | parks the thread for a number of ticks | yes |
| `write` | writes to `/dev/cons` through the real namespace | the path, not the descriptor |
| `nop` | returns zero | no |
| `args` | adds its six arguments | no |

**Descriptor 1 is `/dev/cons`, opened once at boot, with no table behind it.** A
file descriptor belongs to a process and a process is the next milestone. What
is real is everything after the copy: a genuine 9P write, over the real
transport, to the real console.

**`exit` is what ring 3 lacked.** Before it, a program ended by doing something
the CPU refused, and `user.destroy` had to refuse a program that was still
running. Now a program can say so.

### The record is written with interrupts off, and that is not tidiness

`SYS_EXIT` fills the program's exit record and then leaves the core. The
observer polls that record and takes the program's space and frames down when
it sees it. Between the store and the moment the thread stops, the thread is
still translating through that space.

A fault gets this property free, because a fault handler already runs masked.
This path had to ask for it. `docs/TESTING.md` has the control that found the
shape of the problem one milestone before it could happen.

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

## What is missing, and named where it lives

- **A program cannot be stopped from outside.** It can end itself now, and the
  kernel still cannot end it. `destroy` refuses a running program rather than
  free the tables underneath it, and the leak is visible in
  `user.stats().live`. Plan 9 ends a process with a note. That is this missing
  piece by its proper name.
- **A program is not a process.** A process is a space, a namespace and a set
  of open files. The space is real, the namespace exists and belongs to the
  kernel, and there are no open files at all. Descriptor 1 is a constant.
- **The calls are not the interface.** `nop` and `args` go the day something
  real needs their numbers. What belongs behind this door is the four or five
  9P operations a namespace needs. Those are what make a program able to open a
  file, rather than able to print.
- **Nothing counts a program's calls against it.** `MAX_PROGRAMS` bounds how
  many programs exist and nothing bounds what one of them asks for. A single
  program can call `sleep` for ever.
- **`MAX_PROGRAMS` is eight, from a fixed table.** The same argument
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
