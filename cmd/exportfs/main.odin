/*
exportfs -- serve this namespace as 9P on a stream.

    exportfs [-r path]

Answers 9P on descriptor zero, which is the stream `listen` hands a service:
the far end of a TCP conversation, dialled by another machine's `srv` or
`import`. Every request becomes the call a program makes on its own files. A
walk is `stat`, a read is `pread`, a directory read is `read_dir` and a
`stat` per name, a create is `create`. What it exports is what its own
namespace holds from `-r path` down, the root by default, so a `bind` before
it starts decides what a client sees. That is the whole access model, and it
is Plan 9's. `docs/FLEET.md` section 5.

A fid is a path and, once opened, a descriptor. The table is small and
fixed, the way every table a client can grow is here. Reads and writes are
answered on the serve loop's own thread, so a read that parks in this
namespace parks the loop; a flush that reaches it then waits behind the read.
Answering those from threads of their own is the step after this one.
*/
package exportfs

import "base:runtime"

import "vsys:abi"
import "vsys:lib9p"
import "vsys:libauth"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

MAX_FIDS :: 64
PATH_MAX :: 256
FRAME :: vectra9.MSIZE_DEFAULT

Fid :: struct {
	used:   bool,
	fid:    vectra9.Fid,
	fd:     int, // Open descriptor, or -1
	is_dir: bool,
	plen:   int,
	path:   [PATH_MAX]u8,
}

fids: [MAX_FIDS]Fid

// The descriptor 9P is served on: the stream, or the sealed one over it.
serve_fd: int = 0

// Who the handshake proved the client to be, when there was one.
proven: [64]u8
proven_len: int
srv: lib9p.Srv
root: string = "/"
root_buf: [PATH_MAX]u8

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = {}
	#force_no_inline runtime._startup_runtime()
	args := libuser.args(block)
	auth := false
	for i := 1; i < len(args); i += 1 {
		if args[i] == "-r" && i + 1 < len(args) {
			i += 1
			n := copy(root_buf[:], args[i])
			root = string(root_buf[:n])
		} else if args[i] == "-a" {
			auth = true
		}
	}
	if auth {
		// The handshake first, on the raw stream, as this host. A client
		// whose key the keys file does not list is `none`, and the tree is
		// not for `none`: it is refused before 9P begins.
		who: [128]u8
		host, dom, ok := libauth.whoami(who[:])
		if !ok {
			libuser.exits("no host user in the environment")
		}
		sess, done := libauth.auth_server(0, host, dom)
		if !done {
			libuser.exits("the handshake failed")
		}
		if libauth.session_name(&sess) == libauth.NONE {
			_ = libuser.close(sess.fd)
			libuser.exits("a stranger, refused")
		}
		proven_len = copy(proven[:], libauth.session_name(&sess))
		serve_fd = sess.fd
	} else {
		proven_len = copy(proven[:], libauth.NONE)
	}
	become(string(proven[:proven_len]))
	for i in 0 ..< MAX_FIDS {
		fids[i].fd = -1
	}
	libthread.main(threadmain, nil)
}

threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	srv = lib9p.Srv {
		fd      = serve_fd,
		handler = handler,
		msize   = FRAME,
	}
	_, why := lib9p.serve(&srv)
	lib9p.respond_all(&srv, vectra9.Rread{data = nil})
	// A stream that ended is the client hanging up, which is the usual end.
	// A frame that would not decode is worth a word on descriptor 2, which
	// is wherever `listen` was started from.
	if why == .Broken {
		text := "exportfs: a frame did not decode, or was larger than the msize\n"
		_ = libuser.write(2, transmute([]u8)text)
	}
	libthread.threadexitsall(why == .Broken ? "broken" : "")
}

// -- The fid table --------------------------------------------------------------

fid_find :: proc "contextless" (fid: vectra9.Fid) -> ^Fid #no_bounds_check {
	for i in 0 ..< MAX_FIDS {
		if fids[i].used && fids[i].fid == fid {
			return &fids[i]
		}
	}
	return nil
}

fid_new :: proc "contextless" (fid: vectra9.Fid) -> ^Fid #no_bounds_check {
	if fid_find(fid) != nil {
		return nil
	}
	for i in 0 ..< MAX_FIDS {
		if !fids[i].used {
			f := &fids[i]
			f^ = Fid{used = true, fid = fid, fd = -1}
			return f
		}
	}
	return nil
}

