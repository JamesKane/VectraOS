/*
plumber -- messages between programs, routed by rules. `docs/GHOST.md`
section 5, after Plan 9's plumber.

    /mnt/plumb/send      write a message here, and the rules say where it goes
    /mnt/plumb/rules     the rules, as loaded, and a write adds to them
    /mnt/plumb/<port>    a port the rules name: a read answers one message,
                         and parks until there is one

A message is `sys/libplumb`'s: a source, a destination, a working directory,
a type, attributes and data. The rules file is rule sets parted by blank
lines. Each line is an object, a verb and an argument. The first set whose
patterns all hold takes the message, its actions rewrite it, and `plumb to`
names the port. A set that is `plumb to` alone declares the port and takes
nothing.

When no program has the port open, `plumb start` runs a program and drops
the message. `plumb client` runs one and keeps the message for it to read.
A message nobody addressed and no rule takes is refused, and the write
fails.

    type is text
    data matches '([a-zA-Z0-9_/.-]+\.odin):([0-9]+)'
    arg isfile $1
    data set $file
    attr add addr=$2
    plumb to edit

Objects: `src`, `dst`, `wdir`, `type`, `attr`, `data`, `arg` (the argument
itself) and `plumb`. Verbs: `is`, `matches` (the whole object), `isfile`
and `isdir` (which set `$file` and `$dir`), `set`, `add` and `delete` (of
an attribute), `to`, `start` and `client`. `$0` to `$9` are the last
match's groups, and every field is a variable by its name. Quoting is
`rc`'s, and a variable inside quotes is not expanded. A rule starts a
program by its words, never through a shell, so what a message says is
never a command.

The rules come from `-r file`, else `$home/lib/plumbing` if it exists, else
`/lib/plumb/rules`. `include path` in a rules file splices another.
*/
package plumber

import "base:runtime"
import "vsys:abi"
import "vsys:lib9p"
import "vsys:libodin"
import "vsys:libplumb"
import "vsys:libregex"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

FRAME :: 8192 + 512
MAX_PORTS :: 32
MAX_QUEUE :: 32
MAX_WORDS :: 32
MAX_RULES_TEXT :: 64 * 1024

NODE_ROOT :: i32(0)
NODE_SEND :: i32(1)
NODE_RULES :: i32(2)
PORT_BASE :: i32(16)

Obj :: enum u8 {
	None,
	Src,
	Dst,
	Wdir,
	Type,
	Attr,
	Data,
	Arg,
	Plumb,
}

Verb :: enum u8 {
	None,
	Is,
	Matches,
	Isfile,
	Isdir,
	Set,
	Add,
	Delete,
	To,
	Start,
	Client,
}

Rule :: struct {
	obj:  Obj,
	verb: Verb,
	arg:  string, // The rest of the line, quotes and variables as written
	re:   ^libregex.Regex, // Compiled for `matches`
}

Ruleset :: struct {
	rules:    []Rule,
	port:     string, // What `plumb to` named, or ""
	patterns: int, // A set with none only declares its port
}

Port :: struct {
	name:  string,
	opens: int, // Descriptors open on it
	queue: [MAX_QUEUE][]u8, // Packed messages waiting to be read
	head:  int,
	count: int,
}

// A message being routed: its fields as they are rewritten, and the
// variables the rules set.
Work :: struct {
	src, dst, wdir, type, attr, data: string,
	file, dir:                        string,
	caps:                             [libregex.SLOTS]int,
	matched:                          string, // What the last `matches` ran on
	have_match:                       bool,
}

sets: [dynamic]Ruleset
ports: [MAX_PORTS]Port
nports: int
rules_text: [dynamic]u8
fids: libuser.Fid_Table
srv: lib9p.Srv
rules_path: string
rules_path_buf: [256]u8

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = {}
	#force_no_inline runtime._startup_runtime()
	args := libuser.args(block)
	for i := 1; i < len(args); i += 1 {
		if args[i] == "-r" && i + 1 < len(args) {
			i += 1
			n := copy(rules_path_buf[:], args[i])
			rules_path = string(rules_path_buf[:n])
		}
	}
	libthread.main(threadmain, nil)
}

threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = libuser.heap_context()
	sets = make([dynamic]Ruleset, 0, 16)
	rules_text = make([dynamic]u8, 0, 4096)
	if rules_path == "" {
		home_buf: [128]u8
		home := libuser.getenv("home", home_buf[:])
		if home == "" {
			home = "/usr/glenda"
		}
		st: abi.Stat
		own := libuser.cat_into(rules_path_buf[:], home, "/lib/plumbing")
		if libuser.stat(own, &st) >= 0 {
			rules_path = own
		} else {
			rules_path = "/lib/plumb/rules"
		}
	}
	if !load_rules(rules_path, 0) {
		libuser.eprint("plumber: cannot read the rules at ", rules_path, "\n")
	}
	fd, perr := libuser.post("/srv/plumb")
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

// -- The rules ------------------------------------------------------------------

// load_rules reads a rules file and adds its sets. An `include` splices
// another file, a few deep at most.
load_rules :: proc(path: string, depth: int) -> bool {
	if depth > 4 {
		return false
	}
	text, ok := libuser.read_file(path, context.allocator)
	if !ok {
		return false
	}
	add_rules(string(text), depth)
	return true
}

// add_rules parses rule sets out of `text`, which must be the caller's own
// heap copy and is never freed: a rule's argument points into it. The
// read-back text is a second copy. An include lands in the middle of a
// file, and a growing buffer would move what the rules point at.
add_rules :: proc(text: string, depth: int) {
	if len(rules_text) + len(text) <= MAX_RULES_TEXT {
		append(&rules_text, ..transmute([]u8)text)
		if len(text) == 0 || text[len(text) - 1] != '\n' {
			append(&rules_text, '\n')
		}
	}
	src := text
	rules := make([dynamic]Rule, 0, 8)
	port := ""
	flush := proc(rules: ^[dynamic]Rule, port: ^string) {
		if len(rules) > 0 {
			set := Ruleset{rules = rules[:], port = port^}
			for &r in set.rules {
				if is_pattern(&r) {
					set.patterns += 1
				}
			}
			append(&sets, set)
			if len(port^) > 0 {
				declare_port(port^)
			}
			rules^ = make([dynamic]Rule, 0, 8)
		}
		port^ = ""
	}
	at := 0
	for at < len(src) {
		end := at
		for end < len(src) && src[end] != '\n' {
			end += 1
		}
		line := trim(src[at:end])
		at = end + 1
		if len(line) == 0 {
			flush(&rules, &port)
			continue
		}
		if line[0] == '#' {
			continue
		}
		// `include path` is a file spliced in, as its own sets.
		w1, rest := first_word(line)
		if w1 == "include" {
			flush(&rules, &port)
			inc, _ := first_word(rest)
			_ = load_rules(inc, depth + 1)
			continue
		}
		w2, arg := first_word(rest)
		rule := Rule{obj = obj_of(w1), verb = verb_of(w2), arg = arg}
		if rule.obj == .None || rule.verb == .None {
			libuser.eprint("plumber: rule not understood: ", line, "\n")
			continue
		}
		if rule.verb == .Matches {
			// The pattern is the argument's first word, quotes off and no
			// variables: `$` there is the pattern's own anchor.
			words: [1]string
			n := split_words(arg, nil, words[:], false)
			pat := n > 0 ? words[0] : ""
			re, ok := libregex.compile(pat, false, context.allocator)
			if !ok {
				libuser.eprint("plumber: pattern does not parse: ", pat, "\n")
				continue
			}
			rule.re = re
		}
		if rule.obj == .Plumb && rule.verb == .To {
			words: [1]string
			n := split_words(arg, nil, words[:], false)
			port = n > 0 ? words[0] : ""
		}
		append(&rules, rule)
	}
	flush(&rules, &port)
}

// is_pattern says whether a rule can refuse a message.
is_pattern :: proc "contextless" (r: ^Rule) -> bool {
	if r.obj == .Plumb {
		return false
	}
	#partial switch r.verb {
	case .Is, .Matches, .Isfile, .Isdir:
		return true
	}
	return false
}

declare_port :: proc(name: string) {
	if find_port(name) >= 0 || nports >= MAX_PORTS {
		return
	}
	ports[nports].name = name
	nports += 1
}

find_port :: proc "contextless" (name: string) -> int {
	for i in 0 ..< nports {
		if ports[i].name == name {
			return i
		}
	}
	return -1
}

obj_of :: proc "contextless" (w: string) -> Obj {
	switch w {
	case "src":
		return .Src
	case "dst":
		return .Dst
	case "wdir":
		return .Wdir
	case "type":
		return .Type
	case "attr":
		return .Attr
	case "data":
		return .Data
	case "arg":
		return .Arg
	case "plumb":
		return .Plumb
	}
	return .None
}

