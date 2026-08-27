/*
Address spaces, and the one property they exist for.

**Two spaces, the same virtual address, different memory behind it.** Everything
else in this file is a supporting fact. If two threads can hold the same address
and not see each other's writes, the machine can hold two programs.

The check has to run on threads rather than on the boot thread, and not for the
usual reason. Nothing here blocks. It is that an address space is only real
across a *switch*. A test that mapped two spaces and read them both by hand
would be reading page tables, not translations. So two threads run, each
spawned into its own space, and the scheduler is what makes the difference
between them.

## What the kernel half is doing while that happens

Still working, in both spaces, which is the other half of the design. The
thread's stack is in the heap, its code is the kernel image, and the `Verify`
record it writes its answer into is a global. All three live in the higher half,
all three are mapped `Global`, and all three survive a CR3 reload that discards
every other translation.

That is what `populate_higher_half` and `map_kernel_image` were built for, four
milestones before there was anything to switch to. A failure of it does not look
like a failed check. It looks like the machine stopping on the instruction after
the switch. The checks are ordered so something is already on the log by then.
*/
package kernel

import "base:intrinsics"

import "kernel:arch"
import "kernel:mem"
import "kernel:sched"
import "kernel:sync"
import "vsys:libodin"

/*
Where both spaces map a page, and what each writes there.

The address is arbitrary and low. What matters is that it is the *same* number
in both spaces. A kernel address would be refused, which is its own check
further down.
*/
@(private = "file")
USER_VA :: uintptr(0x1000_0000)

@(private = "file")
MARKS := [2]u64{0xA1A1_A1A1_A1A1_A1A1, 0xB2B2_B2B2_B2B2_B2B2}

@(private = "file")
PATIENCE :: 400

@(private = "file")
Space_Result :: struct {
	checks:        int,
	failures:      int,
	first_failure: string,
	switches:      u64, // Context switches that reloaded CR3
	frames:        int, // Frames the two spaces spent on page tables
}

@(private = "file")
scheck :: proc "contextless" (r: ^Space_Result, ok: bool, what: string) -> bool {
	r.checks += 1
	if !ok {
		r.failures += 1
		if r.first_failure == "" {
			r.first_failure = what
		}
	}
	return ok
}

/*
One thread's half of the isolation check, and everything it reported.

`saw` is what it read back from `USER_VA` after writing its own mark there.
`kernel_ok` is whether the higher half still answered while it was doing that.
*/
@(private = "file")
Occupant :: struct {
	slot:      int,
	wrote:     u64,
	saw:       u64,
	kernel_ok: bool,
	done:      bool,
}

@(private = "file")
occupants: [2]Occupant

// A global in the kernel half, which is the thing a thread in a user space
// should still be able to reach. Read and written from inside both spaces.
@(private = "file")
shared_witness: u64

@(private = "file")
both_done :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&occupants[0].done) &&
	       intrinsics.volatile_load(&occupants[1].done)
}

/*
occupy writes this space's mark, waits for the other thread to write its own,
and then reads back.

**The wait is what makes this a test of isolation rather than of ordering.**
Without it, one thread could write, read and finish before the other started,
and two spaces that were secretly the same would still answer correctly. Both
marks are in memory at the same time, and each thread reads after the other
wrote.
*/
@(private = "file")
occupy :: proc "contextless" (arg: rawptr) {
	o := cast(^Occupant)arg
	cell := cast(^u64)USER_VA

	cell^ = o.wrote

	// The kernel half, from inside a user space. A global, not a constant. The
	// compiler answers a read of `.rodata` on its own.
	intrinsics.volatile_store(&shared_witness, intrinsics.volatile_load(&shared_witness) + 1)
	o.kernel_ok = intrinsics.volatile_load(&shared_witness) > 0

	// Let the other space write its own mark before reading back. A yield
	// rather than a delay: this must work whether or not the timer is the
	// thing that switches.
	for _ in 0 ..< 64 {
		sched.yield()
	}

	o.saw = cell^
	intrinsics.volatile_store(&o.done, true)
}

@(private = "file")
watch_space :: proc "contextless" (cond: sync.Condition, arg: rawptr) -> bool {
	for _ in 0 ..< PATIENCE {
		if cond(arg) {
			return true
		}
		sync.delay(1)
	}
	return false
}

