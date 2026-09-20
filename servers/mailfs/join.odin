/*
SecureJoin, Delta Chat's verification handshake, `docs/WEB.md` section
6, and the spool it is proven on.

An invite is a line the inviter's `ctl` shows after `invite`: the
inviter's fingerprint, address and name, and two secrets, the invite
number and the auth. The joiner writes it to `join`. Then the handshake
runs as messages, sealed once the keys are known:

    joiner  -> inviter   vc-request, plain, with the invite number and
                         the joiner's key in its Autocrypt header
    inviter -> joiner    vc-auth-required, sealed
    joiner  -> inviter   vc-request-with-auth, sealed, with the auth and
                         the joiner's fingerprint, once the inviter's
                         key proved to be the invite's
    inviter -> joiner    vc-contact-confirm, sealed, once the auth held

At the end `contacts/<address>/verified` reads `yes` on both sides. A
fingerprint that is not the invite's stops the joiner at the second
step, and `verified` stays `no`. The headers of the sealed steps are
inside the seal.

The spool is mail as files: `spool DIR` on `ctl` makes `fetch` read
`DIR/<own address>/` and a message out land in `DIR/<recipient>/`, so
two of these on one machine exchange mail with no server between them.
Over the servers the handshake runs under `idle`: a step lands, is
answered, and the answer goes out over SMTP on a thread of its own.
*/
package mailfs

import "vsys:abi"
import "vsys:libmime"
import "vsys:libmsg"
import "vsys:libodin"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

// -- The spool -----------------------------------------------------------------------------

Spool :: struct {
	set:  bool,
	dir:  [256]u8,
	dlen: int,
	next: int, // The next file's number
}

spool: Spool

// fetch_spool reads every message in the spool's directory for this
// address into the inbox, and takes each file away once read.
fetch_spool :: proc() -> vectra9.Errno {
	me: [256]u8
	dir := libuser.cat_into(me[:], string(spool.dir[:spool.dlen]), "/", string(account.user[:account.ulen]), "@", string(account.server[:account.slen]))
	names, ok := libuser.read_dir(dir)
	if !ok {
		return 0 // Nothing for this address yet
	}
	inbox := libmsg.conv(&net, "inbox")
	path: [512]u8
	for name in names {
		full := libuser.cat_into(path[:], dir, "/", name)
		data, rok := libuser.read_file(full, context.allocator)
		if rok {
			add_message(inbox, string(data))
		}
		_ = libuser.remove(full)
		delete(name)
	}
	delete(names)
	resolve_replies(inbox)
	rebuild_status()
	return 0
}

// deliver_spool writes a message into each recipient's directory.
deliver_spool :: proc(s: ^Send) -> bool {
	path: [512]u8
	num: [24]u8
	for i in 0 ..< s.nrcpt {
		dir := libuser.cat_into(path[:], string(spool.dir[:spool.dlen]), "/", string(s.rcpts[i][:s.rlen[i]]))
		_ = libuser.mkdir(string(spool.dir[:spool.dlen]))
		_ = libuser.mkdir(dir)
		spool.next += 1
		file: [512]u8
		full := libuser.cat_into(file[:], dir, "/", string(account.user[:account.ulen]), "-", libuser.itoa(num[:], i64(spool.next)), ".eml")
		_ = libuser.remove(full)
		fd := libuser.create(full, abi.O_WRONLY, 0o644)
		if fd < 0 {
			return false
		}
		ok := libuser.write_full(int(fd), s.text[:])
		_ = libuser.close(int(fd))
		if !ok {
			return false
		}
	}
	return true
}

// -- The handshake -------------------------------------------------------------------------

Join_Stage :: enum u8 {
	Idle,
	Invited, // This side made an invite and waits for a request
	Requested, // This side joined and waits for the auth-required
	Authed, // This side sent its auth and waits for the confirm
}

Join :: struct {
	stage:        Join_Stage,
	invitenumber: [33]u8, // Hex secrets
	auth:         [33]u8,
	peer_fpr:     [64]u8, // The fingerprint the invite named
	peer:         [256]u8, // The other address
	plen:         int,
	invite:       [512]u8, // The invite line, for ctl
	ilen:         int,
}

join: Join

// The headers a handshake message carries, outside or inside the seal.
Join_Headers :: struct {
	step:         [32]u8,
	slen:         int,
	invitenumber: [64]u8,
	ilen:         int,
	auth:         [64]u8,
	alen:         int,
	fingerprint:  [64]u8,
	flen:         int,
}

take_join_headers :: proc(h: ^libmime.Headers, into: ^Join_Headers) {
	if v, has := libmime.header(h, "secure-join"); has {
		into.slen = copy(into.step[:], libmime.trim(v))
	}
	if v, has := libmime.header(h, "secure-join-invitenumber"); has {
		into.ilen = copy(into.invitenumber[:], libmime.trim(v))
	}
	if v, has := libmime.header(h, "secure-join-auth"); has {
		into.alen = copy(into.auth[:], libmime.trim(v))
	}
	if v, has := libmime.header(h, "secure-join-fingerprint"); has {
		into.flen = copy(into.fingerprint[:], libmime.trim(v))
	}
}

// make_invite draws the two secrets and writes the invite line.
make_invite :: proc() -> bool {
	if !identity.set {
		return false
	}
	rnd: [32]u8
	if !fill_random(rnd[:]) {
		return false
	}
	libmsg.hex_of(rnd[:16], join.invitenumber[:32])
	libmsg.hex_of(rnd[16:], join.auth[:32])
	join.stage = .Invited
	join.ilen = len(libuser.cat_into(join.invite[:], "OPENPGP4FPR:", string(identity.fpr[:]), "#a=", string(account.user[:account.ulen]), "@", string(account.server[:account.slen]), "&n=", string(account.user[:account.ulen]), "&i=", string(join.invitenumber[:32]), "&s=", string(join.auth[:32])))
	return true
}

