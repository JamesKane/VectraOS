/*
The namespace over a transport that can leave a request pending.

`kernel/vfs` spoke `vectra9.In_Process` from the day it existed. The handler ran
on the caller's own stack, and one request was ever outstanding. A session lock
held across the whole exchange is what made a borrowed reply safe. That
arrangement worked and it had one thing it could not do. A read had no way to
give up.

The payload buffer removed the reason to keep it. A request slot owns its
storage now, so a reply borrows the request rather than the server. The session
no longer has to be exclusive for a reply to be readable. This is the namespace
on the other side of that.

## What the checks are about

    the fid space survives the move    a chan taken before `server_start`
                                       still names a file after it
    the same paths, several threads    four readers through one namespace, no
                                       lock between them
    a read gives up from a path        `chan_read_for` returns EINTR against a
                                       server that will not answer, and the
                                       flush is what makes the fid safe to
                                       reuse
    and moves back                     `server_stop` returns the server to its
                                       own stack, and the same chan still reads

**Nothing in `kernel/vfs` chooses a transport.** The two servers here are
ordinary `vfs.static_handler` trees, unmodified. What tells them apart is that
one has threads. That is the claim `docs/VECTRA9.md` opens with, checked at the
layer that would notice if it were false.

The namespace is private to this test rather than the boot one. A rearranged
`/mnt` under the kernel's own namespace is a poor thing to leave behind, and a
namespace of its own costs one `ns_new`.
*/
package kernel

import "base:intrinsics"
import "base:runtime"

import "kernel:mem"
import "kernel:mnt"
import "kernel:sched"
import "kernel:sync"
import "kernel:vfs"
import "vsys:libodin"
import "vsys:vectra9"

@(private = "file")
MNT_WORKERS :: 4

@(private = "file")
MNT_READERS :: 4

// Rounds each reader does. Enough that the four genuinely overlap, short
// enough that the whole self-test is a fraction of a second.
@(private = "file")
ROUNDS :: 40

// The deadline a read gives up after. Long enough that the request is really
// in the server, short enough to wait for.
@(private = "file")
GIVE_UP :: 10

@(private = "file")
MNT_PATIENCE :: 400

// -- The tree the readers share ------------------------------------------------

/*
Four files, equal length, each filled with its own first letter.

Equal length is the point. A reply that another thread's overwrites is then
exactly the same size, so no length check finds it. Only reading the bytes
does.
*/
@(private = "file")
FILE_BYTES :: 8

@(private = "file")
MTREE_NODES := [?]vfs.Static_Node {
	{name = "", parent = -1, dir = true},
	{name = "mnt", parent = 0, dir = true},
	{name = "alpha", parent = 0, data = "aaaaaaaa"},
	{name = "bravo", parent = 0, data = "bbbbbbbb"},
	{name = "charlie", parent = 0, data = "cccccccc"},
	{name = "delta", parent = 0, data = "dddddddd"},
}

// The names a reader may resolve, and the letter each file is full of. Index i
// belongs to reader i.
@(private = "file")
PATHS := [MNT_READERS]string{"/alpha", "/bravo", "/charlie", "/delta"}

@(private = "file")
LETTERS := [MNT_READERS]u8{'a', 'b', 'c', 'd'}

// Every name a listing of the root may return. A payload one thread half
// overwrote decodes into names that are not here.
@(private = "file")
ROOT_ENTRIES :: len(MTREE_NODES) - 1

@(private = "file")
mtree: vfs.Static_Tree
@(private = "file")
mserver: vfs.Server
@(private = "file")
mns: ^vfs.Namespace

// -- A server that will not answer a read --------------------------------------

