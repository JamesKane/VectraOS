/*
The login on AT: `docs/WEB.md` section 7's app password on
`createSession` first, since the protocol still accepts one for a
command-line tool, and the account it ends in.

`login PDS HANDLE` asks `factotum` for the app password it holds under
`proto=pass`, the handle and the PDS's host, and sends it to
`com.atproto.server.createSession`. The session's access token goes
back to `factotum` under `proto=oauth`, the handle and the host, asked
for on every request and never kept here. Then `me` is the handle and
the DID, and `fetch home` takes the account's timeline with the token.
`account PDS HANDLE` names an account whose token factotum holds
already. Not yet: OAuth with PAR, PKCE and DPoP, and the refresh.
*/
package atfs

import "core:encoding/json"
import "vsys:lib9p"
import "vsys:libmsg"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

BASE_MAX :: 256

Account :: struct {
	set:  bool,
	dpop: bool, // The token is bound to a key, and every request carries a proof
	base: [BASE_MAX]u8, // The PDS: a URL's scheme and host
	blen: int,
	user: [NAME_MAX]u8, // The handle
	ulen: int,
	did:  [128]u8,
	dlen: int,
}

account: Account
me_text: [NAME_MAX + 140]u8

// One login in flight: the held write, the PDS and the handle.
Login :: struct {
	tag:   vectra9.Tag,
	count: int,
	io:    ^libthread.Ioproc,
	base:  [BASE_MAX]u8,
	blen:  int,
	user:  [NAME_MAX]u8,
	ulen:  int,
	why:   string,
}

// start_login holds the ctl write and runs the session on a thread.
start_login :: proc(tag: vectra9.Tag, count: int, base: string, user: string) -> vectra9.Errno {
	if !libmsg.is_url(base) || len(base) > BASE_MAX || user == "" || len(user) > NAME_MAX {
		return vectra9.EINVAL
	}
	l := new(Login)
	l.tag = tag
	l.count = count
	l.blen = copy(l.base[:], base)
	l.ulen = copy(l.user[:], user)
	if libthread.threadcreate(login_thread, l, 256 * 1024) < 0 {
		free(l)
		return vectra9.ENOSPC
	}
	lib9p.hold(&net.srv)
	return 0
}

login_thread :: proc "contextless" (arg: rawptr) {
	context = libuser.heap_context()
	l := (^Login)(arg)
	ok := false
	l.io = libthread.ioproc()
	if l.io != nil {
		ok = create_session(l)
		libthread.ioclose(l.io)
	}
	if !ok && l.why != "" {
		libuser.eprint("atfs: ", l.why, "\n")
	}
	if ok {
		set_me()
		rebuild_status()
	}
	if req := lib9p.find_held_tag(&net.srv, l.tag); req != nil {
		if ok {
			_ = lib9p.respond(req, vectra9.Rwrite{count = u32(l.count)})
		} else {
			_ = lib9p.respond(req, vectra9.error_reply(vectra9.EIO))
		}
	}
	free(l)
	libthread.threadexits("")
}

// create_session sends the app password and keeps the session's token
// in factotum.
create_session :: proc(l: ^Login) -> bool {
	base := string(l.base[:l.blen])
	user := string(l.user[:l.ulen])
	host := libmsg.host_of(base)
	ask: [512]u8
	pw: [256]u8
	password, has := libmsg.factotum_ask(libuser.cat_into(ask[:], "start pass user=", user, " server=", host), "password ", pw[:])
	if !has {
		l.why = "factotum holds no app password for that handle and host"
		return false
	}
	body_buf: [768]u8
	body := libuser.cat_into(body_buf[:], "{\"identifier\": \"", user, "\", \"password\": \"", password, "\"}")
	url: [BASE_MAX + 64]u8
	text, status, ok := libmsg.request(l.io, libuser.cat_into(url[:], base, "/xrpc/com.atproto.server.createSession"), "POST", "Content-Type: application/json\n", body)
	defer delete(text)
	if !ok || status != 200 {
		l.why = "the server refused the session"
		return false
	}
	v, err := json.parse_string(string(text), .JSON)
	defer json.destroy_value(v)
	o, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		l.why = "the session's answer was not JSON"
		return false
	}
	token := libmsg.str_of(o, "accessJwt")
	did := libmsg.str_of(o, "did")
	if token == "" || len(token) > 128 || len(did) > len(account.did) {
		l.why = "the session answered no token"
		return false
	}
	line: [512]u8
	if !libmsg.factotum_write(libuser.cat_into(line[:], "key proto=oauth user=", user, " server=", host, " !token=", token)) {
		l.why = "factotum would not take the token"
		return false
	}
	account = Account{set = true}
	account.blen = copy(account.base[:], base)
	account.ulen = copy(account.user[:], user)
	account.dlen = copy(account.did[:], did)
	return true
}

// set_account names an account whose token factotum holds already.
set_account :: proc(base: string, user: string) -> bool {
	if !libmsg.is_url(base) || len(base) > BASE_MAX || user == "" || len(user) > NAME_MAX {
		return false
	}
	account = Account{set = true}
	account.blen = copy(account.base[:], base)
	account.ulen = copy(account.user[:], user)
	set_me()
	return true
}

// set_me writes `me`: the handle, and the DID when the session said it.
set_me :: proc() {
	if !account.set {
		net.me = ""
		return
	}
	if account.dlen > 0 {
		net.me = libuser.cat_into(me_text[:], string(account.user[:account.ulen]), "\ndid ", string(account.did[:account.dlen]), "\n")
	} else {
		net.me = libuser.cat_into(me_text[:], string(account.user[:account.ulen]), "\n")
	}
}

// ask_token asks factotum for the account's token, into `into`.
ask_token :: proc(into: []u8) -> (string, bool) {
	ask: [512]u8
	question := libuser.cat_into(ask[:], "start oauth user=", string(account.user[:account.ulen]), " server=", libmsg.host_of(string(account.base[:account.blen])))
	return libmsg.factotum_ask(question, "token ", into)
}

// timeline_url answers the URL of one of the account's own timelines,
// `home` or `notifications`, or "" for a name that is not one.
timeline_url :: proc(name: string, into: []u8) -> string {
	if !account.set {
		return ""
	}
	base := string(account.base[:account.blen])
	switch name {
	case "home":
		return libuser.cat_into(into, base, "/xrpc/app.bsky.feed.getTimeline?limit=50")
	case "notifications":
		return libuser.cat_into(into, base, "/xrpc/app.bsky.notification.listNotifications")
	}
	return ""
}
