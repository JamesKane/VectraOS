/*
A read-only server over a table of nodes.

One implementation, many instances: `#/` is one, and anything else that wants
to publish a fixed shape -- a boot manifest, a set of tunables, the skeleton a
real filesystem gets bound into -- is another. Writing a second server should
not mean writing a second fid table.

Two properties are worth being explicit about, because they are what make this
usable at boot before anything else exists:

  - **The handler never allocates.** It is `contextless` like every other
    Vectra9 handler, and the two things a server needs to grow -- a fid table
    and somewhere to encode a directory listing -- are sized once in
    `static_init`. A server that ran out of fids returns ENFILE, which is the
    truth, rather than reaching for a heap it may be underneath.
  - **A read costs no copy.** `Rread.data` points straight into the node's
    string, which lives in `.rodata`. The copy happens once, in `chan_read`,
    because that is the layer whose caller owns a buffer.

`.` and `..` are not in a directory listing here. 9P walks them, and Plan 9's
servers do not emit them; a POSIX layer that needs them synthesises them where
it synthesises the rest of `struct dirent`.
*/
package vfs

import "kernel:sync"
import "vsys:vectra9"

Static_Node :: struct {
	name:   string,
	parent: i32, // Index of the containing directory; -1 for the root
	dir:    bool,
	data:   string, // File contents; ignored for a directory
}

// Linux st_mode type bits, as Rgetattr carries them.
@(private)
S_IFDIR :: u32(0o040000)
@(private)
S_IFREG :: u32(0o100000)

STATIC_FID_BUCKETS :: 32

/*
One client fid, bound to one node.

Chained by index rather than by pointer so the whole table is one allocation
and a slot can be on the free list or in a bucket without either being a
different type. `next` is that chain in both roles.
*/
@(private)
Fid_Slot :: struct {
	fid:   vectra9.Fid,
	node:  i32,
	next:  i32, // Bucket chain when in use, free list when not; -1 ends both
	inuse: bool,
}

Static_Tree :: struct {
	label:   string,
	nodes:   []Static_Node,
	slots:   []Fid_Slot,
	buckets: [STATIC_FID_BUCKETS]i32,
	free:    i32,
	live:    int,

	/*
	Where an Rreaddir payload is built.

	One buffer per server, borrowed by the reply and valid until the next
	message -- which is exactly the ownership rule the whole package runs on.

	"Until the next message" used to mean "until this caller sends another
	one", because nothing could get in between. Preemption ended that: a timer
	between the reply landing and the client copying out of it lets a second
	thread issue a Treaddir and overwrite the buffer the first is standing in.
	What keeps that from happening is `Server.lock`, held across the message
	*and* the caller's use of the reply -- see `rpc` and the borrow rule in
	`lock.odin`. One buffer is still the right shape; what changed is that the
	rule protecting it is now a lock rather than an absence of threads.
	*/
	dirbuf: []u8,

	/*
	The server's own state, which is every field above this one.

	Distinct from the session lock a client holds across a message, and not
	implied by it: `Static_Tree` is the *server* side, and a server protects
	itself rather than trusting each client to have serialised first. Today the
	two are redundant -- one tree, one session, one message at a time -- and
	that redundancy costs a nested acquire on a uniprocessor, which is a
	decrement and an increment. Cheap enough that the layering is worth keeping
	honest.
	*/
	lock:   sync.Spinlock,
}

/*
static_init sizes a server's tables and returns whether it could.

`max_fids` is a real limit and is meant to be: a fid is a server resource, and
a server that grows its table on demand is a server a client can exhaust the
machine's memory through.
*/
static_init :: proc(
	t: ^Static_Tree,
	label: string,
	nodes: []Static_Node,
	max_fids: int = 64,
	dirbuf_size: int = 4096,
) -> bool #no_bounds_check {
	if t == nil || len(nodes) == 0 || max_fids <= 0 {
		return false
	}

	t.label = label
	t.nodes = nodes
	t.slots = make([]Fid_Slot, max_fids)
	t.dirbuf = make([]u8, dirbuf_size)
	if t.slots == nil || t.dirbuf == nil {
		static_destroy(t)
		return false
	}

	for i in 0 ..< max_fids {
		t.slots[i].next = i32(i) + 1
	}
	t.slots[max_fids - 1].next = -1
	t.free = 0
	t.live = 0
	for i in 0 ..< STATIC_FID_BUCKETS {
		t.buckets[i] = -1
	}
	return true
}

static_destroy :: proc(t: ^Static_Tree) {
	if t == nil {
		return
	}
	if t.slots != nil {
		delete(t.slots)
		t.slots = nil
	}
	if t.dirbuf != nil {
		delete(t.dirbuf)
		t.dirbuf = nil
	}
	t.live = 0
}

// -- Fid table ---------------------------------------------------------------

@(private = "file")
slot_hash :: proc "contextless" (fid: vectra9.Fid) -> int {
	return int(u32(fid) % STATIC_FID_BUCKETS)
}

