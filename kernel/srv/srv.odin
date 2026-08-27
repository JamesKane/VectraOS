/*
`/srv` -- services published by name, and the first directory that changes.

`#s` bound at `/srv`. Everything in it is a running service that something
posted at run time, and anything that can name it can mount it. That is the
step between `a server the kernel was built with` and `a server somebody
started`.

Vectra already had one way to reach a service: `#name`, the device table in
`kernel/vfs/vfs.odin`. `/srv` is not a second copy of it, and the four
differences are the whole reason this exists.

    #name                          /srv
    fixed at boot, sixteen slots   posted and removed while the machine runs
    outside every namespace        inside one, so a bind or a fork can hide it
    invisible                      a directory somebody can list
    permanent                      a name that goes when nothing wants it

The second is the one that matters most. `#name` deliberately bypasses the
namespace, because a process with an empty mount table needs some way to name a
console. That makes access to it a privilege. `/srv` is an ordinary part of a
namespace. Publishing there is a deliberate act, and a namespace that never
bound `#s` cannot see any of it.

## What a posted service is

A `^vfs.Server`, which is a handler plus the session a client reaches it
through. That type already hides which transport is underneath -- the caller's
own stack, or a queue with worker threads on it. So posting one is the same
operation whether the service is a table in kernel memory or four threads
answering messages.

**The `Server` belongs to whoever posted it, and must outlive every mount of
it.** That is the same rule `vfs.register_device` already carries, for the same
reason: a `Chan` holds a `^Server` directly. Removing a name does not stop a
service, and an existing mount goes on working. Plan 9 behaves identically, and
what makes it safe there is a reference count on the channel. Vectra will need
one the day a `Server` can be freed, and that day arrives with processes.

The name is copied rather than borrowed. A kernel caller hands over a string in
`.rodata` and is right. The first caller that is not the kernel would hand over
a message buffer and be wrong. A copy costs 32 bytes a slot and
removes the question.

## What is deliberately not here

**Posting is not a file operation yet.** Plan 9 posts by creating a file in
`/srv` and writing a file descriptor number into it. The kernel takes the
channel from that descriptor. Vectra has no file descriptors, so `Tlcreate` here
answers EPERM and `post` is a kernel call.

That is the one piece of `/srv` that genuinely waits for userland, and it is
worth being precise about which piece. Naming, listing, removal, lookup and
mounting are all built. What is missing is the step that turns a client's open
connection into a `^vfs.Server`, and nothing below userland can supply it.

**Removal is a file operation.** `Tremove` on `/srv/foo` takes the name away,
because that step needs no descriptor. `srv.remove` is the same operation from
inside the kernel.
*/
package srv

import "kernel:sync"
import "kernel:vfs"
import "vsys:vectra9"

/*
How many services may be posted at once.

Fixed, like every other table in this kernel that a client can grow. A registry
that allocates on demand is a registry an unprivileged caller exhausts the
machine's memory through. A full table answers ENOSPC, which is the truth.
*/
MAX_SERVICES :: 32

// The longest service name. Short on purpose: a name in `/srv` is a name a
// person types, and `Rstatfs` reports 255 for the tree rather than for this.
MAX_NAME :: 32

// Fids this server hands out at once. A client holds one per open entry, and a
// mount holds none -- it attaches to the posted service instead.
SRV_MAX_FIDS :: 64

// Linux st_mode type bits, as Rgetattr carries them.
@(private = "file")
S_IFDIR :: u32(0o040000)
@(private = "file")
S_IFREG :: u32(0o100000)

/*
One posted service.

`id` is the identity, and the slot index is not. A slot is reused the moment a
name is removed. A fid that named the old occupant would name the new one,
which is a capability a client was never given. A fid binds the `id` and the
lookup is a scan for a live entry carrying it. An entry that went answers
ENOENT rather than somebody else's service.

`id` is monotonic and therefore finite: two billion posts and it stops. That is
a real limit with an obvious fix, and it is the same limit `vfs.alloc_fid`
carries and names. A free list of ids is what retires both.

**A slot is live exactly when its id is not zero**, and there is no second field
saying so. There was one, and a control found it. `remove` zeroes the whole
`Service`, so every test of a `used` flag was already a test of the id. Two
fields that must agree are two fields that can disagree. The one that can be
wrong is the one that is not the identity.
*/
@(private)
Service :: struct {
	name:   [MAX_NAME]u8,
	len:    int,
	server: ^vfs.Server,
	id:     i32,
}

