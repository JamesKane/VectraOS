/*
ghost -- an agent in the shell, `docs/GHOST.md` section 4. A session is a
directory, the draw server's shape, and a person, a script and a program
all drive it through the same files.

    /mnt/ghost/new          read it for a session number
    /mnt/ghost/N/ctl        model, effort, budget, work <dir>, class <c>,
                            hangup; a read says what is set
    /mnt/ghost/N/prompt     write a message from the person
    /mnt/ghost/N/reply      a read that parks, and streams the answer
    /mnt/ghost/N/confirm    a read that parks until the ghost needs a yes;
                            a write is the answer
    /mnt/ghost/N/log        every step: the tool, its input, its result
    /mnt/ghost/N/status     Thinking, Running <tool>, Waiting, Idle, or
                            Stopped and why
    /mnt/ghost/N/tools      the tools this session offers, the API's JSON
    /mnt/ghost/N/ns         the namespace the tools run in, as `ns` prints

**The loop is the API's**, `turn.odin`: write the request to the model's
directory, read the stream events back, run each `tool_use`, and send
every result back in one message. **The tools run in a sandbox**,
`sandbox.odin`: a child forked with its own namespace, the class file's
binds applied, every name the class does not bind unmounted, and then
`RFNOMNT`, so the table the ghost built is the table the tools have.

    ghost [-m modeldir] [-u]

`-m` names the model's directory, `/mnt/model` by default. `-u` forks the
tools without `RFNOMNT`: the control the self-test runs to show the lock
is what its check sees, and nothing a person should start.

The mode check waits for `docs/FLEET.md` step 2's user `ghost`. Until
then the tools run as the person, and a write outside `/n/work` is
refused because nothing outside it is writable in the sandbox, not by a
mode.
*/
package ghost

import "base:runtime"
import "vsys:abi"
import "vsys:lib9p"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

FRAME :: 8192 + 512
MAX_SESSIONS :: 4
NAME_MAX :: 64
PATH_MAX :: 256

// The node numbers, modelfs's scheme: the low bits the kind, the high the
// session, so one number names a file of one session.
NODE_ROOT :: i32(0)
NODE_NEW :: i32(1)
SESS_BASE :: i32(16)
SESS_STRIDE :: i32(16)
SESS_DIR :: i32(0)
SESS_CTL :: i32(1)
SESS_PROMPT :: i32(2)
SESS_REPLY :: i32(3)
SESS_CONFIRM :: i32(4)
SESS_LOG :: i32(5)
SESS_STATUS :: i32(6)
SESS_TOOLS :: i32(7)
SESS_NS :: i32(8)

// A path a read saw, and the qid version it saw: what a `write` is checked
// against.
Seen :: struct {
	path:    string,
	version: u32,
}

Session :: struct {
	used:       bool,

	// What `ctl` sets.
	model:      [NAME_MAX]u8,
	mlen:       int,
	effort:     [16]u8,
	elen:       int,
	class:      [NAME_MAX]u8,
	clen:       int,
	work:       [PATH_MAX]u8,
	wlen:       int,
	budget:     int,

	msess:      int, // The model's session number, or -1 before the first request
	transcript: [dynamic]u8, // The messages, each a JSON object, comma-joined, never rewritten
	reply:      [dynamic]u8, // The answer's text, as it streams
	rpos:       int, // How much of it the reads have taken
	running:    bool, // A turn is under way
	status:     [96]u8,
	slen:       int,
	log:        [dynamic]u8,

	// The requester. A turn that needs a yes sets `question` and waits on
	// `answered`; a write to `confirm`, or the clock after a minute, sends.
	question:   [dynamic]u8,
	asking:     bool,
	delivered:  bool, // A read of `confirm` has taken the question
	deadline:   int,
	answer:     [256]u8,
	alen:       int,
	answered:   ^libthread.Chan,
	write_ok:   bool, // The first write to an existing file was allowed

	seen:       [dynamic]Seen,
	io:         ^libthread.Ioproc, // The turn's: the model's reads and the tools
	tool:       ^Tool_Run, // The tool running now, for the clock's deadline
	ns_text:    [dynamic]u8,
	ns_busy:    bool,
}

sessions: [MAX_SESSIONS]Session

