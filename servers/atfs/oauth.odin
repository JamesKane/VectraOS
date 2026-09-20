/*
OAuth on AT: `docs/WEB.md` section 7's "PAR, PKCE and DPoP", the way the
protocol wants a client to log in now, beside the app password.

`oauth PDS HANDLE` starts it. A DPoP key for the handle at the host is
made in `factotum` under `proto=dpop` unless one is there, and every
request to the server from then on carries a proof it signs. A PKCE
verifier is drawn and its challenge sent in a pushed authorization
request, PAR, with this program as a loopback client, and `ctl` then
shows the page to approve on:

    authorize PDS/oauth/authorize?client_id=...&request_uri=...

The person approves there and the server sends the browser to the
loopback address with a code in its query. This program listens there,
on this machine's own address at CALLBACK_PORT, takes the code off the
one request the browser makes, answers a line to close the window on,
and trades the code with the verifier and a proof for a token bound to
the key, `DPoP` rather than `Bearer`. The token goes to `factotum`
under `proto=oauth` with the account's DID, the way the app password's
session did. `code CODE` trades a code by hand when the browser is
elsewhere. The server's nonce, when it demands one, rides back in the
next proof.
*/
package atfs

import "core:crypto/hash"
import "core:encoding/json"
import "vsys:abi"
import "vsys:lib9p"
import "vsys:libjws"
import "vsys:libmsg"
import "vsys:libnet"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

CLIENT_ID :: "http://localhost"
CALLBACK_PORT :: "8091"
AT_SCOPE :: "atproto transition:generic"

// The flow in progress, between `oauth` and `code`.
Oauth :: struct {
	set:      bool,
	base:     [BASE_MAX]u8,
	blen:     int,
	user:     [NAME_MAX]u8,
	ulen:     int,
	verifier: [64]u8, // PKCE: the secret the token request proves
	vlen:     int,
	state:    [40]u8,
	slen:     int,
	callback: [160]u8, // Where the page sends the browser: this machine, CALLBACK_PORT
	clen:     int,
	nonce:    [128]u8, // The server's last DPoP nonce, or none
	nlen:     int,
	auth:     [768]u8, // The page to open, once the request is pushed
	alen:     int,
}

oauth: Oauth

Oauth_Step :: enum u8 {
	Push, // `oauth PDS HANDLE`: the key, the verifier, PAR, the page
	Code, // `code CODE`: the token, bound to the key
}

Oauth_Job :: struct {
	tag:   vectra9.Tag,
	count: int,
	io:    ^libthread.Ioproc,
	step:  Oauth_Step,
	arg:   [512]u8,
	alen:  int,
	arg2:  [NAME_MAX]u8,
	a2len: int,
	why:   string,
}

// start_oauth holds the ctl write and runs the step on a thread.
start_oauth :: proc(tag: vectra9.Tag, count: int, step: Oauth_Step, arg: string, arg2: string) -> vectra9.Errno {
	if len(arg) == 0 || len(arg) > 511 || len(arg2) > NAME_MAX {
		return vectra9.EINVAL
	}
	if step == .Code && (!oauth.set || oauth.alen == 0) {
		return vectra9.EINVAL // No request pushed to trade a code on
	}
	j := new(Oauth_Job)
	j.tag = tag
	j.count = count
	j.step = step
	j.alen = copy(j.arg[:], arg)
	j.a2len = copy(j.arg2[:], arg2)
	if libthread.threadcreate(oauth_thread, j, 256 * 1024) < 0 {
		free(j)
		return vectra9.ENOSPC
	}
	lib9p.hold(&net.srv)
	return 0
}