// live reports whether a slot holds a service. `ROOT_ID` is zero and no service
// ever carries it, so a zeroed slot is a free one and says so.
@(private = "file")
live :: proc "contextless" (s: ^Service) -> bool {
	return s.id != ROOT_ID
}

@(private)
Srv_Tree :: struct {
	table:   [MAX_SERVICES]Service,
	count:   int,
	next_id: i32,

	// Client fids, bound to an `id` rather than to a slot. Zero is the root.
	fids:    vfs.Fid_Table,

	// Guards everything above. Never held across a message: `mount` reads the
	// `^vfs.Server` out under it and lets go before it attaches.
	lock:    sync.Spinlock,

	server:  vfs.Server,
	posts:   u64,
	removes: u64,
}

@(private)
srv_tree: Srv_Tree

/*
init brings `#s` up and binds it at `/srv`.

Synchronous, and that is a decision rather than an oversight. This server is a
table in kernel memory and every message it answers is a lookup. Nothing in it
waits. There is nothing for a worker thread to do while a caller blocks, and
nothing for a `Tflush` to abandon. `kernel/devfs` takes workers
because a console read has to wait for a key. See `docs/TRANSPORT.md`.

Starts empty. Plan 9's `/srv` is empty until something posts. The kernel is not
the thing that decides which of its own services deserve a public name.
*/
init :: proc(ns: ^vfs.Namespace) -> vfs.Errno {
	t := &srv_tree

	if !vfs.fidtab_init(&t.fids, SRV_MAX_FIDS) {
		return vectra9.ENOMEM
	}
	t.next_id = 1

	if err := vfs.server_init(&t.server, "s", srv_handler, t); err != .None {
		vfs.fidtab_destroy(&t.fids)
		return vectra9.EPROTO
	}
	if !vfs.register_device(&t.server) {
		vfs.fidtab_destroy(&t.fids)
		return vectra9.EEXIST
	}
	return vfs.mount_device(ns, "#s", "/srv")
}

// count reports how many services are posted. For the boot line and the
// self-test, and both only read.
count :: proc "contextless" () -> int {
	t := &srv_tree
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)
	return t.count
}

// stats reports what this server did. Posts and removes rather than a live
// count. A table that ends where it started may still go wrong in the middle.
stats :: proc "contextless" () -> (posts: u64, removes: u64) {
	t := &srv_tree
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)
	return t.posts, t.removes
}

// -- Posting -----------------------------------------------------------------

/*
valid_name reports whether a name may be a service.

One path element and nothing else. A name with a slash in it would be a name no
walk could reach. `.` or `..` would be a name a walk reaches by accident.
Both are refused where the name is taken rather than where the confusion
surfaces.
*/
@(private = "file")
valid_name :: proc "contextless" (name: string) -> bool {
	if len(name) == 0 || len(name) > MAX_NAME {
		return false
	}
	if name == "." || name == ".." {
		return false
	}
	for i in 0 ..< len(name) {
		if name[i] == '/' || name[i] < 0x20 {
			return false
		}
	}
	return true
}

@(private = "file")
name_of :: proc "contextless" (s: ^Service) -> string {
	return string(s.name[:s.len])
}

/*
post publishes a service under a name.

    srv.post("cons", &console_server)

Fails with EEXIST on a name already posted, rather than shadowing it. Two
services that both want `/srv/cons` is a bug in whoever started them. A silent
win for the second would make it a bug that reproduces only sometimes.
`vfs.register_device` refuses a duplicate for the same reason.

The `^vfs.Server` is borrowed and the name is copied. See the file comment for
which of those is a rule and which is a convenience.
*/
post :: proc "contextless" (name: string, server: ^vfs.Server) -> vfs.Errno #no_bounds_check {
	if server == nil || !valid_name(name) {
		return vectra9.EINVAL
	}

	t := &srv_tree
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)

	free := -1
	for i in 0 ..< MAX_SERVICES {
		if !live(&t.table[i]) {
			if free < 0 {
				free = i
			}
			continue
		}
		if name_of(&t.table[i]) == name {
			return vectra9.EEXIST
		}
	}
	if free < 0 {
		return vectra9.ENOSPC
	}
	if t.next_id <= 0 {
		// The counter ran out rather than wrapped. A wrap would hand a new
		// service the identity of an old one, which is exactly the aliasing the
		// id exists to prevent.
		return vectra9.ENOSPC
	}

	s := &t.table[free]
	s^ = Service {
		server = server,
		id     = t.next_id,
		len    = len(name),
	}
	for i in 0 ..< len(name) {
		s.name[i] = name[i]
	}

	t.next_id += 1
	t.count += 1
	t.posts += 1
	return vfs.OK
}

