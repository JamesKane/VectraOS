/*
threadtest -- `sys/libthread`, exercised from ring 3.

The kernel's self-test spawns this program and reads the word it exits
with. The word is `ok` when every step held, or the name of the first
that did not. The steps are the library's claims in `docs/THREAD.md`, in
order.

Threads switch and yield in turn. A channel meets and a buffer queues.
`alt` picks what can go and refuses to wait when told. A proc runs while
this one's threads keep running.

A `QLock` hands over in order. A `Rendez` wakes a sleeper.
`threadexitsall` takes the other procs down with it.
*/
package threadtest

import "base:intrinsics"

import "vsys:abi"
import "vsys:libthread"
import "vsys:libuser"

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = libuser.startup()
	libthread.main(threadmain, nil)
}

fail :: proc "contextless" (what: string) -> ! {
	libthread.threadexitsall(what)
}

// -- Threads take turns ----------------------------------------------------------

// Two threads append their letters to a log, yielding after each, so the
// log says whether a yield really hands the proc to the other.
turns: [16]u8
turns_n: int

turn_thread :: proc "contextless" (arg: rawptr) {
	letter := u8(uintptr(arg))
	for _ in 0 ..< 3 {
		if turns_n < len(turns) {
			turns[turns_n] = letter
			turns_n += 1
		}
		libthread.yield()
	}
}

// -- A channel between threads ---------------------------------------------------

counter_thread :: proc "contextless" (arg: rawptr) {
	c := (^libthread.Chan)(arg)
	for i in 1 ..= 5 {
		libthread.sendul(c, u64(i))
	}
}

// -- A proc of its own ------------------------------------------------------------

// The proc parks in the kernel for a few ticks before it sends, which is
// the time this proc's threads must keep running through.
sleeper_proc :: proc "contextless" (arg: rawptr) {
	c := (^libthread.Chan)(arg)
	_ = libuser.sleep(20)
	libthread.sendul(c, libuser.getpid())
}

spins: int

spin_thread :: proc "contextless" (arg: rawptr) {
	stop := (^bool)(arg)
	for !intrinsics.volatile_load(stop) {
		spins += 1
		libthread.yield()
	}
}

// A thread that reads one end of a pipe through an io proc. The proc is
// seen to keep running while the read parks in the kernel.
io_got: [8]u8
io_n: i64

io_thread :: proc "contextless" (arg: rawptr) {
	fd := int(uintptr(arg))
	io := libthread.ioproc()
	if io == nil {
		fail("ioproc")
	}
	io_n = libthread.ioread(io, fd, io_got[:])
}

// A proc that lives until the program ends, parked in a read nobody will
// answer, so `threadexitsall` has something to take down.
parked_proc :: proc "contextless" (arg: rawptr) {
	_ = arg
	for {
		_ = libuser.sleep(1_000_000)
	}
}

// -- A lock, and a condition under it ------------------------------------------------

lk: libthread.QLock
order: [8]u8
order_n: int

locker_thread :: proc "contextless" (arg: rawptr) {
	letter := u8(uintptr(arg))
	libthread.qlock(&lk)
	if order_n < len(order) {
		order[order_n] = letter
		order_n += 1
	}
	libthread.qunlock(&lk)
}

rz: libthread.Rendez
rz_flag: bool
rz_woken: bool

waiter_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	libthread.qlock(&lk)
	for !rz_flag {
		libthread.rsleep(&rz)
	}
	rz_woken = true
	libthread.qunlock(&lk)
}

// -- The steps ------------------------------------------------------------------------

threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	if libthread.threadid() != 1 {
		fail("first thread id")
	}

	// -- Threads take turns ------------------------------------------------
	if libthread.threadcreate(turn_thread, rawptr(uintptr('a'))) < 0 || libthread.threadcreate(turn_thread, rawptr(uintptr('b'))) < 0 {
		fail("threadcreate")
	}
	for turns_n < 6 {
		libthread.yield()
	}
	if string(turns[:6]) != "ababab" {
		fail("yield order")
	}

	// -- A meeting, and a queue --------------------------------------------
	meet := libthread.chancreate(8, 0)
	if meet == nil || libthread.threadcreate(counter_thread, meet) < 0 {
		fail("chancreate")
	}
	for i in 1 ..= 5 {
		if libthread.recvul(meet) != u64(i) {
			fail("recv in order")
		}
	}
	if _, got := libthread.nbrecvul(meet); got {
		fail("nbrecv on an empty meeting")
	}

	q := libthread.chancreate(8, 3)
	if q == nil {
		fail("chancreate buffered")
	}
	for i in 1 ..= 3 {
		if !libthread.nbsendul(q, u64(i)) {
			fail("nbsend into room")
		}
	}
	if libthread.nbsendul(q, 4) {
		fail("nbsend into a full buffer")
	}
	if libthread.chan_count(q) != 3 {
		fail("chan_count")
	}
	for i in 1 ..= 3 {
		if v, got := libthread.nbrecvul(q); !got || v != u64(i) {
			fail("buffered order")
		}
	}

	// -- alt: what can go, and a refusal to wait ---------------------------
	other := libthread.chancreate(8, 1)
	if other == nil {
		fail("chancreate other")
	}
	v: u64
	arms := [3]libthread.Alt{{c = q, v = &v, op = .Recv}, {c = other, v = &v, op = .Recv}, {op = .Noblock}}
	if libthread.alt(arms[:]) != -1 {
		fail("alt with nothing ready")
	}
	libthread.sendul(other, 77)
	if libthread.alt(arms[:]) != 1 || v != 77 {
		fail("alt picks the ready arm")
	}
	// And one that waits: the counter thread fills `q` while this alt is
	// parked on both.
	if libthread.threadcreate(counter_thread, q) < 0 {
		fail("threadcreate counter")
	}
	wait_arms := [2]libthread.Alt{{c = q, v = &v, op = .Recv}, {c = other, v = &v, op = .Recv}}
	if libthread.alt(wait_arms[:]) != 0 || v != 1 {
		fail("alt parks and wakes")
	}
	for i in 2 ..= 5 {
		if libthread.recvul(q) != u64(i) {
			fail("the rest of the queue")
		}
	}

	// -- A proc of its own -------------------------------------------------
	from_proc := libthread.chancreate(8, 0)
	if from_proc == nil {
		fail("chancreate from_proc")
	}
	pid := libthread.proccreate(sleeper_proc, from_proc)
	if pid <= 0 {
		fail("proccreate")
	}
	stop := false
	if libthread.threadcreate(spin_thread, &stop) < 0 {
		fail("threadcreate spinner")
	}
	if libthread.recvul(from_proc) != u64(pid) {
		fail("the proc's word")
	}
	intrinsics.volatile_store(&stop, true)
	if spins < 100 {
		fail("threads ran while the proc slept")
	}
	if libthread.proccreate(parked_proc, nil) <= 0 {
		fail("proccreate parked")
	}

	// -- A read through an io proc parks the thread and not the proc -------
	packed := libuser.pipe()
	if packed < 0 {
		fail("pipe")
	}
	end0, end1 := abi.pipe_ends(packed)
	if libthread.threadcreate(io_thread, rawptr(uintptr(end0))) < 0 {
		fail("threadcreate io")
	}
	for _ in 0 ..< 20 {
		libthread.yield()
	}
	if io_n != 0 {
		fail("ioread answered before anything was written")
	}
	word := "io"
	if libuser.write(end1, transmute([]u8)word) != 2 {
		fail("write to the pipe")
	}
	for io_n == 0 {
		libthread.yield()
	}
	if io_n != 2 || string(io_got[:2]) != "io" {
		fail("ioread")
	}

	// -- A lock hands over in order ----------------------------------------
	libthread.qlock(&lk)
	for letter in "xyz" {
		if libthread.threadcreate(locker_thread, rawptr(uintptr(letter))) < 0 {
			fail("threadcreate locker")
		}
	}
	// Let each of them queue on the lock before it is released.
	for _ in 0 ..< 4 {
		libthread.yield()
	}
	if order_n != 0 {
		fail("a held lock admits nobody")
	}
	libthread.qunlock(&lk)
	for order_n < 3 {
		libthread.yield()
	}
	if string(order[:3]) != "xyz" {
		fail("lock order")
	}

	// -- A condition wakes its sleeper -------------------------------------
	rz.l = &lk
	if libthread.threadcreate(waiter_thread, nil) < 0 {
		fail("threadcreate waiter")
	}
	for _ in 0 ..< 2 {
		libthread.yield()
	}
	if rz_woken {
		fail("a sleeper woke early")
	}
	libthread.qlock(&lk)
	rz_flag = true
	if !libthread.rwakeup(&rz) {
		fail("rwakeup found nobody")
	}
	libthread.qunlock(&lk)
	for !rz_woken {
		libthread.yield()
	}

	libthread.chanfree(meet)
	libthread.chanfree(q)
	libthread.chanfree(other)
	libthread.chanfree(from_proc)
	libthread.threadexitsall("ok")
}
