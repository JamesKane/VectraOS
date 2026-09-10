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
import "kernel:smmu"
import "kernel:sync"
import "kernel:vfs"
import "vsys:libodin"
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
`Mmio` is: a `Static_Node` has no room for it. `irq_index[i]` names the entry
in `irq_table` for the synthesized `irq` file at node index `i`, and is -1 for
every other row. So the table holds one entry per line rather than one per
row. A read of that file parks on `ready` until the line fires; the handler
masks the line, acknowledges, counts the fire and wakes the reader; the next
read unmasks. `holders` is the open descriptors, so the last close masks the
line for good.
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
irq_index: []i32
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
		if compatible_matches(r.data, want) {
			return int(r.parent), true
		}
	}
	return -1, false
}

// compatible_matches answers whether a `compatible` value, a list of
// NUL-separated strings, names `want` in any of them.
@(private)
compatible_matches :: proc "contextless" (v: string, want: string) -> bool #no_bounds_check {
	start := 0
	for j in 0 ..< len(v) {
		if v[j] == 0 {
			if v[start:j] == want {
				return true
			}
			start = j + 1
		}
	}
	return start < len(v) && v[start:] == want
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
	return be32(transmute([]u8)v, at)
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

// -- The token stream ----------------------------------------------------------

// A cursor over the structure block, which the three walks below share. `at`
// is the next token, `end` the block's end bounded by the blob, and `strings`
// the strings block a property's name is an offset into.
@(private)
Fdt_Cursor :: struct {
	blob:    []u8,
	at:      int,
	end:     int,
	strings: int,
}

// A token off the stream. A node carries its name. A property carries its
// name, its value's offset, and its length as the blob says it. That length
// may run past the blob, and is the caller's to bound.
@(private)
Fdt_Token :: struct {
	kind:     u32,
	name:     string,
	value_at: int,
	length:   int,
}

// fdt_open checks the header and answers a cursor at the first token.
@(private)
fdt_open :: proc "contextless" (blob: []u8) -> (c: Fdt_Cursor, ok: bool) #no_bounds_check {
	if len(blob) < 40 || be32(blob, 0) != FDT_MAGIC {
		return
	}
	c.blob = blob
	c.at = int(be32(blob, 8))
	c.strings = int(be32(blob, 12))
	c.end = min(c.at + int(be32(blob, 36)), len(blob))
	return c, true
}

// fdt_next reads one token and steps past it: past a node's name, or past a
// property's header and value, each aligned to four. False at the block's end.
@(private)
fdt_next :: proc "contextless" (c: ^Fdt_Cursor, t: ^Fdt_Token) -> bool #no_bounds_check {
	if c.at + 4 > c.end {
		return false
	}
	blob := c.blob
	t^ = Fdt_Token{kind = be32(blob, c.at)}
	c.at += 4
	switch t.kind {
	case FDT_BEGIN_NODE:
		n := cstr_len(blob, c.at)
		t.name = string(blob[c.at:c.at + n])
		c.at = align4(c.at + n + 1)
	case FDT_PROP:
		t.length = int(be32(blob, c.at))
		name_off := int(be32(blob, c.at + 4))
		t.value_at = c.at + 8
		c.at = align4(t.value_at + t.length)
		pn := cstr_len(blob, c.strings + name_off)
		t.name = string(blob[c.strings + name_off:c.strings + name_off + pn])
	}
	return true
}

// A node while the walk is inside it: its index, and the cell counts it sets
// for the addresses and sizes of its own children's `reg`. The defaults are
// the device-tree spec's when a node names neither.
@(private)
Frame :: struct {
	idx: int,
	ac:  int,
	sc:  int,

	// An `interrupt-map` seen in this node, decoded when the node ends. By
	// then the node's own `#address-cells` and `#interrupt-cells` are
	// certain, since a property may come before the cell counts it needs.
	map_at:  int,
	map_len: int,
	ic:      int,

	// A `ranges` seen in this node, decoded when the node ends for the
	// same reason. A PCI host's memory windows become `mmio32` and
	// `mmio64`, the files a driver maps a function's registers out of.
	ranges_at:  int,
	ranges_len: int,
}

// The four legacy pins a PCI host routes, `irq0` to `irq3`, and their names
// as the rows spell them.
@(private)
PIN_NAMES := [4]string{"irq0", "irq1", "irq2", "irq3"}

