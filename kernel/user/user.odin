/*
Ring 3: running code the kernel does not trust, and getting back.

Everything before this milestone ran at the privilege the loader handed over.
The scheduler switched stacks, the address spaces switched page tables, and all
of it was one program with many threads. This is where that stops being true.

**A program is bytes. A process is what runs them.** That distinction is the
whole of this file's vocabulary and it took three milestones to earn:

    a program     an image, in `program.odin`, and nothing that runs
    a process     an address space, a namespace, and a set of open files

The order the three arrived in was deliberate, and each unblocked the next:

    ring 3        a thread can run somewhere it cannot damage the kernel
    a syscall     it can ask for something anyway
    a process     what it asks for belongs to it rather than to the kernel

## What makes this ring 3 rather than a jump

Three things, and each has a way of failing that looks like something else.

**The selectors in the frame.** `arch.thread_user_init` puts `USER_CODE_SEL|3`
in CS. The RPL is what turns the trap tail's `iretq` into a privilege change.
With RPL 0 the same `iretq` runs the same bytes at ring 0. Every test of a
program then still passes, except the ones about privilege.

**A stack the CPU can push onto.** A trap from ring 3 loads RSP from the TSS
before it pushes anything. `sched.reschedule` writes the incoming thread's own
kernel stack there. A stale value is not a fault. The report of the problem is
the push with nowhere to go, so it is a triple fault and a reset.

**Somewhere for the fault to go.** A program's fault is an ordinary event and
the kernel's is not. `arch.set_user_trap_handler` is a separate table for
exactly that reason, and `on_trap` below is what ends a program instead of the
machine.

## What a process owns

Segments, an address space, a namespace, and a table of open files.

The frames are the *segments'*, not the space's, because `mem.space_destroy`
frees page tables and never leaves. `segment.odin` is the owner that
division always pointed at, and the reference count there is what lets two
processes share one segment's frames.

**The namespace is a copy, and that is the point of having one.** `ns_fork`
with `.Copy` duplicates the mount table and shares the member chans. A process
can therefore rearrange its own view of the tree, and nothing else sees the
change. `kernel/vfs` was built for that four milestones before anything could
use it.

Descriptors 0, 1 and 2 come open on `/dev/cons`, which is the convention every
system with a shell keeps. Nothing reads 0 yet, and a read of it would park
until somebody types, which is the correct answer rather than a bug.

## What ends a process

`SYS_EXIT`, or a fault. Nothing else, and in particular not the kernel.
`destroy` refuses a process that is still running rather than free the tables
underneath it, because its thread is translating through them. Plan 9 ends a
process with a note. That is the missing piece by its proper name.
*/
package user

import "base:intrinsics"

import "kernel:arch"
import "kernel:devfs"
import "vsys:vectra9"
import "kernel:env"
import "kernel:mem"
import "kernel:sched"
import "kernel:sync"
import "kernel:vfs"
import "vsys:abi"

/*
Where a program's three pages go.

Low, fixed, and the same for every program, which is what a space is for. Two
programs both start at `TEXT_VA` and neither can see the other's. The number is
an index into a table only one of them has.

The stack page sits below `STACK_TOP`, so the first push writes inside it.
`STACK_TOP` itself is the first address past the end, which is the convention
every stack pointer follows. That is also why it is 16-byte aligned rather than
a page boundary minus something.
*/
TEXT_VA :: uintptr(0x0040_0000)
DATA_VA :: uintptr(0x0040_1000)
STACK_TOP :: uintptr(0x7FFF_F000)
STACK_VA :: STACK_TOP - uintptr(arch.PAGE_SIZE)

/*
What a VECTRA02 program gets that a blob does not.

Four pages of stack rather than one, because compiled code spends stack the
way assembler never did -- a codec frame here, a message union there. And a
frame budget rather than a page. Sixty-four pages is a quarter megabyte,
which is five of today's `ramfs`, and it is a *format* bound. A program that
outgrows it asks this constant to move, visibly, rather than quietly taking
the machine.
*/
// 1 MiB per segment, up from 512 KiB: a program that carries `core:crypto`
// carries its tables -- the P-256 field multiples, the AES box, the SHA
// constants -- and the first that did (the TLS 1.3 client `docs/WEB.md` step 0
// builds, and the crypto self-test that proves its substrate) was 513 KiB of
// text and rodata, one page past the old bound. The earlier move, 256 KiB to
// 512, was for a tool that formats through `core:fmt` and so carries the
// runtime's type tables.
MAX_PROGRAM_FRAMES :: 256
STACK_PAGES2 :: 16
STACK_VA2 :: STACK_TOP - uintptr(STACK_PAGES2 * arch.PAGE_SIZE)

/*
How a program ended.

Filled in by `on_trap`, in interrupt context, on the thread that faulted.
`done` is stored last and volatile, because it is what the observer polls. A
reader that saw `done` set has therefore seen every field before it.

`kind` and `error_code` together are the whole answer to what a program did
wrong. A page fault at an address the kernel maps, and one at an address
nothing maps, are the same `kind` with different error codes. That difference
is exactly the thing this milestone is about.
*/
Exit :: struct {
	done:       bool,
	kind:       arch.Trap_Kind,
	vector:     u64,
	error_code: u64,
	has_error:  bool,
	ip:         uintptr,
	address:    uintptr, // CR2, and meaningful only for a page fault
	present:    bool,    // Whether a page was mapped there, which the VMM says
	from_user:  bool,    // The trap was taken in ring 3 rather than in the kernel

	/*
	The program's own stack pointer at the moment of the fault, and the address
	the kernel's frame was built at.

	Two different address spaces in two fields, which is the point of keeping
	both. `sp` is a number in the program's space and means nothing in the
	kernel's. `kstack` is in the kernel's, and has to fall inside the faulting
	thread's own kernel stack. That is what the TSS said, and what the CPU used
	before anything in software could check it.
	*/
	sp:         uintptr,
	kstack:     uintptr,

	// What the program said with `exits`, for `await` to repeat. Empty for
	// a program that used the numeric `exit`, whose number is `status`.
	text:     [EXITS_MAX]u8,
	text_len: int,

	/*
	Whether the program asked to stop, and what it said on the way out.

	`deliberate` is the difference between the two ways out of ring 3 that
	exist. A fault fills `kind` and `error_code` and says what the CPU refused.
	`SYS_EXIT` fills `status` and says what the program chose. Both fill the
	fields above, because both have a frame to fill them from.
	*/
	deliberate: bool,
	status:     u64,

	// Whether a note is what ended it. Never true beside `deliberate`: a
	// noted process dies at a boundary it did not choose to cross that way.
	noted:      bool,
}

// record_frame fills the fields every ending has a frame for: where the
// program was, its stack, the kernel's frame, and which ring it came from.
@(private)
record_frame :: proc "contextless" (e: ^Exit, frame: ^arch.Trap_Frame) {
	e.ip = arch.frame_ip(frame)
	e.sp = arch.frame_sp(frame)
	e.kstack = uintptr(rawptr(frame))
	e.from_user = arch.frame_is_user(frame)
}

