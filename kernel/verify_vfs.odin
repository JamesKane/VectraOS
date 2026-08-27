/*
The namespace under threads.

`kernel/vfs/verify.odin` answers "does the namespace mean the right thing",
one thread at a time. This file answers the question preemption added: does it
still mean that when two threads are inside it at once.

Four races, each with a lock that is supposed to close it.

Since `Server.lock` started to sleep, this file watches a fifth thing. That is
whether the workers get a fair share of the machine at all. A lock that decides
who runs next is a scheduler, and this is where it gets to be wrong in public.

  1. **One session, two callers.** A fid is a plain counter increment and a
     reply borrows the server's own buffer. Two threads walking the same server
     can be handed the same fid, and one can overwrite the directory listing
     the other is halfway through copying. `Server.lock` is the answer, and it
     is the one lock in the package held *across* a message.
  2. **Reference counts.** Chans are shared between namespaces, and an
  increment
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
against what they asked for. Everything shared with them is `volatile`. These
are concurrent variables, and a spin loop the compiler may hoist is a spin loop
that never ends.

## What the negative controls say

Every check here was run against a deliberately broken build, in both build
modes, because a self-test that cannot fail proves nothing.

    free a referenced Mount_Point             caught -- the reference count
    hold a namespace lock across a message    caught -- EDEADLK, four checks
    boost a thread woken by a lock            caught -- two workers starved
    serve waiters in arrival order            caught, one run in ten
    union_pass leaves a cookie unstamped      caught -- the union worker
    drop cross_mounts' reference to a member  NOT caught
    unlocked chan reference counts            NOT caught
    remove Static_Tree.lock                   NOT caught

**There used to be a `remove Server.lock` row at the top, and it was caught.**
That lock is gone. It served one message at a time per server, which is what
made a borrowed reply safe. Removing it let two listers into the same directory
buffer at once. A request slot owns its payload buffer now, so there is no
shared buffer to remove a lock from. `docs/NAMESPACE.md` has the whole of what
changed.

What replaced it in this table is the row underneath, and the result is
different. `Static_Tree.lock` is the *server's* own, and with the directory
buffer no longer shared the only thing left under it is a fid table. Removed,
that is a few instructions between a slot read and a slot written, and this run
does not find it.

**So three mutations are uncaught, and they are the same shape.** One is a
reference count loaded and stored back. One is a member read out of the mount
table and cloned. One is a fid slot claimed and marked. Every one is two or
three instructions wide, and none is at a lock boundary.

Making this layer preemptible did not change that, which is worth knowing
because it falsified the first explanation. The story used to be that a
uniprocessor holding a spinlock for most of its instructions is nearly
impossible to interrupt. A tick rate raised to 20 kHz delivered only 1.4 times
as many ticks, because the LAPIC coalesces what it cannot deliver.

A sleeping session lock removed that objection entirely, and the run then parked
a hundred thousand times, at every message boundary. Neither mutation was
caught in either build mode. Voluntary switches, however many, do not interleave
two threads at an arbitrary instruction. Only a timer does, and only a second
CPU makes one land reliably.

So those two locks are here on the argument rather than the evidence. The
argument is sharper now that something falsified its first explanation.

The one thing this test caught on its own is in `walk1_ex`. A union searched by
index, while something removes a member from the front of the list, skips an
entry. A name that never moved then comes back ENOENT. Plan 9 does not have
that problem because it holds a sleeping read lock across the whole search. See
`Mount_Point.generation` for what replaces it.
*/
package kernel

import "base:intrinsics"
import "base:runtime"

import "kernel:mem"
import "kernel:sched"
import "kernel:sync"
import "kernel:vfs"
import "vsys:libodin"
import "vsys:vectra9"

