/*
libthread -- Plan 9's threads, for a program in ring 3.

`docs/PROCS.md` step 4. A program that waits on two things needed two
processes from `servers/consrv` on, and they talked through shared
memory, rings and spinlocks. This library is the shape Plan 9 gives the
same problem, and `docs/THREAD.md` is the argument for it. The
vocabulary:

    proc      a kernel process. Made by `proccreate`, which is
              `rfork(RFPROC | RFMEM)`: a process sharing this one's memory
              and nothing else it need not.
    thread    a coroutine inside a proc. Made by `threadcreate`. Switched
              in user space, in one small `.S` per architecture, when it
              blocks on a channel, a lock, or a `yield`. Never preempted
              by another thread of its proc.
        channel   how threads and procs talk. `send` and `recv` copy one
              element and park the caller until the other side arrives, or
              until a buffer has room. `alt` waits on several at once.
    io proc   a proc that makes a blocking call for a thread, `io.odin`.
              `ioread` is a `read` a thread may make: the thread parks on a
              channel and its proc keeps running.

**A proc is the answer to blocking, still.** A thread that reads a device
parks its whole proc in the kernel, and every other thread of that proc
with it. So a thread that must block in the kernel is given a proc of its
own, and sends what it reads on a channel. The rest of the program is one
proc of threads that only ever block on each other. That proc needs no
locks at all, because a thread runs until it blocks and nothing
interleaves with it. That is the trade `docs/PROCS.md` names, and it is
the reason the servers on this library lost their state locks.

## How a proc sleeps

A proc with no thread to run parks in `rendezvous` on its own address.
`threadready`, from any proc, puts the thread on its proc's ready queue
under the proc's lock. If the proc is asleep, it meets it at the same
rendezvous. The lock passes to the sleeper without ever being free, which
is Plan 9's `_threadready` exactly. A rendezvous cannot be lost: whichever
side arrives first waits for the other.

**The program takes a rendezvous group of its own first**, `rfork(RFREND)`
in `main`, as Plan 9's `libthread` does. A tag is an address in this
program's heap, and every program's heap begins at the same address. A
fork or an exec inherits the group. Two servers started by one shell
would otherwise park on equal tags in one group, and the wake meant for
one would take the other. That was the first bug this library had.

## How a proc finds itself

Every global here is shared, so `slot` cannot be a global that says "the
current proc". It is a word in the *stack segment*, which `RFMEM` never
shares: a local in `main`'s frame, whose address every proc holds and
whose contents each proc's private copy of the stack decides. Plan 9's
`_privates` is the same trick. A new proc writes its own record there
before it does anything else.

## What a proc costs to make

`proccreate` builds the record, a thread, and a stack for the scheduler.
It then forks through `vectra_proc_fork`, which moves the child onto that
stack before it touches memory. The child cannot stay on the caller's
stack for one instruction. The caller runs on a thread's stack in the
heap, which both processes share, and a word the child pushed there lands
under the parent. The kernel copies the stack *segment*, and that is not
where a thread runs.

## Ending

`threadexits` ends the calling thread, and the proc when it was the last.
A proc other than the first simply exits. The first proc waits for the
procs it created before it goes. So the program's exit is the last of its
processes, and whoever waits for the program sees none of them left. The
kernel would collect them on its own a boundary later, through
`reparent_children`. The wait is what makes that moment the program's
rather than the reaper's.

`threadexitsall` ends the program: it notes
every other proc, waits for the ones this proc made, and exits with the
status. The other procs die at their next kernel boundary, which is the
read or the rendezvous they were parked in.
*/
package libthread

import "base:intrinsics"

import "vsys:abi"
import "vsys:libuser"
import "vsys:vectra9"

// A thread's whole life, given its argument. Contextless like everything
// in `sys/libuser`: a thread that wants a heap behind `context` builds one
// with `libuser.heap_context` on its first line.
Thread_Fn :: #type proc "contextless" (arg: rawptr)

/*
The stacks: a thread's default, the first thread's, and the scheduler's in
a proc that is not the first. A scheduler runs nothing deeper than a lock,
a rendezvous and a wait.

**No thread runs on the process's own stack**, though it grows on demand
and would be free. The stack segment is the one segment `RFMEM` does not
share, and a thread's frames are where a channel's receive buffer and an
io call's record live. Another proc that wrote its answer there would
write into its own copy of the page, and this proc would wait for ever.
So every thread's stack comes from the heap, which every proc shares, and
the first proc's scheduler is what runs on the process stack. A thread
that overruns a heap stack corrupts the heap rather than faults. The
scheduler checks the word at the bottom on every switch back, which
catches the plain overflow.
*/
STACK_DEFAULT :: 16 * 1024
MAIN_STACK :: 64 * 1024
SCHED_STACK :: 8 * 1024
STACK_MAGIC :: u64(0x5EED_57AC_C0DE_F00D)

