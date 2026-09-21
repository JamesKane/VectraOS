/*
modelfs -- a directory a model answers from, `docs/GHOST.md` section 3.
A client writes a request in the Messages API's JSON and reads the reply
as the API's stream events, one event a read. A backend is behind the
files, and a client cannot tell which. This is the stub backend,
`modelfs -e SCRIPT`: it answers from a file of canned replies, so every
check in `docs/GHOST.md` runs with no model on the disk. The local
engine, `sys/libinfer`, is a backend that speaks these same files and
is a manual check until it lands.

    /mnt/model/ctl          the models offered, one a line
    /mnt/model/new          read it for a session number
    /mnt/model/N/ctl        write: model <name>; hangup
    /mnt/model/N/request    write the request, the Messages API's JSON
    /mnt/model/N/reply      a read that parks, and answers one stream
                            event a read, ending at the stream's end
    /mnt/model/N/usage      tokens in, tokens out, cache reads, the cost

The stub's script is replies, each a run of event lines, one JSON
object a line, a reply ended by a line of `==`. A `#` line is a comment.
Each request written takes the next reply, cycling, so a multi-turn
loop is scripted turn by turn.
*/
package modelfs

import "base:runtime"
import "vsys:abi"
import "vsys:lib9p"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

FRAME :: 16384 + 512
MAX_SESSIONS :: 8
NAME_MAX :: 64

// The node numbers, webfs's scheme: the low bits the kind, the high the
// session, one more than its index so zero is none.
NODE_ROOT :: i32(0)
NODE_CTL :: i32(1) // The root's ctl: the models offered
NODE_NEW :: i32(2)
SESS_BASE :: i32(8)
SESS_STRIDE :: i32(8)
SESS_DIR :: i32(0)
SESS_CTL :: i32(1)
SESS_REQUEST :: i32(2)
SESS_REPLY :: i32(3)
SESS_USAGE :: i32(4)

Session :: struct {
	used:      bool,
	model:     [NAME_MAX]u8,
	mlen:      int,
	request:   [dynamic]u8,
	events:    [dynamic]string, // The reply's events, owned, one a read
	epos:      int, // The next event a read of `reply` answers
	streaming: bool, // A request has been written; events are loaded
	in_toks:   int,
	out_toks:  int,
}

sessions: [MAX_SESSIONS]Session

// The stub's replies: each a run of event JSON lines. `cursor` is the
// next reply a request takes, cycling.
replies: [dynamic][dynamic]string
cursor: int

srv: lib9p.Srv
fids: libuser.Fid_Table
g_script: string

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = {}
	#force_no_inline runtime._startup_runtime()
	args := libuser.args(block)
	for i := 1; i + 1 < len(args); i += 1 {
		if args[i] == "-e" {
			g_script = args[i + 1]
		}
	}
	libthread.main(threadmain, nil)
}

threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = libuser.heap_context()
	replies = make([dynamic][dynamic]string, 0, 8)
	if g_script != "" {
		load_script(g_script)
	}
	fd, perr := libuser.post("/srv/model")
	if perr < 0 {
		libthread.threadexitsall("post")
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

// load_script reads the stub's replies out of `path`: event lines split
// into replies by a line of `==`.
load_script :: proc(path: string) {
	data, ok := libuser.read_file(path, context.allocator)
	if !ok {
		return
	}
	defer delete(data)
	current := make([dynamic]string, 0, 8)
	at := 0
	s := string(data)
	for at <= len(s) {
		e := at
		for e < len(s) && s[e] != '\n' {
			e += 1
		}
		line := s[at:e]
		at = e + 1
		if len(line) > 0 && line[0] == '#' {
			continue
		}
		if line == "==" {
			append(&replies, current)
			current = make([dynamic]string, 0, 8)
			continue
		}
		if len(line) == 0 {
			continue
		}
		own := make([]u8, len(line))
		copy(own, line)
		append(&current, string(own))
	}
	if len(current) > 0 {
		append(&replies, current)
	} else {
		delete(current)
	}
}

// -- The session --------------------------------------------------------------

sess_alloc :: proc() -> int {
	for i in 0 ..< MAX_SESSIONS {
		if !sessions[i].used {
			sessions[i] = Session{used = true}
			sessions[i].request = make([dynamic]u8, 0, 1024)
			sessions[i].events = make([dynamic]string, 0, 8)
			sessions[i].mlen = copy(sessions[i].model[:], "stub")
			return i
		}
	}
	return -1
}

sess_free :: proc(i: int) {
	s := &sessions[i]
	delete(s.request)
	for ev in s.events {
		delete(ev)
	}
	delete(s.events)
	s^ = Session{}
}

// take_request loads the next stub reply into the session's events and
// counts the tokens, a word each side. It answers the reply reads parked
// on this session.
take_request :: proc(i: int) {
	s := &sessions[i]
	for ev in s.events {
		delete(ev)
	}
	clear(&s.events)
	s.epos = 0
	if len(replies) > 0 {
		reply := replies[cursor % len(replies)]
		cursor += 1
		for ev in reply {
			own := make([]u8, len(ev))
			copy(own, ev)
			append(&s.events, string(own))
		}
	}
	s.in_toks += count_words(string(s.request[:]))
	s.out_toks += len(s.events)
	s.streaming = true
	answer_reply_reads(i)
}

count_words :: proc "contextless" (s: string) -> int {
	n := 0
	in_word := false
	for i in 0 ..< len(s) {
		if s[i] == ' ' || s[i] == '\n' || s[i] == '\t' {
			in_word = false
		} else if !in_word {
			in_word = true
			n += 1
		}
	}
	return n
}

// -- Serving ------------------------------------------------------------------

node_of :: proc "contextless" (kind: i32, sess: int) -> i32 {
	if sess < 0 {
		return kind
	}
	return SESS_BASE + i32(sess) * SESS_STRIDE + kind
}

kind_of :: proc "contextless" (node: i32) -> i32 {
	if node < SESS_BASE {
		return node
	}
	return (node - SESS_BASE) % SESS_STRIDE
}

sess_of :: proc "contextless" (node: i32) -> int {
	if node < SESS_BASE {
		return -1
	}
	return int((node - SESS_BASE) / SESS_STRIDE)
}

is_dir :: proc "contextless" (node: i32) -> bool {
	return node == NODE_ROOT || (node >= SESS_BASE && kind_of(node) == SESS_DIR)
}

qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if is_dir(node) {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

SESS_FILES := [?]struct {
	name: string,
	kind: i32,
}{{"ctl", SESS_CTL}, {"request", SESS_REQUEST}, {"reply", SESS_REPLY}, {"usage", SESS_USAGE}}

ROOT_FILES := [?]struct {
	name: string,
	node: i32,
}{{"ctl", NODE_CTL}, {"new", NODE_NEW}}

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
	_ = tag
	context = libuser.heap_context()
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
		room := min(len(buf), int(m.count))
		if is_dir(node) {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		read_file(node, m.offset, buf[:room], reply)
	case vectra9.Twrite:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		write_file(node, m.data, reply)
	case vectra9.Treaddir:
		readdir(m, reply, buf)
	case vectra9.Tgetattr:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		dir := is_dir(node)
		mode := u32(0o100444)
		if dir {
			mode = 0o040555
		} else {
			k := kind_of(node)
			if k == NODE_NEW || k == NODE_CTL || k == SESS_CTL || k == SESS_REQUEST {
				mode = 0o100666
			}
		}
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = mode,
			nlink   = dir ? 2 : 1,
			blksize = 512,
		}
	case vectra9.Tclunk:
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rclunk{}
	case vectra9.Tremove:
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rremove{}
	case vectra9.Tflush:
		reply^ = vectra9.Rflush{}
	}
}

