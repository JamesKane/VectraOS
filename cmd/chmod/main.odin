// chmod -- set a file's permission bits: `chmod mode file ...`, mode in octal.
// A wstat of the mode alone, which the file's server checks against who asks.
package chmod

import "vsys:abi"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)[1:]
	if len(args) < 2 {
		libuser.eprint("usage: chmod mode file ...\n")
		libuser.exits("usage")
	}
	mode: u64
	for c in transmute([]u8)args[0] {
		if c < '0' || c > '7' {
			libuser.eprint("chmod: mode is octal\n")
			libuser.exits("usage")
		}
		mode = mode * 8 + u64(c - '0')
	}
	failed := false
	for path in args[1:] {
		st: abi.Stat
		if libuser.stat(path, &st) < 0 {
			libuser.eprint("chmod: ", path, ": ", libuser.errstr(-2), "\n")
			failed = true
			continue
		}
		st.mode = st.mode & ~u32(0o777) | u32(mode & 0o777)
		if r := libuser.wstat(path, &st); r < 0 {
			libuser.eprint("chmod: ", path, ": ", libuser.errstr(r), "\n")
			failed = true
		}
	}
	libuser.exits(failed ? "failed" : "")
}
