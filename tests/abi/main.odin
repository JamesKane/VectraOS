/*
abitest -- the process ABI, exercised from ring 3.

The first program built the way every tool after it will be: a context with
a heap, arguments from the kernel, `libfmt.print`, and `exits`
with a word. It runs every call `docs/SHELL.md` step 1 added, in order, and
says `ok` if each held or the name of the first that did not. The kernel's
self-test spawns it with three arguments and reads the word.

Spawned with `--child` it says so and stops, which is how it checks that a
program it spawns gets the arguments it named.
*/
package abitest

import "core:fmt"

import "vsys:abi"
import "vsys:libfmt"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	main(libuser.args(block))
}

fail :: proc(what: string) -> ! {
	libfmt.print("abitest: failed at %s\n", what)
	libuser.exits(what)
}

main :: proc(args: []string) {
	if len(args) == 2 && args[1] == "--child" {
		libuser.exits("child saw 2")
	}

	// -- The arguments -------------------------------------------------------
	if len(args) != 4 || args[0] != "abitest" || args[1] != "one" || args[2] != "two" || args[3] != "three" {
		fail("args")
	}

	// -- The heap, and a print through it ----------------------------------
	list := make([dynamic]string)
	append(&list, "one")
	append(&list, "two")
	if len(list) != 2 || list[1] != "two" {
		fail("heap")
	}
	delete(list)
	if libfmt.print("abitest: %d arguments, heap live\n", len(args)) <= 0 {
		fail("print")
	}

	// -- A current directory, and a name relative to it -------------------
	if libuser.chdir("/dev") != 0 {
		fail("chdir")
	}
	wd: [64]u8
	n := libuser.getwd(wd[:])
	if n <= 0 || string(wd[:n]) != "/dev" {
		fail("getwd")
	}
	if libuser.chdir("nope") == 0 {
		fail("chdir nope")
	}
	cons := libuser.open("cons", abi.O_WRONLY)
	if cons < 0 {
		fail("relative open")
	}
	if libuser.chdir("..") != 0 || libuser.getwd(wd[:]) != 1 || wd[0] != '/' {
		fail("chdir ..")
	}

	// -- stat, fstat, dirread ---------------------------------------------
	st: abi.Stat
	if libuser.stat("/dev/null", &st) != 0 || st.mode & abi.DMDIR != 0 || string(st.name[:st.name_len]) != "null" {
		fail("stat null")
	}
	if libuser.stat("/dev", &st) != 0 || st.mode & abi.DMDIR == 0 {
		fail("stat dev")
	}
	if libuser.stat("/dev/nope", &st) >= 0 {
		fail("stat nope")
	}
	if libuser.fstat(int(cons), &st) != 0 || st.mode & abi.DMDIR != 0 {
		fail("fstat")
	}
	dev := libuser.open("/dev", abi.O_RDONLY)
	if dev < 0 {
		fail("open dev")
	}
	entries: [16]abi.Dirent
	got := libuser.dirread(int(dev), entries[:])
	if got < 5 {
		fail("dirread")
	}
	saw_cons := false
	for i in 0 ..< got {
		e := &entries[i]
		if string(e.name[:e.name_len]) == "cons" {
			saw_cons = true
		}
	}
	if !saw_cons {
		fail("dirread cons")
	}
	if libuser.dirread(int(dev), entries[:]) != 0 {
		fail("dirread end")
	}
	if libuser.dirread(int(cons), entries[:]) >= 0 {
		fail("dirread file")
	}

	// -- dup, and the two calls with an offset ------------------------------
	if libuser.dup(int(cons), 7) != 7 {
		fail("dup")
	}
	if libuser.write(7, transmute([]u8)string("abitest: through the duplicate\n")) <= 0 {
		fail("write dup")
	}
	if libuser.close(7) != 0 || libuser.write(7, transmute([]u8)string("x")) >= 0 {
		fail("close dup")
	}
	low := libuser.dup(int(cons))
	if low < 0 || low == cons {
		fail("dup lowest")
	}
	zero := libuser.open("/dev/zero", abi.O_RDONLY)
	scratch: [32]u8
	scratch[0] = 0xFF
	if libuser.pread(int(zero), scratch[:], 100) != 32 || scratch[0] != 0 {
		fail("pread")
	}
	null := libuser.open("/dev/null", abi.O_WRONLY)
	if libuser.pwrite(int(null), scratch[:8], 4096) != 8 {
		fail("pwrite")
	}

	// -- A program spawned with arguments, and the word it says ------------
	argv := [?]string{"abitest", "--child"}
	pid := libuser.spawn("/bin/abitest", abi.SPAWN_NS_COPY, argv[:])
	if pid <= 0 {
		fail("spawn")
	}
	said: [96]u8
	n = libuser.await(u64(pid), said[:])
	want: [64]u8
	if n <= 0 || string(said[:n]) != fmt.bprintf(want[:], "%d child saw 2", pid) {
		fail("await spawn")
	}

	// -- A fork whose child says a word, and one that says nothing --------
	child := libuser.rfork(abi.RFPROC | abi.RFFDG)
	if child == 0 {
		libuser.exits("forked")
	}
	if child < 0 {
		fail("rfork")
	}
	n = libuser.await(u64(child), said[:])
	if n <= 0 || string(said[:n]) != fmt.bprintf(want[:], "%d forked", child) {
		fail("await fork")
	}
	quiet := libuser.rfork(abi.RFPROC | abi.RFFDG)
	if quiet == 0 {
		libuser.exit(0)
	}
	n = libuser.await(u64(quiet), said[:])
	if n <= 0 || string(said[:n]) != fmt.bprintf(want[:], "%d", quiet) {
		fail("await quiet")
	}

	libuser.exits("ok")
}