/*
The blocking server, and the only part of this test that is not an ordinary
tree.

Everything but `Tread` goes straight to `vfs.static_handler`, so attach, walk
and open behave exactly as they do anywhere else. A real path therefore reaches
a real file. `Tread` stops, which is what a device waiting on hardware does and
what no static tree can be made to do.

`open` releases it. The abort hook sets `flushed`, which is what lets the
handler give up rather than make the flush wait. Both cases are legal 9P and
`kernel/verify_flush.odin` covers the other one.
*/
@(private = "file")
Slow :: struct {
	tree:    vfs.Static_Tree,
	gate:    sync.Rendez,
	open:    bool,
	blocked: int,
	aborts:  int,
	flushed: [mnt.MAX_REQUESTS]bool,
	waits:   [mnt.MAX_REQUESTS]Slow_Tag,
}

// One per tag, so a wait condition can name the server and the request without
// a closure.
@(private = "file")
Slow_Tag :: struct {
	sv:  ^Slow,
	tag: int,
}

@(private = "file")
SLOW_NODES := [?]vfs.Static_Node {
	{name = "", parent = -1, dir = true},
	{name = "slow", parent = 0, data = "patience"},
}

@(private = "file")
slow: Slow
@(private = "file")
sserver: vfs.Server

@(private = "file")
slow_ready :: proc "contextless" (arg: rawptr) -> bool #no_bounds_check {
	w := cast(^Slow_Tag)arg
	if intrinsics.volatile_load(&w.sv.open) {
		return true
	}
	return intrinsics.volatile_load(&w.sv.flushed[w.tag])
}

@(private = "file")
slow_abort :: proc "contextless" (server: rawptr, tag: vectra9.Tag) #no_bounds_check {
	sv := cast(^Slow)server
	if int(tag) < mnt.MAX_REQUESTS {
		intrinsics.volatile_store(&sv.flushed[int(tag)], true)
	}
	mnt_bump(&sv.aborts)
	sync.wakeup_all(&sv.gate)
}

@(private = "file")
slow_handler :: proc "contextless" (
	server: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	sv := cast(^Slow)server

	if _, is_read := request^.(vectra9.Tread); is_read {
		if int(tag) >= mnt.MAX_REQUESTS {
			reply^ = vectra9.error_reply(vectra9.EIO)
			return
		}
		w := &sv.waits[int(tag)]
		w.sv = sv
		w.tag = int(tag)

		mnt_bump(&sv.blocked)
		sync.sleep(&sv.gate, slow_ready, w)
		mnt_unbump(&sv.blocked)

		if !intrinsics.volatile_load(&sv.open) {
			// Flushed, and this server is one that acts on it. The reply is
			// written and discarded: the client stopped looking the moment its
			// deadline passed. What it waits for is the Rflush behind it.
			reply^ = vectra9.error_reply(vectra9.EINTR)
			return
		}
	}

	// Everything else, and a read that was let through, is an ordinary static
	// tree answering an ordinary message.
	vfs.static_handler(&sv.tree, s, tag, request, reply, buf)
}

@(private = "file")
mnt_bump :: proc "contextless" (p: ^int) {
	intrinsics.volatile_store(p, intrinsics.volatile_load(p) + 1)
}

@(private = "file")
mnt_unbump :: proc "contextless" (p: ^int) {
	intrinsics.volatile_store(p, intrinsics.volatile_load(p) - 1)
}

// -- The readers ----------------------------------------------------------------

@(private = "file")
Reader_Result :: struct {
	reads:     int,
	listings:  int,
	wrong:     int, // Bytes that belonged to another reader's file
	errs:      int,
	returned:  bool,
}

@(private = "file")
readers: [MNT_READERS]Reader_Result

@(private = "file")
reader_done: sync.Rendez

@(private = "file")
reader_returns: int

@(private = "file")
all_read :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&reader_returns) >= MNT_READERS
}

// What the heap gave out and did not take back. The bracket around this whole
// self-test, which is what makes `leaked` mean anything.
@(private = "file")
live_blocks :: proc "contextless" (s: mem.Heap_Stats) -> int {
	live := s.large_blocks
	for i in 0 ..< len(s.class_total) {
		live += s.class_total[i] - s.class_free[i]
	}
	return live
}

