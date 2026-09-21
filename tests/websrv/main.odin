/*
websrv -- a scripted HTTP/1.1 server on `/net/tcp`, so `servers/webfs` is
proven over a real connection.

It announces a port and serves a number of connections, one after another,
each a GET answered by its path. `/` is `hello, web` as a chunked body in two
chunks, the framing a client must reassemble. `/gz` is a body gzipped, with
the header that says so. `/cookie` sets a cookie. `/whoami` answers with the
`Cookie` header it was sent, or `none`.

Then it exits `ok`, or the name of the step that did not hold. The boot
self-test runs it and has `webfs` fetch from it, `docs/WEB.md` step 0.

    websrv [port] [connections]   default 8080 and 1
*/
package websrv

import "vsys:abi"
import "core:crypto/ecdsa"
import "core:crypto/ed25519"
import "core:crypto/hash"
import "core:encoding/json"
import "vsys:libjws"
import "vsys:libmsg"
import "vsys:libolm"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libuser"

CHUNKED :: "HTTP/1.1 200 OK\r\nContent-Type: text/plain; charset=utf-8\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n6\r\nhello,\r\n5\r\n web\n\r\n0\r\n\r\n"
GZ_HEAD :: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Encoding: gzip\r\nContent-Length: 42\r\nConnection: close\r\n\r\n"
// `hello, compressed web\n`, as `gzip -9 -n` framed it.
GZ_BODY := [?]u8{
	0x1f, 0x8b, 0x08, 0x00, 0x00, 0x00, 0x00, 0x00, 0x02, 0x03, 0xcb, 0x48,
	0xcd, 0xc9, 0xc9, 0xd7, 0x51, 0x48, 0xce, 0xcf, 0x2d, 0x28, 0x4a, 0x2d,
	0x2e, 0x4e, 0x4d, 0x51, 0x28, 0x4f, 0x4d, 0xe2, 0x02, 0x00, 0x80, 0xd1,
	0xd8, 0x6d, 0x16, 0x00, 0x00, 0x00,
}
COOKIE :: "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nSet-Cookie: session=abc; Path=/\r\nContent-Length: 11\r\nConnection: close\r\n\r\ncookie set\n"
NOT_FOUND :: "HTTP/1.1 404 Not Found\r\nContent-Length: 0\r\nConnection: close\r\n\r\n"
// A login page, the form a reader fills: a name, a password, a button. The
// POST it sends is answered with the name, so the reader's typing is proven
// by what comes back.
LOGIN_HEAD :: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 314\r\nConnection: close\r\n\r\n"
LOGIN_BODY :: "<html><head><title>Sign in</title></head><body><h1>Sign in</h1><form method=\"post\" action=\"/login\"><p>Name <input type=\"text\" name=\"user\" placeholder=\"name\"></p><p>Password <input type=\"password\" name=\"pass\"></p><input type=\"hidden\" name=\"next\" value=\"/\"><input type=\"submit\" value=\"Sign in\"></form></body></html>\n"

fail :: proc "contextless" (what: string) -> ! {
	libuser.eprint("websrv: ", what, "\n")
	libuser.exits(what)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	port := len(args) >= 2 ? args[1] : "8080"
	served_port = port
	count := 1
	if len(args) >= 3 {
		if v, ok := libuser.atoi(args[2]); ok && v > 0 {
			count = int(v)
		}
	}

	addr: [64]u8
	spec := libuser.cat_into(addr[:], "tcp!*!", port)
	dir: [libnet.DIAL_MAX]u8
	dirlen, ok := libnet.announce(spec, dir[:])
	if !ok {
		fail("announce")
	}
	served := string(dir[:dirlen])
	path: [160]u8
	lfd := libuser.open(libnet.join(path[:], served, "listen"), abi.O_RDONLY)
	if lfd < 0 {
		fail("listen")
	}
	libuser.eprint("websrv: listening at ", served, "\n")
	bob_init()
	for _ in 0 ..< count {
		serve_one(lfd, served)
	}
	_ = libuser.close(int(lfd))
	libuser.exits("ok")
}