srv: lib9p.Srv
fids: libuser.Fid_Table
g_model_dir := "/mnt/model"
g_unlocked: bool
now: int // Ticks since the clock started, advanced by `clock_thread`
ns_io: ^libthread.Ioproc // The `ns` file's computations, which may run beside a turn

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = {}
	#force_no_inline runtime._startup_runtime()
	args := libuser.args(block)
	for i := 1; i < len(args); i += 1 {
		switch args[i] {
		case "-m":
			if i + 1 < len(args) {
				g_model_dir = args[i + 1]
				i += 1
			}
		case "-u":
			g_unlocked = true
		}
	}
	libthread.main(threadmain, nil)
}

threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = libuser.heap_context()
	fd, perr := libuser.post("/srv/ghost")
	if perr < 0 {
		libthread.threadexitsall("post")
	}
	if libthread.threadcreate(clock_thread, nil) < 0 {
		libthread.threadexitsall("threadcreate")
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

/*
clock_thread keeps `now`, and with it the two deadlines a turn cannot keep
for itself: a `run` past its time is killed, its note group and all, and a
question nobody answered inside a minute is answered no. Its sleep is on
an io proc of its own, so the server runs meanwhile.
*/
CLOCK_STEP :: 250
RUN_DEADLINE :: 30_000
CONFIRM_DEADLINE :: 60_000

clock_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = libuser.heap_context()
	io := libthread.ioproc()
	if io == nil {
		libthread.threadexits("")
	}
	for {
		_ = libthread.iosleep(io, CLOCK_STEP)
		now += CLOCK_STEP
		for i in 0 ..< MAX_SESSIONS {
			s := &sessions[i]
			if !s.used {
				continue
			}
			if t := s.tool; t != nil && t.pid > 0 && now > t.deadline && !t.killed {
				t.killed = true
				_ = libuser.notepg(u64(t.pid), "kill")
			}
			if s.asking && now > s.deadline {
				answer_question(s, "no")
			}
		}
	}
}

// -- The session --------------------------------------------------------------

sess_alloc :: proc() -> int {
	for i in 0 ..< MAX_SESSIONS {
		s := &sessions[i]
		if s.used {
			continue
		}
		s^ = Session {
			used  = true,
			msess = -1,
		}
		s.transcript = make([dynamic]u8, 0, 1024)
		s.reply = make([dynamic]u8, 0, 256)
		s.log = make([dynamic]u8, 0, 1024)
		s.question = make([dynamic]u8, 0, 128)
		s.seen = make([dynamic]Seen, 0, 8)
		s.ns_text = make([dynamic]u8, 0, 512)
		s.answered = libthread.chancreate(size_of(rawptr), 1)
		s.clen = copy(s.class[:], "edit")
		s.wlen = copy(s.work[:], "/n/work")
		set_status(s, "Idle")
		return i
	}
	return -1
}

sess_free :: proc(s: ^Session) {
	delete(s.transcript)
	delete(s.reply)
	delete(s.log)
	delete(s.question)
	for e in s.seen {
		delete(e.path)
	}
	delete(s.seen)
	delete(s.ns_text)
	libthread.chanfree(s.answered)
	if s.io != nil {
		libthread.ioclose(s.io)
	}
	if s.msess >= 0 {
		model_hangup(s)
	}
	s^ = Session{}
}

set_status :: proc "contextless" (s: ^Session, words: ..string) {
	sink := libodin.sink_from(s.status[:])
	for w in words {
		libodin.put_str(&sink, w)
	}
	s.slen = len(libodin.str(&sink))
}

log_line :: proc(s: ^Session, parts: ..string) {
	for p in parts {
		append(&s.log, p)
	}
	append(&s.log, '\n')
}

class_of :: proc "contextless" (s: ^Session) -> string {return string(s.class[:s.clen])}
work_of :: proc "contextless" (s: ^Session) -> string {return string(s.work[:s.wlen])}
model_of :: proc "contextless" (s: ^Session) -> string {return string(s.model[:s.mlen])}

// -- Serving ------------------------------------------------------------------