Process :: struct {
	name:   string,
	space:  ^mem.Address_Space,
	thread: ^sched.Thread,

	/*
	Who this process is, and who started it.

	`pid` is monotonic and never reused, for the same reason `kernel/srv`
	keeps an id rather than a slot. The table reuses slots, and a parent must
	not collect a stranger that moved in. `parent` is zero for a process the
	kernel built, which is what makes `wait` refuse to collect it from ring 3.
	*/
	pid:    u64,
	parent: u64,
	/*
	Whose process this is. Set when the process is made, from its parent
	or, for one the kernel starts, from the host owner. Only a write of
	`user` to its own `/proc/n/ctl` changes it after that, and only a
	process of the host owner's may make that write, which is how a server
	that proved a client becomes that client. `docs/FLEET.md` section 4.
	*/
	user:   [USER_MAX]u8,
	ulen:   int,

	/*
	Whether this process is the kernel's to reap rather than a parent's to
	wait for. True for a child forked `RFNOWAIT`, and for one reparented
	when its own parent went. A detached process answers no `wait` -- its
	parent is zero -- and `reap_orphans` collects it once it ends. False for
	a kernel-launched test process, which the self-test destroys by name and
	the reaper must leave alone.
	*/
	detached: bool,

	// Which note group this process is in. Inherited on fork and spawn,
	// fresh under `RFNOTEG`. Nothing posts to a group yet. The field
	// arrives with `rfork` because the flag does. The fan-out of a note
	// to a whole group is the half of Plan 9's notify still missing --
	// the handler half exists now. See `docs/USER.md`.
	note_group: u64,
	// The rendezvous group, `note_group`'s twin: inherited, and a group of
	// one under `RFREND`. A tag is private to it.
	rend_group: u64,
	// When `alarm` posts its note, as a tick, and zero for no alarm.
	alarm_at:   u64,

	// Where a spawned process's name lives. `load` is handed string literals
	// that live in the image. `spawn_path` is handed a path sitting on the
	// calling thread's syscall stack, which is gone when the call returns.
	name_buf: [PATH_MAX]u8,

	// The current directory, as a cleaned absolute path, and `/` when empty.
	// Inherited by a fork and a spawn, changed by `chdir`. See `path.odin`.
	cwd_buf: [PATH_MAX]u8,
	cwd_len: int,

	// The frames behind the three blob mappings, as *aliases*. Physical,
	// because `mem.phys_to_virt` needs them to read the data page back for
	// staging and marks. The segments below own the frames and free them;
	// these fields name three of the same frames and free nothing.
	text:   uintptr,
	data:   uintptr,
	stack:  uintptr,

	/*
	The segments behind every mapping, and the owners of every frame.

	A blob is three one-page segments. A compiled program is one per image
	row and a stack. `unload` releases each, and the last holder's release
	frees the frames. That rule is what lets `rfork` map one segment into
	two spaces without a second owner. See `segment.odin`.
	*/
	segs:      [MAX_PROC_SEGS]^Segment,
	seg_count: int,

	// The bounds of the thread's kernel stack, copied at load time. Copied
	// rather than read back through `thread`, because the next `spawn` frees a
	// dead thread's record and the answer is wanted after that.
	kstack_lo: uintptr,
	kstack_hi: uintptr,

	/*
	This process's own view of the tree.

	A copy rather than a reference, so `SYS_BIND` rearranges one process's
	namespace and no other. `ns_fork` shares the member chans underneath and
	counts references, which is what makes the copy cheap.
	*/
	ns:     ^vfs.Namespace,

	/*
	The open files, as a reference to a group.

	A reference rather than a field, because Plan 9's fork *shares* the
	descriptor group by default and `RFFDG` asks for a copy. The table, its
	lock, and the take/advance discipline live in `fdtable.odin`. The exit
	paths detach and release this in thread context. `unload` releases
	whatever is still attached.
	*/
	fdt:    ^Fd_Table,

	// The environment group: the directory this process sees at `/env`.
	// Copied by a spawn, shared by a fork unless `RFENVG` copies or
	// `RFCENVG` empties it, kept across `exec`. `unload` releases it.
	env:    ^env.Group,

	exit:   Exit,
	live:   bool,

	// Claimed by whichever collector reaches a dead process first. The
	// reaper, a fork that wants a slot, and a self-test that destroys by name
	// can all arrive at one record. `unload` run twice releases twice.
	// `destroy` takes this with a compare-and-swap, and `unload`'s final
	// zeroing of the record clears it with `live`.
	collecting: bool,

	// The note's text, posted before delivery and kept for whoever collects
	// the exit -- or reads it in a handler. A process with no handler still
	// only ever hears a note as an ending.
	note_buf: [NOTE_MAX]u8,
	note_len: int,
	// A note posted while the process was live and had no thread yet: one a
	// group got while this child was being forked. `note_born` delivers it
	// once the thread exists. See `post_note`.
	note_early: bool,

	/*
	The ring 3 note handler, and the state one delivery is in.

	`handler` is a user address `sys_notify` registered, zero for none.
	`notified` means a handler frame is on the user stack right now: no
	second delivery may start, and `sys_noted` is the only way forward.
	`note_sp` is where that frame sits, for `noted` to read back. Only the
	process's own thread touches all three -- at the door, at the tick that
	catches it, or in `sys_notify` -- so they need no lock. See
	`notify.odin`.
	*/
	handler:  uintptr,
	notified: bool,

	/*
	Whether the kernel decided this process ends at its next boundary,
	whatever handler it registered. Plan 9's `procctl` set to `Proc_exitme`,
	which `killproc` sets and `procctl()` answers with `pexit("Killed")`
	before any note is looked at. `end` sets it. The door and the tick read
	it before they read the note, which is what makes it unconditional.
	*/
	stopping: bool,
	note_sp:  uintptr,

	/*
	A stop, from `/proc/n/ctl`. `stop_requested` is the ask; the thread
	parks at its next boundary -- the door, or the tick that catches it in
	ring 3 -- and `stopped` says it has. `start` clears the ask and wakes
	it. The wake for the ask is `sched.note_thread`, the same as a note's,
	so `stop_wake` remembers that the flag was raised for a stop and nothing
	else -- a note posted after clears it -- and the boundary takes the flag
	down again rather than treat it as a note. See `stop_here` and
	`note_trap`.
	*/
	stop_requested:  bool,
	stopped:         bool,
	stopped_in_tick: bool, // parked by the tick, so `start` readies the thread itself
	stop_wake:       bool, // the note flag is up for a stop and nothing else; a post clears it

	/*
	The debugger's asks, `docs/DEVTOOLS.md` section 5, and what a stop keeps
	for it. Each ask is one stop: the boundary that honours it takes it down.
	`stop_frame` is the program's own frame while it is stopped, at the door
	or in the tick, which is what `/proc/n/regs` reads and writes. `stops`
	counts them, so a `startstop` can tell the stop it asked for from the one
	it started from. `pins` are readers of this process's memory through
	`/proc`, and a collector waits for them. See `debug.odin`.
	*/
	trace_note:    bool, // `startstop`: stop before the next note is delivered
	trace_syscall: bool, // `startsyscall`: stop at the next system call's entry
	// The system call this process is inside, plus one, or zero outside
	// one, and its first argument. Plan 9's `psstate`: what a blocked
	// process waits in, which a hung check names.
	in_call:       u64,
	call_arg:      u64,

	// A rendezvous this process sleeps in. The tag, the value it left or was
	// given, whether a partner came, its chain, and its wake, all under
	// `rend_lock`. See `rendezvous`.
	rend_tag:      u64,
	rend_value:    u64,
	rend_matched:  bool,
	rend_waiting:  bool,
	rend_next:     ^Process,
	rend_wake:     sync.Rendez,
	trace_return:  bool, // and once more before that call returns
	hang:          bool, // `hang`: stop at the next exec, before its first instruction
	stepping:      bool, // `step`: the frame carries the step flag, and its trap is a stop
	step_at_door:  bool, // the step left a syscall door, whose return traps once before the first instruction
	step_from:     uintptr, // the counter the step left
	stops:         u64,
	stop_frame:    ^arch.Trap_Frame,
	stop_fpu:      rawptr,
	pins:          int,

	// The arguments the program was started with, joined by spaces and cut
	// at ARGS_KEEP, for `/proc/n/args`. The kernel stages the real ones onto
	// the stack and keeps nothing else.
	args_buf: [ARGS_KEEP]u8,
	args_len: int,
}

// The longest note. Plan 9 says ERRMAX for the same field, and the number
// only has to hold a sentence.
NOTE_MAX :: 64

/*
One open file.

The chan is the namespace's answer to a path. The offset is the process's. It
is here rather than on the chan because two descriptors may name one file and
read it at different places. 9P has no cursor on the wire, because every
`Tread` carries an offset. Somebody above the protocol has to keep one, and
this is that somebody.
*/
Fd :: struct {
	chan:   ^vfs.Chan,
	offset: u64,
}

// Sixty-four, up from thirty-two, because a toolkit window holds five: its
// data, cons, consctl, mouse and store, `docs/CHROME.md` brick 3. A desktop
// with a bar, a backdrop and a few drawers open passed thirty-two. It was
// sixteen before that, until a shell's pipelines outgrew it.
MAX_FDS :: abi.MAX_FDS

/*
The programs, from a fixed table.

The same argument `mem.spaces` makes. A record a program can make the kernel
allocate is a record a program can exhaust the machine through. This is also
the first code in Vectra that anything untrusted will reach.
*/
MAX_PROCESSES :: 256

EXITS_MAX :: abi.EXITS_MAX

// How much of a program's arguments the record keeps for `/proc/n/args`.
ARGS_KEEP :: 256

@(private)
processes: [MAX_PROCESSES]Process

/*
The lock over the table: who holds a slot, and which tenant it holds.

A claim finds a slot that is not live and makes it live, and a release zeroes
it. Two cores that do the first at once would both find the same slot, and one
core zeroing while another claims would wipe a newborn. Both are one
instruction wide and both are real on a second core. So the claim, the release,
the pid counter and every scan of the table are under this lock.

What is not under it is anything that can park: closing a descriptor group, a
namespace, a space. Those run on a record that is already claimed for
collection, with `collecting` set under the lock. Nothing else will touch it,
and the lock is let go of before they begin. The pid is still the identity
across that gap, which is what `collect` re-checks on the far side.
*/
@(private)
table_lock: sync.Spinlock

@(private)
loaded: int
@(private = "file")
faults: int

// The next process id, never reused. Zero is the kernel, so the first process
// is 1. Monotonic and therefore finite, like a fid -- the same one fix
// retires all three counters. See `docs/HANDOFF.md`.
@(private)
next_pid: u64 = 1

// How many processes another process started, rather than the kernel. For
// the boot line, which should say the new thing plainly.
@(private)
spawned: int

Stats :: struct {
	live:    int, // Programs loaded and not destroyed
	loaded:  int, // Programs loaded since boot
	spawned: int, // Of those, started by another process rather than the kernel
	faults:  int, // Faults taken in ring 3
	calls:   int, // System calls answered
	traps:   u64, // Every return from ring 3 through a trap, preemptions included
}

stats :: proc "contextless" () -> Stats {
	live := 0
	guard := sync.acquire(&table_lock)
	for i in 0 ..< MAX_PROCESSES {
		if processes[i].live {
			live += 1
		}
	}
	sync.release(&table_lock, guard)
	return Stats {
		live = live,
		loaded = loaded,
		spawned = spawned,
		faults = faults,
		calls = syscall_count(),
		traps = arch.user_trap_count(),
	}
}