/*
remove takes a name away, and does not stop the service.

That is Plan 9's behaviour and it is the useful one. A mount made before the
removal goes on working, because the `Chan` behind it holds the `^vfs.Server`
rather than the name. What ends is the ability to make a *new* mount by that
name.
*/
remove :: proc "contextless" (name: string) -> vfs.Errno #no_bounds_check {
	t := &srv_tree
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)

	for i in 0 ..< MAX_SERVICES {
		if live(&t.table[i]) && name_of(&t.table[i]) == name {
			t.table[i] = Service{}
			t.count -= 1
			t.removes += 1
			return vfs.OK
		}
	}
	return vectra9.ENOENT
}

// lookup finds a posted service by name. Nil when nothing has that name, which
// a caller must treat as `not posted` rather than as an error worth a code.
lookup :: proc "contextless" (name: string) -> ^vfs.Server #no_bounds_check {
	t := &srv_tree
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)

	for i in 0 ..< MAX_SERVICES {
		if live(&t.table[i]) && name_of(&t.table[i]) == name {
			return t.table[i].server
		}
	}
	return nil
}

// -- Mounting ----------------------------------------------------------------

/*
mount attaches the service named by `path` and binds it at `target`.

    srv.mount(ns, "/srv/cons", "/mnt/cons")

This is Plan 9's `mount(fd, ...)` with the descriptor taken out of it. There,
the client opens `/srv/foo`, gets a channel, and hands the kernel a descriptor
on it. The kernel never looks the name up again -- it uses the channel it was
given.

Here the same two steps happen, and the middle one is a kernel call rather than
a descriptor. `path` is resolved **in the namespace**, so a bind over `/srv`, or
a fork that dropped it, changes what this can reach. Then the qid on the chan
says which entry it landed on, and the entry says which service that is.

Refusing a path that is not one of this server's files is the check that keeps
that honest. Without it, `mount` would be a second way to name a service that
skipped the namespace -- which is the thing `/srv` exists not to be.
*/
mount :: proc(
	ns: ^vfs.Namespace,
	path: string,
	target: string,
	order: vfs.Mount_Order = .Replace,
	flags: vfs.Mount_Flags = {},
) -> vfs.Errno {
	server, err := service_at(ns, path)
	if err != vfs.OK {
		return err
	}

	source: ^vfs.Chan
	source, err = vfs.attach(server)
	if err != vfs.OK {
		return err
	}
	defer vfs.chan_close(source)

	over: ^vfs.Chan
	over, err = vfs.resolve_mount_point(ns, target)
	if err != vfs.OK {
		return err
	}
	defer vfs.chan_close(over)

	return vfs.bind(ns, source, over, order, flags)
}

/*
service_at resolves a path and reports which posted service it names.

EINVAL when the path resolves to something this server does not serve, or to
this server's own root. Neither is a service, and both are a caller that
believes a path is a `/srv` entry when it is not.
*/
@(private = "file")
service_at :: proc(ns: ^vfs.Namespace, path: string) -> (^vfs.Server, vfs.Errno) #no_bounds_check {
	t := &srv_tree

	c, err := vfs.resolve(ns, path)
	if err != vfs.OK {
		return nil, err
	}
	defer vfs.chan_close(c)

	if c.server != &t.server {
		return nil, vectra9.EINVAL
	}
	id := id_of_qid(c.qid)
	if id <= 0 {
		return nil, vectra9.EINVAL
	}

	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)

	i := slot_of(t, id)
	if i < 0 {
		// The name resolved and the entry went between the walk and here.
		// ENOENT is what a client would have got a moment earlier.
		return nil, vectra9.ENOENT
	}
	return t.table[i].server, vfs.OK
}

