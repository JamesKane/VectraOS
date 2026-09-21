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

    /mnt/mail/ctl        account USER SERVER [PORT] [plain]; account dcaccount:URL; fetch;
                         idle [on|off]; smtp SERVER [PORT] [plain]; identity DOM;
                         seal on|off; spool DIR|off; invite; join LINE
    /mnt/mail/me         the address, and the key's fingerprint
    /mnt/mail/new        a message out: to, subject, replyto, attach, body
    /mnt/mail/inbox/     the mailbox, every message a directory
    /mnt/mail/sent/      what went out, the same shape
    /mnt/mail/<chat>/    a thread: the messages with one address, or a group's
    /mnt/mail/contacts/  an address a directory: name, key, fingerprint, verified

A chat is a thread. Every message in or out is in `inbox/` or `sent/` as
mail shows it, and in a chat as a messenger shows it: named for the
other address, or for the `Chat-Group-ID` header a group's messages
carry inside the seal. The same message stands in both.

`identity DOM` names the openpgp key factotum holds for the account's
user in DOM, and `seal.odin` is Autocrypt on it: the key in every
message's header, a key that arrives kept under `contacts/`, a message to
contacts with keys sealed, and a sealed message in opened with the
session key factotum hands back.

A write to `new` is section 4's block. `to` is one address or several
with commas, `replyto` an id in the inbox, whose message id goes in
`In-Reply-To`, and `attach` a path, sent as a base64 part. The message
is submitted over SMTP with `AUTH PLAIN`, the same password from
factotum for the SMTP server's name, and the write returns when the
server has taken it, or says why not. What went out is a message of
`sent/`.

The wire is TLS unless `plain` is said, over the trust roots in
`/lib/tls/roots`, and the boot line runs it plain against scripted
servers on this machine's own stack. `idle` keeps a session with the
server and takes each message as it lands, `idle.odin`, so `event`
answers as it does. Not yet: STARTTLS on 587.
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

DICT :: "account user server port plain    the account: its user and server, the port (993), and plain for no TLS\naccount dcaccount:url             a chatmail account in one request: the relay answers the address and password\nsmtp server port plain            where to submit mail, the port (465), and plain for no TLS\nspool dir            mail as files under dir instead of servers, off to stop\ninvite               make an invite for a contact to join verified, shown on ctl\njoin line            join a contact's invite, which runs the handshake over the next fetches\nidentity dom         the openpgp key factotum holds for the user in dom, for the seal\nseal on|off          whether a message to a contact without a key is refused\nfetch                take every message of the inbox\nidle on|off          a session kept with the server: what lands is taken as it lands, and event says so\nwrite: new           a message out: to, subject, replyto, attach lines, an empty line, the body\nread: inbox/<id>     a message: from, date, subject, body, type, raw, hash, replyto, links\n"

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
smtp: Account // Its user is the account's
status: [dynamic]u8
me_text: [NAME_MAX * 3 + 80]u8
roots: []^x509.Certificate

srv_name: [64]u8
srv_len: int

// `mailfs [-s name]` posts `/srv/name`, `mail` unless said, so two can run.
@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = {}
	#force_no_inline runtime._startup_runtime()
	args := libuser.args(block)
	srv_len = copy(srv_name[:], "/srv/mail")
	for i := 1; i + 1 < len(args); i += 1 {
		if args[i] == "-s" {
			srv_len = len(libuser.cat_into(srv_name[:], "/srv/", args[i + 1]))
		}
	}
	libthread.main(threadmain, nil)
}

