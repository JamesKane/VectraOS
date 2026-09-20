/*
fedifs -- the fediverse as conversations: `docs/WEB.md` section 7's
Mastodon client, in `sys/libmsg`'s shape.

A timeline is a conversation. Its source written to `ctl` makes one of
its statuses, each a message directory, so a home timeline reads like a
mailbox or a feed. A saved timeline's path is read as it is, which is
the offline proof, and a URL is fetched through `webfs` at `/mnt/web`.
The fetch runs on a thread of its own and the write to `ctl` waits for
it, so `echo fetch URL > ctl` returns when the statuses are there or
says why not. A name not given is the URL's host, or the file's name
without its suffix. Fetching again refreshes: a status already there is
replaced by id.

    /mnt/fedi/ctl              fetch [name] url-or-path; fetch home; remove name;
                               fetch notifications [path]; object [name] url-or-path;
                               login BASE; code CODE; account BASE USER
    /mnt/fedi/me               the account, once there is one
    /mnt/fedi/new              a status out: subject, replyto, an empty line, the body
    /mnt/fedi/event            `name/id` when a status lands
    /mnt/fedi/dict             the verbs above
    /mnt/fedi/<name>/<id>/     a status, `libmsg`'s files

A status is the message: the account's name and address as `from`,
`created_at` as the date, the content warning as the subject, the
content as an HTML body, its URL and its attachments as links, and what
it answers as `replyto`. A boost is the boosted status under the
boost's id and date. The message's id is the instance's own, which is
digits, so a reply resolves by it. `raw` is the status as the instance
sent it.

`login.odin` is the account: the authorization code flow that ends
with a token in `factotum`, and `fetch home` then takes the account's
home timeline with it.

`post.odin` is a status written to `new`, posted as the account, the
answer into `home` and under `sent/` of the store `-s DIR` names.

`fetch notifications` takes what came back, into `notify/`: a mention,
a favourite, a boost or a follow is a message from the account that
did it, its kind the subject, and the status it concerns named by
`replyto`. A status a notification carries lands in `home` too, so a
reply is a message under `replies/` of what it answered. A saved
answer's path is the offline proof. `object.odin` is any object by
URL, an actor or a note anywhere, as a message. Not yet: an attachment
on a status out.
*/
package fedifs

import "base:runtime"
import "core:encoding/json"
import "vsys:abi"
import "vsys:lib9p"
import "vsys:libmsg"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

MAX_CONVS :: 64
NAME_MAX :: 64
SOURCE_MAX :: libmsg.SOURCE_MAX

DICT :: "fetch name url       fetch a timeline by its URL or path into the conversation called name\nfetch home           fetch the account's home timeline, with its token\nfetch notifications  fetch what came back into notify/, a saved answer's path or the account's\nobject name url      fetch any actor or object in the fediverse by its URL into the conversation called name\nremove name          empty a conversation\nlogin base           register with the instance at base, and show the page to approve on\ncode code            trade the code the page showed for a token, kept by factotum\naccount base user    an account whose token factotum holds already\nwrite: new           a status out: subject, replyto lines, an empty line, the body\nread: <name>/<id>    a status: from, date, subject, body, type, raw, hash, replyto, links\n"

// What a conversation was fetched from, by its index among the network's.
Source :: struct {
	text: [SOURCE_MAX]u8,
	len:  int,
}

// One fetch in flight: the request held on `ctl`, and where it goes.
Fetch :: struct {
	tag:    vectra9.Tag,
	count:  int, // The write's byte count, answered when it is done
	object: bool, // One object by URL, not a timeline
	name:   [NAME_MAX]u8,
	nlen:   int,
	source: [SOURCE_MAX]u8,
	slen:   int,
	io:     ^libthread.Ioproc,
}

net: libmsg.Net
sources: [MAX_CONVS]Source
status: [dynamic]u8

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = {}
	#force_no_inline runtime._startup_runtime()
	args := libuser.args(block)
	for i := 1; i + 1 < len(args); i += 1 {
		if args[i] == "-s" {
			store_len = copy(store[:], args[i + 1])
		}
	}
	libthread.main(threadmain, nil)
}

threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = libuser.heap_context()
	libmsg.init(&net)
	net.dict = DICT
	net.on_ctl = on_ctl
	net.on_new = on_new
	status = make([dynamic]u8, 0, 256)
	why := libmsg.serve(&net, "/srv/fedi")
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

