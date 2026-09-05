/*
dns -- `/net/dns`: write a name, read its address.

    write  fs.example.com
    read   fs.example.com ip 10.0.0.2

A resolver at a router does the walking; this asks it. The server to ask is
what `ipconfig` learned, the `dns=` in `/net/ndb`, or failing that the
`dns=` on the gateway's record in `/lib/ndb/local`. The asking is one
datagram each way on a conversation of `/net/udp`, `sys/libnet`'s question
and answer, and an alarm to break a read nobody answers.

The file is a message file, the way `/net/cs` is: a write asks the question
and keeps the answer against the fid that asked, and a read takes the answer
whole and forgets it. A name the resolver does not know fails the write. A
small cache answers a name asked twice without asking again, since `cs` asks
here for every dial of a name.

`docs/FLEET.md` section 3 gives this its place beside `cs`, both clients of
`libndb` and of `/net/udp` and nothing else.
*/
package dns

import "base:runtime"

import "vsys:abi"
import "vsys:lib9p"
import "vsys:libndb"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

NODE_ROOT :: i32(0)
NODE_DNS :: i32(1)
FRAME :: 1200

// How long one answer is waited for, in the kernel's millisecond ticks, and
// how many times a question is asked before the name is given up on.
WAIT :: 2000
TRIES :: 2

SLOTS :: 8
NAME_MAX :: 200
TEXT_MAX :: 256

// An answer waiting for the fid that asked for it.
Slot :: struct {
	used: bool,
	fid:  vectra9.Fid,
	len:  int,
	text: [TEXT_MAX]u8,
}

slots: [SLOTS]Slot

CACHE :: 8

Entry :: struct {
	used:     bool,
	name_len: int,
	name:     [NAME_MAX]u8,
	ip:       libnet.IP,
}

cache: [CACHE]Entry
cache_next: int

fids: libuser.Fid_Table
srv: lib9p.Srv
query_id: u16 = 0x3000

// The two databases the server to ask is read from, at each question, since
// `ipconfig` may have written one since the last.
ndb_text: [4096]u8

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	_ = block
	context = {}
	#force_no_inline runtime._startup_runtime()
	libthread.main(threadmain, nil)
}

threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	fd, perr := libuser.post("/srv/dns")
	if perr < 0 {
		libthread.threadexitsall("post")
	}
	if libuser.notify(uintptr(rawptr(on_note))) != 0 {
		libthread.threadexitsall("notify")
	}
	srv = lib9p.Srv {
		fd      = fd,
		handler = handler,
		msize   = FRAME,
	}
	_, why := lib9p.serve(&srv)
	lib9p.respond_all(&srv, vectra9.Rread{data = nil})
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

// on_note is where the alarm lands. The read it interrupted has already
// answered, so there is nothing to do but carry on.
on_note :: proc "c" (ureg: rawptr, note: cstring) {
	_ = ureg
	_ = note
	libuser.noted(abi.NCONT)
}

// -- Resolving ------------------------------------------------------------------

/*
server_address is the resolver to ask: what `ipconfig` wrote to `/net/ndb`,
or the gateway record's `dns=` in `/lib/ndb/local`.
*/
server_address :: proc "contextless" () -> (libnet.IP, bool) {
	for path in ([?]string{"/net/ndb", "/lib/ndb/local"}) {
		fd := libuser.open(path, abi.O_RDONLY)
		if fd < 0 {
			continue
		}
		at := 0
		for at < len(ndb_text) {
			n := libuser.read(int(fd), ndb_text[at:])
			if n <= 0 {
				break
			}
			at += int(n)
		}
		_ = libuser.close(int(fd))
		text := string(ndb_text[:at])
		if v, has := libndb.find(text, "sys", "gw", "dns"); has {
			if ip, ok := address(v); ok {
				return ip, true
			}
		}
		// The note ipconfig leaves is one line with no `sys=`, so its
		// `dns=` is found by hand.
		if ip, ok := attr_ip(text, "dns="); ok {
			return ip, true
		}
	}
	return {}, false
}

// attr_ip finds `key` in a text and reads the address after it.
attr_ip :: proc "contextless" (text: string, key: string) -> (libnet.IP, bool) #no_bounds_check {
	for i := 0; i + len(key) <= len(text); i += 1 {
		if text[i:i + len(key)] == key {
			end := i + len(key)
			for end < len(text) && text[end] != ' ' && text[end] != '\n' && text[end] != '\t' {
				end += 1
			}
			return address(text[i + len(key):end])
		}
	}
	return {}, false
}

/*
resolve answers the address for `name`: from the cache, or by asking the
resolver. A question is asked `TRIES` times, each waiting `WAIT` ticks, and
a reply for another question is passed over.
*/
resolve :: proc "contextless" (name: string) -> (libnet.IP, bool) {
	if ip, hit := cache_lookup(name); hit {
		return ip, true
	}
	server, has := server_address()
	if !has {
		return {}, false
	}
	// Dialled by address, past `cs`: `cs` is what asks here, and a server
	// cannot ask the one that is waiting on it.
	addr: [64]u8
	sink := libodin.sink_from(addr[:])
	put_ip(&sink, server)
	libodin.put_str(&sink, "!53")
	dir: [64]u8
	fd, dirlen, ok := libnet.dial_addr("/net/udp/clone", libodin.str(&sink), dir[:])
	if !ok {
		return {}, false
	}
	defer {
		_ = libuser.close(fd)
		libnet.hangup(string(dir[:dirlen]))
	}

	query: [libnet.DNS_MAX]u8
	reply: [libnet.DNS_MAX]u8
	for _ in 0 ..< TRIES {
		query_id += 1
		id := query_id
		n := libnet.put_dns_query(query[:], id, name)
		if n == 0 {
			return {}, false
		}
		if libuser.write(fd, query[:n]) != i64(n) {
			return {}, false
		}
		_ = libuser.alarm(WAIT)
		for {
			got := libuser.read(fd, reply[:])
			if got <= 0 {
				break
			}
			if ip, found := libnet.parse_dns(reply[:got], id, name); found {
				_ = libuser.alarm(0)
				cache_put(name, ip)
				return ip, true
			}
		}
		_ = libuser.alarm(0)
	}
	return {}, false
}

