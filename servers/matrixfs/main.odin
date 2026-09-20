/*
matrixfs -- a person's rooms as conversations: `docs/WEB.md` section 8,
on the client-server API, in `sys/libmsg`'s shape.

A room is a conversation, named by the room's name or, unnamed, by its
id with the punctuation a name cannot hold made plain. A message event
is a message directory: the sender as `from`, the server's time as the
date, the body as a plain body with the reply fallback taken off, or
the formatted body as HTML, an image's media as a link, and what it
replies to as `replyto`, by the event id's hash. An invite is a line in
`notify/`. A sync is the source: a saved one's path, which is the
offline proof, or the account's, with its token from `factotum`.

    /mnt/matrix/ctl          sync [path]; login BASE USER; account BASE USER
    /mnt/matrix/me           the user id and the device id, once logged in
    /mnt/matrix/new          a message out: to <room>, replyto, an empty line, the body
    /mnt/matrix/notify/      an invite: from the inviter, the room's name the body
    /mnt/matrix/<room>/      the room, one message directory per event

`login BASE USER` sends the password `factotum` holds under
`proto=pass` for the user at the host, and the access token comes back
under `proto=oauth`, the way the networks keep theirs. `sync` is
`/sync` from the last batch, with the token. A write to `new` names a
room and puts the event with the token, and the event the server
named lands in the room. Not yet: the seal, `join`, `leave`, `invite`,
`members`, `typing`, and the long poll behind `event`.
*/
package matrixfs

import "base:runtime"
import "core:encoding/json"
import "vsys:abi"
import "vsys:lib9p"
import "vsys:libmsg"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

MAX_ROOMS :: 64
NAME_MAX :: 64
BASE_MAX :: 256
ROOM_ID_MAX :: 256

DICT :: "sync path            a saved sync's path into the rooms, or the account's sync with its token when no path is given\nlogin base user      log in at the server with the password factotum holds, the token kept by factotum\naccount base user    an account whose token factotum holds already\nwrite: new           a message out: a to line naming the room, a replyto line, an empty line, the body\nread: <room>/<id>    an event: from, date, subject, body, type, raw, hash, replyto, links\n"

// A room known: its id, and the conversation it is.
Room :: struct {
	id:   [ROOM_ID_MAX]u8,
	ilen: int,
	name: [NAME_MAX]u8,
	nlen: int,
}

Account :: struct {
	set:    bool,
	base:   [BASE_MAX]u8,
	blen:   int,
	user:   [NAME_MAX]u8, // The user id, `@user:host`
	ulen:   int,
	device: [64]u8,
	dlen:   int,
	batch:  [128]u8, // The last sync's next_batch
	balen:  int,
	txn:    int,
}

// One request on a thread: a sync, a login, or a message out.
Job :: struct {
	tag:   vectra9.Tag,
	count: int,
	io:    ^libthread.Ioproc,
	kind:  Job_Kind,
	arg:   [512]u8,
	alen:  int,
	arg2:  [NAME_MAX]u8,
	a2len: int,
	text:  string, // A message out: the block, owned
	why:   string,
}

Job_Kind :: enum u8 {
	Sync,
	Login,
	Send,
}

net: libmsg.Net
rooms: [MAX_ROOMS]Room
nrooms: int
account: Account
status: [dynamic]u8
me_text: [NAME_MAX + 80]u8

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = {}
	#force_no_inline runtime._startup_runtime()
	_ = libuser.args(block)
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
	why := libmsg.serve(&net, "/srv/matrix")
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