// serve_one takes the next connection off `listen` and answers its GET by path.
serve_one :: proc(lfd: i64, served: string) {
	path: [160]u8
	line: [64]u8
	n := libuser.read(int(lfd), line[:])
	if n <= 0 {
		fail("nothing connected")
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
		fail("open the stream")
	}

	// The request, up to its empty line.
	req: [4096]u8
	got := 0
	for {
		m := libuser.read(int(dfd), req[got:])
		if m <= 0 {
			fail("the request ended early")
		}
		got += int(m)
		if has_blank_line(req[:got]) || got == len(req) {
			break
		}
	}
	post := got >= 5 && string(req[:5]) == "POST "
	put_ := got >= 4 && string(req[:4]) == "PUT "
	if !post && !put_ && (got < 4 || string(req[:4]) != "GET ") {
		fail("not a GET, a POST or a PUT")
	}
	// The path is the second word of the request line.
	text := string(req[post ? 5 : 4:got])
	// A PUT is a POST here: a body by its length, answered by its path.
	post = post || put_
	sp := 0
	for sp < len(text) && text[sp] != ' ' {
		sp += 1
	}
	rpath := text[:sp]
	// A query rides after the path, and the path is what is answered.
	query := ""
	for i in 0 ..< len(rpath) {
		if rpath[i] == '?' {
			query = rpath[i + 1:]
			rpath = rpath[:i]
			break
		}
	}
	// A POST's body follows the blank line, Content-Length bytes of it,
	// which may still be on the wire.
	body := ""
	if post {
		want := header_int(text, "content-length")
		head_end := blank_line_end(req[:got])
		for got < head_end + want && got < len(req) {
			m := libuser.read(int(dfd), req[got:])
			if m <= 0 {
				break
			}
			got += int(m)
		}
		body = string(req[head_end:min(head_end + want, got)])
	}
	ok := true
	libuser.eprint("websrv: ", put_ ? "PUT " : post ? "POST " : "GET ", rpath, "\n")
	// A bearer token in the request, for the instance's paths.
	bearer := header_value(text, "authorization")
	// A room's event put: its path names the room and the event type. A
	// sealed one opens with the session Glenda shared, and what it said
	// goes into a file for the test to read.
	if post && libodin.has_prefix(rpath, "/_matrix/client/v3/rooms/") && libodin.contains(rpath, "/send/m.room.message/") {
		if bearer == "Bearer syt-1" && libodin.contains(body, "\"msgtype\": \"m.text\"") {
			ok = say_json(dfd, 200, "{\"event_id\": \"$sent1\"}\n")
		} else {
			ok = say_json(dfd, 401, "{\"errcode\": \"M_UNKNOWN_TOKEN\"}\n")
		}
		if !ok {
			fail("write the reply")
		}
		return
	}
	if post && libodin.has_prefix(rpath, "/_matrix/client/v3/rooms/") && libodin.contains(rpath, "/send/m.room.encrypted/") {
		if bearer == "Bearer syt-1" && bob_open_event(body) {
			ok = say_json(dfd, 200, "{\"event_id\": \"$sealed_out\"}\n")
		} else {
			ok = say_json(dfd, 400, "{\"errcode\": \"M_UNKNOWN\", \"error\": \"the sealed event would not open here\"}\n")
		}
		if !ok {
			fail("write the reply")
		}
		return
	}
	// The room's verbs: a join lands the invited room in the sync after,
	// an invite and a leave are taken as said.
	if post && libodin.has_prefix(rpath, "/_matrix/client/v3/join/") {
		if bearer == "Bearer syt-1" && rpath[len("/_matrix/client/v3/join/"):] == "!secret:two.example" {
			secret_joined = true
			ok = say_json(dfd, 200, "{\"room_id\": \"!secret:two.example\"}\n")
		} else {
			ok = say_json(dfd, 403, "{\"errcode\": \"M_FORBIDDEN\"}\n")
		}
		if !ok {
			fail("write the reply")
		}
		return
	}
	if post && rpath == "/_matrix/client/v3/rooms/!secret:two.example/invite" {
		ok = say_json(dfd, bearer == "Bearer syt-1" && libodin.contains(body, "\"@carol:one.example\"") ? 200 : 403, "{}\n")
		if !ok {
			fail("write the reply")
		}
		return
	}
	if post && rpath == "/_matrix/client/v3/rooms/!secret:two.example/leave" {
		ok = say_json(dfd, bearer == "Bearer syt-1" ? 200 : 403, "{}\n")
		if !ok {
			fail("write the reply")
		}
		return
	}
	if post && libodin.has_prefix(rpath, "/_matrix/client/v3/sendToDevice/m.room.encrypted/") {
		if bearer == "Bearer syt-1" && bob_take_to_device(body) {
			ok = say_json(dfd, 200, "{}\n")
		} else {
			ok = say_json(dfd, 400, "{\"errcode\": \"M_UNKNOWN\", \"error\": \"the to-device message would not open here\"}\n")
		}
		if !ok {
			fail("write the reply")
		}
		return
	}
	switch rpath {
	case "/api/v1/apps":
		// A Mastodon instance registering a client: the id and the secret
		// the authorization and the token requests carry.
		ok = post && say_json(dfd, 200, "{\"client_id\": \"cid-1\", \"client_secret\": \"csecret-1\", \"name\": \"vectra\"}\n")
	case "/api/v1/accounts/verify_credentials":
		if bearer == "Bearer token-42" {
			ok = say_json(dfd, 200, "{\"id\": \"1\", \"username\": \"glenda\", \"acct\": \"glenda\", \"display_name\": \"Glenda\"}\n")
		} else {
			ok = say_json(dfd, 401, "{\"error\": \"The access token is invalid\"}\n")
		}
	case "/oauth/par":
		// A pushed authorization request, with a proof on the key the
		// token will be bound to. Where to send the browser, and the
		// state, are kept for the approval.
		if post && dpop_ok(text, "POST", rpath, "") && libodin.contains(body, "code_challenge_method=S256") && libodin.contains(body, "client_id=http://localhost") && libodin.contains(body, "response_type=code") {
			par_rlen = form_value(body, "redirect_uri", par_redirect[:])
			par_slen = form_value(body, "state", par_state[:])
			ok = say_json(dfd, 201, "{\"request_uri\": \"urn:ietf:params:oauth:request_uri:req-1\", \"expires_in\": 60}\n")
		} else {
			ok = say_json(dfd, 400, "{\"error\": \"invalid_request\"}\n")
		}
	case "/oauth/authorize":
		// The page to approve on, and the approval: a form whose answer
		// sends the browser back to the client with the code.
		if !post {
			ok = libuser.write_full(int(dfd), transmute([]u8)string(AUTHORIZE_HEAD)) && libuser.write_full(int(dfd), transmute([]u8)string(AUTHORIZE_BODY))
			break
		}
		if libodin.contains(body, "request_uri=") && par_rlen > 0 {
			loc: [512]u8
			ok = say_redirect(dfd, libuser.cat_into(loc[:], string(par_redirect[:par_rlen]), "?code=dcode&state=", string(par_state[:max(par_slen, 0)])))
		} else {
			ok = say_json(dfd, 400, "{\"error\": \"invalid_request\"}\n")
		}
	case "/oauth/token":
		if post && libodin.contains(body, "code_verifier=") {
			// AT: the code from the loopback, proved on the key.
			if dpop_ok(text, "POST", rpath, "") && libodin.contains(body, "code=dcode") && libodin.contains(body, "client_id=http://localhost") {
				ok = say_json(dfd, 200, "{\"access_token\": \"dtok-9\", \"token_type\": \"DPoP\", \"sub\": \"did:plc:alice1\", \"scope\": \"atproto transition:generic\"}\n")
			} else {
				ok = say_json(dfd, 400, "{\"error\": \"invalid_grant\"}\n")
			}
			break
		}
		// The fediverse: the code the person pasted, for a token. One code is good.
		if post && libodin.contains(body, "code=cafe") && libodin.contains(body, "client_id=cid-1") && libodin.contains(body, "grant_type=authorization_code") {
			ok = say_json(dfd, 200, "{\"access_token\": \"token-42\", \"token_type\": \"Bearer\", \"scope\": \"read write follow\"}\n")
		} else {
			ok = say_json(dfd, 401, "{\"error\": \"invalid_grant\"}\n")
		}
	case "/xrpc/com.atproto.server.createSession":
		// A PDS making a session on an app password: one handle, one
		// password, a token and a DID back.
		if post && libodin.contains(body, "\"identifier\": \"alice.one.example\"") && libodin.contains(body, "\"password\": \"app-pass-1\"") {
			ok = say_json(dfd, 200, "{\"accessJwt\": \"jwt-7\", \"refreshJwt\": \"jwt-8\", \"handle\": \"alice.one.example\", \"did\": \"did:plc:alice1\"}\n")
		} else {
			ok = say_json(dfd, 401, "{\"error\": \"AuthenticationRequired\", \"message\": \"Invalid identifier or password\"}\n")
		}
	case "/xrpc/app.bsky.feed.getTimeline":
		// The timeline, the saved one, for the session's token and nobody
		// else. A token bound to a key wants a proof, and the proof wants
		// this server's nonce, given once and then expected.
		if bearer == "Bearer dtok-9" {
			ok = say_json(dfd, 401, "{\"error\": \"a bound token is not a bearer\"}\n")
			break
		}
		if bearer == "DPoP dtok-9" {
			if !dpop_ok(text, "GET", rpath, "dtok-9") {
				ok = say_json(dfd, 401, "{\"error\": \"invalid_dpop_proof\"}\n")
			} else if !proof_has_nonce(text, "n0nce") {
				ok = say_json_with(dfd, 401, "DPoP-Nonce: n0nce\r\nWWW-Authenticate: DPoP error=\"use_dpop_nonce\"\r\n", "{\"error\": \"use_dpop_nonce\"}\n")
			} else {
				tl, tok := libuser.read_file("/lib/tests/timeline.json", context.allocator)
				if !tok {
					fail("read the saved timeline")
				}
				ok = say_json(dfd, 200, string(tl))
				delete(tl)
			}
			break
		}
		if bearer == "Bearer jwt-7" {
			tl, tok := libuser.read_file("/lib/tests/timeline.json", context.allocator)
			if !tok {
				fail("read the saved timeline")
			}
			ok = say_json(dfd, 200, string(tl))
			delete(tl)
		} else {
			ok = say_json(dfd, 401, "{\"error\": \"AuthMissing\"}\n")
		}
	case "/api/v2/media":
		// An upload, as multipart form data, named by the instance.
		if post && bearer == "Bearer token-42" && libodin.contains(body, "filename=\"dot.png\"") && libodin.contains(body, "Content-Type: image/png") && libodin.contains(body, "\x89PNG") {
			ok = say_json(dfd, 200, "{\"id\": \"m-1\", \"type\": \"image\", \"url\": \"https://one.example/media/m-1.png\"}\n")
		} else {
			ok = say_json(dfd, 401, "{\"error\": \"not an upload this instance takes\"}\n")
		}
	case "/xrpc/com.atproto.repo.uploadBlob":
		// A blob, the bytes as they are, named by its CID.
		if post && (bearer == "Bearer jwt-7" || bearer == "DPoP dtok-9") && header_value(text, "content-type") == "image/png" && libodin.contains(body, "\x89PNG") {
			ok = say_json(dfd, 200, "{\"blob\": {\"$type\": \"blob\", \"ref\": {\"$link\": \"bafkreiblobdotpngblobdotpngblobdotpngblobdotpngblobdotpngblobq\"}, \"mimeType\": \"image/png\", \"size\": 69}}\n")
		} else {
			ok = say_json(dfd, 401, "{\"error\": \"not a blob this server takes\"}\n")
		}
	case "/_matrix/client/v3/keys/upload":
		// Glenda's device keys and one-time keys, kept for Bob to use.
		if post && bearer == "Bearer syt-1" && glenda_take_keys(body) {
			ok = say_json(dfd, 200, "{\"one_time_key_counts\": {\"signed_curve25519\": 8}}\n")
		} else {
			ok = say_json(dfd, 400, "{\"errcode\": \"M_UNKNOWN\", \"error\": \"keys this server does not take\"}\n")
		}
	case "/_matrix/client/v3/keys/query":
		if post && bearer == "Bearer syt-1" && libodin.contains(body, "@bob:two.example") {
			ok = say_json(dfd, 200, bob_device_keys())
		} else {
			ok = say_json(dfd, 200, "{\"device_keys\": {}, \"failures\": {}}\n")
		}
	case "/_matrix/client/v3/keys/claim":
		if post && bearer == "Bearer syt-1" && libodin.contains(body, "@bob:two.example") {
			ok = say_json(dfd, 200, bob_one_time_key())
		} else {
			ok = say_json(dfd, 200, "{\"one_time_keys\": {}, \"failures\": {}}\n")
		}
	case "/_matrix/client/v3/login":
		// A homeserver's login: one user and password, a token and a device.
		if post && libodin.contains(body, "\"user\": \"glenda\"") && libodin.contains(body, "\"password\": \"hunter2\"") {
			ok = say_json(dfd, 200, "{\"user_id\": \"@glenda:one.example\", \"access_token\": \"syt-1\", \"device_id\": \"VECTRA1\"}\n")
		} else {
			ok = say_json(dfd, 403, "{\"errcode\": \"M_FORBIDDEN\", \"error\": \"Invalid password\"}\n")
		}
	case "/_matrix/client/v3/sync":
		// The saved sync, for the token; the sync after it carries Bob's
		// room key by Olm and an event he sealed, once Glenda's keys are up.
		if bearer == "Bearer syt-1" && libodin.contains(query, "since=s_2") && bob_ready {
			ok = say_json(dfd, 200, bob_sync())
		} else if bearer == "Bearer syt-1" && libodin.contains(query, "since=s_3") {
			ok = say_json(dfd, 200, LIVE_SYNC)
		} else if bearer == "Bearer syt-1" && libodin.contains(query, "since=s_4") {
			ok = say_json(dfd, 200, secret_joined ? SECRET_SYNC : EMPTY_SYNC_4)
		} else if bearer == "Bearer syt-1" && libodin.contains(query, "since=s_5") {
			ok = say_json(dfd, 200, EMPTY_SYNC_5)
		} else if bearer == "Bearer syt-1" {
			sy, sok := libuser.read_file("/lib/tests/sync.json", context.allocator)
			if !sok {
				fail("read the saved sync")
			}
			ok = say_json(dfd, 200, string(sy))
			delete(sy)
		} else {
			ok = say_json(dfd, 401, "{\"errcode\": \"M_UNKNOWN_TOKEN\"}\n")
		}
	case "/api/v1/statuses":
		// A status posted: the form's fields, answered as the status made.
		if post && bearer == "Bearer token-42" {
			st: [1024]u8
			cw: [256]u8
			irt: [64]u8
			sn := form_value(body, "status", st[:])
			cn := form_value(body, "spoiler_text", cw[:])
			rn := form_value(body, "in_reply_to_id", irt[:])
			out: [2048]u8
			sink := libodin.sink_from(out[:])
			libodin.put_str(&sink, "{\"id\": \"113000000000000009\", \"created_at\": \"2026-09-18T12:30:00.000Z\", \"in_reply_to_id\": ")
			if rn > 0 {
				libodin.put_str(&sink, "\"")
				libodin.put_str(&sink, string(irt[:rn]))
				libodin.put_str(&sink, "\"")
			} else {
				libodin.put_str(&sink, "null")
			}
			libodin.put_str(&sink, ", \"spoiler_text\": \"")
			libodin.put_str(&sink, string(cw[:max(cn, 0)]))
			libodin.put_str(&sink, "\", \"url\": \"https://one.example/@glenda/9\", \"content\": \"<p>")
			libodin.put_str(&sink, string(st[:max(sn, 0)]))
			libodin.put_str(&sink, "</p>\", \"reblog\": null, \"account\": {\"id\": \"1\", \"acct\": \"glenda\", \"display_name\": \"Glenda\"}, \"media_attachments\": [")
			if libodin.contains(body, "media_ids%5B%5D=m-1") || libodin.contains(body, "media_ids[]=m-1") {
				libodin.put_str(&sink, "{\"id\": \"m-1\", \"type\": \"image\", \"url\": \"https://one.example/media/m-1.png\"}")
			}
			libodin.put_str(&sink, "], \"card\": null}\n")
			ok = say_json(dfd, 200, libodin.str(&sink))
		} else {
			ok = say_json(dfd, 401, "{\"error\": \"The access token is invalid\"}\n")
		}
	case "/xrpc/com.atproto.repo.createRecord":
		// A record put: named by a URI and a CID.
		if post && bearer == "Bearer jwt-7" && libodin.contains(body, "\"collection\": \"app.bsky.feed.post\"") && libodin.contains(body, "\"$type\": \"app.bsky.feed.post\"") {
			// A record with a picture gets a name of its own, so two records
			// put in one second are two.
			if libodin.contains(body, "app.bsky.embed.images") {
				ok = say_json(dfd, 200, "{\"uri\": \"at://did:plc:alice1/app.bsky.feed.post/3kpicnew\", \"cid\": \"bafyreipicturenewpicturenewpicturenewpicturenewpicturenewpictq\"}\n")
				break
			}
			ok = say_json(dfd, 200, "{\"uri\": \"at://did:plc:alice1/app.bsky.feed.post/3knew\", \"cid\": \"bafyreinewrecordnewrecordnewrecordnewrecordnewrecordnewrecordq\"}\n")
		} else {
			ok = say_json(dfd, 401, "{\"error\": \"AuthMissing\"}\n")
		}
	case "/objects/note7":
		// An object in the fediverse, for a client that asks for activity JSON.
		if header_value(text, "accept") == "application/activity+json" {
			ok = say_json(dfd, 200, `{"@context": "https://www.w3.org/ns/activitystreams", "id": "https://one.example/users/glenda/statuses/7", "type": "Note", "published": "2026-09-18T13:00:00.000Z", "attributedTo": "https://one.example/users/glenda", "inReplyTo": null, "summary": null, "content": "<p>An object by URL.</p>", "url": "https://one.example/@glenda/7", "to": ["https://www.w3.org/ns/activitystreams#Public"], "attachment": [{"type": "Document", "mediaType": "image/png", "url": "https://one.example/media/7.png", "name": "a picture"}]}` + "\n")
		} else {
			ok = say_json(dfd, 406, "{\"error\": \"Not Acceptable\"}\n")
		}
	case "/xrpc/com.atproto.repo.getRecord":
		// A record by its repository, collection and key.
		if libodin.contains(query, "repo=did:plc:alice1") && libodin.contains(query, "collection=app.bsky.feed.post") && libodin.contains(query, "rkey=3kfirst") {
			ok = say_json(dfd, 200, `{"uri": "at://did:plc:alice1/app.bsky.feed.post/3kfirst", "cid": "bafyreicetkpcso3otre6mxnejq6vqzrcnr6ajipdxq3mmtpviqjawpw4wi", "value": {"$type": "app.bsky.feed.post", "text": "Hello, AT.", "createdAt": "2026-09-18T10:15:00.000Z"}}` + "\n")
		} else {
			ok = say_json(dfd, 400, "{\"error\": \"RecordNotFound\"}\n")
		}
	case "/api/v1/timelines/home":
		// The home timeline, the saved one, for the token and nobody else.
		if bearer == "Bearer token-42" {
			home, hok := libuser.read_file("/lib/tests/home.json", context.allocator)
			if !hok {
				fail("read the saved timeline")
			}
			ok = say_json(dfd, 200, string(home))
			delete(home)
		} else {
			ok = say_json(dfd, 401, "{\"error\": \"The access token is invalid\"}\n")
		}
	case "/new":
		// A chatmail relay's answer: an account made on this machine's own
		// address, for docs/WEB.md section 6's account in one request.
		local: [64]u8
		ln := read_small("/net/local", local[:])
		out: [256]u8
		json := libuser.cat_into(out[:], "{\"email\": \"ac1@", string(local[:max(ln, 0)]), "\", \"password\": \"relay-made\"}\n")
		head: [160]u8
		num: [16]u8
		ok = libuser.write_full(int(dfd), transmute([]u8)libuser.cat_into(head[:], "HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: ", libuser.itoa(num[:], i64(len(json))), "\r\nConnection: close\r\n\r\n")) && libuser.write_full(int(dfd), transmute([]u8)json)
	case "/login":
		if !post {
			ok = libuser.write_full(int(dfd), transmute([]u8)string(LOGIN_HEAD)) && libuser.write_full(int(dfd), transmute([]u8)string(LOGIN_BODY))
			break
		}
		// The name the form sent, `user=` in the body.
		user := "nobody"
		pos := 0
		for pos < len(body) {
			amp := pos
			for amp < len(body) && body[amp] != '&' {
				amp += 1
			}
			pair := body[pos:amp]
			pos = amp + 1
			if len(pair) > 5 && pair[:5] == "user=" {
				user = pair[5:]
			}
		}
		line: [300]u8
		b := libuser.cat_into(line[:], "welcome ", user, "\n")
		head: [200]u8
		hs := libodin.sink_from(head[:])
		libodin.put_str(&hs, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ")
		libodin.put_uint(&hs, u64(len(b)))
		libodin.put_str(&hs, "\r\nConnection: close\r\n\r\n")
		ok = libuser.write_full(int(dfd), transmute([]u8)libodin.str(&hs)) && libuser.write_full(int(dfd), transmute([]u8)b)
	case "/":
		ok = libuser.write_full(int(dfd), transmute([]u8)string(CHUNKED))
	case "/gz":
		gz := GZ_BODY
		ok = libuser.write_full(int(dfd), transmute([]u8)string(GZ_HEAD)) && libuser.write_full(int(dfd), gz[:])
	case "/cookie":
		ok = libuser.write_full(int(dfd), transmute([]u8)string(COOKIE))
	case "/whoami":
		// The Cookie header the client sent, or none.
		sent := "none"
		pos := 0
		for pos < len(text) {
			eol := pos
			for eol < len(text) && text[eol] != '\n' {
				eol += 1
			}
			hl := text[pos:eol]
			pos = eol + 1
			if len(hl) > 8 && (hl[:8] == "Cookie: " || hl[:8] == "cookie: ") {
				sent = hl[8:]
				for len(sent) > 0 && sent[len(sent) - 1] == '\r' {
					sent = sent[:len(sent) - 1]
				}
			}
		}
		body: [600]u8
		b := libuser.cat_into(body[:], "cookie: ", sent, "\n")
		head: [200]u8
		hs := libodin.sink_from(head[:])
		libodin.put_str(&hs, "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: ")
		libodin.put_uint(&hs, u64(len(b)))
		libodin.put_str(&hs, "\r\nConnection: close\r\n\r\n")
		ok = libuser.write_full(int(dfd), transmute([]u8)libodin.str(&hs)) && libuser.write_full(int(dfd), transmute([]u8)b)
	case:
		ok = libuser.write_full(int(dfd), transmute([]u8)string(NOT_FOUND))
	}
	if !ok {
		fail("send the response")
	}
	libnet.hangup(accepted)
	_ = libuser.close(int(dfd))
}

// header_int answers a header's number, or zero.
read_small :: proc "contextless" (path: string, into: []u8) -> int {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return -1
	}
	n := libuser.read(int(fd), into)
	_ = libuser.close(int(fd))
	// The address, its newline off.
	for n > 0 && (into[n - 1] == '\n' || into[n - 1] == '\r') {
		n -= 1
	}
	return int(n)
}

