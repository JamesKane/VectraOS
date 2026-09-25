/*
Chatmail: an account in one request, `docs/WEB.md` section 6.

A `dcaccount:` URL from a relay, typed or scanned, is a POST that answers
an address and a password. `account dcaccount:URL` on `ctl` makes the
request through `webfs`, writes the password to `factotum` under the
address's user and host, sets the account and the submission server to
that host, and turns the seal on. The relay refuses cleartext, so `seal
off` is refused while the account is a chatmail one.
*/
package mailfs

import "vsys:abi"
import "vsys:lib9p"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

chatmail: bool

// The relay's request in flight: the held write, and the URL.
Chatmail_Job :: struct {
	tag:   vectra9.Tag,
	count: int,
	io:    ^libthread.Ioproc,
	url:   [512]u8,
	ulen:  int,
}

// start_chatmail holds the ctl write and makes the relay's request on a
// thread of its own, since the request waits on the wire.
start_chatmail :: proc(tag: vectra9.Tag, count: int, url: string) -> vectra9.Errno {
	if len(url) == 0 || len(url) > 511 {
		return vectra9.EINVAL
	}
	j := new(Chatmail_Job)
	j.tag = tag
	j.count = count
	j.ulen = copy(j.url[:], url)
	if libthread.threadcreate(chatmail_thread, j, 256 * 1024) < 0 {
		free(j)
		return vectra9.ENOSPC
	}
	lib9p.hold(&net.srv)
	return 0
}

chatmail_thread :: proc "contextless" (arg: rawptr) {
	context = libuser.heap_context()
	j := (^Chatmail_Job)(arg)
	ok := false
	j.io = libthread.ioproc()
	if j.io != nil {
		ok = account_chatmail(j, string(j.url[:j.ulen]))
		libthread.ioclose(j.io)
	}
	if ok {
		rebuild_status()
	}
	if req := lib9p.find_held_tag(&net.srv, j.tag); req != nil {
		if ok {
			_ = lib9p.respond(req, vectra9.Rwrite{count = u32(j.count)})
		} else {
			_ = lib9p.respond(req, vectra9.error_reply(vectra9.EIO))
		}
	}
	free(j)
	libthread.threadexits("")
}

// account_chatmail takes the URL after `dcaccount:` and makes the account.
account_chatmail :: proc(j: ^Chatmail_Job, url: string) -> bool {
	body := make([]u8, 4096)
	defer delete(body)
	n := web_post(j, url, body)
	if n <= 0 {
		return false
	}
	email: [128]u8
	pass: [128]u8
	elen := json_string(string(body[:n]), "email", email[:])
	plen := json_string(string(body[:n]), "password", pass[:])
	if elen <= 0 || plen <= 0 {
		return false
	}
	addr := string(email[:elen])
	at := -1
	for i in 0 ..< len(addr) {
		if addr[i] == '@' {
			at = i
			break
		}
	}
	if at <= 0 || at + 1 >= len(addr) || at > NAME_MAX || len(addr) - at - 1 > NAME_MAX * 2 {
		return false
	}
	user := addr[:at]
	host := addr[at + 1:]
	// The password to factotum, for the IMAP and the submission server both.
	ctl := libuser.open("/mnt/factotum/ctl", abi.O_WRONLY)
	if ctl < 0 {
		if libuser.mount("/srv/factotum", "/mnt/factotum", 0) < 0 {
			return false
		}
		ctl = libuser.open("/mnt/factotum/ctl", abi.O_WRONLY)
		if ctl < 0 {
			return false
		}
	}
	line: [512]u8
	key := libuser.cat_into(line[:], "key proto=pass user=", user, " server=", host, " !password=", string(pass[:plen]))
	wrote := libuser.write(int(ctl), transmute([]u8)key) == i64(len(key))
	_ = libuser.close(int(ctl))
	if !wrote {
		return false
	}
	account = Account{set = true}
	account.ulen = copy(account.user[:], user)
	account.slen = copy(account.server[:], host)
	account.plen = copy(account.port[:], "993")
	smtp = Account{set = true}
	smtp.slen = copy(smtp.server[:], host)
	smtp.plen = copy(smtp.port[:], "465")
	chatmail = true
	seal_only = true
	set_me()
	return true
}