on_ctl :: proc(net: ^libmsg.Net, tag: vectra9.Tag, text: string) -> vectra9.Errno {
	line := text
	for len(line) > 0 && (line[len(line) - 1] == '\n' || line[len(line) - 1] == ' ') {
		line = line[:len(line) - 1]
	}
	verb, rest := word(line)
	switch verb {
	case "sync":
		path, _ := word(rest)
		if path == "" && !account.set {
			return vectra9.EINVAL
		}
		return start_job(tag, len(text), .Sync, path, "")
	case "login":
		base, r2 := word(rest)
		user, _ := word(r2)
		if !libmsg.is_url(base) || len(base) > BASE_MAX || user == "" || len(user) > NAME_MAX {
			return vectra9.EINVAL
		}
		return start_job(tag, len(text), .Login, base, user)
	case "account":
		base, r2 := word(rest)
		user, _ := word(r2)
		if !libmsg.is_url(base) || len(base) > BASE_MAX || user == "" || len(user) > NAME_MAX {
			return vectra9.EINVAL
		}
		account = Account{set = true}
		account.blen = copy(account.base[:], base)
		account.ulen = copy(account.user[:], user)
		set_me()
		rebuild_status()
		return 0
	}
	return vectra9.EINVAL
}

// on_new puts the block's message in the room it names, as the account.
on_new :: proc(net: ^libmsg.Net, tag: vectra9.Tag, text: string) -> vectra9.Errno {
	_ = net
	if !account.set {
		return vectra9.EPERM
	}
	n := libmsg.parse_new(text)
	defer libmsg.new_free(&n)
	if bad, has_bad := libmsg.new_unknown(&n); has_bad {
		libuser.eprint("matrixfs: new: no such header here: ", bad, "\n")
		return vectra9.EINVAL
	}
	to, has_to := libmsg.new_header(&n, "to")
	if !has_to || room_by_name(to) == nil || len(n.body) == 0 {
		return vectra9.ENOENT
	}
	j := new(Job)
	j.tag = tag
	j.count = len(text)
	j.kind = .Send
	j.text = clone(text)
	if libthread.threadcreate(job_thread, j, 256 * 1024) < 0 {
		delete(j.text)
		free(j)
		return vectra9.ENOSPC
	}
	lib9p.hold(&net.srv)
	return 0
}

start_job :: proc(tag: vectra9.Tag, count: int, kind: Job_Kind, arg: string, arg2: string) -> vectra9.Errno {
	if len(arg) > 511 {
		return vectra9.EINVAL
	}
	j := new(Job)
	j.tag = tag
	j.count = count
	j.kind = kind
	j.alen = copy(j.arg[:], arg)
	j.a2len = copy(j.arg2[:], arg2)
	if libthread.threadcreate(job_thread, j, 256 * 1024) < 0 {
		free(j)
		return vectra9.ENOSPC
	}
	lib9p.hold(&net.srv)
	return 0
}

job_thread :: proc "contextless" (arg: rawptr) {
	context = libuser.heap_context()
	j := (^Job)(arg)
	err := vectra9.Errno(0)
	j.io = libthread.ioproc()
	if j.io == nil {
		err = vectra9.EIO
	} else {
		switch j.kind {
		case .Sync:
			err = do_sync(j, string(j.arg[:j.alen]))
		case .Login:
			err = do_login(j, string(j.arg[:j.alen]), string(j.arg2[:j.a2len]))
		case .Send:
			err = do_send(j)
		}
		libthread.ioclose(j.io)
	}
	if err != 0 && j.why != "" {
		libuser.eprint("matrixfs: ", j.why, "\n")
	}
	if req := lib9p.find_held_tag(&net.srv, j.tag); req != nil {
		if err == 0 {
			_ = lib9p.respond(req, vectra9.Rwrite{count = u32(j.count)})
		} else {
			_ = lib9p.respond(req, vectra9.error_reply(err))
		}
	}
	delete(j.text)
	free(j)
	libthread.threadexits("")
}

// -- The login --------------------------------------------------------------------