@(private = "file")
slot_find :: proc "contextless" (t: ^Static_Tree, fid: vectra9.Fid) -> i32 #no_bounds_check {
	for i := t.buckets[slot_hash(fid)]; i >= 0; i = t.slots[i].next {
		if t.slots[i].fid == fid {
			return i
		}
	}
	return -1
}

// slot_bind attaches a fid to a node, rebinding one that already exists --
// which is what a Twalk with newfid equal to fid asks for.
@(private = "file")
slot_bind :: proc "contextless" (t: ^Static_Tree, fid: vectra9.Fid, node: i32) -> bool #no_bounds_check {
	if i := slot_find(t, fid); i >= 0 {
		t.slots[i].node = node
		return true
	}
	if t.free < 0 {
		return false
	}

	i := t.free
	t.free = t.slots[i].next

	b := slot_hash(fid)
	t.slots[i] = Fid_Slot {
		fid   = fid,
		node  = node,
		next  = t.buckets[b],
		inuse = true,
	}
	t.buckets[b] = i
	t.live += 1
	return true
}

@(private = "file")
slot_release :: proc "contextless" (t: ^Static_Tree, fid: vectra9.Fid) -> bool #no_bounds_check {
	b := slot_hash(fid)
	prev := i32(-1)
	for i := t.buckets[b]; i >= 0; i = t.slots[i].next {
		if t.slots[i].fid == fid {
			if prev < 0 {
				t.buckets[b] = t.slots[i].next
			} else {
				t.slots[prev].next = t.slots[i].next
			}
			t.slots[i].inuse = false
			t.slots[i].next = t.free
			t.free = i
			t.live -= 1
			return true
		}
		prev = i
	}
	return false
}

@(private = "file")
node_of :: proc "contextless" (t: ^Static_Tree, fid: vectra9.Fid) -> i32 #no_bounds_check {
	i := slot_find(t, fid)
	if i < 0 {
		return -1
	}
	return t.slots[i].node
}

// -- The tree ----------------------------------------------------------------

@(private = "file")
node_qid :: proc "contextless" (t: ^Static_Tree, node: i32) -> vectra9.Qid #no_bounds_check {
	// Path is the index plus one: zero is left unused so that a qid a caller
	// forgot to fill in does not name the root.
	kind: vectra9.Qid_Flags
	if t.nodes[node].dir {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

@(private = "file")
find_child :: proc "contextless" (t: ^Static_Tree, parent: i32, name: string) -> i32 #no_bounds_check {
	for i in 0 ..< len(t.nodes) {
		if t.nodes[i].parent == parent && t.nodes[i].name == name {
			return i32(i)
		}
	}
	return -1
}

@(private = "file")
step :: proc "contextless" (t: ^Static_Tree, from: i32, name: string) -> i32 #no_bounds_check {
	switch name {
	case ".":
		return from
	case "..":
		// The root's parent is the root. A server has no name for anything
		// above its own tree, and saying so plainly here is what lets the
		// namespace layer notice and climb through `mounted_over` instead.
		p := t.nodes[from].parent
		return p < 0 ? from : p
	}
	if !t.nodes[from].dir {
		return -1
	}
	return find_child(t, from, name)
}

/*
static_mutates reports whether a message would change the tree.

Answered by kind rather than by falling through to a default, so a read-only
server refuses a write with EROFS -- "there is such an operation and you may
not" -- rather than EOPNOTSUPP, which would say the server does not implement
it and send a client looking for a different one.
*/
@(private = "file")
static_mutates :: proc "contextless" (k: vectra9.Kind) -> bool {
	#partial switch k {
	case .Twrite,
	     .Tlcreate,
	     .Tmkdir,
	     .Tmknod,
	     .Tsymlink,
	     .Tlink,
	     .Trename,
	     .Trenameat,
	     .Tunlinkat,
	     .Tremove,
	     .Tsetattr,
	     .Txattrcreate,
	     .Tfsync:
		return true
	}
	return false
}

// -- The handler -------------------------------------------------------------