verb_of :: proc "contextless" (w: string) -> Verb {
	switch w {
	case "is":
		return .Is
	case "matches":
		return .Matches
	case "isfile":
		return .Isfile
	case "isdir":
		return .Isdir
	case "set":
		return .Set
	case "add":
		return .Add
	case "delete":
		return .Delete
	case "to":
		return .To
	case "start":
		return .Start
	case "client":
		return .Client
	}
	return .None
}

// -- Routing ------------------------------------------------------------------

Outcome :: enum u8 {
	Refused, // No rule took it
	Delivered, // On a port's queue, or read at once
	Started, // A program was started for it
	Full, // The port's queue has no room
}

/*
route runs the rule sets over a message. The first set whose patterns all
hold takes it. Its `plumb to` is the port, unless the message came with a
destination, in which case only a set that plumbs there may take it. With
no set, a message with a destination that is a port goes there as it is.
*/
route :: proc(m: ^libplumb.Msg) -> Outcome {
	for &set in sets {
		w := Work{src = m.src, dst = m.dst, wdir = m.wdir, type = m.type, attr = m.attr, data = m.data}
		// A set with no pattern, `plumb to ghost` alone, declares its port
		// and takes nothing.
		if len(set.port) == 0 || set.patterns == 0 {
			continue
		}
		if len(m.dst) > 0 && m.dst != set.port {
			continue
		}
		if apply(&set, &w) {
			w.dst = set.port
			return deliver(&set, &w)
		}
	}
	if len(m.dst) > 0 && find_port(m.dst) >= 0 {
		w := Work{src = m.src, dst = m.dst, wdir = m.wdir, type = m.type, attr = m.attr, data = m.data}
		return deliver(nil, &w)
	}
	return .Refused
}

// apply runs a set's lines in order on `w`, and answers whether every
// pattern held. Actions rewrite `w` as they go, and a set that fails leaves
// its rewrites behind on a copy the caller drops.
apply :: proc(set: ^Ruleset, w: ^Work) -> bool {
	for &rule in set.rules {
		if rule.obj == .Plumb {
			continue
		}
		switch rule.verb {
		case .Is:
			want := one_word(w, rule.arg)
			if object(w, rule.obj, want) != want {
				return false
			}
		case .Matches:
			text := object(w, rule.obj, one_word(w, rule.arg))
			start, end, ok := libregex.match_caps(rule.re, text, 0, w.caps[:])
			if !ok || start != 0 || end != len(text) {
				return false
			}
			w.matched = text
			w.have_match = true
		case .Isfile, .Isdir:
			name := object(w, rule.obj, one_word(w, rule.arg))
			full, ok := full_path(w, name)
			if !ok {
				return false
			}
			st: abi.Stat
			if libuser.stat(full, &st) < 0 {
				return false
			}
			is_dir := st.mode & abi.DMDIR != 0
			if rule.verb == .Isfile {
				if is_dir {
					return false
				}
				w.file = full
			} else {
				if !is_dir {
					return false
				}
				w.dir = full
			}
		case .Set:
			value := one_word(w, rule.arg)
			switch rule.obj {
			case .Src:
				w.src = value
			case .Dst:
				w.dst = value
			case .Wdir:
				w.wdir = value
			case .Type:
				w.type = value
			case .Attr:
				w.attr = value
			case .Data:
				w.data = value
			case .Arg, .Plumb, .None:
			}
		case .Add:
			if rule.obj == .Attr {
				pair := one_word(w, rule.arg)
				if len(pair) > 0 {
					w.attr = keep(len(w.attr) > 0 ? cat3(w.attr, " ", pair) : pair)
				}
			}
		case .Delete:
			if rule.obj == .Attr {
				w.attr = attr_without(w.attr, one_word(w, rule.arg))
			}
		case .To, .Start, .Client, .None:
		}
	}
	return true
}

// deliver sends `w` to its port. A port nobody has open runs the set's
// `start` or `client` program, if it names one.
deliver :: proc(set: ^Ruleset, w: ^Work) -> Outcome {
	pi := find_port(w.dst)
	if pi < 0 {
		return .Refused
	}
	p := &ports[pi]
	if p.opens == 0 && set != nil {
		for &rule in set.rules {
			if rule.obj != .Plumb || (rule.verb != .Start && rule.verb != .Client) {
				continue
			}
			words: [MAX_WORDS]string
			n := split_words(rule.arg, w, words[:], true)
			if n == 0 {
				continue
			}
			run(words[:n])
			if rule.verb == .Start {
				return .Started
			}
			break
		}
	}
	m := libplumb.Msg{src = w.src, dst = w.dst, wdir = w.wdir, type = w.type, attr = w.attr, data = w.data}
	packed := make([]u8, libplumb.MAX)
	n := libplumb.pack(&m, packed)
	if n < 0 {
		delete(packed)
		return .Refused
	}
	if p.count >= MAX_QUEUE {
		delete(packed)
		return .Full
	}
	p.queue[(p.head + p.count) % MAX_QUEUE] = packed[:n]
	p.count += 1
	answer_port(p)
	return .Delivered
}

