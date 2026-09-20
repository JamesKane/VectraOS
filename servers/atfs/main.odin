/*
atfs -- the AT network as conversations: `docs/WEB.md` section 7's AT
Protocol client, in `sys/libmsg`'s shape.

A timeline is a conversation. Its source written to `ctl` makes one of
its posts, each a message directory. A saved `getTimeline` answer's
path is read as it is, which is the offline proof, and a URL is fetched
through `webfs` at `/mnt/web`. The fetch runs on a thread of its own
and the write to `ctl` waits for it. A name not given is the URL's
host, or the file's name without its suffix. Fetching again refreshes:
a post already there is replaced by id.

    /mnt/at/ctl              fetch [name] url-or-path; fetch home; remove name;
                             fetch notifications [path]; record [name] uri-or-path;
                             login PDS HANDLE; oauth PDS HANDLE; code CODE;
                             account PDS HANDLE
    /mnt/at/me               the handle and the DID, once there is a session
    /mnt/at/new              a post out: replyto, an empty line, the text
    /mnt/at/event            `name/id` when a post lands
    /mnt/at/dict             the verbs above
    /mnt/at/<name>/<id>/     a post, `libmsg`'s files

A post is the message: the author's name and handle as `from`, the
record's `createdAt` as the date, its text as a plain body, its page on
the web and its images as links, and the record its reply names as
`replyto`. A post's name is its URI, which is no file name, so the id
carries sixteen hex digits of the URI's hash, and a reply resolves by
the same hash. `raw` is the feed item as the server sent it: the post,
and the reply and the reason beside it.

A record checks against its hash. The server names each post by its
CID, the hash of the record's DAG-CBOR, and `sys/libcid` makes the
bytes again from the JSON and hashes them. A record that checks is
served with its CID as `hash`, the network's own name for it. One that
does not is served with `hash` empty, and a line in `notify/` names
it.

`login.odin` is the account: a session on an app password, its token
in `factotum`, and `fetch home` then takes the account's timeline with
it. `oauth.odin` is the other way in, OAuth with PAR, PKCE and DPoP: a
token bound to a key `factotum` holds, and a proof it signs on every
request.

`post.odin` is a post written to `new`, a record put in the account's
repository, the answer into `home` and under `sent/` of the store `-s
DIR` names.

`fetch notifications` takes what came back, into `notify/`: a reply, a
mention, a quote, a like, a repost or a follow is a message from the
account that did it, its reason the subject, and the post it concerns
named by `replyto`. A post a notification carries lands in `home` too,
so a reply is a message under `replies/` of what it answered. A saved
answer's path is the offline proof. `record.odin` is a record by URI,
asked of the account's server and checked against its CID. Not yet:
an image on a post out.
*/
package atfs

import "base:runtime"
import "core:encoding/json"
import "vsys:abi"
import "vsys:lib9p"
import "vsys:libcid"
import "vsys:libmsg"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

MAX_CONVS :: 64
NAME_MAX :: 64
SOURCE_MAX :: libmsg.SOURCE_MAX

DICT :: "fetch name url       fetch a timeline by its URL or path into the conversation called name\nfetch home           fetch the account's timeline, with its token\nfetch notifications  fetch what came back into notify/, a saved answer's path or the account's\nrecord name uri      fetch a record by its URI into the conversation called name, checked against its CID\nremove name          empty a conversation\nlogin pds handle     a session on the app password factotum holds, its token kept by factotum\noauth pds handle     OAuth: a key in factotum, a pushed request, and the page to approve on\ncode code            trade the code the page sent back for a token bound to the key\naccount pds handle   an account whose token factotum holds already\nwrite: new           a post out: a replyto line, an empty line, the text\nread: <name>/<id>    a post: from, date, subject, body, type, raw, hash, replyto, links\n"

Source :: struct {
	text: [SOURCE_MAX]u8,
	len:  int,
}

