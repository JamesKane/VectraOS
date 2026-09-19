/*
libmsg -- a message is a directory, and a network is a directory of them.

`docs/WEB.md` section 4. Every network in that document serves one shape,
`upas/fs`'s, so a program that reads one reads all of them. A network
server is a translator: it turns bytes from the wire into a record, and
this library serves the record as the tree below on `sys/lib9p`. A server
is then its wire, its record, and nothing about 9P.

    ctl                 verbs the server takes: `fetch`, `login`, `follow`
    me                  who this person is here
    new                 write a message: header lines, an empty line, the body
    event               a read that parks, and answers `conv/id` when one lands
    dict                the vocabulary, `docs/GHOST.md` section 5's contract
    notify/             what came back, a conversation like the others
    <conv>/             a conversation: a mailbox, a room, a timeline, a feed
    <conv>/<id>/from    the author, as the network names them
    <conv>/<id>/date    seconds since the epoch, a space, the network's text
    <conv>/<id>/subject a title, or empty
    <conv>/<id>/body    the text
    <conv>/<id>/type    the body's media type
    <conv>/<id>/raw     what the network sent
    <conv>/<id>/hash    sha256 of `raw`, its name in the store
    <conv>/<id>/replyto the id this answers, or empty
    <conv>/<id>/replies/ what answered it, one level down
    <conv>/<id>/links   what the message points at, one per line
    <dir>/<name>/<file> a tree beside the conversations: `contacts/`,
                        one directory an address, its files name, key
                        and verified

An id sorts by time: the date in sixteen hex digits, a dot, and the
network's own id, so a listing is in order without sorting anything. A
network id that would not be a file name, or is longer than a name should
be, is replaced by sixteen hex digits of its sha256. `make_id` does that.

The server fills a `Net`: its conversations, `me`, `dict`, and two
callbacks. `on_ctl` takes a line written to `ctl` and answers an errno, zero
for done. `on_new` takes a message written to `new`, and a network that
cannot honour it answers `EPERM`. `add` puts a message into a conversation
in order and reports it on `event`. The callbacks may hold the request
(`lib9p.hold`) and answer it later from another thread, the way a fetch
that waits on the wire must.

Not yet: a message's parts (`<id>/N/`), which mail brings.
*/
package libmsg

import "core:crypto/hash"
import "vsys:lib9p"
import "vsys:libuser"
import "vsys:vectra9"

FRAME :: 8192 + 512

// What a write to `ctl` or `new` does. Zero for done, or an errno. The
// text is the write as written, its newline still on, so a callback that
// holds answers `Rwrite` with the whole count. A callback that must wait
// calls `lib9p.hold(&net.srv)` and answers later through
// `lib9p.find_held_tag(&net.srv, tag)`; what it returns is then ignored.
Ctl_Fn :: #type proc(net: ^Net, tag: vectra9.Tag, line: string) -> vectra9.Errno
New_Fn :: #type proc(net: ^Net, tag: vectra9.Tag, text: string) -> vectra9.Errno

MAX_EVENTS :: 256

// A tree beside the conversations: a directory of directories of files,
// the way `contacts/<address>/{name,key,verified}` is. Read only.
Xfile :: struct {
	name: string,
	text: string, // Owned
}

Xsub :: struct {
	name:  string,
	files: [dynamic]Xfile,
}

Xdir :: struct {
	name: string,
	subs: [dynamic]Xsub,
}

MAX_XFILES :: 8

Net :: struct {
	convs:  [dynamic]Conv, // `notify` is the first
	extras: [dynamic]Xdir, // The trees beside them
	me:     string,
	dict:   string,
	status: string, // What a read of `ctl` answers
	on_ctl: Ctl_Fn,
	on_new: New_Fn,

	// The library's.
	srv:    lib9p.Srv,
	fids:   libuser.Fid_Table,
	events: [MAX_EVENTS]string, // `conv/id` lines waiting for a reader of event
	ehead:  int,
	ecount: int,
	eopens: int,
}

// -- The network ----------------------------------------------------------------

// init makes a network with its `notify` conversation and nothing else.
init :: proc(net: ^Net) {
	net.convs = make([dynamic]Conv, 0, 8)
	net.extras = make([dynamic]Xdir, 0, 2)
	_ = conv(net, "notify")
}

