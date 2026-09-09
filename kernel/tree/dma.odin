/*
The `dma` file: a device's walker, bound to a process by a line written to it.
`docs/SMMU.md` section 6.

A node grows a `dma` file when the tree gives it a walker. That is an `iommus`
property naming the SMMU and a stream, or an `iommu-map` on a PCI host naming
a range of them. Only the SMMU the kernel drives counts. The file is a stream
in the shape of `irq`, and it takes writes.

**Write.** `attach <slot> <pid>` binds the slot's stream to that process's
space, and `detach <slot>` aborts the stream and forgets the binding. A slot
is a requester id on a PCI host, or zero for a device with one `iommus`
entry. The line is a capability, section 7: it is refused unless the target
process is the writer itself or holds a file the writer serves.

**Read.** A read parks until the node has a line, and answers one. `fault
<slot> <type> <address> <read|write>` is a record off the event queue.
`detached <slot> exit` is an attach whose process ended or exec'd, which
nothing else tells the driver. `broken` is the walker taking a global error.

**Close.** The last close of a node's file detaches every slot bound through
it. A driver that dies takes its device's mastery with it.

The ring holds sixteen lines. A fault past the sixteenth while nobody reads is
dropped and counted, and the count rides on the next line as `dropped N`. A
ring rather than a queue that grows, because the sink runs where nothing may
allocate.

**Locks.** `Dma.lock` is taken under `space.lock` and the walker's own lock,
when the SMMU reports an orphan. So nothing under `Dma.lock` may call into
`kernel/smmu` or `kernel/mem`. An attach or detach calls the walker with the
lock dropped, and reserves its binding first so a second writer finds the
slot busy.
*/
package tree

import "base:intrinsics"

import "kernel:smmu"
import "kernel:sync"
import "kernel:user"
import "kernel:vfs"
import "vsys:vectra9"

@(private) RING :: 16
@(private) LINE :: 96
@(private) BINDS :: 8

@(private)
Line :: struct {
	text: [LINE]u8,
	n:    int,
}

// One slot bound through this file: the walker's handle for it, and the pid
// it was bound to.
@(private)
Bind :: struct {
	used:   bool,
	slot:   u32,
	handle: int,
	pid:    u64,
}

/*
Dma is one node's walker, beside the node table for the reason `Irq` is.
`single` is an `iommus` node: one slot, zero, one stream. Otherwise the node
is a PCI host with an `iommu-map`, and a slot in `[rid_base, rid_base +
length)` is the stream `sid_base + (slot - rid_base)`.
*/
@(private)
Dma :: struct {
	valid:    bool,
	single:   bool,
	stream:   u32,
	rid_base: u32,
	sid_base: u32,
	length:   u32,

	lock:     sync.Spinlock,
	ready:    sync.Rendez,
	ring:     [RING]Line,
	head:     int,
	count:    int,
	dropped:  u64,
	binds:    [BINDS]Bind,
	holders:  int,
	faults:   u64,
}

@(private)
dma_table: []Dma

// Faults naming a stream no node maps, which a broken descriptor could
// produce. They go to nobody's ring, and the count is here for a self-test.
@(private)
stray_faults: u64

// dma_of is the walker a fid names, or nil for a fid on any other file.
@(private)
dma_of :: proc "contextless" (fid: vectra9.Fid) -> (^Dma, i32) #no_bounds_check {
	g := sync.acquire(&tree_static.lock)
	defer sync.release(&tree_static.lock, g)
	node := vfs.fidtab_node(&tree_static.fids, fid)
	if node >= 0 && int(node) < len(dma_table) && dma_table[node].valid {
		return &dma_table[node], node
	}
	return nil, -1
}

// stream_of turns a slot into a stream, or answers false for a slot the map
// does not cover.
@(private)
stream_of :: proc "contextless" (d: ^Dma, slot: u32) -> (u32, bool) {
	if d.single {
		return d.stream, slot == 0
	}
	if slot < d.rid_base || slot - d.rid_base >= d.length {
		return 0, false
	}
	stream := d.sid_base + (slot - d.rid_base)
	return stream, stream < smmu.stream_count()
}

// slot_of is the reverse, for a fault's line.
@(private)
slot_of_stream :: proc "contextless" (d: ^Dma, stream: u32) -> (u32, bool) {
	if d.single {
		return 0, stream == d.stream
	}
	if stream < d.sid_base || stream - d.sid_base >= d.length {
		return 0, false
	}
	return d.rid_base + (stream - d.sid_base), true
}

// -- The ring ------------------------------------------------------------------------

