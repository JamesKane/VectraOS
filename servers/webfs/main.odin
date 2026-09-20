/*
webfs -- the HTTP client as files, `/mnt/web`. `docs/WEB.md` section 3.

    /mnt/web/clone         read it for a conversation's number
    /mnt/web/N/ctl         `url U`, `method M`, `header H: v`, `hangup`
    /mnt/web/N/postbody    what a POST sends, written before the fetch
    /mnt/web/N/body        the response, a read that streams
    /mnt/web/N/headers     the response's headers, once they are in
    /mnt/web/N/status      the code and the reason
    /mnt/web/N/hash        sha256 of the body, once it ended

A program takes a conversation off `clone`, writes the URL to `ctl`, and reads
`body`. The first open of `body`, `headers`, `status` or `hash` starts the
fetch. A read of what has not arrived yet parks until it has. So `cat body`
prints a page as it comes, and ends when the server does. HTTP/1.1 and no more:
a body by Content-Length, chunked, or to the close. `https` is `sys/libtls`
over the same conversation, the chain verified against `/lib/tls/roots`.

**Every body goes into the store under its hash.** `<store>/store/<sha256>` is
the body, and `<store>/names` gains one line per fetch: the URL, the time, the
media type and the hash. The store is `$home/lib/web`, or what `-s` names.
A page that vanished can be read as it was, and `grep` searches every page
a person ever read.

**Each fetch runs on a thread of its own, with an io proc of its own.** The
serve loop must never park on the network. It holds a read that has nothing
to answer yet, and the fetch thread answers it when the bytes land, the way
`cmd/exportfs`'s readers do. Threads are cooperative, so a fetch thread that
answers a request does so while the loop is parked in its own read.

**The cookie jar is a file.** `/mnt/web/cookies` lists every cookie a
response set, one per line (`host path name value`). A write adds one, and a
remove of the file forgets them all. A request carries the cookies whose host
and path match, unless the conversation's `ctl` said `cookies off`. The jar
persists in the store. There is no third-party cookie because there is no
script to want one.

**Gemini is a scheme.** A `gemini://` URL is one TLS connection, one request
line, one response with a status and a media type. It is served through the
same files: `status` is the `20 text/gemini` line, and `body` the rest.

**gzip is taken.** The request offers it, and a body that arrives gzipped is
inflated whole before it is served: `core:compress/zlib` inflates the deflate
stream inside the frame.

Not yet: a connection kept for the next request, and the WebSocket. Each is a
step this file grows by. And `dial` runs through the fetch's io proc, so the
loop never waits out a connect or a name.
*/
package webfs

import "base:runtime"
import "core:bytes"
import "core:compress/zlib"
import "core:crypto/hash"
import "core:crypto/x509"
import "core:time"
import "vsys:abi"
import "vsys:lib9p"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libtls"
import "vsys:libuser"
import "vsys:vectra9"

FRAME :: 8192 + 512
MAX_CONVS :: 16
URL_MAX :: 1024
HEADERS_MAX :: 16384
REQUEST_MAX :: 4096

NODE_ROOT :: i32(0)
NODE_CLONE :: i32(1)
NODE_COOKIES :: i32(2)
CONV_BASE :: i32(16)
CONV_STRIDE :: i32(8)
CONV_DIR :: i32(0)
CONV_CTL :: i32(1)
CONV_BODY :: i32(2)
CONV_HEADERS :: i32(3)
CONV_STATUS :: i32(4)
CONV_HASH :: i32(5)
CONV_POSTBODY :: i32(6)

State :: enum u8 {
	Idle, // A conversation with no fetch yet
	Fetching, // The request is out, the status line not yet in
	Streaming, // The headers are in, the body arriving
	Done, // The body ended; the hash is known
	Failed, // The fetch did not complete
}

Conv :: struct {
	used:      bool,
	refs:      int,
	state:     State,
	url:       [URL_MAX]u8,
	url_len:   int,
	method:    [8]u8,
	method_len: int,
	extra:     [1024]u8, // Request headers `ctl header` added, CRLF-terminated
	extra_len: int,
	post:      [dynamic]u8,
	cookies_off: bool,
	gzip:      bool, // The body arrives gzipped, and is inflated once whole
	packed:    [dynamic]u8, // The gzipped bytes, until the body ends
	status:    [128]u8, // `200 OK`
	status_len: int,
	ctype:     [96]u8,
	ctype_len: int,
	headers:   [dynamic]u8,
	body:      [dynamic]u8,
	hash_hex:  [64]u8,
	why:       string, // A failure's reason, for the log
}

convs: [MAX_CONVS]Conv
fids: libuser.Fid_Table
srv: lib9p.Srv
store: string = ""
store_buf: [256]u8
roots: []^x509.Certificate

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = {}
	#force_no_inline runtime._startup_runtime()
	args := libuser.args(block)
	for i := 1; i < len(args); i += 1 {
		if args[i] == "-s" && i + 1 < len(args) {
			i += 1
			n := copy(store_buf[:], args[i])
			store = string(store_buf[:n])
		}
	}
	if store == "" {
		home_buf: [128]u8
		home := libuser.getenv("home", home_buf[:])
		if home == "" {
			home = "/usr/glenda"
		}
		store = libuser.cat_into(store_buf[:], home, "/lib/web")
	}
	libthread.main(threadmain, nil)
}

threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = libuser.heap_context()
	fd, perr := libuser.post("/srv/web")
	if perr < 0 {
		libthread.threadexitsall("post")
	}
	roots = load_roots("/lib/tls/roots")
	ensure_store()
	jar_load()
	srv = lib9p.Srv {
		fd             = fd,
		handler        = handler,
		msize          = FRAME,
		keep_on_remove = true, // A remove of `cookies` empties the jar
	}
	_, why := lib9p.serve(&srv)
	lib9p.respond_all(&srv, vectra9.Rread{data = nil})
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

// -- The store ----------------------------------------------------------------

// ensure_store makes the store's directories, each level in turn. A level
// that exists already answers an error this ignores. A store that cannot be
// made leaves every fetch unstored, and `hash` still answers.
ensure_store :: proc() {
	path: [300]u8
	for i in 1 ..< len(store) {
		if store[i] == '/' {
			_ = libuser.mkdir(store[:i])
		}
	}
	_ = libuser.mkdir(store)
	_ = libuser.mkdir(libuser.cat_into(path[:], store, "/store"))
}

// load_roots reads the trust store the way `cmd/tlsclient` does: concatenated
// DER, walked by each certificate's own length. With none, https is refused.
load_roots :: proc(path: string) -> []^x509.Certificate {
	data, ok := libuser.read_file(path, context.allocator)
	if !ok {
		return nil
	}
	list: [dynamic]^x509.Certificate
	off := 0
	for off < len(data) {
		n := libtls.der_len(data[off:])
		if n <= 0 {
			break
		}
		cert, err := x509.parse(data[off:][:n], context.allocator)
		if err == .None {
			c := new(x509.Certificate)
			c^ = cert
			append(&list, c)
		}
		off += n
	}
	return list[:]
}

