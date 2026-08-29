/*
The image format, and `#b` at `/bin` -- programs as files.

Until this milestone a program was a blob the assembler baked into the
kernel. A caller that could see the symbol table handed `load` its bytes.
Nothing outside the kernel could name a program, so nothing outside the
kernel could start one. This file is the half of the fix that makes a program
a *file*. That is something with a name, in a namespace, that a process can
read.

## The format

Not ELF, on purpose. An ELF loader is program headers, relocation kinds, and a
dozen decisions about what to refuse. Every one of them is worth having the day
a real toolchain emits the input. Today the input is a page of position-bound
code, and the format says exactly that and nothing else:

    +0   magic      "VECTRA01", as eight bytes
    +8   entry      the virtual address of the first instruction
    +16  text       how many bytes of code follow the header
    +24  reserved   zero, and refused when it is not

Four words, little-endian, and then the text. The text is mapped at `TEXT_VA`
read-only and executable, which is where every blob already believed it lived.
`entry` names an address inside it rather than being assumed. The format
therefore has room for a program that does not start at its first byte.

The reserved word is checked against zero rather than ignored. A format that
skips what it does not understand cannot ever mean anything new by it. This
kernel refuses an image from the future, which is the honest answer.

## `#b`, and why the images are served rather than special-cased

The loader could have read the blobs out of the kernel image directly. Then
`a program is a file` would have been a sentence in a document rather than a
property of the machine. Instead an ordinary read-only server publishes the
images, registered as `#b` and bound at `/bin` in the boot namespace. The
loader walks a path like any other client, through the namespace of whatever
process asked. A process whose `/bin` is rebound loads something else, which
is not a hole. It is the namespace doing its job.

The server is `vfs.Static_Tree`, the same implementation behind `#/`. The
one cost is that init builds each image once. That is a header and a copy of
the blob, on the heap, for the lifetime of the machine. Two pages, today.
*/
package user

import "kernel:arch"
import "kernel:mem"
import "kernel:vfs"
import "vsys:vectra9"

// "VECTRA01" read as a little-endian u64. The check compares one word rather
// than eight bytes, and a hex dump of a good header reads as the string.
IMAGE_MAGIC :: u64(0x3130_4152_5443_4556)

// The header is four u64 fields. The size is stated rather than derived, so
// the wire layout cannot drift when the struct grows a field.
IMAGE_HEADER_SIZE :: 32

/*
"VECTRA02" -- the format with segments, for programs a compiler built.

VECTRA01 says `one page of text`, and the blobs it carries are exactly that.
A linked program is more shapes than one. Text executes, rodata reads, data
and bss write, and each wants its own permissions on its own pages. So the
second format is a segment table -- the useful rows of an ELF's program
headers, with everything else refused at build time:

    +0   magic     "VECTRA02"
    +8   entry     the virtual address of the first instruction
    +16  nsegs     how many segment rows follow, 1 to 4
    +24  reserved  zero, and refused when it is not

    each row, 32 bytes:
    vaddr filesz memsz flags     flags: bit 0 write, bit 1 execute

The payloads follow the table, each segment's `filesz` bytes in row order.
`build.odin` emits this and carries its own copy of these constants. The
builder and the loader cannot share a file, and the checks below are what
keeps the copies honest.
*/
IMAGE2_MAGIC :: u64(0x3230_4152_5443_4556)
IMAGE2_HEADER_SIZE :: 32
IMAGE2_SEG_SIZE :: 32
IMAGE2_MAX_SEGS :: 4

IMG_FLAG_W :: u64(1)
IMG_FLAG_X :: u64(2)

Image_Seg :: struct {
	vaddr:  uintptr,
	filesz: u64,
	memsz:  u64,
	flags:  u64,
}