/*
init claims the fault path for programs.

Two lines, and the first separates `a fault ends the machine` from `a fault
ends the program`. Until it runs, a trap from ring 3 falls through to
`kernel/panic.odin` and stops the boot. That is the right default for a
privilege level nothing owns yet.

The second arms `syscall` and opens the console behind descriptor 1. It reports
false when the CPU has no such instruction, which no amd64 part does, and the
caller says so rather than halts. Programs then have exactly one way out of
ring 3 again, which is the fault. See `syscall.odin`.
*/
init :: proc(ns: ^vfs.Namespace) -> bool {
	arch.set_user_trap_handler(on_trap)
	sched.set_note_trap(note_trap)
	// The reaper asks this before it frees a thread's record, so a process
	// keeps a valid Dead thread until it is collected. See `on_thread_reaped`.
	sched.set_reap_decide(on_thread_reaped)
	// The collector before the door opens, so no process can end without one
	// running. See `hangup_dead`.
	if !reaper_start() {
		return false
	}
	// The alarm clock, and the console's two questions: whose group a read
	// of it belongs to, and where a typed interrupt goes.
	if sched.spawn("alarms", alarm_loop) == nil {
		return false
	}
	devfs.set_console_owner(console_owner)
	devfs.set_interrupt_sink(interrupt_group)
	return syscall_init(ns)
}

/*
The alarm clock: one kernel thread that wakes for the soonest alarm any
process set, posts `alarm` to every process whose time has come, and goes
back to sleep until the next. `sys_alarm` sets a process's time and pokes
it. Plan 9 keeps an alarm list the clock interrupt walks; this walks the
table from a thread, which a table of a few hundred does not notice.
*/
@(private = "file")
alarm_rendez: sync.Rendez

@(private = "file")
alarm_armed: bool

@(private = "file")
alarm_set :: proc "contextless" (arg: rawptr) -> bool {
	_ = arg
	return intrinsics.volatile_load(&alarm_armed)
}

@(private = "file")
alarm_loop :: proc "contextless" (arg: rawptr) {
	_ = arg
	for {
		intrinsics.volatile_store(&alarm_armed, false)
		now := sched.ticks()
		soonest := u64(0)
		guard := sync.acquire(&table_lock)
		for i in 0 ..< MAX_PROCESSES {
			p := &processes[i]
			if !p.live || p.alarm_at == 0 {
				continue
			}
			if p.alarm_at <= now {
				p.alarm_at = 0
				_ = post_note(p, "alarm")
			} else if soonest == 0 || p.alarm_at < soonest {
				soonest = p.alarm_at
			}
		}
		sync.release(&table_lock, guard)
		if soonest == 0 {
			sync.sleep(&alarm_rendez, alarm_set)
		} else {
			_ = sync.sleep_for(&alarm_rendez, alarm_set, nil, soonest - now)
		}
	}
}

// alarm_poke tells the clock a process set an alarm sooner than it knew.
@(private)
alarm_poke :: proc "contextless" () {
	intrinsics.volatile_store(&alarm_armed, true)
	_ = sync.wakeup(&alarm_rendez)
}

// The note group of the process that last read the console, set by
// `sys_read`, and asked by `kernel/devfs` so a typed interrupt knows where
// to go. The device's own handler runs on a worker thread and cannot ask.
@(private)
console_group: u64

@(private = "file")
console_owner :: proc "contextless" () -> u64 {
	return intrinsics.volatile_load(&console_group)
}

interrupts_typed: int

// interrupt_group is where a typed `^C` goes: `interrupt` to every process
// in the group, from the console's own thread.
@(private = "file")
interrupt_group :: proc "contextless" (group: u64) {
	if group == 0 {
		return
	}
	interrupts_typed += 1
	_ = notepg_kernel(group, "interrupt")
}

// notepg_kernel posts a note to every live process in a group, and answers
// how many took it. The kernel's own `notepg`, with no poster to exclude.
// `sys_notepg` names its caller as `except`, so a process that notes its
// own group does not end itself.
notepg_kernel :: proc "contextless" (group: u64, text: string, except: ^Process = nil) -> int #no_bounds_check {
	noted := 0
	guard := sync.acquire(&table_lock)
	for i in 0 ..< MAX_PROCESSES {
		q := &processes[i]
		if q == except || !q.live || q.note_group != group {
			continue
		}
		if post_note(q, text) {
			noted += 1
		}
	}
	sync.release(&table_lock, guard)
	return noted
}

/*
Rendezvous: Plan 9's `rendezvous(2)`. The first caller with a tag leaves its
value and sleeps. The second finds it, swaps its value for the sleeper's,
marks it matched and wakes the sleeper. Each returns with the other's value.
A tag is private to the callers' rendezvous group. A sleeper that is noted
goes back unmatched.

**The sleepers are the table.** A process waits on one tag at a time. So its
own record carries the tag, the value and the wake. A waiter is found through
a hash of chains threaded through the records, as Plan 9's `rendhash` is.
There is no table of entries to fill. It was 64 entries once, and every
sleeping `libthread` proc holds one. A full table answered as a note does,
and `proc_meet` asked again at once and spun. See `docs/LIMITS.md`.
*/
@(private = "file")
REND_HASH :: 64

@(private = "file")
rend_hash: [REND_HASH]^Process

@(private = "file")
rend_lock: sync.Spinlock

@(private = "file")
rend_bucket :: proc "contextless" (group: u64, tag: u64) -> int {
	return int((tag ~ (tag >> 17) ~ group * 0x9E3779B97F4A7C15) % REND_HASH)
}

@(private = "file")
rend_matched :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&(^Process)(arg).rend_matched)
}

// rend_unlink takes a sleeper off its chain. The lock is the caller's.
@(private = "file")
rend_unlink :: proc "contextless" (q: ^Process) #no_bounds_check {
	at := &rend_hash[rend_bucket(q.rend_group, q.rend_tag)]
	for at^ != nil {
		if at^ == q {
			at^ = q.rend_next
			q.rend_next = nil
			q.rend_waiting = false
			return
		}
		at = &at^.rend_next
	}
}

// rend_forget takes a record off its chain before the record is released.
// A sleeper unlinks itself when it wakes, so this finds one only when a
// record goes with its thread never having woken.
@(private)
rend_forget :: proc "contextless" (p: ^Process) {
	guard := sync.acquire(&rend_lock)
	if p.rend_waiting {
		rend_unlink(p)
	}
	sync.release(&rend_lock, guard)
}

// rendezvous is the call: the partner's value, or `ok` false when a note
// interrupted the wait.
@(private)
rendezvous :: proc "contextless" (p: ^Process, tag: u64, value: u64) -> (partner: u64, ok: bool) #no_bounds_check {
	guard := sync.acquire(&rend_lock)
	b := rend_bucket(p.rend_group, tag)
	for q := rend_hash[b]; q != nil; q = q.rend_next {
		if q.rend_group == p.rend_group && q.rend_tag == tag {
			rend_unlink(q)
			partner = q.rend_value
			q.rend_value = value
			intrinsics.volatile_store(&q.rend_matched, true)
			sync.release(&rend_lock, guard)
			_ = sync.wakeup(&q.rend_wake)
			return partner, true
		}
	}
	p.rend_tag = tag
	p.rend_value = value
	p.rend_matched = false
	p.rend_waiting = true
	p.rend_next = rend_hash[b]
	rend_hash[b] = p
	sync.release(&rend_lock, guard)

	woke := sync.sleep_noted(&p.rend_wake, rend_matched, p)
	guard = sync.acquire(&rend_lock)
	met := intrinsics.volatile_load(&p.rend_matched)
	if p.rend_waiting {
		// Noted before a partner came: off the chain, with nothing exchanged.
		rend_unlink(p)
	}
	partner = p.rend_value
	p.rend_matched = false
	sync.release(&rend_lock, guard)
	return partner, woke || met
}

/*
Semaphores over a word in the caller's memory, 9front's `semacquire` and
`semrelease`. The word is the count, and the kernel touches it through the
direct map with the same atomic operations ring 3 would use, so a
`semrelease` that finds no waiter is one instruction. One rendezvous serves
every semaphore: a release wakes all waiters and each re-checks its own
word, which is right for a handful of waiters and wrong for thousands.
*/
@(private = "file")
sema_rendez: sync.Rendez

@(private = "file")
sema_positive :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.atomic_load((^i64)(arg)) > 0
}

// sema_word finds the kernel's view of a process's semaphore word, or nil
// when the address is not the process's to name.
@(private)
sema_word :: proc "contextless" (p: ^Process, addr: uintptr) -> ^i64 {
	if p == nil || p.space == nil || addr % 8 != 0 {
		return nil
	}
	cow_prepare(p, addr, 8)
	if !reachable(addr, 8, {.User, .Write}) {
		return nil
	}
	phys, ok := mem.translate(p.space, addr)
	if !ok {
		return nil
	}
	return (^i64)(mem.phys_to_virt(phys))
}

@(private)
semacquire :: proc "contextless" (p: ^Process, addr: uintptr, block: bool) -> i64 {
	word := sema_word(p, addr)
	if word == nil {
		return -i64(vectra9.EFAULT)
	}
	for {
		v := intrinsics.atomic_load(word)
		if v > 0 {
			if _, swapped := intrinsics.atomic_compare_exchange_strong(word, v, v - 1); swapped {
				return 1
			}
			continue
		}
		if !block {
			return 0
		}
		if !sync.sleep_noted(&sema_rendez, sema_positive, word) {
			return -i64(vectra9.EINTR)
		}
	}
}

