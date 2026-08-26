/*
The namespace under threads.

`kernel/vfs/verify.odin` answers "does the namespace mean the right thing",
one thread at a time. This file answers the question preemption added: does it
still mean that when two threads are inside it at once.

Four races, each with a lock that is supposed to close it:

  1. **One session, two callers.** A fid is a plain counter increment and a
     reply borrows the server's own buffer. Two threads walking the same server
     can be handed the same fid, and one can overwrite the directory listing
     the other is halfway through copying. `Server.lock` is the answer, and it
     is the one lock in the package held *across* a message.
  2. **Reference counts.** Chans are shared between namespaces; an increment
     that is read-modify-write is an increment that can be lost, and a lost
     increment is a chan freed while someone holds it. `object_lock`.
  3. **The mount table.** A walk consults it between every path element while
     another thread rearranges it. `Namespace.lock`, plus taking a reference to
     anything that leaves it -- see `cross_mounts`.
  4. **A dissolved union.** Not a race at all: a chan reached through a union
     keeps a pointer to the mount point, and unmounting freed it. Reachable
     with one thread and a chan held across an `unmount`, and it was reachable
     before there were threads. Checked deterministically, because it can be.

The workers hammer real paths over real 9P traffic and check what they read
against what they asked for. Everything shared with them is `volatile` -- these
are concurrent variables, and a spin loop the compiler is allowed to hoist is a
spin loop that never ends.

## What the negative controls say

Every check here was run against a deliberately broken build, in both build
modes, because a self-test that cannot fail proves nothing. Three of five
mutations are caught, and the two that are not are the more interesting half.

    remove Server.lock                        caught -- both listers, at once
    free a referenced Mount_Point             caught -- the reference count
    hold a namespace lock across a message    caught -- EDEADLK, four checks
    drop cross_mounts' reference to a member  NOT caught
    unlocked chan reference counts            NOT caught

The last two are not caught, and will not be by any run of this length. Both
windows are a few instructions wide: the gap between reading a member out of
the mount table and cloning it, and the gap between loading a reference count
and storing it back. Catching one means landing a timer interrupt inside about
thirty instructions out of the twenty thousand a round takes, *and* having
another thread free that exact object before this one resumes. Fifty thousand
namespace operations against seven thousand rebinds found neither.

Turning the tick rate up helps far less than it sounds like it should, which is
itself worth knowing: at 20 kHz only about 1.4 times as many ticks are actually
*delivered*. Every lock in `kernel/sync` is the interrupt flag, and this layer
holds one for most of its instructions -- across every message, every heap call,
every table lookup -- so the LAPIC coalesces what it cannot deliver. A
uniprocessor Vectra thread doing file I/O is very nearly non-preemptible, which
is what makes the narrow races very nearly unreachable.

So those two locks are here on the argument rather than the evidence. On a
second CPU the same windows stop being a matter of timing luck and become two
cores executing at once. Which is exactly why they are cheap to leave out now
and expensive to find later.

The one thing this test did catch on its own is in `walk1_ex`: a union searched
by index while a member is removed from the front of the list skips an entry,
and a name that never moved comes back ENOENT. Plan 9 does not have that
problem because it holds a sleeping read lock across the whole search. See
`Mount_Point.generation` for what replaces it.
*/
package kernel

import "base:intrinsics"
import "base:runtime"

import "kernel:mem"
import "kernel:sched"
import "kernel:vfs"
import "vsys:libodin"
import "vsys:vectra9"

