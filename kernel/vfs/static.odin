/*
A read-only server over a table of nodes.

One implementation, many instances. `#/` is one. So is anything else with a
fixed shape to publish. A boot manifest, a set of tunables, or the skeleton a
real filesystem binds into. A second server should not mean a second fid table.

Two properties are worth being explicit about, because they are what make this
usable at boot before anything else exists:

  - **The handler never allocates.** It is `contextless` like every other
    Vectra9 handler. The two things a server needs to grow are a fid table and
    somewhere to encode a directory listing, and `static_init` sizes both once.
    A server that ran out of fids returns ENFILE, which is the truth, rather
    than reaching for a heap it may be underneath.
  - **A read costs no copy.** `Rread.data` points straight into the node's
    string, which lives in `.rodata`. The copy happens once, in `chan_read`,
    because that is the layer whose caller owns a buffer.

`.` and `..` are not in a directory listing here. 9P walks them, and Plan 9's
servers do not emit them. A POSIX layer that needs them synthesises them where
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

Static_Tree :: struct {
	label: string,
	nodes: []Static_Node,

	// One fid table, shared with every other server in the tree -- see
	// `fidtab.odin`. What this server binds to a fid is an index into `nodes`.
	fids:  Fid_Table,

	/*
	Where an Rreaddir payload is built when the transport supplies nowhere else.

	One buffer per server, borrowed by the reply and valid until the next
	message -- which is exactly the ownership rule the whole package runs on.

	`Until the next message` used to mean `until this caller sends another one`,
	because nothing could get in between. Preemption ended that. A timer between
	the reply and the client's copy out of it lets a second thread issue a
	Treaddir. That second thread overwrites the buffer the first is standing in.

	What stops that is `Server.lock`, held across the message *and* the caller's
	use of the reply. See `rpc` and the borrow rule in `lock.odin`. One buffer is
	still the right shape. What changed is that a lock now protects it, rather
	than an absence of threads.

	A lock is enough for one request at a time and cannot be enough for more. The
	fix is not a second buffer here. It is that the transport hands each request
	storage of its own, and this server writes there instead. `static_readdir`
	takes that buffer when it is offered, and falls back to this one when it is
	not. A transport that offers none is a transport with one request in flight,
	where this buffer was always sufficient.
	*/
	dirbuf: []u8,

	/*
	The server's own state, which is every field above this one.

	Distinct from the session lock a client holds across a message, and not
	implied by it. `Static_Tree` is the *server* side, and a server protects
	itself rather than trusts each client to serialise first.

	Today the two are redundant, because there is one tree, one session, and one
	message at a time. That redundancy costs a nested acquire on a uniprocessor,
	which is a decrement and an increment. Cheap enough that the layering is worth
	keeping honest.
	*/
	lock:   sync.Spinlock,
}

/*
static_init sizes a server's tables and returns whether it could.

Both limits are real, and are meant to be. `fidtab_init` says why a fid table
has a ceiling. `dirbuf_size` bounds the one listing this server can build when
its transport offers nowhere else -- see `dirbuf` above.
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
	t.dirbuf = make([]u8, dirbuf_size)
	if !fidtab_init(&t.fids, max_fids) || t.dirbuf == nil {
		static_destroy(t)
		return false
	}
	return true
}

static_destroy :: proc(t: ^Static_Tree) {
	if t == nil {
		return
	}
	fidtab_destroy(&t.fids)
	if t.dirbuf != nil {
		delete(t.dirbuf)
		t.dirbuf = nil
	}
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
		// The root's parent is the root. A server has no name for anything above its
		// own tree. This says so plainly, which is what lets the namespace layer
		// notice and climb through `mounted_over` instead.
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

Answered by kind, rather than by a fall through to a default. A read-only
server therefore refuses a write with EROFS, which says `there is such an
operation and you may not`. EOPNOTSUPP would say the server does not implement
it, and send a client to look for a different one.
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
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = s
	_ = tag
	t := cast(^Static_Tree)server
	if t == nil {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}

	// The whole handler. The fid table is read and written across most of it,
	// and the fallback `dirbuf` near the end of it. Released on the way out. A
	// reply that borrows `dirbuf` past this point is the client's session
	// lock's problem, not this one's. A reply built in `buf` borrows nothing of
	// this server's and has no such problem.
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
		// A refused dialect gets a different version string in the answer, which is
		// what a client checks. Never an Rlerror.
		if m.version != vectra9.VERSION {
			reply^ = vectra9.Rversion{msize = m.msize, version = "unknown"}
			return
		}
		reply^ = vectra9.Rversion {
			msize   = min(m.msize, vectra9.MSIZE_DEFAULT),
			version = vectra9.VERSION,
		}

	case vectra9.Tattach:
		if !fidtab_bind(&t.fids, m.fid, 0) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
		reply^ = vectra9.Rattach{qid = node_qid(t, 0)}

	case vectra9.Twalk:
		static_walk(t, m, reply)

	case vectra9.Tlopen:
		node := fidtab_node(&t.fids, m.fid)
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
		node := fidtab_node(&t.fids, m.fid)
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
		static_readdir(t, m, reply, buf)

	case vectra9.Tgetattr:
		node := fidtab_node(&t.fids, m.fid)
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
		if fidtab_node(&t.fids, m.fid) < 0 {
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
		_ = fidtab_release(&t.fids, m.fid)
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
    is untouched and the client still holds only `fid`. Bound to where the walk
    stopped, it would hand back a handle on a directory the client never asked
    for. The client cannot tell that apart from success.
  - **A failure at element zero is an error reply. A failure later is a short
  Rwalk.** The client distinguishes "the first name is not there" from "the
    path runs out partway" by which of those it gets.
*/
@(private = "file")
static_walk :: proc "contextless" (t: ^Static_Tree, m: vectra9.Twalk, reply: ^vectra9.Msg) #no_bounds_check {
	node := fidtab_node(&t.fids, m.fid)
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
		if !fidtab_bind(&t.fids, m.newfid, cur) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
	}
	reply^ = answer
}

@(private = "file")
static_readdir :: proc "contextless" (
	t: ^Static_Tree,
	m: vectra9.Treaddir,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	node := fidtab_node(&t.fids, m.fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if !t.nodes[node].dir {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}

	// The transport's buffer when there is one, and this server's own when
	// there is not. Only the first is safe with several handlers running, and
	// only the second existed before there were. See `Static_Tree.dirbuf`.
	out := buf
	if out == nil {
		out = t.dirbuf
	}

	room := min(len(out), int(m.count))
	c := vectra9.cursor_from(out[:room])

	/*
	The cookie is the child's ordinal within its parent, one-based. It therefore
	means `resume after this one` rather than `resume at this one`. That is what
	Treaddir means by an offset, and it is why zero is a legal starting value that
	no entry ever returns.

	Linear in the size of the whole table per call. That is fine for a table that
	fits in a cache line's worth of directories. It would not be for a real
	filesystem. A real one keeps its children in a list.
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