@(private)
semrelease :: proc "contextless" (p: ^Process, addr: uintptr, count: i64) -> i64 {
	word := sema_word(p, addr)
	if word == nil {
		return -i64(vectra9.EFAULT)
	}
	if count <= 0 {
		return -i64(vectra9.EINVAL)
	}
	intrinsics.atomic_add(word, count)
	_ = sync.wakeup_all(&sema_rendez)
	return 0
}

/*
on_trap ends the program the fault came from, and says why.

Runs in interrupt context, on the faulting thread's kernel stack, with
interrupts already off. It therefore allocates nothing, takes no lock and logs
nothing. The report is written into the program's own record and read by
whoever was waiting, in thread context, where a console is safe to touch.

Finding the program is one load: the scheduler carries the record on the thread
and never looks at it. A table searched by thread pointer would be the same
answer with a loop in a fault handler.

The return value is another thread's state, which is what ends this one. A
handler that returned what it was given would `iretq` back to the faulting
instruction. It would then take the same fault for ever, which is a hang rather
than a failed check.
*/
@(private = "file")
on_trap :: proc "contextless" (t: ^arch.Trap, r: arch.Resume) -> arch.Resume {
	// Atomic, as every count this handler keeps is: two cores fault at
	// once, and a plain add loses one of them.
	intrinsics.atomic_add(&faults, 1)

	thread := sched.current()
	p := thread != nil ? (^Process)(thread.user) : nil
	if p != nil {
		// A page fault a program survives: a write to a page it holds
		// under copy-on-write, or a page of its own that is not mapped
		// yet. Fixed here, and the same instruction runs again.
		if t.kind == .Page_Fault && t.user && p.space != nil {
			bits := arch.fault_bits(t.kind, t.vector, t.error_code, t.user)
			if fix_fault(p, t.fault_address, .Write in bits) {
				return r
			}
		}
		// A debugger's trap is a stop rather than an ending: the step
		// it asked for, or any trap while `startstop` is in force, which
		// posts the note Plan 9 would and parks before delivering it.
		// A process nobody is watching ends here as it always did.
		if t.user && !intrinsics.volatile_load(&p.stopping) {
			if p.stepping && t.kind == .Debug {
				// A step out of a syscall door returns by `sysretq`,
				// and a step flag loaded that way traps before the
				// first instruction runs, at the very counter the
				// step left. That trap is not the step: the flag
				// stays up and the program goes on to its next one.
				if p.step_at_door && t.ip == p.step_from {
					p.step_at_door = false
					return r
				}
				p.stepping = false
				p.step_at_door = false
				arch.frame_set_step(r.frame, false)
				return stop_in_trap(p, r)
			}
			if p.trace_note {
				p.trace_note = false
				post_trap_note(p, thread, t)
				return stop_in_trap(p, r)
			}
		}
		p.exit.kind = t.kind
		p.exit.vector = t.vector
		p.exit.error_code = t.error_code
		p.exit.has_error = t.has_error
		p.exit.ip = t.ip
		p.exit.address = t.fault_address
		// Whether the page was there, asked of the tables the program
		// faulted through, now, while they are the ones loaded. A
		// syndrome may not say; the VMM always can.
		if t.kind == .Page_Fault && p.space != nil {
			_, p.exit.present = mem.permissions(p.space, t.fault_address)
		}
		p.exit.from_user = t.user
		p.exit.sp = t.sp
		p.exit.kstack = uintptr(rawptr(t.frame))
		// Last, and volatile: it is what the observer polls, and everything
		// above it has to be visible to a reader that sees it set.
		intrinsics.volatile_store(&p.exit.done, true)
	}

	// Interrupts are already off, and `wakeup_all` masks rather than enables,
	// so a woken waiter cannot run before this thread leaves the core.
	sync.wakeup_all(&exit_rendez)
	return sched.kill_current(r)
}

// What the fault handler did, for the boot line: forks that shared rather
// than copied, and pages copied on a write.
cow_forks: int
cow_copies: int
page_refills: int
stack_pages_grown: int

/*
fix_fault is Plan 9's `fixfault` in miniature: the one kind of page fault a
program survives, handled on the faulting thread's own stack in interrupt
context, with spinlocks only.

The page must be one of the process's segments, and must have a frame. A
page that is mapped read-only where the segment says writable is a
copy-on-write page: if the frame has another holder, a fresh frame takes a
copy of it and the seat in the segment, and the old one loses a holder; if
this process is the only holder left, the write bit simply comes back. A
page the tables do not have at all is mapped to the frame the segment
names. Anything else is a fault that ends the program, and the caller does
that.

Nothing here reaches another process. A copy-on-write frame is held by
segments with one holder each -- `fork_segments` copies eagerly otherwise
and `resolve_cow` runs before a share -- so the only mapping that changes is
this process's, and it only widens, which no other core need be told.
*/
@(private)
fix_fault :: proc "contextless" (p: ^Process, addr: uintptr, write: bool) -> bool {
	s := segment_covering(p, addr)
	if s == nil || s.kind == .Device {
		return false
	}
	page := uintptr(arch.PAGE_SIZE)
	va := addr & ~(page - 1)
	j := int((va - s.va) / page)
	cur := segment_frame(s, j)
	if cur == 0 {
		// A hole: a stack page nothing has reached before. It gets a frame
		// of zeros now, which is the stack growing.
		if s.kind != .Stack || s.run {
			return false
		}
		frame, ok := mem.alloc_page_zeroed()
		if !ok {
			return false
		}
		if mem.map_user(p.space, va, frame, s.flags, 1) != .None {
			mem.free_page(frame)
			return false
		}
		segment_set_frame(s, j, frame)
		intrinsics.atomic_add(&stack_pages_grown, 1)
		return true
	}
	flags, present := mem.permissions(p.space, va)
	if !present {
		mapped := s.flags
		if mem.frame_holders(cur) > 1 {
			mapped -= {.Write}
		}
		// Counted after the map, so a watcher that sees the count sees the
		// page. `verify_smp` waits on exactly this.
		ok := mem.map_user(p.space, va, cur, mapped, 1) == .None
		intrinsics.atomic_add(&page_refills, 1)
		return ok
	}
	if !write || .Write not_in s.flags || .Write in flags {
		return false
	}
	if mem.frame_holders(cur) > 1 {
		return cow_copy(p, s, j, va)
	}
	return mem.protect_user(p.space, va, 1, s.flags) == .None
}

/*
cow_copy gives page `j` of segment `s` a frame of this process's own: a
copy of the shared one, put in its seat and mapped writable, the shared one
losing a holder. A run becomes a list first. The staging aliases follow the
frame, so a self-test reading a child's cell reads the child's copy.
*/
@(private)
cow_copy :: proc "contextless" (p: ^Process, s: ^Segment, j: int, va: uintptr) -> bool {
	cur := segment_frame(s, j)
	if cur == 0 {
		return false
	}
	if s.run && !segment_make_list(s) {
		return false
	}
	fresh, ok := mem.alloc_page()
	if !ok {
		return false
	}
	src := (cast([^]u8)mem.phys_to_virt(cur))[:arch.PAGE_SIZE]
	dst := (cast([^]u8)mem.phys_to_virt(fresh))[:arch.PAGE_SIZE]
	copy(dst, src)
	if mem.remap_user(p.space, va, fresh, s.flags) != .None {
		mem.free_page(fresh)
		return false
	}
	segment_set_frame(s, j, fresh)
	if p.data == cur {
		p.data = fresh
	}
	if p.stack == cur {
		p.stack = fresh
	}
	mem.free_page(cur)
	intrinsics.atomic_add(&cow_copies, 1)
	return true
}

// cow_prepare resolves every copy-on-write page in a range the kernel is
// about to write on a process's behalf, as the process's own store would.
@(private)
cow_prepare :: proc "contextless" (p: ^Process, addr: uintptr, n: int) {
	if p == nil || p.space == nil || n <= 0 || addr >= mem.USER_MAX {
		return
	}
	page := uintptr(arch.PAGE_SIZE)
	first := addr & ~(page - 1)
	last := (addr + uintptr(n) - 1) & ~(page - 1)
	for va := first; va <= last && va < mem.USER_MAX; va += page {
		flags, present := mem.permissions(p.space, va)
		if present && .Write not_in flags {
			_ = fix_fault(p, va, true)
		}
	}
}

// own_data makes the data page the staging aliases name the process's own
// before the kernel writes it through the alias.
@(private)
own_data :: proc "contextless" (p: ^Process) {
	if p == nil || p.data == 0 || mem.frame_holders(p.data) <= 1 {
		return
	}
	for i in 0 ..< p.seg_count {
		s := p.segs[i]
		if s == nil || s.run {
			continue
		}
		for j in 0 ..< s.pages {
			if segment_frame(s, j) == p.data {
				_ = cow_copy(p, s, j, s.va + uintptr(j) * uintptr(arch.PAGE_SIZE))
				return
			}
		}
	}
}

/*
Where everything that ends a process reports it, and where collectors wait.

One rendezvous rather than one per process, because an exit is rare and a
scan per wake is nothing. The condition is the child's own `exit.done`, so a
wake for somebody else's child is a loop iteration rather than a wrong
answer. This is what let `wait` stop polling: a parked parent costs the
machine nothing until an ending wakes it.
*/
@(private)
exit_rendez: sync.Rendez

// Where a stopped process's thread waits for `start`.
stop_rendez: sync.Rendez

