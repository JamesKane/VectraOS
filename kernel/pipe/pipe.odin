/*
A pipe -- two ends, a byte ring per direction, and no structure imposed on the
bytes.

This is the channel the handoff called `a pipe whose far side is a process`.
Each end reads what the other wrote, in order, with no message boundary. A
read on an empty ring parks until the other end writes or goes away. A write
on a full ring parks until the other end reads. That is the whole contract,
and every property a 9P conversation needs -- framing, tags, flushes -- lives
in the layer above. See `wire.odin` in `kernel/mnt`.

The ends are chans. `open_end` attaches to this package's own server and
hands back an ordinary `^vfs.Chan`. An end therefore sits in a process's
descriptor table like any other file. It travels through `spawn` like any
other descriptor, and closes by the same `Tclunk` as everything else. That
is what lets a process post one in `/srv` -- posting takes a descriptor, and
a descriptor names a chan.

The server is deliberately not in the `#name` table. A pipe has no name until
somebody posts one. Every end reaches ring 3 through a descriptor the kernel
handed out, which is the same privilege boundary `/srv` posting already
enforces.

## Close, and what it means

Each direction carries two flags rather than one, because the two ends of a
direction die differently:

  - `closed`: the writing end is gone. The reader drains what is buffered
  and then reads zero bytes, which is EOF.
  - `dead`: the reading end is gone. A write returns EPIPE, because nothing
  will ever drain the ring.

One `close_end` sets one of each, on opposite flows. Both ends closed is a
pipe nothing can reach, and the rings go back to the heap. A wire built on
the pipe is the exception, and it pins the pipe for as long as the machine
runs. See `server_for`.
*/
package pipe

import "base:intrinsics"
import "base:runtime"

import "kernel:mem"
import "kernel:sync"
import "kernel:vfs"
import "vsys:vectra9"

/*
How many pipes may exist at once.

Fixed, like every other table a client can grow -- the argument is
`srv.MAX_SERVICES`'s. A full table answers nil, and `sys_pipe` turns that into
ENOSPC.
*/
MAX_PIPES :: 8

// Bytes one direction can buffer. A 9P frame larger than this still crosses,
// because `write` moves what fits and parks for the rest while the far end
// drains.
RING_SIZE :: 2048

/*
One direction of travel.

`flows[e]` carries bytes *to* end `e`: end `1 - e` writes it and end `e` reads
it. The counts are volatile-read by the sleep conditions, which is the same
arrangement every wait in `kernel/mnt` uses. The package lock guards them, and
no sleep happens under it.
*/
@(private)
Flow :: struct {
	buf:    []u8,
	head:   int, // Index of the next byte to read
	used:   int,
	closed: bool, // The writing end has gone: drain, then EOF
	dead:   bool, // The reading end has gone: a write is EPIPE
	r:      sync.Rendez, // Readers wait here for bytes
	w:      sync.Rendez, // Writers wait here for room
}

/*
One pipe.

`id` is the identity and the slot index is not, for the reason `kernel/srv`
established. Slots are reused, and a fid bound to a slot would name whatever
took it next. A fid binds the id, a qid carries it, and a lookup is a scan.

`server9` is the wire-backed `vfs.Server` built the first time a posted end is
mounted, or nil. Once set it pins the pipe: the wire's reader thread and every
mount of the service reach through it, so the slot never goes back. That is
the same honest leak `docs/SRV.md` records for posted services, and the same
fix -- a reference count -- retires both.
*/
Pipe :: struct {
	id:       i32,
	flows:    [2]Flow,
	open:     [2]bool,
	server9:  ^vfs.Server,
	wire_end: int, // Which end `server9`'s wire drives, when it exists
}

@(private)
Pipe_Table :: struct {
	table:   [MAX_PIPES]Pipe,
	next_id: i32,
	count:   int,

	fids:    vfs.Fid_Table,

	// Guards the table, the fid table, and every flow. Never held across a
	// park: every sleep below re-checks its condition through a volatile read.
	lock:    sync.Spinlock,

	// Serialises `server_for`, which allocates, spawns a thread and waits for
	// a Tversion answer. A mutex rather than the spinlock, because all three
	// park.
	build:   sync.Mutex,

	server:  vfs.Server,
	created: u64,
	freed:   u64,
}

@(private)
pipes: Pipe_Table

PIPE_MAX_FIDS :: 32

// Linux st_mode type bits, as Rgetattr carries them.
@(private = "file")
S_IFREG :: u32(0o100000)

