// cmp -- compare two files byte by byte. -s says nothing and only exits.
package cmp

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	silent := false
	if len(args) > 0 && args[0] == "-s" {
		silent = true
		args = args[1:]
	}
	if len(args) != 2 {
		libuser.eprint("usage: cmp [-s] file1 file2\n")
		libuser.exits("usage")
	}
	a, aok := libuser.read_file(args[0], context.allocator)
	if !aok {
		libuser.eprint("cmp: can't open ", args[0], "\n")
		libuser.exits("can't open")
	}
	b, bok := libuser.read_file(args[1], context.allocator)
	if !bok {
		libuser.eprint("cmp: can't open ", args[1], "\n")
		libuser.exits("can't open")
	}
	line := 1
	for i in 0 ..< min(len(a), len(b)) {
		if a[i] != b[i] {
			if !silent {
				num: [24]u8
				lnum: [24]u8
				libuser.eprint(args[0], " ", args[1], " differ: char ", libuser.itoa(num[:], i64(i + 1)), " line ", libuser.itoa(lnum[:], i64(line)), "\n")
			}
			libuser.exits("differ")
		}
		if a[i] == '\n' {
			line += 1
		}
	}
	if len(a) != len(b) {
		if !silent {
			libuser.eprint("cmp: EOF on ", len(a) < len(b) ? args[0] : args[1], "\n")
		}
		libuser.exits("differ")
	}
	libuser.exits("")
}