// do_login sends the password factotum holds and keeps the token there.
do_login :: proc(j: ^Job, base: string, user: string) -> vectra9.Errno {
	host := libmsg.host_of(base)
	ask: [512]u8
	pw: [256]u8
	password, has := libmsg.factotum_ask(libuser.cat_into(ask[:], "start pass user=", user, " server=", host), "password ", pw[:])
	if !has {
		j.why = "factotum holds no password for that user and host"
		return vectra9.EPERM
	}
	body := make([dynamic]u8, 0, 512)
	defer delete(body)
	put(&body, "{\"type\": \"m.login.password\", \"identifier\": {\"type\": \"m.id.user\", \"user\": ")
	put_json_string(&body, user)
	put(&body, "}, \"password\": ")
	put_json_string(&body, password)
	put(&body, ", \"initial_device_display_name\": \"vectra\"}")
	url: [BASE_MAX + 64]u8
	text, status, ok := libmsg.request(j.io, libuser.cat_into(url[:], base, "/_matrix/client/v3/login"), "POST", "Content-Type: application/json\n", string(body[:]))
	defer delete(text)
	if !ok || status != 200 {
		j.why = "the server refused the login"
		return vectra9.EPERM
	}
	v, err := json.parse_string(string(text), .JSON)
	defer json.destroy_value(v)
	o, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		j.why = "the login's answer was not JSON"
		return vectra9.EIO
	}
	token := libmsg.str_of(o, "access_token")
	user_id := libmsg.str_of(o, "user_id")
	device := libmsg.str_of(o, "device_id")
	if token == "" || user_id == "" || len(token) > 128 || len(user_id) > NAME_MAX || len(device) > 63 {
		j.why = "the server answered no token"
		return vectra9.EIO
	}
	line: [512]u8
	if !libmsg.factotum_write(libuser.cat_into(line[:], "key proto=oauth user=", user_id, " server=", host, " !token=", token)) {
		j.why = "factotum would not take the token"
		return vectra9.EIO
	}
	account = Account{set = true}
	account.blen = copy(account.base[:], base)
	account.ulen = copy(account.user[:], user_id)
	account.dlen = copy(account.device[:], device)
	set_me()
	rebuild_status()
	return 0
}

set_me :: proc() {
	if !account.set {
		net.me = ""
		return
	}
	if account.dlen > 0 {
		net.me = libuser.cat_into(me_text[:], string(account.user[:account.ulen]), "\ndevice ", string(account.device[:account.dlen]), "\n")
	} else {
		net.me = libuser.cat_into(me_text[:], string(account.user[:account.ulen]), "\n")
	}
}

// as_account makes one request with the account's token.
as_account :: proc(io: ^libthread.Ioproc, method: string, url: string, headers: string, body: string) -> (text: []u8, status: int, ok: bool) {
	ask: [512]u8
	tok: [256]u8
	token, has := libmsg.factotum_ask(libuser.cat_into(ask[:], "start oauth user=", string(account.user[:account.ulen]), " server=", libmsg.host_of(string(account.base[:account.blen]))), "token ", tok[:])
	if !has {
		return nil, 0, false
	}
	all: [1024]u8
	return libmsg.request(io, url, method, libuser.cat_into(all[:], headers, "Authorization: Bearer ", token, "\n"), body)
}

// -- The sync ---------------------------------------------------------------------

// do_sync reads a sync, a saved one's path or the account's, and takes
// its rooms.
do_sync :: proc(j: ^Job, path: string) -> vectra9.Errno {
	text: []u8
	ok: bool
	if path != "" {
		text, ok = libmsg.read_source(j.io, path)
		if !ok {
			j.why = "the saved sync would not read"
			return vectra9.EIO
		}
	} else {
		url: [BASE_MAX + 256]u8
		u := account.balen > 0 ? libuser.cat_into(url[:], string(account.base[:account.blen]), "/_matrix/client/v3/sync?timeout=0&since=", string(account.batch[:account.balen])) : libuser.cat_into(url[:], string(account.base[:account.blen]), "/_matrix/client/v3/sync?timeout=0")
		status: int
		text, status, ok = as_account(j.io, "", u, "", "")
		if !ok {
			j.why = "factotum holds no token for the account, or the wire would not"
			return vectra9.EPERM
		}
		if status != 200 {
			delete(text)
			j.why = "the server refused the sync"
			return vectra9.EPERM
		}
	}
	defer delete(text)
	if !take_sync(string(text)) {
		j.why = "not a sync"
		return vectra9.EINVAL
	}
	rebuild_status()
	return 0
}

