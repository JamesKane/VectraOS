# Address spaces: the first half of userland

`kernel/mem/space.odin`, and the comparison `kernel/sched/sched.odin` grew to go
with it.

An address space is one page table tree per process, and half of it is shared.
That sentence is the whole design, and `populate_higher_half` wrote it two
milestones before there was anything to build on it.

    index 0..255      this space's own. Empty at birth. Where a program lives.
    index 256..511    the kernel's, copied. The same tables, in every space.

## This is userland's first slice, not userland

A program needs four things Vectra did not have. A private address space, a way
to enter ring 3, a way to call back into the kernel, and something to run. This
milestone is the first. `docs/HANDOFF.md` says what the other three need and in
what order.

The split is not arbitrary. **The address space is the piece everything else
stands on and the piece that can be checked without any of it.** Ring 3 needs a
space to enter from. A syscall needs a stack the kernel can trust, which needs
per-CPU state behind `GS`, which needs a space to switch into first. Doing
those first would mean debugging them on foundations nothing exercised.

What this milestone can prove, and does, is that two threads can hold the same
address and mean different memory. That is the property a program is built on.

## Two halves, two reasons

**A new space copies the upper half entry by entry, rather than tree by tree.** Each of the 256 entries names
a table the kernel already allocated, so every space points at the same
second-level tables. A kernel mapping made afterwards appears in every space with
nothing replayed.

That is why `vmm_init` populates all 256 up front even though the kernel uses a
handful of them. An entry that did not exist at copy time would never appear.
The copy is a snapshot of the top level, and a sharing of everything below it.

**The lower half is what a process gets, and the isolation is one bit in one
place.** The hardware ANDs the user bit down the path, and `populate_higher_half`
sets no `User` on any of those 256 branches. The whole kernel half is therefore
sealed from a program at the top level, once. Not by remembering to leave a bit
clear on every mapping anybody makes.

## What a space owns

Its lower-half **page tables**. Not the frames those tables point at.

That is a real limitation with a real reason. A frame mapped into two spaces
has two owners and no count. Inventing a reference count for one caller would
be inventing it in the wrong place. When there is a process to own its pages,
the owner is the process, and `space_destroy` grows a walk that frees leaves
too. Or frames grow a count, which is the question `Chan.refs` and
`Mount_Point.refs` already answer for their own objects.

Until then the caller frees what it mapped, and a control that makes the space
free leaves instead shows exactly what goes wrong.

**The walk can be read as well as torn down.** `walk_user` visits every
present leaf in the lower half and hands each to a caller, and it is
`free_subtree`'s walk with the leaf case inverted. It frees nothing, so it can
run against a live process.

It exists for `kernel/user`'s `sweep`, which asks
whether every frame a process maps is one of its segments' own. A count of
frames balances whatever the mapping says. Only the mapping says where a wrong
frame went, and this is how a self-test reads it. See `docs/USER.md`.

**The teardown walk stops at the halfway index, and that is the whole
correctness argument.** Entries 256 and above name tables the kernel is still
using and every other space still points at. Freeing one takes the kernel down
with the process, at whatever later moment something touches the address it used
to describe.

## One counter for page tables, not one per space

`map_at` grows `table_frames` wherever the mapping lands. `space_destroy` shrinks
it by what it hands back. There is one number for frames spent on page tables
across every space there is.

**That was a bug first.** The space layer started with a counter of its own,
and the self-test's balance check failed on the first boot. `map_at` counted
its tables in one place, and the teardown gave them back in another. Two counters that must
agree are two counters that can disagree, and the check that brackets them would
have been bracketing half of each.

## What the scheduler grew

One comparison, which is what `docs/HANDOFF.md` promised for four milestones.

```odin
if next.space != prev_space(prev) {
    ...
}
```

**Compared rather than written**, because a write to CR3 flushes every
non-global translation whether or not the value changed. A kernel thread
carries nil, so a switch between two of them compares two nils and costs
nothing. That is the common case by a wide margin, and the one that must stay
free.

The reload is safe because the kernel half is identical in every space and
mapped `Global`. The code executing that line, the stack under it and the thread
record it is reading all survive. `map_kernel_image` marked them global four
milestones ago for exactly this instant.

