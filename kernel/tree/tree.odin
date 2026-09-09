/*
tree -- `#t` at `/dev/tree`, the flattened device tree as files.

`docs/HARDWARE.md` section 3's first thing the kernel does: it knows what is
there. The firmware hands the bootloader a device tree, the bootloader hands it
here, and this publishes it -- a directory per node, a file per property, the
bytes as the tree spells them. `ls /dev/tree` is the hardware inventory, and a
read of a node's `compatible` says which driver to start. The bases
`docs/PORTS.md` section 5 assumes -- the interrupt controller, the UART, the PCIe
window -- are reads of a `reg` file under this, once a driver reads them.

**Read-only, and static.** A tree does not change while the machine runs, so
this is `vfs.static`'s shape exactly: a node table, one row per node and per
property, served with no behaviour behind a file but its bytes. The one nuance
is where the bytes live. The blob is in bootloader-reclaimable memory; so this
copies it to the heap once and points every name and value into the copy, which
outlives the boot the way the images `#b` serves do.

This is arch-neutral: it walks bytes. A machine the bootloader gave no tree --
an x86 PC, which has ACPI instead -- gets no `#t`, and `init` returns without
one. The FDT walk is the same token stream `kernel/arch/riscv64` reads for the
timebase, generalised here to build the whole tree rather than find one value.
*/
package tree

import "base:intrinsics"

import "kernel:arch"
import "kernel:mnt"
import "kernel:sync"
import "kernel:vfs"
import "vsys:vectra9"

// The flattened-tree structure-block tokens, and the header offsets this reads.
@(private)
FDT_MAGIC :: u32(0xD00D_FEED)
@(private)
FDT_BEGIN_NODE :: u32(1)
@(private)
FDT_END_NODE :: u32(2)
@(private)
FDT_PROP :: u32(3)
@(private)
FDT_NOP :: u32(4)
@(private)
FDT_END :: u32(9)

// The deepest the node stack goes. A device tree nests a handful of levels; this
// is generous, and a tree past it is a tree this refuses rather than overruns.
@(private)
MAX_DEPTH :: 32

@(private)
tree_server: vfs.Server
@(private)
tree_static: vfs.Static_Tree
@(private)
node_count: int

// The worker threads `#t` runs on. A read of an `irq` file parks until the line
// fires, and a parked handler on the synchronous transport takes its caller's
// thread down with it -- so `#t` moves onto `kernel/mnt`, where a parked read
// holds one worker and the others still answer property and `mmio` reads. One
// worker per in-flight request, plus one so the flush that unwedges a parked
// read is never itself waiting for a worker.
@(private)
WORKERS :: mnt.MAX_REQUESTS + 1

/*
Mmio is one node's register window, kept beside the node table because a
`Static_Node` has no room for a physical address. `mmio_table[i]` is set for
the synthesized `mmio` file at node index `i`, and left `valid = false` for
every other row. `tree_device` reads it when a program segattaches an `mmio`.
*/
@(private)
Mmio :: struct {
	phys:  uintptr,
	size:  u64,
	valid: bool,
}

@(private)
mmio_table: []Mmio

/*
Irq is one node's interrupt line, beside the node table for the same reason
`Mmio` is: a `Static_Node` has no room for it. `irq_table[i]` is set for the
synthesized `irq` file at node index `i`. A read of that file parks on `ready`
until the line fires; the handler masks the line, acknowledges, counts the fire
and wakes the reader; the next read unmasks. `holders` is the open descriptors,
so the last close masks the line for good.
*/
@(private)
Irq :: struct {
	valid:     bool,
	gsi:       int,   // the shared-line number, from the node's `interrupts`
	intid:     u64,   // the controller id the handler is registered for
	fired:     u64,   // fires the handler has counted
	delivered: u64,   // fires reads have taken
	holders:   int,   // open descriptors on this line's file
	routed:    bool,  // the handler is registered and the line aimed
	ready:     sync.Rendez,
}

@(private)
irq_table: []Irq