/*
cells_of_phandle answers a node's `#address-cells` and `#interrupt-cells` by
its phandle, for the parent half of an `interrupt-map` entry. Two and zero
are the defaults for a node that names neither. False for no such node.
*/
@(private)
cells_of_phandle :: proc "contextless" (blob: []u8, want: u32) -> (ac: int, ic: int, ok: bool) #no_bounds_check {
	Seen :: struct {
		phandle: u32,
		ac:      int,
		ic:      int,
	}
	stack: [MAX_DEPTH]Seen
	sp := 0
	c, valid := fdt_open(blob)
	if !valid {
		return 0, 0, false
	}
	t: Fdt_Token
	for fdt_next(&c, &t) {
		switch t.kind {
		case FDT_BEGIN_NODE:
			if sp < MAX_DEPTH {
				stack[sp] = Seen{ac = 2}
				sp += 1
			}
		case FDT_END_NODE:
			if sp > 0 {
				sp -= 1
				if stack[sp].phandle == want {
					return stack[sp].ac, stack[sp].ic, true
				}
			}
		case FDT_PROP:
			if sp == 0 || t.length != 4 || t.value_at + t.length > len(blob) {
				continue
			}
			switch t.name {
			case "phandle":
				stack[sp - 1].phandle = be32(blob, t.value_at)
			case "#address-cells":
				stack[sp - 1].ac = int(be32(blob, t.value_at))
			case "#interrupt-cells":
				stack[sp - 1].ic = int(be32(blob, t.value_at))
			}
		case FDT_NOP:
		case:
			return 0, 0, false
		}
	}
	return 0, 0, false
}

/*
pin_lines decodes a PCI host's `interrupt-map` into the four shared lines its
legacy pins reach from device zero, `docs/SMMU.md` section 11. An entry is
the child's unit address and pin, the parent's phandle, then the parent's
unit address and interrupt cells, whose counts the parent names. Only a
parent in the GIC's shape is a line this tree can route: three cells of
`<type number flags>` with type zero. That is the rule `interrupts` keeps.
Pins are numbered from one. A pin the map does not route answers -1.
*/
@(private)
pin_lines :: proc "contextless" (blob: []u8, at: int, length: int, child_ac: int, child_ic: int) -> (lines: [4]int) #no_bounds_check {
	lines = {-1, -1, -1, -1}
	if child_ic != 1 || child_ac < 1 || child_ac > 3 {
		return
	}
	cursor := at
	end := at + length
	for cursor + (child_ac + child_ic + 1) * 4 <= end {
		device := be32(blob, cursor) >> 11 & 0x1F
		pin := int(be32(blob, cursor + child_ac * 4))
		phandle := be32(blob, cursor + (child_ac + child_ic) * 4)
		pac, pic, found := cells_of_phandle(blob, phandle)
		if !found {
			return
		}
		entry := (child_ac + child_ic + 1 + pac + pic) * 4
		if cursor + entry > end {
			return
		}
		if device == 0 && pin >= 1 && pin <= 4 && pic == 3 {
			pcells := cursor + (child_ac + child_ic + 1 + pac) * 4
			if be32(blob, pcells) == 0 {
				lines[pin - 1] = int(be32(blob, pcells + 4))
			}
		}
		cursor += entry
	}
	return
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
phandle_of_compatible finds the node whose `compatible` names `want` and
answers its `phandle`, before the walk that needs it. A node's `phandle` may
come before or after its `compatible`, so both are kept per level of the
stack until the node ends. Zero, and false, for no such node.
*/
@(private)
phandle_of_compatible :: proc "contextless" (blob: []u8, want: string) -> (u32, bool) #no_bounds_check {
	Seen :: struct {
		phandle: u32,
		matched: bool,
	}
	stack: [MAX_DEPTH]Seen
	sp := 0
	c, valid := fdt_open(blob)
	if !valid {
		return 0, false
	}
	t: Fdt_Token
	for fdt_next(&c, &t) {
		switch t.kind {
		case FDT_BEGIN_NODE:
			if sp < MAX_DEPTH {
				stack[sp] = {}
				sp += 1
			}
		case FDT_END_NODE:
			if sp > 0 {
				sp -= 1
				if stack[sp].matched && stack[sp].phandle != 0 {
					return stack[sp].phandle, true
				}
			}
		case FDT_PROP:
			if sp == 0 || t.value_at + t.length > len(blob) {
				continue
			}
			if t.name == "phandle" && t.length == 4 {
				stack[sp - 1].phandle = be32(blob, t.value_at)
			} else if t.name == "compatible" {
				if compatible_matches(string(blob[t.value_at:t.value_at + t.length]), want) {
					stack[sp - 1].matched = true
				}
			}
		case FDT_NOP:
		case:
			return 0, false
		}
	}
	return 0, false
}