threadmain :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = libuser.heap_context()
	libmsg.init(&net)
	_ = libmsg.conv(&net, "inbox")
	_ = libmsg.conv(&net, "sent")
	_ = libmsg.extra(&net, "contacts")
	net.dict = DICT
	net.on_ctl = on_ctl
	net.on_new = on_new
	status = make([dynamic]u8, 0, 256)
	roots = load_roots("/lib/tls/roots")
	why := libmsg.serve(&net, string(srv_name[:srv_len]))
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
		if libodin.has_prefix(rest, "dcaccount:") {
			return start_chatmail(tag, len(text), rest[len("dcaccount:"):])
		}
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
		set_me()
		rebuild_status()
		return 0
	case "smtp":
		server, r2 := word(rest)
		port, r3 := word(r2)
		plain, _ := word(r3)
		if port == "plain" {
			plain = port
			port = ""
		}
		if server == "" || len(server) > NAME_MAX * 2 || len(port) > 7 {
			return vectra9.EINVAL
		}
		if port == "" {
			port = "465"
		}
		smtp = Account{set = true, plain = plain == "plain"}
		smtp.slen = copy(smtp.server[:], server)
		smtp.plen = copy(smtp.port[:], port)
		rebuild_status()
		return 0
	case "spool":
		dir, _ := word(rest)
		if dir == "off" {
			spool.set = false
		} else {
			if dir == "" || len(dir) > 255 {
				return vectra9.EINVAL
			}
			spool.set = true
			spool.dlen = copy(spool.dir[:], dir)
		}
		rebuild_status()
		return 0
	case "invite":
		if !make_invite() {
			return vectra9.EINVAL
		}
		rebuild_status()
		return 0
	case "join":
		if !start_join(rest) {
			return vectra9.EINVAL
		}
		rebuild_status()
		return 0
	case "seal":
		how, _ := word(rest)
		switch how {
		case "on":
			seal_only = true
		case "off":
			if chatmail {
				// The relay refuses cleartext, so this cannot go off.
				return vectra9.EPERM
			}
			seal_only = false
		case:
			return vectra9.EINVAL
		}
		rebuild_status()
		return 0
	case "identity":
		dom, _ := word(rest)
		if !account.set || dom == "" || len(dom) > NAME_MAX {
			return vectra9.EINVAL
		}
		if !identity_set(dom) {
			return vectra9.ENOENT
		}
		set_me()
		rebuild_status()
		return 0
	case "idle":
		how, _ := word(rest)
		switch how {
		case "", "on":
			return start_idle(tag, len(text))
		case "off":
			stop_idle()
			return 0
		}
		return vectra9.EINVAL
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

// set_me writes `me`: the address, and the key's fingerprint when there is one.
set_me :: proc() {
	user := string(account.user[:account.ulen])
	server := string(account.server[:account.slen])
	if identity.set {
		net.me = libuser.cat_into(me_text[:], user, "@", server, "\nfpr ", string(identity.fpr[:]), "\n")
	} else {
		net.me = libuser.cat_into(me_text[:], user, "@", server, "\n")
	}
}