// extra answers the tree called `name` beside the conversations, made if
// it was not there.
extra :: proc(net: ^Net, name: string) -> ^Xdir {
	for &x in net.extras {
		if x.name == name {
			return &x
		}
	}
	own := make([]u8, len(name))
	copy(own, name)
	append(&net.extras, Xdir{name = string(own), subs = make([dynamic]Xsub, 0, 8)})
	return &net.extras[len(net.extras) - 1]
}

// xsub answers the directory called `name` in a tree, made if it was not.
xsub :: proc(x: ^Xdir, name: string) -> ^Xsub {
	for &d in x.subs {
		if d.name == name {
			return &d
		}
	}
	own := make([]u8, len(name))
	copy(own, name)
	append(&x.subs, Xsub{name = string(own), files = make([dynamic]Xfile, 0, MAX_XFILES)})
	return &x.subs[len(x.subs) - 1]
}

// xset sets a file's text in a directory, its own copy, replacing what
// the file held.
xset :: proc(d: ^Xsub, name: string, text: string) {
	own := make([]u8, len(text))
	copy(own, text)
	for &f in d.files {
		if f.name == name {
			delete(f.text)
			f.text = string(own)
			return
		}
	}
	if len(d.files) >= MAX_XFILES {
		delete(own)
		return
	}
	nm := make([]u8, len(name))
	copy(nm, name)
	append(&d.files, Xfile{name = string(nm), text = string(own)})
}

// xget answers a file's text in a directory, or false.
xget :: proc "contextless" (d: ^Xsub, name: string) -> (string, bool) {
	for f in d.files {
		if f.name == name {
			return f.text, true
		}
	}
	return "", false
}

// xfind answers the directory called `name` in a tree, or nil.
xfind :: proc "contextless" (x: ^Xdir, name: string) -> ^Xsub {
	for &d in x.subs {
		if d.name == name {
			return &d
		}
	}
	return nil
}

// conv answers the conversation called `name`, made if it was not there.
conv :: proc(net: ^Net, name: string) -> ^Conv {
	for &c in net.convs {
		if c.name == name {
			return &c
		}
	}
	own := make([]u8, len(name))
	copy(own, name)
	append(&net.convs, Conv{name = string(own), msgs = make([dynamic]Msg, 0, 16)})
	return &net.convs[len(net.convs) - 1]
}

conv_index :: proc "contextless" (net: ^Net, name: string) -> int {
	for c, i in net.convs {
		if c.name == name {
			return i
		}
	}
	return -1
}

/*
add puts `m` into `c` at its place in id order, replacing a message with
the same id, and reports it on `event`. The message's hash is taken here
from its raw text, so a translator need not know sha256.
*/
add :: proc(net: ^Net, c: ^Conv, m: Msg) {
	m := m
	digest: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)m.raw, digest[:])
	hex_of(digest[:], m.hash[:])
	at := len(c.msgs)
	for i in 0 ..< len(c.msgs) {
		if c.msgs[i].id == m.id {
			msg_free(&c.msgs[i])
			c.msgs[i] = m
			return
		}
		if c.msgs[i].id > m.id {
			at = i
			break
		}
	}
	inject_at(&c.msgs, at, m)
	event(net, c.name, m.id)
}

// -- Events ---------------------------------------------------------------------

// event queues a `conv/id` line for a reader of `event`, and answers a
// read parked on it. When nobody reads, the oldest lines go.
event :: proc(net: ^Net, conv_name: string, id: string) {
	line := make([]u8, len(conv_name) + 1 + len(id) + 1)
	n := copy(line, conv_name)
	line[n] = '/'
	n += 1
	n += copy(line[n:], id)
	line[n] = '\n'
	if net.ecount == MAX_EVENTS {
		delete(net.events[net.ehead])
		net.ehead = (net.ehead + 1) % MAX_EVENTS
		net.ecount -= 1
	}
	net.events[(net.ehead + net.ecount) % MAX_EVENTS] = string(line)
	net.ecount += 1
	answer_events(net)
}

@(private = "file")
answer_events :: proc(net: ^Net) {
	for net.ecount > 0 {
		req, ok := lib9p.held(&net.srv, net, wants_event)
		if !ok {
			return
		}
		m := req.msg.(vectra9.Tread)
		room := min(len(req.payload), int(m.count))
		_ = lib9p.respond(req, vectra9.Rread{data = pop_event(net, req.payload[:room])})
	}
}

