/*
A program's arguments, from the caller's memory to the new program's stack.

`spawn` and `exec` take a slice of strings that live in the calling
program, and the program those strings are for has a different address
space, or the same one about to be replaced. So the strings are copied in
whole first, into a kernel record bounded by `ARGS_MAX`, and written out
afterwards onto the new stack, once it exists. `docs/SHELL.md` and
`sys/abi` describe the layout the program finds: the bytes at the top, an
Odin `string` per argument below them, and an `abi.Args` record below
those, whose address is the program's first argument.

The write goes through the stack segment's frames rather than through the
program's mapping, because at `spawn` the new space is not the one loaded,
and at `exec` writing through frames is the same code. Every address the
record holds is the *program's*, computed from the stack's top and the
sizes, so the kernel never reads it back.
*/
package user

import "kernel:arch"
import "kernel:mem"
import "vsys:abi"

// The copied arguments: the bytes, and where each argument starts and ends
// in them. `count` is how many.
// set_args keeps a program's arguments on its record, joined by spaces and
// cut at ARGS_KEEP, for `/proc/n/args`.
set_args :: proc "contextless" (p: ^Process, argv: ^Argv) #no_bounds_check {
	p.args_len = 0
	if argv == nil {
		return
	}
	start := 0
	for i in 0 ..< argv.count {
		if i > 0 && p.args_len < ARGS_KEEP {
			p.args_buf[p.args_len] = ' '
			p.args_len += 1
		}
		p.args_len += copy(p.args_buf[p.args_len:], argv.bytes[start:argv.ends[i]])
		start = argv.ends[i]
	}
}

Argv :: struct {
	count: int,
	ends:  [ARGV_MAX]int, // Exclusive end of each argument in `bytes`
	bytes: [abi.ARGS_MAX]u8,
	used:  int,
}

ARGV_MAX :: 64

/*
copy_argv reads a program's slice of strings into a kernel record.

Each string is a pointer and a length in the caller's memory, copied in and
checked like any other. The whole must fit `ARGS_MAX`, one must fit
`ARG_MAX`, and there may be no more than `ARGV_MAX` of them. False is a
slice that does not, or one whose memory the program does not own.
*/
@(private)
copy_argv :: proc "contextless" (addr: uintptr, count: int, into: ^Argv) -> bool {
	into.count = 0
	into.used = 0
	if count == 0 {
		return true
	}
	if count < 0 || count > ARGV_MAX || addr == 0 {
		return false
	}
	// A string is sixteen bytes: the data pointer, then the length.
	headers: [ARGV_MAX * 16]u8
	if !copy_in(addr, count * 16, headers[:]) {
		return false
	}
	for i in 0 ..< count {
		ptr := uintptr(word(headers[i * 16:]))
		length := int(word(headers[i * 16 + 8:]))
		if length < 0 || length > abi.ARG_MAX || into.used + length > abi.ARGS_MAX {
			return false
		}
		if length > 0 && !copy_in(ptr, length, into.bytes[into.used:]) {
			return false
		}
		into.used += length
		into.ends[i] = into.used
	}
	into.count = count
	return true
}

@(private = "file")
word :: proc "contextless" (b: []u8) -> u64 {
	v := u64(0)
	for i in 0 ..< 8 {
		v |= u64(b[i]) << (8 * u64(i))
	}
	return v
}

/*
stage_args writes the arguments onto a program's stack and answers where the
stack pointer and the first argument register should point.

The layout from `top` down: the bytes, the `string` records sixteen-aligned,
the `Args` record, and below it the stack pointer, tilted the way the
architecture's ABI wants a fresh stack. A program given no arguments still
gets a record, with a count of zero, so `libuser.args` has one rule.

The stack is `stack`, the process's stack segment, whose frames are written
through the direct map. Every pointer written is a program address.
*/
@(private)
stage_args :: proc "contextless" (stack: ^Segment, top: uintptr, argv: ^Argv) -> (sp: uintptr, block: uintptr, ok: bool) {
	if stack == nil {
		return 0, 0, false
	}
	count := argv != nil ? argv.count : 0
	used := argv != nil ? argv.used : 0

	bytes_at := top - uintptr(used)
	strings_at := (bytes_at - uintptr(count * 16)) & ~uintptr(15)
	block_at := strings_at - 16
	sp = block_at - uintptr(arch.USER_STACK_TILT)

	// Everything written has to be inside the stack segment.
	span := uintptr(stack.pages) * uintptr(arch.PAGE_SIZE)
	if top - block_at > span {
		return 0, 0, false
	}

	if argv != nil {
		if !stack_write(stack, top, bytes_at, argv.bytes[:used]) {
			return 0, 0, false
		}
		start := 0
		for i in 0 ..< count {
			record: [16]u8
			put_word(record[:], u64(bytes_at + uintptr(start)))
			put_word(record[8:], u64(argv.ends[i] - start))
			if !stack_write(stack, top, strings_at + uintptr(i * 16), record[:]) {
				return 0, 0, false
			}
			start = argv.ends[i]
		}
	}
	header: [16]u8
	put_word(header[:], u64(count))
	put_word(header[8:], u64(strings_at))
	if !stack_write(stack, top, block_at, header[:]) {
		return 0, 0, false
	}
	return sp, block_at, true
}

@(private = "file")
put_word :: proc "contextless" (b: []u8, v: u64) {
	for i in 0 ..< 8 {
		b[i] = u8(v >> (8 * u64(i)))
	}
}

// stack_write puts bytes at a program address inside the stack segment,
// through the frames, a page at a time. `top` is the address just past the
// segment's last byte.
@(private = "file")
stack_write :: proc "contextless" (stack: ^Segment, top: uintptr, at: uintptr, data: []u8) -> bool {
	base := top - uintptr(stack.pages) * uintptr(arch.PAGE_SIZE)
	for i in 0 ..< len(data) {
		va := at + uintptr(i)
		if va < base || va >= top {
			return false
		}
		page := int((va - base) / uintptr(arch.PAGE_SIZE))
		frame := segment_frame(stack, page)
		if frame == 0 {
			// A hole under the arguments: a long argv reaches below the
			// top page. It is filled here the way a fault would fill it,
			// except that the mapping is the caller's to make, as it makes
			// the top page's.
			fresh, ok := mem.alloc_page_zeroed()
			if !ok {
				return false
			}
			segment_set_frame(stack, page, fresh)
			frame = fresh
		}
		dst := cast([^]u8)mem.phys_to_virt(frame)
		dst[(va - base) % uintptr(arch.PAGE_SIZE)] = data[i]
	}
	return true
}

// argv_from fills a record from kernel strings, for the self-test that
// spawns a program with arguments of the kernel's choosing.
@(private)
argv_from :: proc "contextless" (into: ^Argv, strs: []string) -> bool {
	into.count = 0
	into.used = 0
	if len(strs) > ARGV_MAX {
		return false
	}
	for s, i in strs {
		if into.used + len(s) > abi.ARGS_MAX {
			return false
		}
		for k in 0 ..< len(s) {
			into.bytes[into.used + k] = s[k]
		}
		into.used += len(s)
		into.ends[i] = into.used
	}
	into.count = len(strs)
	return true
}
