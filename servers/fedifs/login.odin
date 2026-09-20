/*
The login: `docs/WEB.md` section 7's authorization code flow with the
out-of-band redirect, and the account it ends in.

`login BASE` registers this program with the instance at BASE, a URL's
scheme and host, and `ctl` then shows the page the person opens:

    authorize BASE/oauth/authorize?...client_id=...&redirect_uri=urn:ietf:wg:oauth:2.0:oob

The person approves there and the instance shows a code. `code CODE`
trades it for a token, asks the instance who the token is, and puts
the token in `factotum` under `proto=oauth`, the account's name and the
instance's host. Then `me` is the account, `fetch home` takes the
account's home timeline with the token, and `new` posts as it. `account
BASE USER` names an account whose token factotum already holds, so a
second session logs in nowhere.

The token is asked of factotum on every request and never kept here,
the way mail's password is. The client id and secret the registration
answered are kept, since a token request wants them.
*/
package fedifs

import "core:encoding/json"
import "vsys:lib9p"
import "vsys:libmsg"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

BASE_MAX :: 256
REDIRECT :: "urn:ietf:wg:oauth:2.0:oob"
SCOPES :: "read write follow"

Account :: struct {
	set:       bool,
	base:      [BASE_MAX]u8, // The instance: a URL's scheme and host
	blen:      int,
	user:      [NAME_MAX]u8, // The account's name on it
	ulen:      int,
	client_id: [128]u8,
	cilen:     int,
	secret:    [128]u8,
	slen:      int,
	authorize: [512]u8, // The page to open, once registered
	alen:      int,
}

account: Account
me_text: [NAME_MAX + BASE_MAX + 4]u8

// One step of the login in flight: the held write, and what it asks.
Login :: struct {
	tag:   vectra9.Tag,
	count: int,
	io:    ^libthread.Ioproc,
	step:  Login_Step,
	arg:   [512]u8,
	alen:  int,
	why:   string,
}

Login_Step :: enum u8 {
	Register, // `login BASE`: the app registered, the authorize page shown
	Code, // `code CODE`: the token, the account, and factotum
}

// start_login holds the ctl write and runs the step on a thread.
start_login :: proc(tag: vectra9.Tag, count: int, step: Login_Step, arg: string) -> vectra9.Errno {
	if len(arg) == 0 || len(arg) > 511 {
		return vectra9.EINVAL
	}
	if step == .Code && account.cilen == 0 {
		return vectra9.EINVAL // No registration to trade a code on
	}
	l := new(Login)
	l.tag = tag
	l.count = count
	l.step = step
	l.alen = copy(l.arg[:], arg)
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
		switch l.step {
		case .Register:
			ok = register(l, string(l.arg[:l.alen]))
		case .Code:
			ok = trade_code(l, string(l.arg[:l.alen]))
		}
		libthread.ioclose(l.io)
	}
	if !ok && l.why != "" {
		libuser.eprint("fedifs: ", l.why, "\n")
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

// register asks the instance for a client id and secret, and writes the
// authorize page the person opens.
register :: proc(l: ^Login, base: string) -> bool {
	if !libmsg.is_url(base) || len(base) > BASE_MAX {
		l.why = "login wants the instance as a URL"
		return false
	}
	url: [BASE_MAX + 64]u8
	body := "client_name=vectra&redirect_uris=urn%3Aietf%3Awg%3Aoauth%3A2.0%3Aoob&scopes=read+write+follow"
	text, status, ok := libmsg.request(l.io, libuser.cat_into(url[:], base, "/api/v1/apps"), "POST", "Content-Type: application/x-www-form-urlencoded\n", body)
	defer delete(text)
	if !ok || status != 200 {
		l.why = "the instance would not register the app"
		return false
	}
	v, err := json.parse_string(string(text), .JSON)
	defer json.destroy_value(v)
	o, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		l.why = "the registration's answer was not JSON"
		return false
	}
	id := libmsg.str_of(o, "client_id")
	secret := libmsg.str_of(o, "client_secret")
	if id == "" || secret == "" || len(id) > 128 || len(secret) > 128 {
		l.why = "the registration answered no client id and secret"
		return false
	}
	account = Account{}
	account.blen = copy(account.base[:], base)
	account.cilen = copy(account.client_id[:], id)
	account.slen = copy(account.secret[:], secret)
	account.alen = len(libuser.cat_into(account.authorize[:], base, "/oauth/authorize?response_type=code&client_id=", id, "&redirect_uri=", REDIRECT, "&scope=read+write+follow"))
	return true
}

// trade_code trades the code the person pasted for a token, asks who the
// token is, and puts the token in factotum under that name.
trade_code :: proc(l: ^Login, code: string) -> bool {
	base := string(account.base[:account.blen])
	url: [BASE_MAX + 64]u8
	form: [1024]u8
	body := libuser.cat_into(form[:], "grant_type=authorization_code&code=", code, "&client_id=", string(account.client_id[:account.cilen]), "&client_secret=", string(account.secret[:account.slen]), "&redirect_uri=", REDIRECT, "&scope=read+write+follow")
	text, status, ok := libmsg.request(l.io, libuser.cat_into(url[:], base, "/oauth/token"), "POST", "Content-Type: application/x-www-form-urlencoded\n", body)
	if !ok || status != 200 {
		delete(text)
		l.why = "the instance refused the code"
		return false
	}
	token: [128]u8
	tlen := 0
	{
		v, err := json.parse_string(string(text), .JSON)
		defer json.destroy_value(v)
		delete(text)
		o, is_obj := v.(json.Object)
		if err != .None || !is_obj {
			l.why = "the token's answer was not JSON"
			return false
		}
		t := libmsg.str_of(o, "access_token")
		if t == "" || len(t) > len(token) {
			l.why = "the instance answered no token"
			return false
		}
		tlen = copy(token[:], t)
	}
	// Who the token is: the account's name on the instance.
	auth: [160]u8
	header := libuser.cat_into(auth[:], "Authorization: Bearer ", string(token[:tlen]), "\n")
	text, status, ok = libmsg.request(l.io, libuser.cat_into(url[:], base, "/api/v1/accounts/verify_credentials"), "", header, "")
	if !ok || status != 200 {
		delete(text)
		l.why = "the instance would not say whose the token is"
		return false
	}
	v, err := json.parse_string(string(text), .JSON)
	defer json.destroy_value(v)
	delete(text)
	o, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		l.why = "the account's answer was not JSON"
		return false
	}
	acct := libmsg.str_of(o, "acct")
	if acct == "" || len(acct) > NAME_MAX {
		l.why = "the instance named no account"
		return false
	}
	// The token to factotum, under the account's name and the host.
	line: [512]u8
	key := libuser.cat_into(line[:], "key proto=oauth user=", acct, " server=", libmsg.host_of(base), " !token=", string(token[:tlen]))
	if !libmsg.factotum_write(key) {
		l.why = "factotum would not take the token"
		return false
	}
	account.ulen = copy(account.user[:], acct)
	account.set = true
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

set_me :: proc() {
	if !account.set {
		net.me = ""
		return
	}
	net.me = libuser.cat_into(me_text[:], string(account.user[:account.ulen]), "@", libmsg.host_of(string(account.base[:account.blen])), "\n")
}

// ask_token asks factotum for the account's token over rpc, into `into`.
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
		return libuser.cat_into(into, base, "/api/v1/timelines/home")
	case "notifications":
		return libuser.cat_into(into, base, "/api/v1/notifications")
	}
	return ""
}
