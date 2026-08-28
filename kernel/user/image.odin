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
The four programs `/bin` serves, and the directory over them.

Only the programs that stand alone are published. The other eleven blobs
each expect the kernel to stage an address or a path into their data page
before they run. A file cannot carry that arrangement. A program whose text
holds everything it needs is the shape every later one takes.
*/
@(private = "file")
bin_nodes: [5]vfs.Static_Node

@(private = "file")
bin_tree: vfs.Static_Tree

@(private = "file")
bin_server: vfs.Server

// How many program files `/bin` serves, for the boot line.
BIN_PROGRAMS :: len(bin_nodes) - 1

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
	if child == nil || parent == nil || poster == nil || niner == nil {
		return vectra9.ENOMEM
	}

	bin_nodes = {
		{name = "/", parent = -1, dir = true},
		{name = "child", parent = 0, data = string(child)},
		{name = "niner", parent = 0, data = string(niner)},
		{name = "parent", parent = 0, data = string(parent)},
		{name = "poster", parent = 0, data = string(poster)},
	}

	if !vfs.static_init(&bin_tree, "bin", bin_nodes[:]) {
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

/*
load_image reads a program out of a file, through a namespace.

**This is the loader.** The path resolves in `ns` -- the namespace of whoever
asked, not the kernel's -- so what `/bin/child` means depends on who is
loading. The loader reads and checks the header before a byte of text moves.
The text lands directly in the frame the caller will map, through the direct
map. It arrives in bounded pieces, because the transport bounds a 9P read.

Returns the entry point, because that is the one fact the caller cannot know
without trusting the file. Everything else about the mapping is the caller's.

ENOENT is the walk failing, ENOEXEC is the file failing the format, EIO is a
file that ended before its header said it would. Three different sentences
for the caller to pass upward.
*/
load_image :: proc(ns: ^vfs.Namespace, path: string, frame: uintptr) -> (entry: uintptr, err: vectra9.Errno) {
	if ns == nil || frame == 0 {
		return 0, vectra9.EINVAL
	}

	c, oerr := vfs.open_path(ns, path, vfs.O_RDONLY)
	if oerr != vfs.OK {
		return 0, oerr
	}
	defer vfs.chan_close(c)

	raw: [IMAGE_HEADER_SIZE]u8
	got, rerr := vfs.chan_read(c, 0, raw[:])
	if rerr != vfs.OK {
		return 0, rerr
	}
	header, ok := image_read_header(raw[:got])
	if !ok || !image_check(header) {
		return 0, vectra9.ENOEXEC
	}

	text := (cast([^]u8)mem.phys_to_virt(frame))[:arch.PAGE_SIZE]
	filled := 0
	for filled < int(header.text) {
		n, e := vfs.chan_read(c, u64(IMAGE_HEADER_SIZE + filled), text[filled:header.text])
		if e != vfs.OK {
			return 0, e
		}
		if n == 0 {
			// The file ended before the header's count did. The header lied,
			// and a program with its tail missing must not run.
			return 0, vectra9.EIO
		}
		filled += n
	}
	return uintptr(header.entry), vfs.OK
}