// on_new takes a message out: the block is read, a message is built of it,
// and a thread submits it while the write waits.
on_new :: proc(net: ^libmsg.Net, tag: vectra9.Tag, text: string) -> vectra9.Errno {
	if !account.set || !(smtp.set || spool.set) {
		return vectra9.EINVAL
	}
	n := libmsg.parse_new(text)
	defer libmsg.new_free(&n)
	if bad, has_bad := libmsg.new_unknown(&n); has_bad {
		libuser.eprint("mailfs: new: no such header here: ", bad, "\n")
		return vectra9.EINVAL
	}
	to, has_to := libmsg.new_header(&n, "to")
	if !has_to || len(to) == 0 {
		return vectra9.EINVAL
	}
	s := new(Send)
	s.tag = tag
	s.count = len(text)
	s.fd = -1
	s.held = true
	if !build_message(s, &n) {
		send_free(s)
		return vectra9.EINVAL
	}
	if libthread.threadcreate(send_thread, s, 256 * 1024) < 0 {
		send_free(s)
		return vectra9.ENOSPC
	}
	lib9p.hold(&net.srv)
	return 0
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

// -- Sending ------------------------------------------------------------------------

MAX_RCPT :: 16
ATTACH_MAX :: 1024 * 1024

// One message on its way out: the held write, the message built, and its
// recipients.
Send :: struct {
	using f: Fetch,
	text:    [dynamic]u8, // The RFC 5322 message, CRLF lines
	rcpts:   [MAX_RCPT][NAME_MAX * 2]u8,
	rlen:    [MAX_RCPT]int,
	nrcpt:   int,
	extra:   string, // Header lines the handshake adds, CRLF ended
	held:    bool, // A write to new waits on this; a handshake step has no writer
}

send_free :: proc(s: ^Send) {
	delete(s.text)
	free(s)
}

/*
build_message writes the block as a message: From is the account's
address, To the block's, Date now, a Message-ID of random hex at the
server, In-Reply-To the inbox message `replyto` names, and the body as
UTF-8 text, or a multipart with a base64 part per `attach`. False for a
recipient that is no address, or an attachment that cannot be read.
*/
build_message :: proc(s: ^Send, n: ^libmsg.New) -> bool {
	s.text = make([dynamic]u8, 0, 4096)
	to, _ := libmsg.new_header(n, "to")
	// The recipients, for RCPT TO, each a box.
	at := 0
	for at < len(to) {
		e := at
		for e < len(to) && to[e] != ',' {
			e += 1
		}
		box := libmime.trim(to[at:e])
		at = e + 1
		if len(box) == 0 {
			continue
		}
		if !libodin.contains(box, "@") || s.nrcpt >= MAX_RCPT {
			return false
		}
		s.rlen[s.nrcpt] = copy(s.rcpts[s.nrcpt][:], box)
		s.nrcpt += 1
	}
	if s.nrcpt == 0 {
		return false
	}
	user := string(account.user[:account.ulen])
	server := string(account.server[:account.slen])
	put(s, "From: ")
	put(s, user)
	put(s, "@")
	put(s, server)
	put(s, "\r\nTo: ")
	put(s, libmime.trim(to))
	put(s, "\r\n")
	if subject, has := libmsg.new_header(n, "subject"); has {
		put(s, "Subject: ")
		put(s, subject)
		put(s, "\r\n")
	}
	when_: [40]u8
	put(s, "Date: ")
	put(s, libmsg.format_822(now_seconds(), when_[:]))
	put(s, "\r\nMessage-ID: <")
	rnd: [16]u8
	hex: [32]u8
	_ = fill_random(rnd[:])
	libmsg.hex_of(rnd[:], hex[:])
	put(s, string(hex[:]))
	put(s, "@")
	put(s, server)
	put(s, ">\r\n")
	if replyto, has := libmsg.new_header(n, "replyto"); has && len(replyto) > 0 {
		inbox := libmsg.conv(&net, "inbox")
		if i := libmsg.find(inbox, replyto); i >= 0 {
			if mid, found := message_id_of(inbox.msgs[i].raw); found {
				put(s, "In-Reply-To: <")
				put(s, mid)
				put(s, ">\r\n")
			}
		}
	}
	put(s, "MIME-Version: 1.0\r\n")
	put_autocrypt(s)
	// The content, built apart: the outer message takes it as it is, or
	// sealed when every recipient has a key.
	head_len := len(s.text)
	if !put_content(s, n) {
		return false
	}
	content := make([]u8, len(s.text) - head_len)
	defer delete(content)
	copy(content, s.text[head_len:])
	subject, _ := libmsg.new_header(n, "subject")
	resize(&s.text, head_len)
	// The subject goes inside a sealed message, and a placeholder outside.
	if seal_content(s, subject, content) {
		fix_subject(s, head_len)
		return true
	}
	if seal_only {
		// The person wants only sealed mail, and a recipient has no key.
		return false
	}
	put(s, s.extra)
	append(&s.text, ..content)
	return true
}

// fix_subject replaces the subject line in the headers built so far with
// the placeholder a sealed message shows outside.
fix_subject :: proc(s: ^Send, head_len: int) {
	text := string(s.text[:head_len])
	at := libodin.index(text, "\r\nSubject: ")
	if at < 0 {
		return
	}
	e := at + 2
	for e < len(text) && text[e] != '\n' {
		e += 1
	}
	rest := make([]u8, len(s.text) - e - 1)
	copy(rest, s.text[e + 1:])
	resize(&s.text, at + 2)
	put(s, "Subject: ...\r\n")
	append(&s.text, ..rest)
	delete(rest)
}

// put_content writes the content type, encoding and body: plain text, or
// a multipart with a base64 part an attachment.
put_content :: proc(s: ^Send, n: ^libmsg.New) -> bool {
	_, has_attach := libmsg.new_attach(n, 0)
	if !has_attach {
		put(s, "Content-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n")
		put_body(s, n.body)
		return true
	}
	boundary := "=_vectra_part_"
	put(s, "Content-Type: multipart/mixed; boundary=\"")
	put(s, boundary)
	put(s, "\"\r\n\r\n--")
	put(s, boundary)
	put(s, "\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\n")
	put_body(s, n.body)
	for k := 0; ; k += 1 {
		path, has := libmsg.new_attach(n, k)
		if !has {
			break
		}
		data, ok := libuser.read_file(path, context.allocator)
		if !ok || len(data) > ATTACH_MAX {
			return false
		}
		defer delete(data)
		put(s, "\r\n--")
		put(s, boundary)
		put(s, "\r\nContent-Type: application/octet-stream; name=\"")
		put(s, libuser.basename(path))
		put(s, "\"\r\nContent-Disposition: attachment; filename=\"")
		put(s, libuser.basename(path))
		put(s, "\"\r\nContent-Transfer-Encoding: base64\r\n\r\n")
		enc := make([]u8, len(data) * 4 / 3 + len(data) / 57 * 2 + 8)
		m := libmime.encode_base64(data, enc)
		append(&s.text, ..enc[:m])
		delete(enc)
		put(s, "\r\n")
	}
	put(s, "--")
	put(s, boundary)
	put(s, "--\r\n")
	return true
}

// put_body writes the body with CRLF lines. The wire's dot-stuffing is
// done as the message goes out, not here, since the content may be sealed.
put_body :: proc(s: ^Send, body: string) {
	at := 0
	for at < len(body) {
		e := at
		for e < len(body) && body[e] != '\n' {
			e += 1
		}
		line := body[at:e]
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		put(s, line)
		put(s, "\r\n")
		at = e + 1
	}
}

// dot_stuffed answers the message with a line that begins with a dot
// doubled, which is what DATA wants, its own copy.
dot_stuffed :: proc(text: []u8) -> []u8 {
	dots := 0
	for i in 0 ..< len(text) {
		if text[i] == '.' && (i == 0 || text[i - 1] == '\n') {
			dots += 1
		}
	}
	out := make([]u8, len(text) + dots)
	n := 0
	for i in 0 ..< len(text) {
		if text[i] == '.' && (i == 0 || text[i - 1] == '\n') {
			out[n] = '.'
			n += 1
		}
		out[n] = text[i]
		n += 1
	}
	return out
}

put :: proc(s: ^Send, text: string) {
	append(&s.text, ..transmute([]u8)text)
}

// message_id_of answers a message's Message-ID, brackets off.
message_id_of :: proc(raw: string) -> (string, bool) {
	head, _ := libmime.split_head(raw)
	h := libmime.parse_headers(head)
	defer {
		delete(h.text)
		delete(h.list)
	}
	mid, has := libmime.header(&h, "message-id")
	if !has {
		return "", false
	}
	// A copy, since the headers go with this call.
	@(static) keep: [256]u8
	n := copy(keep[:], angle_off(mid))
	return string(keep[:n]), true
}

send_thread :: proc "contextless" (arg: rawptr) {
	context = libuser.heap_context()
	s := (^Send)(arg)
	err := vectra9.Errno(0)
	s.io = libthread.ioproc()
	if s.io == nil {
		err = vectra9.EIO
	} else {
		err = deliver(s)
		if s.tls != nil {
			free(s.tls)
		}
		if s.fd >= 0 {
			libnet.hangup(string(s.dir[:s.dirlen]))
			_ = libuser.close(s.fd)
		}
		libthread.ioclose(s.io)
	}
	if err != 0 && s.why != "" {
		libuser.eprint("mailfs: ", s.why, "\n")
	}
	if err == 0 {
		// What went out is a message of sent/, its own copy of the bytes.
		sent := libmsg.conv(&net, "sent")
		add_message(sent, clone(string(s.text[:])))
		rebuild_status()
	}
	if s.held {
		if req := lib9p.find_held_tag(&net.srv, s.tag); req != nil {
			if err == 0 {
				_ = lib9p.respond(req, vectra9.Rwrite{count = u32(s.count)})
			} else {
				_ = lib9p.respond(req, vectra9.error_reply(err))
			}
		}
	}
	send_free(s)
	libthread.threadexits("")
}

// submit runs one SMTP submission: the greeting, EHLO, AUTH PLAIN, the
// envelope, DATA with the message dot-stuffed and dot-ended, QUIT.
// deliver sends a built message: into the spool, or over SMTP.
deliver :: proc(s: ^Send) -> vectra9.Errno {
	if spool.set {
		if !deliver_spool(s) {
			s.why = "the spool would not take it"
			return vectra9.EIO
		}
		return 0
	}
	return submit(s)
}

submit :: proc(s: ^Send) -> vectra9.Errno {
	f := &s.f
	user := string(account.user[:account.ulen])
	server := string(smtp.server[:smtp.slen])
	pass: [256]u8
	password, has := ask_password(user, server, pass[:])
	if !has {
		f.why = "factotum holds no password for the submission server"
		return vectra9.EPERM
	}
	if !connect(f, server, string(smtp.port[:smtp.plen]), smtp.plain) {
		return vectra9.EIO
	}
	if !expect(f, "220") {
		f.why = "no greeting from the submission server"
		return vectra9.EIO
	}
	cmd: [1024]u8
	if !say(f, libuser.cat_into(cmd[:], "EHLO ", string(account.server[:account.slen]), "\r\n")) || !expect(f, "250") {
		f.why = "EHLO was refused"
		return vectra9.EIO
	}
	// AUTH PLAIN: a NUL, the user, a NUL, the password, in base64.
	plain: [512]u8
	pn := 0
	plain[pn] = 0
	pn += 1
	pn += copy(plain[pn:], user)
	plain[pn] = 0
	pn += 1
	pn += copy(plain[pn:], password)
	b64: [768]u8
	bn := libmime.encode_base64(plain[:pn], b64[:])
	if !say(f, libuser.cat_into(cmd[:], "AUTH PLAIN ", string(b64[:bn]), "\r\n")) || !expect(f, "235") {
		f.why = "the submission server refused the password"
		return vectra9.EPERM
	}
	if !say(f, libuser.cat_into(cmd[:], "MAIL FROM:<", user, "@", string(account.server[:account.slen]), ">\r\n")) || !expect(f, "250") {
		f.why = "MAIL FROM was refused"
		return vectra9.EIO
	}
	for i in 0 ..< s.nrcpt {
		if !say(f, libuser.cat_into(cmd[:], "RCPT TO:<", string(s.rcpts[i][:s.rlen[i]]), ">\r\n")) || !expect(f, "250") {
			f.why = "a recipient was refused"
			return vectra9.EINVAL
		}
	}
	if !say(f, "DATA\r\n") || !expect(f, "354") {
		f.why = "DATA was refused"
		return vectra9.EIO
	}
	wire := dot_stuffed(s.text[:])
	defer delete(wire)
	if !say(f, string(wire)) || !say(f, ".\r\n") || !expect(f, "250") {
		f.why = "the message was not taken"
		return vectra9.EIO
	}
	_ = say(f, "QUIT\r\n")
	_ = expect(f, "221")
	return 0
}

// expect reads a reply, its continuation lines too, and says whether its
// code is `code`.
expect :: proc(f: ^Fetch, code: string) -> bool {
	for {
		line, ok := read_line(f)
		if !ok || len(line) < 3 {
			return false
		}
		if len(line) > 3 && line[3] == '-' {
			continue
		}
		return line[:3] == code
	}
}

// connect dials and, unless plain, runs the TLS handshake.
connect :: proc(f: ^Fetch, server, port: string, plain: bool) -> bool {
	spec_buf: [256]u8
	spec := libuser.cat_into(spec_buf[:], "tcp!", server, "!", port)
	fd, dirlen, dok := libnet.dial_dir_via(spec, f.dir[:], libnet.Dial_IO{ctx = f, read = dial_read, write = dial_write})
	if !dok {
		f.why = "cannot dial the server"
		return false
	}
	f.fd = fd
	f.dirlen = dirlen
	if plain {
		return true
	}
	if len(roots) == 0 {
		f.why = "no trust roots, so no TLS"
		return false
	}
	f.tls = new(libtls.Client)
	libtls.client_init(f.tls, libtls.IO{ctx = f, read = tls_read, write = tls_write}, roots, time.unix(now_seconds(), 0), server)
	priv: [32]u8
	random: [32]u8
	if !fill_random(priv[:]) || !fill_random(random[:]) {
		f.why = "no entropy from /dev/random"
		return false
	}
	if !libtls.client_handshake(f.tls, priv, random) {
		f.why = "the TLS handshake failed"
		return false
	}
	return true
}

// -- The session --------------------------------------------------------------------

fetch :: proc(f: ^Fetch) -> vectra9.Errno {
	if spool.set {
		return fetch_spool()
	}
	if err := login(f, "a1", "a2"); err != 0 {
		return err
	}
	from := 1
	if !take_messages(f, "a3", &from) {
		return vectra9.EIO
	}
	_ = say(f, "a4 LOGOUT\r\n")
	_ = until_tagged(f, "a4")
	rebuild_status()
	return 0
}

// login dials the account's server with the password from factotum,
// reads the greeting, logs in and selects the inbox, under the two tags.
login :: proc(f: ^Fetch, login_tag, select_tag: string) -> vectra9.Errno {
	user := string(account.user[:account.ulen])
	server := string(account.server[:account.slen])
	pass: [256]u8
	password, has := ask_password(user, server, pass[:])
	if !has {
		f.why = "factotum holds no password for this account"
		return vectra9.EPERM
	}
	if !connect(f, server, string(account.port[:account.plen]), account.plain) {
		return vectra9.EIO
	}
	greet, gok := read_line(f)
	if !gok || !libodin.has_prefix(greet, "* OK") {
		f.why = "no greeting"
		return vectra9.EIO
	}
	cmd: [512]u8
	if !say(f, libuser.cat_into(cmd[:], login_tag, " LOGIN \"", user, "\" \"", password, "\"\r\n")) || !until_tagged(f, login_tag) {
		f.why = "the login was refused"
		return vectra9.EPERM
	}
	if !say(f, libuser.cat_into(cmd[:], select_tag, " SELECT INBOX\r\n")) || !until_tagged(f, select_tag) {
		f.why = "the inbox would not select"
		return vectra9.EIO
	}
	return 0
}

/*
take_messages fetches every message of the inbox from UID `next^` on,
puts each in `inbox/` and its chat, and moves `next^` past the last. A
server asked for `N:*` beyond its last UID answers the last message
again, which is skipped here by its UID. False, with `why`, when the
wire or the server would not.
*/
take_messages :: proc(f: ^Fetch, tag: string, next: ^int) -> bool {
	cmd: [128]u8
	num: [24]u8
	if !say(f, libuser.cat_into(cmd[:], tag, " UID FETCH ", libuser.itoa(num[:], i64(next^)), ":* (UID BODY.PEEK[])\r\n")) {
		f.why = "the fetch would not go"
		return false
	}
	inbox := libmsg.conv(&net, "inbox")
	for {
		line, ok := read_line(f)
		if !ok {
			f.why = "the fetch ended early"
			return false
		}
		if len(line) > len(tag) && line[:len(tag)] == tag && line[len(tag)] == ' ' {
			if !libodin.has_prefix(line[len(tag) + 1:], "OK") {
				f.why = "the fetch was refused"
				return false
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
			return false
		}
		uid := uid_of(line)
		raw := make([]u8, size)
		if !read_bytes(f, raw) {
			delete(raw)
			f.why = "a message ended early"
			return false
		}
		// The rest of the response, up to its closing parenthesis.
		_, _ = read_line(f)
		if uid > 0 && uid < next^ {
			// The last message again, already here.
			delete(raw)
			continue
		}
		add_message(inbox, string(raw))
		if uid >= next^ {
			next^ = uid + 1
		}
	}
	resolve_replies(inbox)
	return true
}

// add_message makes a message of RFC 5322 bytes and puts it in `conv`,
// `inbox` or `sent`, and in its chat. The bytes are the message's raw
// text, kept.
add_message :: proc(conv: ^libmsg.Conv, raw: string) {
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
	note_autocrypt(&p)
	group: [128]u8
	glen := 0
	jh: Join_Headers
	take_join_headers(&p.headers, &jh)
	sealed := p.type == "multipart/encrypted"
	opened := false
	if sealed {
		opened = unseal(&p, &m, group[:], &glen, &jh)
		if !opened {
			delete(m.body)
			m.body = clone("(a sealed message this key does not open)")
		}
	}
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
	// The chat it belongs to: the group's id, else the other address.
	chat: [256]u8
	chat_name := ""
	if glen > 0 {
		chat_name = libuser.cat_into(chat[:], "group-", safe_name(string(group[:glen])))
	} else {
		peer_header := conv.name == "sent" ? "to" : "from"
		if peer, has := libmime.header(&p.headers, peer_header); has {
			name_buf: [256]u8
			_, box := libmime.address(peer, name_buf[:])
			chat_name = libuser.cat_into(chat[:], safe_name(box))
		}
	}
	twin := msg_clone(&m)
	handshake := jh.slen > 0 && conv.name == "inbox" && (!sealed || (opened && m.body != "(a sealed message whose signature did not verify)"))
	if handshake {
		join_handle(&m, &jh, sealed)
	}
	libmsg.add(&net, conv, m)
	if len(chat_name) > 0 && chat_name != "inbox" && chat_name != "sent" && chat_name != "notify" {
		libmsg.add(&net, libmsg.conv(&net, chat_name), twin)
	} else {
		libmsg.msg_free(&twin)
	}
}

// msg_clone answers a message with strings of its own.
msg_clone :: proc(m: ^libmsg.Msg) -> libmsg.Msg {
	c := m^
	c.id = clone(m.id)
	c.from = clone(m.from)
	c.date_text = clone(m.date_text)
	c.subject = clone(m.subject)
	c.body = clone(m.body)
	c.type = clone(m.type)
	c.raw = clone(m.raw)
	c.replyto = clone(m.replyto)
	c.links = clone(m.links)
	return c
}

// safe_name keeps the letters, digits and `@ . _ -` of a name and turns
// the rest to `_`, so an address or a group id is a directory's name.
safe_name :: proc "contextless" (s: string) -> string {
	@(static) buf: [256]u8
	n := 0
	for i in 0 ..< len(s) {
		if n >= len(buf) {
			break
		}
		c := s[i]
		ok := (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '@' || c == '.' || c == '_' || c == '-'
		buf[n] = ok ? c : '_'
		n += 1
	}
	return string(buf[:n])
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
	if seal_only {
		append(&status, ..transmute([]u8)string(chatmail ? "seal on, chatmail\n" : "seal on\n"))
	}
	if identity.set {
		append(&status, ..transmute([]u8)string("identity "))
		append(&status, ..identity.dom[:identity.dlen])
		append(&status, ' ')
		append(&status, ..identity.fpr[:])
		append(&status, '\n')
	}
	if idle != nil {
		append(&status, ..transmute([]u8)string("idle\n"))
	}
	if spool.set {
		append(&status, ..transmute([]u8)string("spool "))
		append(&status, ..spool.dir[:spool.dlen])
		append(&status, '\n')
	}
	if join.ilen > 0 && join.stage == .Invited {
		append(&status, ..transmute([]u8)string("invite "))
		append(&status, ..join.invite[:join.ilen])
		append(&status, '\n')
	}
	if smtp.set {
		append(&status, ..transmute([]u8)string("smtp "))
		append(&status, ..smtp.server[:smtp.slen])
		append(&status, ' ')
		append(&status, ..smtp.port[:smtp.plen])
		append(&status, ..transmute([]u8)string(smtp.plain ? " plain\n" : " tls\n"))
	}
	inbox := libmsg.conv(&net, "inbox")
	sent := libmsg.conv(&net, "sent")
	num: [24]u8
	append(&status, ..transmute([]u8)string("inbox "))
	append(&status, ..transmute([]u8)libuser.itoa(num[:], i64(len(inbox.msgs))))
	append(&status, ..transmute([]u8)string("\nsent "))
	append(&status, ..transmute([]u8)libuser.itoa(num[:], i64(len(sent.msgs))))
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