/*
on_irq is the handler every device line shares. The dispatch calls it with the
frame naming the id that fired, so it finds the line, masks it at the controller
so a level line does not re-fire before the driver has serviced it,
acknowledges, counts the fire and wakes the parked reader. It runs in interrupt
context; `sync.wakeup` is safe there and it touches nothing else.
*/
@(private)
on_irq :: proc "contextless" (r: arch.Resume) -> arch.Resume #no_bounds_check {
	intid := arch.resume_vector(r)
	for i in 0 ..< len(irq_table) {
		e := &irq_table[i]
		if e.valid && e.routed && e.intid == intid {
			arch.irq_set_mask(e.gsi, true)
			arch.irq_ack()
			intrinsics.volatile_store(&e.fired, intrinsics.volatile_load(&e.fired) + 1)
			sync.wakeup(&e.ready)
			return r
		}
	}
	// No line owns it, which should not happen for an id this registered a
	// handler for. Acknowledge anyway, so the controller is not left with an
	// active line masking every lower priority -- the timer among them.
	arch.irq_ack()
	return r
}

// Irq_Wait is what a parked read waits on: the line, and the tag that names the
// request so the wake can tell a fire from a flush. It lives on the worker's own
// stack while the read is parked, which is exactly as long as the condition is
// dereferenced.
@(private)
Irq_Wait :: struct {
	e:   ^Irq,
	tag: vectra9.Tag,
}

/*
irq_ready is a parked read's wake condition. Two ways out, as `devfs`'s reader
has: the line fired and this reader has not taken it, or the request was flushed
-- the client gave up, or was killed, and `tree_abort` woke every reader to let
the flushed one find its tag here. It runs in interrupt context on the wake, so
it loads and compares and does nothing else.
*/
@(private)
irq_ready :: proc "contextless" (arg: rawptr) -> bool {
	w := (^Irq_Wait)(arg)
	if intrinsics.volatile_load(&w.e.fired) > intrinsics.volatile_load(&w.e.delivered) {
		return true
	}
	return vfs.server_flushed(&tree_server, w.tag)
}

// nodes reports how many directories and property files `#t` serves, for the
// boot line. Zero on a machine the bootloader gave no tree.
nodes :: proc "contextless" () -> int {
	return node_count
}

/*
The lookups a kernel driver makes before the tree is a file to anyone.

`kernel/smmu` runs before ring 3 and asks the three questions a program asks
through `/dev/tree`. Which node is the part, what a property of it says, and
where its registers are. The answers are reads of the same rows, by index
rather than by path. A node's index is the position `walk` gave it, stable for
the life of the machine. Every property of the node is a row whose `parent` is
that index.
*/

// find_compatible answers the index of the first node whose `compatible` names
// `want`. A `compatible` is a list of NUL-separated strings, and any one of them
// matching is a match.
find_compatible :: proc "contextless" (want: string) -> (idx: int, ok: bool) #no_bounds_check {
	rows := tree_static.nodes
	for i in 0 ..< len(rows) {
		r := &rows[i]
		if r.dir || r.name != "compatible" || r.parent < 0 {
			continue
		}
		v := r.data
		start := 0
		for j in 0 ..< len(v) {
			if v[j] == 0 {
				if v[start:j] == want {
					return int(r.parent), true
				}
				start = j + 1
			}
		}
		if start < len(v) && v[start:] == want {
			return int(r.parent), true
		}
	}
	return -1, false
}

// property answers the bytes of a node's property, as the tree spells them.
property :: proc "contextless" (node: int, name: string) -> (v: string, ok: bool) #no_bounds_check {
	rows := tree_static.nodes
	for i in 0 ..< len(rows) {
		r := &rows[i]
		if !r.dir && int(r.parent) == node && r.name == name {
			return r.data, true
		}
	}
	return "", false
}

// window answers a node's register window, the same one its `mmio` file names.
window :: proc "contextless" (node: int) -> (phys: uintptr, size: u64, ok: bool) #no_bounds_check {
	rows := tree_static.nodes
	for i in 0 ..< len(rows) {
		r := &rows[i]
		if !r.dir && int(r.parent) == node && r.name == "mmio" && i < len(mmio_table) && mmio_table[i].valid {
			return mmio_table[i].phys, mmio_table[i].size, true
		}
	}
	return 0, 0, false
}

