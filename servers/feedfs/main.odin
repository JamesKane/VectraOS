/*
feedfs -- a feed is a conversation, and this is the first network.

`docs/WEB.md` section 4. A feed's URL written to `ctl` makes a
conversation of its entries, each a message directory in `sys/libmsg`'s
shape, so a feed reads like a mailbox or a room. It is the smallest
network there is, and it needs no login, which is why it comes first.

    /mnt/feed/ctl              fetch [name] url-or-path; remove name; poll seconds
    /mnt/feed/me               empty: a feed knows nobody
    /mnt/feed/new              refused: a feed is read only
    /mnt/feed/event            `name/id` when an entry lands
    /mnt/feed/dict             the verbs above
    /mnt/feed/<name>/<id>/     an entry, `libmsg`'s files

A URL is fetched through `webfs` at `/mnt/web`, and a path is read as it
is, so a saved feed through a pipe is the offline proof. The fetch runs on
a thread of its own and the write to `ctl` waits for it, so `echo fetch
URL > ctl` returns when the entries are there or says why not. A name not
given is the URL's host, or the file's name without its suffix. Fetching
a feed again refreshes it: an entry already there is replaced by id.

`poll N` on `ctl` fetches every feed again each N seconds, on a thread
of its own with a timer, and `poll 0` stops it. An entry that arrived
lands like any other, and `event` says so.
*/
package feedfs

import "base:runtime"
import "vsys:abi"
import "vsys:lib9p"
import "vsys:libfeed"
import "vsys:libmsg"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

MAX_BYTES :: 1024 * 1024
MAX_FEEDS :: 64
NAME_MAX :: 64
SOURCE_MAX :: 512

DICT :: "fetch name url       fetch a feed by its URL or path into the conversation called name\nremove name          empty a feed's conversation\npoll seconds:int     fetch every feed again each so many seconds, 0 to stop\nread: <name>/<id>    an entry: from, date, subject, body, type, raw, hash, links\n"

// What a conversation was fetched from, by its index among the network's.
Source :: struct {
	text: [SOURCE_MAX]u8,
	len:  int,
	got:  int, // Entries the last fetch parsed
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
sources: [MAX_FEEDS]Source
status: [dynamic]u8
poll_secs: int
polling: bool

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
	why := libmsg.serve(&net, "/srv/feed")
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
			name = name_for(a)
		}
		if name == "" || source == "" || !libmsg.is_name(name) || len(name) > NAME_MAX || len(source) > SOURCE_MAX {
			return vectra9.EINVAL
		}
		if libmsg.conv_index(net, name) < 0 && len(net.convs) >= MAX_FEEDS {
			return vectra9.ENOSPC
		}
		f := new(Fetch)
		f.tag = tag
		f.count = len(text) // The whole write, or the writer sees a short one
		f.nlen = copy(f.name[:], name)
		f.slen = copy(f.source[:], source)
		if libthread.threadcreate(fetch_thread, f, 256 * 1024) < 0 {
			free(f)
			return vectra9.ENOSPC
		}
		lib9p.hold(&net.srv)
		return 0
	case "poll":
		count, _ := word(rest)
		secs, ok := libuser.atoi(count)
		if !ok || secs < 0 || secs > 86400 {
			return vectra9.EINVAL
		}
		poll_secs = int(secs)
		if poll_secs > 0 && !polling {
			if libthread.threadcreate(poll_thread, nil, 256 * 1024) < 0 {
				return vectra9.ENOSPC
			}
			polling = true
		}
		rebuild_status()
		return 0
	case "remove":
		name, _ := word(rest)
		i := libmsg.conv_index(net, name)
		if i < 0 || name == "notify" {
			return vectra9.ENOENT
		}
		libmsg.conv_clear(&net.convs[i])
		sources[i].got = 0
		rebuild_status()
		return 0
	}
	return vectra9.EINVAL
}

// on_new refuses: a feed is read only, and the refusal names it.
on_new :: proc(net: ^libmsg.Net, tag: vectra9.Tag, text: string) -> vectra9.Errno {
	_, _, _ = net, tag, text
	return vectra9.EPERM
}

// poll_thread fetches every feed again each `poll_secs` seconds, until
// that is zero. The sleep is on an io proc, so the server runs meanwhile.
poll_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = libuser.heap_context()
	io := libthread.ioproc()
	if io == nil {
		polling = false
		libthread.threadexits("")
	}
	for poll_secs > 0 {
		_ = libthread.iosleep(io, poll_secs * 1000)
		if poll_secs == 0 {
			break
		}
		for i := 1; i < len(net.convs) && i < MAX_FEEDS; i += 1 {
			if sources[i].len == 0 {
				continue
			}
			f := new(Fetch)
			f.io = io
			f.nlen = copy(f.name[:], net.convs[i].name)
			f.slen = copy(f.source[:], sources[i].text[:sources[i].len])
			_ = fetch(f)
			free(f)
		}
	}
	polling = false
	libthread.ioclose(io)
	libthread.threadexits("")
}