/*
Two servers, and the shape of them is the test.

`#t` holds two directories with six files each. Nothing can mistake a listing
of one for a listing of the other. Every name, and every file's contents, begin
with the directory's own letter.

Equal lengths throughout. A reply the other directory's overwrites is therefore
exactly the same size. No length check catches that. Only a read of it does.
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

A round count was the first version, and it was the wrong axis. What finds a
race is not how many namespace operations happen. It is how often a timer
interrupts a thread in the middle of one. And a release build does the same
three thousand operations in a thirteenth of the ticks a debug build takes.

A fixed round count therefore made the optimised kernel test itself thirteen
times less thoroughly. That was demonstrable. With the session lock removed,
the run failed every time under `just run`, and passed every time under `just
release`.

So the workers run until told to stop and the boot thread stops them by the
clock. Both builds now get the same number of preemptions. The fast one simply
gets more work done between them, which is exactly the right way round.
*/
@(private = "file")
RUN_TICKS :: 1000

// Below this many rounds a worker did not meaningfully run, whatever the clock
// says, and the run proves nothing about it.
@(private = "file")
MIN_ROUNDS :: 50

/*
How far apart the busiest and the quietest worker may finish.

A round is not the same amount of work in every worker. The churn thread's
costs several times a listing. So this is not a fairness bar, and cannot be
one. It is an order-of-magnitude starvation bar. It is here because the first
sleeping lock walked straight into the thing it checks for.

Served in arrival order, the lock ignored priority entirely. The quietest
thread got a fiftieth of what its neighbours did. Serving the best waiter
instead puts the spread between two and four, in both build modes, which is
what the number below leaves room for.
*/
@(private = "file")
MAX_SPREAD :: 20

/*
Who watches the clock, and why the boot thread does not.

Three attempts got this wrong, and all three were about priority.

The first waited by yielding. A thread that yields never burns a slice, so it
never decays. The workers burn every slice, and decay to the bottom within a
few. The waiter then outranked everything it waited for, and reached the core
forever.

The second spun instead, which worked for exactly as long as nothing in the
namespace blocked. `Server.lock` became a sleeping lock, and that stopped being
true. `ready` wakes a worker parked on a contended session, and boosts it back
above its base. The workers now sit *above* a boot thread that only ever
decays. The waiter starved rather than the workers, which is the same bug from
the other end. A test cannot rely on a spin loop's priority, in either
direction.

The third attempt took the boot thread out of the race, and gave the job to the
workers. Every one of them reads the same deadline and stops itself. The boot
thread then only had to notice they were gone. That is still how the run ends,
and it is still right. What it did not fix was that last step, which was a poll
with a progress watchdog stapled to it.

That loop's correctness still depended on the priority of the thread that ran
it. All three attempts had just proved nothing can rely on that.

The fourth is the one that stops the argument. The boot thread parks on a
rendezvous until the last worker finishes. It is therefore not on a run queue
at all, and its priority is not a number anything consults. `PATIENCE` is what
keeps a wedged worker from becoming a hung boot: the wait has a deadline, and
missing it is a failed check.

The lesson is worth the four paragraphs. A thread that must not compete should
not be runnable. Every cheaper way to say that turned out to be a statement
about priorities, and some later change was free to falsify it.
*/
@(private = "file")
PATIENCE :: 500

@(private = "file")
WORKERS :: 5

// -- What the workers report -------------------------------------------------

// Where the boot thread waits for the last worker.
@(private = "file")
all_done: sync.Rendez

@(private = "file")
stop: bool
@(private = "file")
deadline: u64 // Absolute tick the workers stop themselves at
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

/*
running is every worker's loop condition.

Each worker checks the deadline itself, rather than waits to hear. The first
one past it latches `stop`, so the others need not reach it independently.

That matters for the churn worker, whose round is the longest.
*/
@(private = "file")
running :: proc "contextless" () -> bool {
	if intrinsics.volatile_load(&stop) {
		return false
	}
	if sched.ticks() >= intrinsics.volatile_load(&deadline) {
		intrinsics.volatile_store(&stop, true)
		return false
	}
	return true
}

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

A `Thread_Proc` is `contextless`, because the scheduler has no opinion about
allocators. So the first thing a thread that means to allocate does is name
one. Without this line every `new` in the namespace layer returns nil and the
worker reports failures that are its own fault.
*/
@(private = "file")
worker_context :: proc "contextless" () -> runtime.Context {
	c := runtime.default_context()
	c.allocator = mem.allocator()
	return c
}

