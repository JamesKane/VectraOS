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

Two kinds. A kernel post, through `post`, is a `^vfs.Server`: a handler plus
the session a client reaches it through. That type already hides which
transport is underneath, so the service may be a table in kernel memory or
four threads answering messages.

A descriptor post is a **connection**: the chan behind the written number,
referenced so it outlives the descriptor and the process both. Which server
that connection means is decided at mount time. Plan 9's `devsrv` stores the
channel and `devmnt` builds the client from it, and `mount` below does the
same through `pipe.server_for`. A chan on a pipe end becomes a wire with a
program answering. Any other chan means the device behind it.

**A kernel `Server` belongs to whoever posted it, and must outlive every
mount of it.** That is the same rule `vfs.register_device` already carries,
for the same reason: a `Chan` holds a `^Server` directly. Removing a name
does not stop a service, and an existing mount goes on working. A posted
connection keeps that promise with its reference count instead.

The name is copied rather than borrowed. A kernel caller hands over a string in
`.rodata` and is right. The first caller that is not the kernel would hand over
a message buffer and be wrong. A copy costs 32 bytes a slot and
removes the question.

## Posting is a file operation now

Plan 9 posts by creating a file in `/srv` and writing a file descriptor
number into it, and Vectra does the same. `Tlcreate` on the root makes a
**pending** entry: a name with no service behind it, whose read says
`pending` and whose mount answers ENXIO. `Twrite` of a decimal descriptor
completes it. The kernel references the chan behind that descriptor, which
is the step that turns a client's open connection into a posted service.

**Whose descriptor?** The writer's. A descriptor is a number in one process's
table, so the write must be judged against the process that sent it. This
server is synchronous, so the handler runs on the calling thread.
`fd_resolver` -- registered by `kernel/user`, the owner of descriptor tables
-- answers for whoever is current. A caller with no process gets EBADF,
because a number from nowhere names nothing.

That is the confused deputy again, and Plan 9's `devsrv` settles it the same
way: the kernel consults the caller's own table and nobody else's.

**Removal is a file operation too.** `Tremove` on `/srv/foo` takes the name
away, and works on a pending entry exactly as on a completed one. That is
what reclaims a name whose creator died before writing. `srv.remove` is the
same operation from inside the kernel.
*/
package srv

import "base:runtime"

import "kernel:mem"
import "kernel:pipe"
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
	name:     [MAX_NAME]u8,
	len:      int,

	/*
	What the name reaches, and there are two kinds.

	`server` is a service the kernel posted directly, through `post`.
	`endpoint` is a *connection* a process posted, through a descriptor write.
	It is the chan behind that descriptor, referenced so it outlives the
	descriptor and the process both. What server the connection reaches is
	decided at mount time. `mount` asks `pipe.server_for`, which is where a
	posted pipe end becomes a 9P client with a program answering. Plan 9's
	`devsrv` holds a channel for the same reason.

	Both nil is a pending entry: created, named, listed, removable, and not
	yet a service. `Twrite` of a descriptor is what fills `endpoint` in, and
	everything that would follow either pointer refuses first. There is no
	second field saying `pending`, for the reason `used` is gone.
	*/
	server:   ^vfs.Server,
	endpoint: ^vfs.Chan,
	id:       i32,
}

/*
How a descriptor number in a Twrite becomes a connection.

Registered by `kernel/user`, which owns descriptor tables, and consulted for
**the calling thread's own process**. The handler runs on the caller's
thread, because this server is synchronous. Nil until userland exists, and a
resolver that finds no process answers nil too. Both mean a posting nobody
can be charged for, and both are refused.

What comes back is the chan itself rather than the server behind it, because
those are different capabilities. A chan on a pipe end *is* the connection a
process serves, and the server a mount uses is built from it later. The
server behind that chan is only the pipe device. Plan 9's `devsrv` stores
the channel for the same reason.

**The answer carries its own reference**, taken under the table's lock, and
this server keeps it as the posting rather than taking another. A borrow
would not survive a shared descriptor table: a sibling process could close
the number between the resolver's answer and an increment here.

The resolver runs under this server's spinlock. It may look tables up, may
nest a spinlock of its own, and may not send a message or take a lock that
parks. The one registered keeps to that.
*/
Fd_Resolver :: proc "contextless" (fd: int) -> ^vfs.Chan