/*
image2_read_segs decodes and judges a segment table.

Every refusal is a rule the loader relies on rather than taste:

  - a segment starts on a page boundary, because pages are what get mapped
    and a mid-page start would share a page across permissions
  - no segment is both writable and executable, which makes W^X a property
    of the *format* rather than a habit of its builders
  - segments ascend and do not touch, so no page is claimed twice
  - everything lands inside the program half, clear of the stack
  - the entry is inside an executable segment

The page budget is the caller's, because the caller owns the frame table
the pages come from.
*/
image2_read_segs :: proc "contextless" (
	raw: []u8,
	entry: uintptr,
	nsegs: int,
	segs: []Image_Seg,
	max_pages: int,
) -> bool #no_bounds_check {
	if nsegs <= 0 || nsegs > IMAGE2_MAX_SEGS || len(segs) < nsegs {
		return false
	}
	if len(raw) < nsegs * IMAGE2_SEG_SIZE {
		return false
	}
	word :: proc "contextless" (b: []u8) -> u64 {
		v := u64(0)
		for i in 0 ..< 8 {
			v |= u64(b[i]) << (8 * u64(i))
		}
		return v
	}

	page := u64(arch.PAGE_SIZE)
	total_pages := 0
	entry_ok := false
	prev_end := u64(0)

	for i in 0 ..< nsegs {
		at := i * IMAGE2_SEG_SIZE
		s := Image_Seg {
			vaddr  = uintptr(word(raw[at:])),
			filesz = word(raw[at + 8:]),
			memsz  = word(raw[at + 16:]),
			flags  = word(raw[at + 24:]),
		}
		if s.memsz == 0 || s.filesz > s.memsz {
			return false
		}
		if u64(s.vaddr) % page != 0 {
			return false
		}
		if s.flags & IMG_FLAG_W != 0 && s.flags & IMG_FLAG_X != 0 {
			return false
		}
		if s.vaddr < mem.USER_MIN {
			return false
		}
		end := u64(s.vaddr) + s.memsz
		if end > u64(STACK_VA2) || end < u64(s.vaddr) {
			return false
		}
		if u64(s.vaddr) < prev_end {
			return false
		}
		prev_end = end

		total_pages += int((s.memsz + page - 1) / page)
		if s.flags & IMG_FLAG_X != 0 && entry >= s.vaddr && u64(entry) < end {
			entry_ok = true
		}
		segs[i] = s
	}
	return entry_ok && total_pages > 0 && total_pages <= max_pages
}

Image_Header :: struct {
	magic:    u64,
	entry:    u64,
	text:     u64,
	reserved: u64,
}

/*
image_check says whether a header names something this loader can run.

Every rule is a refusal a self-test provokes. The size bound is `PAGE_SIZE`
because the loader maps exactly one text page. The bound moves the day the
loader grows a loop. The format does not change when it does.
*/
image_check :: proc "contextless" (h: Image_Header) -> bool {
	if h.magic != IMAGE_MAGIC || h.reserved != 0 {
		return false
	}
	if h.text == 0 || h.text > u64(arch.PAGE_SIZE) {
		return false
	}
	entry := uintptr(h.entry)
	return entry >= TEXT_VA && entry < TEXT_VA + uintptr(h.text)
}

/*
image_read_header decodes the four words by hand.

By hand rather than by casting the buffer. The header comes off a wire, and
a cast asserts alignment and layout that bytes from a file never promised.
Thirty-two bytes is eight lines. The codec in `sys/vectra9` earns its cursor
over fifty-seven message kinds. This does not.
*/
image_read_header :: proc "contextless" (raw: []u8) -> (h: Image_Header, ok: bool) {
	if len(raw) < IMAGE_HEADER_SIZE {
		return h, false
	}
	word :: proc "contextless" (b: []u8) -> u64 {
		v := u64(0)
		for i in 0 ..< 8 {
			v |= u64(b[i]) << (8 * u64(i))
		}
		return v
	}
	h.magic = word(raw[0:])
	h.entry = word(raw[8:])
	h.text = word(raw[16:])
	h.reserved = word(raw[24:])
	return h, true
}

/*
image_build wraps a blob in a header, on the heap.

The blobs sit in the kernel's text with no header, because the assembler that
emits them is also the loader that used to consume them. The file the server
publishes is the format above. This is where the two meet, once per program,
at init.
*/
@(private = "file")
image_build :: proc(code: []u8) -> []u8 {
	if len(code) == 0 || len(code) > arch.PAGE_SIZE {
		return nil
	}
	img := make([]u8, IMAGE_HEADER_SIZE + len(code))
	if img == nil {
		return nil
	}
	put :: proc "contextless" (b: []u8, v: u64) {
		for i in 0 ..< 8 {
			b[i] = u8(v >> (8 * u64(i)))
		}
	}
	put(img[0:], IMAGE_MAGIC)
	put(img[8:], u64(TEXT_VA))
	put(img[16:], u64(len(code)))
	put(img[24:], 0)
	for i in 0 ..< len(code) {
		img[IMAGE_HEADER_SIZE + i] = code[i]
	}
	return img
}