// cell reads the `n`th big-endian 32-bit cell of a property value, or zero past
// its end.
cell :: proc "contextless" (v: string, n: int) -> u32 #no_bounds_check {
	at := n * 4
	if at < 0 || at + 4 > len(v) {
		return 0
	}
	return u32(v[at]) << 24 | u32(v[at + 1]) << 16 | u32(v[at + 2]) << 8 | u32(v[at + 3])
}

@(private)
be32 :: proc "contextless" (b: []u8, at: int) -> u32 #no_bounds_check {
	return u32(b[at]) << 24 | u32(b[at + 1]) << 16 | u32(b[at + 2]) << 8 | u32(b[at + 3])
}

// cstr_len is the length of a NUL-terminated string in the blob at `at`, not
// counting the NUL, bounded by the blob's end.
@(private)
cstr_len :: proc "contextless" (b: []u8, at: int) -> int #no_bounds_check {
	n := 0
	for at + n < len(b) && b[at + n] != 0 {
		n += 1
	}
	return n
}

@(private)
align4 :: proc "contextless" (x: int) -> int {
	return (x + 3) & ~int(3)
}

// A node while the walk is inside it: its index, and the cell counts it sets
// for the addresses and sizes of its own children's `reg`. The defaults are
// the device-tree spec's when a node names neither.
@(private)
Frame :: struct {
	idx: int,
	ac:  int,
	sc:  int,
}

// decode_reg reads the first `reg` tuple -- `ac` address cells then `sc` size
// cells, big-endian -- into a base and a size. It answers false for cells it
// cannot hold in 64 bits or a value too short for one tuple. Nested buses with
// `ranges` are not translated; the `virt` platform devices are the root's own
// children, so there is nothing to translate for step 0.
@(private)
decode_reg :: proc "contextless" (v: []u8, ac: int, sc: int) -> (base: u64, size: u64, ok: bool) #no_bounds_check {
	if ac < 1 || ac > 2 || sc < 0 || sc > 2 {
		return 0, 0, false
	}
	if len(v) < (ac + sc) * 4 {
		return 0, 0, false
	}
	at := 0
	for _ in 0 ..< ac {
		base = base << 32 | u64(be32(v, at))
		at += 4
	}
	for _ in 0 ..< sc {
		size = size << 32 | u64(be32(v, at))
		at += 4
	}
	return base, size, true
}