/*
Two servers, and the shape of them is the test.

`#t` holds two directories with six files each, named so that a listing of one
can never be mistaken for a listing of the other: every name and every file's
contents begin with the directory's own letter. Equal lengths throughout, so a
reply that gets overwritten by the other directory's is exactly the same size
and cannot be caught by a length check -- only by reading it.
*/
@(private = "file")
TREE_T_NODES := [?]vfs.Static_Node {
	{name = "/", parent = -1, dir = true},
	{name = "a", parent = 0, dir = true},
	{name = "b", parent = 0, dir = true},
	{name = "a0", parent = 1, data = "a0 data\n"},
	{name = "a1", parent = 1, data = "a1 data\n"},
	{name = "a2", parent = 1, data = "a2 data\n"},
	{name = "a3", parent = 1, data = "a3 data\n"},
	{name = "a4", parent = 1, data = "a4 data\n"},
	{name = "a5", parent = 1, data = "a5 data\n"},
	{name = "b0", parent = 2, data = "b0 data\n"},
	{name = "b1", parent = 2, data = "b1 data\n"},
	{name = "b2", parent = 2, data = "b2 data\n"},
	{name = "b3", parent = 2, data = "b3 data\n"},
	{name = "b4", parent = 2, data = "b4 data\n"},
	{name = "b5", parent = 2, data = "b5 data\n"},
}

// `#u` is what gets bound and unbound underneath everyone else. Its names
// share no prefix with `#t`'s, so a union listing says which tree it came from.
@(private = "file")
TREE_U_NODES := [?]vfs.Static_Node {
	{name = "/", parent = -1, dir = true},
	{name = "u0", parent = 0, data = "u0 data\n"},
	{name = "u1", parent = 0, data = "u1 data\n"},
	{name = "u2", parent = 0, data = "u2 data\n"},
}

@(private = "file")
DIR_ENTRIES :: 6

@(private = "file")
tree_t: vfs.Static_Tree
@(private = "file")
tree_u: vfs.Static_Tree
@(private = "file")
server_t: vfs.Server
@(private = "file")
server_u: vfs.Server

/*
How long the workers run, measured in ticks rather than rounds.

A round count was the first version and it was the wrong axis. What finds a
race is not how many namespace operations happen, it is how many times a thread
is interrupted in the middle of one -- and a release build does the same three
thousand operations in a thirteenth of the ticks a debug build takes. Fixing
the round count therefore made the optimised kernel test itself thirteen times
less thoroughly, which was demonstrable: removing the session lock failed the
run every time under `just run` and passed every time under `just release`.

So the workers run until told to stop and the boot thread stops them by the
clock. Both builds now get the same number of preemptions; the fast one simply
gets more work done between them, which is exactly the right way round.
*/
@(private = "file")
RUN_TICKS :: 1000

// Below this many rounds a worker did not meaningfully run, whatever the clock
// says, and the run proves nothing about it.
@(private = "file")
MIN_ROUNDS :: 50

/*
How the boot thread decides the run is over.

Not a yield budget, and not a yield loop at all -- which was the first attempt
and was wrong in an instructive way. A thread that waits by yielding never
burns a slice, so it never decays, while the workers burn every slice they get
and decay to the bottom within a few of them. The waiter then outranks
everything it is waiting for and gets dispatched forever. The scheduler was
doing exactly what it was built to do: an interactive thread beats a CPU-bound
one. It just made the waiter the most interactive thread on the machine.

So the boot thread spins instead, the way `verify_preemption` does, and decays
alongside the workers into an even rotation. What bounds the wait is progress:
if the workers have completed no further rounds in STALL_TICKS milliseconds,
something is stuck, and that is a failed check rather than a hung boot.
*/
@(private = "file")
STALL_TICKS :: 500

@(private = "file")
WORKERS :: 5

// -- What the workers report -------------------------------------------------

@(private = "file")
stop: bool
@(private = "file")
finished: int
@(private = "file")
list_errors: [2]int // Listings that came back as another directory's, or torn
@(private = "file")
list_done: [2]int
@(private = "file")
read_errors: int // `/mnt/a/a0` that did not read back as itself
@(private = "file")
read_done: int
@(private = "file")
churn_errors: int // A bind or unmount that refused
@(private = "file")
churn_done: int
@(private = "file")
union_errors: int // A union listing with a name from no tree in it
@(private = "file")
deadlocks: int // Any EDEADLK: a lock was held across a message

@(private = "file")
bump :: proc "contextless" (p: ^int) {
	intrinsics.volatile_store(p, intrinsics.volatile_load(p) + 1)
}