/*
verify_space builds two address spaces, runs a thread in each, and takes them
down again.

Heap and frame counts bracket it. A space that leaked a page table is not a
failed check anywhere else -- it is a number that does not come back.
*/
verify_space :: proc() {
	r: Space_Result

	before := mem.space_stats()

	// -- A space on its own, built and taken down ----------------------------

	/*
	Bracketed by the physical allocator, and alone on purpose.

	This is the only place the frame count means what it says. The isolation phase
	below spawns two threads. A thread's stack comes from the heap, which takes
	frames from here and never gives them back. Measuring across
	that would be measuring the heap.

	So the question `did a space hand back every frame it took` is asked here,
	where nothing else is allocating, and the answer is exact.
	*/
	verify_lifetime(&r)

	// -- Two spaces ----------------------------------------------------------

	space_a, err_a := mem.space_new()
	if !scheck(&r, err_a == .None && space_a != nil, "an address space is built") {
		report_space(&r)
		return
	}
	space_b, err_b := mem.space_new()
	if !scheck(&r, err_b == .None && space_b != nil, "and a second one") {
		mem.space_destroy(space_a)
		report_space(&r)
		return
	}

	scheck(&r, mem.space_root(space_a) != mem.space_root(space_b), "with page tables of their own")

	// A fresh space is empty below the kernel half. A program that names an
	// address before anything maps it should fault, and this is that in the
	// only form a self-test can see.
	_, mapped := mem.translate(space_a, USER_VA)
	scheck(&r, !mapped, "and nothing mapped in the half a program gets")

	// The kernel half is not empty, and is the same in both. That is the copy
	// `space_new` makes, checked at an address the kernel actually uses.
	witness := uintptr(uintptr(rawptr(&shared_witness)))
	pa, ok_a := mem.translate(space_a, witness)
	pb, ok_b := mem.translate(space_b, witness)
	scheck(&r, ok_a && ok_b && pa == pb, "the kernel half is present in both, at the same frame")

	// -- The same address, different memory ----------------------------------

	frame_a, got_a := mem.alloc_page_zeroed()
	frame_b, got_b := mem.alloc_page_zeroed()
	if !scheck(&r, got_a && got_b && frame_a != frame_b, "a frame each") {
		cleanup(space_a, space_b, frame_a, got_a, frame_b, got_b)
		report_space(&r)
		return
	}

	flags := arch.Page_Flags{.Write, .No_Execute}
	scheck(&r, mem.map_user(space_a, USER_VA, frame_a, flags, 1) == .None, "one maps the address")
	scheck(&r, mem.map_user(space_b, USER_VA, frame_b, flags, 1) == .None, "the other maps the same address")

	va, va_ok := mem.translate(space_a, USER_VA)
	vb, vb_ok := mem.translate(space_b, USER_VA)
	scheck(&r, va_ok && vb_ok && va != vb, "and the two resolve to different frames")

	perms, perm_ok := mem.permissions(space_a, USER_VA)
	scheck(&r, perm_ok && .User in perms, "a user mapping carries the bit that lets a program reach it")

	// -- What a user mapping may not name ------------------------------------

	/*
	A higher-half address with nothing at it, which is the one that tests the
	guard.

	The kernel image and the direct map are already mapped. `map_at` refuses
	either of those as a conflict, so the check would pass with no guard at all. This
	address is in the kernel half and empty. The only thing that can refuse it is
	`map_user` deciding a program may not name it.

	Getting that wrong is not a mapping in the wrong place. The top-level entry is
	one of the 256 every space shares. The mapping would appear in the kernel and
	in every other address space at once.
	*/
	kernel_va := uintptr(0xFFFF_C000_0000_0000)
	_, occupied := mem.translate(mem.kernel_address_space(), kernel_va)
	scheck(&r, !occupied, "an empty address in the kernel half, so the guard is what refuses it")
	scheck(
		&r,
		mem.map_user(space_a, kernel_va, frame_a, flags, 1) != .None,
		"and the kernel half is not an address a program may be given",
	)
	scheck(
		&r,
		mem.map_user(space_a, 0, frame_a, flags, 1) != .None,
		"and neither is page zero, so a null dereference faults",
	)

	// -- A thread in each ----------------------------------------------------

	sw_before := sched.stats().space_switches
	for i in 0 ..< 2 {
		occupants[i] = Occupant {
			slot  = i,
			wrote = MARKS[i],
		}
	}

	space := [2]^mem.Address_Space{space_a, space_b}
	started := 0
	for i in 0 ..< 2 {
		t := sched.spawn(
			"space-occupant",
			occupy,
			&occupants[i],
			sched.PRIORITY_NORMAL,
			sched.ANY_CLASS,
			sched.DEFAULT_STACK_SIZE,
			space[i],
		)
		if t != nil {
			started += 1
		}
	}
	scheck(&r, started == 2, "a thread runs in each")

	if started == 2 && scheck(&r, watch_space(both_done, nil), "and both come back") {
		r.switches = sched.stats().space_switches - sw_before

		scheck(&r, occupants[0].saw == MARKS[0], "the first saw its own mark")
		scheck(&r, occupants[1].saw == MARKS[1], "the second saw its own")
		scheck(
			&r,
			occupants[0].saw != occupants[1].saw,
			"and neither saw the other's, which is the whole of an address space",
		)
		scheck(&r, occupants[0].kernel_ok && occupants[1].kernel_ok, "with the kernel half reachable from both")
		scheck(&r, shared_witness == 2, "and written by both, into the one copy of it")
		scheck(&r, r.switches > 0, "the scheduler really did reload CR3")
	}

	// That the two frames really differ is visible from outside the spaces, now
	// that both threads wrote.
	scheck(&r, read_frame(frame_a) == MARKS[0], "the first space's frame holds the first mark")
	scheck(&r, read_frame(frame_b) == MARKS[1], "and the second's holds the second")

	// -- Teardown ------------------------------------------------------------

	r.frames = mem.space_stats().frames - before.frames
	scheck(&r, r.frames > 0, "the two spaces cost page tables")

	cleanup(space_a, space_b, frame_a, got_a, frame_b, got_b)

	after := mem.space_stats()
	scheck(&r, after.live == before.live, "every space was destroyed")
	scheck(&r, after.frames == before.frames, "and gave back every table it took")

	// The kernel is still here, which is the check that the teardown stopped at
	// the halfway index. A walk that freed the shared half would have taken the
	// tables this very read goes through.
	_, still := mem.translate(mem.kernel_address_space(), witness)
	scheck(&r, still, "and the kernel half it shares is untouched")

	report_space(&r)
}

