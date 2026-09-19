/*
mailfs -- a person's mail as `docs/WEB.md` section 4's shape, on IMAP.

Section 6. An account is a user and a server, and its password is a
line in `factotum`, `key proto=pass user=... server=... !password=...`,
asked for at login and never kept here. `fetch` logs in over IMAP4rev1,
takes every message of the inbox, and serves each as a message directory
in `libmsg`'s shape, `inbox/` the conversation. A message's sender, date
and subject come off its headers, its body is the part a reader shows
with the type it declares, and `raw` is the RFC 5322 bytes. A message's
`In-Reply-To` that names another message here becomes `replyto`.

    /mnt/mail/ctl        account USER SERVER [PORT] [plain]; fetch
    /mnt/mail/me         the address
    /mnt/mail/new        refused, until SMTP submission is in
    /mnt/mail/inbox/     the mailbox, every message a directory

The wire is TLS unless `plain` is said, over the trust roots in
`/lib/tls/roots`, and the boot line runs it plain against a scripted
server on this machine's own stack. Not yet: IDLE as the read that
parks, `new` over SMTP, the seal, contacts and chats.
*/
package mailfs

import "base:runtime"
import "core:crypto/x509"
import "core:time"
import "vsys:abi"
import "vsys:lib9p"
import "vsys:libmime"
import "vsys:libmsg"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libtls"
import "vsys:libuser"
import "vsys:vectra9"

NAME_MAX :: 64
MAX_MESSAGE :: 4 * 1024 * 1024
LINE_MAX :: 8192

DICT :: "account user server port plain    the account: its user and server, the port (993), and plain for no TLS\nfetch                take every message of the inbox\nread: inbox/<id>     a message: from, date, subject, body, type, raw, hash, replyto, links\n"

Account :: struct {
	set:    bool,
	plain:  bool,
	user:   [NAME_MAX]u8,
	ulen:   int,
	server: [NAME_MAX * 2]u8,
	slen:   int,
	port:   [8]u8,
	plen:   int,
}

// One fetch in flight: the held write, the connection, and the line
// reader over it.
Fetch :: struct {
	tag:    vectra9.Tag,
	count:  int,
	io:     ^libthread.Ioproc,
	fd:     int,
	dir:    [libnet.DIAL_MAX]u8,
	dirlen: int,
	tls:    ^libtls.Client,
	buf:    [LINE_MAX]u8,
	start:  int,
	end:    int,
	eof:    bool,
	why:    string,
}

net: libmsg.Net
account: Account
status: [dynamic]u8
me_text: [NAME_MAX * 3]u8
roots: []^x509.Certificate

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
	_ = libmsg.conv(&net, "inbox")
	net.dict = DICT
	net.on_ctl = on_ctl
	net.on_new = on_new
	status = make([dynamic]u8, 0, 256)
	roots = load_roots("/lib/tls/roots")
	why := libmsg.serve(&net, "/srv/mail")
	libthread.threadexitsall(why == .Removed ? "" : "hangup")
}

on_ctl :: proc(net: ^libmsg.Net, tag: vectra9.Tag, text: string) -> vectra9.Errno {
	line := text
	for len(line) > 0 && (line[len(line) - 1] == '\n' || line[len(line) - 1] == ' ') {
		line = line[:len(line) - 1]
	}
	verb, rest := word(line)
	switch verb {
	case "account":
		user, r2 := word(rest)
		server, r3 := word(r2)
		port, r4 := word(r3)
		plain, _ := word(r4)
		if port == "plain" {
			plain = port
			port = ""
		}
		if user == "" || server == "" || len(user) > NAME_MAX || len(server) > NAME_MAX * 2 || len(port) > 7 {
			return vectra9.EINVAL
		}
		if port == "" {
			port = "993"
		}
		account = Account{set = true, plain = plain == "plain"}
		account.ulen = copy(account.user[:], user)
		account.slen = copy(account.server[:], server)
		account.plen = copy(account.port[:], port)
		net.me = libuser.cat_into(me_text[:], user, "@", server, "\n")
		rebuild_status()
		return 0
	case "fetch":
		if !account.set {
			return vectra9.EINVAL
		}
		f := new(Fetch)
		f.tag = tag
		f.count = len(text)
		f.fd = -1
		if libthread.threadcreate(fetch_thread, f, 256 * 1024) < 0 {
			free(f)
			return vectra9.ENOSPC
		}
		lib9p.hold(&net.srv)
		return 0
	}
	return vectra9.EINVAL
}