// -- The tree ----------------------------------------------------------------
//
// Two numbers name a file here and the mapping between them is worth stating
// once. A qid path is an id plus one, so that zero names nothing and the root
// gets a path of its own. A fid is bound to the id, and the root's id is zero.

@(private = "file")
ROOT_ID :: i32(0)

@(private = "file")
qid_of_id :: proc "contextless" (id: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if id == ROOT_ID {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(id) + 1}
}

@(private = "file")
id_of_qid :: proc "contextless" (q: vectra9.Qid) -> i32 {
	if q.path == 0 {
		return -1
	}
	return i32(q.path - 1)
}

// slot_of finds the live entry carrying an id. Caller holds `lock`.
@(private = "file")
slot_of :: proc "contextless" (t: ^Srv_Tree, id: i32) -> int #no_bounds_check {
	for i in 0 ..< MAX_SERVICES {
		if live(&t.table[i]) && t.table[i].id == id {
			return i
		}
	}
	return -1
}

// slot_named finds the live entry with a name. Caller holds `lock`.
@(private = "file")
slot_named :: proc "contextless" (t: ^Srv_Tree, name: string) -> int #no_bounds_check {
	for i in 0 ..< MAX_SERVICES {
		if live(&t.table[i]) && name_of(&t.table[i]) == name {
			return i
		}
	}
	return -1
}

// -- The handler -------------------------------------------------------------

/*
srv_creates reports whether a message would add a name to this tree.

EPERM rather than EOPNOTSUPP, and the difference matters here more than it did
in `kernel/devfs`. A client that tries to create in `/srv` is doing the exact
thing Plan 9 does to post a service. The answer is `not yet, and not like
that`, which is a permission rather than an absence. See the file comment.
*/
@(private = "file")
srv_creates :: proc "contextless" (k: vectra9.Kind) -> bool {
	#partial switch k {
	case .Tlcreate, .Tmkdir, .Tmknod, .Tsymlink, .Tlink, .Trename, .Trenameat:
		return true
	}
	return false
}