// -- The server --------------------------------------------------------------

/*
The programs `/bin` serves, and the directory over them.

Only the programs that stand alone are published. The blob programs that
expect the kernel to stage an address into their data page cannot be files,
because a file has no side channel.

`ramfs` is the different one: an image `build.odin` compiled and converted,
embedded here at build time. The `when` is for a tree checked before the
image was ever built. The kernel still compiles, `/bin` simply lacks the
file, and the self-test says so loudly rather than nothing quietly.
*/
when #exists("../../build/user/ramfs.vx") {
	@(private = "file")
	RAMFS_IMAGE := #load("../../build/user/ramfs.vx")
} else {
	@(private = "file")
	RAMFS_IMAGE: []u8
}

when #exists("../../build/user/consrv.vx") {
	@(private = "file")
	CONSRV_IMAGE := #load("../../build/user/consrv.vx")
} else {
	@(private = "file")
	CONSRV_IMAGE: []u8
}

when #exists("../../build/user/kbdfs.vx") {
	@(private = "file")
	KBDFS_IMAGE := #load("../../build/user/kbdfs.vx")
} else {
	@(private = "file")
	KBDFS_IMAGE: []u8
}

when #exists("../../build/user/eiafs.vx") {
	@(private = "file")
	EIAFS_IMAGE := #load("../../build/user/eiafs.vx")
} else {
	@(private = "file")
	EIAFS_IMAGE: []u8
}

@(private = "file")
bin_nodes: [11]vfs.Static_Node

// The rows `/bin` actually publishes -- `bin_nodes` less any compiled image
// a fresh tree has not built yet. Package-scope, because `static_init`
// borrows the slice for the life of the machine.
@(private = "file")
bin_live: [11]vfs.Static_Node

@(private = "file")
bin_tree: vfs.Static_Tree

@(private = "file")
bin_server: vfs.Server

// How many program files `/bin` serves, for the boot line.
@(private = "file")
bin_published: int

// bin_programs reports how many program files `/bin` serves, for the boot
// line. A count rather than a constant, because a tree checked before the
// ramfs image was built publishes one fewer.
bin_programs :: proc "contextless" () -> int {
	return bin_published
}

/*
bin_init builds the images, brings `#b` up, and binds it at `/bin`.

Runs after `vfs.init`, because the images live on the heap and the bind
needs a namespace. Runs before the first program that will name one. The
images outlive everything, so a failure here leaks nothing worth naming.
*/
bin_init :: proc(ns: ^vfs.Namespace) -> vfs.Errno {
	child := image_build(program_child())
	parent := image_build(program_parent())
	poster := image_build(program_poster())
	niner := image_build(program_niner())
	noter := image_build(program_noter())
	spin := image_build(program_spin())
	if child == nil || parent == nil || poster == nil || niner == nil ||
	   noter == nil || spin == nil {
		return vectra9.ENOMEM
	}

	bin_nodes = {
		{name = "/", parent = -1, dir = true},
		{name = "child", parent = 0, data = string(child)},
		{name = "consrv", parent = 0, data = string(CONSRV_IMAGE)},
		{name = "niner", parent = 0, data = string(niner)},
		{name = "noter", parent = 0, data = string(noter)},
		{name = "parent", parent = 0, data = string(parent)},
		{name = "poster", parent = 0, data = string(poster)},
		{name = "spin", parent = 0, data = string(spin)},
		{name = "ramfs", parent = 0, data = string(RAMFS_IMAGE)},
		{name = "kbdfs", parent = 0, data = string(KBDFS_IMAGE)},
		{name = "eiafs", parent = 0, data = string(EIAFS_IMAGE)},
	}

	/*
	A tree checked before `build.odin` ever built an image serves what it
	has. Two images can now be missing independently. The fallback is
	therefore a filter rather than a slice: every file row with bytes
	behind it, in order. Dropping a row cannot break a `parent` index, because every file
	is a child of row zero. The published count says what happened, and
	`verify_runtime` and `verify_consrv` fail loudly on an absence.
	*/
	count := 0
	for node in bin_nodes {
		if node.dir || len(node.data) > 0 {
			bin_live[count] = node
			count += 1
		}
	}
	bin_published = count - 1

	if !vfs.static_init(&bin_tree, "bin", bin_live[:count]) {
		return vectra9.ENOMEM
	}
	if err := vfs.server_init(&bin_server, "b", vfs.static_handler, &bin_tree); err != .None {
		return vectra9.EPROTO
	}
	if !vfs.register_device(&bin_server) {
		return vectra9.EEXIST
	}
	return vfs.mount_device(ns, "#b", "/bin")
}