@(private = "file")
mnt_context :: proc "contextless" () -> runtime.Context {
	ctx := runtime.default_context()
	ctx.allocator = mem.allocator()
	return ctx
}

/*
One reader: resolve, open, read, list, close, and check every byte.

Each round walks the path again rather than holds a chan open. That is what
puts real Twalk traffic on the connection alongside the reads, and it is what
the old session lock would have serialised.
*/
@(private = "file")
reader :: proc "contextless" (arg: rawptr) #no_bounds_check {
	context = mnt_context()

	i := int(uintptr(arg))
	rd := &readers[i]
	want := LETTERS[i]

	data: [FILE_BYTES]u8
	list: [512]u8

	for _ in 0 ..< ROUNDS {
		c, err := vfs.resolve(mns, PATHS[i])
		if err != vfs.OK {
			rd.errs += 1
			continue
		}
		if e := vfs.chan_open(c, vfs.O_RDONLY); e != vfs.OK {
			rd.errs += 1
			vfs.chan_close(c)
			continue
		}

		n, e := vfs.chan_read(c, 0, data[:])
		vfs.chan_close(c)
		if e != vfs.OK || n != FILE_BYTES {
			rd.errs += 1
			continue
		}
		for b in data[:n] {
			if b != want {
				rd.wrong += 1
			}
		}
		rd.reads += 1

		// And a listing of the root, which is the reply that used to come out
		// of one buffer the whole server shared.
		root, rerr := vfs.resolve(mns, "/")
		if rerr != vfs.OK {
			rd.errs += 1
			continue
		}
		if le := vfs.chan_open(root, vfs.O_RDONLY | vfs.O_DIRECTORY); le != vfs.OK {
			rd.errs += 1
			vfs.chan_close(root)
			continue
		}
		ln, lerr := vfs.readdir(root, 0, list[:])
		vfs.chan_close(root)
		if lerr != vfs.OK {
			rd.errs += 1
			continue
		}
		if count_entries(list[:ln]) == ROOT_ENTRIES {
			rd.listings += 1
		} else {
			rd.wrong += 1
		}
	}

	intrinsics.volatile_store(&rd.returned, true)
	mnt_bump(&reader_returns)
	sync.wakeup_all(&reader_done)
}

// count_entries decodes a listing and counts only names this tree actually
// has. A payload another thread wrote over decodes into names that are not
// here, and those are not counted.
@(private = "file")
count_entries :: proc "contextless" (payload: []u8) -> int #no_bounds_check {
	c := vectra9.cursor_from(payload)
	n := 0
	for {
		e, more := vectra9.next_dirent(&c)
		if !more {
			break
		}
		for i in 1 ..< len(MTREE_NODES) {
			if MTREE_NODES[i].name == e.name {
				n += 1
				break
			}
		}
	}
	if c.err != .None {
		return -1
	}
	return n
}

// -- The self-test ---------------------------------------------------------------

@(private = "file")
Mnt_Result :: struct {
	using tally:   libodin.Tally,
	reads:         int,
	listings:      int,
	msize:         u32,
	gave_up:       u64, // Ticks a read with a deadline actually took
	leaked:        int,
}

@(private = "file")
mcheck :: proc "contextless" (r: ^Mnt_Result, ok: bool, what: string) -> bool {
	return libodin.tally(&r.tally, ok, what)
}


@(private = "file")
one_blocked :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&slow.blocked) >= 1
}

/*
The thread that gives up, and everything it came back with.

On a thread rather than on the boot thread, and that is not tidiness. A read
whose deadline is not honoured never returns. The boot thread would then wait
inside it forever and print nothing at all. That is the failure mode
`docs/TESTING.md` calls worse than a failed check. It says nothing, in the place
hardest to attach a debugger to.

A thread can be watched instead. One that does not come back is a check that
fails and a boot that carries on.
*/
@(private = "file")
Give_Up :: struct {
	c:        ^vfs.Chan,
	err:      vfs.Errno,
	n:        int,
	ticks:    u64,
	returned: bool,
}

@(private = "file")
give_up: Give_Up