// run starts a program by its words, never through a shell. A name with no
// slash is looked for in /bin. The start is logged, since a program that
// appears from nowhere should say who called it. The program gets a copy of
// the namespace, not a share. One that mounts the plumber itself would
// otherwise mount it into this server's own namespace. A server that holds
// a mount of its own pipe never sees that pipe go.
run :: proc(argv: []string) {
	path_buf: [256]u8
	path := argv[0]
	if !libodin.contains(path, "/") {
		path = libuser.cat_into(path_buf[:], "/bin/", argv[0])
	}
	libuser.eprint("plumber: starting", "")
	for a in argv {
		libuser.eprint(" ", a)
	}
	libuser.eprint("\n")
	_ = libuser.spawn(path, abi.SPAWN_NOWAIT | abi.SPAWN_NS_COPY, argv)
}

// object answers the field a rule names, or the argument itself for `arg`.
object :: proc "contextless" (w: ^Work, obj: Obj, arg: string) -> string {
	switch obj {
	case .Src:
		return w.src
	case .Dst:
		return w.dst
	case .Wdir:
		return w.wdir
	case .Type:
		return w.type
	case .Attr:
		return w.attr
	case .Data:
		return w.data
	case .Arg:
		return arg
	case .Plumb, .None:
	}
	return ""
}

// full_path is `name` under the working directory unless it is absolute.
full_path :: proc(w: ^Work, name: string) -> (string, bool) {
	if len(name) == 0 {
		return "", false
	}
	if name[0] == '/' {
		return name, true
	}
	if len(w.wdir) == 0 {
		return keep(cat3("/", name, "")), true
	}
	return keep(cat3(w.wdir, "/", name)), true
}

// attr_without is `attr` less the pair named `name`.
attr_without :: proc(attr: string, name: string) -> string {
	out := make([dynamic]u8, 0, len(attr))
	at := 0
	for at < len(attr) {
		for at < len(attr) && attr[at] == ' ' {
			at += 1
		}
		start := at
		for at < len(attr) && attr[at] != ' ' {
			at += 1
		}
		pair := attr[start:at]
		eq := -1
		for i in 0 ..< len(pair) {
			if pair[i] == '=' {
				eq = i
				break
			}
		}
		if eq >= 0 && pair[:eq] == name {
			continue
		}
		if len(pair) > 0 {
			if len(out) > 0 {
				append(&out, ' ')
			}
			append(&out, ..transmute([]u8)pair)
		}
	}
	return string(out[:])
}

// -- Words and variables ----------------------------------------------------

/*
split_words parts `text` into words `rc`'s way. Spaces part them, single
quotes hold a word together with `''` for one quote, and a quoted part
joins what it touches. Outside quotes `$name` is a variable when `w` is
given, and `expand` says whether to. Answers the count.
*/
split_words :: proc(text: string, w: ^Work, into: []string, expand: bool) -> int {
	n := 0
	at := 0
	for at < len(text) && n < len(into) {
		for at < len(text) && (text[at] == ' ' || text[at] == '\t') {
			at += 1
		}
		if at >= len(text) {
			break
		}
		word := make([dynamic]u8, 0, 64)
		for at < len(text) && text[at] != ' ' && text[at] != '\t' {
			c := text[at]
			switch {
			case c == '\'':
				at += 1
				for at < len(text) {
					if text[at] == '\'' {
						if at + 1 < len(text) && text[at + 1] == '\'' {
							append(&word, '\'')
							at += 2
							continue
						}
						at += 1
						break
					}
					append(&word, text[at])
					at += 1
				}
			case c == '$' && expand && w != nil:
				at += 1
				name_end := at
				if name_end < len(text) && text[name_end] >= '0' && text[name_end] <= '9' {
					name_end += 1
				} else {
					for name_end < len(text) && is_name(text[name_end]) {
						name_end += 1
					}
				}
				append(&word, ..transmute([]u8)variable(w, text[at:name_end]))
				at = name_end
			case:
				append(&word, c)
				at += 1
			}
		}
		into[n] = string(word[:])
		n += 1
	}
	return n
}