// read_exact fills `dst` from a file offset, or says the file ended early.
// The loader's one loop, shared by every segment of every format.
@(private = "file")
read_exact :: proc(c: ^vfs.Chan, offset: u64, dst: []u8) -> vectra9.Errno {
	filled := 0
	for filled < len(dst) {
		n, e := vfs.chan_read(c, offset + u64(filled), dst[filled:])
		if e != vfs.OK {
			return e
		}
		if n == 0 {
			return vectra9.EIO
		}
		filled += n
	}
	return vfs.OK
}

/*
load_program reads a program out of a file and builds its whole memory image.

**This is the loader for both formats**, and the split of labour with the
callers moved when it arrived. `spawn_path` no longer assumes a shape, it
asks. A VECTRA01 blob gets the three named pages the blobs were written
against. Its `arg0` says the data page's address, which is the blobs' first
argument. A VECTRA02 program gets a page span per segment and a
`STACK_PAGES2` stack, each mapping with the permissions its row asked for.
Its `arg0` is zero, because a compiled program's world is in its own
segments.

Every frame allocated lands in the process record before anything can fail,
so `unload` can always give back exactly what was taken. ENOEXEC is a file
that is not a program. EIO is a program with its tail missing. ENOMEM is
the machine, not the file.
*/
load_program :: proc(
	p: ^Process,
	ns: ^vfs.Namespace,
	path: string,
) -> (entry: uintptr, sp: uintptr, arg0: u64, err: vectra9.Errno) #no_bounds_check {
	if p == nil || ns == nil {
		return 0, 0, 0, vectra9.EINVAL
	}

	c, oerr := vfs.open_path(ns, path, vfs.O_RDONLY)
	if oerr != vfs.OK {
		return 0, 0, 0, oerr
	}
	defer vfs.chan_close(c)

	raw: [IMAGE2_HEADER_SIZE]u8
	got, rerr := vfs.chan_read(c, 0, raw[:])
	if rerr != vfs.OK {
		return 0, 0, 0, rerr
	}
	if got < IMAGE_HEADER_SIZE {
		return 0, 0, 0, vectra9.ENOEXEC
	}

	word :: proc "contextless" (b: []u8) -> u64 {
		v := u64(0)
		for i in 0 ..< 8 {
			v |= u64(b[i]) << (8 * u64(i))
		}
		return v
	}

	switch word(raw[:]) {
	case IMAGE_MAGIC:
		return load_v1(p, c, raw[:got])
	case IMAGE2_MAGIC:
		return load_v2(p, c, raw[:got])
	}
	return 0, 0, 0, vectra9.ENOEXEC
}

// load_v1 is the blob shape: one page each of text, data and stack, at the
// addresses every blob was written against.
@(private = "file")
load_v1 :: proc(p: ^Process, c: ^vfs.Chan, raw: []u8) -> (uintptr, uintptr, u64, vectra9.Errno) {
	header, ok := image_read_header(raw)
	if !ok || !image_check(header) {
		return 0, 0, 0, vectra9.ENOEXEC
	}

	if p.text = segment_one_page(p, TEXT_VA, {}, .Text); p.text == 0 {
		return 0, 0, 0, vectra9.ENOMEM
	}
	if p.data = segment_one_page(p, DATA_VA, {.Write, .No_Execute}, .Data); p.data == 0 {
		return 0, 0, 0, vectra9.ENOMEM
	}
	if p.stack = segment_one_page(p, STACK_VA, {.Write, .No_Execute}, .Stack); p.stack == 0 {
		return 0, 0, 0, vectra9.ENOMEM
	}

	text := (cast([^]u8)mem.phys_to_virt(p.text))[:arch.PAGE_SIZE]
	if e := read_exact(c, IMAGE_HEADER_SIZE, text[:header.text]); e != vfs.OK {
		return 0, 0, 0, e
	}
	return uintptr(header.entry), STACK_TOP, u64(DATA_VA), vfs.OK
}