/*
init brings the pipe server up. It binds nothing and registers nothing.

Reports false when the fid table has no memory or the handshake fails, and the
boot says so on its own line. A machine without pipes still boots -- what it
loses is `sys_pipe`, and the first caller finds out.
*/
init :: proc() -> bool {
	t := &pipes
	if !vfs.fidtab_init(&t.fids, PIPE_MAX_FIDS) {
		return false
	}
	t.next_id = 1
	if vfs.server_init(&t.server, "|", pipe_handler, t) != .None {
		vfs.fidtab_destroy(&t.fids)
		return false
	}
	return true
}

// count reports how many pipes are live. For the boot line and the self-test.
count :: proc "contextless" () -> int {
	t := &pipes
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)
	return t.count
}

// stats reports how many pipes were made and how many went back. A table that
// ends where it started may still go wrong in the middle.
stats :: proc "contextless" () -> (created: u64, freed: u64) {
	t := &pipes
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)
	return t.created, t.freed
}

@(private)
live :: proc "contextless" (p: ^Pipe) -> bool {
	return p.id != 0
}

// slot_of finds the live pipe carrying an id. Caller holds the lock.
@(private = "file")
slot_of :: proc "contextless" (t: ^Pipe_Table, id: i32) -> ^Pipe #no_bounds_check {
	for i in 0 ..< MAX_PIPES {
		if live(&t.table[i]) && t.table[i].id == id {
			return &t.table[i]
		}
	}
	return nil
}

/*
create makes a pipe with both ends open and no chans on it yet.

The rings come off the heap here rather than live in the table. A slot then
costs two pointers when empty and 4 KiB when live. Nil when the table is
full, the id counter ran out, or the heap has no room.
*/
create :: proc() -> ^Pipe #no_bounds_check {
	t := &pipes

	a := make([]u8, RING_SIZE)
	b := make([]u8, RING_SIZE)
	if a == nil || b == nil {
		delete(a)
		delete(b)
		return nil
	}

	g := sync.acquire(&t.lock)
	free_slot: ^Pipe
	for i in 0 ..< MAX_PIPES {
		if !live(&t.table[i]) {
			free_slot = &t.table[i]
			break
		}
	}
	if free_slot == nil || t.next_id <= 0 {
		sync.release(&t.lock, g)
		delete(a)
		delete(b)
		return nil
	}

	free_slot^ = Pipe {
		id   = t.next_id,
		open = {true, true},
	}
	free_slot.flows[0].buf = a
	free_slot.flows[1].buf = b
	t.next_id += 1
	t.count += 1
	t.created += 1
	sync.release(&t.lock, g)
	return free_slot
}

// -- Moving bytes ------------------------------------------------------------

@(private = "file")
flow_readable :: proc "contextless" (arg: rawptr) -> bool {
	f := cast(^Flow)arg
	if intrinsics.volatile_load(&f.used) > 0 {
		return true
	}
	return intrinsics.volatile_load(&f.closed)
}

@(private = "file")
flow_writable :: proc "contextless" (arg: rawptr) -> bool {
	f := cast(^Flow)arg
	if intrinsics.volatile_load(&f.used) < len(f.buf) {
		return true
	}
	return intrinsics.volatile_load(&f.dead)
}

/*
read takes what is buffered for `end`, parking while there is nothing.

Returns at the first byte rather than the full buffer, which is a pipe's
rule everywhere. A reader that waits for a frame must not park behind bytes
that arrived after it could run. Zero is EOF -- the far end closed and the
ring is empty -- and it is final.
*/
read :: proc "contextless" (p: ^Pipe, end: int, buf: []u8) -> int #no_bounds_check {
	t := &pipes
	f := &p.flows[end & 1]
	if len(buf) == 0 {
		return 0
	}

	for {
		g := sync.acquire(&t.lock)
		if f.used > 0 {
			n := min(f.used, len(buf))
			for i in 0 ..< n {
				buf[i] = f.buf[(f.head + i) % len(f.buf)]
			}
			f.head = (f.head + n) % len(f.buf)
			f.used -= n
			sync.release(&t.lock, g)
			sync.wakeup_all(&f.w)
			return n
		}
		closed := f.closed
		sync.release(&t.lock, g)

		if closed {
			return 0
		}
		sync.sleep(&f.r, flow_readable, f)
	}
}

