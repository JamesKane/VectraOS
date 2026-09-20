/*
A post written to `new`: `docs/WEB.md` section 4's block, a record put
in the account's repository. The body is the text, and `replyto` an id
in `home`, whose post the record then answers, its parent and root by
URI and CID. The write waits for the server, and the record lands in
`home` under the URI and CID the server answered, and under `sent/` of
the store, the record as sent. The token comes from `factotum` for the
request and is not kept.
*/
package atfs

import "core:encoding/json"
import "vsys:lib9p"
import "vsys:libmsg"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

// The store: `-s DIR`, where `sent/` keeps what went out.
store: [256]u8
store_len: int

// One record on its way out: the held write, the record, and the id of
// the post it answers.
Post :: struct {
	tag:    vectra9.Tag,
	count:  int,
	io:     ^libthread.Ioproc,
	record: [dynamic]u8, // The record, as JSON
	text:   string, // Its text, owned
	date:   i64,
	parent: string, // The id in home it answers, owned, or ""
	why:    string,
}

// start_post reads the block, builds the record, and puts it on a thread
// while the write waits.
start_post :: proc(tag: vectra9.Tag, text: string) -> vectra9.Errno {
	if !account.set || account.dlen == 0 {
		return vectra9.EPERM // No session, so no repository to put it in
	}
	n := libmsg.parse_new(text)
	defer libmsg.new_free(&n)
	if bad, has_bad := libmsg.new_unknown(&n); has_bad {
		libuser.eprint("atfs: new: no such header here: ", bad, "\n")
		return vectra9.EINVAL
	}
	body := n.body
	for len(body) > 0 && (body[len(body) - 1] == '\n' || body[len(body) - 1] == '\r') {
		body = body[:len(body) - 1]
	}
	if len(body) == 0 {
		return vectra9.EINVAL
	}
	p := new(Post)
	p.tag = tag
	p.count = len(text)
	p.text = clone(body)
	p.date = libmsg.now_seconds()
	p.record = make([dynamic]u8, 0, 512)
	when_: [32]u8
	put(&p.record, "{\"$type\": \"app.bsky.feed.post\", \"text\": ")
	put_json_string(&p.record, body)
	put(&p.record, ", \"createdAt\": \"")
	put(&p.record, libmsg.format_3339(p.date, when_[:]))
	put(&p.record, "\"")
	if replyto, has := libmsg.new_header(&n, "replyto"); has && len(replyto) > 0 {
		home := libmsg.conv(&net, "home")
		i := libmsg.find(home, replyto)
		if i < 0 {
			post_free(p)
			return vectra9.ENOENT
		}
		puri, pcid, pok := uri_cid_of(home.msgs[i].raw)
		if !pok {
			post_free(p)
			return vectra9.ENOENT
		}
		// The root: the parent's own root when it is a reply, else the parent.
		ruri, rcid := puri, pcid
		if home.msgs[i].replyto != "" {
			if j := libmsg.find(home, home.msgs[i].replyto); j >= 0 {
				if u, c, ok := uri_cid_of(home.msgs[j].raw); ok {
					ruri, rcid = u, c
				}
			}
		}
		put(&p.record, ", \"reply\": {\"root\": {\"uri\": \"")
		put(&p.record, ruri)
		put(&p.record, "\", \"cid\": \"")
		put(&p.record, rcid)
		put(&p.record, "\"}, \"parent\": {\"uri\": \"")
		put(&p.record, puri)
		put(&p.record, "\", \"cid\": \"")
		put(&p.record, pcid)
		put(&p.record, "\"}}")
		p.parent = clone(replyto)
	}
	put(&p.record, "}")
	if libthread.threadcreate(post_thread, p, 256 * 1024) < 0 {
		post_free(p)
		return vectra9.ENOSPC
	}
	lib9p.hold(&net.srv)
	return 0
}

post_free :: proc(p: ^Post) {
	delete(p.record)
	delete(p.text)
	delete(p.parent)
	free(p)
}

post_thread :: proc "contextless" (arg: rawptr) {
	context = libuser.heap_context()
	p := (^Post)(arg)
	err := vectra9.Errno(0)
	p.io = libthread.ioproc()
	if p.io == nil {
		err = vectra9.EIO
	} else {
		err = put_record(p)
		libthread.ioclose(p.io)
	}
	if err != 0 && p.why != "" {
		libuser.eprint("atfs: ", p.why, "\n")
	}
	if req := lib9p.find_held_tag(&net.srv, p.tag); req != nil {
		if err == 0 {
			_ = lib9p.respond(req, vectra9.Rwrite{count = u32(p.count)})
		} else {
			_ = lib9p.respond(req, vectra9.error_reply(err))
		}
	}
	post_free(p)
	libthread.threadexits("")
}