@(private = "file")
note :: proc "contextless" (err: vfs.Errno, counter: ^int) {
	if err == vfs.OK {
		return
	}
	if err == vectra9.EDEADLK {
		bump(&deadlocks)
	}
	bump(counter)
}

// -- The workers -------------------------------------------------------------

/*
Every worker starts by giving itself a context.

A `Thread_Proc` is `contextless` -- the scheduler has no opinion about
allocators -- so the first thing a thread that means to allocate does is say
which one. Without this line every `new` in the namespace layer returns nil and
the worker reports failures that are its own fault.
*/
@(private = "file")
worker_context :: proc "contextless" () -> runtime.Context {
	c := runtime.default_context()
	c.allocator = mem.allocator()
	return c
}

/*
list_worker lists one directory of `#t`, forever, and checks what came back.

Reached through `#t` rather than through a path, so nothing here touches the
mount table: this worker is a test of one session with two threads in it and
nothing else. Two of them run, on `a` and on `b`, and the only thing that can
put a `b` name in the `a` listing is the two of them sharing a fid or a buffer.
*/
@(private = "file")
list_worker :: proc "contextless" (arg: rawptr) #no_bounds_check {
	context = worker_context()

	which := int(uintptr(arg))
	letter := u8('a') + u8(which)
	path := which == 0 ? "#t/a" : "#t/b"

	buf: [512]u8
	for !intrinsics.volatile_load(&stop) {
		if !list_is(path, letter, buf[:], &list_errors[which]) {
			bump(&list_errors[which])
		}
		bump(&list_done[which])
	}
	bump(&finished)
}

/*
list_is opens a directory and reports whether every entry belongs to it.

Six entries, each named for the directory it is in. Anything else -- a short
listing, a name starting with the other letter, a cursor that fails partway --
means the reply was not the one this thread asked for.
*/
@(private = "file")
list_is :: proc(path: string, letter: u8, buf: []u8, errs: ^int) -> bool #no_bounds_check {
	c, err := vfs.open_path(vfs.boot_namespace, path, vfs.O_RDONLY | vfs.O_DIRECTORY)
	if err != vfs.OK {
		note(err, errs)
		return false
	}
	defer vfs.chan_close(c)

	seen := 0
	offset := u64(0)
	for _ in 0 ..< DIR_ENTRIES + 2 {
		n: int
		n, err = vfs.readdir(c, offset, buf)
		if err != vfs.OK {
			note(err, errs)
			return false
		}
		if n == 0 {
			break
		}
		cursor := vectra9.cursor_from(buf[:n])
		for {
			entry, more := vectra9.next_dirent(&cursor)
			if !more {
				break
			}
			if len(entry.name) == 0 || entry.name[0] != letter {
				return false
			}
			offset = entry.offset
			seen += 1
		}
		if cursor.err != .None {
			return false
		}
	}
	return seen == DIR_ENTRIES
}

/*
read_worker reads one file through the namespace while the table moves.

`/mnt/a/a0` lives in `#t`, which stays bound to `/mnt` for the whole run, so
the answer is the same every time no matter what the churn thread is doing to
the second member. A walk that consulted a mount point mid-rearrangement, or
followed a member that had just been freed, does not get to keep returning
"a0 data\n".
*/
@(private = "file")
read_worker :: proc "contextless" (arg: rawptr) {
	context = worker_context()
	_ = arg

	buf: [64]u8
	for !intrinsics.volatile_load(&stop) {
		c, err := vfs.open_path(vfs.boot_namespace, "/mnt/a/a0", vfs.O_RDONLY)
		if err != vfs.OK {
			note(err, &read_errors)
		} else {
			n: int
			n, err = vfs.chan_read(c, 0, buf[:])
			if err != vfs.OK || string(buf[:n]) != "a0 data\n" {
				note(err, &read_errors)
				if err == vfs.OK {
					bump(&read_errors)
				}
			}
			vfs.chan_close(c)
		}
		bump(&read_done)
	}
	bump(&finished)
}