// on_new refuses, until submission over SMTP is in.
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
		if f.tls != nil {
			free(f.tls)
		}
		if f.fd >= 0 {
			libnet.hangup(string(f.dir[:f.dirlen]))
			_ = libuser.close(f.fd)
		}
		libthread.ioclose(f.io)
	}
	if err != 0 && f.why != "" {
		libuser.eprint("mailfs: ", f.why, "\n")
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

// -- The session --------------------------------------------------------------------

fetch :: proc(f: ^Fetch) -> vectra9.Errno {
	user := string(account.user[:account.ulen])
	server := string(account.server[:account.slen])
	pass: [256]u8
	password, has := ask_password(user, server, pass[:])
	if !has {
		f.why = "factotum holds no password for this account"
		return vectra9.EPERM
	}

	spec_buf: [256]u8
	spec := libuser.cat_into(spec_buf[:], "tcp!", server, "!", string(account.port[:account.plen]))
	fd, dirlen, dok := libnet.dial_dir_via(spec, f.dir[:], libnet.Dial_IO{ctx = f, read = dial_read, write = dial_write})
	if !dok {
		f.why = "cannot dial the server"
		return vectra9.EIO
	}
	f.fd = fd
	f.dirlen = dirlen
	if !account.plain {
		if len(roots) == 0 {
			f.why = "no trust roots, so no TLS"
			return vectra9.EIO
		}
		f.tls = new(libtls.Client)
		libtls.client_init(f.tls, libtls.IO{ctx = f, read = tls_read, write = tls_write}, roots, time.unix(now_seconds(), 0), server)
		priv: [32]u8
		random: [32]u8
		if !fill_random(priv[:]) || !fill_random(random[:]) {
			f.why = "no entropy from /dev/random"
			return vectra9.EIO
		}
		if !libtls.client_handshake(f.tls, priv, random) {
			f.why = "the TLS handshake failed"
			return vectra9.EIO
		}
	}

	// The greeting, then a login.
	greet, gok := read_line(f)
	if !gok || !libodin.has_prefix(greet, "* OK") {
		f.why = "no greeting"
		return vectra9.EIO
	}
	cmd: [512]u8
	if !say(f, libuser.cat_into(cmd[:], "a1 LOGIN \"", user, "\" \"", password, "\"\r\n")) || !until_tagged(f, "a1") {
		f.why = "the login was refused"
		return vectra9.EPERM
	}
	if !say(f, "a2 SELECT INBOX\r\n") || !until_tagged(f, "a2") {
		f.why = "the inbox would not select"
		return vectra9.EIO
	}
	if !say(f, "a3 UID FETCH 1:* (UID BODY.PEEK[])\r\n") {
		return vectra9.EIO
	}
	inbox := libmsg.conv(&net, "inbox")
	got := 0
	for {
		line, ok := read_line(f)
		if !ok {
			f.why = "the fetch ended early"
			return vectra9.EIO
		}
		if libodin.has_prefix(line, "a3 ") {
			if !libodin.has_prefix(line, "a3 OK") {
				f.why = "the fetch was refused"
				return vectra9.EIO
			}
			break
		}
		if !libodin.has_prefix(line, "* ") || !libodin.contains(line, " FETCH ") {
			continue
		}
		size, has_literal := literal_size(line)
		if !has_literal {
			continue
		}
		if size > MAX_MESSAGE {
			f.why = "a message too large to hold"
			return vectra9.EIO
		}
		raw := make([]u8, size)
		if !read_bytes(f, raw) {
			delete(raw)
			f.why = "a message ended early"
			return vectra9.EIO
		}
		// The rest of the response, up to its closing parenthesis.
		_, _ = read_line(f)
		add_message(inbox, string(raw))
		got += 1
	}
	resolve_replies(inbox)
	_ = say(f, "a4 LOGOUT\r\n")
	_ = until_tagged(f, "a4")
	rebuild_status()
	return 0
}

// add_message makes a message of RFC 5322 bytes and puts it in the inbox.
// The bytes are the message's raw text, kept.
add_message :: proc(inbox: ^libmsg.Conv, raw: string) {
	p, ok := libmime.parse(raw)
	if !ok {
		delete(raw)
		return
	}
	defer libmime.part_free(&p)
	m: libmsg.Msg
	buf: [512]u8
	if from, has := libmime.header(&p.headers, "from"); has {
		m.from = clone(libmime.decode_words(from, buf[:]))
	}
	if subject, has := libmime.header(&p.headers, "subject"); has {
		m.subject = clone(libmime.decode_words(subject, buf[:]))
	}
	if date, has := libmime.header(&p.headers, "date"); has {
		m.date, _ = libmsg.parse_date(date)
		m.date_text = clone(libmime.trim(date))
	}
	body, btype := libmime.text_body(&p)
	m.body = clone(body)
	m.type = clone(btype != "" ? btype : "text/plain")
	netid := ""
	if mid, has := libmime.header(&p.headers, "message-id"); has {
		netid = angle_off(mid)
	}
	if netid == "" {
		netid = m.subject
	}
	idbuf: [128]u8
	m.id = clone(libmsg.make_id(m.date, netid, idbuf[:]))
	if irt, has := libmime.header(&p.headers, "in-reply-to"); has {
		// The other message's network id, resolved to its full id below.
		m.replyto = clone(angle_off(irt))
	}
	m.raw = raw
	libmsg.add(&net, inbox, m)
}

// resolve_replies turns each `replyto` that still names a message id into
// the full id of the message that bears it, or leaves it dated zero.
resolve_replies :: proc(inbox: ^libmsg.Conv) {
	for &m in inbox.msgs {
		if m.replyto == "" || len(m.replyto) > 17 && m.replyto[16] == '.' && is_hex16(m.replyto[:16]) {
			continue
		}
		idbuf: [128]u8
		tail := libmsg.make_id(0, m.replyto, idbuf[:])[17:]
		found := ""
		for other in inbox.msgs {
			if len(other.id) > 17 && other.id[17:] == tail {
				found = other.id
				break
			}
		}
		if found == "" {
			found = libmsg.make_id(0, m.replyto, idbuf[:])
		}
		delete(m.replyto)
		m.replyto = clone(found)
	}
}

is_hex16 :: proc "contextless" (s: string) -> bool {
	if len(s) != 16 {
		return false
	}
	for i in 0 ..< 16 {
		c := s[i]
		if !((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f')) {
			return false
		}
	}
	return true
}

// angle_off answers a message id without its angle brackets.
angle_off :: proc "contextless" (s: string) -> string {
	t := libmime.trim(s)
	if len(t) >= 2 && t[0] == '<' && t[len(t) - 1] == '>' {
		return t[1:len(t) - 1]
	}
	return t
}

// ask_password asks factotum for the account's password over `rpc`.
ask_password :: proc(user, server: string, into: []u8) -> (string, bool) {
	rpc := libuser.open("/mnt/factotum/rpc", abi.O_RDWR)
	if rpc < 0 {
		if libuser.mount("/srv/factotum", "/mnt/factotum", 0) < 0 {
			return "", false
		}
		rpc = libuser.open("/mnt/factotum/rpc", abi.O_RDWR)
		if rpc < 0 {
			return "", false
		}
	}
	defer _ = libuser.close(int(rpc))
	ask: [256]u8
	question := libuser.cat_into(ask[:], "start pass user=", user, " server=", server)
	if libuser.write(int(rpc), transmute([]u8)question) != i64(len(question)) {
		return "", false
	}
	n := libuser.read(int(rpc), into)
	if n <= 0 {
		return "", false
	}
	line := string(into[:n])
	for len(line) > 0 && line[len(line) - 1] == '\n' {
		line = line[:len(line) - 1]
	}
	if !libodin.has_prefix(line, "password ") {
		return "", false
	}
	return line[len("password "):], true
}

// -- Lines over the stream ------------------------------------------------------------

stream_read :: proc(f: ^Fetch, buf: []u8) -> int {
	if f.tls != nil {
		return libtls.client_read(f.tls, buf)
	}
	return int(libthread.ioread(f.io, f.fd, buf))
}

say :: proc(f: ^Fetch, text: string) -> bool {
	data := transmute([]u8)text
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

// read_line answers the next line without its CRLF. False at the end.
read_line :: proc(f: ^Fetch) -> (line: string, ok: bool) {
	for {
		for i in f.start ..< f.end {
			if f.buf[i] == '\n' {
				e := i
				if e > f.start && f.buf[e - 1] == '\r' {
					e -= 1
				}
				line = string(f.buf[f.start:e])
				f.start = i + 1
				return line, true
			}
		}
		if f.eof {
			return "", false
		}
		if f.start > 0 {
			copy(f.buf[:], f.buf[f.start:f.end])
			f.end -= f.start
			f.start = 0
		}
		if f.end == len(f.buf) {
			return "", false
		}
		n := stream_read(f, f.buf[f.end:])
		if n <= 0 {
			f.eof = true
			continue
		}
		f.end += n
	}
}

// read_bytes fills `into` from what the reader holds and then the stream.
read_bytes :: proc(f: ^Fetch, into: []u8) -> bool {
	n := copy(into, f.buf[f.start:f.end])
	f.start += n
	for n < len(into) {
		got := stream_read(f, into[n:])
		if got <= 0 {
			return false
		}
		n += got
	}
	return true
}

// until_tagged reads lines until the one tagged `tag`, and says whether
// it was OK.
until_tagged :: proc(f: ^Fetch, tag: string) -> bool {
	for {
		line, ok := read_line(f)
		if !ok {
			return false
		}
		if len(line) > len(tag) && line[:len(tag)] == tag && line[len(tag)] == ' ' {
			return libodin.has_prefix(line[len(tag) + 1:], "OK")
		}
	}
}

// literal_size answers the `{N}` a line ends with.
literal_size :: proc "contextless" (line: string) -> (int, bool) {
	if len(line) < 3 || line[len(line) - 1] != '}' {
		return 0, false
	}
	i := len(line) - 2
	v := 0
	mul := 1
	digits := 0
	for i >= 0 && line[i] >= '0' && line[i] <= '9' {
		v += int(line[i] - '0') * mul
		mul *= 10
		digits += 1
		i -= 1
	}
	if digits == 0 || i < 0 || line[i] != '{' {
		return 0, false
	}
	return v, true
}

tls_read :: proc(ctx: rawptr, buf: []u8) -> int {
	f := (^Fetch)(ctx)
	return int(libthread.ioread(f.io, f.fd, buf))
}

tls_write :: proc(ctx: rawptr, buf: []u8) -> int {
	f := (^Fetch)(ctx)
	return int(libthread.iowrite(f.io, f.fd, buf))
}

dial_read :: proc "contextless" (ctx: rawptr, fd: int, buf: []u8) -> i64 {
	f := (^Fetch)(ctx)
	return libthread.ioread(f.io, fd, buf)
}

dial_write :: proc "contextless" (ctx: rawptr, fd: int, data: []u8) -> i64 {
	f := (^Fetch)(ctx)
	return libthread.iowrite(f.io, fd, data)
}

// -- Small things ---------------------------------------------------------------------

rebuild_status :: proc() {
	clear(&status)
	if account.set {
		append(&status, ..transmute([]u8)string("account "))
		append(&status, ..account.user[:account.ulen])
		append(&status, ' ')
		append(&status, ..account.server[:account.slen])
		append(&status, ' ')
		append(&status, ..account.port[:account.plen])
		append(&status, ..transmute([]u8)string(account.plain ? " plain\n" : " tls\n"))
	}
	inbox := libmsg.conv(&net, "inbox")
	num: [24]u8
	append(&status, ..transmute([]u8)string("inbox "))
	append(&status, ..transmute([]u8)libuser.itoa(num[:], i64(len(inbox.msgs))))
	append(&status, '\n')
	net.status = string(status[:])
}

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
		c := line[i]
		if c < '0' || c > '9' {
			break
		}
		sec = sec * 10 + i64(c - '0')
	}
	return sec
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