fid_drop :: proc "contextless" (f: ^Fid) {
	if f.fd >= 0 {
		_ = libuser.close(f.fd)
	}
	f^ = Fid{fd = -1}
}

path_of :: proc "contextless" (f: ^Fid) -> string {
	return string(f.path[:f.plen])
}

set_path :: proc "contextless" (f: ^Fid, p: string) -> bool {
	if len(p) > PATH_MAX {
		return false
	}
	f.plen = copy(f.path[:], p)
	return true
}

/*
child answers `dir/name` in `into`. `..` goes up one element and never above
the exported root, which is what keeps a client inside what was exported.
`.` is the directory itself.
*/
child :: proc "contextless" (dir: string, name: string, into: []u8) -> (string, bool) #no_bounds_check {
	if name == "." {
		n := copy(into, dir)
		return string(into[:n]), true
	}
	if name == ".." {
		if len(dir) <= len(root) {
			n := copy(into, dir)
			return string(into[:n]), true
		}
		cut := len(dir)
		for cut > 0 && dir[cut - 1] != '/' {
			cut -= 1
		}
		if cut > 1 {
			cut -= 1
		}
		n := copy(into, dir[:cut])
		return string(into[:n]), true
	}
	for i in 0 ..< len(name) {
		if name[i] == '/' {
			return "", false
		}
	}
	n := len(dir) + len(name) + 1
	if n > len(into) {
		return "", false
	}
	at := copy(into, dir)
	if at == 0 || into[at - 1] != '/' {
		into[at] = '/'
		at += 1
	}
	at += copy(into[at:], name)
	return string(into[:at]), true
}

// -- Stat, as 9P wants it -----------------------------------------------------

qid_of :: proc "contextless" (st: ^abi.Stat) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if st.qid_kind & abi.QTDIR != 0 {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = st.qid_path, version = st.qid_version}
}

is_dir :: proc "contextless" (st: ^abi.Stat) -> bool {
	return st.qid_kind & abi.QTDIR != 0
}

getattr_of :: proc "contextless" (st: ^abi.Stat, mask: u64) -> vectra9.Rgetattr {
	dir := is_dir(st)
	mode := st.mode & 0o777
	mode |= dir ? 0o040000 : 0o100000
	return vectra9.Rgetattr {
		valid   = mask & 0x000007FF,
		qid     = qid_of(st),
		mode    = mode,
		nlink   = dir ? 2 : 1,
		size    = st.length,
		blksize = 4096,
		atime_sec = st.atime,
		mtime_sec = st.mtime,
	}
}

// -- The handler ----------------------------------------------------------------

