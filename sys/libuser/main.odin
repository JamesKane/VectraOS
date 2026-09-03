/*
What a tool starts with: a context, a heap, its arguments, and a way to
print.

A server's `_start` runs the Odin runtime with an empty context and goes to
its serve loop. A tool wants more: an allocator behind `context`, its
arguments as strings, a formatted print, and a buffered writer for output
that comes in pieces. This file is that, and a tool's entry is three lines:

    @(export, link_name = "_start")
    start :: proc "c" (block: ^abi.Args) {
        context = libuser.startup()
        main(libuser.args(block))
    }

`Bio` is Plan 9's `Biobuf` for output: bytes gather until the buffer fills
or `flush`, so a tool that prints a character at a time makes one system
call per buffer rather than one per character. Formatted printing is
`vsys:libfmt`, a package apart, and its file says why.
*/
package libuser

import "base:runtime"

import "vsys:abi"
import "vsys:vectra9"

// startup runs the runtime and answers the context a tool runs under, with
// the heap as its allocator. The temp allocator is the heap too: a tool has
// no arena, and a leak in a short program is a leak nobody meets.
startup :: proc "c" () -> runtime.Context {
	context = {}
	#force_no_inline runtime._startup_runtime()
	ctx := runtime.default_context()
	ctx.allocator = allocator()
	ctx.temp_allocator = allocator()
	return ctx
}

// heap_context is the context a contextless handler builds when it needs
// the heap: a server's 9P handler, called from the serve loop. The runtime
// is already up; this is the allocator alone.
heap_context :: proc "contextless" () -> runtime.Context {
	ctx := runtime.default_context()
	ctx.allocator = allocator()
	ctx.temp_allocator = allocator()
	return ctx
}

// args is the arguments the kernel wrote onto the stack, as a slice. The
// first is the program's own name, by the caller's convention.
args :: proc "contextless" (block: ^abi.Args) -> []string {
	if block == nil || block.count <= 0 || block.strings == nil {
		return nil
	}
	return block.strings[:block.count]
}

// errstr names an error a call answered with, for a tool's message. The
// number is `-errno`, and the name is 9P's.
errstr :: proc "contextless" (answer: i64) -> string {
	if answer >= 0 {
		return ""
	}
	return vectra9.errno_name(vectra9.Errno(-answer))
}

// -- Buffered output -----------------------------------------------------------

BIO_SIZE :: 4096

Bio :: struct {
	fd:   int,
	used: int,
	buf:  [BIO_SIZE]u8,
}

bio_init :: proc "contextless" (b: ^Bio, fd: int) {
	b.fd = fd
	b.used = 0
}

// bio_write buffers bytes, flushing as the buffer fills. Answers false when
// a flush failed, which is the descriptor gone.
bio_write :: proc "contextless" (b: ^Bio, data: []u8) -> bool {
	at := 0
	for at < len(data) {
		if b.used == BIO_SIZE && !bio_flush(b) {
			return false
		}
		n := min(len(data) - at, BIO_SIZE - b.used)
		for i in 0 ..< n {
			b.buf[b.used + i] = data[at + i]
		}
		b.used += n
		at += n
	}
	return true
}

bio_puts :: proc "contextless" (b: ^Bio, s: string) -> bool {
	return bio_write(b, transmute([]u8)s)
}

bio_putc :: proc "contextless" (b: ^Bio, c: u8) -> bool {
	one := [1]u8{c}
	return bio_write(b, one[:])
}

bio_flush :: proc "contextless" (b: ^Bio) -> bool {
	if b.used == 0 {
		return true
	}
	ok := write_full(b.fd, b.buf[:b.used])
	b.used = 0
	return ok
}