// read_file answers a file's bytes. `reply` on a session parks until the
// request is written and an event is ready.
read_file :: proc "contextless" (node: i32, offset: u64, into: []u8, reply: ^vectra9.Msg) {
	context = libuser.heap_context()
	k := kind_of(node)
	si := sess_of(node)
	switch {
	case node == NODE_NEW:
		if offset > 0 {
			reply^ = vectra9.Rread{data = nil}
			return
		}
		i := sess_alloc()
		if i < 0 {
			reply^ = vectra9.error_reply(vectra9.ENOSPC)
			return
		}
		reply^ = vectra9.Rread{data = slice_window(transmute([]u8)num_line(i), offset, into)}
	case node == NODE_CTL:
		reply^ = vectra9.Rread{data = slice_window(models_line(), offset, into)}
	case k == SESS_USAGE && si >= 0 && si < MAX_SESSIONS && sessions[si].used:
		reply^ = vectra9.Rread{data = slice_window(usage_line(si), offset, into)}
	case k == SESS_REPLY && si >= 0 && si < MAX_SESSIONS && sessions[si].used:
		s := &sessions[si]
		if s.epos < len(s.events) {
			// A stream: the next event whole, the byte offset ignored.
			ev := s.events[s.epos]
			s.epos += 1
			reply^ = vectra9.Rread{data = event_into(ev, into)}
			return
		}
		if s.streaming {
			// The stream ended: EOF, so a reader's loop stops.
			reply^ = vectra9.Rread{data = nil}
			return
		}
		// No request yet: hold until one is written.
		lib9p.hold(&srv)
	case:
		reply^ = vectra9.Rread{data = nil}
	}
}

// write_file takes a write to `ctl`, `request` or a session's `ctl`.
write_file :: proc "contextless" (node: i32, data: []u8, reply: ^vectra9.Msg) {
	context = libuser.heap_context()
	k := kind_of(node)
	si := sess_of(node)
	switch {
	case node == NODE_CTL:
		reply^ = vectra9.error_reply(vectra9.EPERM)
	case k == SESS_CTL && si >= 0 && si < MAX_SESSIONS && sessions[si].used:
		line := libodin.trim_space(string(data))
		verb, rest := libmsg_word(line)
		switch verb {
		case "model":
			name, _ := libmsg_word(rest)
			if name != "" && len(name) <= NAME_MAX {
				sessions[si].mlen = copy(sessions[si].model[:], name)
			}
			reply^ = vectra9.Rwrite{count = u32(len(data))}
		case "hangup":
			sess_free(si)
			reply^ = vectra9.Rwrite{count = u32(len(data))}
		case:
			reply^ = vectra9.error_reply(vectra9.EINVAL)
		}
	case k == SESS_REQUEST && si >= 0 && si < MAX_SESSIONS && sessions[si].used:
		append(&sessions[si].request, ..data)
		take_request(si)
		reply^ = vectra9.Rwrite{count = u32(len(data))}
	case:
		reply^ = vectra9.error_reply(vectra9.EPERM)
	}
}

// answer_reply_reads gives the reads parked on a session's `reply` its
// events, now that a request has loaded them.
answer_reply_reads :: proc(si: int) {
	want := Reply_Want{node = node_of(SESS_REPLY, si)}
	for {
		req, ok := lib9p.held(&srv, &want, wants_reply)
		if !ok {
			return
		}
		s := &sessions[si]
		if s.epos >= len(s.events) {
			_ = lib9p.respond(req, vectra9.Rread{data = nil})
			continue
		}
		ev := s.events[s.epos]
		s.epos += 1
		m := req.msg.(vectra9.Tread)
		room := min(len(req.payload), int(m.count))
		_ = lib9p.respond(req, vectra9.Rread{data = event_into(ev, req.payload[:room])})
	}
}

Reply_Want :: struct {
	node: i32,
}

wants_reply :: proc "contextless" (arg: rawptr, request: ^vectra9.Msg) -> bool {
	w := (^Reply_Want)(arg)
	#partial switch m in request^ {
	case vectra9.Tread:
		return libuser.fid_lookup(&fids, m.fid) == w.node
	}
	return false
}

// -- Small things -------------------------------------------------------------

models_buf: [256]u8

models_line :: proc "contextless" () -> []u8 {
	// The stub offers one model; a real backend lists what it loaded.
	n := copy(models_buf[:], "stub\n")
	return models_buf[:n]
}

usage_buf: [128]u8

usage_line :: proc "contextless" (si: int) -> []u8 {
	s := &sessions[si]
	sink := libodin.sink_from(usage_buf[:])
	libodin.put_str(&sink, "in ")
	libodin.put_uint(&sink, u64(s.in_toks))
	libodin.put_str(&sink, " out ")
	libodin.put_uint(&sink, u64(s.out_toks))
	libodin.put_str(&sink, " cache 0 cost 0\n")
	return transmute([]u8)libodin.str(&sink)
}