@(private = "file")
pop_event :: proc(net: ^Net, into: []u8) -> []u8 {
	line := net.events[net.ehead]
	net.events[net.ehead] = ""
	net.ehead = (net.ehead + 1) % MAX_EVENTS
	net.ecount -= 1
	n := copy(into, line)
	delete(line)
	return into[:n]
}

@(private = "file")
wants_event :: proc "contextless" (arg: rawptr, request: ^vectra9.Msg) -> bool {
	net := (^Net)(arg)
	#partial switch m in request^ {
	case vectra9.Tread:
		return kind_of(libuser.fid_lookup(&net.fids, m.fid)) == .Event
	}
	return false
}

// -- Serving --------------------------------------------------------------------

/*
serve posts `srv_name` and answers the tree until the pipe ends or a
remove is answered. It returns why, for the server to exit with. The
server calls it from its main thread, after `init` and its own setup.
*/
serve :: proc(net: ^Net, srv_name: string) -> lib9p.Serve_End {
	serving = net
	fd, perr := libuser.post(srv_name)
	if perr < 0 {
		return .Broken
	}
	net.srv = lib9p.Srv {
		fd      = fd,
		handler = handler,
		state   = net,
		msize   = FRAME,
	}
	_, why := lib9p.serve(&net.srv)
	lib9p.respond_all(&net.srv, vectra9.Rread{data = nil})
	return why
}

/*
A node is one number: five bits of what it is, fifteen of which message,
and eleven of which conversation, the conversation and the message each
one more than their index so zero means none.
*/
Kind :: enum u8 {
	Root,
	Ctl,
	Me,
	New,
	Event,
	Dict,
	Conv,
	Msg,
	From,
	Date,
	Subject,
	Body,
	Type,
	Raw,
	Hash,
	Replyto,
	Replies,
	Links,
	Xdir, // A tree beside the conversations: its index in the conv field
	Xsub, // A directory in it: the sub's index in the msg field's low twelve bits
	Xfile, // A file in that: the file's index in the msg field's high three
}

MSG_FILES := [?]Kind{.From, .Date, .Subject, .Body, .Type, .Raw, .Hash, .Replyto, .Replies, .Links}
MSG_NAMES := [?]string{"from", "date", "subject", "body", "type", "raw", "hash", "replyto", "replies", "links"}
ROOT_FILES := [?]string{"ctl", "me", "new", "event", "dict"}

// The network being served. One a process, since `step` walks it for the
// library's fid table and takes no argument of its own.
@(private = "file")
serving: ^Net

node_of :: proc "contextless" (kind: Kind, ci: int, mi: int) -> i32 {
	return i32(kind) | i32(mi + 1) << 5 | i32(ci + 1) << 20
}

kind_of :: proc "contextless" (node: i32) -> Kind {
	if node < 0 {
		return .Root
	}
	return Kind(node & 31)
}

conv_of :: proc "contextless" (node: i32) -> int {
	return int(node >> 20) - 1
}

msg_of :: proc "contextless" (node: i32) -> int {
	return int((node >> 5) & 0x7FFF) - 1
}

is_dir :: proc "contextless" (kind: Kind) -> bool {
	return kind == .Root || kind == .Conv || kind == .Msg || kind == .Replies || kind == .Xdir || kind == .Xsub
}

// An extra tree's node: the sub's index in the low twelve bits of the msg
// field and the file's index above them.
xnode :: proc "contextless" (kind: Kind, xi: int, si: int, fi: int) -> i32 {
	return node_of(kind, xi, si | fi << 12)
}

xsub_of :: proc "contextless" (node: i32) -> int {
	return msg_of(node) & 0xFFF
}

xfile_of :: proc "contextless" (node: i32) -> int {
	return msg_of(node) >> 12
}