// on_ctl takes `fetch [name] source` and `remove name`. A fetch holds the
// write and starts a thread that answers it.
on_ctl :: proc(net: ^libmsg.Net, tag: vectra9.Tag, text: string) -> vectra9.Errno {
	line := text
	for len(line) > 0 && (line[len(line) - 1] == '\n' || line[len(line) - 1] == ' ') {
		line = line[:len(line) - 1]
	}
	verb, rest := word(line)
	switch verb {
	case "fetch", "object":
		a, b := word(rest)
		name, source := a, b
		if b == "" {
			source = a
			name = libmsg.name_for(a)
		}
		if name == "" || source == "" || !libmsg.is_name(name) || len(name) > NAME_MAX || len(source) > SOURCE_MAX {
			return vectra9.EINVAL
		}
		if libmsg.conv_index(net, name) < 0 && len(net.convs) >= MAX_CONVS {
			return vectra9.ENOSPC
		}
		f := new(Fetch)
		f.tag = tag
		f.count = len(text)
		f.object = verb == "object"
		f.nlen = copy(f.name[:], name)
		f.slen = copy(f.source[:], source)
		if libthread.threadcreate(fetch_thread, f, 256 * 1024) < 0 {
			free(f)
			return vectra9.ENOSPC
		}
		lib9p.hold(&net.srv)
		return 0
	case "remove":
		name, _ := word(rest)
		i := libmsg.conv_index(net, name)
		if i < 0 || name == "notify" {
			return vectra9.ENOENT
		}
		libmsg.conv_clear(&net.convs[i])
		rebuild_status()
		return 0
	case "login":
		base, _ := word(rest)
		return start_login(tag, len(text), .Register, base)
	case "code":
		code, _ := word(rest)
		return start_login(tag, len(text), .Code, code)
	case "account":
		base, r2 := word(rest)
		user, _ := word(r2)
		if !set_account(base, user) {
			return vectra9.EINVAL
		}
		rebuild_status()
		return 0
	}
	return vectra9.EINVAL
}

// on_new posts the block as the account, and refuses without one.
on_new :: proc(net: ^libmsg.Net, tag: vectra9.Tag, text: string) -> vectra9.Errno {
	_ = net
	return start_post(tag, text)
}

fetch_thread :: proc "contextless" (arg: rawptr) {
	context = libuser.heap_context()
	f := (^Fetch)(arg)
	err := vectra9.Errno(0)
	f.io = libthread.ioproc()
	if f.io == nil {
		err = vectra9.EIO
	} else {
		err = fetch(f)
		libthread.ioclose(f.io)
	}
	if req := lib9p.find_held_tag(&net.srv, f.tag); req != nil {
		if err == 0 {
			_ = lib9p.respond(req, vectra9.Rwrite{count = u32(f.count)})
		} else {
			_ = lib9p.respond(req, vectra9.error_reply(err))
		}
	}
	free(f)
	libthread.threadexits("")
}

// fetch reads the source, makes a message of each status, and puts them
// in their conversation. EINVAL for a source that is not a timeline.
fetch :: proc(f: ^Fetch) -> vectra9.Errno {
	if f.object {
		return fetch_object(f)
	}
	source := string(f.source[:f.slen])
	name := string(f.name[:f.nlen])
	text: []u8
	ok: bool
	urlbuf: [BASE_MAX + 64]u8
	if url := timeline_url(source, urlbuf[:]); url != "" {
		// The account's own timeline, with its token from factotum.
		tok: [256]u8
		token, has := ask_token(tok[:])
		if !has {
			return vectra9.EPERM
		}
		auth: [300]u8
		status: int
		text, status, ok = libmsg.request(f.io, url, "", libuser.cat_into(auth[:], "Authorization: Bearer ", token, "\n"), "")
		if ok && status != 200 {
			delete(text)
			return vectra9.EPERM
		}
	} else {
		text, ok = libmsg.read_source(f.io, source)
	}
	if !ok {
		return vectra9.EIO
	}
	defer delete(text)
	ranges, is_array := libmsg.elements(string(text))
	defer delete(ranges)
	if !is_array {
		return vectra9.EINVAL
	}
	if name == "notifications" {
		return take_notifications(text, ranges[:], source)
	}
	c := libmsg.conv(&net, name)
	i := libmsg.conv_index(&net, name)
	got := 0
	for rg in ranges {
		raw := string(text[rg[0]:rg[1]])
		if m, made := status_message(raw); made {
			libmsg.add(&net, c, m)
			got += 1
		}
	}
	if got == 0 && len(ranges) > 0 {
		return vectra9.EINVAL
	}
	resolve_replies(c)
	src := &sources[i]
	src.len = copy(src.text[:], source)
	rebuild_status()
	return 0
}

// -- Notifications ----------------------------------------------------------------