/*
verify_lifetime builds one space, maps a page into it, and destroys it.

Two frames deep: a top-level table, and the three levels a 4 KiB mapping needs
under it. A teardown that stopped early or freed too much shows up as a number,
rather than as a fault somewhere later.

The frame the mapping points at is this procedure's, not the space's. It is
freed here, and the count only balances because both halves of that ownership
were honoured. See the file comment in `kernel/mem/space.odin`.
*/
@(private = "file")
verify_lifetime :: proc(r: ^Space_Result) {
	free_before := mem.pmm_stats().free_frames
	doubles_before := mem.pmm_stats().double_frees

	space, err := mem.space_new()
	if !scheck(r, err == .None && space != nil, "a space is built with nothing else running") {
		return
	}

	frame, got := mem.alloc_page_zeroed()
	if !scheck(r, got, "and a frame to put in it") {
		mem.space_destroy(space)
		return
	}

	scheck(
		r,
		mem.map_user(space, USER_VA, frame, {.Write, .No_Execute}, 1) == .None,
		"a page maps into it, growing three levels of table",
	)
	scheck(r, mem.pmm_stats().free_frames < free_before, "which costs frames")

	mem.space_destroy(space)
	mem.free_page(frame)

	scheck(
		r,
		mem.pmm_stats().free_frames == free_before,
		"and the teardown hands back every one of them",
	)

	/*
	And handed back only what was its.

	The count above balances whether or not the teardown freed the *leaf*. This
	procedure frees it too, and a second release finds the bit already clear and
	changes nothing. The allocator absorbed the
	double free silently, so the arithmetic agreed and the bug did not show.

	It is counted now. A teardown that frees a frame belonging to whoever mapped
	it is a double free the moment that owner frees it too. This is the check that
	says so.
	*/
	scheck(
		r,
		mem.pmm_stats().double_frees == doubles_before,
		"and nothing twice, which is what a space owning its leaves would do",
	)
}

@(private = "file")
read_frame :: proc "contextless" (frame: uintptr) -> u64 {
	return (cast(^u64)mem.phys_to_virt(frame))^
}

@(private = "file")
cleanup :: proc(
	a, b: ^mem.Address_Space,
	frame_a: uintptr,
	got_a: bool,
	frame_b: uintptr,
	got_b: bool,
) {
	mem.space_destroy(a)
	mem.space_destroy(b)
	if got_a {
		mem.free_page(frame_a)
	}
	if got_b {
		mem.free_page(frame_b)
	}
}

@(private = "file")
report_space :: proc(r: ^Space_Result) {
	ok := r.failures == 0 && r.checks > 0

	sink := begin(&klog)
	libodin.put_str(&sink, "space ")
	libodin.put_uint(&sink, u64(r.checks))
	if ok {
		libodin.put_str(&sink, " address space checks passed -- 2 spaces sharing one kernel half, ")
		libodin.put_uint(&sink, u64(r.frames))
		libodin.put_str(&sink, " tables between them, ")
		libodin.put_uint(&sink, r.switches)
		libodin.put_str(&sink, " CR3 reloads, one address two meanings")
		emit(&klog, .Ok, &sink)
		return
	}

	libodin.put_str(&sink, " checks, ")
	libodin.put_uint(&sink, u64(r.failures))
	libodin.put_str(&sink, " FAILED -- first: ")
	libodin.put_str(&sink, r.first_failure)
	emit(&klog, .Fault, &sink)
}