@(private = "file")
handler :: proc "contextless" (
	state: rawptr,
	s: ^vectra9.Session,
	tag: vectra9.Tag,
	request: ^vectra9.Msg,
	reply: ^vectra9.Msg,
	buf: []u8,
) #no_bounds_check {
	_ = s
	context = libuser.heap_context()
	net := (^Net)(state)

	if !libuser.default_reply(request, reply) {
		return
	}

	#partial switch m in request^ {
	case vectra9.Tversion:
		vectra9.version_reply(m, reply, FRAME)

	case vectra9.Tattach:
		libuser.attach(&net.fids, m, reply, node_of(.Root, -1, -1), qid_of)

	case vectra9.Twalk:
		libuser.walk(&net.fids, m, reply, step, qid_of)

	case vectra9.Tlopen:
		node, ok := libuser.node_of(&net.fids, m.fid, reply)
		if !ok {
			return
		}
		if kind_of(node) == .Event {
			net.eopens += 1
		}
		libuser.fid_open(&net.fids, m.fid)
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}

	case vectra9.Tread:
		node, ok := libuser.open_node(&net.fids, m.fid, reply)
		if !ok {
			return
		}
		room := min(len(buf), int(m.count))
		kind := kind_of(node)
		if is_dir(kind) {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		if kind == .Event {
			if net.ecount == 0 {
				lib9p.hold(&net.srv)
				return
			}
			reply^ = vectra9.Rread{data = pop_event(net, buf[:room])}
			return
		}
		text, found := text_of(net, node)
		if !found {
			reply^ = vectra9.error_reply(vectra9.ENOENT)
			return
		}
		reply^ = vectra9.Rread{data = slice_window(text, m.offset, buf[:room])}

	case vectra9.Twrite:
		node, ok := libuser.open_node(&net.fids, m.fid, reply)
		if !ok {
			return
		}
		#partial switch kind_of(node) {
		case .Ctl:
			if net.on_ctl == nil {
				reply^ = vectra9.error_reply(vectra9.EPERM)
				return
			}
			err := net.on_ctl(net, tag, string(m.data))
			if err != 0 {
				reply^ = vectra9.error_reply(err)
				return
			}
			reply^ = vectra9.Rwrite{count = u32(len(m.data))}
		case .New:
			if net.on_new == nil {
				reply^ = vectra9.error_reply(vectra9.EPERM)
				return
			}
			err := net.on_new(net, tag, string(m.data))
			if err != 0 {
				reply^ = vectra9.error_reply(err)
				return
			}
			reply^ = vectra9.Rwrite{count = u32(len(m.data))}
		case:
			reply^ = vectra9.error_reply(vectra9.EPERM)
		}

	case vectra9.Treaddir:
		readdir(net, m, reply, buf)

	case vectra9.Tgetattr:
		node, ok := libuser.node_of(&net.fids, m.fid, reply)
		if !ok {
			return
		}
		kind := kind_of(node)
		dir := is_dir(kind)
		size := u64(0)
		if !dir {
			if text, found := text_of(net, node); found {
				size = u64(len(text))
			}
		}
		mode := u32(0o100444)
		if dir {
			mode = 0o040555
		} else if kind == .Ctl || kind == .New {
			mode = 0o100666
		}
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = mode,
			nlink   = dir ? 2 : 1,
			size    = size,
			blksize = 512,
		}

	case vectra9.Tclunk:
		node := libuser.fid_lookup(&net.fids, m.fid)
		if libuser.fid_is_open(&net.fids, m.fid) && kind_of(node) == .Event && net.eopens > 0 {
			net.eopens -= 1
		}
		libuser.fid_release(&net.fids, m.fid)
		reply^ = vectra9.Rclunk{}

	case vectra9.Tremove:
		libuser.fid_release(&net.fids, m.fid)
		reply^ = vectra9.Rremove{}

	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

// text_of answers the bytes a file holds, and whether the node names one.
@(private = "file")
text_of :: proc(net: ^Net, node: i32) -> (text: []u8, found: bool) {
	kind := kind_of(node)
	switch kind {
	case .Ctl:
		return transmute([]u8)net.status, true
	case .Me:
		return transmute([]u8)net.me, true
	case .New:
		return nil, true
	case .Dict:
		return transmute([]u8)net.dict, true
	case .Root, .Conv, .Msg, .Replies, .Event, .Xdir, .Xsub:
		return nil, false
	case .Xfile:
		xi, si, fi := conv_of(node), xsub_of(node), xfile_of(node)
		if xi < 0 || xi >= len(net.extras) || si < 0 || si >= len(net.extras[xi].subs) || fi < 0 || fi >= len(net.extras[xi].subs[si].files) {
			return nil, false
		}
		return transmute([]u8)net.extras[xi].subs[si].files[fi].text, true
	case .From, .Date, .Subject, .Body, .Type, .Raw, .Hash, .Replyto, .Links:
		ci, mi := conv_of(node), msg_of(node)
		if ci < 0 || ci >= len(net.convs) || mi < 0 || mi >= len(net.convs[ci].msgs) {
			return nil, false
		}
		m := &net.convs[ci].msgs[mi]
		#partial switch kind {
		case .From:
			return line_of(net, m.from), true
		case .Date:
			return date_line(net, m), true
		case .Subject:
			return line_of(net, m.subject), true
		case .Body:
			return transmute([]u8)m.body, true
		case .Type:
			return line_of(net, m.type), true
		case .Raw:
			return transmute([]u8)m.raw, true
		case .Hash:
			return line_of(net, string(m.hash[:])), true
		case .Replyto:
			return line_of(net, m.replyto), true
		case .Links:
			return transmute([]u8)m.links, true
		}
	}
	return nil, false
}