now_seconds :: proc "contextless" () -> i64 {
	fd := libuser.open("/dev/time", abi.O_RDONLY)
	if fd < 0 {
		return 0
	}
	line: [96]u8
	n := libuser.read(int(fd), line[:])
	_ = libuser.close(int(fd))
	sec: i64
	for i in 0 ..< int(n) {
		if line[i] < '0' || line[i] > '9' {
			break
		}
		sec = sec * 10 + i64(line[i] - '0')
	}
	return sec
}

// keep writes a finished body into the store under its hash and appends the
// fetch's line to `names`. A body already there is not written again: a second
// fetch of the same bytes adds a line and no file.
keep :: proc(c: ^Conv) {
	path: [400]u8
	hex := string(c.hash_hex[:])
	file := libuser.cat_into(path[:], store, "/store/", hex)
	st: abi.Stat
	if libuser.stat(file, &st) < 0 {
		fd := libuser.create(file, abi.O_WRONLY, 0o644)
		if fd >= 0 {
			_ = libuser.write_full(int(fd), c.body[:])
			_ = libuser.close(int(fd))
		}
	}

	// The index line: url, time, type, hash.
	line: [URL_MAX + 256]u8
	sink := libodin.sink_from(line[:])
	libodin.put_str(&sink, string(c.url[:c.url_len]))
	libodin.put_str(&sink, " ")
	libodin.put_int(&sink, now_seconds())
	libodin.put_str(&sink, " ")
	libodin.put_str(&sink, c.ctype_len > 0 ? string(c.ctype[:c.ctype_len]) : "-")
	libodin.put_str(&sink, " ")
	libodin.put_str(&sink, hex)
	libodin.put_str(&sink, "\n")
	text := libodin.str(&sink)

	names := libuser.cat_into(path[:], store, "/names")
	fd := libuser.open(names, abi.O_WRONLY)
	if fd < 0 {
		fd = libuser.create(names, abi.O_WRONLY, 0o644)
	}
	if fd >= 0 {
		at: u64 = 0
		if libuser.fstat(int(fd), &st) >= 0 {
			at = st.length
		}
		_ = libuser.pwrite(int(fd), transmute([]u8)text, at)
		_ = libuser.close(int(fd))
	}
}

// -- The conversations --------------------------------------------------------

/*
conv_alloc takes a free slot, or reclaims one nothing holds. A conversation
outlives its descriptors, as `netfs`'s do. So a shell can write `ctl`, read
`body` and then `hash` as three commands. A finished or never-used one with no
descriptor on it is done, and its slot serves the next when none is free. A
`hangup` frees a slot at once.
*/
conv_alloc :: proc "contextless" () -> int {
	context = libuser.heap_context()
	slot := -1
	for i in 0 ..< MAX_CONVS {
		if !convs[i].used {
			slot = i
			break
		}
	}
	if slot < 0 {
		for i in 0 ..< MAX_CONVS {
			c := &convs[i]
			if c.refs == 0 && (c.state == .Done || c.state == .Failed || c.state == .Idle) {
				conv_free(i)
				slot = i
				break
			}
		}
	}
	if slot < 0 {
		return -1
	}
	c := &convs[slot]
	c^ = Conv{used = true}
	c.post = make([dynamic]u8, libuser.allocator())
	c.headers = make([dynamic]u8, libuser.allocator())
	c.body = make([dynamic]u8, libuser.allocator())
	c.packed = make([dynamic]u8, libuser.allocator())
	c.method_len = copy(c.method[:], "GET")
	return slot
}

conv_free :: proc "contextless" (i: int) {
	context = libuser.heap_context()
	c := &convs[i]
	delete(c.post)
	delete(c.headers)
	delete(c.body)
	delete(c.packed)
	c^ = Conv{}
}

conv_node :: proc "contextless" (i: int, kind: i32) -> i32 {
	return CONV_BASE + i32(i) * CONV_STRIDE + kind
}

conv_of :: proc "contextless" (node: i32) -> (i: int, kind: i32, ok: bool) {
	if node < CONV_BASE {
		return 0, 0, false
	}
	v := node - CONV_BASE
	i = int(v / CONV_STRIDE)
	kind = v % CONV_STRIDE
	if i >= MAX_CONVS || kind > CONV_POSTBODY {
		return 0, 0, false
	}
	return i, kind, true
}

is_dir :: proc "contextless" (node: i32) -> bool {
	if node == NODE_ROOT {
		return true
	}
	_, kind, ok := conv_of(node)
	return ok && kind == CONV_DIR
}

qid_of :: proc "contextless" (node: i32) -> vectra9.Qid {
	kind: vectra9.Qid_Flags
	if is_dir(node) {
		kind = {.Dir}
	}
	return vectra9.Qid{kind = kind, path = u64(node) + 1}
}

step :: proc "contextless" (from: i32, name: string) -> i32 {
	if name == "." {
		return from
	}
	if name == ".." {
		if i, kind, ok := conv_of(from); ok && kind != CONV_DIR {
			return conv_node(i, CONV_DIR)
		}
		return NODE_ROOT
	}
	if from == NODE_ROOT {
		if name == "clone" {
			return NODE_CLONE
		}
		if name == "cookies" {
			return NODE_COOKIES
		}
		if v, _, ok := scan_uint(name); ok {
			i := int(v)
			if i < MAX_CONVS && convs[i].used {
				return conv_node(i, CONV_DIR)
			}
		}
		return -1
	}
	if i, kind, ok := conv_of(from); ok && kind == CONV_DIR {
		switch name {
		case "ctl":
			return conv_node(i, CONV_CTL)
		case "body":
			return conv_node(i, CONV_BODY)
		case "headers":
			return conv_node(i, CONV_HEADERS)
		case "status":
			return conv_node(i, CONV_STATUS)
		case "hash":
			return conv_node(i, CONV_HASH)
		case "postbody":
			return conv_node(i, CONV_POSTBODY)
		}
	}
	return -1
}

