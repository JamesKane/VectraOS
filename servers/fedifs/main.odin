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

    /mnt/fedi/ctl              fetch [name] url-or-path; remove name
    /mnt/fedi/me               empty until a login
    /mnt/fedi/new              refused until a login
    /mnt/fedi/event            `name/id` when a status lands
    /mnt/fedi/dict             the verbs above
    /mnt/fedi/<name>/<id>/     a status, `libmsg`'s files

A status is the message: the account's name and address as `from`,
`created_at` as the date, the content warning as the subject, the
content as an HTML body, its URL and its attachments as links, and what
it answers as `replyto`. A boost is the boosted status under the
boost's id and date. The message's id is the instance's own, which is
digits, so a reply resolves by it. `raw` is the status as the instance
sent it. Not yet: the login, the account's own timelines and
notifications, a status written to `new`, and any object by URL.
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

DICT :: "fetch name url       fetch a timeline by its URL or path into the conversation called name\nremove name          empty a conversation\nread: <name>/<id>    a status: from, date, subject, body, type, raw, hash, replyto, links\n"

// What a conversation was fetched from, by its index among the network's.
Source :: struct {
	text: [SOURCE_MAX]u8,
	len:  int,
}

// One fetch in flight: the request held on `ctl`, and where it goes.
Fetch :: struct {
	tag:    vectra9.Tag,
	count:  int, // The write's byte count, answered when it is done
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
	case "fetch":
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
	}
	return vectra9.EINVAL
}

// on_new refuses until there is a login to post with.
on_new :: proc(net: ^libmsg.Net, tag: vectra9.Tag, text: string) -> vectra9.Errno {
	_, _, _ = net, tag, text
	return vectra9.EPERM
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
	source := string(f.source[:f.slen])
	name := string(f.name[:f.nlen])
	text, ok := libmsg.read_source(f.io, source)
	if !ok {
		return vectra9.EIO
	}
	defer delete(text)
	ranges, is_array := libmsg.elements(string(text))
	defer delete(ranges)
	if !is_array {
		return vectra9.EINVAL
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