/*
take_sync takes a sync's rooms: each joined room's state names it and
its timeline's message events become its messages, and each invite is
a line in notify/. The next batch is kept for the sync after.
*/
take_sync :: proc(text: string) -> bool {
	v, err := json.parse_string(text, .JSON, true)
	defer json.destroy_value(v)
	top, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		return false
	}
	if nb := libmsg.str_of(top, "next_batch"); nb != "" && len(nb) < len(account.batch) {
		account.balen = copy(account.batch[:], nb)
	}
	rooms_obj, has_rooms := libmsg.obj_of(top, "rooms")
	if !has_rooms {
		return false
	}
	if join, has := libmsg.obj_of(rooms_obj, "join"); has {
		for id, rv in (map[string]json.Value)(join) {
			room, is := rv.(json.Object)
			if !is {
				continue
			}
			take_room(id, room, text)
		}
	}
	if invite, has := libmsg.obj_of(rooms_obj, "invite"); has {
		for id, rv in (map[string]json.Value)(invite) {
			room, is := rv.(json.Object)
			if !is {
				continue
			}
			take_invite(id, room)
		}
	}
	return true
}

// take_room names the room off its state and puts its timeline's
// message events in its conversation.
take_room :: proc(id: string, room: json.Object, text: string) {
	name_buf: [NAME_MAX]u8
	name := room_name_of(id, room, name_buf[:])
	r := room_by_id(id)
	if r == nil {
		if nrooms >= MAX_ROOMS || len(id) > ROOM_ID_MAX {
			return
		}
		r = &rooms[nrooms]
		nrooms += 1
		r.ilen = copy(r.id[:], id)
	}
	r.nlen = copy(r.name[:], name)
	c := libmsg.conv(&net, string(r.name[:r.nlen]))
	if timeline, has := libmsg.obj_of(room, "timeline"); has {
		if events, has_events := libmsg.arr_of(timeline, "events"); has_events {
			for ev in events {
				e, is := ev.(json.Object)
				if !is {
					continue
				}
				if m, made := event_message(e, text); made {
					libmsg.add(&net, c, m)
				}
			}
		}
	}
	resolve_replies(c)
}