@(private = "file")
fd_resolver: Fd_Resolver

set_fd_resolver :: proc "contextless" (r: Fd_Resolver) {
	fd_resolver = r
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
post_chan publishes a connection under a name, from the kernel.

The same entry `Tlcreate` and a `Twrite` of a descriptor make from ring 3,
in one step for a caller that holds the chan already. The self-test is that
caller. It posts a pipe end whose far side is a kernel thread. That is the
only way to reach the posted end's teardown paths without a process. The
reference is the posting, taken here, and `remove` is what gives it back.
*/
post_chan :: proc(name: string, c: ^vfs.Chan) -> vfs.Errno #no_bounds_check {
	if c == nil || !valid_name(name) {
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
	if free < 0 || t.next_id <= 0 {
		return vectra9.ENOSPC
	}

	s := &t.table[free]
	s^ = Service {
		endpoint = vfs.chan_incref(c),
		id       = t.next_id,
		len      = len(name),
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
remove :: proc(name: string) -> vfs.Errno #no_bounds_check {
	t := &srv_tree
	retired: ^vfs.Chan

	g := sync.acquire(&t.lock)
	found := false
	for i in 0 ..< MAX_SERVICES {
		if live(&t.table[i]) && name_of(&t.table[i]) == name {
			retired = t.table[i].endpoint
			t.table[i] = Service{}
			t.count -= 1
			t.removes += 1
			found = true
			break
		}
	}
	sync.release(&t.lock, g)

	if retired != nil {
		// Outside the lock, because a close may clunk a fid, and a clunk is a
		// message. The service does not stop -- a wire built from this chan
		// holds its own reference. What the removal does release is the
		// name's *stake* on that wire: with the last mount also gone, the
		// connection comes down here.
		//
		// The close goes first. The release's own close has to be the last
		// one on the posted end. This reference would otherwise keep the end
		// open under the wire's reader. See `pipe.unpost`.
		staked := pipe.unpost(retired)
		vfs.chan_close(retired)
		if staked != nil {
			vfs.server_unpin(staked)
		}
	}
	return found ? vfs.OK : vectra9.ENOENT
}

// lookup finds a posted service by name. Nil when nothing has that name, and
// nil for a pending entry too. A name is not a service until something wrote
// a connection into it, and a caller treats both as `not posted`.
lookup :: proc "contextless" (name: string) -> ^vfs.Server #no_bounds_check {
	t := &srv_tree
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)

	for i in 0 ..< MAX_SERVICES {
		if live(&t.table[i]) && name_of(&t.table[i]) == name {
			return served_by(&t.table[i])
		}
	}
	return nil
}