/*
load_v2 is the segment shape, now literally: one `Segment` per image row and
one for the stack. Each frame lands in its segment the moment it exists, so
a failure anywhere leaves nothing the teardown cannot find.

The stack pointer it answers is `STACK_TOP - 8`, and the eight matter. The
SysV ABI enters a function with the return address already pushed. Compiled
code therefore assumes `rsp + 8` is 16-byte aligned, and spills SSE
registers on that belief. A blob never held the belief, so only this loader
tilts the stack. There is no return address to pop, and `_start` never
returns.
*/
@(private = "file")
load_v2 :: proc(p: ^Process, c: ^vfs.Chan, raw: []u8) -> (uintptr, uintptr, u64, vectra9.Errno) #no_bounds_check {
	word :: proc "contextless" (b: []u8) -> u64 {
		v := u64(0)
		for i in 0 ..< 8 {
			v |= u64(b[i]) << (8 * u64(i))
		}
		return v
	}
	entry := uintptr(word(raw[8:]))
	nsegs := int(word(raw[16:]))
	if word(raw[24:]) != 0 {
		return 0, 0, 0, vectra9.ENOEXEC
	}

	table: [IMAGE2_MAX_SEGS * IMAGE2_SEG_SIZE]u8
	if nsegs <= 0 || nsegs > IMAGE2_MAX_SEGS {
		return 0, 0, 0, vectra9.ENOEXEC
	}
	if e := read_exact(c, IMAGE2_HEADER_SIZE, table[:nsegs * IMAGE2_SEG_SIZE]); e != vfs.OK {
		return 0, 0, 0, e
	}

	segs: [IMAGE2_MAX_SEGS]Image_Seg
	budget := MAX_PROGRAM_FRAMES - STACK_PAGES2
	if !image2_read_segs(table[:nsegs * IMAGE2_SEG_SIZE], entry, nsegs, segs[:], budget) {
		return 0, 0, 0, vectra9.ENOEXEC
	}

	page := u64(arch.PAGE_SIZE)
	offset := u64(IMAGE2_HEADER_SIZE + nsegs * IMAGE2_SEG_SIZE)
	for i in 0 ..< nsegs {
		s := segs[i]
		flags: arch.Page_Flags = {.No_Execute}
		kind := Segment_Kind.Text
		if s.flags & IMG_FLAG_X != 0 {
			flags = {}
		}
		if s.flags & IMG_FLAG_W != 0 {
			flags = {.Write, .No_Execute}
			kind = .Data
		}

		seg := segment_new(s.vaddr, flags, kind)
		if seg == nil || !proc_add_segment(p, seg) {
			return 0, 0, 0, vectra9.ENOMEM
		}

		pages := int((s.memsz + page - 1) / page)
		copied := u64(0)
		for j in 0 ..< pages {
			frame, ok := mem.alloc_page_zeroed()
			if !ok {
				return 0, 0, 0, vectra9.ENOMEM
			}
			if !segment_add_frame(seg, frame) {
				mem.free_page(frame)
				return 0, 0, 0, vectra9.ENOMEM
			}

			if copied < s.filesz {
				chunk := min(s.filesz - copied, page)
				dst := (cast([^]u8)mem.phys_to_virt(frame))[:chunk]
				if e := read_exact(c, offset + copied, dst); e != vfs.OK {
					return 0, 0, 0, e
				}
				copied += chunk
			}
			va := s.vaddr + uintptr(j) * uintptr(page)
			if mem.map_user(p.space, va, frame, flags, 1) != .None {
				return 0, 0, 0, vectra9.ENOMEM
			}
		}
		offset += s.filesz
	}

	stack := segment_new(STACK_VA2, {.Write, .No_Execute}, .Stack)
	if stack == nil || !proc_add_segment(p, stack) {
		return 0, 0, 0, vectra9.ENOMEM
	}
	for j in 0 ..< STACK_PAGES2 {
		frame, ok := mem.alloc_page_zeroed()
		if !ok {
			return 0, 0, 0, vectra9.ENOMEM
		}
		if !segment_add_frame(stack, frame) {
			mem.free_page(frame)
			return 0, 0, 0, vectra9.ENOMEM
		}
		va := STACK_VA2 + uintptr(j * arch.PAGE_SIZE)
		if mem.map_user(p.space, va, frame, {.Write, .No_Execute}, 1) != .None {
			return 0, 0, 0, vectra9.ENOMEM
		}
	}
	return entry, STACK_TOP - 8, 0, vfs.OK
}