/*
union_worker lists `/mnt` while its membership is changing underneath.

The one path where a listing is assembled from several trees, and the one that
has to re-find its place in the member list between every message -- see
`member_ref_at`. What it cannot check is *how many* names come back: rebinding
a union mid-listing is undefined by design, in Plan 9 and here, because the
cookie names a position in a list that moved. What it can check is that every
name that does come back belongs to a tree that was bound at some point, and
that the listing ends. A member freed under the walker produces neither.
*/
@(private = "file")
union_worker :: proc "contextless" (arg: rawptr) #no_bounds_check {
	context = worker_context()
	_ = arg

	buf: [512]u8
	for !intrinsics.volatile_load(&stop) {
		c, err := vfs.open_path(
			vfs.boot_namespace,
			"/mnt",
			vfs.O_RDONLY | vfs.O_DIRECTORY,
		)
		if err != vfs.OK {
			note(err, &union_errors)
			continue
		}

		offset := u64(0)
		ended := false
		for _ in 0 ..< MAX_UNION_PASSES {
			n: int
			n, err = vfs.readdir(c, offset, buf[:])
			if err != vfs.OK {
				note(err, &union_errors)
				break
			}
			if n == 0 {
				ended = true
				break
			}
			cursor := vectra9.cursor_from(buf[:n])
			for {
				entry, more := vectra9.next_dirent(&cursor)
				if !more {
					break
				}
				if !known_name(entry.name) {
					bump(&union_errors)
				}
				offset = entry.offset
			}
			if cursor.err != .None {
				bump(&union_errors)
				break
			}
		}
		if !ended && err == vfs.OK {
			bump(&union_errors)
		}
		vfs.chan_close(c)
	}
	bump(&finished)
}

// The complete vocabulary of `/mnt`: `#t`'s two directories and `#u`'s three
// files. Anything else came out of a buffer that was not this listing's.
@(private = "file")
known_name :: proc "contextless" (name: string) -> bool {
	switch name {
	case "a", "b", "u0", "u1", "u2":
		return true
	}
	return false
}

// Five names, a few per message, plus room for the union to be re-entered as
// members come and go. A listing that has not ended by here is one that is not
// making progress.
@(private = "file")
MAX_UNION_PASSES :: 64

/*
churn_worker binds and unbinds a second member of `/mnt` under everyone else.

Every operation must succeed, and `#u` goes on the *front* of the list, which
is the sharper of the two choices. A member appended to the end is one a walk
usually never reaches; a member at the front is the one `cross_mounts`
substitutes for `/mnt` itself, so it is the chan every walker is holding at the
moment this thread unbinds it. That is the window a reference is for.

`/mnt/a` is answered by `#t` throughout regardless -- `#u` does not have an `a`,
so the union search falls through to the member behind it. What moves is which
tree a walker is standing on, not what it finds.
*/
@(private = "file")
churn_worker :: proc "contextless" (arg: rawptr) {
	context = worker_context()
	_ = arg

	for !intrinsics.volatile_load(&stop) {
		note(vfs.mount_device(vfs.boot_namespace, "#u", "/mnt", .Before), &churn_errors)
		note(vfs.unmount_path(vfs.boot_namespace, "#u", "/mnt"), &churn_errors)
		bump(&churn_done)
	}
	bump(&finished)
}

// -- The boot thread's part --------------------------------------------------

@(private = "file")
verify_live :: proc "contextless" (s: mem.Heap_Stats) -> int {
	live := s.large_blocks
	for i in 0 ..< len(s.class_total) {
		live += s.class_total[i] - s.class_free[i]
	}
	return live
}

@(private = "file")
Vfs_Threads :: struct {
	checks:        int,
	failures:      int,
	first_failure: string,
	operations:    int, // Namespace operations the workers completed
	rebinds:       int,
	ticks:         u64, // What the run cost the boot, in timer ticks
	leaked_run:    int, // Objects the worker phase did not give back
	leaked_total:  int,
	settled:       bool, // Every worker is gone; teardown is safe
}

// completed totals what the workers have finished, for the progress check. A
// plain sum of volatile loads: it does not have to be a consistent snapshot,
// only larger than it was.
@(private = "file")
completed :: proc "contextless" () -> int #no_bounds_check {
	return(
		intrinsics.volatile_load(&list_done[0]) +
		intrinsics.volatile_load(&list_done[1]) +
		intrinsics.volatile_load(&read_done) +
		intrinsics.volatile_load(&churn_done) 	)
}

