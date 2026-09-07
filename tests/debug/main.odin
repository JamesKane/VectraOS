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

// A global with a type of this program's own, so the file carries a
// variable at an address and a struct with members to find by name.
Point :: struct {
	x, y: i32,
	tag:  u8,
}

origin: Point = {x = 3, y = 4, tag = 'o'}
counter: int = 7

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

	// -- Variables, scopes and types ----------------------------------------

	c, cok := libdebug.var_at(&d, entry, "counter")
	want(cok && c.kind == .Addr && c.offset == i64(uintptr(&counter)), "a global resolves by name to its address")
	ct, _, ctok := libdebug.type_resolved(&d, int(c.type))
	want(ctok && ct.kind == .Base && ct.size == 8 && ct.name == "int", "with its type followed through the typedef to int")

	o, ook := libdebug.var_at(&d, entry, "origin")
	want(ook && o.kind == .Addr && o.offset == i64(uintptr(&origin)), "a global of a struct type resolves too")
	ot, _, otok := libdebug.type_resolved(&d, int(o.type))
	want(otok && ot.kind == .Struct && ot.size == size_of(Point) && ot.count == 3, "with its struct's size and member count")
	mname, mtype, moff, mok := libdebug.member_row(&d, int(ot.first) + 1)
	want(mok && mname == "y" && moff == 4, "and its second member named at its offset")
	mt, _, mtok := libdebug.type_resolved(&d, int(mtype))
	want(mtok && mt.kind == .Base && mt.size == 4, "of a four-byte base type")

	pi, pok2 := libdebug.type_named(&d, "debugtest::Point")
	want(pok2 && pi >= 0, "and the struct is found by its own name")

	sc, sok := libdebug.scope_at(&d, inside)
	want(sok, "an address inside probe is inside a scope")
	_, scope, pok3 := libdebug.scope_proc(&d, sc)
	want(pok3 && ends_with(scope.name, "::probe"), "whose procedure is probe")
	xv, xok := libdebug.var_at(&d, inside, "x")
	want(xok && xv.name == "x", "whose parameter x is known there")
	xt, _, xtok := libdebug.type_resolved(&d, int(xv.type))
	want(xtok && xt.kind == .Base && xt.size == 8, "as an eight-byte integer")
	gc, gok := libdebug.var_at(&d, inside, "counter")
	want(gok && gc.kind == .Addr, "and the unit's globals are visible from inside it")

	_ = probe(int(counter))

	_ = probe(1)
	libuser.exits("ok")
}