oauth_thread :: proc "contextless" (arg: rawptr) {
	context = libuser.heap_context()
	j := (^Oauth_Job)(arg)
	ok := false
	j.io = libthread.ioproc()
	if j.io != nil {
		switch j.step {
		case .Push:
			ok = push_request(j, string(j.arg[:j.alen]), string(j.arg2[:j.a2len]))
		case .Code:
			ok = trade_code(j, string(j.arg[:j.alen]))
		}
		libthread.ioclose(j.io)
	}
	if !ok && j.why != "" {
		libuser.eprint("atfs: ", j.why, "\n")
	}
	if ok {
		set_me()
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

// push_request makes the key and the verifier, pushes the authorization
// request, and writes the page to open.
push_request :: proc(j: ^Oauth_Job, base: string, user: string) -> bool {
	if !libmsg.is_url(base) || len(base) > BASE_MAX || user == "" {
		j.why = "oauth wants the server as a URL and the handle"
		return false
	}
	host := libmsg.host_of(base)
	// The flow begins here, so a proof signed for the pushed request
	// itself names this handle and this server.
	oauth = Oauth{set = true}
	oauth.blen = copy(oauth.base[:], base)
	oauth.ulen = copy(oauth.user[:], user)
	local: [64]u8
	ln := libmsg.read_small(j.io, "/net/local", local[:])
	if ln <= 0 {
		j.why = "no address of this machine for the callback"
		return false
	}
	oauth.clen = len(libuser.cat_into(oauth.callback[:], "http://", string(local[:ln]), ":", CALLBACK_PORT, "/callback"))
	// The key, in factotum, unless there is one for the handle and host.
	line: [512]u8
	probe: [64]u8
	if _, has := libmsg.factotum_ask(libuser.cat_into(line[:], "start dpop user=", user, " server=", host), "ok", probe[:]); !has {
		if !libmsg.factotum_write(libuser.cat_into(line[:], "key proto=dpop user=", user, " server=", host)) {
			j.why = "factotum would not make the key"
			return false
		}
	}
	// PKCE: a verifier of thirty-two random bytes, its challenge their hash.
	rnd: [32]u8
	if !fill_random(rnd[:]) {
		j.why = "no entropy"
		return false
	}
	oauth.vlen = libjws.base64url_encode(rnd[:], oauth.verifier[:])
	digest: [32]u8
	hash.hash_bytes_to_buffer(.SHA256, oauth.verifier[:oauth.vlen], digest[:])
	challenge: [48]u8
	cn := libjws.base64url_encode(digest[:], challenge[:])
	if !fill_random(rnd[:16]) {
		j.why = "no entropy"
		return false
	}
	oauth.slen = len(hex_of(rnd[:16], oauth.state[:]))
	form: [1024]u8
	body := libuser.cat_into(form[:], "response_type=code&client_id=", CLIENT_ID, "&redirect_uri=", string(oauth.callback[:oauth.clen]), "&code_challenge=", string(challenge[:cn]), "&code_challenge_method=S256&state=", string(oauth.state[:oauth.slen]), "&scope=atproto+transition%3Ageneric&login_hint=", user)
	url: [BASE_MAX + 64]u8
	text, status, ok := dpop_request(j.io, "POST", libuser.cat_into(url[:], base, "/oauth/par"), "Content-Type: application/x-www-form-urlencoded\n", body, "")
	defer delete(text)
	if !ok || status != 201 && status != 200 {
		oauth.set = false
		j.why = "the server would not take the pushed request"
		return false
	}
	v, err := json.parse_string(string(text), .JSON)
	defer json.destroy_value(v)
	o, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		j.why = "the pushed request's answer was not JSON"
		return false
	}
	request_uri := libmsg.str_of(o, "request_uri")
	if request_uri == "" {
		j.why = "the server answered no request URI"
		return false
	}
	encoded: [512]u8
	oauth.alen = len(libuser.cat_into(oauth.auth[:], base, "/oauth/authorize?client_id=", CLIENT_ID, "&request_uri=", form_encode_into(request_uri, encoded[:])))
	// The listener for the code, before the page can send it.
	if libthread.threadcreate(callback_thread, nil, 256 * 1024) < 0 {
		j.why = "no thread to listen for the code"
		return false
	}
	return true
}

/*
callback_thread listens where the page sends the browser, takes the
code and the state off the one request, answers a line to close the
window on, and trades the code. A state that is not this flow's is
refused, and nothing is traded.
*/
callback_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = libuser.heap_context()
	io := libthread.ioproc()
	if io != nil {
		serve_callback(io)
		libthread.ioclose(io)
	}
	libthread.threadexits("")
}