header_int :: proc "contextless" (text: string, name: string) -> int {
	pos := 0
	for pos < len(text) {
		eol := pos
		for eol < len(text) && text[eol] != '\n' {
			eol += 1
		}
		hl := text[pos:eol]
		pos = eol + 1
		if len(hl) <= len(name) + 1 || hl[len(name)] != ':' {
			continue
		}
		same := true
		for i in 0 ..< len(name) {
			c := hl[i]
			if c >= 'A' && c <= 'Z' {
				c += 32
			}
			if c != name[i] {
				same = false
				break
			}
		}
		if !same {
			continue
		}
		v := 0
		for i in len(name) + 1 ..< len(hl) {
			if hl[i] >= '0' && hl[i] <= '9' {
				v = v * 10 + int(hl[i] - '0')
			}
		}
		return v
	}
	return 0
}

// blank_line_end is the offset just past the first blank line.
blank_line_end :: proc "contextless" (req: []u8) -> int {
	for i in 0 ..< len(req) {
		if req[i] == '\n' && i + 2 < len(req) && req[i + 1] == '\r' && req[i + 2] == '\n' {
			return i + 3
		}
		if req[i] == '\n' && i + 1 < len(req) && req[i + 1] == '\n' {
			return i + 2
		}
	}
	return len(req)
}