// served_by is the server a name reaches without a mount's work: the kernel
// service, or the device behind a posted connection. A posted pipe end
// answers with the pipe device here, and only `mount` builds the wire.
@(private = "file")
served_by :: proc "contextless" (s: ^Service) -> ^vfs.Server {
	if s.server != nil {
		return s.server
	}
	if s.endpoint != nil {
		return s.endpoint.server
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
	server, endpoint, err := service_at(ns, path)
	if err != vfs.OK {
		return err
	}

	pinned: ^vfs.Server
	if endpoint != nil {
		/*
		A posted connection rather than a kernel service. For a pipe end this is
		where the wire is built, which is Plan 9's `devmnt` moment in the same
		place. The kernel becomes a 9P client of whatever answers the far side,
		and the first answer it wants is Tversion. For any other chan, the
		connection is the device behind it, which is how posting a descriptor on
		`/dev/cons` publishes the whole of `#c`.
		*/
		defer vfs.chan_close(endpoint)
		if wired := pipe.server_for(endpoint); wired != nil {
			server = wired
			pinned = wired
		} else if p, _ := pipe.chan_pipe(endpoint); p != nil {
			// A pipe end whose wire could not be built: the far side missed
			// the handshake, spoke another dialect, or the end is already
			// spoken for. The pipe device behind the chan answers nothing a
			// mount can use. This is `/srv`'s sentence for a name whose
			// service is not there, said here rather than left to the
			// device's ENOENT.
			return vectra9.ENXIO
		} else {
			server = endpoint.server
		}
	}
	/*
	`server_for` handed the wire over pinned, and the pin comes off when this
	mount's fate is settled. Registered before the chan-closing defers, so it
	runs after them. On success the mount table holds chans by then, and
	nothing fires. On failure this unpin is the last stake of a mount that
	never was. With the name also gone, it is what tears the wire down.
	*/
	defer if pinned != nil {
		vfs.server_unpin(pinned)
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
service_at resolves a path and reports what the posted name holds.

One of the two answers is non-nil on success: the kernel service, or the
posted connection with a reference taken for the caller. The reference is
what keeps the chan alive across the mount that follows, against a removal
racing it.

EINVAL when the path resolves to something this server does not serve, or to
this server's own root. Neither is a service, and both are a caller that
believes a path is a `/srv` entry when it is not.
*/
@(private = "file")
service_at :: proc(
	ns: ^vfs.Namespace,
	path: string,
) -> (^vfs.Server, ^vfs.Chan, vfs.Errno) #no_bounds_check {
	t := &srv_tree

	c, err := vfs.resolve(ns, path)
	if err != vfs.OK {
		return nil, nil, err
	}
	defer vfs.chan_close(c)

	if c.server != &t.server {
		return nil, nil, vectra9.EINVAL
	}
	id := id_of_qid(c.qid)
	if id <= 0 {
		return nil, nil, vectra9.EINVAL
	}

	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)

	i := slot_of(t, id)
	if i < 0 {
		// The name resolved and the entry went between the walk and here.
		// ENOENT is what a client would have got a moment earlier.
		return nil, nil, vectra9.ENOENT
	}
	if t.table[i].server != nil {
		return t.table[i].server, nil, vfs.OK
	}
	if t.table[i].endpoint != nil {
		return nil, vfs.chan_incref(t.table[i].endpoint), vfs.OK
	}
	// Created and not yet written. The name is real and the connection
	// behind it is not there, which is ENXIO's exact sentence.
	return nil, nil, vectra9.ENXIO
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
srv_creates reports whether a message would add a name some way this tree
does not allow.

`Tlcreate` is no longer in the list, because creating a file in `/srv` is
how a service is posted -- the exact thing Plan 9 does. The rest still
answer EPERM rather than EOPNOTSUPP. A directory, a link or a rename in
`/srv` is a thing a client may imagine and may not have. That is a
permission rather than an absence.
*/
@(private = "file")
srv_creates :: proc "contextless" (k: vectra9.Kind) -> bool {
	#partial switch k {
	case .Tmkdir, .Tmknod, .Tsymlink, .Tlink, .Trename, .Trenameat:
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
) {
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

	// A context, because two arms below touch chans, and chan bookkeeping is
	// context code. Built once here rather than in each arm.
	ctx := runtime.default_context()
	ctx.allocator = mem.allocator()
	context = ctx

	retired := srv_dispatch(t, request, reply, buf)
	if retired != nil {
		// After the dispatch released the table lock, because a close may
		// clunk a fid and a clunk is a message. The service behind the chan
		// does not stop with the name -- but the name's stake on a wired
		// connection goes with it, after this reference. See `remove`.
		staked := pipe.unpost(retired)
		vfs.chan_close(retired)
		if staked != nil {
			vfs.server_unpin(staked)
		}
	}
}

// srv_dispatch answers one message under the table lock. It hands back the
// chan a removal retired, for the caller to close where a message is legal.
@(private = "file")
srv_dispatch :: proc(
	t: ^Srv_Tree,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) -> (retired: ^vfs.Chan) #no_bounds_check {
	// Everything unhandled is a genuine "not implemented". Set it first, so
	// each case below is one assignment rather than one and a fall-through
	// somebody forgets.
	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)

	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)

	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply)

	case vectra9.Tattach:
		if !vfs.fidtab_bind(&t.fids, m.fid, ROOT_ID) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
		reply^ = vectra9.Rattach{qid = qid_of_id(ROOT_ID)}

	case vectra9.Twalk:
		srv_walk(t, m, reply)

	case vectra9.Tlcreate:
		/*
		Posting, step one: a name is reserved and nothing serves it yet.

		The fid arrives on the root and leaves on the new entry, open.
		That mutation is Tlcreate's own semantics, and `fidtab_bind` on an
		existing fid is exactly a rebind. The name is copied out of the
		message before the reply, because the message's string borrows the
		decode buffer.
		*/
		id := vfs.fidtab_node(&t.fids, m.fid)
		if id < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		if id != ROOT_ID {
			reply^ = vectra9.error_reply(vectra9.ENOTDIR)
			return
		}
		if !valid_name(m.name) {
			reply^ = vectra9.error_reply(vectra9.EINVAL)
			return
		}
		if slot_named(t, m.name) >= 0 {
			reply^ = vectra9.error_reply(vectra9.EEXIST)
			return
		}
		free := -1
		for i in 0 ..< MAX_SERVICES {
			if !live(&t.table[i]) {
				free = i
				break
			}
		}
		if free < 0 || t.next_id <= 0 {
			reply^ = vectra9.error_reply(vectra9.ENOSPC)
			return
		}
		s := &t.table[free]
		s^ = Service {
			id  = t.next_id,
			len = len(m.name),
		}
		for i in 0 ..< len(m.name) {
			s.name[i] = m.name[i]
		}
		t.next_id += 1
		t.count += 1
		_ = vfs.fidtab_bind(&t.fids, m.fid, s.id)
		reply^ = vectra9.Rlcreate{qid = qid_of_id(s.id), iounit = 0}

	case vectra9.Twrite:
		/*
		Posting, step two: a descriptor number turns into the service.

		The number is judged against the calling process's own table,
		through the resolver `kernel/user` registered. See `Fd_Resolver`
		for why that is sound here and nowhere else. A completed entry
		refuses a second write: a posted service is not a thing to swap
		underneath whoever mounted the name.
		*/
		id := vfs.fidtab_node(&t.fids, m.fid)
		if id < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		if id == ROOT_ID {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		i := slot_of(t, id)
		if i < 0 {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		if t.table[i].server != nil || t.table[i].endpoint != nil {
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		fd, ok := parse_fd(m.data)
		if !ok {
			reply^ = vectra9.error_reply(vectra9.EINVAL)
			return
		}
		ch: ^vfs.Chan
		if fd_resolver != nil {
			ch = fd_resolver(fd)
		}
		if ch == nil {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		// The reference is the posting, and the resolver already took it.
		// The descriptor may close and the process may end, and the
		// connection stays reachable by name.
		t.table[i].endpoint = ch
		t.posts += 1
		reply^ = vectra9.Rwrite{count = u32(len(m.data))}

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
		retired = t.table[i].endpoint
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
	return
}

/*
parse_fd reads a decimal descriptor number out of a write's bytes.

Digits, then at most one newline, then nothing -- the exact bytes a shell's
`echo` or a program's formatter produces. Anything else is EINVAL from the
caller's point of view, before any table is consulted. A malformed write
therefore fails the same way whoever sent it.

The bound is not a descriptor-table size. That table belongs to whoever
resolves the number, and this parser only refuses values that could not be a
descriptor anywhere.
*/
@(private = "file")
parse_fd :: proc "contextless" (data: []u8) -> (fd: int, ok: bool) #no_bounds_check {
	end := len(data)
	if end > 0 && data[end - 1] == '\n' {
		end -= 1
	}
	if end == 0 || end > 5 {
		return 0, false
	}
	n := 0
	for i in 0 ..< end {
		if data[i] < '0' || data[i] > '9' {
			return 0, false
		}
		n = n * 10 + int(data[i] - '0')
	}
	return n, true
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
	sv := served_by(&t.table[i])

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

	if sv == nil {
		// Created and not yet written. Saying so is more use to a person at
		// a shell than any answer built from fields that are not there.
		return put(out, n, "pending\n")
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