scan_uint :: proc "contextless" (s: string) -> (v: u64, digits: int, ok: bool) {
	for i in 0 ..< len(s) {
		if s[i] < '0' || s[i] > '9' {
			break
		}
		v = v * 10 + u64(s[i] - '0')
		digits += 1
	}
	return v, digits, digits > 0 && digits == len(s)
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
		if i, kind, is_conv := conv_of(node); is_conv {
			c := &convs[i]
			if !c.used {
				reply^ = vectra9.error_reply(vectra9.ENOENT)
				return
			}
			// The first open of what the response fills starts the fetch.
			if kind == CONV_BODY || kind == CONV_HEADERS || kind == CONV_STATUS || kind == CONV_HASH {
				if c.state == .Idle {
					if c.url_len == 0 {
						reply^ = vectra9.error_reply(vectra9.EINVAL)
						return
					}
					c.state = .Fetching
					c.refs += 1 // The fetch's own hold on the conversation
					if libthread.threadcreate(fetch_thread, c, 256 * 1024) < 0 {
						c.state = .Failed
						c.refs -= 1
						reply^ = vectra9.error_reply(vectra9.EIO)
						return
					}
				}
			}
			c.refs += 1
		}
		libuser.fid_open(&fids, m.fid)
		reply^ = vectra9.Rlopen{qid = qid_of(node), iounit = 0}

	case vectra9.Tread:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		room := min(len(buf), int(m.count))
		if node == NODE_CLONE {
			if m.offset > 0 {
				reply^ = vectra9.Rread{data = nil}
				return
			}
			i := conv_alloc()
			if i < 0 {
				reply^ = vectra9.error_reply(vectra9.ENOSPC)
				return
			}
			sink := libodin.sink_from(buf[:room])
			libodin.put_uint(&sink, u64(i))
			libodin.put_str(&sink, "\n")
			reply^ = vectra9.Rread{data = buf[:len(libodin.str(&sink))]}
			return
		}
		if node == NODE_COOKIES {
			text := make([dynamic]u8, libuser.allocator())
			defer delete(text)
			jar_render(&text)
			reply^ = vectra9.Rread{data = slice_window(text[:], m.offset, buf[:room])}
			return
		}
		i, kind, is_conv := conv_of(node)
		if !is_conv || is_dir(node) {
			reply^ = vectra9.error_reply(vectra9.EISDIR)
			return
		}
		c := &convs[i]
		if kind == CONV_CTL {
			sink := libodin.sink_from(buf[:room])
			if m.offset == 0 {
				libodin.put_uint(&sink, u64(i))
				libodin.put_str(&sink, "\n")
			}
			reply^ = vectra9.Rread{data = buf[:len(libodin.str(&sink))]}
			return
		}
		if kind == CONV_POSTBODY {
			reply^ = vectra9.Rread{data = slice_window(c.post[:], m.offset, buf[:room])}
			return
		}
		// What the response fills: answered when it is in, held until then.
		if !read_ready(c, kind, m.offset) {
			lib9p.hold(&srv)
			return
		}
		answer_read(c, kind, m.offset, buf[:room], reply)

	case vectra9.Twrite:
		node, ok := libuser.open_node(&fids, m.fid, reply)
		if !ok {
			return
		}
		if node == NODE_COOKIES {
			if !jar_add_line(string(m.data)) {
				reply^ = vectra9.error_reply(vectra9.EINVAL)
				return
			}
			jar_save()
			reply^ = vectra9.Rwrite{count = u32(len(m.data))}
			return
		}
		i, kind, is_conv := conv_of(node)
		if !is_conv {
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		c := &convs[i]
		switch kind {
		case CONV_CTL:
			if !run_ctl(c, string(m.data)) {
				reply^ = vectra9.error_reply(vectra9.EINVAL)
				return
			}
			reply^ = vectra9.Rwrite{count = u32(len(m.data))}
		case CONV_POSTBODY:
			if c.state != .Idle {
				reply^ = vectra9.error_reply(vectra9.EBUSY)
				return
			}
			append(&c.post, ..m.data)
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
		dir := is_dir(node)
		size := u64(0)
		if i, kind, is_conv := conv_of(node); is_conv {
			c := &convs[i]
			switch kind {
			case CONV_BODY:
				size = u64(len(c.body))
			case CONV_HEADERS:
				size = u64(len(c.headers))
			case CONV_POSTBODY:
				size = u64(len(c.post))
			}
		}
		reply^ = vectra9.Rgetattr {
			valid   = m.request_mask & 0x000007FF,
			qid     = qid_of(node),
			mode    = dir ? 0o040555 : 0o100644,
			nlink   = dir ? 2 : 1,
			size    = size,
			blksize = 512,
		}

	case vectra9.Tclunk:
		node := libuser.fid_lookup(&fids, m.fid)
		held_open := libuser.fid_is_open(&fids, m.fid)
		libuser.fid_release(&fids, m.fid)
		if held_open {
			if i, _, is_conv := conv_of(node); is_conv && convs[i].used {
				release(i)
			}
		}
		reply^ = vectra9.Rclunk{}

	case vectra9.Tremove:
		node := libuser.fid_lookup(&fids, m.fid)
		libuser.fid_release(&fids, m.fid)
		if node != NODE_COOKIES {
			reply^ = vectra9.error_reply(vectra9.EPERM)
			return
		}
		// Forgetting every cookie is the one remove here. The file stays.
		jar_clear()
		jar_save()
		reply^ = vectra9.Rremove{}

	case vectra9.Tflush:
		_ = m
		reply^ = vectra9.Rflush{}
	}
}

// release drops one hold on a conversation. The record stays: `conv_alloc`
// reclaims it once nothing holds it and it is not mid-fetch, and `hangup`
// frees it at once.
release :: proc "contextless" (i: int) {
	c := &convs[i]
	if c.refs > 0 {
		c.refs -= 1
	}
}

// slice_window answers the part of `data` a read at `offset` for `len(into)`
// bytes sees, copied into `into`.
slice_window :: proc "contextless" (data: []u8, offset: u64, into: []u8) -> []u8 {
	if offset >= u64(len(data)) {
		return nil
	}
	n := copy(into, data[offset:])
	return into[:n]
}

// read_ready says whether a read of `kind` at `offset` can be answered now.
read_ready :: proc "contextless" (c: ^Conv, kind: i32, offset: u64) -> bool {
	switch kind {
	case CONV_BODY:
		return offset < u64(len(c.body)) || c.state == .Done || c.state == .Failed
	case CONV_HEADERS, CONV_STATUS:
		return c.state == .Streaming || c.state == .Done || c.state == .Failed
	case CONV_HASH:
		return c.state == .Done || c.state == .Failed
	}
	return true
}

// answer_read fills `reply` for a read `read_ready` said could be answered.
answer_read :: proc "contextless" (c: ^Conv, kind: i32, offset: u64, into: []u8, reply: ^vectra9.Msg) {
	if c.state == .Failed && (kind != CONV_BODY || offset >= u64(len(c.body))) {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	switch kind {
	case CONV_BODY:
		reply^ = vectra9.Rread{data = slice_window(c.body[:], offset, into)}
	case CONV_HEADERS:
		reply^ = vectra9.Rread{data = slice_window(c.headers[:], offset, into)}
	case CONV_STATUS:
		line: [140]u8
		sink := libodin.sink_from(line[:])
		libodin.put_str(&sink, string(c.status[:c.status_len]))
		libodin.put_str(&sink, "\n")
		reply^ = vectra9.Rread{data = slice_window(transmute([]u8)libodin.str(&sink), offset, into)}
	case CONV_HASH:
		line: [66]u8
		n := copy(line[:], c.hash_hex[:])
		line[n] = '\n'
		reply^ = vectra9.Rread{data = slice_window(line[:n + 1], offset, into)}
	case:
		reply^ = vectra9.Rread{data = nil}
	}
}

// wants_conv accepts a held read of one of `c`'s files that can be answered
// now. This is how the fetch thread finds what its bytes unblocked.
wants_conv :: proc "contextless" (arg: rawptr, request: ^vectra9.Msg) -> bool {
	c := (^Conv)(arg)
	#partial switch m in request^ {
	case vectra9.Tread:
		node := libuser.fid_lookup(&fids, m.fid)
		i, kind, ok := conv_of(node)
		if !ok || &convs[i] != c || kind == CONV_DIR {
			return false
		}
		return read_ready(c, kind, m.offset)
	}
	return false
}

// answer_held answers every held read of `c`'s files that the fetch has since
// made answerable. Called by the fetch thread after each arrival and at the end.
answer_held :: proc "contextless" (c: ^Conv) {
	for {
		req, ok := lib9p.held(&srv, c, wants_conv)
		if !ok {
			return
		}
		m := req.msg.(vectra9.Tread)
		node := libuser.fid_lookup(&fids, m.fid)
		_, kind, _ := conv_of(node)
		room := min(len(req.payload), int(m.count))
		reply: vectra9.Msg
		answer_read(c, kind, m.offset, req.payload[:room], &reply)
		_ = lib9p.respond(req, reply)
	}
}

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
	if node == NODE_ROOT {
		// `clone`, then a numbered entry per conversation that exists.
		if m.offset == 0 {
			vectra9.put_dirent(&c, vectra9.Dirent{qid = qid_of(NODE_CLONE), offset = 1, type = vectra9.DT_REG, name = "clone"})
		}
		if m.offset <= 1 {
			vectra9.put_dirent(&c, vectra9.Dirent{qid = qid_of(NODE_COOKIES), offset = 2, type = vectra9.DT_REG, name = "cookies"})
		}
		name: [16]u8
		for i := max(int(m.offset) - 2, 0); i < MAX_CONVS; i += 1 {
			if !convs[i].used {
				continue
			}
			sink := libodin.sink_from(name[:])
			libodin.put_uint(&sink, u64(i))
			entry := libodin.str(&sink)
			if vectra9.remaining(&c) < vectra9.dirent_size(entry) {
				break
			}
			vectra9.put_dirent(&c, vectra9.Dirent{qid = qid_of(conv_node(i, CONV_DIR)), offset = u64(i + 3), type = vectra9.DT_DIR, name = entry})
		}
	} else {
		i, _, _ := conv_of(node)
		names := [?]string{"ctl", "body", "headers", "status", "hash", "postbody"}
		kinds := [?]i32{CONV_CTL, CONV_BODY, CONV_HEADERS, CONV_STATUS, CONV_HASH, CONV_POSTBODY}
		for k := int(m.offset); k < len(names); k += 1 {
			if vectra9.remaining(&c) < vectra9.dirent_size(names[k]) {
				break
			}
			vectra9.put_dirent(&c, vectra9.Dirent{qid = qid_of(conv_node(i, kinds[k])), offset = u64(k + 1), type = vectra9.DT_REG, name = names[k]})
		}
	}
	if c.err != .None {
		reply^ = vectra9.error_reply(vectra9.EIO)
		return
	}
	reply^ = vectra9.Rreaddir{data = vectra9.written(&c)}
}