/*
take_notifications puts each notification into notify/, and the status
one carries into home. The notification is a message from the account
that did it: its kind as the subject, the status's content as the body,
and the status's id as replyto, so a reader finds what it concerns.
*/
take_notifications :: proc(text: []u8, ranges: [][2]int, source: string) -> vectra9.Errno {
	notify := libmsg.conv(&net, "notify")
	home := libmsg.conv(&net, "home")
	got := 0
	for rg in ranges {
		raw := string(text[rg[0]:rg[1]])
		v, err := json.parse_string(raw, .JSON)
		if err != .None {
			json.destroy_value(v)
			continue
		}
		o, is_obj := v.(json.Object)
		if !is_obj {
			json.destroy_value(v)
			continue
		}
		id := libmsg.str_of(o, "id")
		kind := libmsg.str_of(o, "type")
		if id == "" || kind == "" {
			json.destroy_value(v)
			continue
		}
		n: libmsg.Msg
		n.date_text = clone(libmsg.str_of(o, "created_at"))
		n.date, _ = libmsg.parse_date(n.date_text)
		idbuf: [128]u8
		n.id = clone(libmsg.make_id(n.date, id, idbuf[:]))
		n.from = clone(actor_of(o))
		n.subject = clone(kind)
		n.type = clone("text/html")
		n.raw = clone(raw)
		// The status it carries: into home, and named by replyto.
		if status, has := libmsg.obj_of(o, "status"); has {
			sid := libmsg.str_of(status, "id")
			sdate, _ := libmsg.parse_date(libmsg.str_of(status, "created_at"))
			n.replyto = clone(libmsg.make_id(sdate, sid, idbuf[:]))
			n.body = clone(libmsg.str_of(status, "content"))
			links := make([dynamic]u8, 0, 128)
			put_link(&links, libmsg.str_of(status, "url"))
			n.links = string(links[:])
			if at := libmsg.array_at(raw, "status"); at < 0 {
				// The status's own bytes are the object under "status".
				if s_at := object_at(raw, "status"); s_at >= 0 {
					if m, made := status_message(raw[s_at:object_end(raw, s_at)]); made {
						libmsg.add(&net, home, m)
					}
				}
			}
		}
		json.destroy_value(v)
		libmsg.add(&net, notify, n)
		got += 1
	}
	resolve_replies(home)
	if got == 0 && len(ranges) > 0 {
		return vectra9.EINVAL
	}
	i := libmsg.conv_index(&net, "notify")
	src := &sources[i]
	src.len = copy(src.text[:], source)
	rebuild_status()
	return 0
}

// actor_of answers the account a notification came from, as `from`.
actor_of :: proc(o: json.Object) -> string {
	@(static) buf: [512]u8
	name := ""
	handle := ""
	if acct, has := libmsg.obj_of(o, "account"); has {
		name = libmsg.str_of(acct, "display_name")
		handle = libmsg.str_of(acct, "acct")
	}
	if name == "" {
		return handle
	}
	return libuser.cat_into(buf[:], name, " <", handle, ">")
}

// object_at answers where the object under the top-level key `key`
// begins in `text`, its `{`, or -1.
object_at :: proc(text: string, key: string) -> int {
	depth := 0
	in_string := false
	i := 0
	for i < len(text) {
		c := text[i]
		if in_string {
			if c == '\\' {
				i += 1
			} else if c == '"' {
				in_string = false
			}
			i += 1
			continue
		}
		switch c {
		case '"':
			if depth == 1 && i + len(key) + 1 < len(text) && text[i + 1:i + 1 + len(key)] == key && text[i + 1 + len(key)] == '"' {
				j := i + len(key) + 2
				for j < len(text) && (text[j] == ' ' || text[j] == ':' || text[j] == '\n' || text[j] == '\r' || text[j] == '\t') {
					j += 1
				}
				if j < len(text) && text[j] == '{' {
					return j
				}
			}
			in_string = true
		case '[', '{':
			depth += 1
		case ']', '}':
			depth -= 1
		}
		i += 1
	}
	return -1
}

// object_end answers where the object beginning at `at` ends, one past
// its closing brace.
object_end :: proc(text: string, at: int) -> int {
	depth := 0
	in_string := false
	for i := at; i < len(text); i += 1 {
		c := text[i]
		if in_string {
			if c == '\\' {
				i += 1
			} else if c == '"' {
				in_string = false
			}
			continue
		}
		switch c {
		case '"':
			in_string = true
		case '{', '[':
			depth += 1
		case '}', ']':
			depth -= 1
			if depth == 0 {
				return i + 1
			}
		}
	}
	return len(text)
}

