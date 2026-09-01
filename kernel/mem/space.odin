/*
Address spaces: one page table tree per process, and one half of it shared.

`vmm.odin` builds the kernel's. This builds everybody else's, and the whole
design is in one sentence that `populate_higher_half` wrote two milestones ago.
**A user address space is a fresh lower half and a copy of the kernel's upper
one.**

    index 0..255      this space's own. Empty at birth. Where a program lives.
    index 256..511    the kernel's, copied. The same tables, in every space.

Both halves matter and for different reasons.

The upper half is copied *by entry*, not by tree. Each of those 256 entries
names a table the kernel already allocated, so every space points at the same
second-level tables. A kernel mapping made afterwards appears in all of them,
with nothing replayed. That is why `vmm_init` populates all 256 up front even
though the kernel uses a handful. An entry that did not exist at copy time would
never appear.

The lower half is what a process gets to itself, and the isolation is one bit in
one place. The hardware ANDs the user bit down the path, and
`populate_higher_half` sets no `User` on any of those 256 branches. So the
whole kernel half is sealed from a program at the top level, once. Not by
remembering to leave a bit clear on every mapping anybody makes.

## What a space owns, and what it does not

It owns its lower-half **page tables** and frees them. It does not own the
frames those tables point at.

That division asked a question for three milestones: a frame mapped into
two spaces has two owners and no count. `rfork` is what answered it.
The owner is the *segment*, `kernel/user/segment.odin`: the frames behind
one mapping, under one reference count, mapped into as many spaces as share
it. This walk stays table-only exactly so that a space can die while the
frames it mapped live on in a sibling.

The caller still frees what it mapped -- through its segments now -- and
`space_stats` reports enough for a self-test to notice when it did not.
*/
package mem

import "kernel:arch"

/*
The range a program may name.

The lower half, less the first page. Nothing may map address zero, so a null
dereference in a program faults rather than reading whatever the program put
there. That is the cheapest bug-finder in an operating system and it costs one
page of address space.

The top is where the canonical hole starts. An address above it is not a
higher-half address. It is not an address at all, and `map_at` already refuses
it. Refusing here names the caller rather than the encoding.
*/
USER_MIN :: uintptr(arch.PAGE_SIZE)
USER_MAX :: uintptr(1) << 47

// How many spaces exist. The frames they cost are counted where every other
// page table is counted. See `table_frames` in `vmm.odin`, and why there is one
// of it rather than one per space.
@(private = "file")
live_spaces: int

Space_Stats :: struct {
	live:   int, // Address spaces created and not destroyed
	frames: int, // Frames spent on page tables, everywhere
}

space_stats :: proc "contextless" () -> Space_Stats {
	return Space_Stats{live = live_spaces, frames = table_frames}
}

/*
space_new builds an empty address space that shares the kernel's upper half.

The copy is 256 entries and no allocation beyond the top-level table itself.
Every kernel mapping that exists is immediately visible in the new space, and so
is every one made afterwards.

The lower half is left zeroed, which is what makes it empty. A program that
names an address before anything maps it takes a page fault, which is the answer
it should get.
*/
space_new :: proc "contextless" () -> (^Address_Space, Error) {
	frame, ok := alloc_page_zeroed()
	if !ok {
		return nil, .Out_Of_Memory
	}

	space := new_space_record()
	if space == nil {
		free_page(frame)
		return nil, .Out_Of_Memory
	}
	space.root = frame

	kernel := cast(^arch.Page_Table)phys_to_virt(kernel_root())
	table := cast(^arch.Page_Table)phys_to_virt(frame)
	for i in arch.TABLE_ENTRIES / 2 ..< arch.TABLE_ENTRIES {
		table[i] = kernel[i]
	}

	live_spaces += 1
	table_frames += 1
	return space, .None
}

/*
space_destroy frees a space's own tables and switches away from it first if it
has to.

**The walk stops at the halfway index, and that is the whole of the correctness
argument.** Entries 256 and above name tables the kernel is still using and every
other address space still points at. Freeing one would take the kernel down with
the process, at whatever later moment something touched the address it used to
describe.

Leaves are not freed. See the file comment for what owns them and what would
have to change.

Switching away first, because the tree being freed is the tree the machine is
translating through. A CR3 pointing at a freed frame survives exactly as long as
the TLB keeps its entries.
*/
space_destroy :: proc "contextless" (space: ^Address_Space) {
	if space == nil || space.root == 0 {
		return
	}
	if arch.read_cr3() == u64(space.root) {
		space_switch(kernel_address_space())
	}

	table := cast(^arch.Page_Table)phys_to_virt(space.root)
	for i in 0 ..< arch.TABLE_ENTRIES / 2 {
		free_subtree(table[i], arch.TABLE_LEVELS)
	}

	free_page(space.root)
	table_frames -= 1
	live_spaces -= 1
	space.root = 0
	free_space_record(space)
}