@(private)
exit_done :: proc "contextless" (arg: rawptr) -> bool {
	return intrinsics.volatile_load(&(^Process)(arg).exit.done)
}

/*
on_thread_reaped is what the reaper asks before it frees a thread's record.

A note sender keeps reading `p.thread`, so a user thread's record has to stand
until its process is collected. This marks the thread reaped and returns
whether reap may free the record now. It may only when collect has already run
and cleared `p.thread`, and otherwise collect frees it once it sees the thread
reaped. Whoever runs second frees the record under `table_lock`, so a sender
holding the lock reads a live Dead record or nil, never freed memory. A worker
with no process is reap's, as before. See `unload` and `sched.free_reaped`.
*/
@(private)
on_thread_reaped :: proc "contextless" (t: ^sched.Thread) -> bool {
	guard := sync.acquire(&table_lock)
	defer sync.release(&table_lock, guard)
	t.reaped = true
	p := (^Process)(t.user)
	return p == nil || p.thread != t
}

/*
post_note delivers an ending to a process, from outside it.

The note is a flag on the thread and a line of text on the process. What
makes it an *ending* is the boundaries: the next system call the thread
enters, or the next tick that catches it in ring 3. `sched.note_thread`
readies a parked thread, so an interruptible sleep unwinds toward one of
those. Delivery is not instant, and this does not wait for it. A caller that
wants the corpse waits on the exit and then destroys. That is `wait_pid`'s
arc for parents, and the kernel's for itself.

Refused on a process that already ended. The note would outlive its target
and kill whatever reuses the thread, which is the aliasing every id in this
tree exists to prevent.

Called with `table_lock` held. The guard and the wake both read `p.thread`,
and only the lock keeps the collector from taking it off and freeing the
record in between. The callers that hold it are `proc_note`, `end`, and the
group senders `notepg_kernel` and `sys_note`. See `on_thread_reaped`.
*/
post_note :: proc "contextless" (p: ^Process, text: string) -> bool {
	if p == nil || !p.live {
		return false
	}
	if intrinsics.volatile_load(&p.exit.done) {
		return false
	}
	/*
	A process live with no thread yet is one being born: a fork past its
	claim and before its thread, or a spawn the same. A `notepg` to its group
	in that window used to pass it by, and the parent took the note and ended
	while the child lived on, waiting for a parent that was gone. A libthread
	program killed as it made an io proc left that proc standing, `docs/CHROME.md`
	brick 3. So the note waits in the record, and `note_born` delivers it.
	*/
	if p.thread == nil {
		set_note_text(p, text)
		p.note_early = true
		return true
	}

	set_note_text(p, text)
	p.stop_wake = false
	sched.note_thread(p.thread)
	return true
}

/*
note_born delivers a note that reached a process before its thread did, once
the thread exists. Every place that gives a process its thread calls it. Under
`table_lock`, so a `notepg` either sees the thread and notes it or ran before
and left the note here: never neither.
*/
note_born :: proc "contextless" (p: ^Process) {
	guard := sync.acquire(&table_lock)
	if p.note_early && p.thread != nil {
		p.note_early = false
		p.stop_wake = false
		sched.note_thread(p.thread)
	}
	sync.release(&table_lock, guard)
}

// set_note_text is the note's words into the record, cut to what it holds.
@(private = "file")
set_note_text :: proc "contextless" (p: ^Process, text: string) {
	p.note_len = copy(p.note_buf[:], text)
}

/*
request_end is `end` without the wait: the kernel's word set, the note
that names it, and the wake. `end` waits after it; `/proc/n/ctl` does not.

Called with `table_lock` held, for the reason `post_note` gives. The wake
reads `p.thread`, and the lock keeps the collector from freeing the record
meanwhile.
*/
request_end :: proc "contextless" (p: ^Process) -> bool {
	if p == nil || !p.live || p.thread == nil || intrinsics.volatile_load(&p.exit.done) {
		return false
	}
	set_note_text(p, "sys: killed")
	p.stop_wake = false
	intrinsics.volatile_store(&p.stopping, true)
	sched.note_thread(p.thread)
	return true
}

/*
stop_here parks the calling thread until `start`, at the door.

Thread context, so the park is an ordinary rendezvous sleep. It ends when
the ask is withdrawn, or when the process is being killed, which the door
handles next. A note posted while stopped waits until the start. The door
then takes down the note flag the stop's own wake raised, if nothing was
posted since, so it does not deliver a note that was never there.
*/
stop_here :: proc(p: ^Process) {
	p.stopped = true
	// Counted after `stopped` is up, so a waiter that sees the count sees
	// the stop. See `wait_stop` in `debug.odin`.
	intrinsics.atomic_add(&p.stops, 1)
	for intrinsics.volatile_load(&p.stop_requested) && !intrinsics.volatile_load(&p.stopping) {
		sync.sleep_noted(&stop_rendez, stop_lifted, p)
	}
	p.stopped = false
	p.stop_frame = nil
	p.stop_fpu = nil
	// The door clears the stop's own wake flag next, once the ask is gone.
}

// stop_at_door is `stop_here` with the program's frame kept for `/proc/n/regs`:
// the syscall frame, and the float image the door parked below it.
@(private)
stop_at_door :: proc(p: ^Process, frame: ^arch.Trap_Frame) {
	p.stop_frame = frame
	p.stop_fpu = arch.syscall_frame_fpu(frame)
	intrinsics.volatile_store(&p.stop_requested, true)
	stop_here(p)
}

/*
stop_in_trap is the stop from interrupt context: the tick that caught a
stop's ask in ring 3, or a trap the debugger asked to see. The frame is the
program's own, so `regs` reads it where it lies. `start` readies the thread
by hand, which `stopped_in_tick` tells it. The ask is raised here too, so
one `start` lifts every kind of stop the same way.
*/
@(private)
stop_in_trap :: proc "contextless" (p: ^Process, r: arch.Resume) -> arch.Resume {
	p.stop_frame = r.frame
	p.stop_fpu = r.fpu
	intrinsics.volatile_store(&p.stop_requested, true)
	p.stopped = true
	p.stopped_in_tick = true
	intrinsics.atomic_add(&p.stops, 1)
	return sched.park_current(r)
}

@(private = "file")
stop_lifted :: proc "contextless" (arg: rawptr) -> bool {
	p := (^Process)(arg)
	return !intrinsics.volatile_load(&p.stop_requested) || intrinsics.volatile_load(&p.stopping)
}

/*
end stops a process from outside, and waits for it to be gone.

**This is the kill the kernel did not have.** A note is a request a handler
may decline, and `destroy` refuses a process whose thread still translates
through the space. So a process that caught every note and never exited was
the kernel's to keep for ever. `docs/HANDOFF.md` carried it as the honest
leak for four milestones.

Plan 9's `killproc` is the shape. It sets `procctl` to `Proc_exitme` and
pushes a "sys: killed" note beside it. The note is what wakes a parked
process and what the exit record carries. The word is what makes the ending
unconditional. `procctl()` runs before `notify` looks at any note or any
handler, and answers `pexit("Killed")`.

Here `stopping` is the word and `sched.note_thread` is the wake. The door
and the tick both read the word before the handler. So a process ends at its
next boundary whether or not it registered one, and whether or not a
delivery is in flight.

The wait is bounded, the way every wait in this tree is. A process that
reaches no boundary inside `patience` ticks is still running when this
returns false, and is still the caller's to leave alone. Nothing here can
end a thread that never crosses back into the kernel, and a tick is a
boundary, so nothing runs that long.

True means the process ended, noted, and its record is still there for the
caller to read. `stop` is this and the collection.
*/
end :: proc(p: ^Process, patience: int) -> bool {
	if p == nil || !p.live || p.thread == nil {
		return false
	}
	if intrinsics.volatile_load(&p.exit.done) {
		return true
	}
	// The note under the lock that pins `p.thread`. The wait comes after it,
	// with the lock let go, because `wait` sleeps and a `Spinlock` cannot be
	// held across a sleep. See `request_end` and `on_thread_reaped`.
	{
		guard := sync.acquire(&table_lock)
		request_end(p)
		sync.release(&table_lock, guard)
	}
	return wait(p, patience)
}

// stop is `end` and the collection, which is the whole arc `wait_pid` walks
// for a parent, walked by the kernel for itself.
stop :: proc(p: ^Process, patience: int) -> bool {
	if !end(p, patience) {
		return false
	}
	return destroy(p)
}

// note reports the text an ending carried, empty when nothing was posted.
note :: proc "contextless" (p: ^Process) -> string {
	if p == nil {
		return ""
	}
	return string(p.note_buf[:p.note_len])
}