node_of :: proc "contextless" (kind: i32, sess: int) -> i32 {
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

live :: proc "contextless" (si: int) -> bool {
	return si >= 0 && si < MAX_SESSIONS && sessions[si].used
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
} {
	{"ctl", SESS_CTL},
	{"prompt", SESS_PROMPT},
	{"reply", SESS_REPLY},
	{"confirm", SESS_CONFIRM},
	{"log", SESS_LOG},
	{"status", SESS_STATUS},
	{"tools", SESS_TOOLS},
	{"ns", SESS_NS},
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
	_, _, _ = state, s, tag
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
		if is_dir(node) {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		room := min(len(buf), int(m.count))
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
		switch {
		case dir:
			mode = 0o040555
		case kind_of(node) == SESS_CTL, kind_of(node) == SESS_CONFIRM:
			mode = 0o100666
		case kind_of(node) == SESS_PROMPT:
			mode = 0o100222
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
	}
}

/*
read_file answers a file's bytes. `reply` and `confirm` are streams and
park: `reply` until the answer has text the reads have not taken, and
`confirm` until the turn needs a yes. Both end, a read answered empty, when
no turn is running and nothing is left. `ns` is computed in a sandbox, so
its first read parks while a child builds one.
*/
read_file :: proc(node: i32, offset: u64, into: []u8, reply: ^vectra9.Msg) {
	k := kind_of(node)
	si := sess_of(node)
	if node == NODE_NEW {
		if offset > 0 {
			reply^ = vectra9.Rread{data = nil}
			return
		}
		i := sess_alloc()
		if i < 0 {
			reply^ = vectra9.error_reply(vectra9.ENOSPC)
			return
		}
		nb: [24]u8
		reply^ = vectra9.Rread{data = slice_window(transmute([]u8)libuser.itoa(nb[:], i64(i)), 0, into)}
		return
	}
	if !live(si) {
		reply^ = vectra9.Rread{data = nil}
		return
	}
	s := &sessions[si]
	switch k {
	case SESS_CTL:
		text: [512]u8
		reply^ = vectra9.Rread{data = slice_window(ctl_text(s, text[:]), offset, into)}
	case SESS_REPLY:
		if s.rpos < len(s.reply) {
			reply^ = vectra9.Rread{data = drain_reply(s, into)}
		} else if s.running {
			lib9p.hold(&srv)
		} else {
			reply^ = vectra9.Rread{data = nil}
		}
	case SESS_CONFIRM:
		if s.asking && !s.delivered {
			reply^ = vectra9.Rread{data = take_question(s, into)}
		} else if s.running {
			lib9p.hold(&srv)
		} else {
			reply^ = vectra9.Rread{data = nil}
		}
	case SESS_LOG:
		reply^ = vectra9.Rread{data = slice_window(s.log[:], offset, into)}
	case SESS_STATUS:
		line: [100]u8
		n := copy(line[:], s.status[:s.slen])
		n += copy(line[n:], "\n")
		reply^ = vectra9.Rread{data = slice_window(line[:n], offset, into)}
	case SESS_TOOLS:
		reply^ = vectra9.Rread{data = slice_window(transmute([]u8)TOOLS_JSON, offset, into)}
	case SESS_NS:
		if offset > 0 {
			reply^ = vectra9.Rread{data = slice_window(s.ns_text[:], offset, into)}
			return
		}
		lib9p.hold(&srv)
		if !s.ns_busy {
			s.ns_busy = true
			if libthread.threadcreate(ns_thread, rawptr(uintptr(si)), 64 * 1024) < 0 {
				s.ns_busy = false
				answer_held(si)
			}
		}
	case:
		reply^ = vectra9.Rread{data = nil}
	}
}

// write_file takes a write to a session's `ctl`, `prompt` or `confirm`.
write_file :: proc(node: i32, data: []u8, reply: ^vectra9.Msg) {
	k := kind_of(node)
	si := sess_of(node)
	if !live(si) {
		reply^ = vectra9.error_reply(vectra9.EPERM)
		return
	}
	s := &sessions[si]
	done := vectra9.Rwrite{count = u32(len(data))}
	switch k {
	case SESS_CTL:
		if err := ctl_write(si, libodin.trim_space(string(data))); err != 0 {
			reply^ = vectra9.error_reply(err)
			return
		}
		reply^ = done
	case SESS_PROMPT:
		if s.running {
			reply^ = vectra9.error_reply(vectra9.EBUSY)
			return
		}
		text := libodin.trim_space(string(data))
		if len(text) == 0 {
			reply^ = vectra9.error_reply(vectra9.EINVAL)
			return
		}
		t := new(Turn)
		t.si = si
		t.prompt = clone(text)
		s.running = true
		set_status(s, "Thinking")
		if libthread.threadcreate(turn_thread, t, 256 * 1024) < 0 {
			s.running = false
			set_status(s, "Idle")
			delete(t.prompt)
			free(t)
			reply^ = vectra9.error_reply(vectra9.ENOSPC)
			return
		}
		reply^ = done
	case SESS_CONFIRM:
		if !s.asking {
			reply^ = vectra9.error_reply(vectra9.EINVAL)
			return
		}
		answer_question(s, libodin.trim_space(string(data)))
		reply^ = done
	case:
		reply^ = vectra9.error_reply(vectra9.EPERM)
	}
}

/*
ctl_write takes one line. `model`, `effort`, `budget`, `work` and `class`
set what the next turn uses, and none of them may change while a turn is
running. `hangup` ends the session.
*/
ctl_write :: proc(si: int, line: string) -> vectra9.Errno {
	s := &sessions[si]
	verb, rest := word(line)
	arg, _ := word(rest)
	if verb != "hangup" && (arg == "" || len(arg) > PATH_MAX) {
		return vectra9.EINVAL
	}
	if s.running {
		return vectra9.EBUSY
	}
	switch verb {
	case "model":
		if len(arg) > NAME_MAX {
			return vectra9.EINVAL
		}
		s.mlen = copy(s.model[:], arg)
	case "effort":
		if len(arg) > len(s.effort) {
			return vectra9.EINVAL
		}
		s.elen = copy(s.effort[:], arg)
	case "budget":
		n, ok := libuser.atoi(arg)
		if !ok || n < 0 {
			return vectra9.EINVAL
		}
		s.budget = int(n)
	case "work":
		if arg[0] != '/' {
			return vectra9.EINVAL
		}
		s.wlen = copy(s.work[:], arg)
	case "class":
		// A class is a file under /lib/ghost/ns, named by one word.
		if len(arg) > NAME_MAX || !is_word(arg) {
			return vectra9.EINVAL
		}
		s.clen = copy(s.class[:], arg)
	case "hangup":
		sess_free(s)
	case:
		return vectra9.EINVAL
	}
	return 0
}

ctl_text :: proc "contextless" (s: ^Session, buf: []u8) -> []u8 {
	sink := libodin.sink_from(buf)
	libodin.put_str(&sink, "model ")
	libodin.put_str(&sink, s.mlen > 0 ? model_of(s) : "default")
	libodin.put_str(&sink, "\neffort ")
	libodin.put_str(&sink, s.elen > 0 ? string(s.effort[:s.elen]) : "default")
	libodin.put_str(&sink, "\nbudget ")
	libodin.put_uint(&sink, u64(s.budget))
	libodin.put_str(&sink, "\nwork ")
	libodin.put_str(&sink, work_of(s))
	libodin.put_str(&sink, "\nclass ")
	libodin.put_str(&sink, class_of(s))
	libodin.put_str(&sink, "\n")
	return transmute([]u8)libodin.str(&sink)
}

// drain_reply takes what it can of the answer's text the reads have not.
drain_reply :: proc "contextless" (s: ^Session, into: []u8) -> []u8 {
	n := copy(into, s.reply[s.rpos:])
	s.rpos += n
	return into[:n]
}

// take_question answers the question, whole, to the one read that takes it.
take_question :: proc "contextless" (s: ^Session, into: []u8) -> []u8 {
	s.delivered = true
	if len(into) == 0 {
		return nil
	}
	n := copy(into[:len(into) - 1], s.question[:])
	into[n] = '\n'
	return into[:n + 1]
}

// answer_question gives the turn waiting on `confirm` its answer, once.
answer_question :: proc "contextless" (s: ^Session, text: string) {
	if !s.asking {
		return
	}
	s.asking = false
	s.alen = copy(s.answer[:], text)
	_ = libthread.nbsendp(s.answered, rawptr(s))
}

Want :: struct {
	node: i32,
}

wants_node :: proc "contextless" (arg: rawptr, request: ^vectra9.Msg) -> bool {
	w := (^Want)(arg)
	#partial switch m in request^ {
	case vectra9.Tread:
		return libuser.fid_lookup(&fids, m.fid) == w.node
	}
	return false
}

/*
answer_held gives the reads parked on a session's streams what they can
now have: text of the answer, the question, the namespace. A read of a
stream with nothing for it stays parked while the turn runs, and ends when
it does not.
*/
answer_held :: proc "contextless" (si: int) {
	s := &sessions[si]
	want := Want{node = node_of(SESS_REPLY, si)}
	for {
		req, ok := lib9p.held(&srv, &want, wants_node)
		if !ok {
			break
		}
		m := req.msg.(vectra9.Tread)
		room := min(len(req.payload), int(m.count))
		if s.rpos < len(s.reply) {
			_ = lib9p.respond(req, vectra9.Rread{data = drain_reply(s, req.payload[:room])})
		} else if !s.running {
			_ = lib9p.respond(req, vectra9.Rread{data = nil})
		} else {
			break
		}
	}
	want.node = node_of(SESS_CONFIRM, si)
	for {
		req, ok := lib9p.held(&srv, &want, wants_node)
		if !ok {
			break
		}
		m := req.msg.(vectra9.Tread)
		room := min(len(req.payload), int(m.count))
		if s.asking && !s.delivered {
			_ = lib9p.respond(req, vectra9.Rread{data = take_question(s, req.payload[:room])})
		} else if !s.running {
			_ = lib9p.respond(req, vectra9.Rread{data = nil})
		} else {
			break
		}
	}
	if s.ns_busy {
		return
	}
	want.node = node_of(SESS_NS, si)
	for {
		req, ok := lib9p.held(&srv, &want, wants_node)
		if !ok {
			break
		}
		m := req.msg.(vectra9.Tread)
		room := min(len(req.payload), int(m.count))
		_ = lib9p.respond(req, vectra9.Rread{data = slice_window(s.ns_text[:], m.offset, req.payload[:room])})
	}
}

// ns_thread builds the session's sandbox in a child that prints its own
// namespace, and answers the reads of `ns` that wait for it.
ns_thread :: proc "contextless" (arg: rawptr) {
	context = libuser.heap_context()
	si := int(uintptr(arg))
	s := &sessions[si]
	if ns_io == nil {
		ns_io = libthread.ioproc(32 * 1024)
	}
	clear(&s.ns_text)
	if ns_io != nil {
		t := tool_new(s, .Ns)
		_ = libthread.iorun(ns_io, tool_run, t)
		append(&s.ns_text, ..t.out[:t.nout])
		tool_free(t)
	}
	s.ns_busy = false
	answer_held(si)
}

step :: proc "contextless" (from: i32, name: string) -> i32 {
	if name == "." {
		return from
	}
	if name == ".." {
		return NODE_ROOT
	}
	if from == NODE_ROOT {
		if name == "new" {
			return NODE_NEW
		}
		if v, ok := libuser.atoi(name); ok && v >= 0 && live(int(v)) {
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
	names: [24]u8
	if node == NODE_ROOT {
		// `new`, then a directory per live session, in index order.
		for i <= MAX_SESSIONS {
			e: vectra9.Dirent
			if i == 0 {
				e = vectra9.Dirent{qid = qid_of(NODE_NEW), type = vectra9.DT_REG, name = "new"}
			} else {
				si := i - 1
				if !live(si) {
					i += 1
					continue
				}
				e = vectra9.Dirent{qid = qid_of(node_of(SESS_DIR, si)), type = vectra9.DT_DIR, name = libuser.itoa(names[:], i64(si))}
			}
			if !put_dirent(&c, e, i) {
				break
			}
			i += 1
		}
	} else {
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

// -- Small things -------------------------------------------------------------

slice_window :: proc "contextless" (data: []u8, offset: u64, into: []u8) -> []u8 {
	if offset >= u64(len(data)) {
		return nil
	}
	n := copy(into, data[offset:])
	return into[:n]
}

// word takes the first run of non-space off `s`, and answers it and the rest.
word :: proc "contextless" (s: string) -> (first: string, rest: string) {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i += 1
	}
	start := i
	for i < len(s) && s[i] != ' ' && s[i] != '\t' {
		i += 1
	}
	first = s[start:i]
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i += 1
	}
	return first, s[i:]
}

// is_word says `s` is letters, digits, `-` and `_`: a name that is one
// path element and never `..`.
is_word :: proc "contextless" (s: string) -> bool {
	for i in 0 ..< len(s) {
		c := s[i]
		if !((c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_') {
			return false
		}
	}
	return len(s) > 0
}

clone :: proc(s: string) -> string {
	b := make([]u8, len(s))
	copy(b, s)
	return string(b)
}