/*
walk reads the structure block and either counts the rows or fills them. One
walk serves both passes: called with empty slices it returns the count, and
called with slices of that size it writes each row and each window. The two runs
assign the same index in the same order, so a property's `parent` set in the
fill is the index the same node took in the count.

A node is a directory whose parent is the node on top of the stack; the first,
the tree's own root with no name, becomes `/` with no parent. A property is a
file under the node on top of the stack, its bytes a slice of the blob. And a
node with a `reg` grows one more file, a synthesized `mmio`, whose window
`decode_reg` reads from that `reg` with the node's *parent* cell counts -- the
one file the kernel adds, not the firmware, and the one a driver segattaches.
*/
@(private)
walk :: proc "contextless" (blob: []u8, out: []vfs.Static_Node, mtab: []Mmio, itab: []Irq) -> int #no_bounds_check {
	if len(blob) < 40 || be32(blob, 0) != FDT_MAGIC {
		return 0
	}
	struct_off := int(be32(blob, 8))
	strings_off := int(be32(blob, 12))
	struct_size := int(be32(blob, 36))

	stack: [MAX_DEPTH]Frame
	sp := 0
	count := 0

	at := struct_off
	end := struct_off + struct_size
	if end > len(blob) {
		end = len(blob)
	}
	for at + 4 <= end {
		token := be32(blob, at)
		at += 4
		switch token {
		case FDT_BEGIN_NODE:
			name_at := at
			n := cstr_len(blob, name_at)
			at = align4(name_at + n + 1)
			idx := count
			count += 1
			parent := sp > 0 ? stack[sp - 1].idx : -1
			name := sp == 0 ? "/" : string(blob[name_at:name_at + n])
			if idx < len(out) {
				out[idx] = vfs.Static_Node{name = name, parent = i32(parent), dir = true}
			}
			if sp < MAX_DEPTH {
				// Two and two are the spec's defaults until a `#*-cells` says
				// otherwise, which arrives as a property below.
				stack[sp] = Frame{idx = idx, ac = 2, sc = 2}
				sp += 1
			}
		case FDT_END_NODE:
			if sp > 0 {
				sp -= 1
			}
		case FDT_PROP:
			length := int(be32(blob, at))
			name_off := int(be32(blob, at + 4))
			value_at := at + 8
			at = align4(value_at + length)
			vend := value_at + length
			if vend > len(blob) {
				vend = value_at
			}
			pn := cstr_len(blob, strings_off + name_off)
			pname := string(blob[strings_off + name_off:strings_off + name_off + pn])

			idx := count
			count += 1
			parent := sp > 0 ? stack[sp - 1].idx : -1
			if idx < len(out) {
				out[idx] = vfs.Static_Node {
					name   = pname,
					parent = i32(parent),
					data   = string(blob[value_at:vend]),
				}
			}

			// A node names the cell counts for its own children here.
			if sp > 0 && length == 4 {
				if pname == "#address-cells" {
					stack[sp - 1].ac = int(be32(blob, value_at))
				} else if pname == "#size-cells" {
					stack[sp - 1].sc = int(be32(blob, value_at))
				}
			}

			// A `reg` grows the node a synthesized `mmio`, decoded with the
			// parent's cell counts. The root, which has no parent, has no bus
			// address and so no window.
			if sp >= 2 && pname == "reg" {
				pac := stack[sp - 2].ac
				psc := stack[sp - 2].sc
				if base, size, rok := decode_reg(blob[value_at:vend], pac, psc); rok && size > 0 {
					midx := count
					count += 1
					if midx < len(out) {
						out[midx] = vfs.Static_Node{name = "mmio", parent = i32(stack[sp - 1].idx)}
					}
					if midx < len(mtab) {
						mtab[midx] = Mmio{phys = uintptr(base), size = size, valid = true}
					}
				}
			}

			// A shared interrupt grows the node an `irq` file. The `interrupts`
			// property is cells of `<type intid flags>`; type 0 is a shared
			// peripheral line, whose controller id is the base plus the number.
			// A per-core line (type 1, the timer's kind) is not a device's to
			// take, so it grows no file.
			if sp > 0 && pname == "interrupts" && length >= 12 {
				itype := be32(blob, value_at)
				icell := be32(blob, value_at + 4)
				if itype == 0 {
					iidx := count
					count += 1
					if iidx < len(out) {
						out[iidx] = vfs.Static_Node{name = "irq", parent = i32(stack[sp - 1].idx)}
					}
					if iidx < len(itab) {
						itab[iidx] = Irq {
							valid = true,
							gsi   = int(icell),
							intid = u64(arch.VECTOR_IRQ_BASE) + u64(icell),
						}
					}
				}
			}
		case FDT_NOP:
		case FDT_END:
			return count
		case:
			return count
		}
	}
	return count
}

/*
tree_device answers a segattach of an `mmio` file: the register window the node's
`reg` named, as device memory. Every other file in the tree is a stream of bytes
and answers no.
*/
@(private)
tree_device :: proc "contextless" (sv: ^vfs.Server, qid: vectra9.Qid) -> (phys: uintptr, bytes: u64, device_mem: bool, ok: bool) #no_bounds_check {
	_ = sv
	node := int(qid.path) - 1
	if node < 0 || node >= len(mmio_table) || !mmio_table[node].valid {
		return 0, 0, false, false
	}
	return mmio_table[node].phys, mmio_table[node].size, true, true
}