/*
note_trap is the tick's half of delivery: a noted thread caught in ring 3.

Interrupt context, exactly like `on_trap`, and the same rules -- no lock, no
log, no allocation. `deliver_note` keeps them. It walks page tables and
writes user memory through mappings that are live right now, because the
tick caught this very thread running.

Three ways out. A handler mid-delivery holds the note and resumes, and the
next boundary after `noted` finishes takes it. A registered handler gets
the frame the tick interrupted, redirected. And a process with no handler,
or no stack a frame fits on, ends here. The record says a note did it, and
the descriptors stay open until `destroy` closes them, which is the fault
path's arrangement too.
*/
@(private = "file")
note_trap :: proc "contextless" (r: arch.Resume) -> arch.Resume {
	thread := sched.current()
	p := thread != nil ? (^Process)(thread.user) : nil
	// A stop parks the thread here, off every queue, its frame in the
	// record, until `start` readies it. Resumed, the flag that woke it
	// is still up: if it was the stop's own and nothing was posted, it
	// comes off and the thread simply carries on in ring 3.
	if p != nil && !intrinsics.volatile_load(&p.stopping) {
		if intrinsics.volatile_load(&p.stop_requested) {
			return stop_in_trap(p, r)
		}
		if p.stop_wake {
			p.stop_wake = false
			sched.clear_note(thread)
			return r
		}
		// A debugger asked to see the next note before it lands. The
		// note stays pending; `start` delivers it, or a read of
		// `/proc/n/note` takes it away first. See `debug.odin`.
		if p.trace_note {
			p.trace_note = false
			return stop_in_trap(p, r)
		}
	}
	// The kernel's word first, before any handler. See `end`.
	if p != nil && p.handler != 0 && !intrinsics.volatile_load(&p.stopping) {
		if p.notified {
			// One delivery at a time. The note waits, flagged, for the
			// boundary after the handler's own `noted`.
			return r
		}
		if deliver_note(p, r.frame) {
			sched.clear_note(thread)
			return r
		}
	}

	// The frame is a tick's, taken in ring 3: `sched` calls this hook for
	// a user frame alone.
	if p != nil {
		record_frame(&p.exit, r.frame)
		p.exit.noted = true
		intrinsics.volatile_store(&p.exit.done, true)
	}
	sync.wakeup_all(&exit_rendez)
	return sched.kill_current(r)
}

/*
load builds a space, puts a program in it, and starts a thread on it.

Three mappings, and the flags on each are the whole of what a program may do:

    text    read and execute, and **not write**
    data    read and write, and not execute
    stack   read and write, and not execute

Every one of those is a fault the self-test provokes on purpose, because a
permission nothing tests is a permission that may not be there. `mem.map_user`
adds `User` to all three, which is the bit that lets ring 3 reach them at all.

`arg` and `arg2` are the program's second and third arguments. The blobs take
an address to touch, or a length to use. Which address a blob receives is what
makes one run a test of the kernel half and another a test of a read-only page.

**The namespace is forked here rather than shared**, and the descriptors are
opened through the fork rather than through the kernel's. A caller that
rearranges the fork before this returns therefore changes what descriptor 1
means, which is the whole demonstration in `verify_namespaces`.
*/
load :: proc(name: string, code: []u8, arg: u64 = 0, arg2: u64 = 0) -> (^Process, mem.Error) {
	p, err := load_held(name, code)
	if err != .None {
		return nil, err
	}
	if !launch(p, arg, arg2) {
		unload(p)
		return nil, .Out_Of_Memory
	}
	return p, .None
}

// load_held is `load` up to the brink: space, namespace, pages, descriptors,
// and no thread. What a caller stages into the data page before `launch` is
// the program's from its first instruction.
load_held :: proc(name: string, code: []u8) -> (^Process, mem.Error) {
	if len(code) == 0 || len(code) > arch.PAGE_SIZE {
		return nil, .Not_Canonical
	}

	p := claim_slot(parent = 0, detached = false, note_group = 0, rend_group = 0)
	if p == nil {
		return nil, .Out_Of_Memory
	}

	space, err := mem.space_new()
	if err != .None {
		unload(p)
		return nil, err
	}
	p.name = name
	p.space = space

	p.ns = vfs.ns_fork(vfs.boot_namespace, {.Copy})
	if p.ns == nil {
		unload(p)
		return nil, .Out_Of_Memory
	}
	if p.fdt = fdt_new(); p.fdt == nil {
		unload(p)
		return nil, .Out_Of_Memory
	}
	if p.env = env.new_group(); p.env == nil {
		unload(p)
		return nil, .Out_Of_Memory
	}

	if p.text = segment_one_page(p, TEXT_VA, {}, .Text); p.text == 0 {
		unload(p)
		return nil, .Out_Of_Memory
	}
	if p.data = segment_one_page(p, DATA_VA, {.Write, .No_Execute}, .Data); p.data == 0 {
		unload(p)
		return nil, .Out_Of_Memory
	}
	if p.stack = segment_one_page(p, STACK_VA, {.Write, .No_Execute}, .Stack); p.stack == 0 {
		unload(p)
		return nil, .Out_Of_Memory
	}

	// The copy the file comment in `program.odin` argues for. No `User` bit
	// sits anywhere on the path to the kernel image. A program could not
	// execute those bytes where they lie, whatever the source was. Mapped
	// already, but there is no thread yet, so there is no race to lose.
	dst := (cast([^]u8)mem.phys_to_virt(p.text))[:arch.PAGE_SIZE]
	copy(dst, code)

	// Before the thread, not after. A program's first instruction may be a
	// write to descriptor 1. The next interrupt can dispatch any thread that
	// is already on a run queue.
	open_standard(p)
	return p, .None
}

/*
launch puts a thread on a held program, which is the moment it can run.

Split from `load_held` for one reason, found as a one-in-twenty flake. A
caller that stages bytes into the data page *after* the thread exists races
the program for its own memory. The next interrupt can dispatch the new
thread, and a program whose first message is half-staged prints the staged
half and zeroes for the rest. Staging before `launch` is not a convention to
remember. There is no thread yet, so there is no race to lose.

The thread gets `p` before it can run, because the fault handler reads it
and the first fault may arrive on the very next interrupt.
*/
launch :: proc(p: ^Process, arg: u64 = 0, arg2: u64 = 0) -> bool {
	if p == nil || p.thread != nil {
		return false
	}
	p.thread = sched.spawn_user(p.name, p.space, TEXT_VA, STACK_TOP, u64(DATA_VA), arg, arg2, p)
	if p.thread == nil {
		return false
	}
	note_born(p)
	p.kstack_lo = uintptr(raw_data(p.thread.stack))
	p.kstack_hi = p.thread.kstack_top
	loaded += 1
	return true
}

/*
wait polls for a program to end, up to a bound in ticks.

Polling rather than parking. What this waits for is a fault in interrupt
context, and nothing there may take a lock or wake a sleeper. A rendezvous
becomes the right answer the moment a program can exit deliberately. Until then
the only event is a trap, and a trap is the worst place to grow a dependency.

Returns false when the bound runs out, which is a program that did not end. The
caller has to treat that as the failure it is: `destroy` will refuse it, and
its space and frames stay out of circulation.
*/
wait :: proc "contextless" (p: ^Process, patience: int) -> bool {
	if p == nil {
		return false
	}
	return sync.sleep_for(&exit_rendez, exit_done, p, u64(patience))
}

/*
blocked reports how many times a program's thread was woken.

A thread that never parked has none. A system call that parks is therefore
visible from outside as a number, rather than inferred from how long the
program took.

**Valid only until the next `load`.** A dead thread's record is still allocated
until something reaps it, and `spawn` is what reaps. `destroy` clears the
pointer, which is why this reads zero afterwards rather than reads freed
memory.
*/
blocked :: proc "contextless" (p: ^Process) -> u64 {
	if p == nil {
		return 0
	}
	// Under `table_lock`, so `p.thread` is a live record or nil, never one
	// the collector is freeing. See `on_thread_reaped`.
	guard := sync.acquire(&table_lock)
	defer sync.release(&table_lock, guard)
	return p.thread != nil ? p.thread.wakeups : 0
}

/*
cell reads one eight-byte word of a program's data page, from the kernel side.

Through the direct map, not through the program's space. The kernel is not
translating through those tables and must not have to be. That is also what
makes the page shared in the honest sense: the same frame, two mappings, two
privilege levels, and neither one a copy.
*/
cell :: proc "contextless" (p: ^Process, index: int) -> u64 {
	if p == nil || p.data == 0 || index < 0 || index >= arch.PAGE_SIZE / size_of(u64) {
		return 0
	}
	words := cast([^]u64)mem.phys_to_virt(p.data)
	return intrinsics.volatile_load(&words[index])
}

// set_cell writes one word of a program's data page. The other direction of
// `cell`, and what tells `spin` to stop.
set_cell :: proc "contextless" (p: ^Process, index: int, value: u64) {
	if p == nil || p.data == 0 || index < 0 || index >= arch.PAGE_SIZE / size_of(u64) {
		return
	}
	own_data(p)
	words := cast([^]u64)mem.phys_to_virt(p.data)
	intrinsics.volatile_store(&words[index], value)
}

/*
destroy gives back a program's space and its three frames.

Refuses a program that did not end. The space is the tree the machine would
translate through if its thread ran again. The frames are pages that thread may
still write to. There is no way to stop it, so the only safe answer is to keep
them.

That refusal is a leak, and it is the honest kind: it is visible in
`stats().live` and in the frame count, rather than absorbed. See the file
comment.
*/
destroy :: proc(p: ^Process) -> bool {
	if p == nil {
		return false
	}
	return collect(p, p.pid)
}