// -- The control file -----------------------------------------------------------

// run_ctl takes one control line. `url`, `method` and `header` shape the
// request to come. `hangup` is refused while a fetch runs, since the thread
// owns the connection. Otherwise it resets the conversation.
run_ctl :: proc "contextless" (c: ^Conv, text: string) -> bool {
	context = libuser.heap_context()
	line := text
	for len(line) > 0 && (line[len(line) - 1] == '\n' || line[len(line) - 1] == '\r' || line[len(line) - 1] == ' ') {
		line = line[:len(line) - 1]
	}
	verb, rest := word(line)
	switch verb {
	case "url":
		if c.state != .Idle || len(rest) == 0 || len(rest) > URL_MAX {
			return false
		}
		c.url_len = copy(c.url[:], rest)
		return true
	case "method":
		if c.state != .Idle || len(rest) == 0 || len(rest) > len(c.method) {
			return false
		}
		c.method_len = copy(c.method[:], rest)
		return true
	case "header":
		if c.state != .Idle || len(rest) == 0 || c.extra_len + len(rest) + 2 > len(c.extra) {
			return false
		}
		c.extra_len += copy(c.extra[c.extra_len:], rest)
		c.extra_len += copy(c.extra[c.extra_len:], "\r\n")
		return true
	case "cookies":
		if rest == "off" {
			c.cookies_off = true
			return true
		}
		if rest == "on" {
			c.cookies_off = false
			return true
		}
		return false
	case "hangup":
		if c.state == .Fetching || c.state == .Streaming {
			return false
		}
		// The slot goes now if nothing else holds it, and at the writer's
		// clunk otherwise -- `conv_alloc` sees a finished one with no refs.
		c.state = .Idle
		c.url_len = 0
		c.extra_len = 0
		clear(&c.post)
		clear(&c.headers)
		clear(&c.body)
		clear(&c.packed)
		c.gzip = false
		c.status_len = 0
		return true
	}
	return false
}

word :: proc "contextless" (line: string) -> (first: string, rest: string) {
	i := 0
	for i < len(line) && line[i] != ' ' {
		i += 1
	}
	j := i
	for j < len(line) && line[j] == ' ' {
		j += 1
	}
	return line[:i], line[j:]
}

// -- The fetch ------------------------------------------------------------------

// Where a URL's parts land, all slices of the conversation's own text.
Url :: struct {
	scheme: string,
	host:   string,
	port:   string,
	path:   string,
}

// split_url cuts `scheme://host[:port]/path`. The port defaults by scheme
// and the path to `/`. Anything else is refused.
split_url :: proc "contextless" (text: string) -> (u: Url, ok: bool) {
	sep := -1
	for i in 0 ..< len(text) - 2 {
		if text[i] == ':' && text[i + 1] == '/' && text[i + 2] == '/' {
			sep = i
			break
		}
	}
	if sep <= 0 {
		return u, false
	}
	u.scheme = text[:sep]
	rest := text[sep + 3:]
	slash := len(rest)
	for i in 0 ..< len(rest) {
		if rest[i] == '/' {
			slash = i
			break
		}
	}
	authority := rest[:slash]
	u.path = slash < len(rest) ? rest[slash:] : "/"
	colon := -1
	for i in 0 ..< len(authority) {
		if authority[i] == ':' {
			colon = i
		}
	}
	if colon >= 0 {
		u.host = authority[:colon]
		u.port = authority[colon + 1:]
	} else {
		u.host = authority
		switch u.scheme {
		case "https":
			u.port = "443"
		case "gemini":
			u.port = "1965"
		case:
			u.port = "80"
		}
	}
	if len(u.host) == 0 || len(u.port) == 0 {
		return u, false
	}
	return u, u.scheme == "http" || u.scheme == "https" || u.scheme == "gemini"
}