// A line under construction, on the caller's stack.
@(private)
Text :: struct {
	b: [LINE]u8,
	n: int,
}

@(private)
text_str :: proc "contextless" (t: ^Text, s: string) #no_bounds_check {
	for i in 0 ..< len(s) {
		if t.n >= LINE {
			return
		}
		t.b[t.n] = s[i]
		t.n += 1
	}
}

@(private)
text_uint :: proc "contextless" (t: ^Text, v: u64) {
	if t.n < LINE {
		t.n += put_uint(t.b[t.n:], v)
	}
}

@(private)
text_hex :: proc "contextless" (t: ^Text, v: u64) #no_bounds_check {
	text_str(t, "0x")
	digits: [16]u8
	n := 0
	x := v
	for {
		d := u8(x & 0xF)
		digits[n] = d < 10 ? '0' + d : 'a' + d - 10
		n += 1
		x >>= 4
		if x == 0 {
			break
		}
	}
	for i := n - 1; i >= 0 && t.n < LINE; i -= 1 {
		t.b[t.n] = digits[i]
		t.n += 1
	}
}

// push appends a line to the ring and wakes the readers, or drops it and
// counts. With `d.lock` held.
@(private)
push :: proc "contextless" (d: ^Dma, t: ^Text) #no_bounds_check {
	if d.count == RING {
		d.dropped += 1
		return
	}
	if d.dropped > 0 {
		text_str(t, " dropped ")
		text_uint(t, d.dropped)
		d.dropped = 0
	}
	if t.n < LINE {
		t.b[t.n] = '\n'
		t.n += 1
	}
	at := (d.head + d.count) % RING
	d.ring[at].text = t.b
	d.ring[at].n = t.n
	d.count += 1
	sync.wakeup_all(&d.ready)
}

/*
on_event is the walker's sink, `smmu.Sink`. A fault goes to the ring of the
node whose map covers its stream. Its line names the slot, the type by its
specification name, the address and the direction. An orphan goes to the
node holding the bind, as `detached <slot> exit`, and the bind stays until
the program gives it back. A global error goes to every node as `broken`.
In interrupt context, or under the walker's locks: the ring's lock and a
wake, nothing more.
*/
@(private)
on_event :: proc "contextless" (e: smmu.Event) #no_bounds_check {
	switch e.kind {
	case .Fault:
		for i in 0 ..< len(dma_table) {
			d := &dma_table[i]
			if !d.valid {
				continue
			}
			slot, covered := slot_of_stream(d, e.stream)
			if !covered {
				continue
			}
			t: Text
			text_str(&t, "fault ")
			text_uint(&t, u64(slot))
			text_str(&t, " ")
			text_str(&t, smmu.fault_name(e.fault))
			text_str(&t, " ")
			text_hex(&t, e.addr)
			text_str(&t, e.write ? " write" : " read")
			g := sync.acquire(&d.lock)
			d.faults += 1
			push(d, &t)
			sync.release(&d.lock, g)
			return
		}
		intrinsics.atomic_add(&stray_faults, 1)
	case .Orphaned:
		for i in 0 ..< len(dma_table) {
			d := &dma_table[i]
			if !d.valid {
				continue
			}
			g := sync.acquire(&d.lock)
			for b in 0 ..< BINDS {
				if d.binds[b].used && d.binds[b].handle == e.handle {
					t: Text
					text_str(&t, "detached ")
					text_uint(&t, u64(d.binds[b].slot))
					text_str(&t, " exit")
					push(d, &t)
					sync.release(&d.lock, g)
					return
				}
			}
			sync.release(&d.lock, g)
		}
	case .Broken:
		for i in 0 ..< len(dma_table) {
			d := &dma_table[i]
			if !d.valid {
				continue
			}
			t: Text
			text_str(&t, "broken")
			g := sync.acquire(&d.lock)
			push(d, &t)
			sync.release(&d.lock, g)
		}
	}
}

// -- The file ---------------------------------------------------------------------------

// tree_dma_open answers the open itself, because the static tree would refuse
// a writable one. A holder is counted per open, and the last close lets go.
@(private)
tree_dma_open :: proc "contextless" (d: ^Dma, node: i32, fid: vectra9.Fid, reply: ^vectra9.Msg) {
	vfs.fidtab_set_open(&tree_static.fids, fid, true)
	g := sync.acquire(&d.lock)
	d.holders += 1
	sync.release(&d.lock, g)
	reply^ = vectra9.Rlopen{qid = vfs.static_node_qid(&tree_static, node), iounit = 0}
}