has_blank_line :: proc "contextless" (data: []u8) -> bool #no_bounds_check {
	for i in 0 ..< len(data) - 1 {
		if data[i] == '\n' && (data[i + 1] == '\n' || (i + 2 < len(data) && data[i + 1] == '\r' && data[i + 2] == '\n')) {
			return true
		}
	}
	return false
}

// say_json answers a JSON body with a status.
say_json :: proc(dfd: i64, status: int, body: string) -> bool {
	return say_json_with(dfd, status, "", body)
}

// say_json_with is say_json with more header lines, CRLF ended.
say_json_with :: proc(dfd: i64, status: int, extra: string, body: string) -> bool {
	head: [400]u8
	num: [16]u8
	reason := status == 200 ? "OK" : status == 201 ? "Created" : status == 401 ? "Unauthorized" : "Bad Request"
	snum: [8]u8
	h := libuser.cat_into(head[:], "HTTP/1.1 ", libuser.itoa(snum[:], i64(status)), " ", reason, "\r\nContent-Type: application/json\r\nContent-Length: ", libuser.itoa(num[:], i64(len(body))), "\r\n", extra, "Connection: close\r\n\r\n")
	return libuser.write_full(int(dfd), transmute([]u8)h) && libuser.write_full(int(dfd), transmute([]u8)body)
}

