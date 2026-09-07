/*
debuggee -- the program the debugger's self-test stops, reads and steps.

`docs/DEVTOOLS.md` section 7's script drives `servers/dbgfs` at this
program. It has a loop that sums into a global, a struct it fills on the
way, and a line the script breaks on by number. The script knows the answers, so
the numbers here are the numbers there. A change to a line's number is a
change to `tests/dbg.rc`.
*/
package debuggee

import "vsys:abi"
import "vsys:libuser"

Point :: struct {
	x, y: i32,
	name: string,
}

total: int = 0
last: Point = {x = 0, y = 0, name = "none"}
label: string = "debuggee"

// add is the procedure the script breaks in, with a parameter and a local
// the debugger reads.
add :: proc "contextless" (n: int) -> int {
	twice := n * 2
	total += twice
	last.x = i32(n)
	last.y = i32(twice)
	last.name = "added"
	return total
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = libuser.startup()
	for i in 1 ..= 5 {
		_ = add(i)
	}
	libuser.eprint(label, ": total is ", "done\n")
	libuser.exits("")
}
