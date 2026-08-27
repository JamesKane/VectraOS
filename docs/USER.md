# Ring 3: running code the kernel does not trust

`kernel/user/`, and what the GDT, the IDT and the scheduler grew to go with it.

Everything before this milestone ran at the privilege the loader handed over.
The scheduler switched stacks, the address spaces switched page tables, and all
of it was one program with many threads. This is where that stops being true.

A program is three mapped pages and a thread whose saved frame names a ring 3
code selector. There is no loader, no system call and no process yet, and the
order is deliberate:

    ring 3        a thread can run somewhere it cannot damage the kernel
    a syscall     it can ask for something anyway
    a process     what it asks for belongs to it rather than to the kernel

`docs/SPACE.md` built the piece under all three. This is the second of four.

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

Every blob is position-independent, because a copy lands wherever the space
maps it. Every one writes a mark to its data page first, which is how the
kernel knows the program reached its first instruction at all.

`poke` runs twice, against two different addresses. Which address a blob
receives is what makes one run a test of the kernel half and another a test of
a read-only page.

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

### The controls

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

## What is missing, and named where it lives

- **A program cannot be stopped.** It ends by faulting and there is no other
  way. It cannot ask, because there is no system call. The kernel cannot tell
  it, because nothing but the clock interrupts a program. `destroy` therefore
  refuses a running program rather than free the tables underneath it, and the
  leak is visible in `user.stats().live`. Plan 9 ends a process with a note.
  That is this missing piece by its proper name.
- **A program cannot ask for anything.** SYSCALL and SYSRET are the next
  milestone, and `EFER.SCE`, `STAR`, `LSTAR` and `SFMASK` are what they need.
  The entry stub is naked assembly and the first thing it wants is a stack.
  That is why `swapgs` and per-CPU state behind `GS` belong to that milestone
  rather than this one.
- **A program is not a process.** A process is a space, a namespace and a set
  of open files. Two of the three exist, and nothing yet ties them together.
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
- `docs/SCHED.md` — the switch, and the two stores a user thread costs it.
- `docs/BOOT.md` — the GDT, the TSS and the trap path this extends.
- `docs/TESTING.md` — the self-test discipline, and the cluster the one
  uncaught control joins.