// one_word is the argument's first word, expanded.
one_word :: proc(w: ^Work, arg: string) -> string {
	words: [1]string
	n := split_words(arg, w, words[:], true)
	return n > 0 ? words[0] : ""
}

// variable answers `$name`: a group of the last match by its digit, a field
// by its name, or the file or directory a rule found.
variable :: proc "contextless" (w: ^Work, name: string) -> string {
	if len(name) == 1 && name[0] >= '0' && name[0] <= '9' {
		if !w.have_match {
			return ""
		}
		g := int(name[0] - '0')
		if g == 0 {
			return w.matched
		}
		s, e := w.caps[2 * (g - 1)], w.caps[2 * (g - 1) + 1]
		if s < 0 || e < s || e > len(w.matched) {
			return ""
		}
		return w.matched[s:e]
	}
	switch name {
	case "src":
		return w.src
	case "dst":
		return w.dst
	case "wdir":
		return w.wdir
	case "type":
		return w.type
	case "attr":
		return w.attr
	case "data":
		return w.data
	case "file":
		return w.file
	case "dir":
		return w.dir
	}
	return ""
}

is_name :: proc "contextless" (c: u8) -> bool {
	return (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '_'
}

first_word :: proc "contextless" (s: string) -> (word: string, rest: string) {
	t := trim(s)
	for i in 0 ..< len(t) {
		if t[i] == ' ' || t[i] == '\t' {
			return t[:i], trim(t[i:])
		}
	}
	return t, ""
}

trim :: proc "contextless" (s: string) -> string {
	t := s
	for len(t) > 0 && (t[0] == ' ' || t[0] == '\t' || t[0] == '\r') {
		t = t[1:]
	}
	for len(t) > 0 && (t[len(t) - 1] == ' ' || t[len(t) - 1] == '\t' || t[len(t) - 1] == '\r') {
		t = t[:len(t) - 1]
	}
	return t
}

cat3 :: proc(a, b, c: string) -> string {
	out := make([]u8, len(a) + len(b) + len(c))
	n := copy(out, a)
	n += copy(out[n:], b)
	n += copy(out[n:], c)
	return string(out[:n])
}

// keep answers `s` as it is. A string built while routing lives on the heap
// until the message is packed, and the packing copies it. The heap grows by
// a routing's scraps and is a program's own, freed at its end.
keep :: proc "contextless" (s: string) -> string {
	return s
}

// -- The handler --------------------------------------------------------------

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
		if pi := port_of(node); pi >= 0 {
			ports[pi].opens += 1
		}
		libuser.fid_open(&fids, m.fid)
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}

	case vectra9.Tread:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		room := min(len(buf), int(m.count))
		switch {
		case node == NODE_RULES:
			reply^ = vectra9.Rread{data = slice_window(rules_text[:], m.offset, buf[:room])}
		case node == NODE_SEND:
			reply^ = vectra9.Rread{data = nil}
		case node == NODE_ROOT:
			reply^ = vectra9.error_reply(vectra9.EISDIR)
		case:
			pi := port_of(node)
			if pi < 0 {
				reply^ = vectra9.error_reply(vectra9.ENOENT)
				return
			}
			p := &ports[pi]
			if p.count == 0 {
				lib9p.hold(&srv)
				return
			}
			reply^ = vectra9.Rread{data = pop(p, buf[:room])}
		}

	case vectra9.Twrite:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		switch node {
		case NODE_SEND:
			msg, mok := libplumb.unpack(string(m.data))
			if !mok {
				reply^ = vectra9.error_reply(vectra9.EINVAL)
				return
			}
			switch route(&msg) {
			case .Refused:
				reply^ = vectra9.error_reply(vectra9.ENOENT)
			case .Full:
				reply^ = vectra9.error_reply(vectra9.EBUSY)
			case .Delivered, .Started:
				reply^ = vectra9.Rwrite{count = u32(len(m.data))}
			}
		case NODE_RULES:
			// A copy of its own, since the rules point into what they parsed.
			own := make([]u8, len(m.data))
			copy(own, m.data)
			add_rules(string(own), 0)
			reply^ = vectra9.Rwrite{count = u32(len(m.data))}
		case:
			reply^ = vectra9.error_reply(vectra9.EPERM)
		}

	case vectra9.Treaddir:
		readdir(m, reply, buf)

	case vectra9.Tgetattr:
		node, ok := libuser.node_of(&fids, m.fid, reply)
		if !ok {
			return
		}
		dir := node == NODE_ROOT
		size := u64(0)
		if node == NODE_RULES {
			size = u64(len(rules_text))
		}
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = dir ? 0o040555 : 0o100666,
			nlink   = dir ? 2 : 1,
			size    = size,
			blksize = 512,
		}

	case vectra9.Tclunk:
		node := libuser.fid_lookup(&fids, m.fid)
		was_open := libuser.fid_is_open(&fids, m.fid)
		libuser.fid_release(&fids, m.fid)
		if was_open {
			if pi := port_of(node); pi >= 0 && ports[pi].opens > 0 {
				ports[pi].opens -= 1
			}
		}
		reply^ = vectra9.Rclunk{}

	case vectra9.Tremove:
		libuser.fid_release(&fids, m.fid)
		reply^ = vectra9.Rremove{}

	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