// A fetch in flight: the connection, the io proc it reads through, and the
// TLS client over it when the scheme wants one.
Fetch :: struct {
	c:     ^Conv,
	io:    ^libthread.Ioproc,
	fd:    int,
	dir:   [libnet.DIAL_MAX]u8,
	dirlen: int,
	tls:   ^libtls.Client,
}

tls_read :: proc(ctx: rawptr, buf: []u8) -> int {
	f := (^Fetch)(ctx)
	return int(libthread.ioread(f.io, f.fd, buf))
}

tls_write :: proc(ctx: rawptr, buf: []u8) -> int {
	f := (^Fetch)(ctx)
	return int(libthread.iowrite(f.io, f.fd, buf))
}

// The dial's parking calls, through the fetch's io proc: the `connect` line
// held for the handshake, and the name off `/net/cs` that may wait on dns.
dial_read :: proc "contextless" (ctx: rawptr, fd: int, buf: []u8) -> i64 {
	f := (^Fetch)(ctx)
	return libthread.ioread(f.io, fd, buf)
}

dial_write :: proc "contextless" (ctx: rawptr, fd: int, data: []u8) -> i64 {
	f := (^Fetch)(ctx)
	return libthread.iowrite(f.io, fd, data)
}

// stream_read takes the next bytes of the response, through TLS or not.
stream_read :: proc(f: ^Fetch, buf: []u8) -> int {
	if f.tls != nil {
		return libtls.client_read(f.tls, buf)
	}
	return int(libthread.ioread(f.io, f.fd, buf))
}

stream_write :: proc(f: ^Fetch, data: []u8) -> bool {
	if f.tls != nil {
		return libtls.client_write(f.tls, data)
	}
	sent := 0
	for sent < len(data) {
		n := libthread.iowrite(f.io, f.fd, data[sent:])
		if n <= 0 {
			return false
		}
		sent += int(n)
	}
	return true
}

fetch_thread :: proc "contextless" (arg: rawptr) {
	context = libuser.heap_context()
	c := (^Conv)(arg)
	f := new(Fetch)
	f.c = c
	f.fd = -1
	f.io = libthread.ioproc()
	if f.io == nil {
		fail_fetch(c, "no io proc")
	} else {
		fetch(f)
	}
	// The end, whichever way: the held reads learn it, the store keeps a
	// body that ended, and the record goes if nothing else holds it.
	if c.state == .Done {
		keep(c)
	}
	answer_held(c)
	if f.tls != nil {
		free(f.tls)
	}
	if f.fd >= 0 {
		libnet.hangup(string(f.dir[:f.dirlen]))
		_ = libuser.close(f.fd)
	}
	if f.io != nil {
		libthread.ioclose(f.io)
	}
	free(f)
	i := int(uintptr(rawptr(c)) - uintptr(rawptr(&convs[0]))) / size_of(Conv)
	release(i)
	libthread.threadexits("")
}

fail_fetch :: proc "contextless" (c: ^Conv, why: string) {
	c.state = .Failed
	c.why = why
	libuser.eprint("webfs: ", why, "\n")
}

// fetch runs one HTTP/1.1 exchange over the conversation's URL. The dial, the
// TLS handshake when the scheme is https, the request, the status line and the
// headers. Then the body, framed whichever of the three ways the headers say.
fetch :: proc(f: ^Fetch) {
	c := f.c
	u, uok := split_url(string(c.url[:c.url_len]))
	if !uok {
		fail_fetch(c, "a URL this client does not understand")
		return
	}

	spec_buf: [512]u8
	spec := libuser.cat_into(spec_buf[:], "tcp!", u.host, "!", u.port)
	fd, dirlen, dok := libnet.dial_dir_via(spec, f.dir[:], libnet.Dial_IO{ctx = f, read = dial_read, write = dial_write})
	if !dok {
		fail_fetch(c, "cannot dial the host")
		return
	}
	f.fd = fd
	f.dirlen = dirlen

	if u.scheme == "https" || u.scheme == "gemini" {
		if len(roots) == 0 {
			fail_fetch(c, "no trust roots, so no https")
			return
		}
		f.tls = new(libtls.Client)
		libtls.client_init(f.tls, libtls.IO{ctx = f, read = tls_read, write = tls_write}, roots, time.unix(now_seconds(), 0), u.host)
		priv: [32]u8
		random: [32]u8
		if !fill_random(priv[:]) || !fill_random(random[:]) {
			fail_fetch(c, "no entropy from /dev/random")
			return
		}
		if !libtls.client_handshake(f.tls, priv, random) {
			fail_fetch(c, "the TLS handshake failed")
			return
		}
	}

	if u.scheme == "gemini" {
		fetch_gemini(f, u)
		return
	}

	// The request.
	req: [REQUEST_MAX]u8
	sink := libodin.sink_from(req[:])
	libodin.put_str(&sink, string(c.method[:c.method_len]))
	libodin.put_str(&sink, " ")
	libodin.put_str(&sink, u.path)
	libodin.put_str(&sink, " HTTP/1.1\r\nHost: ")
	libodin.put_str(&sink, u.host)
	libodin.put_str(&sink, "\r\nUser-Agent: vectra-webfs/0\r\n")
	// Anything is accepted, unless the conversation's own headers say
	// what: a client asking for activity JSON must not also say */*.
	if !extra_has(c, "accept:") {
		libodin.put_str(&sink, "Accept: */*\r\n")
	}
	libodin.put_str(&sink, "Accept-Encoding: gzip\r\nConnection: close\r\n")
	if !c.cookies_off {
		jar_header(&sink, u.host, u.path)
	}
	if len(c.post) > 0 {
		libodin.put_str(&sink, "Content-Length: ")
		libodin.put_uint(&sink, u64(len(c.post)))
		libodin.put_str(&sink, "\r\n")
	}
	libodin.put_str(&sink, string(c.extra[:c.extra_len]))
	libodin.put_str(&sink, "\r\n")
	if !stream_write(f, transmute([]u8)libodin.str(&sink)) || (len(c.post) > 0 && !stream_write(f, c.post[:])) {
		fail_fetch(c, "could not send the request")
		return
	}

	// The status line and the headers, up to the empty line.
	head := make([dynamic]u8, libuser.allocator())
	defer delete(head)
	chunk: [4096]u8
	body_start := -1
	for body_start < 0 {
		n := stream_read(f, chunk[:])
		if n <= 0 {
			fail_fetch(c, "the response ended before its headers")
			return
		}
		append(&head, ..chunk[:n])
		body_start = find_blank_line(head[:])
		if body_start < 0 && len(head) > HEADERS_MAX {
			fail_fetch(c, "the headers are too long")
			return
		}
	}
	if !parse_head(c, string(head[:body_start])) {
		fail_fetch(c, "a status line this client does not understand")
		return
	}
	framing := body_framing(string(head[:body_start]))
	if v, has := header_value(string(head[:body_start]), "content-encoding"); has && libodin.contains(v, "gzip") {
		c.gzip = true
	}
	jar_take(string(head[:body_start]), u.host)
	c.state = .Streaming
	answer_held(c)

	// The body: what came with the headers first, then the rest.
	first := head[body_start:]
	ok: bool
	switch framing.kind {
	case .Chunked:
		ok = read_chunked(f, first)
	case .Length:
		ok = read_length(f, first, framing.length)
	case .Until_Close:
		ok = read_until_close(f, first)
	}
	if !ok {
		fail_fetch(c, "the body ended early")
		return
	}
	if c.gzip && !inflate_gzip(c) {
		fail_fetch(c, "the gzip body would not inflate")
		return
	}
	digest: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, c.body[:], digest[:])
	hex_of(digest[:], c.hash_hex[:])
	c.state = .Done
}

