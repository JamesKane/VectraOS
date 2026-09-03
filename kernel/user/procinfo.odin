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

Proc_Info :: struct {
	name:       string, // into a static buffer of this package; copy it before the next call
	pid:        u64,
	parent:     u64,
	note_group: u64,
	detached:   bool,
	state:      string, // Ready, Running, Blocked, Exited, or Faulted
	cwd:        string,
}

@(private = "file") info_name: [PATH_MAX]u8
@(private = "file") info_cwd: [PATH_MAX]u8

// proc_info reads one record, or answers false for a pid that is not live.
proc_info :: proc "contextless" (pid: u64) -> (info: Proc_Info, ok: bool) #no_bounds_check {
	guard := sync.acquire(&table_lock)
	defer sync.release(&table_lock, guard)
	p := live_by_pid(pid)
	if p == nil {
		return {}, false
	}
	n := copy(info_name[:], p.name)
	info.name = string(info_name[:n])
	c := copy(info_cwd[:], current_directory(p))
	info.cwd = string(info_cwd[:c])
	info.pid = p.pid
	info.parent = p.parent
	info.note_group = p.note_group
	info.detached = p.detached
	switch {
	case intrinsics.volatile_load(&p.exit.done):
		info.state = p.exit.deliberate || p.exit.noted ? "Exited" : "Faulted"
	case p.thread == nil:
		info.state = "Starting"
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
	return info, true
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
	if p == nil || p.thread == nil || intrinsics.volatile_load(&p.exit.done) {
		return false
	}
	text := "sys: killed"
	for i in 0 ..< len(text) {
		p.note_buf[i] = text[i]
	}
	p.note_len = len(text)
	intrinsics.volatile_store(&p.stopping, true)
	sched.note_thread(p.thread)
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

@(private = "file")
live_by_pid :: proc "contextless" (pid: u64) -> ^Process #no_bounds_check {
	for i in 0 ..< MAX_PROCESSES {
		p := &processes[i]
		if p.live && p.pid == pid {
			return p
		}
	}
	return nil
}