// A one-line file ends in a newline, so `cat` leaves the prompt where it
// should be. The line is built in a buffer the handler owns for one reply.
@(private = "file")
line_buf: [4096]u8

@(private = "file")
line_of :: proc "contextless" (net: ^Net, s: string) -> []u8 {
	_ = net
	if len(s) == 0 {
		return nil
	}
	n := copy(line_buf[:len(line_buf) - 1], s)
	line_buf[n] = '\n'
	return line_buf[:n + 1]
}

@(private = "file")
date_line :: proc "contextless" (net: ^Net, m: ^Msg) -> []u8 {
	_ = net
	n := put_int(line_buf[:], m.date)
	if len(m.date_text) > 0 {
		line_buf[n] = ' '
		n += 1
		n += copy(line_buf[n:len(line_buf) - 1], m.date_text)
	}
	line_buf[n] = '\n'
	return line_buf[:n + 1]
}

@(private = "file")
qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if is_dir(kind_of(node)) {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

// step walks one name from a node. The network is the walk's context,
// since the library's walk takes a bare step.
@(private = "file")
step :: proc "contextless" (from: i32, name: string) -> i32 {
	net := serving
	if name == "." {
		return from
	}
	kind := kind_of(from)
	ci, mi := conv_of(from), msg_of(from)
	if name == ".." {
		#partial switch kind {
		case .Root, .Conv, .Xdir:
			return node_of(.Root, -1, -1)
		case .Msg:
			return node_of(.Conv, ci, -1)
		case .Replies:
			return node_of(.Msg, ci, mi)
		case .Xsub:
			return node_of(.Xdir, ci, -1)
		}
		return -1
	}
	#partial switch kind {
	case .Root:
		for n, i in ROOT_FILES {
			if n == name {
				return node_of(Kind(int(Kind.Ctl) + i), -1, -1)
			}
		}
		if i := conv_index(net, name); i >= 0 {
			return node_of(.Conv, i, -1)
		}
		for x, i in net.extras {
			if x.name == name {
				return node_of(.Xdir, i, -1)
			}
		}
	case .Xdir:
		if ci < 0 || ci >= len(net.extras) {
			return -1
		}
		for d, i in net.extras[ci].subs {
			if d.name == name {
				return xnode(.Xsub, ci, i, 0)
			}
		}
	case .Xsub:
		si := xsub_of(from)
		if ci < 0 || ci >= len(net.extras) || si < 0 || si >= len(net.extras[ci].subs) {
			return -1
		}
		for f, i in net.extras[ci].subs[si].files {
			if f.name == name {
				return xnode(.Xfile, ci, si, i)
			}
		}
	case .Conv:
		if ci < 0 || ci >= len(net.convs) {
			return -1
		}
		if i := find(&net.convs[ci], name); i >= 0 {
			return node_of(.Msg, ci, i)
		}
	case .Msg:
		for n, i in MSG_NAMES {
			if n == name {
				return node_of(MSG_FILES[i], ci, mi)
			}
		}
	case .Replies:
		// A reply is a message of the same conversation that answers this one.
		if ci < 0 || ci >= len(net.convs) || mi < 0 || mi >= len(net.convs[ci].msgs) {
			return -1
		}
		c := &net.convs[ci]
		if i := find(c, name); i >= 0 && c.msgs[i].replyto == c.msgs[mi].id {
			return node_of(.Msg, ci, i)
		}
	}
	return -1
}