/*
collect is `destroy` for a collector that saw the record a moment ago, and
names the process it saw.

**A slot is not an identity, and a pid is.** The reaper, a fork that wants a
slot, and a parent's `wait` each read a record, decide it is dead, and reach
for it. A tick between the two lets the slot be freed and reborn. The claim
below then lands on a process the caller never looked at, a newborn whose
thread has not run. It passes the "ended" test for the wrong reason. The
compare-and-swap on `collecting` closes the double release on one record and
says nothing about two records in one slot.

The pid is the generation. It is monotonic and never reused, which is what
`kernel/srv` keeps an id for and `wait` already leans on. So the claim is
taken and then the pid is read again, and a claim on a slot that changed
tenants is given back untouched. The loser answers false, which is the answer
it would get from a record that was already gone.
*/
collect :: proc(p: ^Process, pid: u64) -> bool {
	if p == nil {
		return false
	}
	// The check and the claim are one step under the table lock, so a slot
	// cannot change tenants between them. One collector: the reaper takes a
	// detached process the moment it ends, and a fork or a self-test may reach
	// for the same record a tick later. The second finds `collecting` set.
	for {
		guard := sync.acquire(&table_lock)
		ok := p.live && p.pid == pid && !p.collecting
		if ok && p.thread != nil && !intrinsics.volatile_load(&p.exit.done) {
			ok = false
		}
		if ok && p.pins > 0 {
			// A debugger is reading its memory through /proc. The record
			// outlives the read, which is a page copy, and this comes back.
			sync.release(&table_lock, guard)
			sync.delay(1)
			continue
		}
		if ok {
			p.collecting = true
		}
		sync.release(&table_lock, guard)
		if !ok {
			return false
		}
		unload(p)
		return true
	}
}

/*
set_bytes copies into a program's data page from the kernel side.

The other direction of `copy_in` in `syscall.odin`, and much the easier one.
The kernel owns the frame, reaches it through the direct map, and is not
guessing about what is mapped where. That asymmetry is the whole reason a
kernel has a `copy_in` and does not have a `copy_out` that checks anything.
*/
set_bytes :: proc "contextless" (p: ^Process, offset: int, data: []u8) -> bool {
	if p == nil || p.data == 0 || offset < 0 {
		return false
	}
	own_data(p)
	if offset + len(data) > arch.PAGE_SIZE {
		return false
	}
	dst := (cast([^]u8)mem.phys_to_virt(p.data))[:arch.PAGE_SIZE]
	copy(dst[offset:], data)
	return true
}

/*
reparent_children detaches every live child of a process about to go.

A child's `parent` is a pid, and a pid never reuses. Once the parent's slot
is gone, the child names a parent that will never call `wait`. It dangles
uncollectable then, the honest leak the handoff named beside `RFNOWAIT`. So
the teardown hands its children to the kernel: `parent` zero, `detached` set,
and `reap_orphans` collects each when it ends. This is Plan 9's
reparent-to-init with the kernel standing in for init.

Runs before the record is zeroed, off `p.pid`. A process the kernel built
has a zero parent already, so its children are no one else's to wait for.
*/
@(private = "file")
reparent_children :: proc "contextless" (dying_pid: u64) #no_bounds_check {
	if dying_pid == 0 {
		return
	}
	guard := sync.acquire(&table_lock)
	defer sync.release(&table_lock, guard)
	for i in 0 ..< MAX_PROCESSES {
		c := &processes[i]
		if c.live && c.parent == dying_pid {
			c.parent = 0
			c.detached = true
		}
	}
}

/*
reap_orphans collects every detached process that ended, and reports how
many.

The counterpart to `wait_pid` for a process no parent will wait for. A
detached process is the kernel's, so the kernel gives its record back. But
only once its thread is gone, which `exit.done` reports and `destroy`
re-checks. A detached process still running is left for a later pass.

Called from the reaper at every ending now, and still where a slot is wanted
and where a count is about to be believed. The reaper is what makes a
detached process go back on its own. The other callers make it go back
*before* a decision that depends on it. The reaper is a thread, and a thread
runs when the scheduler gets to it. A self-test that wants to
look at a detached process has to hold it alive to do so, and `verify_reap`
does.
*/
/*
hangup_dead gives back the descriptors of every process whose thread has gone,
and reports how many tables it released.

**This is the hangup a faulting server never performed.** `sys_exit` releases
the descriptor group before it publishes the exit record, so a process that
ends deliberately hangs up its pipes on the way out. `on_trap` cannot: it is a
trap handler with interrupts off, and `fdt_release` closes chans, and a clunk
is a message that may park. So a process that *faulted* kept its descriptors
until something called `destroy`, and `destroy` ran only from `spawn_path`.

The consequence was not a leak but a **hang**. A ring 3 server that faults
mid-request never hangs up its pipe, so the client parked on it waits for a
reply from a process that no longer exists. `docs/TESTING.md` names a hang as
the worst way for a check to report, and this is the one gap in the tree that
turns a failed check into one.

**The record stays for a parent.** Only the descriptors go here, which is
Plan 9's `pexit` closing the file group while the proc record waits for its
parent. A parent parked in `wait` still gets its child's exit status. A
record nobody will wait for is a different case, and the reaper collects it
whole through `reap_orphans` one call later -- see the thread below.

The exchange is atomic because three paths race for the same pointer -- this
one, `sys_exit` on another thread, and `unload` from a collector. Whoever wins
releases, and the losers find nil. That is the "one release per holder,
whichever paths ran" rule `unload` already states, made true rather than
argued.
*/
hangup_dead :: proc() -> (released: int) #no_bounds_check {
	for i in 0 ..< MAX_PROCESSES {
		p := &processes[i]
		// The check and the exchange are one step under the table lock, so
		// the table taken is the dead tenant's and never a newborn's. The
		// release is outside it, because closing a descriptor can park.
		guard := sync.acquire(&table_lock)
		t: ^Fd_Table
		if p.live && intrinsics.volatile_load(&p.exit.done) {
			t = intrinsics.atomic_exchange(&p.fdt, nil)
		}
		sync.release(&table_lock, guard)
		if t != nil {
			fdt_release(t)
			released += 1
		}
	}
	return released
}

// dead_needs_collecting is the reaper's wake condition. Some process ended
// and still holds a descriptor group, or is nobody's and still holds a
// record.
@(private = "file")
dead_needs_collecting :: proc "contextless" (arg: rawptr) -> bool #no_bounds_check {
	for i in 0 ..< MAX_PROCESSES {
		p := &processes[i]
		if p.live && intrinsics.volatile_load(&p.exit.done) && (p.fdt != nil || p.detached) {
			return true
		}
	}
	return false
}

/*
The reaper thread, which is what makes the release above happen without
anybody asking, and takes a detached process's record back the same way.

It parks on `exit_rendez`, the rendezvous every ending already wakes -- the
deliberate exit, the note, and the fault. So the trigger costs nothing and no
death path grew a line.

**A detached process goes whole, and the moment it ends.** It used to wait
for the next fork, because `reap_orphans` ran only where a slot was wanted.
That left every count a dead process still held standing until then. A
concurrent server's worker, forked `RFNOWAIT` per parked request, kept its
segments after it answered and exited. `segbrk` counted three dead ones as
sharers of every window run. The general shape of that fix is this thread.

A process nobody will wait for is the kernel's, and the kernel collects it
when it ends, which is init reaping on Plan 9. A process a parent may still
`wait` for keeps its record, as before.

The deadline is a backstop rather than a schedule. Every ending wakes this,
and a wake that finds nothing goes straight back to sleep, so the timeout only
matters if a wake were ever missed.
*/
REAP_PATIENCE :: 50

@(private = "file")
reaper :: proc "contextless" (arg: rawptr) {
	// A clunk crossing to a ring 3 server runs a codec on this stack, and a
	// codec may allocate. `kernel/mnt`'s worker takes a context for the same
	// reason and in the same words.
	context = mem.kernel_context()

	for {
		_ = sync.sleep_for(&exit_rendez, dead_needs_collecting, nil, REAP_PATIENCE)
		intrinsics.volatile_store(&reaper_busy, true)
		hangup_dead()
		reap_orphans()
		intrinsics.volatile_store(&reaper_busy, false)
	}
}

// Whether the reaper is between waking and going back to sleep. Its work
// releases descriptor tables, and the last chan closed into a dead server's
// mount releases that server's wire, fifty-odd objects, on the reaper's own
// stack. See `settled`.
@(private = "file")
reaper_busy: bool

/*
settled is whether the collectors are idle: no process has ended holding a
descriptor table or a record nobody will wait for, and the reaper is not part
way through releasing one.

Shaped for `sync.await`. A self-test that brackets the heap reads its opening
number only when this holds, because the reaper usually beats the test's own
`finish` to a dead process's descriptors and closes them on its own time. A
test that stopped a server, waited for it and moved on reached the next
test's opening reading before the reaper had closed the last chan into that
server's mount, and the wire it then released read as minus fifty-three
objects in the next bracket, one boot in eight. `docs/TESTING.md`.
*/
settled :: proc "contextless" (arg: rawptr) -> bool {
	_ = arg
	return !intrinsics.volatile_load(&reaper_busy) && !dead_needs_collecting(nil)
}

// reaper_start puts the collector on the scheduler. Called once, from init.
reaper_start :: proc() -> bool {
	return sched.spawn("reaper", reaper) != nil
}

reap_orphans :: proc() -> (collected: int) #no_bounds_check {
	for i in 0 ..< MAX_PROCESSES {
		p := &processes[i]
		// The candidate is read under the lock and named by pid, and
		// `collect` checks the name again under the lock before it claims.
		guard := sync.acquire(&table_lock)
		pid := p.pid
		due := p.live && p.detached && intrinsics.volatile_load(&p.exit.done)
		sync.release(&table_lock, guard)
		if due && collect(p, pid) {
			collected += 1
		}
	}
	return collected
}