Thread :: struct {
	id:      int,
	fn:      Thread_Fn,
	arg:     rawptr,
		stack:   []u8, // From the heap
	label:   Label,
	exited:  bool,
	owner:   ^Proc,
	next:    ^Thread, // The ready queue, or a lock's or a rendezvous's waiters

	// What the thread waits on while it does, and what it learnt when the
	// wait ended. `chan.odin`.
	alts:    []Alt,
	alt_ret: int,
}

Proc :: struct {
	lock:       libuser.Spin, // The ready queue and `asleep`
	pid:        u64,
	sched:      Label, // Where the scheduler was when it switched to a thread
		stack:      []u8, // The scheduler's own, nil for the first proc
	running:    ^Thread,
	ready_head: ^Thread,
	ready_tail: ^Thread,
	asleep:     bool, // Parked in rendezvous with nothing to run
	nthreads:   int,
	status:     string, // What the last thread to exit said
	creator:    ^Proc, // Nil for the first proc
	detached:   bool, // Made by a proc other than the first, so nobody waits for it
	next:       ^Proc,
}

// Every proc, under `procs_lock`, for `threadexitsall` to find.
procs: ^Proc
procs_lock: libuser.Spin

// The private word: see the file comment. Its address is the same in every
// proc and its contents are each proc's own.
slot: ^^Proc

next_id: int

foreign {
	// `thread_<arch>.S`. The switch saves into `from`, restores from `to`,
	// and returns into whatever `to` was doing.
	vectra_thread_switch :: proc "c" (from: ^Label, to: ^Label) ---
	// rfork by `nr` and `flags`, with the child moved onto `sp` and calling
	// `entry(arg)` there. The parent hears the pid, or the errno.
	vectra_proc_fork :: proc "c" (nr: u64, flags: u64, sp: uintptr, entry: proc "c" (arg: rawptr) -> !, arg: rawptr) -> i64 ---
}

// -- The current proc and thread -----------------------------------------------

current :: proc "contextless" () -> ^Proc {
	return slot^
}

self :: proc "contextless" () -> ^Thread {
	return slot^.running
}

threadid :: proc "contextless" () -> int {
	return self().id
}



// -- Starting ------------------------------------------------------------------

/*
main is what a program's `_start` calls. It makes the first proc out of
the calling process, runs `fn` as its first thread, and schedules from
then on. It never returns. The program ends through `threadexits` or
`threadexitsall`.

`me` is the private word, and this frame is where it lives for the life of
the program. The scheduler of the first proc runs below it on the same
stack, which is the process's own. The threads do not, for the reason
the stacks' comment gives.
*/
main :: proc "contextless" (fn: Thread_Fn, arg: rawptr, stacksize := MAIN_STACK) -> ! {
	me: ^Proc
	slot = &me
	if libuser.rfork(abi.RFREND) < 0 {
		libuser.exits("libthread: no rendezvous group")
	}
	p := proc_new()
	if p == nil {
		libuser.exits("libthread: no memory for the first proc")
	}
	p.pid = libuser.getpid()
	me = p
	if thread_new(p, fn, arg, stacksize) == nil {
		libuser.exits("libthread: no memory for the first thread")
	}
	sched(p)
}

// proc_new is a record on the list of every proc.
@(private = "file")
proc_new :: proc "contextless" () -> ^Proc {
	p := (^Proc)(libuser.heap_alloc(size_of(Proc)))
	if p == nil {
		return nil
	}
	p^ = {}
	libuser.lock(&procs_lock)
	p.next = procs
	procs = p
	libuser.unlock(&procs_lock)
	return p
}

