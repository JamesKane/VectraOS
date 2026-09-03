/*
`#p`: the process table as a directory, bound at `/proc`.

Plan 9's `/proc/n/` is a directory per process, with files that describe it
and files that act on it. This is the four a shell needs:

    /proc/n/status    one line: name, pid, parent, state, note group, directory
    /proc/n/ns        the mount table as bind and mount lines a script can replay
    /proc/n/note      a write posts a note; a read is the last note posted
    /proc/n/ctl       a write of `kill` ends the process at its next boundary

`ps` reads the first, `ns` the second, and `kill` writes the last. The
listing of `/proc` is the live pids, in order, with the pid as the cookie:
a process that ends between two reads is a missing entry.

The device imports `kernel/user` and reads through the five doors
`procinfo.odin` opens; it holds no process pointer across a message. A fid
names a pid and a file, and a pid that is gone answers `no such process`.

Synchronous, like `#e` and `#s`: every message is a table lookup.
*/
package procfs

import "base:runtime"

import "kernel:mem"
import "kernel:sync"
import "kernel:user"
import "kernel:vfs"
import "vsys:libodin"
import "vsys:vectra9"

PROC_MAX_FIDS :: 64

// A node is a pid and a file kind. Zero is the root.
File :: enum i32 {
	Dir,
	Status,
	Ns,
	Note,
	Ctl,
}

FILE_NAMES := [File]string {
	.Dir    = "",
	.Status = "status",
	.Ns     = "ns",
	.Note   = "note",
	.Ctl    = "ctl",
}

// Pids fit in 28 bits here; a machine that counts past that has outrun a
// i32 node and asks this to move.
PID_BITS :: 28

S_IFDIR :: u32(0o040000)
S_IFREG :: u32(0o100000)

@(private = "file")
Proc_Device :: struct {
	fids:   vfs.Fid_Table,
	lock:   sync.Spinlock,
	server: vfs.Server,
	notes:  u64, // notes posted through /proc/n/note
	kills:  u64, // and kills through ctl
}

@(private = "file")
dev: Proc_Device

init :: proc(ns: ^vfs.Namespace) -> vfs.Errno {
	d := &dev
	if !vfs.fidtab_init(&d.fids, PROC_MAX_FIDS) {
		return vectra9.ENOMEM
	}
	if err := vfs.server_init(&d.server, "p", proc_handler, d); err != .None {
		vfs.fidtab_destroy(&d.fids)
		return vectra9.EPROTO
	}
	if !vfs.register_device(&d.server) {
		vfs.fidtab_destroy(&d.fids)
		return vectra9.EEXIST
	}
	return vfs.mount_device(ns, "#p", "/proc")
}

// stats reports what the device did: notes and kills, for the boot line.
stats :: proc "contextless" () -> (notes, kills: u64) {
	g := sync.acquire(&dev.lock)
	defer sync.release(&dev.lock, g)
	return dev.notes, dev.kills
}

ROOT :: i32(0)

@(private = "file")
node_of :: proc "contextless" (pid: u64, f: File) -> i32 {
	return i32(pid) << 3 | i32(f)
}

@(private = "file")
split :: proc "contextless" (node: i32) -> (pid: u64, f: File) {
	return u64(node >> 3), File(node & 7)
}