@(private = "file")
srv_handler :: proc "contextless" (
	server: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = s
	_ = tag
	t := cast(^Srv_Tree)server
	if t == nil {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}

	if srv_creates(vectra9.kind(request^)) {
		reply^ = vectra9.error_reply(vectra9.EPERM)
		return
	}

	// Everything unhandled is a genuine "not implemented". Set it first, so
	// each case below is one assignment rather than one and a fall-through
	// somebody forgets.
	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)

	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)

	#partial switch m in request^ {
	case vectra9.Tversion:
		if m.version != vectra9.VERSION {
			reply^ = vectra9.Rversion{msize = m.msize, version = "unknown"}
			return
		}
		reply^ = vectra9.Rversion {
			msize   = min(m.msize, vectra9.MSIZE_DEFAULT),
			version = vectra9.VERSION,
		}

	case vectra9.Tattach:
		if !vfs.fidtab_bind(&t.fids, m.fid, ROOT_ID) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
		reply^ = vectra9.Rattach{qid = qid_of_id(ROOT_ID)}

	case vectra9.Twalk:
		srv_walk(t, m, reply)

	case vectra9.Tlopen:
		id := vfs.fidtab_node(&t.fids, m.fid)
		if id < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		if id == ROOT_ID && m.flags & 0o3 != vfs.O_RDONLY {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		if id != ROOT_ID && slot_of(t, id) < 0 {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		reply^ = vectra9.Rlopen{qid = qid_of_id(id), iounit = 0}

	case vectra9.Tread:
		srv_read(t, m, reply, buf)

	case vectra9.Treaddir:
		srv_readdir(t, m, reply, buf)

	case vectra9.Tremove:
		/*
		The one mutation this tree accepts, and the reason it can.

		Removing a name needs nothing a client cannot express. Posting needs a
		connection, which needs a file descriptor, which needs userland. So half
		of Plan 9's `/srv` is a file operation here and half is a kernel call.

		9P clunks the fid whether or not the remove succeeds, so the release
		happens on both paths below.
		*/
		id := vfs.fidtab_node(&t.fids, m.fid)
		_ = vfs.fidtab_release(&t.fids, m.fid)
		if id < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		if id == ROOT_ID {
			// The root of a served tree is not a file in it.
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		i := slot_of(t, id)
		if i < 0 {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		t.table[i] = Service{}
		t.count -= 1
		t.removes += 1
		reply^ = vectra9.Rremove{}

	case vectra9.Tgetattr:
		id := vfs.fidtab_node(&t.fids, m.fid)
		if id < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		dir := id == ROOT_ID
		if !dir && slot_of(t, id) < 0 {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		attr := vectra9.Rgetattr {
			valid   = m.request_mask & vfs.GETATTR_BASIC,
			qid     = qid_of_id(id),
			// 0o600 on an entry, because a posted service is a capability and
			// not a public one. A permission model that means it arrives with
			// the processes that would be checked against it.
			mode    = dir ? S_IFDIR | 0o555 : S_IFREG | 0o600,
			nlink   = dir ? 2 : 1,
			blksize = 512,
		}
		if !dir {
			attr.size = u64(report_len(t, id))
		}
		attr.blocks = (attr.size + 511) / 512
		reply^ = attr

	case vectra9.Tstatfs:
		if vfs.fidtab_node(&t.fids, m.fid) < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		reply^ = vectra9.Rstatfs {
			type    = 0x0139_9249, // V9FS_MAGIC, as Linux reports for 9P
			bsize   = 512,
			files   = u64(t.count),
			ffree   = u64(MAX_SERVICES - t.count),
			namelen = MAX_NAME,
		}

	case vectra9.Tclunk:
		_ = vfs.fidtab_release(&t.fids, m.fid)
		reply^ = vectra9.Rclunk{}

	case vectra9.Tflush:
		// Nothing is ever pending against a synchronous transport, so the
		// request being flushed has already been answered. Rflush regardless:
		// Tflush may never be answered with an error.
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

/*
srv_walk resolves names against a directory with one level in it.

Every entry is a child of the root, so a walk of more than one name can only
succeed on `.` and `..`. The same two rules as every other server here. A
partial walk binds nothing, and a failure at element zero is an error while a
failure later is a short Rwalk.
*/
@(private = "file")
srv_walk :: proc "contextless" (t: ^Srv_Tree, m: vectra9.Twalk, reply: ^vectra9.Msg) #no_bounds_check {
	id := vfs.fidtab_node(&t.fids, m.fid)
	if id < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}

	answer: vectra9.Rwalk
	cur := id
	for i in 0 ..< m.count {
		next := step(t, cur, m.names[i])
		if next < 0 {
			if i == 0 {
				reply^ = vectra9.error_reply(vectra9.ENOENT)
				return
			}
			break
		}
		cur = next
		answer.qids[answer.count] = qid_of_id(cur)
		answer.count += 1
	}

	if answer.count == m.count {
		if !vfs.fidtab_bind(&t.fids, m.newfid, cur) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
	}
	reply^ = answer
}

// step walks one name. Returns the id, or -1 for `no such name`. An id of zero
// is the root rather than a failure, which is why the failure is -1 and not it.
@(private = "file")
step :: proc "contextless" (t: ^Srv_Tree, from: i32, name: string) -> i32 #no_bounds_check {
	switch name {
	case ".":
		return from
	case "..":
		// Everything is one level down, and the root's parent is the root. A
		// server has no name for anything above its own tree, and saying so is
		// what lets `kernel/vfs` climb out through `mounted_over` instead.
		return ROOT_ID
	}
	if from != ROOT_ID {
		// An entry is a file. Nothing walks out of one.
		return -1
	}
	i := slot_named(t, name)
	if i < 0 {
		return -1
	}
	return t.table[i].id
}

/*
What a read of `/srv/foo` says.

Plan 9 answers a read of a posted service with the channel itself, through the
open rather than through the bytes. Vectra has no descriptor to hand over, so a
read reports identity instead:

    c workers

The `#name` the service is registered under, and whether it has worker threads.
Both are things a person at a shell would want from `cat /srv/foo`, and neither
is something a client could work out from the namespace.

An error would have been the other option, and it would have been worse. A file
that cannot be read is a file with nothing to say about itself.
*/
@(private = "file")
report :: proc "contextless" (t: ^Srv_Tree, id: i32, out: []u8) -> int #no_bounds_check {
	i := slot_of(t, id)
	if i < 0 {
		return 0
	}
	sv := t.table[i].server

	n := 0
	put :: proc "contextless" (out: []u8, n: int, text: string) -> int #no_bounds_check {
		n := n
		for j in 0 ..< len(text) {
			if n >= len(out) {
				return n
			}
			out[n] = text[j]
			n += 1
		}
		return n
	}

	n = put(out, n, sv.name)
	n = put(out, n, vfs.server_interruptible(sv) ? " workers\n" : " direct\n")
	return n
}

