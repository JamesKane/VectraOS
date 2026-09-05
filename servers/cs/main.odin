/*
cs -- `/net/cs`, the name a dial string carries turned into an address.

A program writes a dial string and reads back what to open:

    write  tcp!fs!9fs
    read   /net/tcp/clone 10.0.2.15!564

That is the whole of the connection server. The names come from
`/lib/ndb/local`, which `sys/libndb` reads: `sys=fs` answers an `ip`, and
`tcp=9fs` answers a `port`. A host the database does not name is asked of
`/net/dns`, which asks the network. A part that is already a number is used as
it stands, so `tcp!10.0.2.15!9` needs no database at all, and `*` is this
machine, read from `/net/local`.

**A server of its own, mounted after `netfs` at `/net`.** It began inside
`netfs`, where a name was only ever the database's. A name the network must
answer is a question to another process, and a server cannot ask one from
inside its own serve loop while the asker waits on it. So this asks from a
process of its own, and `netfs` serves everything else.

**A translation belongs to the fid that asked for it.** Two programs dialling
at once must not read each other's answer. The write remembers what it worked
out against the fid it came in on, and the read answers that.
*/
package cs

import "base:runtime"

import "vsys:abi"
import "vsys:lib9p"
import "vsys:libndb"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

NODE_ROOT :: i32(0)
NODE_CS :: i32(1)
FRAME :: 1200

CS_SLOTS :: 8
CS_TEXT :: 96

Cs_Slot :: struct {
	used: bool,
	fid:  vectra9.Fid,
	len:  int,
	text: [CS_TEXT]u8,
}

cs_slots: [CS_SLOTS]Cs_Slot

// The database, read once at start. A machine with no file has an empty one,
// and every name then has to be a number or the network's.
NDB_MAX :: 4096
ndb_text: [NDB_MAX]u8
ndb_len: int

fids: libuser.Fid_Table
srv: lib9p.Srv

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = {}
	#force_no_inline runtime._startup_runtime()
	libthread.main(threadmain, nil)
}

threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	fd, perr := libuser.post("/srv/cs")
	if perr < 0 {
		libthread.threadexitsall("post")
	}
	ndb_load()
	srv = lib9p.Srv {
		fd      = fd,
		handler = handler,
		msize   = FRAME,
	}
	_, why := lib9p.serve(&srv)
	lib9p.respond_all(&srv, vectra9.Rread{data = nil})
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

// ndb_load reads `/lib/ndb/local` into memory, once, before serving.
ndb_load :: proc "contextless" () {
	fd := libuser.open("/lib/ndb/local", abi.O_RDONLY)
	if fd < 0 {
		return
	}
	at := 0
	for at < NDB_MAX {
		n := libuser.read(int(fd), ndb_text[at:])
		if n <= 0 {
			break
		}
		at += int(n)
	}
	_ = libuser.close(int(fd))
	ndb_len = at
}

ndb :: proc "contextless" () -> string #no_bounds_check {
	return string(ndb_text[:ndb_len])
}

// -- The translation ----------------------------------------------------------

// numeric reports whether every byte is a digit. That is what makes a part of a
// dial string an address or a port rather than a name.
numeric :: proc "contextless" (s: string) -> bool #no_bounds_check {
	if len(s) == 0 {
		return false
	}
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return true
}

// dotted reports whether a part looks like an address rather than a name.
dotted :: proc "contextless" (s: string) -> bool #no_bounds_check {
	dots := 0
	for i in 0 ..< len(s) {
		if s[i] == '.' {
			dots += 1
		} else if s[i] < '0' || s[i] > '9' {
			return false
		}
	}
	return dots == 3
}

// cut splits `s` at the first `!`, which is what separates a dial string's
// three parts.
cut :: proc "contextless" (s: string) -> (head: string, rest: string, ok: bool) #no_bounds_check {
	for i in 0 ..< len(s) {
		if s[i] == '!' {
			return s[:i], s[i + 1:], true
		}
	}
	return s, "", false
}

/*
host_address answers the address for `host`: this machine's own for `*`, the
database's when it has one, and the network's through `/net/dns` otherwise.
The text lands in `into`.
*/
host_address :: proc "contextless" (host: string, into: []u8) -> (string, bool) #no_bounds_check {
	if host == "*" {
		n := read_file("/net/local", into)
		if n <= 0 {
			return "", false
		}
		text := string(into[:n])
		for len(text) > 0 && (text[len(text) - 1] == '\n' || text[len(text) - 1] == '\r') {
			text = text[:len(text) - 1]
		}
		return text, true
	}
	if found, has := libndb.find(ndb(), "sys", host, "ip"); has {
		return found, true
	}
	// The network's answer: `name ip a.b.c.d`, of which the address is
	// wanted.
	fd := libuser.open("/net/dns", abi.O_RDWR)
	if fd < 0 {
		return "", false
	}
	defer libuser.close(int(fd))
	if libuser.write(int(fd), transmute([]u8)host) != i64(len(host)) {
		return "", false
	}
	n := libuser.read(int(fd), into)
	if n <= 0 {
		return "", false
	}
	line := string(into[:n])
	// `name ip addr`: the address is the third word.
	words := 0
	at := 0
	for at < len(line) {
		for at < len(line) && line[at] == ' ' {at += 1}
		w0 := at
		for at < len(line) && line[at] != ' ' && line[at] != '\n' {at += 1}
		words += 1
		if words == 3 {
			return line[w0:at], true
		}
	}
	return "", false
}