handler :: proc "contextless" (
	state: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = state
	_ = s
	_ = tag
	reply^ = vectra9.error_reply(vectra9.EOPNOTSUPP)

	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply, FRAME)

	case vectra9.Tattach:
		f := fid_new(m.fid)
		if f == nil {
			reply^ = vectra9.error_reply(vectra9.ENFILE)
			return
		}
		st: abi.Stat
		if !set_path(f, root) || libuser.stat(root, &st) < 0 {
			fid_drop(f)
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		f.is_dir = is_dir(&st)
		reply^ = vectra9.Rattach{qid = qid_of(&st)}

	case vectra9.Twalk:
		f := fid_find(m.fid)
		if f == nil || f.fd >= 0 {
			reply^ = vectra9.error_reply(f == nil ? vectra9.EBADF : vectra9.EBUSY)
			return
		}
		scratch: [PATH_MAX]u8
		cur := path_of(f)
		curbuf: [PATH_MAX]u8
		cn := copy(curbuf[:], cur)
		cur = string(curbuf[:cn])
		answer: vectra9.Rwalk
		last: abi.Stat
		if libuser.stat(cur, &last) < 0 {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		for i in 0 ..< m.count {
			next, ok := child(cur, m.names[i], scratch[:])
			st: abi.Stat
			if !ok || libuser.stat(next, &st) < 0 {
				if i == 0 {
					reply^ = vectra9.error_reply(vectra9.ENOENT)
					return
				}
				break
			}
			cn = copy(curbuf[:], next)
			cur = string(curbuf[:cn])
			last = st
			answer.qids[answer.count] = qid_of(&st)
			answer.count += 1
		}
		if answer.count == m.count {
			target := f
			if m.newfid != m.fid {
				target = fid_new(m.newfid)
				if target == nil {
					reply^ = vectra9.error_reply(vectra9.ENFILE)
					return
				}
			}
			_ = set_path(target, cur)
			target.is_dir = is_dir(&last)
		}
		reply^ = answer

	case vectra9.Tlopen:
		f := fid_find(m.fid)
		if f == nil {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		st: abi.Stat
		if libuser.stat(path_of(f), &st) < 0 {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		if !is_dir(&st) {
			fd := libuser.open(path_of(f), u64(m.flags) & 0o3)
			if fd < 0 {
				reply^ = vectra9.error_reply(vectra9.Errno(-fd))
				return
			}
			f.fd = int(fd)
		} else if m.flags & 0o3 != 0 {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		f.is_dir = is_dir(&st)
		reply^ = vectra9.Rlopen{qid = qid_of(&st), iounit = 0}

	case vectra9.Tlcreate:
		f := fid_find(m.fid)
		if f == nil {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		scratch: [PATH_MAX]u8
		next, ok := child(path_of(f), m.name, scratch[:])
		if !ok {
			reply^ = vectra9.error_reply(vectra9.EINVAL)
			return
		}
		fd := libuser.create(next, u64(m.flags) & 0o3, u64(m.mode) & 0o777)
		if fd < 0 {
			reply^ = vectra9.error_reply(vectra9.Errno(-fd))
			return
		}
		st: abi.Stat
		if libuser.stat(next, &st) < 0 {
			_ = libuser.close(int(fd))
			reply^ = vectra9.error_reply(vectra9.EIO)
			return
		}
		_ = set_path(f, next)
		f.fd = int(fd)
		f.is_dir = false
		reply^ = vectra9.Rlcreate{qid = qid_of(&st), iounit = 0}

	case vectra9.Tmkdir:
		f := fid_find(m.dfid)
		if f == nil {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		scratch: [PATH_MAX]u8
		next, ok := child(path_of(f), m.name, scratch[:])
		if !ok {
			reply^ = vectra9.error_reply(vectra9.EINVAL)
			return
		}
		fd := libuser.mkdir(next, u64(m.mode) & 0o777)
		if fd < 0 {
			reply^ = vectra9.error_reply(vectra9.Errno(-fd))
			return
		}
		_ = libuser.close(int(fd))
		st: abi.Stat
		_ = libuser.stat(next, &st)
		reply^ = vectra9.Rmkdir{qid = qid_of(&st)}

	case vectra9.Tread:
		f := fid_find(m.fid)
		if f == nil || f.fd < 0 {
			reply^ = vectra9.error_reply(f == nil ? vectra9.EBADF : vectra9.EINVAL)
			return
		}
		room := min(len(buf), int(m.count))
		n := libuser.pread(f.fd, buf[:room], m.offset)
		if n < 0 {
			reply^ = vectra9.error_reply(vectra9.Errno(-n))
			return
		}
		reply^ = vectra9.Rread{data = buf[:int(n)]}

	case vectra9.Twrite:
		f := fid_find(m.fid)
		if f == nil || f.fd < 0 {
			reply^ = vectra9.error_reply(f == nil ? vectra9.EBADF : vectra9.EINVAL)
			return
		}
		n := libuser.pwrite(f.fd, m.data, m.offset)
		if n < 0 {
			reply^ = vectra9.error_reply(vectra9.Errno(-n))
			return
		}
		reply^ = vectra9.Rwrite{count = u32(n)}

	case vectra9.Treaddir:
		readdir(m, reply, buf)

	case vectra9.Tgetattr:
		f := fid_find(m.fid)
		if f == nil {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		st: abi.Stat
		if libuser.stat(path_of(f), &st) < 0 {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		reply^ = getattr_of(&st, m.request_mask)

	case vectra9.Tunlinkat:
		f := fid_find(m.dirfid)
		if f == nil {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		scratch: [PATH_MAX]u8
		next, ok := child(path_of(f), m.name, scratch[:])
		if !ok {
			reply^ = vectra9.error_reply(vectra9.EINVAL)
			return
		}
		if r := libuser.remove(next); r < 0 {
			reply^ = vectra9.error_reply(vectra9.Errno(-r))
			return
		}
		reply^ = vectra9.Runlinkat{}

	case vectra9.Tremove:
		f := fid_find(m.fid)
		if f == nil {
			reply^ = vectra9.error_reply(vectra9.EBADF)
			return
		}
		r := libuser.remove(path_of(f))
		fid_drop(f)
		if r < 0 {
			reply^ = vectra9.error_reply(vectra9.Errno(-r))
			return
		}
		reply^ = vectra9.Rremove{}

	case vectra9.Tclunk:
		if f := fid_find(m.fid); f != nil {
			fid_drop(f)
		}
		reply^ = vectra9.Rclunk{}

	case vectra9.Tstatfs:
		reply^ = vectra9.Rstatfs{type = 0x6578_706F, bsize = 4096, namelen = abi.NAME_MAX}

	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

/*
readdir lists a directory a page at a time. The offset counts entries, so a
client that comes back with the offset it was given goes on from there. Each
name is stat'd for its qid and kind, which is what a listing carries.
*/
readdir :: proc "contextless" (m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	f := fid_find(m.fid)
	if f == nil || !f.is_dir {
		reply^ = vectra9.error_reply(f == nil ? vectra9.EBADF : vectra9.ENOTDIR)
		return
	}
	context = libuser.heap_context()
	names, ok := libuser.read_dir(path_of(f), context.allocator)
	if !ok {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	defer {
		for name in names {
			delete(name)
		}
		delete(names)
	}
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	scratch: [PATH_MAX]u8
	for i := int(m.offset); i < len(names); i += 1 {
		if vectra9.remaining(&c) < vectra9.dirent_size(names[i]) {
			break
		}
		next, cok := child(path_of(f), names[i], scratch[:])
		st: abi.Stat
		if !cok || libuser.stat(next, &st) < 0 {
			continue
		}
		t := is_dir(&st) ? vectra9.DT_DIR : vectra9.DT_REG
		vectra9.put_dirent(&c, vectra9.Dirent{qid = qid_of(&st), offset = u64(i + 1), type = t, name = names[i]})
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}

/*
become makes this process the user the handshake proved -- or `none` when
there was no handshake -- and attaches the writable tree again as that user.
`/usr` was mounted by the kernel at boot as the host; a fid from that attach
answers for the host, not the client. A fresh mount from this process, now
the client's, carries the client's name in Tattach, and every open the tree
checks is checked against it. That is what makes a private file refuse. A
process of the host owner's may make the `user` write; anything else stays
who it is, which the far side then sees in its own status line.
*/
become :: proc "contextless" (name: string) {
	path: [48]u8
	pid := libuser.getpid()
	ctl := libuser.open(libuser.cat_into(path[:], "/proc/", pidtext(pid), "/ctl"), abi.O_WRONLY)
	if ctl < 0 {
		libuser.exits("cannot open my own ctl")
	}
	line: [64]u8
	text := libuser.cat_into(line[:], "user ", name)
	wrote := libuser.write(int(ctl), transmute([]u8)text)
	_ = libuser.close(int(ctl))
	// A server that cannot be the client it proved must not serve as the
	// host instead. The write is refused only to a process that is not the
	// host owner's, which is `init` having failed to name the host -- worth
	// a word rather than a tree quietly served as the wrong user.
	if wrote != i64(len(text)) {
		msg := "exportfs: cannot become the client: this process is not the host owner's\n"
		_ = libuser.write(2, transmute([]u8)msg)
		libuser.exits("become")
	}

	// Attach the writable tree afresh, now as this user. The kernel mounted
	// `/srv/kfs` at `/usr` at boot as the host, and a fid from that attach
	// answers for the host whoever walks it -- so an open exportfs makes on
	// behalf of a client is checked against the host, not the client. A
	// replace here mounts it again from this process, whose user is now the
	// one the handshake proved, so kfs's Tattach carries that name and every
	// open is checked against it. That is what makes a private file refuse
	// across the wire. This process's namespace only; nothing else's `/usr`
	// moves. A machine with no `/srv/kfs` serves what it has.
	_ = libuser.mount("/srv/kfs", "/usr", abi.ORDER_REPLACE)
}

@(private = "file")
pid_buf: [24]u8

@(private = "file")
pidtext :: proc "contextless" (pid: u64) -> string {
	n := 0
	v := pid
	tmp: [24]u8
	if v == 0 {
		tmp[n] = '0'
		n += 1
	}
	for v > 0 {
		tmp[n] = u8('0' + v % 10)
		n += 1
		v /= 10
	}
	for i in 0 ..< n {
		pid_buf[i] = tmp[n - 1 - i]
	}
	return string(pid_buf[:n])
}