// tree_dma_close drops a holder for a fid that was opened, and on the last
// one detaches every slot bound through the file.
@(private)
tree_dma_close :: proc "contextless" (d: ^Dma, fid: vectra9.Fid) {
	if !vfs.fidtab_is_open(&tree_static.fids, fid) {
		return
	}
	g := sync.acquire(&d.lock)
	if d.holders > 0 {
		d.holders -= 1
	}
	last := d.holders == 0
	sync.release(&d.lock, g)
	if last {
		detach_all(d)
	}
}

@(private)
detach_all :: proc "contextless" (d: ^Dma) {
	for {
		handle := -1
		g := sync.acquire(&d.lock)
		for b in 0 ..< BINDS {
			if d.binds[b].used {
				handle = d.binds[b].handle
				d.binds[b].used = false
				break
			}
		}
		sync.release(&d.lock, g)
		if handle < 0 {
			return
		}
		_ = smmu.detach(handle)
	}
}

/*
A word off a line: decimal digits, ended by a space, a newline or the end.
Answers false for no digits or for anything else in the way.
*/
@(private)
word_uint :: proc "contextless" (line: []u8, at: ^int) -> (v: u64, ok: bool) #no_bounds_check {
	for at^ < len(line) && line[at^] == ' ' {
		at^ += 1
	}
	start := at^
	for at^ < len(line) && line[at^] >= '0' && line[at^] <= '9' {
		v = v * 10 + u64(line[at^] - '0')
		at^ += 1
	}
	if at^ == start {
		return 0, false
	}
	if at^ < len(line) && line[at^] != ' ' && line[at^] != '\n' {
		return 0, false
	}
	return v, true
}

@(private)
word_is :: proc "contextless" (line: []u8, at: ^int, want: string) -> bool #no_bounds_check {
	for at^ < len(line) && line[at^] == ' ' {
		at^ += 1
	}
	if at^ + len(want) > len(line) || string(line[at^:at^ + len(want)]) != want {
		return false
	}
	end := at^ + len(want)
	if end < len(line) && line[end] != ' ' && line[end] != '\n' {
		return false
	}
	at^ = end
	return true
}

@(private)
line_end :: proc "contextless" (line: []u8, at: int) -> bool #no_bounds_check {
	for i in at ..< len(line) {
		if line[i] != ' ' && line[i] != '\n' {
			return false
		}
	}
	return true
}

/*
tree_dma_write is the `ctl` convention, `docs/DEVFS.md`: one line, two or
three words, and an errno for every way it can be wrong, section 6's table.
The writer is the thread the transport's slot remembers, turned into a pid.
A request the kernel sent itself has none and is refused, since the kernel
attaches nothing on a program's behalf.
*/
@(private)
tree_dma_write :: proc "contextless" (d: ^Dma, tag: vectra9.Tag, line: []u8, reply: ^vectra9.Msg) #no_bounds_check {
	at := 0
	switch {
	case word_is(line, &at, "attach"):
		slot, sok := word_uint(line, &at)
		pid, pok := word_uint(line, &at)
		if !sok || !pok || !line_end(line, at) {
			reply^ = vectra9.error_reply(vectra9.EINVAL)
			return
		}
		reply^ = attach(d, tag, slot, pid, len(line))
	case word_is(line, &at, "detach"):
		slot, sok := word_uint(line, &at)
		if !sok || !line_end(line, at) {
			reply^ = vectra9.error_reply(vectra9.EINVAL)
			return
		}
		reply^ = detach(d, slot, len(line))
	case:
		reply^ = vectra9.error_reply(vectra9.EINVAL)
	}
}