/*
cs_translate turns `proto!host!service` into the line a caller opens: the
protocol's clone file, and the far end to connect to. A host that is already an
address and a service that is already a number are used as they stand.
Anything else is a question for the database or the network, and a name
neither knows is a failure.
*/
cs_translate :: proc "contextless" (query: string, into: []u8) -> int #no_bounds_check {
	// Trim the newline a shell or a program leaves on the end.
	q := query
	for len(q) > 0 && (q[len(q) - 1] == '\n' || q[len(q) - 1] == '\r') {
		q = q[:len(q) - 1]
	}

	proto, rest, ok := cut(q)
	if !ok {
		return 0
	}
	if proto != "tcp" && proto != "udp" && proto != "icmp" {
		return 0
	}
	host, service, ok2 := cut(rest)
	if !ok2 {
		return 0
	}

	addr: [64]u8
	ip := host
	if !dotted(host) {
		found, has := host_address(host, addr[:])
		if !has {
			return 0
		}
		ip = found
	}

	port := service
	if !numeric(service) {
		found, has := libndb.find(ndb(), proto, service, "port")
		if !has {
			return 0
		}
		port = found
	}

	sink := libodin.sink_from(into)
	libodin.put_str(&sink, "/net/")
	libodin.put_str(&sink, proto)
	libodin.put_str(&sink, "/clone ")
	libodin.put_str(&sink, ip)
	libodin.put_str(&sink, "!")
	libodin.put_str(&sink, port)
	libodin.put_str(&sink, "\n")
	return len(libodin.str(&sink))
}

read_file :: proc "contextless" (path: string, into: []u8) -> int {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return -1
	}
	n := libuser.read(int(fd), into)
	_ = libuser.close(int(fd))
	return int(n)
}

// -- The answer, per fid ------------------------------------------------------

// cs_write works out a translation and remembers it for the fid that asked.
cs_write :: proc "contextless" (fid: vectra9.Fid, query: string) -> bool #no_bounds_check {
	scratch: [CS_TEXT]u8
	n := cs_translate(query, scratch[:])
	if n == 0 {
		return false
	}
	slot := cs_slot(fid)
	if slot < 0 {
		return false
	}
	e := &cs_slots[slot]
	e.used = true
	e.fid = fid
	e.len = n
	copy(e.text[:], scratch[:n])
	return true
}

/*
cs_read answers what this fid's write worked out, and forgets it. A second read
then answers nothing, and a caller sees the end of the answers.

**The offset is ignored, on purpose.** A caller writes the dial string and then
reads, on one descriptor, so the write has already moved the offset past where
the answer begins. This is a file whose read is a reply rather than a window on
bytes, as Plan 9's `cs` is. The reply is taken whole.
*/
cs_read :: proc "contextless" (fid: vectra9.Fid) -> string #no_bounds_check {
	for i in 0 ..< CS_SLOTS {
		e := &cs_slots[i]
		if e.used && e.fid == fid {
			e.used = false
			return string(e.text[:e.len])
		}
	}
	return ""
}

// cs_forget drops a fid's answer, which a clunk does.
cs_forget :: proc "contextless" (fid: vectra9.Fid) #no_bounds_check {
	for i in 0 ..< CS_SLOTS {
		if cs_slots[i].used && cs_slots[i].fid == fid {
			cs_slots[i].used = false
		}
	}
}

// cs_slot finds this fid's slot, or a free one.
cs_slot :: proc "contextless" (fid: vectra9.Fid) -> int #no_bounds_check {
	for i in 0 ..< CS_SLOTS {
		if cs_slots[i].used && cs_slots[i].fid == fid {
			return i
		}
	}
	for i in 0 ..< CS_SLOTS {
		if !cs_slots[i].used {
			return i
		}
	}
	return -1
}

// -- 9P ------------------------------------------------------------------------

is_dir :: proc "contextless" (node: i32) -> bool {
	return node == NODE_ROOT
}

qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if is_dir(node) {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

step :: proc "contextless" (from: i32, name: string) -> i32 {
	switch name {
	case ".", "..":
		return NODE_ROOT
	case "cs":
		if from == NODE_ROOT {
			return NODE_CS
		}
	}
	return -1
}

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
	if !libuser.default_reply(request, reply) {
		return
	}
	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply, FRAME)
	case vectra9.Tattach:
		libuser.attach(&fids, m, reply, NODE_ROOT, qid_of)
	case vectra9.Twalk:
		libuser.walk(&fids, m, reply, step, qid_of)
	case vectra9.Tlopen:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		libuser.fid_open(&fids, m.fid)
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}
	case vectra9.Tread:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		if node != NODE_CS {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		text := cs_read(m.fid)
		room := min(min(len(buf), int(m.count)), len(text))
		copy(buf[:room], text[:room])
		reply^ = vectra9.Rread{data = buf[:room]}
	case vectra9.Twrite:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		if node != NODE_CS {
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		if !cs_write(m.fid, string(m.data)) {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		reply^ = vectra9.Rwrite{count = u32(len(m.data))}
	case vectra9.Treaddir:
		readdir(m, reply, buf)
	case vectra9.Tgetattr:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		dir := is_dir(node)
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = dir ? 0o040555 : 0o100666,
			nlink   = dir ? 2 : 1,
			blksize = 512,
		}
	case vectra9.Tclunk:
		cs_forget(m.fid)
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rclunk{}
	case vectra9.Tremove:
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rremove{}
	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

readdir :: proc "contextless" (m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	node, ok := libuser.open_node(&fids, m.fid, reply)
	if !ok {
		return
	}
	if !is_dir(node) {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	if m.offset < 1 && vectra9.remaining(&c) >= vectra9.dirent_size("cs") {
		vectra9.put_dirent(&c, vectra9.Dirent{qid = qid_of(NODE_CS), offset = 1, type = vectra9.DT_REG, name = "cs"})
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