fill_random :: proc(buf: []u8) -> bool {
	fd := libuser.open("/dev/random", abi.O_RDONLY)
	if fd < 0 {
		return false
	}
	n := libuser.read(int(fd), buf)
	_ = libuser.close(int(fd))
	return int(n) == len(buf)
}

hex_of :: proc "contextless" (bytes: []u8, out: []u8) #no_bounds_check {
	digits := "0123456789abcdef"
	for b, i in bytes {
		out[2 * i] = digits[b >> 4]
		out[2 * i + 1] = digits[b & 15]
	}
}

// find_blank_line answers the index just past the first `\r\n\r\n` (or
// `\n\n`), which is where the body starts, or -1.
find_blank_line :: proc "contextless" (data: []u8) -> int #no_bounds_check {
	for i in 0 ..< len(data) {
		if data[i] == '\n' {
			if i + 2 < len(data) && data[i + 1] == '\r' && data[i + 2] == '\n' {
				return i + 3
			}
			if i + 1 < len(data) && data[i + 1] == '\n' {
				return i + 2
			}
		}
	}
	return -1
}

// parse_head keeps the status (`200 OK`), the headers whole, and the media
// type. The status line is `HTTP/1.1 200 OK`, and the code and reason are kept.
parse_head :: proc(c: ^Conv, head: string) -> bool {
	eol := 0
	for eol < len(head) && head[eol] != '\n' {
		eol += 1
	}
	line := head[:eol]
	if len(line) > 0 && line[len(line) - 1] == '\r' {
		line = line[:len(line) - 1]
	}
	if len(line) < 12 || line[:5] != "HTTP/" {
		return false
	}
	sp := 0
	for sp < len(line) && line[sp] != ' ' {
		sp += 1
	}
	if sp >= len(line) {
		return false
	}
	c.status_len = copy(c.status[:], line[sp + 1:])
	rest := eol + 1 < len(head) ? head[eol + 1:] : ""
	clear(&c.headers)
	append(&c.headers, ..transmute([]u8)rest)
	if v, has := header_value(rest, "content-type"); has {
		c.ctype_len = copy(c.ctype[:], v)
		// The media type alone, without its parameters.
		for i in 0 ..< c.ctype_len {
			if c.ctype[i] == ';' || c.ctype[i] == ' ' {
				c.ctype_len = i
				break
			}
		}
	}
	return true
}

// header_value finds a header by name, case-insensitively, and answers its
// value with the surrounding space trimmed.
header_value :: proc "contextless" (headers: string, name: string) -> (value: string, has: bool) #no_bounds_check {
	at := 0
	for at < len(headers) {
		eol := at
		for eol < len(headers) && headers[eol] != '\n' {
			eol += 1
		}
		line := headers[at:eol]
		at = eol + 1
		colon := -1
		for i in 0 ..< len(line) {
			if line[i] == ':' {
				colon = i
				break
			}
		}
		if colon != len(name) {
			continue
		}
		same := true
		for i in 0 ..< len(name) {
			a := line[i]
			b := name[i]
			if a >= 'A' && a <= 'Z' {
				a += 'a' - 'A'
			}
			if a != b {
				same = false
				break
			}
		}
		if !same {
			continue
		}
		v := line[colon + 1:]
		for len(v) > 0 && (v[0] == ' ' || v[0] == '\t') {
			v = v[1:]
		}
		for len(v) > 0 && (v[len(v) - 1] == '\r' || v[len(v) - 1] == ' ') {
			v = v[:len(v) - 1]
		}
		return v, true
	}
	return "", false
}

Framing_Kind :: enum {
	Until_Close,
	Length,
	Chunked,
}

Framing :: struct {
	kind:   Framing_Kind,
	length: int,
}

body_framing :: proc "contextless" (head: string) -> Framing {
	if v, has := header_value(head, "transfer-encoding"); has && libodin.contains(v, "chunked") {
		return Framing{kind = .Chunked}
	}
	if v, has := header_value(head, "content-length"); has {
		if n, _, ok := scan_uint(v); ok {
			return Framing{kind = .Length, length = int(n)}
		}
	}
	return Framing{kind = .Until_Close}
}

// deliver appends body bytes and answers the reads that were waiting on them.
deliver :: proc "contextless" (c: ^Conv, data: []u8) {
	context = libuser.heap_context()
	if c.gzip {
		append(&c.packed, ..data)
		return
	}
	append(&c.body, ..data)
	answer_held(c)
}

/*
inflate_gzip turns the gzipped bytes into the body, once they are all here. The
frame is RFC 1952's: a ten-byte header, optional fields the flags name, the
deflate stream, and a trailer of CRC and size. `core:compress/zlib` inflates the
stream raw. The trailer is not checked, since the hash `hash` answers is of
the bytes served either way.
*/
inflate_gzip :: proc(c: ^Conv) -> bool {
	g := c.packed[:]
	if len(g) < 18 || g[0] != 0x1f || g[1] != 0x8b || g[2] != 8 {
		return false
	}
	flags := g[3]
	at := 10
	if flags & 4 != 0 { // FEXTRA
		if at + 2 > len(g) {
			return false
		}
		xlen := int(g[at]) | int(g[at + 1]) << 8
		at += 2 + xlen
	}
	if flags & 8 != 0 { // FNAME
		for at < len(g) && g[at] != 0 {
			at += 1
		}
		at += 1
	}
	if flags & 16 != 0 { // FCOMMENT
		for at < len(g) && g[at] != 0 {
			at += 1
		}
		at += 1
	}
	if flags & 2 != 0 { // FHCRC
		at += 2
	}
	if at + 8 > len(g) {
		return false
	}
	out: bytes.Buffer
	defer bytes.buffer_destroy(&out)
	if err := zlib.inflate_from_byte_array(g[at:len(g) - 8], &out, raw = true); err != nil {
		return false
	}
	append(&c.body, ..out.buf[:])
	clear(&c.packed)
	return true
}