// pop takes the oldest message off a port into `into`.
pop :: proc "contextless" (p: ^Port, into: []u8) -> []u8 {
	msg := p.queue[p.head]
	p.queue[p.head] = nil
	p.head = (p.head + 1) % MAX_QUEUE
	p.count -= 1
	n := copy(into, msg)
	context = libuser.heap_context()
	delete(msg)
	return into[:n]
}

// wants_port accepts a held read of port `arg`.
wants_port :: proc "contextless" (arg: rawptr, request: ^vectra9.Msg) -> bool {
	p := (^Port)(arg)
	#partial switch m in request^ {
	case vectra9.Tread:
		node := libuser.fid_lookup(&fids, m.fid)
		pi := port_of(node)
		return pi >= 0 && &ports[pi] == p
	}
	return false
}

// answer_port gives a port's held reads the messages queued for it, one each.
answer_port :: proc "contextless" (p: ^Port) {
	for p.count > 0 {
		req, ok := lib9p.held(&srv, p, wants_port)
		if !ok {
			return
		}
		m := req.msg.(vectra9.Tread)
		room := min(len(req.payload), int(m.count))
		_ = lib9p.respond(req, vectra9.Rread{data = pop(p, req.payload[:room])})
	}
}

slice_window :: proc "contextless" (data: []u8, offset: u64, into: []u8) -> []u8 {
	if offset >= u64(len(data)) {
		return nil
	}
	n := copy(into, data[offset:])
	return into[:n]
}

port_of :: proc "contextless" (node: i32) -> int {
	if node < PORT_BASE || int(node - PORT_BASE) >= nports {
		return -1
	}
	return int(node - PORT_BASE)
}

qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if node == NODE_ROOT {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

step :: proc "contextless" (from: i32, name: string) -> i32 {
	if name == "." {
		return from
	}
	if name == ".." {
		return NODE_ROOT
	}
	if from != NODE_ROOT {
		return -1
	}
	switch name {
	case "send":
		return NODE_SEND
	case "rules":
		return NODE_RULES
	}
	if pi := find_port(name); pi >= 0 {
		return PORT_BASE + i32(pi)
	}
	return -1
}

readdir :: proc "contextless" (m: vectra9.Treaddir, reply: ^vectra9.Msg, buf: []u8) #no_bounds_check {
	node, ok := libuser.open_node(&fids, m.fid, reply)
	if !ok {
		return
	}
	if node != NODE_ROOT {
		reply^ = vectra9.error_reply(vectra9.ENOTDIR)
		return
	}
	room := min(len(buf), int(m.count))
	c := vectra9.cursor_from(buf[:room])
	if m.offset == 0 {
		vectra9.put_dirent(&c, vectra9.Dirent{qid = qid_of(NODE_SEND), offset = 1, type = vectra9.DT_REG, name = "send"})
	}
	if m.offset <= 1 {
		vectra9.put_dirent(&c, vectra9.Dirent{qid = qid_of(NODE_RULES), offset = 2, type = vectra9.DT_REG, name = "rules"})
	}
	for i := max(int(m.offset) - 2, 0); i < nports; i += 1 {
		if vectra9.remaining(&c) < vectra9.dirent_size(ports[i].name) {
			break
		}
		vectra9.put_dirent(&c, vectra9.Dirent{qid = qid_of(PORT_BASE + i32(i)), offset = u64(i + 3), type = vectra9.DT_REG, name = ports[i].name})
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}