// serve_callback is the listener's one request, on the thread's io proc.
serve_callback :: proc(io: ^libthread.Ioproc) {
	spec: [32]u8
	dir: [libnet.DIAL_MAX]u8
	dirlen, ok := libnet.announce(libuser.cat_into(spec[:], "tcp!*!", CALLBACK_PORT), dir[:])
	if !ok {
		libuser.eprint("atfs: cannot listen for the code\n")
		return
	}
	served := string(dir[:dirlen])
	path: [160]u8
	lfd := libuser.open(libnet.join(path[:], served, "listen"), abi.O_RDONLY)
	if lfd < 0 {
		return
	}
	line: [64]u8
	n := libthread.ioread(io, int(lfd), line[:])
	_ = libuser.close(int(lfd))
	if n <= 0 {
		return
	}
	at := 0
	for at < int(n) && line[at] >= '0' && line[at] <= '9' {
		at += 1
	}
	cut := 0
	for i in 0 ..< len(served) {
		if served[i] == '/' {
			cut = i
		}
	}
	base: [160]u8
	accepted := libuser.cat_into(base[:], served[:cut + 1], string(line[:at]))
	dfd := libuser.open(libnet.join(path[:], accepted, "data"), abi.O_RDWR)
	if dfd < 0 {
		return
	}
	req: [2048]u8
	got := 0
	for got < len(req) {
		m := libthread.ioread(io, int(dfd), req[got:])
		if m <= 0 {
			break
		}
		got += int(m)
		if libodin_contains(string(req[:got]), "\r\n\r\n") || libodin_contains(string(req[:got]), "\n\n") {
			break
		}
	}
	code: [256]u8
	state: [64]u8
	cn := query_value(string(req[:got]), "code", code[:])
	sn := query_value(string(req[:got]), "state", state[:])
	good := cn > 0 && sn > 0 && string(state[:sn]) == string(oauth.state[:oauth.slen])
	libuser.eprint("atfs: the browser came back to the callback, ", good ? "this login's code" : "not this login's", "\n")
	answer := good ? "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 70\r\nConnection: close\r\n\r\n<html><body><p>Signed in. You may close this window.</p></body></html>" : "HTTP/1.1 400 Bad Request\r\nContent-Type: text/plain\r\nContent-Length: 21\r\nConnection: close\r\n\r\nnot this login's code"
	_ = libthread.iowrite(io, int(dfd), transmute([]u8)answer)
	_ = libuser.close(int(dfd))
	libnet.hangup(accepted)
	if good {
		j: Oauth_Job
		j.io = io
		if trade_code(&j, string(code[:cn])) {
			set_me()
			rebuild_status()
		} else if j.why != "" {
			libuser.eprint("atfs: ", j.why, "\n")
		}
	}
}

// query_value answers a query field's value off a request line, decoded.
query_value :: proc "contextless" (req: string, name: string, into: []u8) -> int {
	q := 0
	for q < len(req) && req[q] != '?' {
		q += 1
	}
	if q >= len(req) {
		return -1
	}
	e := q + 1
	for e < len(req) && req[e] != ' ' && req[e] != '\r' && req[e] != '\n' {
		e += 1
	}
	query := req[q + 1:e]
	pos := 0
	for pos < len(query) {
		amp := pos
		for amp < len(query) && query[amp] != '&' {
			amp += 1
		}
		pair := query[pos:amp]
		pos = amp + 1
		if len(pair) > len(name) && pair[:len(name)] == name && pair[len(name)] == '=' {
			v := pair[len(name) + 1:]
			n := 0
			i := 0
			for i < len(v) && n < len(into) {
				c := v[i]
				if c == '+' {
					into[n] = ' '
				} else if c == '%' && i + 2 < len(v) {
					into[n] = hex_nibble(v[i + 1]) << 4 | hex_nibble(v[i + 2])
					i += 2
				} else {
					into[n] = c
				}
				n += 1
				i += 1
			}
			return n
		}
	}
	return -1
}

hex_nibble :: proc "contextless" (c: u8) -> u8 {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	case c >= 'A' && c <= 'F':
		return c - 'A' + 10
	}
	return 0
}

libodin_contains :: proc "contextless" (s: string, want: string) -> bool {
	if len(want) == 0 || len(s) < len(want) {
		return false
	}
	for i in 0 ..< len(s) - len(want) + 1 {
		if s[i:i + len(want)] == want {
			return true
		}
	}
	return false
}

// trade_code trades the code for a token bound to the key, and puts the
// token in factotum under the account.
trade_code :: proc(j: ^Oauth_Job, code: string) -> bool {
	base := string(oauth.base[:oauth.blen])
	user := string(oauth.user[:oauth.ulen])
	form: [1024]u8
	body := libuser.cat_into(form[:], "grant_type=authorization_code&code=", code, "&redirect_uri=", string(oauth.callback[:oauth.clen]), "&client_id=", CLIENT_ID, "&code_verifier=", string(oauth.verifier[:oauth.vlen]))
	url: [BASE_MAX + 64]u8
	text, status, ok := dpop_request(j.io, "POST", libuser.cat_into(url[:], base, "/oauth/token"), "Content-Type: application/x-www-form-urlencoded\n", body, "")
	defer delete(text)
	if !ok || status != 200 {
		j.why = "the server refused the code"
		return false
	}
	v, err := json.parse_string(string(text), .JSON)
	defer json.destroy_value(v)
	o, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		j.why = "the token's answer was not JSON"
		return false
	}
	token := libmsg.str_of(o, "access_token")
	did := libmsg.str_of(o, "sub")
	if token == "" || len(token) > 128 || libmsg.str_of(o, "token_type") != "DPoP" {
		j.why = "the server answered no token bound to the key"
		return false
	}
	line: [512]u8
	if !libmsg.factotum_write(libuser.cat_into(line[:], "key proto=oauth user=", user, " server=", libmsg.host_of(base), " !token=", token)) {
		j.why = "factotum would not take the token"
		return false
	}
	account = Account{set = true, dpop = true}
	account.blen = copy(account.base[:], base)
	account.ulen = copy(account.user[:], user)
	account.dlen = copy(account.did[:], did)
	oauth.set = false
	return true
}