Fetch :: struct {
	tag:    vectra9.Tag,
	count:  int,
	record: bool, // One record by URI, not a timeline
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
	why := libmsg.serve(&net, "/srv/at")
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

on_ctl :: proc(net: ^libmsg.Net, tag: vectra9.Tag, text: string) -> vectra9.Errno {
	line := text
	for len(line) > 0 && (line[len(line) - 1] == '\n' || line[len(line) - 1] == ' ') {
		line = line[:len(line) - 1]
	}
	verb, rest := word(line)
	switch verb {
	case "fetch", "record":
		a, b := word(rest)
		name, source := a, b
		if b == "" {
			source = a
			name = verb == "record" && libodin.has_prefix(a, "at://") ? "records" : libmsg.name_for(a)
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
		f.record = verb == "record"
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
		base, r2 := word(rest)
		user, _ := word(r2)
		return start_login(tag, len(text), base, user)
	case "oauth":
		base, r2 := word(rest)
		user, _ := word(r2)
		return start_oauth(tag, len(text), .Push, base, user)
	case "code":
		code, _ := word(rest)
		return start_oauth(tag, len(text), .Code, code, "")
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

// on_new puts the block in the account's repository, and refuses
// without a session.
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

// fetch reads the source, makes a message of each item of its `feed`,
// and puts them in their conversation. EINVAL for a source that is
// not a timeline.
fetch :: proc(f: ^Fetch) -> vectra9.Errno {
	if f.record {
		return fetch_record(f)
	}
	source := string(f.source[:f.slen])
	name := string(f.name[:f.nlen])
	text: []u8
	ok: bool
	urlbuf: [BASE_MAX + 64]u8
	if url := timeline_url(source, urlbuf[:]); url != "" {
		// The account's own timeline, with its token from factotum.
		status: int
		text, status, ok = as_account(f.io, "GET", url, "", "")
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
	if name == "notifications" {
		return take_notifications(text, source)
	}
	at := libmsg.array_at(string(text), "feed")
	if at < 0 {
		return vectra9.EINVAL
	}
	ranges, is_array := libmsg.elements(string(text), at)
	defer delete(ranges)
	if !is_array {
		return vectra9.EINVAL
	}
	c := libmsg.conv(&net, name)
	i := libmsg.conv_index(&net, name)
	got := 0
	for rg in ranges {
		raw := string(text[rg[0]:rg[1]])
		if m, made := item_message(raw); made {
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

// -- A post as a message ------------------------------------------------------

// item_message makes the message of one feed item's JSON, `{post, reply,
// reason}`. False for an item with no post, or one with no URI.
item_message :: proc(raw: string) -> (m: libmsg.Msg, ok: bool) {
	// The integers kept as integers, or a size would hash as a float.
	v, err := json.parse_string(raw, .JSON, true)
	if err != .None {
		json.destroy_value(v)
		return m, false
	}
	defer json.destroy_value(v)
	item, is_obj := v.(json.Object)
	if !is_obj {
		return m, false
	}
	post, has_post := libmsg.obj_of(item, "post")
	if !has_post {
		return m, false
	}
	return post_message(post, raw)
}

// post_message makes the message of a post's view: its URI, author and
// record, which a feed item holds under `post` and a notification holds
// at its top. `raw` is what the message keeps.
post_message :: proc(post: json.Object, raw: string) -> (m: libmsg.Msg, ok: bool) {
	uri := libmsg.str_of(post, "uri")
	if uri == "" {
		return m, false
	}
	record, _ := libmsg.obj_of(post, "record")
	m.date_text = clone(libmsg.str_of(record, "createdAt"))
	m.date, _ = libmsg.parse_date(m.date_text)
	idbuf: [128]u8
	m.id = clone(libmsg.make_id(m.date, uri, idbuf[:]))
	name := ""
	handle := ""
	if author, has := libmsg.obj_of(post, "author"); has {
		name = libmsg.str_of(author, "displayName")
		handle = libmsg.str_of(author, "handle")
	}
	from: [512]u8
	if name == "" {
		m.from = clone(handle)
	} else {
		m.from = clone(libuser.cat_into(from[:], name, " <", handle, ">"))
	}
	m.subject = ""
	m.body = clone(libmsg.str_of(record, "text"))
	m.type = clone("text/plain")
	if reply, has := libmsg.obj_of(record, "reply"); has {
		if parent, has_parent := libmsg.obj_of(reply, "parent"); has_parent {
			m.replyto = clone(libmsg.str_of(parent, "uri"))
		}
	}
	// Links: the post's page on the web, then its images full size.
	links := make([dynamic]u8, 0, 256)
	page: [256]u8
	put_link(&links, libuser.cat_into(page[:], "https://bsky.app/profile/", handle, "/post/", rkey_of(uri)))
	if embed, has := libmsg.obj_of(post, "embed"); has {
		if images, has_images := libmsg.arr_of(embed, "images"); has_images {
			for img in images {
				if io, is := img.(json.Object); is {
					put_link(&links, libmsg.str_of(io, "fullsize"))
				}
			}
		}
	}
	m.links = string(links[:])
	m.raw = clone(raw)
	// The record against its name: the CID the server gave is the hash
	// of the record's DAG-CBOR, or the record is not what it says.
	m.hash_own = true
	cid := libmsg.str_of(post, "cid")
	got, made := libcid.value_cid(record, m.hash[:])
	if made && got == cid {
		m.hash_len = len(got)
	} else {
		m.hash_len = 0
		note_failed(uri, m.date, m.date_text)
	}
	return m, true
}

// note_failed puts a line in notify/ for a record that failed its check:
// the URI as the body, under the post's own id.
note_failed :: proc(uri: string, date: i64, date_text: string) {
	n: libmsg.Msg
	idbuf: [128]u8
	n.id = clone(libmsg.make_id(date, uri, idbuf[:]))
	n.from = clone("atfs")
	n.date = date
	n.date_text = clone(date_text)
	n.subject = clone("a record failed its check")
	n.body = clone(uri)
	n.type = clone("text/plain")
	libmsg.add(&net, libmsg.conv(&net, "notify"), n)
}

/*
take_notifications puts each notification into notify/, and the post
one carries, a reply, a mention or a quote, into home. The notification
is a message from the account that did it: its reason as the subject,
the record's text as the body, and the post it concerns as replyto: the
carried post's own id, or the subject's.
*/
take_notifications :: proc(text: []u8, source: string) -> vectra9.Errno {
	at := libmsg.array_at(string(text), "notifications")
	if at < 0 {
		return vectra9.EINVAL
	}
	ranges, is_array := libmsg.elements(string(text), at)
	defer delete(ranges)
	if !is_array {
		return vectra9.EINVAL
	}
	notify := libmsg.conv(&net, "notify")
	home := libmsg.conv(&net, "home")
	got := 0
	for rg in ranges {
		raw := string(text[rg[0]:rg[1]])
		v, err := json.parse_string(raw, .JSON, true)
		if err != .None {
			json.destroy_value(v)
			continue
		}
		o, is_obj := v.(json.Object)
		if !is_obj {
			json.destroy_value(v)
			continue
		}
		uri := libmsg.str_of(o, "uri")
		reason := libmsg.str_of(o, "reason")
		if uri == "" || reason == "" {
			json.destroy_value(v)
			continue
		}
		record, _ := libmsg.obj_of(o, "record")
		n: libmsg.Msg
		n.date_text = clone(libmsg.str_of(record, "createdAt"))
		if n.date_text == "" {
			n.date_text = clone(libmsg.str_of(o, "indexedAt"))
		}
		n.date, _ = libmsg.parse_date(n.date_text)
		idbuf: [128]u8
		n.id = clone(libmsg.make_id(n.date, uri, idbuf[:]))
		name := ""
		handle := ""
		if author, has := libmsg.obj_of(o, "author"); has {
			name = libmsg.str_of(author, "displayName")
			handle = libmsg.str_of(author, "handle")
		}
		from: [512]u8
		n.from = clone(name == "" ? handle : libuser.cat_into(from[:], name, " <", handle, ">"))
		n.subject = clone(reason)
		n.body = clone(libmsg.str_of(record, "text"))
		n.type = clone("text/plain")
		n.raw = clone(raw)
		switch reason {
		case "reply", "mention", "quote":
			// The post itself, into home, and the notification names it.
			if m, made := post_message(o, raw); made {
				n.replyto = clone(m.id)
				links := make([dynamic]u8, 0, 128)
				put_link(&links, libuser.cat_into(from[:], "https://bsky.app/profile/", handle, "/post/", rkey_of(uri)))
				n.links = string(links[:])
				libmsg.add(&net, home, m)
			}
		case:
			// What it concerns, by the subject's URI: the post's id, when
			// home has it, else the URI's hash dated zero.
			if subject := libmsg.str_of(o, "reasonSubject"); subject != "" {
				n.replyto = clone(subject)
			}
		}
		json.destroy_value(v)
		libmsg.add(&net, notify, n)
		got += 1
	}
	resolve_replies(home)
	resolve_against(notify, home)
	if got == 0 && len(ranges) > 0 {
		return vectra9.EINVAL
	}
	i := libmsg.conv_index(&net, "notify")
	src := &sources[i]
	src.len = copy(src.text[:], source)
	rebuild_status()
	return 0
}

// resolve_against turns each `replyto` of `c` that still names a URI
// into the id of the post in `against` that bears it.
resolve_against :: proc(c: ^libmsg.Conv, against: ^libmsg.Conv) {
	for &m in c.msgs {
		if m.replyto == "" || (len(m.replyto) > 17 && m.replyto[16] == '.') {
			continue
		}
		idbuf: [128]u8
		zero := libmsg.make_id(0, m.replyto, idbuf[:])
		tail := zero[17:]
		found := ""
		for other in against.msgs {
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

// rkey_of answers the last element of an AT URI, the record's key.
rkey_of :: proc "contextless" (uri: string) -> string {
	for i := len(uri) - 1; i >= 0; i -= 1 {
		if uri[i] == '/' {
			return uri[i + 1:]
		}
	}
	return uri
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

// resolve_replies turns each `replyto` that still names a URI into the
// full id of the post that bears it, by the URI's hash, or leaves it
// dated zero.
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

// -- Small things ------------------------------------------------------------------

// as_account makes one request with the account's token: as Bearer, or
// bound to the key with a proof, the server's nonce carried back.
as_account :: proc(io: ^libthread.Ioproc, method: string, url: string, headers: string, body: string) -> (text: []u8, status: int, ok: bool) {
	tok: [256]u8
	token, has := ask_token(tok[:])
	if !has {
		return nil, 0, false
	}
	if account.dpop {
		return dpop_request(io, method, url, headers, body, token)
	}
	all: [1024]u8
	return libmsg.request(io, url, method, libuser.cat_into(all[:], headers, "Authorization: Bearer ", token, "\n"), body)
}

rebuild_status :: proc() {
	clear(&status)
	if oauth.set && oauth.alen > 0 {
		append(&status, ..transmute([]u8)string("authorize "))
		append(&status, ..oauth.auth[:oauth.alen])
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