// put_record sends the record to createRecord with the token, and takes
// the post into home under the URI and CID answered, and the record
// into the store.
put_record :: proc(p: ^Post) -> vectra9.Errno {
	tok: [256]u8
	token, has := ask_token(tok[:])
	if !has {
		p.why = "factotum holds no token for the account"
		return vectra9.EPERM
	}
	body := make([dynamic]u8, 0, len(p.record) + 256)
	defer delete(body)
	put(&body, "{\"repo\": \"")
	put(&body, string(account.did[:account.dlen]))
	put(&body, "\", \"collection\": \"app.bsky.feed.post\", \"record\": ")
	append(&body, ..p.record[:])
	put(&body, "}")
	url: [BASE_MAX + 64]u8
	auth: [400]u8
	headers := libuser.cat_into(auth[:], "Authorization: Bearer ", token, "\nContent-Type: application/json\n")
	text, status, ok := libmsg.request(p.io, libuser.cat_into(url[:], string(account.base[:account.blen]), "/xrpc/com.atproto.repo.createRecord"), "POST", headers, string(body[:]))
	defer delete(text)
	if !ok || status != 200 {
		p.why = "the server would not take the record"
		return vectra9.EIO
	}
	uri: [256]u8
	cid: [128]u8
	ulen, clen := 0, 0
	{
		v, err := json.parse_string(string(text), .JSON)
		defer json.destroy_value(v)
		o, is_obj := v.(json.Object)
		if err != .None || !is_obj {
			p.why = "the server's answer was not JSON"
			return vectra9.EIO
		}
		ulen = copy(uri[:], libmsg.str_of(o, "uri"))
		clen = copy(cid[:], libmsg.str_of(o, "cid"))
	}
	if ulen == 0 || clen == 0 {
		p.why = "the server named no record"
		return vectra9.EIO
	}
	// The post as a view, the record inside: what home keeps as raw.
	view := make([dynamic]u8, 0, len(p.record) + 512)
	put(&view, "{\"uri\": \"")
	put(&view, string(uri[:ulen]))
	put(&view, "\", \"cid\": \"")
	put(&view, string(cid[:clen]))
	put(&view, "\", \"author\": {\"did\": \"")
	put(&view, string(account.did[:account.dlen]))
	put(&view, "\", \"handle\": \"")
	put(&view, string(account.user[:account.ulen]))
	put(&view, "\"}, \"record\": ")
	append(&view, ..p.record[:])
	put(&view, "}")
	m: libmsg.Msg
	idbuf: [128]u8
	m.id = clone(libmsg.make_id(p.date, string(uri[:ulen]), idbuf[:]))
	m.from = clone(string(account.user[:account.ulen]))
	m.date = p.date
	when_: [32]u8
	m.date_text = clone(libmsg.format_3339(p.date, when_[:]))
	m.body = clone(p.text)
	m.type = clone("text/plain")
	m.replyto = clone(p.parent)
	page: [256]u8
	m.links = clone(libuser.cat_into(page[:], "https://bsky.app/profile/", string(account.user[:account.ulen]), "/post/", rkey_of(string(uri[:ulen]))))
	m.raw = string(view[:])
	// The server named the record: its CID is the hash, this side's own.
	m.hash_own = true
	m.hash_len = copy(m.hash[:], cid[:clen])
	_ = libmsg.keep_sent(string(store[:store_len]), m.id, string(p.record[:]))
	home := libmsg.conv(&net, "home")
	libmsg.add(&net, home, m)
	rebuild_status()
	return 0
}

// uri_cid_of answers a post's URI and CID out of what its message kept
// as raw: a feed item, with them under `post`, or a view with them at
// the top. The strings are the caller's until the next call.
uri_cid_of :: proc(raw: string) -> (uri: string, cid: string, ok: bool) {
	@(static) ubuf: [256]u8
	@(static) cbuf: [128]u8
	v, err := json.parse_string(raw, .JSON)
	defer json.destroy_value(v)
	o, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		return "", "", false
	}
	if post, has := libmsg.obj_of(o, "post"); has {
		o = post
	}
	u := libmsg.str_of(o, "uri")
	c := libmsg.str_of(o, "cid")
	if u == "" || c == "" {
		return "", "", false
	}
	un := copy(ubuf[:], u)
	cn := copy(cbuf[:], c)
	return string(ubuf[:un]), string(cbuf[:cn]), true
}

put :: proc(out: ^[dynamic]u8, s: string) {
	append(out, ..transmute([]u8)s)
}

// put_json_string appends `s` as a JSON string, quoted and escaped.
put_json_string :: proc(out: ^[dynamic]u8, s: string) {
	hex := "0123456789abcdef"
	append(out, '"')
	for c in transmute([]u8)s {
		switch c {
		case '"':
			append(out, '\\', '"')
		case '\\':
			append(out, '\\', '\\')
		case '\n':
			append(out, '\\', 'n')
		case '\r':
			append(out, '\\', 'r')
		case '\t':
			append(out, '\\', 't')
		case:
			if c < 0x20 {
				append(out, '\\', 'u', '0', '0', hex[c >> 4], hex[c & 15])
			} else {
				append(out, c)
			}
		}
	}
	append(out, '"')
}