@(private = "file")
give_up_done: sync.Rendez

@(private = "file")
give_up_returned :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&give_up.returned)
}

@(private = "file")
give_up_reader :: proc "contextless" (arg: rawptr) {
	context = mnt_context()

	buf: [FILE_BYTES]u8
	started := sched.ticks()
	give_up.n, give_up.err = vfs.chan_read_for(give_up.c, 0, buf[:], GIVE_UP)
	give_up.ticks = sched.ticks() - started

	intrinsics.volatile_store(&give_up.returned, true)
	sync.wakeup_all(&give_up_done)
}

@(private = "file")
none_blocked :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&slow.blocked) == 0
}

verify_vfs_mnt :: proc() #no_bounds_check {
	r: Mnt_Result

	if !mcheck(&r, vfs.static_init(&mtree, "m", MTREE_NODES[:]), "the shared tree came up") {
		report_vfs_mnt(&r)
		return
	}
	defer vfs.static_destroy(&mtree)

	if !mcheck(&r, vfs.static_init(&slow.tree, "w", SLOW_NODES[:]), "the blocking tree came up") {
		report_vfs_mnt(&r)
		return
	}
	defer vfs.static_destroy(&slow.tree)

	mcheck(&r, vfs.server_init(&mserver, "m", vfs.static_handler, &mtree) == .None, "#m Tversion")
	mcheck(&r, vfs.server_init(&sserver, "w", slow_handler, &slow) == .None, "#w Tversion")
	mcheck(&r, vfs.register_device(&mserver), "#m registered")
	mcheck(&r, vfs.register_device(&sserver), "#w registered")

	before := live_blocks(mem.heap_stats())

	// -- A namespace of this test's own --------------------------------------

	mns = vfs.ns_new()
	if !mcheck(&r, mns != nil, "a private namespace") {
		report_vfs_mnt(&r)
		return
	}

	root, root_err := vfs.device_attach("#m")
	if !mcheck(&r, root_err == vfs.OK, "#m attached through the device escape") {
		report_vfs_mnt(&r)
		return
	}
	mcheck(&r, vfs.ns_set_root(mns, root) == vfs.OK, "and became the namespace root")
	vfs.chan_close(root)

	mcheck(
		&r,
		vfs.mount_device(mns, "#w", "/mnt") == vfs.OK,
		"#w bound at /mnt, which is a walk that crosses servers",
	)

	// -- Synchronous first, so the move has a baseline -----------------------

	mcheck(&r, !vfs.server_interruptible(&mserver), "a server on its own stack cannot be interrupted")
	mcheck(&r, read_is(mns, "/alpha", 'a'), "and answers an ordinary read")

	/*
	A chan taken before the move, kept across it, and read after.

	The old session handed out the fid it holds, and the server's fid table still
	binds it. `server_start` rebuilds the session around a new transport. Carrying
	the fid counter over is what stops the next `alloc_fid` from handing out a
	number already in use. A chan that stopped working here would say it did not.
	*/
	kept, kept_err := vfs.resolve(mns, "/bravo")
	mcheck(&r, kept_err == vfs.OK, "a chan taken before the move")

	// -- The move ------------------------------------------------------------

	if !mcheck(
		&r,
		vfs.server_start(&mserver, MNT_WORKERS),
		"the shared server took four workers",
	) {
		report_vfs_mnt(&r)
		return
	}
	mcheck(
		&r,
		vfs.server_start(&sserver, MNT_WORKERS, 0, slow_abort),
		"the blocking server took four workers and an abort hook",
	)

	r.msize = vfs.server_msize(&mserver)
	mcheck(&r, vfs.server_interruptible(&mserver), "a server with workers can be interrupted")
	mcheck(
		&r,
		r.msize == u32(vfs.DEFAULT_PAYLOAD + vectra9.IOHDRSZ),
		"and says so in an msize its slots can actually carry",
	)

	if kept != nil {
		mcheck(&r, vfs.chan_open(kept, vfs.O_RDONLY) == vfs.OK, "still opens after the move")
		got: [FILE_BYTES]u8
		n, e := vfs.chan_read(kept, 0, got[:])
		clean := e == vfs.OK && n == FILE_BYTES
		for b in got[:n] {
			if b != 'b' {
				clean = false
			}
		}
		mcheck(&r, clean, "and still names the file it named before")
		vfs.chan_close(kept)
	}

	// -- Four readers through one namespace ----------------------------------

	run_readers(&r)

	// -- A read that gives up, from a path -----------------------------------

	verify_give_up(&r)

	// -- And back onto its own stack -----------------------------------------

	vfs.server_stop(&sserver)
	vfs.server_stop(&mserver)
	mcheck(&r, !vfs.server_interruptible(&mserver), "a stopped server is on its own stack again")
	mcheck(
		&r,
		vfs.server_msize(&mserver) == vectra9.MSIZE_DEFAULT,
		"with the msize a transport that carries no buffer reports",
	)
	mcheck(&r, read_is(mns, "/charlie", 'c'), "and answers an ordinary read as it always did")

	// -- Leave nothing behind -------------------------------------------------

	mcheck(&r, vfs.unmount_path(mns, "", "/mnt") == vfs.OK, "/mnt unbound again")
	vfs.ns_close(mns)
	mns = nil

	sched.reap()
	r.leaked = live_blocks(mem.heap_stats()) - before
	mcheck(&r, r.leaked == 0, "every chan, mount point and connection was released")

	report_vfs_mnt(&r)
}

