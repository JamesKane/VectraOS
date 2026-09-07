/*
What `#p` may know about a process, and do to one.

`kernel/proc` serves the process table as files and imports this package
to read it. These are the only doors: a snapshot of one record, the next
live pid after a given one, a note, a kill, and the namespace written out.
Each takes the table lock for as long as it reads and no longer, so a
process that ends mid-listing is a missing entry and not a torn one.
*/
package user

import "base:intrinsics"

import "kernel:sched"
import "kernel:sync"
import "kernel:vfs"

/*
A snapshot of one record. The strings point into the snapshot's own
buffers, so it is the caller's to keep and to read after the lock is gone.
They pointed into buffers of this package once, and `procfs` built its
text after `proc_info` returned. Two `ps` on two cores then wrote one
buffer between them, and a status line could carry another process's name
or directory. The snapshot is filled in place rather than returned, because
a string into a value that is then copied points at the copy's source.
*/
Proc_Info :: struct {
	name:       string, // into `name_buf`
	pid:        u64,
	parent:     u64,
	note_group: u64,
	detached:   bool,
	state:      string, // Ready, Running, Blocked, Stopped, Exited, or Faulted
	user:       string, // Whose process it is, into `user_buf`
	cwd:        string, // into `cwd_buf`
	args:       string, // the arguments it was started with, as `/proc/n/args` shows them
	name_buf:   [PATH_MAX]u8,
	cwd_buf:    [PATH_MAX]u8,
	user_buf:   [USER_MAX]u8,
	args_buf:   [ARGS_KEEP]u8,
}

// proc_info fills `info` from one record, or answers false for a pid that
// is not live.
proc_info :: proc "contextless" (pid: u64, info: ^Proc_Info) -> bool #no_bounds_check {
	guard := sync.acquire(&table_lock)
	defer sync.release(&table_lock, guard)
	p := live_by_pid(pid)
	if p == nil {
		return false
	}
	n := copy(info.name_buf[:], p.name)
	info.name = string(info.name_buf[:n])
	u := copy(info.user_buf[:], p.user[:p.ulen])
	info.user = string(info.user_buf[:u])
	c := copy(info.cwd_buf[:], current_directory(p))
	info.cwd = string(info.cwd_buf[:c])
	a := copy(info.args_buf[:], p.args_buf[:p.args_len])
	info.args = string(info.args_buf[:a])
	info.pid = p.pid
	info.parent = p.parent
	info.note_group = p.note_group
	info.detached = p.detached
	switch {
	case intrinsics.volatile_load(&p.exit.done):
		info.state = p.exit.deliberate || p.exit.noted ? "Exited" : "Faulted"
	case p.thread == nil:
		info.state = "Starting"
	case p.stopped:
		info.state = "Stopped"
	case:
		switch p.thread.state {
		case .Ready:
			info.state = "Ready"
		case .Running:
			info.state = "Running"
		case .Blocked:
			info.state = "Blocked"
		case .Dead:
			info.state = "Dead"
		}
	}
	return true
}

// proc_live says whether a pid names a live process: the existence check
// the device makes on every walk, open and stat, without a snapshot.
proc_live :: proc "contextless" (pid: u64) -> bool {
	guard := sync.acquire(&table_lock)
	defer sync.release(&table_lock, guard)
	return live_by_pid(pid) != nil
}

// proc_after is the smallest live pid greater than `pid`, or zero.
proc_after :: proc "contextless" (pid: u64) -> u64 #no_bounds_check {
	guard := sync.acquire(&table_lock)
	defer sync.release(&table_lock, guard)
	best: u64
	for i in 0 ..< MAX_PROCESSES {
		p := &processes[i]
		if p.live && p.pid > pid && (best == 0 || p.pid < best) {
			best = p.pid
		}
	}
	return best
}

// proc_note posts a note to a process by pid, from anyone: Plan 9 grants
// notes by owner, and there are no owners yet.
proc_note :: proc "contextless" (pid: u64, text: string) -> bool {
	guard := sync.acquire(&table_lock)
	p := live_by_pid(pid)
	sync.release(&table_lock, guard)
	return post_note(p, text)
}

// proc_kill ends a process unconditionally at its next boundary, without
// waiting for it: `end` less the wait, for a writer of `/proc/n/ctl`.
proc_kill :: proc "contextless" (pid: u64) -> bool {
	guard := sync.acquire(&table_lock)
	p := live_by_pid(pid)
	sync.release(&table_lock, guard)
	return request_end(p)
}

// proc_stop asks a process to stop at its next boundary. The wake is a
// note's, and the record remembers it was a stop's, so the boundary parks
// rather than delivers. See `stop_here`.
proc_stop :: proc "contextless" (pid: u64) -> bool {
	guard := sync.acquire(&table_lock)
	p := live_by_pid(pid)
	sync.release(&table_lock, guard)
	if p == nil || p.thread == nil || intrinsics.volatile_load(&p.exit.done) {
		return false
	}
	p.stop_wake = true
	intrinsics.volatile_store(&p.stop_requested, true)
	sched.note_thread(p.thread)
	return true
}

/*
proc_start lets a stopped process go on: the ask comes down, the door's
sleeper wakes, and a thread the tick parked is readied by hand.

The wake for the tick's park is `sched.unstop`, not `ready`. A kill that
lands while the process is stopped wakes it out of that park by the note
path, and the thread then walks its exit, which closes descriptors and may
park in a sleeping lock on the way. `stopped_in_tick` is still set then,
because only this call clears it. A plain `ready` here would pull the
thread out of that lock without the handoff, which is the stale wake
`docs/SYNC.md` records. `unstop` wakes only a park that a note may wake,
which is the tick's park and never a lock's.
*/
proc_start :: proc "contextless" (pid: u64) -> bool {
	guard := sync.acquire(&table_lock)
	p := live_by_pid(pid)
	sync.release(&table_lock, guard)
	if p == nil || p.thread == nil {
		return false
	}
	intrinsics.volatile_store(&p.stop_requested, false)
	sync.wakeup_all(&stop_rendez)
	if p.stopped_in_tick {
		// The tick's park announces itself a few instructions before it
		// parks. A start that arrives inside them would find the thread
		// still running and wake nothing, so wait for the park, briefly.
		for _ in 0 ..< 50 {
			if p.thread == nil || intrinsics.volatile_load(&p.thread.state) == .Blocked || intrinsics.volatile_load(&p.exit.done) {
				break
			}
			sync.delay(1)
		}
		p.stopped_in_tick = false
		p.stopped = false
		p.stop_frame = nil
		p.stop_fpu = nil
		sched.unstop(p.thread)
	}
	return true
}

// proc_namespace writes a process's mount table as `bind` and `mount`
// lines into `out`, and answers the length, or -1 for no such process.
proc_namespace :: proc(pid: u64, out: []u8) -> int {
	guard := sync.acquire(&table_lock)
	p := live_by_pid(pid)
	ns := p != nil && p.ns != nil ? vfs.ns_incref(p.ns) : nil
	sync.release(&table_lock, guard)
	if ns == nil {
		return -1
	}
	n := vfs.ns_describe(ns, out)
	vfs.ns_close(ns)
	return n
}

@(private)
live_by_pid :: proc "contextless" (pid: u64) -> ^Process #no_bounds_check {
	for i in 0 ..< MAX_PROCESSES {
		p := &processes[i]
		if p.live && p.pid == pid {
			return p
		}
	}
	return nil
}
