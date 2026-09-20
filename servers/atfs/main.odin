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

    /mnt/at/ctl              fetch [name] url-or-path; remove name
    /mnt/at/me               empty until a login
    /mnt/at/new              refused until a login
    /mnt/at/event            `name/id` when a post lands
    /mnt/at/dict             the verbs above
    /mnt/at/<name>/<id>/     a post, `libmsg`'s files

A post is the message: the author's name and handle as `from`, the
record's `createdAt` as the date, its text as a plain body, its page on
the web and its images as links, and the record its reply names as
`replyto`. A post's name is its URI, which is no file name, so the id
carries sixteen hex digits of the URI's hash, and a reply resolves by
the same hash. `raw` is the feed item as the server sent it: the post,
and the reply and the reason beside it. Not yet: the login, the
account's own timelines and notifications, a post written to `new`,
a record by URI, and the CID a record checks against.
*/
package atfs

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

DICT :: "fetch name url       fetch a timeline by its URL or path into the conversation called name\nremove name          empty a conversation\nread: <name>/<id>    a post: from, date, subject, body, type, raw, hash, replyto, links\n"

Source :: struct {
	text: [SOURCE_MAX]u8,
	len:  int,
}

Fetch :: struct {
	tag:    vectra9.Tag,
	count:  int,
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

// fetch reads the source, makes a message of each item of its `feed`,
// and puts them in their conversation. EINVAL for a source that is
// not a timeline.
fetch :: proc(f: ^Fetch) -> vectra9.Errno {
	source := string(f.source[:f.slen])
	name := string(f.name[:f.nlen])
	text, ok := libmsg.read_source(f.io, source)
	if !ok {
		return vectra9.EIO
	}
	defer delete(text)
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
	v, err := json.parse_string(raw, .JSON)
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
	return m, true
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