// room_name_of answers a room's name off its state, or its id made
// plain: the `!` off and the `:` a `_`.
room_name_of :: proc(id: string, room: json.Object, into: []u8) -> string {
	for key in ([?]string{"state", "invite_state"}) {
		if state, has := libmsg.obj_of(room, key); has {
			if events, has_events := libmsg.arr_of(state, "events"); has_events {
				for ev in events {
					if e, is := ev.(json.Object); is && libmsg.str_of(e, "type") == "m.room.name" {
						if content, has_content := libmsg.obj_of(e, "content"); has_content {
							if name := libmsg.str_of(content, "name"); name != "" {
								return libuser.cat_into(into, safe_name(name))
							}
						}
					}
				}
			}
		}
	}
	plain := id
	if len(plain) > 0 && plain[0] == '!' {
		plain = plain[1:]
	}
	n := 0
	for i in 0 ..< len(plain) {
		if n >= len(into) {
			break
		}
		c := plain[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '-'
		into[n] = ok ? c : '_'
		n += 1
	}
	return string(into[:n])
}

/*
event_message makes the message of a message event: the sender as
from, the server's time as the date, the body with the reply fallback
taken off, or the formatted body as HTML, an image's media as a link,
and what it replies to. `raw` is the event's own bytes out of the sync.
*/
event_message :: proc(e: json.Object, text: string) -> (m: libmsg.Msg, ok: bool) {
	if libmsg.str_of(e, "type") != "m.room.message" {
		return m, false
	}
	event_id := libmsg.str_of(e, "event_id")
	content, has_content := libmsg.obj_of(e, "content")
	if event_id == "" || !has_content {
		return m, false
	}
	ms: i64 = 0
	if tsv, has := (map[string]json.Value)(e)["origin_server_ts"]; has {
		#partial switch t in tsv {
		case json.Integer:
			ms = i64(t)
		case json.Float:
			ms = i64(t)
		}
	}
	m.date = ms / 1000
	when_: [32]u8
	m.date_text = clone(libmsg.format_3339(m.date, when_[:]))
	idbuf: [128]u8
	m.id = clone(libmsg.make_id(m.date, event_id, idbuf[:]))
	m.from = clone(libmsg.str_of(e, "sender"))
	body := libmsg.str_of(content, "body")
	formatted := libmsg.str_of(content, "formatted_body")
	msgtype := libmsg.str_of(content, "msgtype")
	if formatted != "" && libmsg.str_of(content, "format") == "org.matrix.custom.html" {
		m.body = clone(strip_mx_reply(formatted))
		m.type = clone("text/html")
	} else {
		m.body = clone(strip_reply_fallback(body))
		m.type = clone("text/plain")
	}
	links := make([dynamic]u8, 0, 128)
	if msgtype == "m.image" || msgtype == "m.file" || msgtype == "m.video" || msgtype == "m.audio" {
		mxc := libmsg.str_of(content, "url")
		if len(mxc) > 6 && mxc[:6] == "mxc://" {
			// The media's download URL: the server and the id off the mxc URI.
			rest := mxc[6:]
			slash := 0
			for slash < len(rest) && rest[slash] != '/' {
				slash += 1
			}
			if slash < len(rest) {
				url: [512]u8
				put_link(&links, libuser.cat_into(url[:], "https://", rest[:slash], "/_matrix/media/v3/download/", rest[:slash], "/", rest[slash + 1:]))
			}
		}
	}
	m.links = string(links[:])
	if rel, has := libmsg.obj_of(content, "m.relates_to"); has {
		if irt, has_irt := libmsg.obj_of(rel, "m.in_reply_to"); has_irt {
			m.replyto = clone(libmsg.str_of(irt, "event_id"))
		}
	}
	// The event's own bytes, found by its id in the sync's text.
	m.raw = clone(event_bytes(text, event_id))
	return m, true
}

// event_bytes answers the object in `text` that holds `"event_id": ID`,
// or "" when it is not there.
event_bytes :: proc(text: string, event_id: string) -> string {
	needle: [300]u8
	n := libuser.cat_into(needle[:], "\"event_id\": \"", event_id, "\"")
	at := libodin_index(text, n)
	if at < 0 {
		return ""
	}
	// Back to the object's opening brace at depth one above the id.
	depth := 0
	start := -1
	for i := at; i >= 0; i -= 1 {
		c := text[i]
		if c == '}' {
			depth += 1
		} else if c == '{' {
			if depth == 0 {
				start = i
				break
			}
			depth -= 1
		}
	}
	if start < 0 {
		return ""
	}
	return text[start:object_end(text, start)]
}

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

// strip_reply_fallback takes the quoted lines a reply's plain body
// begins with off, up to the first empty line.
strip_reply_fallback :: proc "contextless" (body: string) -> string {
	if len(body) < 2 || body[:2] != "> " {
		return body
	}
	at := 0
	for at < len(body) {
		e := at
		for e < len(body) && body[e] != '\n' {
			e += 1
		}
		if e == at {
			return body[min(e + 1, len(body)):]
		}
		at = e + 1
	}
	return ""
}

// strip_mx_reply takes the `<mx-reply>...</mx-reply>` a reply's HTML
// begins with off.
strip_mx_reply :: proc "contextless" (html: string) -> string {
	if len(html) < 10 || html[:10] != "<mx-reply>" {
		return html
	}
	end := "</mx-reply>"
	for i in 0 ..< len(html) - len(end) + 1 {
		if html[i:i + len(end)] == end {
			return html[i + len(end):]
		}
	}
	return html
}