// -- Gemini ---------------------------------------------------------------------

/*
fetch_gemini runs one Gemini exchange over the TLS connection already made.
The URL and a CRLF go out. A line of `STATUS META` comes back, then the body
to the close. The status line is what `status` answers, the META its media type,
and the body is served as any other.
*/
fetch_gemini :: proc(f: ^Fetch, u: Url) {
	c := f.c
	req: [URL_MAX + 2]u8
	rn := copy(req[:], c.url[:c.url_len])
	rn += copy(req[rn:], "\r\n")
	if !stream_write(f, req[:rn]) {
		fail_fetch(c, "could not send the request")
		return
	}
	head := make([dynamic]u8, libuser.allocator())
	defer delete(head)
	chunk: [4096]u8
	eol := -1
	for eol < 0 {
		n := stream_read(f, chunk[:])
		if n <= 0 {
			fail_fetch(c, "the response ended before its header")
			return
		}
		append(&head, ..chunk[:n])
		for i in 0 ..< len(head) {
			if head[i] == '\n' {
				eol = i
				break
			}
		}
		if eol < 0 && len(head) > 1100 {
			fail_fetch(c, "the header is too long")
			return
		}
	}
	line := string(head[:eol])
	if len(line) > 0 && line[len(line) - 1] == '\r' {
		line = line[:len(line) - 1]
	}
	if len(line) < 2 {
		fail_fetch(c, "a header this client does not understand")
		return
	}
	c.status_len = copy(c.status[:], line)
	meta := len(line) > 3 ? line[3:] : ""
	c.ctype_len = copy(c.ctype[:], meta)
	for i in 0 ..< c.ctype_len {
		if c.ctype[i] == ';' || c.ctype[i] == ' ' {
			c.ctype_len = i
			break
		}
	}
	clear(&c.headers)
	append(&c.headers, ..transmute([]u8)line)
	append(&c.headers, '\n')
	c.state = .Streaming
	answer_held(c)
	if !read_until_close(f, head[eol + 1:]) {
		fail_fetch(c, "the body ended early")
		return
	}
	digest: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, c.body[:], digest[:])
	hex_of(digest[:], c.hash_hex[:])
	c.state = .Done
}

// -- The cookie jar ---------------------------------------------------------------

MAX_COOKIES :: 64

Cookie :: struct {
	used:      bool,
	host:      [128]u8,
	host_len:  int,
	path:      [128]u8,
	path_len:  int,
	name:      [64]u8,
	name_len:  int,
	value:     [512]u8,
	value_len: int,
}

jar: [MAX_COOKIES]Cookie

// jar_set adds a cookie, replacing one of the same host, path and name.
jar_set :: proc "contextless" (host, path, name, value: string) -> bool {
	if len(host) == 0 || len(name) == 0 || len(host) > 128 || len(path) > 128 || len(name) > 64 || len(value) > 512 {
		return false
	}
	free_slot := -1
	for i in 0 ..< MAX_COOKIES {
		k := &jar[i]
		if !k.used {
			if free_slot < 0 {
				free_slot = i
			}
			continue
		}
		if string(k.host[:k.host_len]) == host && string(k.path[:k.path_len]) == path && string(k.name[:k.name_len]) == name {
			k.value_len = copy(k.value[:], value)
			return true
		}
	}
	if free_slot < 0 {
		return false
	}
	k := &jar[free_slot]
	k^ = Cookie{used = true}
	k.host_len = copy(k.host[:], host)
	k.path_len = copy(k.path[:], len(path) > 0 ? path : "/")
	k.name_len = copy(k.name[:], name)
	k.value_len = copy(k.value[:], value)
	return true
}

jar_clear :: proc "contextless" () {
	for i in 0 ..< MAX_COOKIES {
		jar[i].used = false
	}
}

// jar_add_line takes `host path name value`, the line the jar file shows.
jar_add_line :: proc "contextless" (text: string) -> bool {
	line := text
	for len(line) > 0 && (line[len(line) - 1] == '\n' || line[len(line) - 1] == '\r') {
		line = line[:len(line) - 1]
	}
	host, r1 := word(line)
	path, r2 := word(r1)
	name, value := word(r2)
	return jar_set(host, path, name, value)
}

jar_render :: proc "contextless" (into: ^[dynamic]u8) {
	context = libuser.heap_context()
	for i in 0 ..< MAX_COOKIES {
		k := &jar[i]
		if !k.used {
			continue
		}
		append(into, ..k.host[:k.host_len])
		append(into, ' ')
		append(into, ..k.path[:k.path_len])
		append(into, ' ')
		append(into, ..k.name[:k.name_len])
		append(into, ' ')
		append(into, ..k.value[:k.value_len])
		append(into, '\n')
	}
}

// jar_matches says whether a cookie is sent to `host` for `path`: the host is
// the cookie's or ends in `.` and the cookie's, and the path starts with the
// cookie's.
jar_matches :: proc "contextless" (k: ^Cookie, host, path: string) -> bool #no_bounds_check {
	kh := string(k.host[:k.host_len])
	if host != kh {
		if len(host) <= len(kh) || host[len(host) - len(kh):] != kh || host[len(host) - len(kh) - 1] != '.' {
			return false
		}
	}
	kp := string(k.path[:k.path_len])
	return len(path) >= len(kp) && path[:len(kp)] == kp
}

// jar_header writes the `Cookie:` line for a request, if any cookie matches.
jar_header :: proc "contextless" (sink: ^libodin.Sink, host, path: string) {
	first := true
	for i in 0 ..< MAX_COOKIES {
		k := &jar[i]
		if !k.used || !jar_matches(k, host, path) {
			continue
		}
		libodin.put_str(sink, first ? "Cookie: " : "; ")
		libodin.put_str(sink, string(k.name[:k.name_len]))
		libodin.put_str(sink, "=")
		libodin.put_str(sink, string(k.value[:k.value_len]))
		first = false
	}
	if !first {
		libodin.put_str(sink, "\r\n")
	}
}