// web_post makes an empty POST to `url` through webfs, on the job's io
// proc, and answers the body's length in `into`, or -1.
web_post :: proc(j: ^Chatmail_Job, url: string, into: []u8) -> int {
	num: [16]u8
	hold, n := clone_hold(j, num[:])
	mounted := false
	if hold < 0 {
		if libthread.iomount(j.io, "/srv/web", "/mnt/web", 0) < 0 {
			return -1
		}
		mounted = true
		hold, n = clone_hold(j, num[:])
		if hold < 0 {
			_ = libuser.unmount("", "/mnt/web")
			return -1
		}
	}
	// A mount made for this request goes when it is done, or webfs would
	// wait on this namespace to end.
	defer if mounted {
		_ = libuser.unmount("", "/mnt/web")
	}
	// The clone stays open to the end, before the unmount: it is the hold
	// on the conversation, `libmsg.web_clone`.
	defer _ = libuser.close(hold)
	conv := string(num[:n])
	path: [128]u8
	line: [1024]u8
	ctl := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/ctl"), abi.O_WRONLY)
	if ctl < 0 {
		return -1
	}
	req := libuser.cat_into(line[:], "url ", url)
	ok := libthread.iowrite(j.io, int(ctl), transmute([]u8)req) == i64(len(req))
	ok = ok && libthread.iowrite(j.io, int(ctl), transmute([]u8)string("method POST")) > 0
	_ = libuser.close(int(ctl))
	if !ok {
		return -1
	}
	fd := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/body"), abi.O_RDONLY)
	if fd < 0 {
		return -1
	}
	total := 0
	for total < len(into) {
		got := libthread.ioread(j.io, int(fd), into[total:])
		if got <= 0 {
			break
		}
		total += int(got)
	}
	_ = libuser.close(int(fd))
	if hctl := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/ctl"), abi.O_WRONLY); hctl >= 0 {
		_ = libthread.iowrite(j.io, int(hctl), transmute([]u8)string("hangup"))
		_ = libuser.close(int(hctl))
	}
	return total
}

// clone_hold opens webfs's clone and reads the conversation's number, and
// keeps the descriptor, which holds the conversation. -1 when it will not.
clone_hold :: proc(j: ^Chatmail_Job, into: []u8) -> (fd: int, n: int) {
	cfd := libuser.open("/mnt/web/clone", abi.O_RDONLY)
	if cfd < 0 {
		return -1, 0
	}
	got := int(libthread.ioread(j.io, int(cfd), into))
	for got > 0 && (into[got - 1] == '\n' || into[got - 1] == '\r') {
		got -= 1
	}
	if got <= 0 {
		_ = libuser.close(int(cfd))
		return -1, 0
	}
	return int(cfd), got
}

read_small :: proc(j: ^Chatmail_Job, path: string, into: []u8) -> int {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return -1
	}
	total := 0
	for total < len(into) {
		n := libthread.ioread(j.io, int(fd), into[total:])
		if n <= 0 {
			break
		}
		total += int(n)
	}
	_ = libuser.close(int(fd))
	// A number off clone ends in a newline, which no path wants.
	for total > 0 && (into[total - 1] == '\n' || into[total - 1] == '\r') {
		total -= 1
	}
	return total
}

// json_string answers the string value of `key` in a flat JSON object,
// as far as a relay's answer goes: `"key": "value"`, no escapes but `\"`.
json_string :: proc "contextless" (text: string, key: string, into: []u8) -> int {
	quoted: [64]u8
	q := libuser.cat_into(quoted[:], "\"", key, "\"")
	at := libodin.index(text, q)
	if at < 0 {
		return -1
	}
	i := at + len(q)
	for i < len(text) && (text[i] == ' ' || text[i] == ':' || text[i] == '\t' || text[i] == '\n' || text[i] == '\r') {
		i += 1
	}
	if i >= len(text) || text[i] != '"' {
		return -1
	}
	i += 1
	n := 0
	for i < len(text) && text[i] != '"' && n < len(into) {
		if text[i] == '\\' && i + 1 < len(text) {
			i += 1
		}
		into[n] = text[i]
		n += 1
		i += 1
	}
	return n
}