@(private)
unload :: proc(p: ^Process) {
	// Children first, before the pid this reparenting keys on is zeroed. A
	// process that outlives its parent becomes the kernel's to reap rather
	// than a dangling pointer to a pid nobody holds. See `reparent_children`.
	reparent_children(p.pid)

	// The descriptors first, and the namespace after them. A chan holds a
	// reference to the server it came from, and the mount table holds
	// references to the chans it was built out of. The order is deliberate.
	// Closing the namespace first would leave every open file pointing into a
	// mount table with one reference left and no way to reach it. A process
	// that exited deliberately already detached its table, and this release
	// finds nothing -- one release per holder, whichever paths ran.
	//
	// Taken with an exchange, not a test, because the reaper thread takes it
	// the same way and the two race for real. A process that faulted or was
	// noted still holds its table when its ending wakes both this collector
	// and the reaper. The reaper usually gets there first. When it does not,
	// a test-then-release here left the pointer standing for as long as the
	// closes took, and the reaper found it and released the table a second
	// time. The first release had already given the pool slot back, so the
	// second closed whichever process had been handed that slot since --
	// three chans out from under a live process, and a namespace mount point
	// whose count never came back to zero. It showed up as one 64-byte
	// object leaked, one boot in twenty or so, first in the draw server's
	// teardown and then wherever timing put it.
	if t := intrinsics.atomic_exchange(&p.fdt, nil); t != nil {
		fdt_release(t)
	}
	if p.env != nil {
		env.release(p.env)
		p.env = nil
	}
	if p.ns != nil {
		vfs.ns_close(p.ns)
	}
	if p.space != nil {
		mem.space_destroy(p.space)
	}
	// Segments after the space, deliberately. The tables come down first, so
	// there is no window where a still-standing table entry names a frame the
	// release already recycled. The frames themselves outlive this process
	// whenever another still holds the segment.
	for i in 0 ..< p.seg_count {
		segment_release(p.segs[i])
	}
	// The thread record, then the slot, under one lock. The thread went Dead
	// and the reaper gave its stack back, but the record stayed, so a note
	// sender read a live Dead record. Zeroing the slot removes `p.thread`. The
	// record is freed here if reap already reached it, and left for reap
	// otherwise, which then finds `p.thread` gone and frees it. The release is
	// under the lock, so a claim on another core sees the slot whole and free,
	// not half zeroed and live. See `on_thread_reaped`.
	rend_forget(p)
	guard := sync.acquire(&table_lock)
	dead := p.thread
	reaped := dead != nil && dead.reaped
	p^ = Process{}
	sync.release(&table_lock, guard)
	if reaped {
		sched.free_reaped(dead)
	}
}

/*
claim_slot takes a free slot and makes it live, with its pid, in one step.

Everything a second core could race on is written here: `live`, the pid,
the parent, and the note group, with the pid counter advanced under the same
hold. The caller fills in the rest of the record on a slot that is already
its own. A claim that fails later -- no space, no namespace -- is given back
through `unload`, which is what a record with nothing in it needs.

`note_group` of zero means `the new pid`. A process with no parent wants that,
and so does a child forked into a group of its own. `rend_group` follows the
same rule: inherited, or a group of one under `RFREND`.

`inherit` is the parent, or nil for a process the kernel builds. The user
and the current directory follow it, as the namespace does.
*/
@(private)
claim_slot :: proc "contextless" (parent: u64, detached: bool, note_group: u64, rend_group: u64, inherit: ^Process = nil) -> ^Process #no_bounds_check {
	guard := sync.acquire(&table_lock)
	defer sync.release(&table_lock, guard)
	for i in 0 ..< MAX_PROCESSES {
		p := &processes[i]
		if p.live {
			continue
		}
		p^ = Process {
			live       = true,
			pid        = next_pid,
			parent     = parent,
			detached   = detached,
			note_group = note_group == 0 ? next_pid : note_group,
			rend_group = rend_group == 0 ? next_pid : rend_group,
		}
		// A child is its parent's user; a process with no parent is the
		// host owner's, which is who the kernel runs as.
		if inherit != nil {
			p.ulen = copy(p.user[:], inherit.user[:inherit.ulen])
			_ = set_directory(p, current_directory(inherit))
		} else {
			p.ulen = copy(p.user[:], hostowner[:hostowner_len])
		}
		next_pid += 1
		return p
	}
	return nil
}

// -- Users -----------------------------------------------------------------------

USER_MAX :: 32

/*
The host owner: the user the machine itself runs as, `glenda` until `init`
says otherwise by writing `hostowner` to its own ctl file, with the name the
database gives the machine. Every process the kernel starts is the host
owner's, and the host owner's processes are the ones that may become
another user, which is what a server does for a client it has proved.
*/
hostowner: [USER_MAX]u8 = {0 = 'g', 1 = 'l', 2 = 'e', 3 = 'n', 4 = 'd', 5 = 'a'}
hostowner_len: int = 6

user_of :: proc "contextless" (p: ^Process) -> string {
	if p == nil {
		return string(hostowner[:hostowner_len])
	}
	return string(p.user[:p.ulen])
}

hostowner_name :: proc "contextless" () -> string {
	return string(hostowner[:hostowner_len])
}

is_hostowner :: proc "contextless" (p: ^Process) -> bool {
	return p != nil && string(p.user[:p.ulen]) == string(hostowner[:hostowner_len])
}

/*
proc_set_user makes process `pid` the user `name`: `user` on `/proc/n/ctl`.
Only the process itself may be changed, and only by a process of the host
owner's. False is a refusal or a name too long.
*/
proc_set_user :: proc "contextless" (pid: u64, name: string) -> bool {
	caller := current()
	if caller == nil || caller.pid != pid || !is_hostowner(caller) || len(name) == 0 || len(name) > USER_MAX {
		return false
	}
	caller.ulen = copy(caller.user[:], name)
	return true
}

/*
set_hostowner is `hostowner` on `/proc/n/ctl`: a process of the host owner's
names the host, and process `pid` becomes that user. `init` does it once,
with the name the database gives the machine, before anything runs that
must be the host's.

The target is `pid`, not the caller, and that is the whole point. `init`
writes it as `echo hostowner $sysname > /proc/$pid/ctl`, and `echo` is a
program: rc forks and execs it, so the write arrives from a child whose pid
is not `$pid`. A rule of `only yourself` refused every such write, silently,
and the host never had an owner but the kernel's default -- so nothing
downstream could ever `become` a client it had proved. Plan 9's
`#c/hostowner` is the same shape: writable by whoever is eve now, and it
sets the writer's process user as well as the name. The caller gets it too,
so a program that writes its own ctl ends up as it asked either way.
`user` stays a process's own to change, which is what `exportfs` does for
the client it proved, with `getpid` and no fork between.
*/
set_hostowner :: proc "contextless" (pid: u64, name: string) -> bool {
	caller := current()
	if caller == nil || !is_hostowner(caller) || len(name) == 0 || len(name) > USER_MAX {
		return false
	}
	guard := sync.acquire(&table_lock)
	target := live_by_pid(pid)
	if target == nil {
		sync.release(&table_lock, guard)
		return false
	}
	hostowner_len = copy(hostowner[:], name)
	target.ulen = copy(target.user[:], name)
	if caller != target {
		caller.ulen = copy(caller.user[:], name)
	}
	sync.release(&table_lock, guard)
	return true
}

/*
may_control says whether the calling process may stop, start, kill or note
process `pid`: its own user's processes, or any as the host owner. A thread
with no process -- the kernel's own -- may control anything, since it is the
kernel. `docs/PROC.md`'s line that any process may stop any other retires.
*/
may_control :: proc "contextless" (pid: u64) -> bool {
	caller := current()
	if caller == nil || is_hostowner(caller) {
		return true
	}
	guard := sync.acquire(&table_lock)
	target := live_by_pid(pid)
	same := target == nil || string(target.user[:target.ulen]) == string(caller.user[:caller.ulen])
	sync.release(&table_lock, guard)
	return same // A target that is gone is left for the operation to say ESRCH.
}


// -- Descriptors -------------------------------------------------------------
//
// The table itself, its pool, and every per-descriptor operation live in
// `fdtable.odin`. What stays here is the one procedure that knows which
// files a process is *born* holding.

/*
open_standard gives a new process the three descriptors a program expects.

All three on `/dev/cons`, through **this process's** namespace rather than the
kernel's. That distinction is inert today, because the fork is a faithful copy
at the moment it is made. It stops being inert the first time somebody
rearranges the fork before the process starts.

A failure here is not fatal to the process. A program that writes to a
descriptor it does not have gets `EBADF`, which is a better answer than a
process that could not start.
*/
@(private)
open_standard :: proc(p: ^Process) {
	if p == nil || p.ns == nil {
		return
	}
	modes := [3]u32{vfs.O_RDONLY, vfs.O_WRONLY, vfs.O_WRONLY}
	for mode in modes {
		c, err := vfs.open_path(p.ns, "/dev/cons", mode)
		if err != vfs.OK {
			return
		}
		if _, ok := fd_open(p, c); !ok {
			vfs.chan_close(c)
			return
		}
	}
}

// pid_of is a process's pid, for a caller outside this package that holds a
// record and wants the identity rather than the slot.
pid_of :: proc "contextless" (p: ^Process) -> u64 {
	return p == nil ? 0 : p.pid
}