/*
tree_handler serves the tree. The property files, the directories and the `mmio`
device are `vfs.static_handler`'s and the device hook's; this adds the one file
with behaviour, the `irq` stream. It handles a `Tlopen`, `Tread` and `Tclunk` on
an `irq` fid itself -- arming the line, parking the read, masking on the last
close -- and hands every other message to `static_handler`.

It never holds `tree_static.lock` across a park: `irq_of` takes it only to read
the fid's node, and the read then sleeps outside any lock. The park is on a
`kernel/mnt` worker thread, not the caller's -- `#t` runs worker-backed for
exactly this, so a parked read holds one worker and the rest keep answering.
*/
@(private)
tree_handler :: proc "contextless" (server: rawptr, s: ^vectra9.Session, tag: vectra9.Tag, request: ^vectra9.Msg, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	#partial switch m in request^ {
	case vectra9.Tlopen:
		if e := irq_of(m.fid); e != nil {
			tree_irq_arm(e)
		}
	case vectra9.Tread:
		if e := irq_of(m.fid); e != nil {
			tree_irq_read(e, tag, buf, reply)
			return
		}
	case vectra9.Tclunk:
		if e := irq_of(m.fid); e != nil {
			tree_irq_disarm(e)
		}
	}
	vfs.static_handler(&tree_static, s, tag, request, reply, buf)
}

// irq_of is the line a fid names, or nil for a fid on any other file.
@(private)
irq_of :: proc "contextless" (fid: vectra9.Fid) -> ^Irq #no_bounds_check {
	g := sync.acquire(&tree_static.lock)
	defer sync.release(&tree_static.lock, g)
	node := vfs.fidtab_node(&tree_static.fids, fid)
	if node >= 0 && int(node) < len(irq_table) && irq_table[node].valid {
		return &irq_table[node]
	}
	return nil
}

// tree_irq_arm registers the handler and aims the line on the first open, and
// counts the holder. The line stays masked; a read is what unmasks it.
@(private)
tree_irq_arm :: proc "contextless" (e: ^Irq) {
	g := sync.acquire(&tree_static.lock)
	defer sync.release(&tree_static.lock, g)
	if e.holders == 0 {
		arch.set_interrupt_handler(int(e.intid), on_irq)
		arch.irq_route(e.gsi, arch.irq_vector_of(e.gsi), 0)
		e.routed = true
		e.delivered = intrinsics.volatile_load(&e.fired)
	}
	e.holders += 1
}

// tree_irq_disarm drops a holder and masks the line for good on the last close,
// the property `docs/HARDWARE.md` section 3 keeps: a line with nobody to unmask
// it stays masked, so a reader that goes away cannot storm the machine.
@(private)
tree_irq_disarm :: proc "contextless" (e: ^Irq) {
	g := sync.acquire(&tree_static.lock)
	defer sync.release(&tree_static.lock, g)
	if e.holders > 0 {
		e.holders -= 1
	}
	if e.holders == 0 {
		arch.irq_set_mask(e.gsi, true)
		e.routed = false
	}
}

/*
tree_irq_read unmasks the line and parks until it fires, then answers the count
of fires taken. It runs on a `kernel/mnt` worker, so the way out of the park is
not a note to the caller's thread but a flush: the client gives up or dies, the
transport sets the flushed bit and `tree_abort` wakes the reader, which finds
its tag flushed and answers EINTR. The reply of a flushed request is dropped, so
the fire it would have reported is left uncounted for the read that follows.

The flush is tested before the count is taken, and the order is the same one
`devfs` keeps: a fire taken into a flushed reply is a fire handed to nobody.
*/
@(private)
tree_irq_read :: proc "contextless" (e: ^Irq, tag: vectra9.Tag, buf: []u8, reply: ^vectra9.Msg) #no_bounds_check {
	arch.irq_set_mask(e.gsi, false)
	w := Irq_Wait{e = e, tag = tag}
	for {
		if vfs.server_flushed(&tree_server, tag) {
			reply^ = vectra9.error_reply(vectra9.EINTR)
			return
		}
		fired := intrinsics.volatile_load(&e.fired)
		if fired > intrinsics.volatile_load(&e.delivered) {
			n := fired - intrinsics.volatile_load(&e.delivered)
			intrinsics.volatile_store(&e.delivered, fired)
			at := put_uint(buf, n)
			if at < len(buf) {
				buf[at] = '\n'
				at += 1
			}
			reply^ = vectra9.Rread{data = buf[:at]}
			return
		}
		sync.sleep(&e.ready, irq_ready, &w)
	}
}