// take_invite puts an invite in notify/: from the inviter, the room's
// name as the body, under the room id's hash.
take_invite :: proc(id: string, room: json.Object) {
	name_buf: [NAME_MAX]u8
	name := room_name_of(id, room, name_buf[:])
	inviter := ""
	if state, has := libmsg.obj_of(room, "invite_state"); has {
		if events, has_events := libmsg.arr_of(state, "events"); has_events {
			for ev in events {
				if e, is := ev.(json.Object); is && libmsg.str_of(e, "type") == "m.room.member" {
					if content, has_content := libmsg.obj_of(e, "content"); has_content && libmsg.str_of(content, "membership") == "invite" {
						inviter = libmsg.str_of(e, "sender")
					}
				}
			}
		}
	}
	n: libmsg.Msg
	idbuf: [128]u8
	n.id = clone(libmsg.make_id(0, id, idbuf[:]))
	n.from = clone(inviter)
	n.subject = clone("invite")
	n.body = clone(name)
	n.type = clone("text/plain")
	n.raw = clone(id)
	libmsg.add(&net, libmsg.conv(&net, "notify"), n)
}

// resolve_replies turns each `replyto` that still names an event id
// into the id of the message that bears it, by the event id's hash.
resolve_replies :: proc(c: ^libmsg.Conv) {
	for &m in c.msgs {
		if m.replyto == "" || (len(m.replyto) > 17 && m.replyto[16] == '.') {
			continue
		}
		idbuf: [128]u8
		zero := libmsg.make_id(0, m.replyto, idbuf[:])
		tail := zero[17:]
		found := ""
		for other in c.msgs {
			if len(other.id) > 17 && other.id[17:] == tail {
				found = other.id
				break
			}
		}
		if found == "" {
			found = zero
		}
		delete(m.replyto)
		m.replyto = clone(found)
	}
}

// -- A message out --------------------------------------------------------------------

// do_send puts the block's message in its room with the token, and the
// event the server named lands in the room.
do_send :: proc(j: ^Job) -> vectra9.Errno {
	n := libmsg.parse_new(j.text)
	defer libmsg.new_free(&n)
	to, _ := libmsg.new_header(&n, "to")
	r := room_by_name(to)
	if r == nil {
		return vectra9.ENOENT
	}
	body := n.body
	for len(body) > 0 && (body[len(body) - 1] == '\n' || body[len(body) - 1] == '\r') {
		body = body[:len(body) - 1]
	}
	c := libmsg.conv(&net, string(r.name[:r.nlen]))
	content := make([dynamic]u8, 0, 512)
	defer delete(content)
	put(&content, "{\"msgtype\": \"m.text\", \"body\": ")
	put_json_string(&content, body)
	reply_id := ""
	if replyto, has := libmsg.new_header(&n, "replyto"); has && len(replyto) > 0 {
		i := libmsg.find(c, replyto)
		if i < 0 {
			return vectra9.ENOENT
		}
		reply_id = replyto
		// The event answered, by its id out of what the message kept.
		if eid := event_id_of(c.msgs[i].raw); eid != "" {
			put(&content, ", \"m.relates_to\": {\"m.in_reply_to\": {\"event_id\": ")
			put_json_string(&content, eid)
			put(&content, "}}")
		}
	}
	put(&content, "}")
	account.txn += 1
	num: [24]u8
	url: [BASE_MAX + ROOM_ID_MAX + 128]u8
	text, status, ok := as_account(j.io, "PUT", libuser.cat_into(url[:], string(account.base[:account.blen]), "/_matrix/client/v3/rooms/", string(r.id[:r.ilen]), "/send/m.room.message/vectra", libuser.itoa(num[:], i64(account.txn))), "Content-Type: application/json\n", string(content[:]))
	defer delete(text)
	if !ok {
		j.why = "factotum holds no token for the account, or the wire would not"
		return vectra9.EPERM
	}
	if status != 200 {
		j.why = "the server would not take the message"
		return vectra9.EIO
	}
	v, err := json.parse_string(string(text), .JSON)
	defer json.destroy_value(v)
	o, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		j.why = "the server's answer was not JSON"
		return vectra9.EIO
	}
	event_id := libmsg.str_of(o, "event_id")
	if event_id == "" {
		j.why = "the server named no event"
		return vectra9.EIO
	}
	m: libmsg.Msg
	m.date = libmsg.now_seconds()
	when_: [32]u8
	m.date_text = clone(libmsg.format_3339(m.date, when_[:]))
	idbuf: [128]u8
	m.id = clone(libmsg.make_id(m.date, event_id, idbuf[:]))
	m.from = clone(string(account.user[:account.ulen]))
	m.body = clone(body)
	m.type = clone("text/plain")
	m.replyto = clone(reply_id)
	// What the room keeps: the event as this side would see it come back.
	view := make([dynamic]u8, 0, len(content) + 256)
	put(&view, "{\"type\": \"m.room.message\", \"event_id\": ")
	put_json_string(&view, event_id)
	put(&view, ", \"sender\": ")
	put_json_string(&view, string(account.user[:account.ulen]))
	put(&view, ", \"content\": ")
	append(&view, ..content[:])
	put(&view, "}")
	m.raw = string(view[:])
	libmsg.add(&net, c, m)
	rebuild_status()
	return 0
}

