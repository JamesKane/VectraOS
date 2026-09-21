/*
mentionfs -- the mentions a person's pages drew, as `docs/WEB.md`
section 4's shape: `docs/WEB.md` section 9's other end of the two-way
link. `httpd` verifies a Webmention and writes it as a file under a
store; this server reads that store and serves each mention as a
message, grouped by the page it is about, so a page of the person's own
has a `notify/`-like conversation and the reader's column shows who
wrote about it.

    /mnt/mention/ctl          reload; the store is read again
    /mnt/mention/me           empty: a mention knows nobody here
    /mnt/mention/new          refused: a mention comes from the wire
    /mnt/mention/<page>/<id>/ a mention: from the source, subject the
                              target page, body the source's title,
                              links the source URL

A mention file is `source`, `target` and `title` lines under
`<store>/mention/`. `-s DIR` names the store; `reload` reads it again,
so a mention `httpd` wrote after this started shows.
*/
package mentionfs

import "base:runtime"

import "vsys:abi"
import "vsys:libmsg"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

NAME_MAX :: 64
DICT :: "reload               read the store again, so a mention just written shows\nread: <page>/<id>    a mention: from the source, subject the target, body the source's title, links the source\n"

store: [256]u8
store_len: int

net: libmsg.Net
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
	load_store()
	rebuild_status()
	why := libmsg.serve(&net, "/srv/mention")
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

on_ctl :: proc(net: ^libmsg.Net, tag: vectra9.Tag, text: string) -> vectra9.Errno {
	_, _ = net, tag
	verb, _ := libmsg.word(libodin.trim_space(text))
	if verb == "reload" {
		load_store()
		rebuild_status()
		return 0
	}
	return vectra9.EINVAL
}

on_new :: proc(net: ^libmsg.Net, tag: vectra9.Tag, text: string) -> vectra9.Errno {
	_, _, _ = net, tag, text
	return vectra9.EPERM
}

/*
load_store reads every mention file under `<store>/mention/` and makes it
a message in the conversation named for its target page. A mention seen
before, by its id, is replaced.
*/
load_store :: proc() {
	if store_len == 0 {
		return
	}
	dir: [320]u8
	path := libuser.cat_into(dir[:], string(store[:store_len]), "/mention")
	names, ok := libuser.read_dir(path)
	if !ok {
		return
	}
	defer delete(names)
	for name in names {
		if name == "." || name == ".." {
			continue
		}
		full: [512]u8
		fp := libuser.cat_into(full[:], path, "/", name)
		data, dok := libuser.read_file(fp, context.allocator)
		if !dok {
			continue
		}
		take_mention(string(data), name)
		delete(data)
	}
}

// take_mention makes a message of one mention file's `source`, `target`
// and `title` lines, in the conversation named for the target's page.
take_mention :: proc(text: string, id: string) {
	source := field(text, "source")
	target := field(text, "target")
	title := field(text, "title")
	if source == "" || target == "" {
		return
	}
	page := page_of(target)
	m: libmsg.Msg
	m.date = libmsg.now_seconds()
	when_: [32]u8
	m.date_text = libmsg.clone(libmsg.format_3339(m.date, when_[:]))
	idbuf: [128]u8
	m.id = libmsg.clone(libmsg.make_id(m.date, id, idbuf[:]))
	m.from = libmsg.clone(source)
	m.subject = libmsg.clone(target)
	m.body = libmsg.clone(title == "" ? source : title)
	m.type = libmsg.clone("text/plain")
	m.raw = libmsg.clone(text)
	links := make([dynamic]u8, 0, len(source) + 1)
	libmsg.put(&links, source)
	m.links = string(links[:])
	libmsg.add(&net, libmsg.conv(&net, page), m)
}

// page_of answers the conversation a target URL is filed under: the last
// path element made a safe name, or `page` when there is none.
page_of :: proc "contextless" (target: string) -> string {
	@(static) buf: [NAME_MAX]u8
	// The path after the host, then its last element.
	s := target
	if i := libodin.index(s, "://"); i >= 0 {
		s = s[i + 3:]
	}
	last := s
	for i in 0 ..< len(s) {
		if s[i] == '/' && i + 1 < len(s) {
			last = s[i + 1:]
		}
	}
	// Its query and fragment off.
	for i in 0 ..< len(last) {
		if last[i] == '?' || last[i] == '#' {
			last = last[:i]
			break
		}
	}
	if last == "" || last == s {
		return "page"
	}
	n := 0
	for i in 0 ..< len(last) {
		if n >= len(buf) {
			break
		}
		c := last[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '.' || c == '_' || c == '-'
		buf[n] = ok ? c : '_'
		n += 1
	}
	return n == 0 ? "page" : string(buf[:n])
}

// field answers the value of a `name: value` line in a mention file, or "".
field :: proc "contextless" (text: string, name: string) -> string {
	at := 0
	for at < len(text) {
		e := at
		for e < len(text) && text[e] != '\n' {
			e += 1
		}
		line := text[at:e]
		if len(line) > len(name) + 1 && line[:len(name)] == name && line[len(name)] == ':' {
			v := line[len(name) + 1:]
			for len(v) > 0 && v[0] == ' ' {
				v = v[1:]
			}
			return v
		}
		at = e + 1
	}
	return ""
}

rebuild_status :: proc() {
	clear(&status)
	for c, i in net.convs {
		if i == 0 {
			continue
		}
		append(&status, ..transmute([]u8)string("page "))
		append(&status, ..transmute([]u8)c.name)
		append(&status, ' ')
		num: [24]u8
		append(&status, ..transmute([]u8)libuser.itoa(num[:], i64(len(c.msgs))))
		append(&status, '\n')
	}
	net.status = string(status[:])
}

