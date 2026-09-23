/*
style -- which line of the theme set a value, `docs/WORKBENCH.md` step 5.

    style                       every role, its value and the line that set it
    style explain ROLE [APP]    every line that names ROLE, which one wins,
                                and which it beat, as program APP sees it

The look is two files merged, `/lib/theme` (or the one a `use` line names)
and `$home/lib/theme` over it, and a line may be scoped to one program,
`muidemo/face copper`. That is a cascade, and a person may not follow it.
This says. It reads what `sys/libmui` reads, with the toolkit's own parser.
*/
package style

import "vsys:abi"
import "vsys:libmui"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	out: [4096]u8
	if len(args) >= 3 && args[1] == "explain" {
		if len(args) >= 4 {
			libmui.set_app_name(args[3])
		}
		n := libmui.theme_explain(args[2], out[:])
		_ = libuser.write_full(1, out[:n])
		libuser.exits("")
	}
	if len(args) != 1 {
		libuser.eprint("usage: style [explain role [app]]\n")
		libuser.exits("usage")
	}
	// Every role: the winning line, or the chassis.
	for role in libmui.THEME_ROLES {
		n := libmui.theme_explain(role, out[:])
		text := string(out[:n])
		at := 0
		for at < len(text) {
			e := at
			for e < len(text) && text[e] != '\n' {
				e += 1
			}
			line := text[at:e]
			at = e + 1
			if len(line) >= 5 && line[len(line) - 5:] == " wins" {
				_ = libuser.write_full(1, transmute([]u8)line[:len(line) - 5])
				_ = libuser.write_full(1, transmute([]u8)string("\n"))
			}
		}
	}
	libuser.exits("")
}