/*
read_is resolves a path, reads it, and reports whether every byte was the
letter that file is full of.

The whole path layer in one line. A walk from the namespace root, a mount table
consulted between elements, an open, a read, and a clunk on the way out.
*/
@(private = "file")
read_is :: proc(ns: ^vfs.Namespace, path: string, want: u8) -> bool #no_bounds_check {
	c, err := vfs.resolve(ns, path)
	if err != vfs.OK {
		return false
	}
	defer vfs.chan_close(c)
	if vfs.chan_open(c, vfs.O_RDONLY) != vfs.OK {
		return false
	}

	buf: [FILE_BYTES]u8
	n, e := vfs.chan_read(c, 0, buf[:])
	if e != vfs.OK || n != FILE_BYTES {
		return false
	}
	for b in buf[:n] {
		if b != want {
			return false
		}
	}
	return true
}

@(private = "file")
run_readers :: proc(r: ^Mnt_Result) #no_bounds_check {
	intrinsics.volatile_store(&reader_returns, 0)
	for i in 0 ..< MNT_READERS {
		readers[i] = {}
	}

	spawned := 0
	for i in 0 ..< MNT_READERS {
		if sched.spawn("vfs-mnt-read", reader, rawptr(uintptr(i))) != nil {
			spawned += 1
		}
	}
	if !mcheck(r, spawned == MNT_READERS, "a reader for every path") {
		return
	}
	if !mcheck(r, sync.await(all_read, nil, MNT_PATIENCE), "and every one of them came back") {
		return
	}

	wrong, errs := 0, 0
	for i in 0 ..< MNT_READERS {
		r.reads += readers[i].reads
		r.listings += readers[i].listings
		wrong += readers[i].wrong
		errs += readers[i].errs
	}

	mcheck(r, errs == 0, "no path failed while four threads walked it at once")
	mcheck(r, r.reads == MNT_READERS * ROUNDS, "every read got its bytes")
	mcheck(r, r.listings == MNT_READERS * ROUNDS, "every listing was the whole directory")
	mcheck(r, wrong == 0, "and no thread was handed another thread's payload")
}