@(private = "file")
tcheck :: proc "contextless" (r: ^Vfs_Threads, ok: bool, what: string) -> bool {
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
verify_vfs_threads runs the whole thing and reports.

Bracketed by heap stats like the single-threaded self-test, and for a sharper
reason here: the failure mode of a lost reference count is not a wrong answer,
it is a chan freed early or never. Neither shows up as a failed check. Both
show up as a heap that does not come back to where it started.
*/
verify_vfs_threads :: proc() {
	r: Vfs_Threads

	if !tcheck(&r, vfs.boot_namespace != nil, "boot namespace exists") {
		report_vfs_threads(&r)
		return
	}
	if !tcheck(&r, vfs.static_init(&tree_t, "t", TREE_T_NODES[:]), "#t server tables") {
		report_vfs_threads(&r)
		return
	}
	if !tcheck(&r, vfs.static_init(&tree_u, "u", TREE_U_NODES[:]), "#u server tables") {
		vfs.static_destroy(&tree_t)
		report_vfs_threads(&r)
		return
	}

	tcheck(&r, vfs.server_init(&server_t, "t", vfs.static_handler, &tree_t) == .None, "#t Tversion")
	tcheck(&r, vfs.server_init(&server_u, "u", vfs.static_handler, &tree_u) == .None, "#u Tversion")
	tcheck(&r, vfs.register_device(&server_t), "#t registered")
	tcheck(&r, vfs.register_device(&server_u), "#u registered")

	before := verify_live(mem.heap_stats())

	tcheck(
		&r,
		vfs.mount_device(vfs.boot_namespace, "#t", "/mnt") == vfs.OK,
		"#t bound at /mnt",
	)

	run_workers(&r)
	r.leaked_run = verify_live(mem.heap_stats()) - before
	if !r.settled {
		// A worker is still in there. Everything from here down would be
		// pulling the floor out from under it; leave the servers standing and
		// report what is known.
		report_vfs_threads(&r)
		return
	}

	verify_dissolved_union(&r)

	// Leave the namespace as it was found, so the heap bracket below means
	// what it says and so nothing after this boots into a rearranged `/mnt`.
	tcheck(
		&r,
		vfs.unmount_path(vfs.boot_namespace, "", "/mnt") == vfs.OK,
		"/mnt unbound again",
	)

	r.leaked_total = verify_live(mem.heap_stats()) - before
	tcheck(&r, r.leaked_total == 0, "every chan and mount point was released")

	vfs.static_destroy(&tree_u)
	vfs.static_destroy(&tree_t)
	report_vfs_threads(&r)
}

/*
run_workers starts four threads and waits for them.

The wait is a yield loop with a bound rather than a join, because there is no
join: a thread that never finishes is a scheduler question, and the only thing
this self-test owes the boot is to say so rather than to hang.
*/
@(private = "file")
run_workers :: proc(r: ^Vfs_Threads) #no_bounds_check {
	intrinsics.volatile_store(&finished, 0)
	intrinsics.volatile_store(&stop, false)

	spawned := 0
	if sched.spawn("vfs-list-a", list_worker, rawptr(uintptr(0))) != nil {
		spawned += 1
	}
	if sched.spawn("vfs-list-b", list_worker, rawptr(uintptr(1))) != nil {
		spawned += 1
	}
	if sched.spawn("vfs-read", read_worker) != nil {
		spawned += 1
	}
	if sched.spawn("vfs-union", union_worker) != nil {
		spawned += 1
	}
	if sched.spawn("vfs-churn", churn_worker) != nil {
		spawned += 1
	}
	if !tcheck(r, spawned == WORKERS, "every worker spawned") {
		return
	}

	// Let them run by the clock, then ask them to stop. The spin is the point
	// -- see STALL_TICKS -- and it decays into an even rotation with the rest.
	started := sched.ticks()
	for sched.ticks() - started < RUN_TICKS {
	}
	intrinsics.volatile_store(&stop, true)

	// Now wait for them to notice. Bounded by progress rather than by a
	// deadline: a worker that is not finishing and not advancing is stuck.
	checked := sched.ticks()
	seen := completed()
	for intrinsics.volatile_load(&finished) < WORKERS {
		now := sched.ticks()
		if now - checked < STALL_TICKS {
			continue
		}
		checked = now
		if done := completed(); done > seen {
			seen = done
			continue
		}
		break
	}
	r.ticks = sched.ticks() - started

	// Nothing below here is safe to run while a worker is still inside the
	// namespace, and neither is the teardown in the caller -- destroying a
	// server's fid table under a live client is a fault, not a failed check.
	// So this is the one failure that stops the self-test rather than counting.
	if !tcheck(r, intrinsics.volatile_load(&finished) == WORKERS, "every worker finished") {
		return
	}

	/*
	Collect the corpses before anyone measures the heap.

	A dead thread is still standing on its stack when it is descheduled, so the
	free waits for something else to be running -- which in practice means the
	next `spawn`, and nothing spawns after this. Five threads and five stacks
	would otherwise show up in the bracket below as ten leaked objects, which
	is true and has nothing to do with the namespace.
	*/
	sched.reap()
	r.settled = true

	a_done := intrinsics.volatile_load(&list_done[0])
	b_done := intrinsics.volatile_load(&list_done[1])
	reads := intrinsics.volatile_load(&read_done)
	rebinds := intrinsics.volatile_load(&churn_done)

	r.operations = a_done + b_done + reads
	r.rebinds = rebinds

	tcheck(r, a_done >= MIN_ROUNDS && b_done >= MIN_ROUNDS, "both listers got a share of the core")
	tcheck(r, reads >= MIN_ROUNDS, "so did the reader")
	tcheck(r, rebinds >= MIN_ROUNDS, "so did the thread rearranging the table under them")

	// The four that matter. Each is one lock's job, and each of them fails
	// loudly and often when that lock is not there.
	tcheck(r, intrinsics.volatile_load(&list_errors[0]) == 0, "/a listed only /a, every time")
	tcheck(r, intrinsics.volatile_load(&list_errors[1]) == 0, "/b listed only /b, every time")
	tcheck(r, intrinsics.volatile_load(&read_errors) == 0, "a file read the same under a moving mount table")
	tcheck(r, intrinsics.volatile_load(&churn_errors) == 0, "every bind and unmount succeeded")
	tcheck(r, intrinsics.volatile_load(&union_errors) == 0, "no union listing invented a name")
	tcheck(r, intrinsics.volatile_load(&deadlocks) == 0, "no lock was held across a message")
}