/*
walk reads the structure block and either counts the rows or fills them. One
walk serves both passes: called with empty slices it returns the counts, and
called with slices of those sizes it writes each row and each window. The two
runs assign the same index in the same order, so a property's `parent` set in
the fill is the index the same node took in the count. The rows that grow an
`irq` or a `dma` file are counted apart, as `irqs` and `dmas`. Their tables
hold one entry per file, and `irq_index` and `dma_index` name each row's
entry.

A node is a directory whose parent is the node on top of the stack; the first,
the tree's own root with no name, becomes `/` with no parent. A property is a
file under the node on top of the stack, its bytes a slice of the blob. And a
node with a `reg` grows one more file, a synthesized `mmio`, whose window
`decode_reg` reads from that `reg` with the node's *parent* cell counts -- the
one file the kernel adds, not the firmware, and the one a driver segattaches.
*/
@(private)
walk :: proc "contextless" (blob: []u8, out: []vfs.Static_Node, mtab: []Mmio, iidx: []i32, itab: []Irq, didx: []i32, dtab: []Dma, walker: u32) -> (count, irqs, dmas: int) #no_bounds_check {
	stack: [MAX_DEPTH]Frame
	sp := 0

	c, valid := fdt_open(blob)
	if !valid {
		return 0, 0, 0
	}
	t: Fdt_Token
	for fdt_next(&c, &t) {
		switch t.kind {
		case FDT_BEGIN_NODE:
			idx := count
			count += 1
			parent := sp > 0 ? stack[sp - 1].idx : -1
			name := sp == 0 ? "/" : t.name
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
				// A PCI host's `interrupt-map` grows `irq0` to `irq3`, one
				// per legacy pin, now that the node's cell counts are all
				// read. A device at slot `d` on pin `p` reads
				// `irq<(d + p - 1) mod 4>`, the rotation the map spells.
				f := &stack[sp]
				// A PCI host's `ranges`. An entry is the child's three
				// cells, whose high cell's type bits say 32-bit or 64-bit
				// memory, then the parent's address and the size. Those
				// two are in the parent's and this node's counts. Each
				// memory window grows a file a driver attaches a BAR's
				// pages out of.
				if f.ranges_len > 0 && f.ac == 3 && sp > 0 {
					pac := stack[sp - 1].ac
					entry := (3 + pac + f.sc) * 4
					if pac >= 1 && pac <= 2 && f.sc >= 1 && f.sc <= 2 {
						for e := 0; e + entry <= f.ranges_len; e += entry {
							ra := f.ranges_at + e
							kind := be32(blob, ra) & 0x0300_0000
							if kind != 0x0200_0000 && kind != 0x0300_0000 {
								continue
							}
							base, size, rok := decode_reg(blob[ra + 12:ra + entry], pac, f.sc)
							if !rok || size == 0 {
								continue
							}
							widx := count
							count += 1
							if widx < len(out) {
								out[widx] = vfs.Static_Node{name = kind == 0x0200_0000 ? "mmio32" : "mmio64", parent = i32(f.idx)}
							}
							if widx < len(mtab) {
								mtab[widx] = Mmio{phys = uintptr(base), size = size, valid = true}
							}
						}
					}
				}
				if f.map_len > 0 {
					lines := pin_lines(blob, f.map_at, f.map_len, f.ac, f.ic)
					for pin in 0 ..< 4 {
						if lines[pin] < 0 {
							continue
						}
						pidx := count
						count += 1
						if pidx < len(out) {
							out[pidx] = vfs.Static_Node{name = PIN_NAMES[pin], parent = i32(f.idx)}
						}
						if pidx < len(iidx) && irqs < len(itab) {
							iidx[pidx] = i32(irqs)
							itab[irqs] = Irq {
								valid = true,
								gsi   = lines[pin],
								intid = u64(arch.VECTOR_IRQ_BASE) + u64(lines[pin]),
							}
						}
						irqs += 1
					}
				}
			}
		case FDT_PROP:
			length := t.length
			value_at := t.value_at
			vend := value_at + length
			if vend > len(blob) {
				vend = value_at
			}
			pname := t.name

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
				} else if pname == "#interrupt-cells" {
					stack[sp - 1].ic = int(be32(blob, value_at))
				}
			}
			if sp > 0 && pname == "interrupt-map" && vend > value_at {
				stack[sp - 1].map_at = value_at
				stack[sp - 1].map_len = vend - value_at
			}
			if sp > 0 && pname == "ranges" && vend > value_at {
				stack[sp - 1].ranges_at = value_at
				stack[sp - 1].ranges_len = vend - value_at
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
					lidx := count
					count += 1
					if lidx < len(out) {
						out[lidx] = vfs.Static_Node{name = "irq", parent = i32(stack[sp - 1].idx)}
					}
					if lidx < len(iidx) && irqs < len(itab) {
						iidx[lidx] = i32(irqs)
						itab[irqs] = Irq {
							valid = true,
							gsi   = int(icell),
							intid = u64(arch.VECTOR_IRQ_BASE) + u64(icell),
						}
					}
					irqs += 1
				}
			}

			// A walker grows the node a `dma` file, `docs/SMMU.md` section
			// 6. `iommus` is `<phandle stream>` for a device with one
			// stream. `iommu-map` on a PCI host is `<rid phandle sid
			// length>` per entry. The first entry naming the walker the
			// kernel drives is the one kept. `walker` is that phandle.
			// It is zero on a machine with none, which then grows no file.
			if sp > 0 && walker != 0 {
				d: Dma
				if pname == "iommus" && length >= 8 && be32(blob, value_at) == walker {
					d = Dma{valid = true, single = true, stream = be32(blob, value_at + 4)}
				} else if pname == "iommu-map" && length >= 16 {
					for e := 0; e + 16 <= length; e += 16 {
						if be32(blob, value_at + e + 4) == walker {
							d = Dma {
								valid    = true,
								rid_base = be32(blob, value_at + e),
								sid_base = be32(blob, value_at + e + 8),
								length   = be32(blob, value_at + e + 12),
							}
							break
						}
					}
				}
				if d.valid {
					widx := count
					count += 1
					if widx < len(out) {
						out[widx] = vfs.Static_Node{name = "dma", parent = i32(stack[sp - 1].idx)}
					}
					if widx < len(didx) && dmas < len(dtab) {
						didx[widx] = i32(dmas)
						dtab[dmas] = d
					}
					dmas += 1
				}
			}
		case FDT_NOP:
		case FDT_END:
			return count, irqs, dmas
		case:
			return count, irqs, dmas
		}
	}
	return count, irqs, dmas
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
		if d, node := dma_of(m.fid); d != nil {
			tree_dma_open(d, node, m.fid, reply)
			return
		}
	case vectra9.Tread:
		if e := irq_of(m.fid); e != nil {
			tree_irq_read(e, tag, buf, reply)
			return
		}
		if d, _ := dma_of(m.fid); d != nil {
			tree_dma_read(d, tag, buf, reply)
			return
		}
	case vectra9.Twrite:
		if d, _ := dma_of(m.fid); d != nil {
			tree_dma_write(d, tag, m.data, reply)
			return
		}
	case vectra9.Tclunk:
		if e := irq_of(m.fid); e != nil {
			tree_irq_disarm(e)
		}
		if d, _ := dma_of(m.fid); d != nil {
			tree_dma_close(d, m.fid)
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
	if node >= 0 && int(node) < len(irq_index) && irq_index[node] >= 0 {
		return &irq_table[irq_index[node]]
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
			line := libodin.sink_from(buf)
			libodin.put_uint(&line, n)
			libodin.put_byte(&line, '\n')
			reply^ = vectra9.Rread{data = libodin.bytes(&line)}
			return
		}
		sync.sleep(&e.ready, irq_ready, &w)
	}
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
	for i in 0 ..< len(dma_table) {
		if dma_table[i].valid {
			sync.wakeup_all(&dma_table[i].ready)
		}
	}
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
	copy(blob, src[:total])

	// The walker the kernel drives, by phandle. The walk needs it to tell a
	// node with a `dma` file from one whose walker is some other part's.
	walker, _ := phandle_of_compatible(blob, "arm,smmu-v3")

	count, irqs, dmas := walk(blob, nil, nil, nil, nil, nil, nil, walker)
	if count <= 0 {
		delete(blob)
		return vfs.OK
	}
	// One index per row, and a table entry only per synthesized `irq` or
	// `dma` file. A `Dma` carries a ring of lines, and one per row would be
	// most of the heap the tree takes.
	rows := make([]vfs.Static_Node, count)
	mtab := make([]Mmio, count)
	iidx := make([]i32, count)
	didx := make([]i32, count)
	if rows == nil || mtab == nil || iidx == nil || didx == nil {
		delete(blob)
		return vectra9.ENOMEM
	}
	itab: []Irq
	dtab: []Dma
	if irqs > 0 {
		itab = make([]Irq, irqs)
		if itab == nil {
			delete(blob)
			return vectra9.ENOMEM
		}
	}
	if dmas > 0 {
		dtab = make([]Dma, dmas)
		if dtab == nil {
			delete(blob)
			return vectra9.ENOMEM
		}
	}
	for i in 0 ..< count {
		iidx[i] = -1
		didx[i] = -1
	}
	_, _, _ = walk(blob, rows, mtab, iidx, itab, didx, dtab, walker)
	node_count = count
	mmio_table = mtab
	irq_index = iidx
	irq_table = itab
	dma_index = didx
	dma_table = dtab
	smmu.set_sink(on_event)

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
