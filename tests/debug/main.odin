/*
debugtest -- the debug file beside a program, read back on the machine.

The kernel's self-test spawns this and reads the word it exits with: `ok`,
or the name of the first check that did not hold. The build wrote
`/lib/debug/debugtest.vxd` from this program's own ELF, `docs/DEVTOOLS.md`
section 6, and `sys/libdebug` reads it. This opens the file and finds its own
entry by name. It names one of its own procedures from an address inside
it, and finds the source line that address came from. It reads the
instruction text at the entry, which is the table an engine steps riscv64
with.
*/
package debugtest

import "vsys:abi"
import "vsys:libdebug"
import "vsys:libuser"

fail :: proc "contextless" (what: string) -> ! {
	libuser.exits(what)
}

want :: proc "contextless" (cond: bool, what: string) {
	if !cond {
		fail(what)
	}
}

ends_with :: proc "contextless" (s, tail: string) -> bool {
	return len(s) >= len(tail) && s[len(s) - len(tail):] == tail
}

// probe is a procedure with a body, so that an address inside it names it
// and lands on a line of this file.
probe :: proc "contextless" (x: int) -> int {
	y := x * 3
	y += 7
	return y
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	data, ok := libuser.read_file("/lib/debug/debugtest.vxd", context.allocator)
	want(ok && len(data) > 0, "the debug file opens")
	d, dok := libdebug.open(data)
	want(dok, "and is a debug file this reader knows")
	want(libdebug.count(&d, .Units) >= 1, "with a compilation unit in it")
	want(libdebug.count(&d, .Procs) > 10, "and the program's procedures")

	entry := u64(uintptr(rawptr(start)))
	low, high, found := libdebug.lookup(&d, "_start")
	want(found && low == entry && high > low, "the entry resolves by name to where it is")

	inside := u64(uintptr(rawptr(probe))) + 2
	name, plow, pok := libdebug.proc_at(&d, inside)
	want(pok && ends_with(name, "probe") && plow == u64(uintptr(rawptr(probe))), "an address inside a procedure names it")

	file, line, lok := libdebug.line_at(&d, inside)
	want(lok && ends_with(file, "tests/debug/main.odin") && line > 20 && line < 60, "and says which line of this file it came from")

	text, tok := libdebug.dis_at(&d, entry)
	want(tok && len(text) > 0, "the entry has its instruction text")
	next, nok := libdebug.dis_next(&d, entry)
	want(nok && next > entry && next < entry + 16, "and the instruction after it is known")

	_ = probe(1)
	libuser.exits("ok")
}