/*
jar_take keeps every `Set-Cookie` of a response for `host`. It takes the name
and value before the first `;`, and a `Path` attribute if one is given. `Domain` sets the
host the cookie is for, with its leading dot dropped. Expiry is not kept, so
a cookie stays until the jar forgets it. The jar is saved when it changed.
*/
jar_take :: proc "contextless" (headers: string, host: string) #no_bounds_check {
	changed := false
	at := 0
	for at < len(headers) {
		eol := at
		for eol < len(headers) && headers[eol] != '\n' {
			eol += 1
		}
		line := headers[at:eol]
		at = eol + 1
		if len(line) < 11 || !same_fold(line[:11], "set-cookie:") {
			continue
		}
		v := line[11:]
		for len(v) > 0 && v[0] == ' ' {
			v = v[1:]
		}
		for len(v) > 0 && (v[len(v) - 1] == '\r' || v[len(v) - 1] == ' ') {
			v = v[:len(v) - 1]
		}
		// name=value, then attributes.
		semi := len(v)
		for i in 0 ..< len(v) {
			if v[i] == ';' {
				semi = i
				break
			}
		}
		pair := v[:semi]
		eq := -1
		for i in 0 ..< len(pair) {
			if pair[i] == '=' {
				eq = i
				break
			}
		}
		if eq <= 0 {
			continue
		}
		name := pair[:eq]
		value := pair[eq + 1:]
		path := "/"
		chost := host
		attrs := semi < len(v) ? v[semi + 1:] : ""
		for len(attrs) > 0 {
			for len(attrs) > 0 && attrs[0] == ' ' {
				attrs = attrs[1:]
			}
			end := len(attrs)
			for i in 0 ..< len(attrs) {
				if attrs[i] == ';' {
					end = i
					break
				}
			}
			attr := attrs[:end]
			attrs = end < len(attrs) ? attrs[end + 1:] : ""
			if len(attr) > 5 && same_fold(attr[:5], "path=") {
				path = attr[5:]
			} else if len(attr) > 7 && same_fold(attr[:7], "domain=") {
				chost = attr[7:]
				if len(chost) > 0 && chost[0] == '.' {
					chost = chost[1:]
				}
			}
		}
		if jar_set(chost, path, name, value) {
			changed = true
		}
	}
	if changed {
		jar_save()
	}
}

// same_fold compares ASCII without case, for a header's name and its attributes.
same_fold :: proc "contextless" (a, b: string) -> bool #no_bounds_check {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		x := a[i]
		y := b[i]
		if x >= 'A' && x <= 'Z' {
			x += 'a' - 'A'
		}
		if y >= 'A' && y <= 'Z' {
			y += 'a' - 'A'
		}
		if x != y {
			return false
		}
	}
	return true
}

// jar_save writes the jar whole to the store, and jar_load reads it back.
jar_save :: proc "contextless" () {
	context = libuser.heap_context()
	text := make([dynamic]u8, libuser.allocator())
	defer delete(text)
	jar_render(&text)
	path: [300]u8
	file := libuser.cat_into(path[:], store, "/cookies")
	fd := libuser.create(file, abi.O_WRONLY | abi.O_TRUNC, 0o600)
	if fd < 0 {
		return
	}
	_ = libuser.write_full(int(fd), text[:])
	_ = libuser.close(int(fd))
}

jar_load :: proc() {
	path: [300]u8
	data, ok := libuser.read_file(libuser.cat_into(path[:], store, "/cookies"), context.allocator)
	if !ok {
		return
	}
	text := string(data)
	at := 0
	for at < len(text) {
		eol := at
		for eol < len(text) && text[eol] != '\n' {
			eol += 1
		}
		_ = jar_add_line(text[at:eol])
		at = eol + 1
	}
}

read_length :: proc(f: ^Fetch, first: []u8, length: int) -> bool {
	got := min(len(first), length)
	deliver(f.c, first[:got])
	chunk: [4096]u8
	for got < length {
		n := stream_read(f, chunk[:])
		if n <= 0 {
			return false
		}
		take := min(n, length - got)
		deliver(f.c, chunk[:take])
		got += take
	}
	return true
}

read_until_close :: proc(f: ^Fetch, first: []u8) -> bool {
	deliver(f.c, first)
	chunk: [4096]u8
	for {
		n := stream_read(f, chunk[:])
		if n < 0 {
			return false
		}
		if n == 0 {
			return true
		}
		deliver(f.c, chunk[:n])
	}
}

/*
read_chunked takes a chunked body. A hex size on a line, that many bytes, a
CRLF, and again, until a size of zero and the trailer's empty line. The raw
bytes are gathered in `raw` as they arrive and consumed from its head. So a
chunk split across reads, or two in one, both come out whole.
*/
read_chunked :: proc(f: ^Fetch, first: []u8) -> bool {
	raw := make([dynamic]u8, libuser.allocator())
	defer delete(raw)
	append(&raw, ..first)
	chunk: [4096]u8
	pos := 0
	for {
		// The size line.
		eol := -1
		for i := pos; i + 1 < len(raw); i += 1 {
			if raw[i] == '\r' && raw[i + 1] == '\n' {
				eol = i
				break
			}
		}
		if eol < 0 {
			n := stream_read(f, chunk[:])
			if n <= 0 {
				return false
			}
			append(&raw, ..chunk[:n])
			continue
		}
		size := 0
		for i := pos; i < eol; i += 1 {
			ch := raw[i]
			switch {
			case ch >= '0' && ch <= '9':
				size = size * 16 + int(ch - '0')
			case ch >= 'a' && ch <= 'f':
				size = size * 16 + int(ch - 'a') + 10
			case ch >= 'A' && ch <= 'F':
				size = size * 16 + int(ch - 'A') + 10
			case:
				// A chunk extension, or the end of the digits.
				i = eol
			}
		}
		data_at := eol + 2
		if size == 0 {
			return true
		}
		// The chunk's bytes and its CRLF, read until they are all here.
		for len(raw) < data_at + size + 2 {
			n := stream_read(f, chunk[:])
			if n <= 0 {
				return false
			}
			append(&raw, ..chunk[:n])
		}
		deliver(f.c, raw[data_at:][:size])
		pos = data_at + size + 2
		// Drop what was consumed, so `raw` does not grow with the body.
		if pos > 0 {
			copy(raw[:], raw[pos:])
			resize(&raw, len(raw) - pos)
			pos = 0
		}
	}
}

// extra_has says whether the conversation's own headers name `name`, lower
// case with its colon, at the start of a line.
extra_has :: proc "contextless" (c: ^Conv, name: string) -> bool {
	extra := string(c.extra[:c.extra_len])
	at := 0
	for at < len(extra) {
		e := at
		for e < len(extra) && extra[e] != '\n' {
			e += 1
		}
		line := extra[at:e]
		at = e + 1
		if len(line) < len(name) {
			continue
		}
		same := true
		for i in 0 ..< len(name) {
			ch := line[i]
			if ch >= 'A' && ch <= 'Z' {
				ch += 32
			}
			if ch != name[i] {
				same = false
				break
			}
		}
		if same {
			return true
		}
	}
	return false
}