// fetch_thread reads the source, parses it, and puts the entries into
// their conversation, then answers the write that asked.
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

fetch :: proc(f: ^Fetch) -> vectra9.Errno {
	source := string(f.source[:f.slen])
	name := string(f.name[:f.nlen])
	text, ok := read_source(f, source)
	if !ok {
		return vectra9.EIO
	}
	defer delete(text)
	feed, parsed := libfeed.parse(string(text))
	if !parsed {
		libfeed.feed_free(&feed)
		return vectra9.EINVAL
	}
	c := libmsg.conv(&net, name)
	i := libmsg.conv_index(&net, name)
	for m in feed.entries {
		libmsg.add(&net, c, m)
	}
	// The messages are the conversation's now; the feed's own strings go.
	clear(&feed.entries)
	src := &sources[i]
	src.len = copy(src.text[:], source)
	src.got = len(c.msgs)
	libfeed.feed_free(&feed)
	rebuild_status()
	return 0
}

// read_source reads a URL through webfs, or a path as it is, on the
// fetch's io proc so the server's other threads run meanwhile.
read_source :: proc(f: ^Fetch, source: string) -> (text: []u8, ok: bool) {
	if is_url(source) {
		return read_url(f, source)
	}
	fd := libuser.open(source, abi.O_RDONLY)
	if fd < 0 {
		return nil, false
	}
	defer _ = libuser.close(int(fd))
	return read_all(f, int(fd))
}

read_url :: proc(f: ^Fetch, url: string) -> (text: []u8, ok: bool) {
	num: [16]u8
	n := read_small(f, "/mnt/web/clone", num[:])
	if n <= 0 {
		_ = libthread.iomount(f.io, "/srv/web", "/mnt/web", 0)
		n = read_small(f, "/mnt/web/clone", num[:])
		if n <= 0 {
			return nil, false
		}
	}
	conv := string(num[:n])
	path: [128]u8
	line: [SOURCE_MAX + 8]u8
	ctl := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/ctl"), abi.O_WRONLY)
	if ctl < 0 {
		return nil, false
	}
	req := libuser.cat_into(line[:], "url ", url)
	wrote := libthread.iowrite(f.io, int(ctl), transmute([]u8)req) == i64(len(req))
	_ = libuser.close(int(ctl))
	if !wrote {
		return nil, false
	}
	body := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/body"), abi.O_RDONLY)
	if body < 0 {
		return nil, false
	}
	text, ok = read_all(f, int(body))
	_ = libuser.close(int(body))
	if hctl := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/ctl"), abi.O_WRONLY); hctl >= 0 {
		_ = libthread.iowrite(f.io, int(hctl), transmute([]u8)string("hangup"))
		_ = libuser.close(int(hctl))
	}
	return text, ok
}

read_all :: proc(f: ^Fetch, fd: int) -> (text: []u8, ok: bool) {
	buf := make([dynamic]u8, 0, 16384)
	chunk: [8192]u8
	for len(buf) < MAX_BYTES {
		got := libthread.ioread(f.io, fd, chunk[:])
		if got < 0 {
			delete(buf)
			return nil, false
		}
		if got == 0 {
			break
		}
		append(&buf, ..chunk[:got])
	}
	return buf[:], true
}

read_small :: proc(f: ^Fetch, path: string, into: []u8) -> int {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return -1
	}
	total := 0
	for total < len(into) {
		n := libthread.ioread(f.io, int(fd), into[total:])
		if n <= 0 {
			break
		}
		total += int(n)
	}
	_ = libuser.close(int(fd))
	return total
}

// rebuild_status writes what a read of `ctl` answers: a line a feed, its
// name, how many entries, and its source.
rebuild_status :: proc() {
	clear(&status)
	if poll_secs > 0 {
		num: [24]u8
		append(&status, ..transmute([]u8)string("poll "))
		append(&status, ..transmute([]u8)libuser.itoa(num[:], i64(poll_secs)))
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

// name_for is the conversation a source is called when no name is given:
// a URL's host, or a path's last element without its suffix.
name_for :: proc "contextless" (source: string) -> string {
	s := source
	if is_url(s) {
		i := 0
		for i + 2 < len(s) && s[i:i + 3] != "://" {
			i += 1
		}
		s = s[i + 3:]
		e := 0
		for e < len(s) && s[e] != '/' && s[e] != ':' {
			e += 1
		}
		return s[:e]
	}
	base := libuser.basename(s)
	for i := len(base) - 1; i > 0; i -= 1 {
		if base[i] == '.' {
			return base[:i]
		}
	}
	return base
}

is_url :: proc "contextless" (s: string) -> bool {
	return libodin.has_prefix(s, "http://") || libodin.has_prefix(s, "https://") || libodin.has_prefix(s, "gemini://")
}

// word answers the first space-parted word of `s` and what follows it.
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