cache_lookup :: proc "contextless" (name: string) -> (libnet.IP, bool) #no_bounds_check {
	for i in 0 ..< CACHE {
		e := &cache[i]
		if e.used && libnet.names_equal(e.name[:e.name_len], transmute([]u8)name) {
			return e.ip, true
		}
	}
	return {}, false
}

cache_put :: proc "contextless" (name: string, ip: libnet.IP) #no_bounds_check {
	if len(name) > NAME_MAX {
		return
	}
	e := &cache[cache_next]
	cache_next = (cache_next + 1) % CACHE
	e.used = true
	e.name_len = len(name)
	copy(e.name[:], name)
	e.ip = ip
}

// -- The file -----------------------------------------------------------------

/*
ask takes one question written to the file: a name, and a type after it that
may only be `ip`. The answer is kept for the fid. False is a name that will
not resolve, which fails the write.
*/
ask :: proc "contextless" (fid: vectra9.Fid, text: string) -> bool #no_bounds_check {
	q := text
	for len(q) > 0 && (q[len(q) - 1] == '\n' || q[len(q) - 1] == '\r' || q[len(q) - 1] == ' ') {
		q = q[:len(q) - 1]
	}
	name := q
	kind := "ip"
	for i in 0 ..< len(q) {
		if q[i] == ' ' {
			name = q[:i]
			kind = q[i + 1:]
			break
		}
	}
	if len(name) == 0 || len(name) > NAME_MAX || kind != "ip" {
		return false
	}
	ip, ok := resolve(name)
	if !ok {
		return false
	}
	slot := slot_for(fid)
	if slot < 0 {
		return false
	}
	e := &slots[slot]
	sink := libodin.sink_from(e.text[:])
	libodin.put_str(&sink, name)
	libodin.put_str(&sink, " ip ")
	put_ip(&sink, ip)
	libodin.put_str(&sink, "\n")
	e.used = true
	e.fid = fid
	e.len = len(libodin.str(&sink))
	return true
}

// answer takes the fid's answer, whole, and forgets it.
answer :: proc "contextless" (fid: vectra9.Fid) -> string #no_bounds_check {
	for i in 0 ..< SLOTS {
		e := &slots[i]
		if e.used && e.fid == fid {
			e.used = false
			return string(e.text[:e.len])
		}
	}
	return ""
}

forget :: proc "contextless" (fid: vectra9.Fid) #no_bounds_check {
	for i in 0 ..< SLOTS {
		if slots[i].used && slots[i].fid == fid {
			slots[i].used = false
		}
	}
}

slot_for :: proc "contextless" (fid: vectra9.Fid) -> int #no_bounds_check {
	for i in 0 ..< SLOTS {
		if slots[i].used && slots[i].fid == fid {
			return i
		}
	}
	for i in 0 ..< SLOTS {
		if !slots[i].used {
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
	case "dns":
		if from == NODE_ROOT {
			return NODE_DNS
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
		if node != NODE_DNS {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		// The answer, whole, whatever the offset: the write that asked moved
		// it, and this is a reply rather than a window on bytes.
		text := answer(m.fid)
		room := min(min(len(buf), int(m.count)), len(text))
		copy(buf[:room], text[:room])
		reply^ = vectra9.Rread{data = buf[:room]}
	case vectra9.Twrite:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		if node != NODE_DNS {
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		if !ask(m.fid, string(m.data)) {
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
		forget(m.fid)
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
	if m.offset < 1 && vectra9.remaining(&c) >= vectra9.dirent_size("dns") {
		vectra9.put_dirent(&c, vectra9.Dirent{qid = qid_of(NODE_DNS), offset = 1, type = vectra9.DT_REG, name = "dns"})
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}

// -- Text ----------------------------------------------------------------------

put_ip :: proc "contextless" (sink: ^libodin.Sink, ip: libnet.IP) {
	for i in 0 ..< 4 {
		if i > 0 {
			libodin.put_str(sink, ".")
		}
		libodin.put_uint(sink, u64(ip[i]))
	}
}

// address reads `a.b.c.d`.
address :: proc "contextless" (s: string) -> (ip: libnet.IP, ok: bool) #no_bounds_check {
	at := 0
	for i in 0 ..< 4 {
		v := 0
		digits := 0
		for at < len(s) && s[at] >= '0' && s[at] <= '9' {
			v = v * 10 + int(s[at] - '0')
			at += 1
			digits += 1
		}
		if digits == 0 || v > 255 {
			return {}, false
		}
		ip[i] = u8(v)
		if i < 3 {
			if at >= len(s) || s[at] != '.' {
				return {}, false
			}
			at += 1
		}
	}
	return ip, true
}