static_handler :: proc "contextless" (
	server: rawptr,
	s: ^vectra9.Session,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
) #no_bounds_check {
	_ = s
	t := cast(^Static_Tree)server
	if t == nil {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}

	// The whole handler, because the fid table is read and written across most
	// of it and `dirbuf` is written near the end of it. Released on the way
	// out -- the *reply* borrowing `dirbuf` past this point is the client's
	// session lock's problem, not this one's.
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)

	if static_mutates(vectra9.kind(request^)) {
		reply^ = vectra9.error_reply(vectra9.EROFS)
		return
	}

	// Everything unhandled is a genuine "not implemented". Set it first so
	// each case below is one assignment rather than one assignment and a
	// fall-through nobody remembers to write.
	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)

	#partial switch m in request^ {
	case vectra9.Tversion:
		// Refusing a dialect is done by answering with a different version
		// string, which is what a client checks. Never an Rlerror.
		if m.version != vectra9.VERSION {
			reply^ = vectra9.Rversion{msize = m.msize, version = "unknown"}
			return
		}
		reply^ = vectra9.Rversion {
			msize   = min(m.msize, vectra9.MSIZE_DEFAULT),
			version = vectra9.VERSION,
		}

	case vectra9.Tattach:
		if !slot_bind(t, m.fid, 0) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
		reply^ = vectra9.Rattach{qid = node_qid(t, 0)}

	case vectra9.Twalk:
		static_walk(t, m, reply)

	case vectra9.Tlopen:
		node := node_of(t, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		// Read-only, so anything but O_RDONLY in the access bits is a no.
		if m.flags & 0o3 != O_RDONLY {
			reply^ = vectra9.error_reply(vectra9.EROFS)
			return
		}
		reply^ = vectra9.Rlopen{qid = node_qid(t, node), iounit = 0}

	case vectra9.Tread:
		node := node_of(t, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		if t.nodes[node].dir {
			// 9P2000.L reads directories with Treaddir. Tread on one is the
			// client using the wrong message, not a permissions problem.
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		data := transmute([]u8)t.nodes[node].data
		if m.offset >= u64(len(data)) {
			reply^ = vectra9.Rread{data = data[:0]}
			return
		}
		start := int(m.offset)
		end := min(len(data), start + int(m.count))
		reply^ = vectra9.Rread{data = data[start:end]}

	case vectra9.Treaddir:
		static_readdir(t, m, reply)

	case vectra9.Tgetattr:
		node := node_of(t, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		n := &t.nodes[node]
		attr := vectra9.Rgetattr {
			valid   = m.request_mask & GETATTR_BASIC,
			qid     = node_qid(t, node),
			mode    = n.dir ? S_IFDIR | 0o555 : S_IFREG | 0o444,
			nlink   = n.dir ? 2 : 1,
			size    = n.dir ? 0 : u64(len(n.data)),
			blksize = 512,
		}
		attr.blocks = (attr.size + 511) / 512
		reply^ = attr

	case vectra9.Tstatfs:
		if node_of(t, m.fid) < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		reply^ = vectra9.Rstatfs {
			type    = 0x0139_9249, // V9FS_MAGIC, as Linux reports for 9P
			bsize   = 512,
			files   = u64(len(t.nodes)),
			namelen = 255,
		}

	case vectra9.Tclunk:
		// Clunking an unknown fid is not worth an error: the client wanted it
		// gone and it is gone. Refusing would only ever break a cleanup path.
		_ = slot_release(t, m.fid)
		reply^ = vectra9.Rclunk{}

	case vectra9.Tflush:
		// Nothing is ever pending against a synchronous transport, so the
		// request being flushed has already been answered. Rflush regardless:
		// Tflush can never be answered with an error. See section 7.3.
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

/*
static_walk resolves up to sixteen names in one message.

The two rules a walk has to get right, both easy to miss:

  - **A partial walk binds nothing.** If element three of five fails, `newfid`
    is untouched and the client still holds only `fid`. Binding it to where the
    walk stopped would hand back a handle on a directory the client never asked
    for and cannot tell apart from success.
  - **A failure at element zero is an error reply; a failure later is a short
    Rwalk.** The client distinguishes "the first name is not there" from "the
    path runs out partway" by which of those it gets.
*/
@(private = "file")
static_walk :: proc "contextless" (t: ^Static_Tree, m: vectra9.Twalk, reply: ^vectra9.Msg) #no_bounds_check {
	node := node_of(t, m.fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}

	answer: vectra9.Rwalk
	cur := node
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
		answer.qids[answer.count] = node_qid(t, cur)
		answer.count += 1
	}

	if answer.count == m.count {
		if !slot_bind(t, m.newfid, cur) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
	}
	reply^ = answer
}

@(private = "file")
static_readdir :: proc "contextless" (t: ^Static_Tree, m: vectra9.Treaddir, reply: ^vectra9.Msg) #no_bounds_check {
	node := node_of(t, m.fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if !t.nodes[node].dir {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}

	room := min(len(t.dirbuf), int(m.count))
	c := vectra9.cursor_from(t.dirbuf[:room])

	/*
	The cookie is the child's ordinal within its parent, one-based, so it is
	"resume after this one" rather than "resume at this one" -- which is what
	Treaddir means by an offset and why zero is a legal starting value that is
	never returned in an entry.

	Linear in the size of the whole table per call, which is fine for a table
	that fits in a cache line's worth of directories and would not be for a
	real filesystem. A real one keeps its children in a list.
	*/
	ordinal := u64(0)
	for i in 0 ..< len(t.nodes) {
		if t.nodes[i].parent != node {
			continue
		}
		ordinal += 1
		if ordinal <= m.offset {
			continue
		}
		if vectra9.remaining(&c) < vectra9.dirent_size(t.nodes[i].name) {
			break
		}
		vectra9.put_dirent(
			&c,
			vectra9.Dirent {
				qid = node_qid(t, i32(i)),
				offset = ordinal,
				type = t.nodes[i].dir ? vectra9.DT_DIR : vectra9.DT_REG,
				name = t.nodes[i].name,
			},
		)
	}

	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