/*
verify_give_up is the point of the milestone: a path-level read that a caller
walks away from.

`chan_read_for` sends the read, watches its deadline pass, sends `Tflush`, and
waits for `Rflush`. The wait is the part that matters. Without it the fid is one
the server still believes is in use. A later reply would then land in a buffer
this caller no longer looks at.

The server here acts on the flush, so the give-up is prompt. A server that
refuses to is equally legal and `kernel/verify_flush.odin` is built around one.
*/
@(private = "file")
verify_give_up :: proc(r: ^Mnt_Result) #no_bounds_check {
	intrinsics.volatile_store(&slow.open, false)
	for i in 0 ..< mnt.MAX_REQUESTS {
		intrinsics.volatile_store(&slow.flushed[i], false)
	}
	aborts_before := intrinsics.volatile_load(&slow.aborts)

	c, err := vfs.resolve(mns, "/mnt/slow")
	if !mcheck(r, err == vfs.OK, "a path that crosses into the blocking server") {
		return
	}
	defer vfs.chan_close(c)

	if !mcheck(r, vfs.chan_open(c, vfs.O_RDONLY) == vfs.OK, "and opens, because only a read blocks") {
		return
	}
	mcheck(r, vfs.chan_interruptible(c), "a read on it can be given up on")

	give_up = Give_Up {
		c = c,
	}
	if !mcheck(
		r,
		sched.spawn("vfs-give-up", give_up_reader, nil) != nil,
		"a thread to do the giving up",
	) {
		return
	}

	came_back := sync.await(give_up_returned, nil, MNT_PATIENCE)
	if !mcheck(r, came_back, "a read that outlives its deadline comes back at all") {
		// It did not, so it is still inside the server. Let it finish, or the
		// teardown below pulls the tree out from under a live thread.
		intrinsics.volatile_store(&slow.open, true)
		sync.wakeup_all(&slow.gate)
		_ = sync.await(give_up_returned, nil, MNT_PATIENCE)
		return
	}
	r.gave_up = give_up.ticks

	mcheck(r, give_up.err == vectra9.EINTR, "and reports EINTR")
	mcheck(r, give_up.n == 0, "and hands back no bytes it did not get")
	mcheck(r, r.gave_up >= GIVE_UP, "after waiting the deadline it was given")
	mcheck(
		r,
		intrinsics.volatile_load(&slow.aborts) > aborts_before,
		"and the server was told which request to abandon",
	)
	mcheck(r, sync.await(none_blocked, nil, MNT_PATIENCE), "which left no handler parked behind it")

	// The connection is a connection afterwards. A give-up that poisoned the
	// session would show up here rather than at the next boot.
	intrinsics.volatile_store(&slow.open, true)
	sync.wakeup_all(&slow.gate)

	buf: [FILE_BYTES]u8
	n2, e2 := vfs.chan_read(c, 0, buf[:])
	mcheck(r, e2 == vfs.OK && n2 == FILE_BYTES, "and the same fid reads normally once the server will answer")
}

@(private = "file")
report_vfs_mnt :: proc(r: ^Mnt_Result) {
	sink := begin(&klog)
	libodin.put_str(&sink, "vfs ")
	libodin.put_uint(&sink, u64(r.checks))
	if libodin.passed(r.tally) {
		libodin.put_str(&sink, " transport checks passed -- ")
		libodin.put_uint(&sink, u64(r.reads))
		libodin.put_str(&sink, " reads and ")
		libodin.put_uint(&sink, u64(r.listings))
		libodin.put_str(&sink, " listings across ")
		libodin.put_uint(&sink, u64(MNT_READERS))
		libodin.put_str(&sink, " threads on ")
		libodin.put_uint(&sink, u64(MNT_WORKERS))
		libodin.put_str(&sink, " workers, msize ")
		libodin.put_uint(&sink, u64(r.msize))
		libodin.put_str(&sink, ", a read gave up after ")
		libodin.put_uint(&sink, r.gave_up)
		libodin.put_str(&sink, " ticks")
		emit(&klog, .Ok, &sink)
		return
	}

	libodin.put_str(&sink, " transport checks, ")
	libodin.put_uint(&sink, u64(r.failures))
	libodin.put_str(&sink, " FAILED -- first: ")
	libodin.put_str(&sink, r.first_failure)
	emit(&klog, .Fault, &sink)
}