@(private = "file")
readdir :: proc(net: ^Net, m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	node, ok := libuser.open_node(&net.fids, m.fid, reply)
	if !ok {
		return
	}
	kind := kind_of(node)
	if !is_dir(kind) {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	ci, mi := conv_of(node), msg_of(node)
	// Entries are numbered from one, and a listing resumes at the number
	// after the last one answered.
	i := int(m.offset)
	#partial switch kind {
	case .Root:
		for i < len(ROOT_FILES) + len(net.convs) + len(net.extras) {
			e: vectra9.Dirent
			if i < len(ROOT_FILES) {
				e = vectra9.Dirent{qid = qid_of(node_of(Kind(int(Kind.Ctl) + i), -1, -1)), type = vectra9.DT_REG, name = ROOT_FILES[i]}
			} else if i < len(ROOT_FILES) + len(net.convs) {
				k := i - len(ROOT_FILES)
				e = vectra9.Dirent{qid = qid_of(node_of(.Conv, k, -1)), type = vectra9.DT_DIR, name = net.convs[k].name}
			} else {
				k := i - len(ROOT_FILES) - len(net.convs)
				e = vectra9.Dirent{qid = qid_of(node_of(.Xdir, k, -1)), type = vectra9.DT_DIR, name = net.extras[k].name}
			}
			if !put(&c, e, i) {
				break
			}
			i += 1
		}
	case .Xdir:
		if ci < 0 || ci >= len(net.extras) {
			break
		}
		x := &net.extras[ci]
		for i < len(x.subs) {
			e := vectra9.Dirent{qid = qid_of(xnode(.Xsub, ci, i, 0)), type = vectra9.DT_DIR, name = x.subs[i].name}
			if !put(&c, e, i) {
				break
			}
			i += 1
		}
	case .Xsub:
		si := xsub_of(node)
		if ci < 0 || ci >= len(net.extras) || si < 0 || si >= len(net.extras[ci].subs) {
			break
		}
		d := &net.extras[ci].subs[si]
		for i < len(d.files) {
			e := vectra9.Dirent{qid = qid_of(xnode(.Xfile, ci, si, i)), type = vectra9.DT_REG, name = d.files[i].name}
			if !put(&c, e, i) {
				break
			}
			i += 1
		}
	case .Conv:
		if ci < 0 || ci >= len(net.convs) {
			break
		}
		conv := &net.convs[ci]
		for i < len(conv.msgs) {
			e := vectra9.Dirent{qid = qid_of(node_of(.Msg, ci, i)), type = vectra9.DT_DIR, name = conv.msgs[i].id}
			if !put(&c, e, i) {
				break
			}
			i += 1
		}
	case .Msg:
		for i < len(MSG_NAMES) {
			t := vectra9.DT_REG
			if MSG_FILES[i] == .Replies {
				t = vectra9.DT_DIR
			}
			e := vectra9.Dirent{qid = qid_of(node_of(MSG_FILES[i], ci, mi)), type = t, name = MSG_NAMES[i]}
			if !put(&c, e, i) {
				break
			}
			i += 1
		}
	case .Replies:
		if ci < 0 || ci >= len(net.convs) || mi < 0 || mi >= len(net.convs[ci].msgs) {
			break
		}
		conv := &net.convs[ci]
		for i < len(conv.msgs) {
			if conv.msgs[i].replyto == conv.msgs[mi].id {
				e := vectra9.Dirent{qid = qid_of(node_of(.Msg, ci, i)), type = vectra9.DT_DIR, name = conv.msgs[i].id}
				if !put(&c, e, i) {
					break
				}
			}
			i += 1
		}
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}

@(private = "file")
put :: proc "contextless" (c: ^vectra9.Cursor, e: vectra9.Dirent, i: int) -> bool {
	if vectra9.remaining(c) < vectra9.dirent_size(e.name) {
		return false
	}
	e := e
	e.offset = u64(i + 1)
	vectra9.put_dirent(c, e)
	return true
}

@(private = "file")
slice_window :: proc "contextless" (data: []u8, offset: u64, into: []u8) -> []u8 {
	if offset >= u64(len(data)) {
		return nil
	}
	n := copy(into, data[offset:])
	return into[:n]
}

@(private = "file")
inject_at :: proc(msgs: ^[dynamic]Msg, at: int, m: Msg) {
	append(msgs, Msg{})
	for i := len(msgs) - 1; i > at; i -= 1 {
		msgs[i] = msgs[i - 1]
	}
	msgs[at] = m
}