served_port: string

// What the pushed request said: where to send the browser, and the state.
par_redirect: [256]u8
par_rlen: int
par_state: [64]u8
par_slen: int

// The page to approve on: one button, and the request it approves.
AUTHORIZE_HEAD :: "HTTP/1.1 200 OK\r\nContent-Type: text/html\r\nContent-Length: 255\r\nConnection: close\r\n\r\n"
AUTHORIZE_BODY :: "<html><head><title>Approve</title></head><body><h1>Approve</h1><p>Let this client act as you?</p><form method=\"post\" action=\"/oauth/authorize\"><input type=\"hidden\" name=\"request_uri\" value=\"req-1\"><input type=\"submit\" value=\"Approve\"></form></body></html>"

// say_redirect sends the browser elsewhere.
say_redirect :: proc(dfd: i64, location: string) -> bool {
	head: [640]u8
	h := libuser.cat_into(head[:], "HTTP/1.1 303 See Other\r\nLocation: ", location, "\r\nContent-Length: 0\r\nConnection: close\r\n\r\n")
	return libuser.write_full(int(dfd), transmute([]u8)h)
}

/*
dpop_ok verifies the request's DPoP proof, RFC 9449, the way a server
does: the JWS checks against the key its own header carries, and its
payload names this method and this URI, and the token's hash when the
request carries one. That is docs/WEB.md section 7's "a DPoP proof the
test verifies with the public key carries the right method and URL".
*/
dpop_ok :: proc(text: string, method: string, path: string, token: string) -> bool {
	proof := header_value(text, "dpop")
	if proof == "" {
		libuser.eprint("websrv: dpop: no proof\n")
		return false
	}
	hbuf: [512]u8
	pbuf: [1024]u8
	// The key is in the header, so the header is read once unverified.
	d1 := 0
	for d1 < len(proof) && proof[d1] != '.' {
		d1 += 1
	}
	hn := libjws.base64url_decode(proof[:d1], hbuf[:])
	if hn <= 0 {
		libuser.eprint("websrv: dpop: the header would not decode\n")
		return false
	}
	jwk_at := libodin_index(string(hbuf[:hn]), "\"jwk\":")
	if jwk_at < 0 {
		libuser.eprint("websrv: dpop: no jwk in the header\n")
		return false
	}
	pub: ecdsa.Public_Key
	if !libjws.jwk_to_p256(string(hbuf[jwk_at + 6:hn - 1]), &pub) {
		libuser.eprint("websrv: dpop: the jwk is not a P-256 key: ", string(hbuf[jwk_at + 6:hn - 1]), "\n")
		return false
	}
	header, payload, ok := libjws.verify_es256(proof, &pub, hbuf[:], pbuf[:])
	if !ok {
		libuser.eprint("websrv: dpop: the signature does not verify\n")
		return false
	}
	if !libodin.contains(header, "\"typ\":\"dpop+jwt\"") || !libodin.contains(header, "\"alg\":\"ES256\"") {
		libuser.eprint("websrv: dpop: the header is not a dpop+jwt on ES256\n")
		return false
	}
	local: [64]u8
	ln := read_small("/net/local", local[:])
	want: [256]u8
	htu := libuser.cat_into(want[:], "\"htu\":\"http://", string(local[:max(ln, 0)]), ":", served_port, path, "\"")
	htm: [32]u8
	if !libodin.contains(payload, libuser.cat_into(htm[:], "\"htm\":\"", method, "\"")) || !libodin.contains(payload, htu) {
		libuser.eprint("websrv: dpop: the method or the URI is not this request's: ", payload, " wanted ", htu, "\n")
		return false
	}
	if token != "" {
		digest: [32]u8
		hash.hash_bytes_to_buffer(.SHA256, transmute([]u8)token, digest[:])
		ath: [48]u8
		an := libjws.base64url_encode(digest[:], ath[:])
		claim: [80]u8
		if !libodin.contains(payload, libuser.cat_into(claim[:], "\"ath\":\"", string(ath[:an]), "\"")) {
			libuser.eprint("websrv: dpop: the token's hash is not in the proof\n")
			return false
		}
	}
	return true
}