// event_id_of answers the event id out of an event's bytes.
event_id_of :: proc(raw: string) -> string {
	@(static) keep: [256]u8
	v, err := json.parse_string(raw, .JSON)
	defer json.destroy_value(v)
	o, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		return ""
	}
	n := copy(keep[:], libmsg.str_of(o, "event_id"))
	return string(keep[:n])
}

// -- Small things ------------------------------------------------------------------

room_by_id :: proc "contextless" (id: string) -> ^Room {
	for i in 0 ..< nrooms {
		if string(rooms[i].id[:rooms[i].ilen]) == id {
			return &rooms[i]
		}
	}
	return nil
}

room_by_name :: proc "contextless" (name: string) -> ^Room {
	for i in 0 ..< nrooms {
		if string(rooms[i].name[:rooms[i].nlen]) == name {
			return &rooms[i]
		}
	}
	return nil
}

rebuild_status :: proc() {
	clear(&status)
	if account.set {
		append(&status, ..transmute([]u8)string("account "))
		append(&status, ..account.base[:account.blen])
		append(&status, ' ')
		append(&status, ..account.user[:account.ulen])
		append(&status, '\n')
	}
	for i in 0 ..< nrooms {
		r := &rooms[i]
		append(&status, ..transmute([]u8)string("room "))
		append(&status, ..r.name[:r.nlen])
		append(&status, ' ')
		append(&status, ..r.id[:r.ilen])
		append(&status, '\n')
	}
	net.status = string(status[:])
}

safe_name :: proc "contextless" (s: string) -> string {
	@(static) buf: [NAME_MAX]u8
	n := 0
	for i in 0 ..< len(s) {
		if n >= len(buf) {
			break
		}
		c := s[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'
		buf[n] = ok ? c : '_'
		n += 1
	}
	return string(buf[:n])
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

put :: proc(out: ^[dynamic]u8, s: string) {
	append(out, ..transmute([]u8)s)
}

put_json_string :: proc(out: ^[dynamic]u8, s: string) {
	hex := "0123456789abcdef"
	append(out, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"':
			append(out, '\\', '"')
		case '\\':
			append(out, '\\', '\\')
		case '\n':
			append(out, '\\', 'n')
		case '\r':
			append(out, '\\', 'r')
		case '\t':
			append(out, '\\', 't')
		case:
			if c < 0x20 {
				append(out, '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15])
			} else {
				append(out, c)
			}
		}
	}
	append(out, '"')
}

libodin_index :: proc "contextless" (s: string, want: string) -> int {
	if len(want) == 0 || len(s) < len(want) {
		return -1
	}
	for i in 0 ..< len(s) - len(want) + 1 {
		if s[i:i + len(want)] == want {
			return i
		}
	}
	return -1
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

_ :: libodin
