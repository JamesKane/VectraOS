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
named lands in the room. `seal.odin` is the seal: the device's keys
made and uploaded at login, a message out in an encrypted room sealed
by Megolm with the session's key shared by Olm first, and a sealed
event in opened with the session its key named. `-s DIR` names the
store, where `keys/matrix/` keeps the sessions that came. Not yet:
`join`, `leave`, `invite`, `members`, `typing`, the long poll behind
`event`, and the device requester.
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

// A room known: its id, the conversation it is, its members, and
// whether its messages are sealed.
Room :: struct {
	id:        [ROOM_ID_MAX]u8,
	ilen:      int,
	name:      [NAME_MAX]u8,
	nlen:      int,
	members:   [MAX_MEMBERS][NAME_MAX]u8,
	mlen:      [MAX_MEMBERS]int,
	nmembers:  int,
	encrypted: bool,
	out:       Megolm_Out, // Its outbound session, once a message has gone
}

// The store: `-s DIR`, where the keys that came are kept.
store: [256]u8
store_len: int

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
	why := libmsg.serve(&net, "/srv/matrix")
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

on_ctl :: proc(net: ^libmsg.Net, tag: vectra9.Tag, text: string) -> vectra9.Errno {
	verb, rest := libmsg.word(libodin.trim_space(text))
	switch verb {
	case "sync":
		path, _ := libmsg.word(rest)
		if path == "" && !account.set {
			return vectra9.EINVAL
		}
		return start_job(tag, len(text), .Sync, path, "")
	case "login":
		base, r2 := libmsg.word(rest)
		user, _ := libmsg.word(r2)
		if !libmsg.is_url(base) || len(base) > BASE_MAX || user == "" || len(user) > NAME_MAX {
			return vectra9.EINVAL
		}
		return start_job(tag, len(text), .Login, base, user)
	case "account":
		base, r2 := libmsg.word(rest)
		user, _ := libmsg.word(r2)
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
	j.text = libmsg.clone(text)
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
	libmsg.put(&body, "{\"type\": \"m.login.password\", \"identifier\": {\"type\": \"m.id.user\", \"user\": ")
	libmsg.put_json_string(&body, user)
	libmsg.put(&body, "}, \"password\": ")
	libmsg.put_json_string(&body, password)
	libmsg.put(&body, ", \"initial_device_display_name\": \"vectra\"}")
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
	if !libmsg.keep_token(user_id, host, token) {
		j.why = "factotum would not take the token"
		return vectra9.EIO
	}
	account = Account{set = true}
	account.blen = copy(account.base[:], base)
	account.ulen = copy(account.user[:], user_id)
	account.dlen = copy(account.device[:], device)
	// The device's keys, made now and uploaded signed.
	if !make_device() || !upload_keys(j.io) {
		j.why = "the device's keys would not upload"
		return vectra9.EIO
	}
	set_me()
	rebuild_status()
	return 0
}

set_me :: proc() {
	if !account.set {
		net.me = ""
		return
	}
	// A device, with its keys, is a login's; an account named has neither.
	if device.set {
		net.me = libuser.cat_into(me_text[:], string(account.user[:account.ulen]), "\ndevice ", string(account.device[:account.dlen]), "\ncurve25519 ", string(device.identity_b64[:device.ib64]), "\ned25519 ", string(device.sign_b64[:device.sb64]), "\n")
	} else {
		net.me = libuser.cat_into(me_text[:], string(account.user[:account.ulen]), "\n")
	}
}

// as_account makes one request with the account's token.
as_account :: proc(io: ^libthread.Ioproc, method: string, url: string, headers: string, body: string) -> (text: []u8, status: int, ok: bool) {
	tok: [256]u8
	token, has := libmsg.ask_token(string(account.user[:account.ulen]), libmsg.host_of(string(account.base[:account.blen])), tok[:])
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
		u := libuser.cat_into(url[:], string(account.base[:account.blen]), "/_matrix/client/v3/sync?timeout=0", account.balen > 0 ? "&since=" : "", string(account.batch[:account.balen]))
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
	// What came to this device first, so a key is known when its event is.
	take_to_device(top)
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
	name, named := room_name_of(id, room, name_buf[:])
	r := room_by_id(id)
	if r == nil {
		if nrooms >= MAX_ROOMS || len(id) > ROOM_ID_MAX {
			return
		}
		r = &rooms[nrooms]
		nrooms += 1
		r.ilen = copy(r.id[:], id)
		r.nlen = copy(r.name[:], name)
	} else if named {
		// A sync that repeats the room without its state keeps its name.
		r.nlen = copy(r.name[:], name)
	}
	take_state(r, room)
	c := libmsg.conv(&net, string(r.name[:r.nlen]))
	if timeline, has := libmsg.obj_of(room, "timeline"); has {
		if events, has_events := libmsg.arr_of(timeline, "events"); has_events {
			// Each event's own bytes, by its place in the array's text.
			ranges: [dynamic][2]int
			if at := timeline_at(text, id); at >= 0 {
				ranges, _ = libmsg.elements(text, at)
			}
			defer delete(ranges)
			for ev, k in events {
				e, is := ev.(json.Object)
				if !is {
					continue
				}
				raw := k < len(ranges) ? text[ranges[k][0]:ranges[k][1]] : ""
				if m, made := event_message(e, raw); made {
					libmsg.add(&net, c, m)
				}
			}
		}
	}
	libmsg.resolve_replies(c)
}

/*
timeline_at answers where a joined room's timeline events array begins
in the sync's text, or -1: the room's id as a key, `timeline` as a key
inside its object, `events` inside that. A room's id turns up only as
a key, so the first is the room.
*/
timeline_at :: proc(text: string, id: string) -> int {
	needle: [ROOM_ID_MAX + 2]u8
	at := key_at(text, libuser.cat_into(needle[:], "\"", id, "\""), 0, len(text))
	if at < 0 {
		return -1
	}
	end := libmsg.object_end(text, at)
	at = key_at(text, "\"timeline\"", at, end)
	if at < 0 {
		return -1
	}
	return key_at(text, "\"events\"", at, libmsg.object_end(text, at))
}

// key_at answers where the value of the member named `quoted` begins,
// looking between `from` and `to`, or -1.
key_at :: proc(text: string, quoted: string, from: int, to: int) -> int {
	i := libodin.index(text[from:to], quoted)
	if i < 0 {
		return -1
	}
	j := libmsg.skip_json_space(text, from + i + len(quoted))
	if j >= to || text[j] != ':' {
		return -1
	}
	return libmsg.skip_json_space(text, j + 1)
}

// take_state reads a room's state for its members and its seal.
take_state :: proc(r: ^Room, room: json.Object) {
	for key in ([?]string{"state", "timeline"}) {
		if part, has := libmsg.obj_of(room, key); has {
			if events, has_events := libmsg.arr_of(part, "events"); has_events {
				for ev in events {
					e, is := ev.(json.Object)
					if !is {
						continue
					}
					switch libmsg.str_of(e, "type") {
					case "m.room.encryption":
						r.encrypted = true
					case "m.room.member":
						content, has_content := libmsg.obj_of(e, "content")
						who := libmsg.str_of(e, "state_key")
						if !has_content || who == "" {
							continue
						}
						joined := libmsg.str_of(content, "membership") == "join"
						at := -1
						for i in 0 ..< r.nmembers {
							if string(r.members[i][:r.mlen[i]]) == who {
								at = i
								break
							}
						}
						if joined && at < 0 && r.nmembers < MAX_MEMBERS && len(who) <= NAME_MAX {
							r.mlen[r.nmembers] = copy(r.members[r.nmembers][:], who)
							r.nmembers += 1
						} else if !joined && at >= 0 {
							r.nmembers -= 1
							r.members[at] = r.members[r.nmembers]
							r.mlen[at] = r.mlen[r.nmembers]
						}
					}
				}
			}
		}
	}
}

// room_name_of answers a room's name off its state, and whether the
// state named it, or its id made plain: the `!` off and the `:` a `_`.
room_name_of :: proc(id: string, room: json.Object, into: []u8) -> (string, bool) {
	for key in ([?]string{"state", "invite_state"}) {
		if state, has := libmsg.obj_of(room, key); has {
			if events, has_events := libmsg.arr_of(state, "events"); has_events {
				for ev in events {
					if e, is := ev.(json.Object); is && libmsg.str_of(e, "type") == "m.room.name" {
						if content, has_content := libmsg.obj_of(e, "content"); has_content {
							if name := libmsg.str_of(content, "name"); name != "" {
								return libuser.cat_into(into, safe_name(name)), true
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
	return libuser.cat_into(into, safe_name(plain)), false
}

/*
event_message makes the message of a message event: the sender as
from, the server's time as the date, the body with the reply fallback
taken off, or the formatted body as HTML, an image's media as a link,
and what it replies to. `raw` is the event's own bytes out of the sync.
*/
event_message :: proc(e: json.Object, raw: string) -> (m: libmsg.Msg, ok: bool) {
	kind := libmsg.str_of(e, "type")
	if kind != "m.room.message" && kind != "m.room.encrypted" {
		return m, false
	}
	event_id := libmsg.str_of(e, "event_id")
	content, has_content := libmsg.obj_of(e, "content")
	if event_id == "" || !has_content {
		return m, false
	}
	// A sealed event opens into the event inside, whose content is the
	// message's; one that will not open is a message that says so.
	opened: json.Value
	defer json.destroy_value(opened)
	sealed_why := ""
	if kind == "m.room.encrypted" {
		plain, why := open_event(content)
		if plain != "" {
			ov, oerr := json.parse_string(plain, .JSON)
			delete(plain)
			if oerr == .None {
				opened = ov
				if oo, is := ov.(json.Object); is {
					if oc, has_oc := libmsg.obj_of(oo, "content"); has_oc {
						content = oc
					}
				}
			} else {
				json.destroy_value(ov)
				sealed_why = "(a sealed message that opened to no event)"
			}
		} else {
			sealed_why = why
		}
	}
	ms, _ := libmsg.int_of(e, "origin_server_ts")
	m.date = ms / 1000
	when_: [32]u8
	m.date_text = libmsg.clone(libmsg.format_3339(m.date, when_[:]))
	idbuf: [128]u8
	m.id = libmsg.clone(libmsg.make_id(m.date, event_id, idbuf[:]))
	m.from = libmsg.clone(libmsg.str_of(e, "sender"))
	body := libmsg.str_of(content, "body")
	formatted := libmsg.str_of(content, "formatted_body")
	msgtype := libmsg.str_of(content, "msgtype")
	if sealed_why != "" {
		m.body = libmsg.clone(sealed_why)
		m.type = libmsg.clone("text/plain")
	} else if formatted != "" && libmsg.str_of(content, "format") == "org.matrix.custom.html" {
		m.body = libmsg.clone(strip_mx_reply(formatted))
		m.type = libmsg.clone("text/html")
	} else {
		m.body = libmsg.clone(strip_reply_fallback(body))
		m.type = libmsg.clone("text/plain")
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
				libmsg.put_link(&links, libuser.cat_into(url[:], "https://", rest[:slash], "/_matrix/media/v3/download/", rest[:slash], "/", rest[slash + 1:]))
			}
		}
	}
	m.links = string(links[:])
	if rel, has := libmsg.obj_of(content, "m.relates_to"); has {
		if irt, has_irt := libmsg.obj_of(rel, "m.in_reply_to"); has_irt {
			m.replyto = libmsg.clone(libmsg.str_of(irt, "event_id"))
		}
	}
	m.raw = libmsg.clone(raw)
	return m, true
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
	name, _ := room_name_of(id, room, name_buf[:])
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
	n.id = libmsg.clone(libmsg.make_id(0, id, idbuf[:]))
	n.from = libmsg.clone(inviter)
	n.subject = libmsg.clone("invite")
	n.body = libmsg.clone(name)
	n.type = libmsg.clone("text/plain")
	n.raw = libmsg.clone(id)
	libmsg.add(&net, libmsg.conv(&net, "notify"), n)
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
	libmsg.put(&content, "{\"msgtype\": \"m.text\", \"body\": ")
	libmsg.put_json_string(&content, body)
	reply_id := ""
	if replyto, has := libmsg.new_header(&n, "replyto"); has && len(replyto) > 0 {
		i := libmsg.find(c, replyto)
		if i < 0 {
			return vectra9.ENOENT
		}
		reply_id = replyto
		// The event answered, by its id out of what the message kept.
		if eid := event_id_of(c.msgs[i].raw); eid != "" {
			libmsg.put(&content, ", \"m.relates_to\": {\"m.in_reply_to\": {\"event_id\": ")
			libmsg.put_json_string(&content, eid)
			libmsg.put(&content, "}}")
		}
	}
	libmsg.put(&content, "}")
	// In an encrypted room the event goes sealed, its key shared first.
	event_type := "m.room.message"
	wire := content
	sealed: [dynamic]u8
	defer delete(sealed)
	if r.encrypted {
		if !device.set {
			j.why = "the room is encrypted and this device has no keys: log in first"
			return vectra9.EPERM
		}
		sealed = make([dynamic]u8, 0, len(content) + 1024)
		if !seal_out(j.io, r, string(content[:]), &sealed) {
			j.why = "the message would not seal, or its key would not go to the members"
			return vectra9.EIO
		}
		event_type = "m.room.encrypted"
		wire = sealed
	}
	account.txn += 1
	num: [24]u8
	url: [BASE_MAX + ROOM_ID_MAX + 128]u8
	text, status, ok := as_account(j.io, "PUT", libuser.cat_into(url[:], string(account.base[:account.blen]), "/_matrix/client/v3/rooms/", string(r.id[:r.ilen]), "/send/", event_type, "/vectra", libuser.itoa(num[:], i64(account.txn))), "Content-Type: application/json\n", string(wire[:]))
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
	m.date_text = libmsg.clone(libmsg.format_3339(m.date, when_[:]))
	idbuf: [128]u8
	m.id = libmsg.clone(libmsg.make_id(m.date, event_id, idbuf[:]))
	m.from = libmsg.clone(string(account.user[:account.ulen]))
	m.body = libmsg.clone(body)
	m.type = libmsg.clone("text/plain")
	m.replyto = libmsg.clone(reply_id)
	// What the room keeps: the event as this side would see it come back.
	view := make([dynamic]u8, 0, len(content) + 256)
	libmsg.put(&view, "{\"type\": \"m.room.message\", \"event_id\": ")
	libmsg.put_json_string(&view, event_id)
	libmsg.put(&view, ", \"sender\": ")
	libmsg.put_json_string(&view, string(account.user[:account.ulen]))
	libmsg.put(&view, ", \"content\": ")
	append(&view, ..content[:])
	libmsg.put(&view, "}")
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
		if r.encrypted {
			append(&status, ..transmute([]u8)string(" sealed"))
		}
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