/*
verify_dissolved_union is the one check that needs no threads.

A chan reached through a union keeps a reference to the mount point, because
`readdir` has to find the other members through it. Unmounting used to free
that object while the chan still pointed at it -- a use-after-free reachable by
one thread holding a directory open across an `unmount`, which is an ordinary
thing to do.

The shape of this check is the interesting part, and it took two attempts. The
obvious version -- dissolve the union, then read through the held chan -- passes
whether or not the fix is there, because a freed `Mount_Point` still reads as
one: the allocator writes its free list link over the first field and leaves
`members` exactly as `unmount` left it, which is nil, which is what a correctly
dissolved mount point looks like. A use-after-free that reads plausible data is
the whole reason use-after-free is hard to find.

So the block has to be *reused* before it is read. Dissolving `/mnt` and
immediately building a different union at the same name puts a fresh
`Mount_Point` at the head of the same size class's free list -- which is the
block that was just freed, if it was freed. The held chan then finds itself
pointing at a live union it was never part of, and lists a tree it is not
standing on. With the reference in place the new union is a different object,
the chan's own mount point is still dissolved and still empty, and it lists the
one tree it actually has a fid on.
*/
@(private = "file")
verify_dissolved_union :: proc(r: ^Vfs_Threads) {
	ns := vfs.boot_namespace

	if !tcheck(r, vfs.mount_device(ns, "#u", "/mnt", .After) == vfs.OK, "#u bound after #t") {
		return
	}

	c, err := vfs.open_path(ns, "/mnt", vfs.O_RDONLY | vfs.O_DIRECTORY)
	if !tcheck(r, err == vfs.OK, "/mnt opens as a union") {
		return
	}
	defer vfs.chan_close(c)

	mp := c.union_head
	tcheck(r, mp != nil, "a union chan remembers its mount point")
	tcheck(r, vfs.mount_point_refs(mp) == 2, "which the table and the chan each hold")

	// Every member goes, including the one this chan is standing on. The chan
	// itself is untouched -- it holds its own fid on `#t`'s root.
	tcheck(r, vfs.unmount_path(ns, "", "/mnt") == vfs.OK, "/mnt dissolved while open")

	// The check the behavioural ones below cannot make. A mount point freed
	// one reference early goes on reading as a valid empty one for as long as
	// nothing claims the block, so the listing comes out right either way and
	// the bug survives the test. The count is the thing that actually differs.
	tcheck(r, vfs.mount_point_refs(mp) == 1, "leaving the chan's reference and no other")
	tcheck(r, vfs.member_count(mp) == 0, "and no members")

	/*
	A second union at the same name, built out of the same size class the first
	one would have been freed into -- and deliberately the other way round.

	`#u` goes first this time. If it went first-is-`#t` again the two unions
	would be indistinguishable from this chan's point of view, because member
	zero would be the tree it is already standing on either way, and the
	listing would come out right whether or not it was reading the wrong mount
	point. Order is what makes the difference observable.
	*/
	tcheck(r, vfs.mount_device(ns, "#u", "/mnt") == vfs.OK, "/mnt rebound to #u")
	tcheck(r, vfs.mount_device(ns, "#t", "/mnt", .After) == vfs.OK, "and unioned the other way round")

	buf: [512]u8
	n: int
	n, err = vfs.readdir(c, 0, buf[:])
	if !tcheck(r, err == vfs.OK && n > 0, "a chan outlives the union it was reached through") {
		return
	}

	// What it lists is `#t`'s root, which is what it was standing on: `a` and
	// `b`, and nothing from the union that replaced the one it came through.
	names := 0
	foreign_name := false
	cursor := vectra9.cursor_from(buf[:n])
	for {
		entry, more := vectra9.next_dirent(&cursor)
		if !more {
			break
		}
		if len(entry.name) == 0 || (entry.name[0] != 'a' && entry.name[0] != 'b') {
			foreign_name = true
			break
		}
		names += 1
	}
	tcheck(r, !foreign_name, "a dissolved union lists only the tree the chan is on")
	tcheck(r, names == 2, "and lists all of it")
}

