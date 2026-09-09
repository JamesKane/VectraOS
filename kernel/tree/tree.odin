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

// nodes reports how many directories and property files `#t` serves, for the
// boot line. Zero on a machine the bootloader gave no tree.
nodes :: proc "contextless" () -> int {
	return node_count
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
walk :: proc "contextless" (blob: []u8, out: []vfs.Static_Node, mtab: []Mmio) -> int #no_bounds_check {
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

	count := walk(blob, nil, nil)
	if count <= 0 {
		delete(blob)
		return vfs.OK
	}
	rows := make([]vfs.Static_Node, count)
	mtab := make([]Mmio, count)
	if rows == nil || mtab == nil {
		delete(blob)
		return vectra9.ENOMEM
	}
	_ = walk(blob, rows, mtab)
	node_count = count
	mmio_table = mtab

	if !vfs.static_init(&tree_static, "tree", rows) {
		return vectra9.ENOMEM
	}
	if err := vfs.server_init(&tree_server, "t", vfs.static_handler, &tree_static); err != .None {
		return vectra9.EPROTO
	}
	// The kernel hook that answers a segattach of an `mmio`, beside the handler
	// that answers the property reads. See `docs/HARDWARE.md` section 3.
	tree_server.device = tree_device
	if !vfs.register_device(&tree_server) {
		return vectra9.EEXIST
	}
	return vfs.mount_device(ns, "#t", "/dev/tree")
}