// put_uint writes an unsigned decimal into a buffer and answers its length.
@(private)
put_uint :: proc "contextless" (b: []u8, v: u64) -> int #no_bounds_check {
	if len(b) == 0 {
		return 0
	}
	if v == 0 {
		b[0] = '0'
		return 1
	}
	tmp: [20]u8
	n := 0
	x := v
	for x > 0 {
		tmp[n] = u8('0' + x % 10)
		x /= 10
		n += 1
	}
	out := 0
	for i := n - 1; i >= 0 && out < len(b); i -= 1 {
		b[out] = tmp[i]
		out += 1
	}
	return out
}

/*
tree_abort is the transport's flush hook. It cannot know which line the flushed
read was parked on -- a rendezvous, not a tag, is what a sleeper waits on -- so
it wakes every line's readers, and each re-tests its own condition: the one that
was flushed finds its tag set and leaves, the rest find neither a fire nor a
flush and park again. It runs in interrupt context, where `wakeup_all` is safe.
*/
@(private)
tree_abort :: proc "contextless" (server: rawptr, tag: vectra9.Tag) {
	_ = server
	_ = tag
	for i in 0 ..< len(irq_table) {
		if irq_table[i].valid {
			sync.wakeup_all(&irq_table[i].ready)
		}
	}
}

/*
init builds `#t` from the blob the bootloader gave and binds it at `/dev/tree`.
A nil blob -- a machine with no device tree -- is not a failure: it returns OK
having published nothing, and there is simply no `/dev/tree`.

The blob is copied to the heap, because it lives in memory the bootloader may
reclaim; the copy outlives the machine, as every name and value points into it.
*/
init :: proc(ns: ^vfs.Namespace, dtb: rawptr) -> vfs.Errno {
	if dtb == nil {
		return vfs.OK
	}
	// The blob's own size, from its header, and a heap copy of exactly that.
	src := ([^]u8)(dtb)
	if u32(src[0]) << 24 | u32(src[1]) << 16 | u32(src[2]) << 8 | u32(src[3]) != FDT_MAGIC {
		return vfs.OK
	}
	total := int(u32(src[4]) << 24 | u32(src[5]) << 16 | u32(src[6]) << 8 | u32(src[7]))
	if total < 40 {
		return vfs.OK
	}
	blob := make([]u8, total)
	if blob == nil {
		return vectra9.ENOMEM
	}
	for i in 0 ..< total {
		blob[i] = src[i]
	}

	count := walk(blob, nil, nil, nil)
	if count <= 0 {
		delete(blob)
		return vfs.OK
	}
	rows := make([]vfs.Static_Node, count)
	mtab := make([]Mmio, count)
	itab := make([]Irq, count)
	if rows == nil || mtab == nil || itab == nil {
		delete(blob)
		return vectra9.ENOMEM
	}
	_ = walk(blob, rows, mtab, itab)
	node_count = count
	mmio_table = mtab
	irq_table = itab

	if !vfs.static_init(&tree_static, "tree", rows) {
		return vectra9.ENOMEM
	}
	// `tree_handler` wraps `static_handler`: the property reads and the mmio
	// device are its and the hook's, and the `irq` stream is the one file with
	// behaviour of its own. See `docs/HARDWARE.md` section 3.
	if err := vfs.server_init(&tree_server, "t", tree_handler, &tree_static); err != .None {
		return vectra9.EPROTO
	}
	tree_server.device = tree_device
	// Worker-backed, so a read parked on an `irq` file holds one worker rather
	// than wedging every property and `mmio` read behind it. `server_start`
	// comes before `register_device`, so nothing reaches this server while it is
	// still on its own stack -- the same order `devfs` keeps, and for the same
	// reason: the synchronous transport hands a parked handler no way back.
	if !vfs.server_start(&tree_server, WORKERS, 0, tree_abort) {
		return vectra9.ENOMEM
	}
	if !vfs.register_device(&tree_server) {
		vfs.server_stop(&tree_server)
		return vectra9.EEXIST
	}
	return vfs.mount_device(ns, "#t", "/dev/tree")
}
