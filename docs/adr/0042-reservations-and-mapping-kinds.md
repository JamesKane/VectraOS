# ADR-0042: Reservations, no-access and shared mappings, resizable VMOs

Status: accepted, 2026-10-07 (proposed 2026-10-07). M6 step 6e1a1 (decided the same day: 6e1a split in two, the kernel then musl; random bases for reservations only; sharing across fork as a map flag). It gives `as_reserve` (01 §5), reserved since M1, its arguments, and adds `VX_AS_FIXED`, `VX_AS_RELEASE`, `VX_MAP_NOACCESS`, `VX_MAP_SHARED` and `VX_VMO_RESIZABLE` to the ABI (`abi/vx/abi.h`).

## Context

The loader (6f1a) maps shared objects with RELRO and guard pages, an allocator reserves before it commits, and an emulator or translation layer needs address space at addresses it names (01 §5). The POSIX personality needs `PROT_NONE` that faults, `MAP_SHARED` anonymous memory that a forked child shares, and `mremap` that can move or grow in place. The kernel had none of these: a mapping was always readable, every anonymous mapping was copied into a forked child, an anonymous VMO could not be resized (its pages are read without its lock), and `as_reserve` returned UNSUPPORTED. Placement was a bump pointer from a fixed base.

Fuchsia's VMARs give a sub-region of address space a capability of its own (`zx_vmar_allocate`, `ZX_VM_SPECIFIC`); Windows' placeholders (`VirtualAlloc2` with `MEM_RESERVE_PLACEHOLDER`) keep a range reserved until it is replaced by a view. Fuchsia's VMOs are resizable only when made with `ZX_VMO_RESIZABLE`, so that the common VMO's pages stay where every reader expects them.

## Decision

1. **`as_reserve(task, size, align, flags, &address)`**, with `VX_RIGHT_MANAGE` on the task: a reservation, address space that the kernel's own placement (`as_map` with address 0) never lands in, kept for the task's `as_map` at addresses inside it. `align` is 0 (a page) or a power of two up to 2^39. Without flags the base is random and aligned, drawn from the kernel's generator (vx-rand, seeded from the bootloader's entropy). With `VX_AS_FIXED` it is `*address`, or the call fails with `EXISTS` and `*address` set to the start of the first mapping or reservation in the way. `VX_AS_RELEASE` gives back the reservation starting at `*address` of exactly `size` bytes, unmapping what is in it. `as_unmap` inside a reservation leaves it reserved. A mapping at an address lies wholly inside one reservation or outside every one (`RANGE`). At most 32 a task. A forked task has its parent's; `task_exec` takes them with the address space.
2. **`VX_MAP_NOACCESS`** on `as_map` or `as_protect`: a mapping with no page entries, so any touch faults (`PROT_NONE`, a guard page, a reservation's placeholder). It goes with no other right. The mapping keeps its VMO and its place, and `as_protect` gives it access again.
3. **`VX_MAP_SHARED`** on `as_map` only: a forked task maps the same VMO at that place, not a copy, as it already does for a pager's VMO. Per mapping, so one VMO may be shared in one place and private in another, as Linux's `MAP_SHARED` and `MAP_PRIVATE`.
4. **`VX_VMO_RESIZABLE`** on `vmo_create`: `vmo_op` `VX_VMO_RESIZE` may change its size; pages added are zero, pages past a shrink leave every mapping and are freed, and a touch there faults. Its page list is read under its lock, as a pager's is (`vmo_rw` through a bounce, a fork's copy, a debugger's access). A VMO made without it is not resized (`UNSUPPORTED`), and its readers stay as fast as before.

## Consequences

- The loader can reserve a shared object's whole span, map its segments inside, and leave guard pages no-access; a JIT can reserve an arena and fill it; `mprotect(PROT_NONE)` faults.
- Reservations' bases are random; `as_map`'s own placement stays a bump pointer from a fixed base (a known gap until it is randomized too), so crash addresses in today's tests do not move.
- The generator is the kernel's alone, mixed once from the bootloader's entropy and the clock; without the bootloader's entropy the bases are predictable.
- A resizable VMO pays a lock on each `vmo_rw` page and on a fork's copy; one that is never resized should not be made resizable.