@(private = "file")
report_vfs_threads :: proc(r: ^Vfs_Threads) {
	sink := begin(&klog)
	libodin.put_str(&sink, "vfs ")
	libodin.put_uint(&sink, u64(r.checks))
	if r.failures == 0 && r.checks > 0 {
		libodin.put_str(&sink, " concurrency checks passed -- ")
		libodin.put_uint(&sink, u64(r.operations))
		libodin.put_str(&sink, " namespace operations across 5 threads, ")
		libodin.put_uint(&sink, u64(r.rebinds))
		libodin.put_str(&sink, " rebinds under them in ")
		libodin.put_uint(&sink, r.ticks)
		libodin.put_str(&sink, " ms, heap balanced")
		emit(&klog, .Ok, &sink)
		return
	}

	libodin.put_str(&sink, " concurrency checks, ")
	libodin.put_uint(&sink, u64(r.failures))
	libodin.put_str(&sink, " FAILED -- first: ")
	libodin.put_str(&sink, r.first_failure)
	libodin.put_str(&sink, " (leaked ")
	libodin.put_int(&sink, i64(r.leaked_run))
	libodin.put_str(&sink, " in the run, ")
	libodin.put_int(&sink, i64(r.leaked_total))
	libodin.put_str(&sink, " overall)")
	emit(&klog, .Fault, &sink)
}