/*
thread_new builds a thread on `p` and readies it. The stack's bottom word
is the overflow mark. `label_init` lays out its top, so the first switch
into the thread lands in `thread_launch`.
*/
@(private = "file")
thread_new :: proc "contextless" (p: ^Proc, fn: Thread_Fn, arg: rawptr, stacksize: int) -> ^Thread {
	t := (^Thread)(libuser.heap_alloc(size_of(Thread)))
	if t == nil {
		return nil
	}
	size := max(stacksize, 4096)
	stack := libuser.heap_alloc(size)
	if stack == nil {
		libuser.heap_free(t)
		return nil
	}
	t^ = {}
	t.stack = ([^]u8)(stack)[:size]
	(^u64)(stack)^ = STACK_MAGIC
	label_init(&t.label, t.stack, rawptr(thread_launch))
	t.id = intrinsics.atomic_add(&next_id, 1) + 1
	t.owner = p
	t.fn = fn
	t.arg = arg
	p.nthreads += 1
	threadready(t)
	return t
}

// thread_launch is where a thread's first switch lands: the thread's own
// procedure, and the exit when it returns.
@(private = "file")
thread_launch :: proc "c" () {
	t := self()
	t.fn(t.arg)
	threadexits("")
}

// threadcreate makes a thread in the calling proc and answers its id, or
// -1 when there was no memory for it.
threadcreate :: proc "contextless" (fn: Thread_Fn, arg: rawptr, stacksize := STACK_DEFAULT) -> int {
	t := thread_new(current(), fn, arg, stacksize)
	if t == nil {
		return -1
	}
	return t.id
}

/*
proccreate makes a proc whose first thread runs `fn`, and answers its pid,
or -1.

The parent builds the record, the thread and the scheduler's stack, and
the thread is on the new proc's ready queue before the fork.
The child arrives in `proc_entry` on the scheduler's stack with nothing
to do but write the private word and schedule.

A proc made by the first proc is waited for at the end. One made by any
other proc is detached, `RFNOWAIT`, because its maker may be gone before
it is and a wait nobody makes is a leak.
*/
proccreate :: proc "contextless" (fn: Thread_Fn, arg: rawptr, stacksize := STACK_DEFAULT) -> i64 {
	me := current()
	p := proc_new()
	if p == nil {
		return -1
	}
	p.creator = me
	p.detached = me.creator != nil
	stack := libuser.heap_alloc(SCHED_STACK)
	if stack == nil {
		return -1
	}
	p.stack = ([^]u8)(stack)[:SCHED_STACK]
	if thread_new(p, fn, arg, stacksize) == nil {
		return -1
	}
	flags := abi.RFPROC | abi.RFMEM
	if p.detached {
		flags |= abi.RFNOWAIT
	}
	pid := vectra_proc_fork(abi.SYS_RFORK, flags, stack_top(p.stack), proc_entry, p)
	if pid < 0 {
		return pid
	}
	p.pid = u64(pid)
	return pid
}

// proc_entry is a new proc's first procedure, on its scheduler's stack.
// It reads its pid rather than takes the parent's word, because the
// parent may not know it yet.
@(private = "file")
proc_entry :: proc "c" (arg: rawptr) -> ! {
	p := (^Proc)(arg)
	slot^ = p
	p.pid = libuser.getpid()
	sched(p)
}

// -- Scheduling ----------------------------------------------------------------

/*
sched is a proc's life: take the next ready thread, run it until it
switches back, and deal with what it left. A thread that exited is freed
here rather than by itself, because a thread cannot free the stack it is
standing on. A proc whose last thread is gone ends.
*/
@(private = "file")
sched :: proc "contextless" (p: ^Proc) -> ! {
	for {
		t := runthread(p)
		p.running = t
		vectra_thread_switch(&p.sched, &t.label)
		p.running = nil
				if (^u64)(raw_data(t.stack))^ != STACK_MAGIC {
			threadexitsall("libthread: thread stack overflow")
		}
		if t.exited {
			thread_free(t)
			if p.nthreads == 0 {
				proc_end(p)
			}
		}
	}
}

/*
runthread takes the head of the ready queue, or parks until there is one.

The lock discipline is Plan 9's. A proc that finds nothing marks itself
asleep, lets go of the lock, and waits at the rendezvous. The `threadready`
that wakes it holds the lock when it arrives, and does not let go. The
lock passes to this side, which takes the head and releases it.
*/
@(private = "file")
runthread :: proc "contextless" (p: ^Proc) -> ^Thread {
	libuser.lock(&p.lock)
	if p.ready_head == nil {
		p.asleep = true
		libuser.unlock(&p.lock)
		proc_meet(p)
		// The lock is this side's now, passed by the waker.
	}
	t := p.ready_head
	p.ready_head = t.next
	if p.ready_head == nil {
		p.ready_tail = nil
	}
	t.next = nil
	libuser.unlock(&p.lock)
	return t
}