// start_join reads an invite line and sends the request.
start_join :: proc(invite: string) -> bool {
	if !identity.set || !libodin.has_prefix(invite, "OPENPGP4FPR:") {
		return false
	}
	rest := invite[len("OPENPGP4FPR:"):]
	hash_at := -1
	for i in 0 ..< len(rest) {
		if rest[i] == '#' {
			hash_at = i
			break
		}
	}
	if hash_at != 64 {
		return false
	}
	copy(join.peer_fpr[:], rest[:64])
	query := rest[65:]
	join.plen = 0
	join.ilen = 0
	at := 0
	for at < len(query) {
		e := at
		for e < len(query) && query[e] != '&' {
			e += 1
		}
		pair := query[at:e]
		at = e + 1
		if len(pair) < 3 || pair[1] != '=' {
			continue
		}
		switch pair[0] {
		case 'a':
			join.plen = copy(join.peer[:], pair[2:])
		case 'i':
			copy(join.invitenumber[:32], pair[2:])
		case 's':
			copy(join.auth[:32], pair[2:])
		}
	}
	if join.plen == 0 {
		return false
	}
	join.stage = .Requested
	extra: [128]u8
	return send_step(string(join.peer[:join.plen]), "vc-request", libuser.cat_into(extra[:], "Secure-Join-Invitenumber: ", string(join.invitenumber[:32]), "\r\n"))
}

/*
join_handle takes a message that arrived with handshake headers and
answers it, as the stage says. The message is already in the inbox, its
Autocrypt key in contacts, and a sealed one's signature checked.
*/
join_handle :: proc(m: ^libmsg.Msg, jh: ^Join_Headers, sealed: bool) {
	if jh.slen == 0 {
		return
	}
	step := string(jh.step[:jh.slen])
	name_buf: [256]u8
	_, from := libmime.address(m.from, name_buf[:])
	extra: [256]u8
	switch step {
	case "vc-request":
		if join.stage != .Invited || string(jh.invitenumber[:jh.ilen]) != string(join.invitenumber[:32]) {
			return
		}
		cert: [2048]u8
		if _, ok := contact_key(from, cert[:]); !ok {
			return
		}
		join.plen = copy(join.peer[:], from)
		_ = send_step(from, "vc-auth-required", "")
	case "vc-auth-required":
		if join.stage != .Requested || !sealed || from != string(join.peer[:join.plen]) {
			return
		}
		// The inviter's key must be the one the invite named.
		fpr, has := contact_file(from, "fingerprint")
		if !has || fpr != string(join.peer_fpr[:]) {
			libuser.eprint("mailfs: securejoin: the inviter's key is not the invite's, stopping\n")
			join.stage = .Idle
			return
		}
		join.stage = .Authed
		_ = send_step(from, "vc-request-with-auth", libuser.cat_into(extra[:], "Secure-Join-Auth: ", string(join.auth[:32]), "\r\nSecure-Join-Fingerprint: ", string(identity.fpr[:]), "\r\n"))
	case "vc-request-with-auth":
		if join.stage != .Invited || !sealed || from != string(join.peer[:join.plen]) {
			return
		}
		fpr, has := contact_file(from, "fingerprint")
		if !has || string(jh.auth[:jh.alen]) != string(join.auth[:32]) || string(jh.fingerprint[:jh.flen]) != fpr {
			libuser.eprint("mailfs: securejoin: the auth or the fingerprint did not hold\n")
			return
		}
		set_verified(from)
		join.stage = .Idle
		_ = send_step(from, "vc-contact-confirm", "")
	case "vc-contact-confirm":
		if join.stage != .Authed || !sealed || from != string(join.peer[:join.plen]) {
			return
		}
		set_verified(from)
		join.stage = .Idle
	}
}

contact_file :: proc(addr: string, name: string) -> (string, bool) {
	contacts := libmsg.extra(&net, "contacts")
	d := libmsg.xfind(contacts, addr)
	if d == nil {
		return "", false
	}
	return libmsg.xget(d, name)
}

set_verified :: proc(addr: string) {
	contacts := libmsg.extra(&net, "contacts")
	d := libmsg.xsub(contacts, addr)
	libmsg.xset(d, "verified", "yes")
}

// send_step sends one handshake message to `to`, with the step and any
// more headers, sealed when the recipient has a key. Into the spool it
// goes now; over the servers it goes on a sender thread, since this is
// called from the session that took the step it answers.
send_step :: proc(to: string, step: string, more: string) -> bool {
	if !spool.set && !smtp.set {
		return false
	}
	block: [1024]u8
	text := libuser.cat_into(block[:], "to: ", to, "\nsubject: Secure-Join: ", step, "\n\n", step, "\n")
	n := libmsg.parse_new(text)
	defer libmsg.new_free(&n)
	s := new(Send)
	s.fd = -1
	s.io = nil
	extra: [512]u8
	s.extra = libuser.cat_into(extra[:], "Secure-Join: ", step, "\r\n", more)
	if !build_message(s, &n) {
		send_free(s)
		return false
	}
	if !spool.set {
		if libthread.threadcreate(send_thread, s, 256 * 1024) < 0 {
			send_free(s)
			return false
		}
		return true
	}
	ok := deliver(s) == 0
	if ok {
		sent := libmsg.conv(&net, "sent")
		add_message(sent, clone(string(s.text[:])))
	}
	send_free(s)
	return ok
}

