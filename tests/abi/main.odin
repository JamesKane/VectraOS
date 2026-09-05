/*
abitest -- the process ABI, exercised from ring 3.

The first program built the way every tool after it will be: a context with
a heap, arguments from the kernel, `libfmt.print`, and `exits`
with a word. It runs every call `docs/SHELL.md` step 1 added, in order, and
says `ok` if each held or the name of the first that did not. The kernel's
self-test spawns it with three arguments and reads the word.

Spawned with `--child` it says so and stops, which is how it checks that a
program it spawns gets the arguments it named. Spawned with `--env` it says
what `/env/abitest` holds, which is how it checks that a spawned program's
environment is a copy of its parent's.
*/
package abitest

import "base:intrinsics"
import "core:fmt"

import "vsys:abi"
import "vsys:libfmt"
import "vsys:libuser"
import "vsys:vectra9"

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
	if len(args) == 2 && args[1] == "--env" {
		// What the spawner left in its environment is what this copy holds.
		word: [abi.EXITS_MAX]u8
		value: [32]u8
		n := libuser.read(int(libuser.open("/env/abitest", abi.O_RDONLY)), value[:])
		libuser.exits(fmt.bprintf(word[:], "env %s", n > 0 ? string(value[:n]) : "unset"))
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
	// `/dev` is a union of the console device and the disk device, so a
	// listing comes back a member at a time: read until a call answers zero,
	// which is the end of the whole union rather than the end of one member.
	total := 0
	saw_cons := false
	got: i64
	for {
		got = libuser.dirread(int(dev), entries[:])
		if got <= 0 {
			break
		}
		for i in 0 ..< got {
			e := &entries[i]
			if string(e.name[:e.name_len]) == "cons" {
				saw_cons = true
			}
		}
		total += int(got)
	}
	if total < 5 {
		fail("dirread")
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

	// -- The environment: a directory of variables, one per process --------
	if libuser.stat("/env/abitest", &st) >= 0 {
		fail("env clean")
	}
	ev := libuser.create("/env/abitest", abi.O_WRONLY, 0o666)
	if ev < 0 {
		fail("env create")
	}
	if libuser.write(int(ev), transmute([]u8)string("hello")) != 5 || libuser.close(int(ev)) != 0 {
		fail("env write")
	}
	if libuser.create("/env/abitest", abi.O_WRONLY, 0o666) >= 0 {
		fail("env create twice")
	}
	ev = libuser.open("/env/abitest", abi.O_RDONLY)
	n = libuser.read(int(ev), scratch[:])
	if ev < 0 || n != 5 || string(scratch[:5]) != "hello" || libuser.close(int(ev)) != 0 {
		fail("env read")
	}
	ev = libuser.open("/env/abitest", abi.O_WRONLY | abi.O_TRUNC)
	if ev < 0 || libuser.write(int(ev), transmute([]u8)string("there")) != 5 || libuser.close(int(ev)) != 0 {
		fail("env truncate")
	}
	if libuser.stat("/env/abitest", &st) != 0 || st.length != 5 || string(st.name[:st.name_len]) != "abitest" {
		fail("env stat")
	}
	envdir := libuser.open("/env", abi.O_RDONLY)
	got = libuser.dirread(int(envdir), entries[:])
	saw_var := false
	for i in 0 ..< got {
		if string(entries[i].name[:entries[i].name_len]) == "abitest" {
			saw_var = true
		}
	}
	if envdir < 0 || !saw_var || libuser.close(int(envdir)) != 0 {
		fail("env list")
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

	// -- A spawned program holds a copy of the environment -----------------
	argv_env := [?]string{"abitest", "--env"}
	pid = libuser.spawn("/bin/abitest", abi.SPAWN_NS_COPY, argv_env[:])
	n = libuser.await(u64(pid), said[:])
	if pid <= 0 || n <= 0 || string(said[:n]) != fmt.bprintf(want[:], "%d env there", pid) {
		fail("env spawn")
	}

	// -- A fork copies it under RFENVG, and starts clean under RFCENVG ------
	copier := libuser.rfork(abi.RFPROC | abi.RFFDG | abi.RFENVG)
	if copier == 0 {
		ev = libuser.open("/env/abitest", abi.O_WRONLY | abi.O_TRUNC)
		_ = libuser.write(int(ev), transmute([]u8)string("changed"))
		libuser.exits("changed")
	}
	n = libuser.await(u64(copier), said[:])
	if copier < 0 || n <= 0 || string(said[:n]) != fmt.bprintf(want[:], "%d changed", copier) {
		fail("env rfork")
	}
	ev = libuser.open("/env/abitest", abi.O_RDONLY)
	n = libuser.read(int(ev), scratch[:])
	if n != 5 || string(scratch[:5]) != "there" || libuser.close(int(ev)) != 0 {
		fail("env copy")
	}
	cleaner := libuser.rfork(abi.RFPROC | abi.RFFDG | abi.RFCENVG)
	if cleaner == 0 {
		libuser.exits(libuser.stat("/env/abitest", &st) >= 0 ? "saw" : "clean")
	}
	n = libuser.await(u64(cleaner), said[:])
	if cleaner < 0 || n <= 0 || string(said[:n]) != fmt.bprintf(want[:], "%d clean", cleaner) {
		fail("env clean fork")
	}
	sharer := libuser.rfork(abi.RFPROC | abi.RFFDG)
	if sharer == 0 {
		libuser.exit(libuser.remove("/env/abitest") == 0 ? 0 : 1)
	}
	n = libuser.await(u64(sharer), said[:])
	if sharer < 0 || n <= 0 || string(said[:n]) != fmt.bprintf(want[:], "%d", sharer) {
		fail("env share")
	}
	if libuser.stat("/env/abitest", &st) >= 0 {
		fail("env remove")
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

	// -- A heap written after a fork still grows ---------------------------
	/*
	A fork marks a run copy-on-write, and the parent's first write to it
	copies that page, which turns the run into the list shape. `segbrk` has
	to find the segment by what it is, not by its shape, or a shell that
	forked a program could never grow its heap again. The child sleeps so the
	parent's write is the one that copies, and then grows its own copy too.
	*/
	PAGE :: 4096
	run, rerr := libuser.segalloc(2 * PAGE)
	if rerr != 0 {
		fail("segalloc run")
	}
	holder := libuser.rfork(abi.RFPROC | abi.RFFDG)
	if holder == 0 {
		_ = libuser.sleep(20)
		(cast(^u8)run)^ = 2
		if libuser.segbrk(run, run + 4 * PAGE) != 0 {
			libuser.exits("child segbrk")
		}
		(cast(^u8)(run + 3 * PAGE))^ = 3
		libuser.exit(0)
	}
	if holder < 0 {
		fail("rfork holder")
	}
	(cast(^u8)run)^ = 1
	if libuser.segbrk(run, run + 4 * PAGE) != 0 {
		fail("segbrk after fork")
	}
	(cast(^u8)(run + 3 * PAGE))^ = 4
	n = libuser.await(u64(holder), said[:])
	if n <= 0 || string(said[:n]) != fmt.bprintf(want[:], "%d", holder) {
		fail("child segbrk after fork")
	}
	if (cast(^u8)run)^ != 1 || libuser.segdetach(run) != 0 {
		fail("run after fork")
	}

	// -- A sleep past the old cap, and a rendezvous between two processes --
	if libuser.sleep(150) != 150 {
		fail("sleep long")
	}
	meeter := libuser.rfork(abi.RFPROC | abi.RFFDG)
	if meeter == 0 {
		got, rok := libuser.rendezvous(0x5EED, 8)
		libuser.exits(rok && got == 7 ? "met" : "missed")
	}
	partner, rok := libuser.rendezvous(0x5EED, 7)
	if meeter < 0 || !rok || partner != 8 {
		fail("rendezvous")
	}
	n = libuser.await(u64(meeter), said[:])
	if n <= 0 || string(said[:n]) != fmt.bprintf(want[:], "%d met", meeter) {
		fail("rendezvous child")
	}

	// -- A semaphore in shared memory, released to a waiting child ---------
	intrinsics.atomic_store(&gate, 0)
	waiter := libuser.rfork(abi.RFPROC | abi.RFFDG | abi.RFMEM)
	if waiter == 0 {
		libuser.exits(libuser.semacquire(&gate, true) == 1 ? "passed" : "blocked")
	}
	_ = libuser.sleep(5)
	if waiter < 0 || libuser.semrelease(&gate, 1) != 0 {
		fail("semrelease")
	}
	n = libuser.await(u64(waiter), said[:])
	if n <= 0 || string(said[:n]) != fmt.bprintf(want[:], "%d passed", waiter) {
		fail("semacquire")
	}
	if libuser.semacquire(&gate, false) != 0 {
		fail("semaphore count")
	}

	// -- An alarm, which is a note this program catches ----------------------
	intrinsics.atomic_store(&alarmed, 0)
	if libuser.notify(uintptr(rawptr(alarm_handler))) != 0 {
		fail("notify")
	}
	if libuser.alarm(20) != 0 {
		fail("alarm set")
	}
	slept := libuser.sleep(500)
	if slept != -i64(vectra9.EINTR) {
		fail("alarm sleep")
	}
	// The note is delivered at the next boundary, which this call is.
	_ = libuser.sleep(1)
	if intrinsics.atomic_load(&alarmed) != 1 {
		fail("alarm")
	}
	_ = libuser.notify(0)

	libuser.exits("ok")
}

// The semaphore the fork shares, and the alarm's count.
gate: i64
alarmed: i64

// alarm_handler counts the note and carries on.
alarm_handler :: proc "c" (ureg: rawptr, note: cstring) {
	_ = ureg
	if string(note) == "alarm" {
		intrinsics.atomic_add(&alarmed, 1)
	}
	libuser.noted(abi.NCONT)
}