// proc_meet is both halves of a proc's sleep: the sleeper and the waker
// call it with the same tag, and the kernel pairs them. A note cuts a
// rendezvous short with nothing exchanged, and the caller asks again. A
// note with no handler then ends the proc at that boundary, which is what
// `threadexitsall` counts on.
@(private = "file")
proc_meet :: proc "contextless" (p: ^Proc) {
	for {
		if _, ok := libuser.rendezvous(u64(uintptr(p)), 0); ok {
			return
		}
	}
}

/*
threadready puts a thread on its proc's ready queue and wakes the proc if
it sleeps. Any proc may call it. The queue is under the proc's lock. The
wake is the rendezvous `runthread` waits at, made *under the lock* so the
lock passes to the sleeper.
*/
threadready :: proc "contextless" (t: ^Thread) {
	p := t.owner
	libuser.lock(&p.lock)
	t.next = nil
	if p.ready_head == nil {
		p.ready_head = t
	} else {
		p.ready_tail.next = t
	}
	p.ready_tail = t
	if p.asleep {
		p.asleep = false
		proc_meet(p)
		return
	}
	libuser.unlock(&p.lock)
}

// block switches from the running thread to its proc's scheduler. The
// caller set the thread's state first and put it where its waker will
// look. It returns when something readies the thread and the scheduler
// picks it again.
block :: proc "contextless" () {
	t := self()
	vectra_thread_switch(&t.label, &t.owner.sched)
}

// yield lets every other ready thread of this proc run once.
yield :: proc "contextless" () {
	threadready(self())
	block()
}

@(private = "file")
thread_free :: proc "contextless" (t: ^Thread) {
	libuser.heap_free(raw_data(t.stack))
	libuser.heap_free(t)
}

// -- Ending --------------------------------------------------------------------

// threadexits ends the calling thread with `status`, and the proc when
// this was its last thread. The scheduler frees its stack after the
// switch away from it.
threadexits :: proc "contextless" (status: string) -> ! {
	p := current()
	t := p.running
	p.status = status
	t.exited = true
	p.nthreads -= 1
	block()
	for {
	}
}

/*
proc_end is a proc with no threads left. The first proc waits for every
proc it made, so its exit is the program's last. Any other exits at once,
and its record stays on the list. A note to a pid that ended is refused
and harmless, because a pid never reuses.
*/
@(private = "file")
proc_end :: proc "contextless" (p: ^Proc) -> ! {
	if p.creator == nil {
		wait_children(p)
	}
	libuser.exits(p.status)
}

// wait_children collects every proc `p` made and has not collected. The
// kernel's wait answers EAGAIN after its patience, and a child parked in a
// device read may take longer than that to hear its note.
@(private = "file")
wait_children :: proc "contextless" (p: ^Proc) {
	for q := procs; q != nil; q = q.next {
		if q.creator != p || q.detached || q.pid == 0 {
			continue
		}
		for {
			r := libuser.wait(q.pid)
			if r != -i64(vectra9.EAGAIN) {
				break
			}
		}
		q.pid = 0
	}
}

/*
threadexitsall ends the program with `status`.

Every other proc is noted. A proc with no handler dies at its next
kernel boundary: the read it is parked in, the rendezvous it sleeps at,
or the tick. This proc then waits for the procs it made, so the
program's exit is the last of its processes. Whoever waits for the
program hears `status` from a machine that holds nothing of it any more.
*/
threadexitsall :: proc "contextless" (status: string) -> ! {
	me := current()
	libuser.lock(&procs_lock)
	for q := procs; q != nil; q = q.next {
		if q != me && q.pid != 0 {
			_ = libuser.note(q.pid, "threadexitsall")
		}
	}
	libuser.unlock(&procs_lock)
	wait_children(me)
	libuser.exits(status)
}

// -- Small things --------------------------------------------------------------

// stack_top is the sixteen-aligned end of a stack, which is what a stack
// pointer must be before any procedure is entered on it.
stack_top :: proc "contextless" (stack: []u8) -> uintptr {
	return (uintptr(raw_data(stack)) + uintptr(len(stack))) & ~uintptr(15)
}

// A small generator for `alt`'s choice among ready channels. Plan 9 picks
// at random so no channel starves another, and this is one xorshift.
@(private)
rand_state: u64 = 0x9E37_79B9_7F4A_7C15

@(private)
rand :: proc "contextless" () -> u64 {
	x := rand_state
	x ~= x << 13
	x ~= x >> 7
	x ~= x << 17
	rand_state = x
	return x
}
