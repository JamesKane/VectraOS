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

/*
walk reads the structure block and either counts the rows or fills them. One
walk serves both passes: called with an empty `out` it returns the count, and
called with a slice of that size it writes each row. The two runs assign the
same index in the same order, so a property's `parent` set in the fill is the
index the same node took in the count.

A node is a directory whose parent is the node on top of the stack; the first,
the tree's own root with no name, becomes `/` with no parent. A property is a
file under the node on top of the stack, its bytes a slice of the blob.
*/
@(private)
walk :: proc "contextless" (blob: []u8, out: []vfs.Static_Node) -> int #no_bounds_check {
	if len(blob) < 40 || be32(blob, 0) != FDT_MAGIC {
		return 0
	}
	struct_off := int(be32(blob, 8))
	strings_off := int(be32(blob, 12))
	struct_size := int(be32(blob, 36))

	stack: [MAX_DEPTH]int
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
			parent := sp > 0 ? stack[sp - 1] : -1
			name := sp == 0 ? "/" : string(blob[name_at:name_at + n])
			if idx < len(out) {
				out[idx] = vfs.Static_Node{name = name, parent = i32(parent), dir = true}
			}
			if sp < MAX_DEPTH {
				stack[sp] = idx
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
			idx := count
			count += 1
			parent := sp > 0 ? stack[sp - 1] : -1
			pn := cstr_len(blob, strings_off + name_off)
			if idx < len(out) {
				vend := value_at + length
				if vend > len(blob) {
					vend = value_at
				}
				out[idx] = vfs.Static_Node {
					name   = string(blob[strings_off + name_off:strings_off + name_off + pn]),
					parent = i32(parent),
					data   = string(blob[value_at:vend]),
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

	count := walk(blob, nil)
	if count <= 0 {
		delete(blob)
		return vfs.OK
	}
	rows := make([]vfs.Static_Node, count)
	if rows == nil {
		delete(blob)
		return vectra9.ENOMEM
	}
	_ = walk(blob, rows)
	node_count = count

	if !vfs.static_init(&tree_static, "tree", rows) {
		return vectra9.ENOMEM
	}
	if err := vfs.server_init(&tree_server, "t", vfs.static_handler, &tree_static); err != .None {
		return vectra9.EPROTO
	}
	if !vfs.register_device(&tree_server) {
		return vectra9.EEXIST
	}
	return vfs.mount_device(ns, "#t", "/dev/tree")
}