// -- A status as a message ------------------------------------------------------

/*
status_message makes the message of one status's JSON. A boost, `reblog`
an object, is the boosted status under the boost's id and date. False
for JSON that is not a status: no id, or not an object.
*/
status_message :: proc(raw: string) -> (m: libmsg.Msg, ok: bool) {
	v, err := json.parse_string(raw, .JSON)
	if err != .None {
		json.destroy_value(v)
		return m, false
	}
	defer json.destroy_value(v)
	o, is_obj := v.(json.Object)
	if !is_obj {
		return m, false
	}
	id := libmsg.str_of(o, "id")
	if id == "" {
		return m, false
	}
	inner := o
	if rb, has := libmsg.obj_of(o, "reblog"); has {
		inner = rb
	}
	m.date_text = clone(libmsg.str_of(o, "created_at"))
	m.date, _ = libmsg.parse_date(m.date_text)
	idbuf: [128]u8
	m.id = clone(libmsg.make_id(m.date, id, idbuf[:]))
	// From: the display name and the address, or the address alone.
	name := ""
	handle := ""
	if acct, has := libmsg.obj_of(inner, "account"); has {
		name = libmsg.str_of(acct, "display_name")
		handle = libmsg.str_of(acct, "acct")
	}
	from: [512]u8
	if name == "" {
		m.from = clone(handle)
	} else {
		m.from = clone(libuser.cat_into(from[:], name, " <", handle, ">"))
	}
	m.subject = clone(libmsg.str_of(inner, "spoiler_text"))
	m.body = clone(libmsg.str_of(inner, "content"))
	m.type = clone("text/html")
	m.replyto = clone(libmsg.str_of(o, "in_reply_to_id"))
	// Links: the status's URL, its attachments, and its card.
	links := make([dynamic]u8, 0, 256)
	put_link(&links, libmsg.str_of(inner, "url"))
	if media, has := libmsg.arr_of(inner, "media_attachments"); has {
		for item in media {
			if mo, is := item.(json.Object); is {
				put_link(&links, libmsg.str_of(mo, "url"))
			}
		}
	}
	if card, has := libmsg.obj_of(inner, "card"); has {
		put_link(&links, libmsg.str_of(card, "url"))
	}
	m.links = string(links[:])
	m.raw = clone(raw)
	return m, true
}

put_link :: proc(links: ^[dynamic]u8, url: string) {
	if url == "" {
		return
	}
	if len(links) > 0 {
		append(links, '\n')
	}
	append(links, ..transmute([]u8)url)
}

// resolve_replies turns each `replyto` that names a status by the
// instance's id into the full id of the message that bears it, or leaves
// it dated zero, the way mail and feeds do.
resolve_replies :: proc(c: ^libmsg.Conv) {
	for &m in c.msgs {
		if m.replyto == "" || (len(m.replyto) > 17 && m.replyto[16] == '.') {
			continue
		}
		found := ""
		for other in c.msgs {
			if len(other.id) > 17 && other.id[17:] == m.replyto {
				found = other.id
				break
			}
		}
		idbuf: [128]u8
		if found == "" {
			found = libmsg.make_id(0, m.replyto, idbuf[:])
		}
		delete(m.replyto)
		m.replyto = clone(found)
	}
}

// -- Small things ------------------------------------------------------------------

// rebuild_status writes what a read of `ctl` answers: a line a
// conversation, its name, how many statuses, and its source.
rebuild_status :: proc() {
	clear(&status)
	if account.alen > 0 && !account.set {
		append(&status, ..transmute([]u8)string("authorize "))
		append(&status, ..account.authorize[:account.alen])
		append(&status, '\n')
	}
	if account.set {
		append(&status, ..transmute([]u8)string("account "))
		append(&status, ..account.base[:account.blen])
		append(&status, ' ')
		append(&status, ..account.user[:account.ulen])
		append(&status, '\n')
	}
	for c, i in net.convs {
		if i == 0 || sources[i].len == 0 {
			continue
		}
		append(&status, ..transmute([]u8)c.name)
		append(&status, ' ')
		num: [24]u8
		append(&status, ..transmute([]u8)libuser.itoa(num[:], i64(len(c.msgs))))
		append(&status, ' ')
		append(&status, ..sources[i].text[:sources[i].len])
		append(&status, '\n')
	}
	net.status = string(status[:])
}

clone :: proc(s: string) -> string {
	if len(s) == 0 {
		return ""
	}
	own := make([]u8, len(s))
	copy(own, s)
	return string(own)
}

word :: proc "contextless" (s: string) -> (first: string, rest: string) {
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