/*
list_worker lists one directory of `#t`, forever, and checks what came back.

Reached through `#t` rather than a path, so nothing here touches the mount
table. This worker tests one session with two threads in it, and nothing else.
Two of them run, on `a` and on `b`. Only one thing can put a `b` name in the
`a` listing, and that is the two of them sharing a fid or a buffer.
*/
@(private = "file")
list_worker :: proc "contextless" (arg: rawptr) #no_bounds_check {
	context = worker_context()

	which := int(uintptr(arg))
	letter := u8('a') + u8(which)
	path := which == 0 ? "#t/a" : "#t/b"

	buf: [512]u8
	for running() {
		if !list_is(path, letter, buf[:], &list_errors[which]) {
			bump(&list_errors[which])
		}
		bump(&list_done[which])
	}
	bump(&finished)
	sync.wakeup(&all_done)
}

/*
list_is opens a directory and reports whether every entry belongs to it.

Six entries, each named for the directory it is in. Anything else means the
reply was not the one this thread asked for. That covers a short listing, a
name that starts with the other letter, and a cursor that fails part-way.
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

`/mnt/a/a0` lives in `#t`, and that stays bound to `/mnt` for the whole run.
The answer is therefore the same every time, whatever the churn thread does to
the second member. A walk that consulted a mount point mid-rearrangement, or
followed a member that had just been freed, does not get to keep returning "a0
data\n".
*/
@(private = "file")
read_worker :: proc "contextless" (arg: rawptr) {
	context = worker_context()
	_ = arg

	buf: [64]u8
	for running() {
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
	sync.wakeup(&all_done)
}

/*
union_worker lists `/mnt` while its membership is changing underneath.

The one path that assembles a listing from several trees. It is also the one
that has to find its place in the member list again between every message. See
`member_ref_at`.

What it cannot check is *how many* names come back. Plan 9 leaves a union
rebound part-way through a listing undefined by design, and so does this. The
cookie names a position in a list that moved.

What it can check is that every name that comes back belongs to a tree
something bound at some point. It also checks that the listing ends. A member
freed under the walker produces neither.
*/
@(private = "file")
union_worker :: proc "contextless" (arg: rawptr) #no_bounds_check {
	context = worker_context()
	_ = arg

	buf: [512]u8
	for running() {
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
	sync.wakeup(&all_done)
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
is the sharper of the two choices. A walk usually never reaches a member
appended to the end.

A member at the front is the one `cross_mounts` substitutes for `/mnt` itself.
It is therefore the chan every walker holds at the moment this thread unbinds
it. That is the window a reference is for.

`#t` answers `/mnt/a` throughout regardless. `#u` does not have an `a`, so the
union search falls through to the member behind it. What moves is which tree a
walker is standing on, not what it finds.
*/
@(private = "file")
churn_worker :: proc "contextless" (arg: rawptr) {
	context = worker_context()
	_ = arg

	for running() {
		note(vfs.mount_device(vfs.boot_namespace, "#u", "/mnt", .Before), &churn_errors)
		note(vfs.unmount_path(vfs.boot_namespace, "#u", "/mnt"), &churn_errors)
		bump(&churn_done)
	}
	bump(&finished)
	sync.wakeup(&all_done)
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

// The condition the boot thread waits on. Run by `sync.sleep_for` with
// interrupts masked, which is the whole of why it may not do anything but
// read.
@(private = "file")
all_workers_done :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&finished) >= WORKERS
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

Heap stats bracket it, as they do the single-threaded self-test, and for a
sharper reason here. The failure mode of a lost reference count is not a wrong
answer. It is a chan freed early, or never. Neither shows up as a failed check.
Both show up as a heap that does not come back to where it started.
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
		// A worker is still in there. Everything from here down would pull the floor
		// out from under it. Leave the servers standing, and report what is known.
		report_vfs_threads(&r)
		return
	}

	verify_dissolved_union(&r)

	// Leave the namespace as it was found. The heap bracket below then means what
	// it says, and nothing after this boots into a rearranged `/mnt`.
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
run_workers starts the five threads and waits for them.

There is no join, and this is not one. A thread that never finishes is a
scheduler question. The only thing this self-test owes the boot is to say so,
rather than hang.
*/
@(private = "file")
run_workers :: proc(r: ^Vfs_Threads) #no_bounds_check {
	intrinsics.volatile_store(&finished, 0)
	intrinsics.volatile_store(&stop, false)

	started := sched.ticks()
	intrinsics.volatile_store(&deadline, started + RUN_TICKS)

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

	/*
	The workers stop themselves at `deadline`. This waits for the last of them.

	Off every run queue for the whole run. The five threads under test therefore
	have the core entirely to themselves, and nothing here has an opinion about
	priority. See PATIENCE. Each worker wakes this rendezvous as it leaves. The
	first four wakes find the condition still false, and `sleep_for` parks again.
	The fifth is the one that returns.
	*/
	_ = sync.sleep_for(&all_done, all_workers_done, nil, RUN_TICKS + PATIENCE)
	r.ticks = sched.ticks() - started

	// Nothing below here is safe to run while a worker is still inside the
	// namespace, and neither is the teardown in the caller. A server's fid table
	// destroyed under a live client is a fault, not a failed check. So this is
	// the one failure that stops the self-test rather than counting.
	if !tcheck(r, intrinsics.volatile_load(&finished) == WORKERS, "every worker finished") {
		return
	}

	/*
	Collect the corpses before anyone measures the heap.

	A dead thread still stands on its stack when it leaves the CPU, so the free
	waits for something else to be running. In practice that means the next
	`spawn`, and nothing spawns after this. Five threads and five stacks would
	otherwise read in the bracket below as ten leaked objects. That is true, and
	has nothing to do with the namespace.
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

	// And none of them got a share that only counts as one arithmetically. A
	// scheduler that ignores priority on a wake leaves exactly one thread
	// behind, and MIN_ROUNDS alone catches that only when it is severe.
	busiest := max(a_done, b_done, reads, rebinds)
	quietest := min(a_done, b_done, reads, rebinds)
	tcheck(r, quietest * MAX_SPREAD >= busiest, "and the quietest of them still got a share")

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
`readdir` has to find the other members through it. `unmount` used to free that
object while the chan still pointed at it. One thread that holds a directory
open across an `unmount` reaches that use-after-free, and that is an ordinary
thing to do.

The shape of this check is the interesting part, and it took two attempts. The
obvious version dissolves the union, then reads through the held chan. It
passes whether or not the fix is there, because a freed `Mount_Point` still
reads as one.

The allocator writes its free list link over the first field, and leaves
`members` exactly as `unmount` left it. That is nil, and nil is what a
correctly dissolved mount point looks like. A use-after-free that reads
plausible data is the whole reason use-after-free is hard to find.

So something has to *reuse* the block before the check reads it. Dissolve
`/mnt`, then immediately build a different union at the same name. That puts a
fresh `Mount_Point` at the head of the same size class's free list, which is
the block just freed, if anything freed it.

The held chan then points at a live union it was never part of, and lists a
tree it is not standing on.

With the reference in place, the new union is a different object. The chan's
own mount point is still dissolved and still empty, and it lists the one tree
it actually has a fid on.
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

	// The check the behavioural ones below cannot make. A mount point freed one
	// reference early goes on reading as a valid empty one, for as long as
	// nothing claims the block. The listing therefore comes out right either way,
	// and the bug survives the test. The count is the thing that actually
	// differs.
	tcheck(r, vfs.mount_point_refs(mp) == 1, "leaving the chan's reference and no other")
	tcheck(r, vfs.member_count(mp) == 0, "and no members")

	/*
	A second union at the same name, built out of the same size class a free of
	the first would have used. And deliberately the other way round.

	`#u` goes first this time. First-is-`#t` again would make the two unions
	indistinguishable from this chan's point of view. Member zero would be the
	tree it already stands on either way.

	The listing would then come out right, whether or not it read the wrong mount
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

	// What it lists is `#t`'s root, which is what it stood on. That is `a` and
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
		libodin.put_str(&sink, " ms, nothing serialised, heap balanced")
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