step :: proc "contextless" (from: i32, name: string) -> i32 {
	if name == "." {
		return from
	}
	if name == ".." {
		if from >= SESS_BASE {
			return NODE_ROOT
		}
		return NODE_ROOT
	}
	if from == NODE_ROOT {
		for f in ROOT_FILES {
			if f.name == name {
				return f.node
			}
		}
		// A session directory by its number.
		if v, ok := parse_uint(name); ok && int(v) < MAX_SESSIONS && sessions[v].used {
			return node_of(SESS_DIR, int(v))
		}
		return -1
	}
	if from >= SESS_BASE && kind_of(from) == SESS_DIR {
		si := sess_of(from)
		for f in SESS_FILES {
			if f.name == name {
				return node_of(f.kind, si)
			}
		}
	}
	return -1
}

@(private = "file")
readdir :: proc "contextless" (m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	context = libuser.heap_context()
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
	i := int(m.offset)
	if node == NODE_ROOT {
		// The root's files, then a directory per live session.
		nsess := 0
		for j in 0 ..< MAX_SESSIONS {
			if sessions[j].used {
				nsess += 1
			}
		}
		for i < len(ROOT_FILES) + nsess {
			e: vectra9.Dirent
			if i < len(ROOT_FILES) {
				e = vectra9.Dirent{qid = qid_of(ROOT_FILES[i].node), type = vectra9.DT_REG, name = ROOT_FILES[i].name}
			} else {
				// The k-th live session.
				k := i - len(ROOT_FILES)
				at := -1
				seen := 0
				for j in 0 ..< MAX_SESSIONS {
					if sessions[j].used {
						if seen == k {
							at = j
							break
						}
						seen += 1
					}
				}
				if at < 0 {
					break
				}
				e = vectra9.Dirent{qid = qid_of(node_of(SESS_DIR, at)), type = vectra9.DT_DIR, name = num_name(at)}
			}
			if !put_dirent(&c, e, i) {
				break
			}
			i += 1
		}
	} else if node >= SESS_BASE && kind_of(node) == SESS_DIR {
		si := sess_of(node)
		for i < len(SESS_FILES) {
			e := vectra9.Dirent{qid = qid_of(node_of(SESS_FILES[i].kind, si)), type = vectra9.DT_REG, name = SESS_FILES[i].name}
			if !put_dirent(&c, e, i) {
				break
			}
			i += 1
		}
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}

put_dirent :: proc "contextless" (c: ^vectra9.Cursor, e: vectra9.Dirent, i: int) -> bool {
	if vectra9.remaining(c) < vectra9.dirent_size(e.name) {
		return false
	}
	e := e
	e.offset = u64(i + 1)
	vectra9.put_dirent(c, e)
	return true
}

// The `new` read allocates a session and answers its number. A read of
// `new` at a non-zero offset is the tail of that answer.
name_buf: [24]u8

num_line :: proc "contextless" (i: int) -> string {
	sink := libodin.sink_from(name_buf[:])
	libodin.put_uint(&sink, u64(i))
	libodin.put_str(&sink, "\n")
	return libodin.str(&sink)
}

num_name :: proc "contextless" (i: int) -> string {
	sink := libodin.sink_from(name_buf[:])
	libodin.put_uint(&sink, u64(i))
	return libodin.str(&sink)
}

// event_into copies one event and its newline into `into`, capped, for a
// stream read that answers the whole event a read.
event_into :: proc "contextless" (ev: string, into: []u8) -> []u8 {
	if len(into) == 0 {
		return nil
	}
	n := copy(into[:len(into) - 1], ev)
	into[n] = '\n'
	return into[:n + 1]
}

slice_window :: proc "contextless" (data: []u8, offset: u64, into: []u8) -> []u8 {
	if offset >= u64(len(data)) {
		return nil
	}
	n := copy(into, data[offset:])
	return into[:n]
}

parse_uint :: proc "contextless" (s: string) -> (u64, bool) {
	if len(s) == 0 {
		return 0, false
	}
	v: u64 = 0
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			return 0, false
		}
		v = v * 10 + u64(s[i] - '0')
	}
	return v, true
}

libmsg_word :: proc "contextless" (s: string) -> (first: string, rest: string) {
	i := 0
	for i < len(s) && s[i] == ' ' {
		i += 1
	}
	start := i
	for i < len(s) && s[i] != ' ' {
		i += 1
	}
	first = s[start:i]
	for i < len(s) && s[i] == ' ' {
		i += 1
	}
	return first, s[i:]
}