/*
free_subtree releases one entry's tree, and stops at anything that is not a
branch.

A leaf at any level is a mapping rather than a table. The frame under it belongs
to whoever mapped it, so this steps over it and frees nothing.
*/
@(private = "file")
free_subtree :: proc "contextless" (entry: arch.Page_Table_Entry, level: int) {
	if !arch.entry_present(entry) || arch.entry_is_leaf(entry, level) {
		return
	}
	frame := arch.entry_address(entry)

	if level > 1 {
		table := cast(^arch.Page_Table)phys_to_virt(frame)
		for i in 0 ..< arch.TABLE_ENTRIES {
			free_subtree(table[i], level - 1)
		}
	}

	free_page(frame)
	table_frames -= 1
}

/*
space_switch makes a space the one the machine translates through.

A write to CR3 and nothing else. It flushes every non-global translation, which
is why `map_kernel_image` marks the kernel `Global`. Those mappings are the
same in every space, and survive the reload rather than being walked again
after it.

Writing the same value is not free -- it still flushes -- so callers that switch
per context check first. `sched.reschedule` does.
*/
space_switch :: proc "contextless" (space: ^Address_Space) {
	if space != nil && space.root != 0 {
		arch.write_cr3(u64(space.root))
	}
}

// space_root is the physical address the machine translates through when this
// space is current. For a scheduler comparing two spaces without dereferencing
// either.
space_root :: proc "contextless" (space: ^Address_Space) -> uintptr {
	return space == nil ? 0 : space.root
}

/*
user_span_ok is where a run of pages has to be for a process to name it.

One statement of the rule, because `map_user` and `unmap_user` both need it and
a caller that could name the kernel's half could map or unmap the kernel out
from under itself. Two copies of that test are two chances for one to drift.
*/
@(private)
user_span_ok :: proc "contextless" (virt: uintptr, pages: int) -> bool {
	if pages <= 0 {
		return false
	}
	span := uintptr(pages) * uintptr(arch.PAGE_SIZE)
	return virt >= USER_MIN && virt < USER_MAX && virt + span <= USER_MAX
}

/*
map_user installs a mapping a program may reach.

`.User` is added rather than expected. A caller that forgot it would produce a
mapping that faults on first touch, from the only code allowed to use it. The rest of the flags are the caller's: a program's text wants no `.Write`
and its stack wants `.No_Execute`, and neither decision belongs here.

Refuses anything outside the lower half, with a name. `map_at` refuses a
non-canonical address on its own, and would happily map a *kernel* address into
a user space. That is the mistake worth catching: the result is a program that
can read the kernel, and a check that passes.
*/
map_user :: proc "contextless" (
	space: ^Address_Space,
	virt, phys: uintptr,
	flags: arch.Page_Flags,
	pages: int,
) -> Error {
	if space == nil || pages <= 0 {
		return .Not_Canonical
	}

	if !user_span_ok(virt, pages) {
		return .Not_Canonical
	}

	user := flags + {.User}
	for i in 0 ..< pages {
		step := uintptr(i) * uintptr(arch.PAGE_SIZE)
		if err := map_at(space, virt + step, phys + step, user, 1); err != .None {
			return err
		}
	}
	return .None
}

/*
unmap_user takes a run of pages out of a process's half, and is `map_user`'s
inverse over the same bounds.

`unmap_page` is the walk, and it was already here -- written when the page
tables were, and left without a caller until `segbrk` wanted one. A page that
was never mapped answers false, and this does not care: unmapping what is
already unmapped is the state the caller asked for.

**It does not free anything.** What the pages were is the caller's to know --
`kernel/user`'s segments own their frames and give them back through the
allocator. This makes them unreachable, which is the half that has to happen
first.
*/
unmap_user :: proc "contextless" (space: ^Address_Space, virt: uintptr, pages: int) -> Error {
	if space == nil || !user_span_ok(virt, pages) {
		return .Not_Canonical
	}
	for i in 0 ..< pages {
		unmap_page(space, virt + uintptr(i) * uintptr(arch.PAGE_SIZE))
	}
	return .None
}

// -- Where the records live --------------------------------------------------
//
// An `Address_Space` is sixteen bytes and there will be one per process. The
// heap is the obvious home and the heap is exactly where a page-table allocator
// should not depend on being. So they come from a fixed table, sized for the
// processes this kernel can currently have, which is none.
//
// A free list rather than a count, so a space destroyed in the middle is
// reused. `MAX_SPACES` is the ceiling and it is meant to be one. A table that
// grows on demand is a table a program can exhaust the machine through, which
// is the argument `vfs.fidtab_init` and `srv.MAX_SERVICES` already make.

MAX_SPACES :: 64

@(private = "file")
Space_Slot :: struct {
	space: Address_Space,
	used:  bool,
}

@(private = "file")
spaces: [MAX_SPACES]Space_Slot

@(private = "file")
new_space_record :: proc "contextless" () -> ^Address_Space #no_bounds_check {
	for i in 0 ..< MAX_SPACES {
		if !spaces[i].used {
			spaces[i].used = true
			spaces[i].space = Address_Space{}
			return &spaces[i].space
		}
	}
	return nil
}

@(private = "file")
free_space_record :: proc "contextless" (space: ^Address_Space) #no_bounds_check {
	for i in 0 ..< MAX_SPACES {
		if &spaces[i].space == space {
			spaces[i].used = false
			return
		}
	}
}