// proof_has_nonce says whether the request's proof names `nonce`.
proof_has_nonce :: proc(text: string, nonce: string) -> bool {
	proof := header_value(text, "dpop")
	d1 := 0
	for d1 < len(proof) && proof[d1] != '.' {
		d1 += 1
	}
	d2 := d1 + 1
	for d2 < len(proof) && proof[d2] != '.' {
		d2 += 1
	}
	if d1 >= len(proof) || d2 >= len(proof) {
		return false
	}
	pbuf: [1024]u8
	pn := libjws.base64url_decode(proof[d1 + 1:d2], pbuf[:])
	if pn <= 0 {
		return false
	}
	claim: [160]u8
	return libodin.contains(string(pbuf[:pn]), libuser.cat_into(claim[:], "\"nonce\":\"", nonce, "\""))
}

libodin_index :: proc "contextless" (s: string, want: string) -> int {
	if len(want) == 0 || len(s) < len(want) {
		return -1
	}
	for i in 0 ..< len(s) - len(want) + 1 {
		if s[i:i + len(want)] == want {
			return i
		}
	}
	return -1
}

// form_value answers a form field's value, decoded, into `into`: `+` a
// space and `%XX` a byte. -1 when the field is not there.
form_value :: proc "contextless" (body: string, name: string, into: []u8) -> int {
	pos := 0
	for pos < len(body) {
		amp := pos
		for amp < len(body) && body[amp] != '&' {
			amp += 1
		}
		pair := body[pos:amp]
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
					into[n] = hex_byte(v[i + 1]) << 4 | hex_byte(v[i + 2])
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

hex_byte :: proc "contextless" (c: u8) -> u8 {
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

// -- Bob's device, the far side of the seal ---------------------------------------

/*
Bob is a device this server holds, with keys made from fixed seeds. It
answers Glenda's key query and claim, opens the room key she sends it
by Olm, opens the event she seals with it and writes what she said to
/usr/glenda/matrix-bob.txt, and, once her keys are up, makes a Megolm
session of its own, shares it with her by Olm on a one-time key she
uploaded, and seals an event with it for the sync after her first.
*/
BOB_USER :: "@bob:two.example"
BOB_DEVICE :: "BOBDEV"
BOB_OUT :: "/usr/glenda/matrix-bob.txt"

bob_identity: [32]u8
bob_identity_pub: [32]u8
bob_sign: ed25519.Private_Key
bob_sign_pub: [32]u8
bob_one_time: [32]u8
bob_one_time_pub: [32]u8
bob_session: libolm.Session // With Glenda's device, made from her pre-key message
bob_megolm_in: libolm.Inbound // Glenda's room key
bob_megolm_in_set: bool
bob_ready: bool // Glenda's keys are up
secret_joined: bool // Glenda joined the room Bob invited her to

// What the long poll pulls after Bob's sync: Bob typing in the sealed
// room and a line in the plain one, then, once Glenda has joined the
// room he invited her to, that room with its state and his welcome,
// then nothing new.
LIVE_SYNC :: `{"next_batch": "s_4", "rooms": {"join": {"!vectra:one.example": {"ephemeral": {"events": [{"type": "m.typing", "content": {"user_ids": ["@bob:two.example"]}}]}}, "!plain:one.example": {"timeline": {"events": [{"type": "m.room.message", "event_id": "$live1", "sender": "@carol:one.example", "origin_server_ts": 1789760000000, "content": {"msgtype": "m.text", "body": "Live from the poll."}}], "prev_batch": "p_4", "limited": false}}}}}
`
SECRET_SYNC :: `{"next_batch": "s_5", "rooms": {"join": {"!secret:two.example": {"state": {"events": [{"type": "m.room.name", "state_key": "", "sender": "@bob:two.example", "content": {"name": "secret"}}, {"type": "m.room.member", "state_key": "@bob:two.example", "sender": "@bob:two.example", "content": {"membership": "join"}}, {"type": "m.room.member", "state_key": "@glenda:one.example", "sender": "@glenda:one.example", "content": {"membership": "join"}}]}, "timeline": {"events": [{"type": "m.room.message", "event_id": "$welcome", "sender": "@bob:two.example", "origin_server_ts": 1789770000000, "content": {"msgtype": "m.text", "body": "Welcome to secret."}}], "prev_batch": "p_5", "limited": false}}}}}
`
EMPTY_SYNC_4 :: `{"next_batch": "s_4", "rooms": {"join": {}}}
`
EMPTY_SYNC_5 :: `{"next_batch": "s_5", "rooms": {"join": {}}}
`
glenda_curve: [32]u8
glenda_ed: [32]u8
glenda_one_time: [32]u8
glenda_user: [64]u8
glenda_ulen: int

bob_init :: proc() {
	for i in 0 ..< 32 {
		bob_identity[i] = u8(i * 7 + 3)
		bob_one_time[i] = u8(i * 11 + 5)
	}
	seed: [32]u8
	for i in 0 ..< 32 {
		seed[i] = u8(i * 13 + 7)
	}
	libolm.basepoint(bob_identity_pub[:], bob_identity[:])
	libolm.basepoint(bob_one_time_pub[:], bob_one_time[:])
	_ = ed25519.private_key_set_bytes(&bob_sign, seed[:])
	ed25519.private_key_public_bytes(&bob_sign, bob_sign_pub[:])
}

b64 :: proc(data: []u8, into: []u8) -> string {
	n := libodin.b64_encode(data, into)
	return string(into[:max(n, 0)])
}

// bob_device_keys answers a key query with Bob's device.
bob_device_keys :: proc() -> string {
	@(static) out: [1024]u8
	c: [48]u8
	e: [48]u8
	return libuser.cat_into(out[:], "{\"device_keys\": {\"", BOB_USER, "\": {\"", BOB_DEVICE, "\": {\"user_id\": \"", BOB_USER, "\", \"device_id\": \"", BOB_DEVICE, "\", \"algorithms\": [\"m.olm.v1.curve25519-aes-sha2\", \"m.megolm.v1.aes-sha2\"], \"keys\": {\"curve25519:", BOB_DEVICE, "\": \"", b64(bob_identity_pub[:], c[:]), "\", \"ed25519:", BOB_DEVICE, "\": \"", b64(bob_sign_pub[:], e[:]), "\"}, \"signatures\": {}}}}, \"failures\": {}}\n")
}

// bob_one_time_key answers a claim with Bob's one key.
bob_one_time_key :: proc() -> string {
	@(static) out: [512]u8
	k: [48]u8
	return libuser.cat_into(out[:], "{\"one_time_keys\": {\"", BOB_USER, "\": {\"", BOB_DEVICE, "\": {\"signed_curve25519:AAAAAQ\": {\"key\": \"", b64(bob_one_time_pub[:], k[:]), "\", \"signatures\": {}}}}}, \"failures\": {}}\n")
}

// glenda_take_keys keeps the keys Glenda's device uploaded: her identity
// and signing keys, and one one-time key for Bob to begin a session on.
glenda_take_keys :: proc(body: string) -> bool {
	v, err := json.parse_string(body, .JSON)
	defer json.destroy_value(v)
	top, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		return false
	}
	dk, has := libmsg.obj_of(top, "device_keys")
	if !has {
		return false
	}
	glenda_ulen = copy(glenda_user[:], libmsg.str_of(dk, "user_id"))
	keys, has_keys := libmsg.obj_of(dk, "keys")
	if !has_keys {
		return false
	}
	got_c, got_e := false, false
	for name, val in (map[string]json.Value)(keys) {
		s, is := val.(json.String)
		if !is {
			continue
		}
		if len(name) > 11 && name[:11] == "curve25519:" {
			got_c = libodin.b64_decode(string(s), glenda_curve[:]) == 32
		} else if len(name) > 8 && name[:8] == "ed25519:" {
			got_e = libodin.b64_decode(string(s), glenda_ed[:]) == 32
		}
	}
	otk, has_otk := libmsg.obj_of(top, "one_time_keys")
	got_o := false
	if has_otk {
		for _, val in (map[string]json.Value)(otk) {
			if ko, is := val.(json.Object); is {
				got_o = libodin.b64_decode(libmsg.str_of(ko, "key"), glenda_one_time[:]) == 32
				if got_o {
					break
				}
			}
		}
	}
	bob_ready = got_c && got_e && got_o
	return bob_ready
}

// bob_take_to_device opens the room key Glenda sent Bob by Olm, and keeps
// the Megolm session it carries.
bob_take_to_device :: proc(body: string) -> bool {
	v, err := json.parse_string(body, .JSON)
	defer json.destroy_value(v)
	top, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		return false
	}
	messages, has := libmsg.obj_of(top, "messages")
	if !has {
		return false
	}
	u, has_u := libmsg.obj_of(messages, BOB_USER)
	if !has_u {
		return false
	}
	d, has_d := libmsg.obj_of(u, BOB_DEVICE)
	if !has_d {
		return false
	}
	ct, has_ct := libmsg.obj_of(d, "ciphertext")
	if !has_ct {
		return false
	}
	c: [48]u8
	mine, for_bob := libmsg.obj_of(ct, b64(bob_identity_pub[:], c[:]))
	if !for_bob {
		return false
	}
	raw := make([]u8, 4096)
	defer delete(raw)
	n := libodin.b64_decode(libmsg.str_of(mine, "body"), raw)
	if n <= 0 {
		return false
	}
	if !libolm.inbound(&bob_session, bob_identity[:], bob_one_time[:], raw[:n]) {
		return false
	}
	plain := make([]u8, n)
	defer delete(plain)
	pn, ok := libolm.decrypt(&bob_session, raw[:n], plain, true)
	if !ok {
		return false
	}
	pv, perr := json.parse_string(string(plain[:pn]), .JSON)
	defer json.destroy_value(pv)
	po, pis := pv.(json.Object)
	if perr != .None || !pis || libmsg.str_of(po, "type") != "m.room_key" {
		return false
	}
	content, has_content := libmsg.obj_of(po, "content")
	if !has_content {
		return false
	}
	share := make([]u8, 512)
	defer delete(share)
	sn := libodin.b64_decode(libmsg.str_of(content, "session_key"), share)
	if sn < libolm.EXPORT_BYTES || !libolm.session_import(&bob_megolm_in, share[:sn]) {
		return false
	}
	bob_megolm_in_set = true
	return true
}

// bob_open_event opens the Megolm event Glenda sealed and writes what it
// says, the body of the message inside, to the file.
bob_open_event :: proc(body: string) -> bool {
	if !bob_megolm_in_set {
		return false
	}
	v, err := json.parse_string(body, .JSON)
	defer json.destroy_value(v)
	content, is_obj := v.(json.Object)
	if err != .None || !is_obj || libmsg.str_of(content, "algorithm") != "m.megolm.v1.aes-sha2" {
		return false
	}
	raw := make([]u8, 4096)
	defer delete(raw)
	n := libodin.b64_decode(libmsg.str_of(content, "ciphertext"), raw)
	if n <= 0 {
		return false
	}
	plain := make([]u8, n)
	defer delete(plain)
	pn, _, ok := libolm.group_decrypt(&bob_megolm_in, raw[:n], plain)
	if !ok {
		return false
	}
	pv, perr := json.parse_string(string(plain[:pn]), .JSON)
	defer json.destroy_value(pv)
	po, pis := pv.(json.Object)
	if perr != .None || !pis || libmsg.str_of(po, "type") != "m.room.message" {
		return false
	}
	inner, has_inner := libmsg.obj_of(po, "content")
	if !has_inner {
		return false
	}
	_ = libuser.remove(BOB_OUT)
	fd := libuser.create(BOB_OUT, abi.O_WRONLY, 0o644)
	if fd < 0 {
		return false
	}
	text := libmsg.str_of(inner, "body")
	wrote := libuser.write_full(int(fd), transmute([]u8)text)
	_ = libuser.close(int(fd))
	return wrote
}

/*
bob_sync answers the sync after the first: Bob's own Megolm session,
shared with Glenda by Olm on the one-time key she uploaded, as a
to-device event, and an event in the room sealed with it, so her rooms
open a message her device never had the key for until then.
*/
bob_sync :: proc() -> string {
	@(static) out: [8192]u8
	seed: [128]u8
	sign_seed: [32]u8
	for i in 0 ..< 128 {
		seed[i] = u8(i * 3 + 17)
	}
	for i in 0 ..< 32 {
		sign_seed[i] = u8(i * 5 + 19)
	}
	mo: libolm.Outbound
	if !libolm.outbound_init(&mo, seed[:], sign_seed[:]) {
		fail("bob's megolm session")
	}
	sid: [48]u8
	session_id := b64(mo.pub[:], sid[:])
	share: [libolm.SHARE_BYTES]u8
	_ = libolm.session_share(&mo, share[:])
	share_b64: [320]u8
	shared := b64(share[:], share_b64[:])
	// The room key, sealed by Olm for Glenda's device on her one-time key.
	base_priv, ratchet_priv: [32]u8
	for i in 0 ..< 32 {
		base_priv[i] = u8(i * 23 + 1)
		ratchet_priv[i] = u8(i * 29 + 2)
	}
	s: libolm.Session
	if !libolm.outbound(&s, bob_identity[:], glenda_curve[:], glenda_one_time[:], base_priv[:], ratchet_priv[:]) {
		fail("bob's olm session")
	}
	ge: [48]u8
	be: [48]u8
	plain: [1024]u8
	p := libuser.cat_into(plain[:], "{\"content\":{\"algorithm\":\"m.megolm.v1.aes-sha2\",\"room_id\":\"!vectra:one.example\",\"session_id\":\"", session_id, "\",\"session_key\":\"", shared, "\"},\"keys\":{\"ed25519\":\"", b64(bob_sign_pub[:], be[:]), "\"},\"recipient\":\"", string(glenda_user[:glenda_ulen]), "\",\"recipient_keys\":{\"ed25519\":\"", b64(glenda_ed[:], ge[:]), "\"},\"sender\":\"", BOB_USER, "\",\"sender_device\":\"", BOB_DEVICE, "\",\"type\":\"m.room_key\"}")
	sealed: [2048]u8
	sn := libolm.encrypt(&s, transmute([]u8)p, sealed[:], nil)
	if sn <= 0 {
		fail("bob seals the room key")
	}
	olm_b64: [3072]u8
	olm := b64(sealed[:sn], olm_b64[:])
	// An event in the room, sealed with Bob's session.
	event_plain := "{\"content\":{\"body\":\"Sealed from Bob.\",\"msgtype\":\"m.text\"},\"room_id\":\"!vectra:one.example\",\"type\":\"m.room.message\"}"
	event_sealed: [1024]u8
	en := libolm.group_encrypt(&mo, transmute([]u8)event_plain, event_sealed[:])
	if en <= 0 {
		fail("bob seals an event")
	}
	ev_b64: [1536]u8
	ev := b64(event_sealed[:en], ev_b64[:])
	bc: [48]u8
	gc: [48]u8
	return libuser.cat_into(out[:], "{\"next_batch\": \"s_3\", \"to_device\": {\"events\": [{\"type\": \"m.room.encrypted\", \"sender\": \"", BOB_USER, "\", \"content\": {\"algorithm\": \"m.olm.v1.curve25519-aes-sha2\", \"sender_key\": \"", b64(bob_identity_pub[:], bc[:]), "\", \"ciphertext\": {\"", b64(glenda_curve[:], gc[:]), "\": {\"type\": 0, \"body\": \"", olm, "\"}}}}]}, \"rooms\": {\"join\": {\"!vectra:one.example\": {\"timeline\": {\"events\": [{\"type\": \"m.room.encrypted\", \"event_id\": \"$sealed_in\", \"sender\": \"", BOB_USER, "\", \"origin_server_ts\": 1789750000000, \"content\": {\"algorithm\": \"m.megolm.v1.aes-sha2\", \"sender_key\": \"", b64(bob_identity_pub[:], bc[:]), "\", \"device_id\": \"", BOB_DEVICE, "\", \"session_id\": \"", session_id, "\", \"ciphertext\": \"", ev, "\"}}], \"prev_batch\": \"p_3\", \"limited\": false}}}}}\n")
}

// header_value answers a request header's value by its name, lower
// case, or "".
header_value :: proc "contextless" (text: string, name: string) -> string {
	pos := 0
	for pos < len(text) {
		eol := pos
		for eol < len(text) && text[eol] != '\n' {
			eol += 1
		}
		hl := text[pos:eol]
		pos = eol + 1
		if len(hl) > 0 && hl[len(hl) - 1] == '\r' {
			hl = hl[:len(hl) - 1]
		}
		if len(hl) > len(name) + 1 && hl[len(name)] == ':' {
			same := true
			for i in 0 ..< len(name) {
				c := hl[i]
				if c >= 'A' && c <= 'Z' {
					c += 32
				}
				if c != name[i] {
					same = false
					break
				}
			}
			if same {
				v := hl[len(name) + 1:]
				for len(v) > 0 && v[0] == ' ' {
					v = v[1:]
				}
				return v
			}
		}
	}
	return ""
}