// report_len is what `report` would write, for the size in an Rgetattr. Built
// into a scratch line rather than counted a second way, because two procedures
// that must agree about a length eventually do not.
@(private = "file")
report_len :: proc "contextless" (t: ^Srv_Tree, id: i32) -> int {
	line: [MAX_NAME + 16]u8
	return report(t, id, line[:])
}

@(private = "file")
srv_read :: proc "contextless" (
	t: ^Srv_Tree,
	m: vectra9.Tread,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	id := vfs.fidtab_node(&t.fids, m.fid)
	if id < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if id == ROOT_ID {
		// 9P2000.L reads a directory with Treaddir. Tread on one is the client
		// using the wrong message.
		reply^ = vectra9.error_reply(vectra9.EISDIR)
		return
	}
	if slot_of(t, id) < 0 {
		reply^ = vectra9.error_reply(vectra9.ENOENT)
		return
	}

	line: [MAX_NAME + 16]u8
	n := report(t, id, line[:])
	if m.offset >= u64(n) {
		reply^ = vectra9.Rread{data = nil}
		return
	}

	start := int(m.offset)
	end := min(n, start + min(len(buf), int(m.count)))
	copy(buf[:end - start], line[start:end])
	reply^ = vectra9.Rread{data = buf[:end - start]}
}

/*
srv_readdir lists what is posted, and its cookie survives a change.

**The cookie is the entry's id, not its position.** Every other directory in
this tree is a fixed table where an ordinal names the same file every time.
This one is not. A name posted or removed between two Treaddir calls moves
every position after it. An ordinal cookie would then skip an entry or repeat
one, and the client would never know which.

An id is monotonic and never reused, so `resume after this id` means the same
thing however the table moved underneath. A removed entry is simply not found
and the listing goes on to the next id.

That is the treatment `docs/NAMESPACE.md` says a union listing could have if it
ever mattered. Here it matters, so here it is.

Finding the next id is a scan of the table per entry emitted, which is
quadratic in a table of thirty-two. A directory of any real size wants its
entries in a sorted list. This one does not.
*/
@(private = "file")
srv_readdir :: proc "contextless" (
	t: ^Srv_Tree,
	m: vectra9.Treaddir,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	id := vfs.fidtab_node(&t.fids, m.fid)
	if id < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if id != ROOT_ID {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}

	out := buf
	room := min(len(out), int(m.count))
	c := vectra9.cursor_from(out[:room])

	after := i32(m.offset)
	for {
		i := next_after(t, after)
		if i < 0 {
			break
		}
		e := &t.table[i]
		if vectra9.remaining(&c) < vectra9.dirent_size(name_of(e)) {
			break
		}
		vectra9.put_dirent(
			&c,
			vectra9.Dirent {
				qid = qid_of_id(e.id),
				offset = u64(e.id),
				type = vectra9.DT_REG,
				name = name_of(e),
			},
		)
		after = e.id
	}

	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}

// next_after is the live entry with the smallest id greater than `after`, or -1
// when there is none. Caller holds `lock`.
@(private = "file")
next_after :: proc "contextless" (t: ^Srv_Tree, after: i32) -> int #no_bounds_check {
	best := -1
	for i in 0 ..< MAX_SERVICES {
		if !live(&t.table[i]) || t.table[i].id <= after {
			continue
		}
		if best < 0 || t.table[i].id < t.table[best].id {
			best = i
		}
	}
	return best
}