@(private = "file")
qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	_, f := split(node)
	kind: vectra9.Qid_Flags
	if f == .Dir {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

@(private = "file")
proc_handler :: proc "contextless" (
	server: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) {
	_ = server
	_ = s
	_ = tag
	ctx := runtime.default_context()
	ctx.allocator = mem.allocator()
	context = ctx
	dispatch(request, reply, buf)
}

@(private = "file")
dispatch :: proc(request: ^vectra9.Msg, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	d := &dev
	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)
	if vectra9.creates(vectra9.kind(request^)) {
		reply^ = vectra9.error_reply(vectra9.EPERM)
		return
	}
	if m, is_read := request.(vectra9.Tread); is_read {
		// Apart, because writing a namespace out takes its read lock, which
		// sleeps, and nothing may sleep under the device's spinlock.
		read(m, reply, buf)
		return
	}
	g := sync.acquire(&d.lock)
	defer sync.release(&d.lock, g)

	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply)

	case vectra9.Tattach:
		if !vfs.fidtab_bind(&d.fids, m.fid, ROOT) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
		reply^ = vectra9.Rattach{qid = qid_of(ROOT)}

	case vectra9.Twalk:
		walk(m, reply)

	case vectra9.Tlopen:
		node := vfs.fidtab_node(&d.fids, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		pid, f := split(node)
		if node != ROOT {
			if _, ok := user.proc_info(pid); !ok {
				reply^ = vectra9.error_reply(vectra9.ESRCH)
				return
			}
		}
		if f == .Dir && m.flags & 0o3 != vfs.O_RDONLY {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		vfs.fidtab_set_open(&d.fids, m.fid, true)
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}

	case vectra9.Twrite:
		node := vfs.fidtab_node(&d.fids, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		if !vfs.fidtab_is_open(&d.fids, m.fid) {
			reply^ = vectra9.error_reply(vectra9.EINVAL)
			return
		}
		pid, f := split(node)
		text := trim_newline(string(m.data))
		switch f {
		case .Note:
			if !user.proc_note(pid, text) {
				reply^ = vectra9.error_reply(vectra9.ESRCH)
				return
			}
			d.notes += 1
		case .Ctl:
			if text != "kill" {
				reply^ = vectra9.error_reply(vectra9.EINVAL)
				return
			}
			if !user.proc_kill(pid) {
				reply^ = vectra9.error_reply(vectra9.ESRCH)
				return
			}
			d.kills += 1
		case .Dir:
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		case .Status, .Ns:
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		reply^ = vectra9.Rwrite{count = u32(len(m.data))}

	case vectra9.Treaddir:
		readdir(m, reply, buf)

	case vectra9.Tgetattr:
		node := vfs.fidtab_node(&d.fids, m.fid)
		if node < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		pid, f := split(node)
		if node != ROOT {
			if _, ok := user.proc_info(pid); !ok {
				reply^ = vectra9.error_reply(vectra9.ESRCH)
				return
			}
		}
		attr := vectra9.Rgetattr {
			valid   = m.request_mask & vfs.GETATTR_BASIC,
			qid     = qid_of(node),
			mode    = f == .Dir ? S_IFDIR | 0o555 : (f == .Status || f == .Ns ? S_IFREG | 0o444 : S_IFREG | 0o222),
			nlink   = f == .Dir ? 2 : 1,
			blksize = 512,
		}
		// Size zero for the readable files, as Plan 9 reports its: the text
		// is made when it is read, and reading it here would take a lock
		// that sleeps under one that does not.
		reply^ = attr

	case vectra9.Tstatfs:
		if vfs.fidtab_node(&d.fids, m.fid) < 0 {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		reply^ = vectra9.Rstatfs{type = 0x0139_9249, bsize = 512, namelen = 20}

	case vectra9.Tremove:
		_ = vfs.fidtab_release(&d.fids, m.fid)
		reply^ = vectra9.error_reply(vectra9.EPERM)

	case vectra9.Tclunk:
		_ = vfs.fidtab_release(&d.fids, m.fid)
		reply^ = vectra9.Rclunk{}

	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

// read answers a Tread: the fid is looked up under the lock and the text is
// made after it is dropped, on this thread's own stack.
@(private = "file")
read :: proc(m: vectra9.Tread, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	d := &dev
	g := sync.acquire(&d.lock)
	node := vfs.fidtab_node(&d.fids, m.fid)
	open := node >= 0 && vfs.fidtab_is_open(&d.fids, m.fid)
	sync.release(&d.lock, g)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if !open {
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return
	}
	pid, f := split(node)
	if f == .Dir {
		reply^ = vectra9.error_reply(vectra9.EISDIR)
		return
	}
	text: [2048]u8
	n := render(pid, f, text[:])
	if n < 0 {
		reply^ = vectra9.error_reply(vectra9.ESRCH)
		return
	}
	if m.offset >= u64(n) {
		reply^ = vectra9.Rread{data = nil}
		return
	}
	start := int(m.offset)
	end := min(n, start + min(len(buf), int(m.count)))
	copy(buf[:end - start], text[start:end])
	reply^ = vectra9.Rread{data = buf[:end - start]}
}

// render writes a file's text into `out` and answers its length, or -1 for
// a pid that is gone.
@(private = "file")
render :: proc(pid: u64, f: File, out: []u8) -> int {
	info, ok := user.proc_info(pid)
	if !ok {
		return -1
	}
	switch f {
	case .Status:
		sink := libodin.sink_from(out)
		libodin.put_str(&sink, info.name)
		libodin.put_str(&sink, " ")
		libodin.put_uint(&sink, info.pid)
		libodin.put_str(&sink, " ")
		libodin.put_uint(&sink, info.parent)
		libodin.put_str(&sink, " ")
		libodin.put_str(&sink, info.state)
		libodin.put_str(&sink, " ")
		libodin.put_uint(&sink, info.note_group)
		libodin.put_str(&sink, info.detached ? " detached " : " held ")
		libodin.put_str(&sink, info.cwd)
		libodin.put_str(&sink, "\n")
		return len(libodin.str(&sink))
	case .Ns:
		return user.proc_namespace(pid, out)
	case .Note, .Ctl, .Dir:
		return 0
	}
	return 0
}

@(private = "file")
trim_newline :: proc "contextless" (s: string) -> string {
	if len(s) > 0 && s[len(s) - 1] == '\n' {
		return s[:len(s) - 1]
	}
	return s
}

// walk resolves names: from the root a pid, from a pid directory one of
// the four file names. `..` from anywhere below the root is the root or
// the pid directory.
@(private = "file")
walk :: proc(m: vectra9.Twalk, reply: ^vectra9.Msg) #no_bounds_check {
	d := &dev
	node := vfs.fidtab_node(&d.fids, m.fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if vfs.fidtab_is_open(&d.fids, m.fid) {
		reply^ = vectra9.error_reply(vectra9.EBUSY)
		return
	}
	answer: vectra9.Rwalk
	cur := node
	for i in 0 ..< m.count {
		next := step(cur, m.names[i])
		if next < 0 {
			if i == 0 {
				reply^ = vectra9.error_reply(vectra9.ENOENT)
				return
			}
			break
		}
		cur = next
		answer.qids[answer.count] = qid_of(cur)
		answer.count += 1
	}
	if answer.count == m.count {
		if !vfs.fidtab_bind(&d.fids, m.newfid, cur) {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
	}
	reply^ = answer
}

@(private = "file")
step :: proc(from: i32, name: string) -> i32 {
	pid, f := split(from)
	switch name {
	case ".":
		return from
	case "..":
		return from == ROOT || f == .Dir ? ROOT : node_of(pid, .Dir)
	}
	if from == ROOT {
		v, ok := parse_pid(name)
		if !ok || v >= 1 << PID_BITS {
			return -1
		}
		if _, live := user.proc_info(v); !live {
			return -1
		}
		return node_of(v, .Dir)
	}
	if f != .Dir {
		return -1
	}
	for kind in File {
		if kind != .Dir && FILE_NAMES[kind] == name {
			return node_of(pid, kind)
		}
	}
	return -1
}

@(private = "file")
parse_pid :: proc "contextless" (s: string) -> (v: u64, ok: bool) {
	if len(s) == 0 || len(s) > 18 {
		return 0, false
	}
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		v = v * 10 + u64(s[i] - '0')
	}
	return v, true
}

// readdir lists the root's pids, cookie the pid, or a pid directory's four
// files, cookie the ordinal.
@(private = "file")
readdir :: proc(m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	d := &dev
	node := vfs.fidtab_node(&d.fids, m.fid)
	if node < 0 {
		reply^ = vectra9.error_reply(vectra9.EBADF)
		return
	}
	if !vfs.fidtab_is_open(&d.fids, m.fid) {
		reply^ = vectra9.error_reply(vectra9.EINVAL)
		return
	}
	pid, f := split(node)
	if f != .Dir {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	if node == ROOT {
		after := m.offset
		for {
			next := user.proc_after(after)
			if next == 0 || next >= 1 << PID_BITS {
				break
			}
			digits: [24]u8
			sink := libodin.sink_from(digits[:])
			libodin.put_uint(&sink, next)
			name := libodin.str(&sink)
			if vectra9.remaining(&c) < vectra9.dirent_size(name) {
				break
			}
			vectra9.put_dirent(
				&c,
				vectra9.Dirent{qid = qid_of(node_of(next, .Dir)), offset = next, type = vectra9.DT_DIR, name = name},
			)
			after = next
		}
	} else {
		if _, ok := user.proc_info(pid); !ok {
			reply^ = vectra9.error_reply(vectra9.ESRCH)
			return
		}
		for i := int(m.offset) + 1; i <= int(File.Ctl); i += 1 {
			kind := File(i)
			name := FILE_NAMES[kind]
			if vectra9.remaining(&c) < vectra9.dirent_size(name) {
				break
			}
			vectra9.put_dirent(
				&c,
				vectra9.Dirent{qid = qid_of(node_of(pid, kind)), offset = u64(i), type = vectra9.DT_REG, name = name},
			)
		}
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