@(private)
attach :: proc "contextless" (d: ^Dma, tag: vectra9.Tag, slot64: u64, pid: u64, count: int) -> vectra9.Msg #no_bounds_check {
	if slot64 > u64(max(u32)) {
		return vectra9.error_reply(vectra9.EINVAL)
	}
	slot := u32(slot64)
	stream, covered := stream_of(d, slot)
	if !covered {
		return vectra9.error_reply(vectra9.EINVAL)
	}
	if !smmu.present() {
		return vectra9.error_reply(vectra9.ENXIO)
	}
	if smmu.broken() {
		return vectra9.error_reply(vectra9.EIO)
	}
	writer := user.pid_of_thread(vfs.server_requester(&tree_server, tag))
	if writer == 0 || (pid != writer && !user.holds_server_of(pid, writer)) {
		return vectra9.error_reply(vectra9.EPERM)
	}

	// Reserve the binding first, so a second attach of the slot through this
	// file is busy from here rather than from the walker's answer.
	b := -1
	{
		g := sync.acquire(&d.lock)
		defer sync.release(&d.lock, g)
		for i in 0 ..< BINDS {
			if d.binds[i].used && d.binds[i].slot == slot {
				return vectra9.error_reply(vectra9.EBUSY)
			}
			if !d.binds[i].used && b < 0 {
				b = i
			}
		}
		if b < 0 {
			return vectra9.error_reply(vectra9.ENOMEM)
		}
		d.binds[b] = Bind{used = true, slot = slot, handle = -1, pid = pid}
	}

	space := user.hold_space(pid)
	if space == nil {
		unbind(d, b)
		return vectra9.error_reply(vectra9.ESRCH)
	}
	handle, err := smmu.attach(stream, space)
	user.release_space(pid)
	if err != .None {
		unbind(d, b)
		switch err {
		case .None:
		case .Busy:
			return vectra9.error_reply(vectra9.EBUSY)
		case .No_Memory:
			return vectra9.error_reply(vectra9.ENOMEM)
		case .Broken:
			return vectra9.error_reply(vectra9.EIO)
		case .Not_Present:
			return vectra9.error_reply(vectra9.ENXIO)
		case .Bad_Stream, .Bad_Handle:
			return vectra9.error_reply(vectra9.EINVAL)
		}
	}
	g := sync.acquire(&d.lock)
	d.binds[b].handle = handle
	sync.release(&d.lock, g)
	return vectra9.Rwrite{count = u32(count)}
}

@(private)
unbind :: proc "contextless" (d: ^Dma, b: int) {
	g := sync.acquire(&d.lock)
	d.binds[b].used = false
	sync.release(&d.lock, g)
}

@(private)
detach :: proc "contextless" (d: ^Dma, slot64: u64, count: int) -> vectra9.Msg #no_bounds_check {
	if slot64 > u64(max(u32)) {
		return vectra9.error_reply(vectra9.EINVAL)
	}
	slot := u32(slot64)
	handle := -1
	{
		g := sync.acquire(&d.lock)
		defer sync.release(&d.lock, g)
		for i in 0 ..< BINDS {
			if d.binds[i].used && d.binds[i].slot == slot {
				if d.binds[i].handle < 0 {
					// An attach of this slot is still in flight.
					return vectra9.error_reply(vectra9.EBUSY)
				}
				handle = d.binds[i].handle
				d.binds[i].used = false
				break
			}
		}
	}
	if handle < 0 {
		return vectra9.error_reply(vectra9.EINVAL)
	}
	if smmu.detach(handle) == .Broken {
		return vectra9.error_reply(vectra9.EIO)
	}
	return vectra9.Rwrite{count = u32(count)}
}

// Dma_Wait is what a parked read waits on, as `Irq_Wait` is. The ring and
// the tag, so the wake can tell a line from a flush.
@(private)
Dma_Wait :: struct {
	d:   ^Dma,
	tag: vectra9.Tag,
}

@(private)
dma_ready :: proc "contextless" (arg: rawptr) -> bool {
	w := (^Dma_Wait)(arg)
	if intrinsics.volatile_load(&w.d.count) > 0 {
		return true
	}
	return vfs.server_flushed(&tree_server, w.tag)
}

// tree_dma_read parks until the ring has a line and answers one, the way
// `tree_irq_read` parks: a flush is the way out, and answers EINTR.
@(private)
tree_dma_read :: proc "contextless" (d: ^Dma, tag: vectra9.Tag, buf: []u8, reply: ^vectra9.Msg) #no_bounds_check {
	w := Dma_Wait{d = d, tag = tag}
	for {
		if vfs.server_flushed(&tree_server, tag) {
			reply^ = vectra9.error_reply(vectra9.EINTR)
			return
		}
		g := sync.acquire(&d.lock)
		if d.count > 0 {
			l := &d.ring[d.head]
			n := min(l.n, len(buf))
			for i in 0 ..< n {
				buf[i] = l.text[i]
			}
			d.head = (d.head + 1) % RING
			d.count -= 1
			sync.release(&d.lock, g)
			reply^ = vectra9.Rread{data = buf[:n]}
			return
		}
		sync.release(&d.lock, g)
		sync.sleep(&d.ready, dma_ready, &w)
	}
}

// -- For a self-test -----------------------------------------------------------------------

// dma_files answers how many nodes grew a `dma` file.
dma_files :: proc "contextless" () -> (n: int) {
	for i in 0 ..< len(dma_table) {
		if dma_table[i].valid {
			n += 1
		}
	}
	return n
}

// dma_stray answers the faults that named a stream no node maps.
dma_stray :: proc "contextless" () -> u64 {
	return intrinsics.atomic_load(&stray_faults)
}