**The space is set before a thread is enqueued.** The next interrupt can
dispatch a thread sitting on a run queue. One dispatched with the wrong space
runs its first instruction through somebody else's tables.

## The self-test

Two threads, one per space, both writing to the same virtual address.

**The wait between them is what makes it a test of isolation rather than of
ordering.** Without it, one thread could write, read and finish before the other
started — and two spaces that were secretly the same would still answer
correctly. Both marks are in memory at once, and each thread reads after the
other wrote.

It runs on threads rather than on the boot thread, and not for the usual reason.
Nothing here blocks. It is that **an address space is only real across a
switch**. A test that mapped two spaces and read them both by hand would be
reading page tables, not translations.

The frame-balance check runs in a phase of its own, before the threads exist. A
thread's stack comes from the heap, which takes frames from the physical
allocator and never gives them back. Measuring across a spawn measures the
heap. The question *did a space hand back every frame it took* is asked where
nothing else is allocating, and the answer is exact.

### The controls

Six mutations, one at a time, each observed on a real boot.

| Mutation | Result |
|---|---|
| a user mapping carries no user bit | `a user mapping carries the bit that lets a program reach it` |
| a user mapping may name the kernel half | `and the kernel half is not an address a program may be given` |
| teardown frees the leaves as well as the tables | `and nothing twice, which is what a space owning its leaves would do` |
| the scheduler never reloads CR3 | **#PF at `0x10000000`**, named on the panic screen |
| teardown walks the whole table, shared half included | **a fault inside the panic handler**, and a halt |
| a new space copies the kernel's lower half too | **not caught**, and the mutation is inert |

**Two of those are faults rather than failed checks.** That is a property of
what is being tested, rather than a gap in the test. An address space that is
wrong is not a wrong answer, it is an address that is not there. The scheduler
control faults on the exact address the two spaces disagree about, and the panic
screen names it. The teardown control frees the kernel's own tables and takes
the panic screen down with everything else. That is unmissable, and the loudest
thing here.

**The inert one is worth stating plainly.** Copying the kernel's lower half
copies 256 empty entries, because the kernel maps nothing below the canonical
hole. So the mutation changes nothing that can be observed, and the check that
a new space starts empty passes either way. It becomes a real mutation the day
the kernel maps anything low, and nothing plans to.

### Two checks passed for the wrong reason first

**The kernel-half guard was tested at an address that was already mapped.** The
first version used the kernel image's own address, so `map_at` refused it as a
conflict and the check passed with the guard deleted. It uses an *empty*
higher-half address now, where the guard is the only thing that can say no. The
failure it prevents is worse than a mapping in the wrong place: that top-level
entry is one of the 256 every space shares.

**The teardown ran against an allocator that absorbs a double free.** A space
that freed its leaves frees frames the caller then frees again. `release` finds
the bit already clear, changes no count, and says nothing. The
arithmetic agreed and the bug did not show.

Double frees are counted now. That is a two-line change to the physical
allocator, and the right one on its own terms. A double free is always a bug in
the caller, and an allocator that absorbs it silently is one that hides it.

## What this leaves for next time

- **Ring 3.** Built. See `docs/USER.md`. Entering is an `iretq` with a user
  `CS` and `SS`. Two things had to go with it: a kernel stack in the TSS, and a
  fault path that ends a program rather than the machine.
- **SYSCALL and SYSRET.** `EFER.SCE`, then `STAR`, `LSTAR` and `SFMASK`. The
  entry stub is naked assembly, and the first thing it needs is a stack.
- **Per-CPU state behind `GS`.** Which is where that stack comes from, and why
  `swapgs` belongs to the same milestone as the syscall path rather than to this
  one.
- **A process.** A space, a namespace and a set of open files. This milestone
  built the first of the three, and `Thread.space` is deliberately not called a
  process for that reason.
- **Frames a space owns**, and the reference count that lets two spaces share
  one.

## See also

- `docs/MEMORY.md` — the PMM, the VMM, and the kernel space this copies from.
- `docs/SCHED.md` — the switch this added a comparison to.
- `docs/USER.md` — ring 3, the slice that came next, and what it needed from
  this one.
- `docs/HANDOFF.md` — section 6, and what the other slices of userland need.
