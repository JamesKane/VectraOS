/*
nstest -- the namespace as a file, `docs/FLEET.md` step 3, proven.

The kernel's self-test spawns this and reads the word it exits with: `ok`, or
the name of the first check that did not hold. It replays a namespace file with
`sys/libuser`'s `newns` -- a comment, a blank line, and a `bind` whose source
is `/n/esp/vectra/$cputype/bin` -- and checks the bind landed and `$cputype`
expanded, by resolving a known program through it. `$cputype` itself is the
variable the kernel seeds into `#e` at boot.
*/
package nstest

import "vsys:abi"
import "vsys:libuser"

want :: proc "contextless" (cond: bool, what: string) {
	if !cond {
		libuser.exits(what)
	}
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()

	// The kernel seeds `$cputype`; `newns` needs it to expand the path.
	cb: [32]u8
	want(libuser.getenv("cputype", cb[:]) != "", "cputype is set in the environment")

	// Nothing at /mnt/echo before the bind: this process's /mnt holds the
	// mount points init put there, not the tools.
	before := libuser.open("/mnt/echo", abi.O_RDONLY)
	if before >= 0 {
		_ = libuser.close(int(before))
	}
	want(before < 0, "no tool resolves under /mnt before the bind")

	// Replay the file: the comment and blank line are skipped, the bind is
	// applied with $cputype expanded.
	want(libuser.newns("/lib/nsconf"), "newns replays the namespace file")

	// The bind landed: a known program now resolves through it.
	fd := libuser.open("/mnt/echo", abi.O_RDONLY)
	want(fd >= 0, "a program resolves through the replayed bind")
	_ = libuser.close(int(fd))

	libuser.exits("ok")
}