/*
dpop_request makes one request with a proof from factotum in its `DPoP`
header, and the token as `Authorization: DPoP` when one is given. A
server that wants its nonce first answers with one in `DPoP-Nonce`, and
the request goes again with it in the proof. The nonce is kept for the
requests after.
*/
dpop_request :: proc(io: ^libthread.Ioproc, method: string, url: string, headers: string, body: string, token: string) -> (text: []u8, status: int, ok: bool) {
	for try in 0 ..< 2 {
		proof: [2048]u8
		p, has := make_proof(method, url, string(oauth.nonce[:oauth.nlen]), token, proof[:])
		if !has {
			libuser.eprint("atfs: factotum gave no proof for ", method, " ", url, "\n")
			return nil, 0, false
		}
		all: [2560]u8
		hs := headers
		if token != "" {
			hs = libuser.cat_into(all[:], headers, "Authorization: DPoP ", token, "\nDPoP: ", p, "\n")
		} else {
			hs = libuser.cat_into(all[:], headers, "DPoP: ", p, "\n")
		}
		nonce: [128]u8
		nlen: int
		text, status, nlen, ok = libmsg.request_with(io, url, method, hs, body, "DPoP-Nonce", nonce[:])
		if nlen > 0 {
			oauth.nlen = copy(oauth.nonce[:], nonce[:nlen])
		}
		// A nonce demanded: once more, with it.
		if ok && (status == 400 || status == 401) && nlen > 0 && try == 0 {
			delete(text)
			continue
		}
		return text, status, ok
	}
	return nil, 0, false
}

// make_proof asks factotum for one request's proof, into `into`.
make_proof :: proc(method: string, url: string, nonce: string, token: string, into: []u8) -> (string, bool) {
	user := oauth.set ? string(oauth.user[:oauth.ulen]) : string(account.user[:account.ulen])
	base := oauth.set ? string(oauth.base[:oauth.blen]) : string(account.base[:account.blen])
	line: [512]u8
	// One rpc conversation: the key, then the proof.
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
	start := libuser.cat_into(line[:], "start dpop user=", user, " server=", libmsg.host_of(base))
	if libuser.write(int(rpc), transmute([]u8)start) != i64(len(start)) {
		return "", false
	}
	small: [64]u8
	if n := libuser.read(int(rpc), small[:]); n < 2 || string(small[:2]) != "ok" {
		return "", false
	}
	// The target URI in a proof has no query, RFC 9449.
	htu := url
	for i in 0 ..< len(url) {
		if url[i] == '?' {
			htu = url[:i]
			break
		}
	}
	ask: [1024]u8
	q := libuser.cat_into(ask[:], "proof htm=", method, " htu=", htu)
	if nonce != "" {
		q = libuser.cat_into(ask[:], q, " nonce=", nonce)
	}
	if token != "" {
		q = libuser.cat_into(ask[:], q, " ath=", token)
	}
	if libuser.write(int(rpc), transmute([]u8)q) != i64(len(q)) {
		return "", false
	}
	n := libuser.read(int(rpc), into)
	if n <= 6 || string(into[:6]) != "proof " {
		return "", false
	}
	e := int(n)
	for e > 6 && (into[e - 1] == '\n' || into[e - 1] == '\r') {
		e -= 1
	}
	return string(into[6:e]), true
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

hex_of :: proc "contextless" (bytes: []u8, into: []u8) -> string {
	digits := "0123456789abcdef"
	n := 0
	for b in bytes {
		if n + 2 > len(into) {
			break
		}
		into[n] = digits[b >> 4]
		into[n + 1] = digits[b & 15]
		n += 2
	}
	return string(into[:n])
}

// form_encode_into writes `s` as a form value into `into`.
form_encode_into :: proc "contextless" (s: string, into: []u8) -> string {
	hex := "0123456789ABCDEF"
	n := 0
	for c in transmute([]u8)s {
		if n + 3 > len(into) {
			break
		}
		if (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~' {
			into[n] = c
			n += 1
		} else {
			into[n] = '%'
			into[n + 1] = hex[c >> 4]
			into[n + 2] = hex[c & 15]
			n += 3
		}
	}
	return string(into[:n])
}