/*
write moves `data` toward the other end, parking whenever the ring is full.

Returns how many bytes crossed. Short only when the reading end closed
mid-transfer, and zero-with-EPIPE when it was closed before the first byte.
The distinction matters to exactly one caller. A writer that sent half a
frame has a peer that will never see the rest, and `wire.odin` treats both
answers as a broken connection.
*/
write :: proc "contextless" (p: ^Pipe, end: int, data: []u8) -> (n: int, err: vfs.Errno) #no_bounds_check {
	t := &pipes
	f := &p.flows[1 - (end & 1)]

	sent := 0
	for sent < len(data) {
		g := sync.acquire(&t.lock)
		if f.dead {
			sync.release(&t.lock, g)
			return sent, sent == 0 ? vectra9.EPIPE : vfs.OK
		}
		room := len(f.buf) - f.used
		if room > 0 {
			k := min(room, len(data) - sent)
			tail := (f.head + f.used) % len(f.buf)
			for i in 0 ..< k {
				f.buf[(tail + i) % len(f.buf)] = data[sent + i]
			}
			f.used += k
			sent += k
			sync.release(&t.lock, g)
			sync.wakeup_all(&f.r)
			continue
		}
		sync.release(&t.lock, g)
		sync.sleep(&f.w, flow_writable, f)
	}
	return sent, vfs.OK
}

/*
close_end retires one end.

The flow toward the peer stops accepting bytes and reports EOF once drained.
The flow toward this end reports EPIPE to the peer's writes. Every parked
thread on the pipe is woken to re-read those flags.

When the second end goes and no wire was built, the rings go back to the heap
and the slot clears. A pipe with a wire stays, because the wire's reader
thread and every chan a mount handed out still reach through it.
*/
close_end :: proc(p: ^Pipe, end: int) {
	t := &pipes
	e := end & 1

	g := sync.acquire(&t.lock)
	if !live(p) || !p.open[e] {
		sync.release(&t.lock, g)
		return
	}
	p.open[e] = false
	p.flows[1 - e].closed = true // Nothing writes toward the peer any more
	p.flows[e].dead = true // Nothing reads what the peer writes any more

	last := !p.open[0] && !p.open[1]
	reclaim := last && p.server9 == nil
	a, b: []u8
	if reclaim {
		a = p.flows[0].buf
		b = p.flows[1].buf
	}
	sync.release(&t.lock, g)

	for i in 0 ..< 2 {
		sync.wakeup_all(&p.flows[i].r)
		sync.wakeup_all(&p.flows[i].w)
	}

	if reclaim {
		// Nothing can name the pipe now. Both chans are clunked, so no reader or
		// writer can arrive. The woken threads re-check the flags through the
		// rendez conditions, which read flags and not the rings.
		g2 := sync.acquire(&t.lock)
		p^ = Pipe{}
		t.count -= 1
		t.freed += 1
		sync.release(&t.lock, g2)
		delete(a)
		delete(b)
	}
}

// -- The ends as chans -------------------------------------------------------

/*
open_end attaches to the pipe server and returns a chan on one end.

The attach names the end in its aname, `id.end`, which is this package talking
to itself: nothing else can reach the server to attach. One chan per end is
the contract. `spawn` shares that chan by reference, and the end closes when
the last reference clunks it.
*/
open_end :: proc(p: ^Pipe, end: int) -> (^vfs.Chan, vfs.Errno) {
	t := &pipes
	name: [16]u8
	n := format_aname(name[:], p.id, end & 1)
	return vfs.attach(&t.server, string(name[:n]))
}

@(private = "file")
format_aname :: proc "contextless" (buf: []u8, id: i32, end: int) -> int #no_bounds_check {
	digits: [12]u8
	d := 0
	v := u32(id)
	for {
		digits[d] = '0' + u8(v % 10)
		d += 1
		v /= 10
		if v == 0 {
			break
		}
	}
	n := 0
	for d > 0 {
		d -= 1
		buf[n] = digits[d]
		n += 1
	}
	buf[n] = '.'
	buf[n + 1] = '0' + u8(end)
	return n + 2
}

@(private = "file")
parse_aname :: proc "contextless" (aname: string) -> (id: i32, end: int, ok: bool) #no_bounds_check {
	dot := -1
	for i in 0 ..< len(aname) {
		if aname[i] == '.' {
			dot = i
			break
		}
	}
	if dot <= 0 || dot != len(aname) - 2 {
		return 0, 0, false
	}
	v := i32(0)
	for i in 0 ..< dot {
		c := aname[i]
		if c < '0' || c > '9' || v > (max(i32) - 10) / 10 {
			return 0, 0, false
		}
		v = v * 10 + i32(c - '0')
	}
	e := aname[dot + 1]
	if e != '0' && e != '1' {
		return 0, 0, false
	}
	return v, int(e - '0'), true
}

// A fid binds `id * 2 + end`, and a qid carries the same number as its path.
// Ids never come back, so neither do the nodes and paths built from them.

@(private)
node_of :: proc "contextless" (id: i32, end: int) -> i32 {
	return id * 2 + i32(end)
}

@(private = "file")
qid_of :: proc "contextless" (id: i32, end: int) -> vectra9.Qid {
	return vectra9.Qid{path = u64(node_of(id, end))}
}

// chan_pipe reports which pipe end a chan names, or nil for a chan that is
// not one of this package's. The qid is enough: paths here are ids, and ids
// never come back.
chan_pipe :: proc "contextless" (c: ^vfs.Chan) -> (^Pipe, int) {
	t := &pipes
	if c == nil || c.server != &t.server {
		return nil, 0
	}
	node := i32(c.qid.path)
	if node < 2 {
		return nil, 0
	}

	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)
	p := slot_of(t, node / 2)
	if p == nil {
		return nil, 0
	}
	return p, int(node & 1)
}

// -- The handler -------------------------------------------------------------

@(private = "file")
pipe_creates :: proc "contextless" (k: vectra9.Kind) -> bool {
	#partial switch k {
	case .Tlcreate, .Tmkdir, .Tmknod, .Tsymlink, .Tlink, .Trename, .Trenameat, .Tremove:
		return true
	}
	return false
}

/*
pipe_handler answers for the ends.

Synchronous, and the reads and writes park on the caller's own thread. That
is the behaviour a process asks for when it reads an empty pipe. It is legal
here for the reason `lock.odin` states. No vfs lock is held across a
message, so the thread that arrives holds nothing the rest of the machine
waits on.

There is no root to speak of. A fid comes into being bound to an end, through
the aname, and walks nowhere.
*/
@(private = "file")
pipe_handler :: proc "contextless" (
	server: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = s
	_ = tag
	t := cast(^Pipe_Table)server
	if t == nil {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	if pipe_creates(vectra9.kind(request^)) {
		reply^ = vectra9.error_reply(vectra9.EPERM)
		return
	}

	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)

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
		id, end, ok := parse_aname(m.aname)
		if !ok {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		g := sync.acquire(&t.lock)
		p := slot_of(t, id)
		if p == nil || !p.open[end] {
			sync.release(&t.lock, g)
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		if !vfs.fidtab_bind(&t.fids, m.fid, node_of(id, end)) {
			sync.release(&t.lock, g)
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
		sync.release(&t.lock, g)
		reply^ = vectra9.Rattach{qid = qid_of(id, end)}

	case vectra9.Tlopen:
		node := locked_node(t, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		reply^ = vectra9.Rlopen{qid = vectra9.Qid{path = u64(node)}, iounit = 0}

	case vectra9.Tread:
		node := locked_node(t, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		p, end, ok := end_of(t, node)
		if !ok {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		// The park happens here, on the calling thread, with no lock held.
		n := read(p, end, buf[:min(len(buf), int(m.count))])
		reply^ = vectra9.Rread{data = buf[:n]}

	case vectra9.Twrite:
		node := locked_node(t, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		p, end, ok := end_of(t, node)
		if !ok {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		n, err := write(p, end, m.data)
		if err != vfs.OK {
			reply^ = vectra9.error_reply(err)
			return
		}
		reply^ = vectra9.Rwrite{count = u32(n)}

	case vectra9.Tgetattr:
		node := locked_node(t, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & vfs.GETATTR_BASIC,
			qid     = vectra9.Qid{path = u64(node)},
			mode    = S_IFREG | 0o600,
			nlink   = 1,
			blksize = RING_SIZE,
		}

	case vectra9.Tclunk:
		g := sync.acquire(&t.lock)
		node := vfs.fidtab_node(&t.fids, m.fid)
		_ = vfs.fidtab_release(&t.fids, m.fid)
		sync.release(&t.lock, g)
		if node >= 2 {
			p, end, ok := end_of(t, node)
			if ok {
				// `close_end` frees the rings on the last close, which wants
				// an allocator, and a contextless handler arrives without one.
				ctx := runtime.default_context()
				ctx.allocator = mem.allocator()
				context = ctx
				close_end(p, end)
			}
		}
		reply^ = vectra9.Rclunk{}

	case vectra9.Tflush:
		// Nothing is ever pending against a synchronous transport, so the
		// request being flushed has already been answered.
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

@(private = "file")
locked_node :: proc "contextless" (t: ^Pipe_Table, fid: vectra9.Fid) -> i32 {
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)
	return vfs.fidtab_node(&t.fids, fid)
}

@(private = "file")
end_of :: proc "contextless" (t: ^Pipe_Table, node: i32) -> (^Pipe, int, bool) {
	g := sync.acquire(&t.lock)
	defer sync.release(&t.lock, g)
	p := slot_of(t, node / 2)
	if p == nil {
		return nil, 0, false
	}
	return p, int(node & 1), true
}
