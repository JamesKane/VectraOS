/*
A post written to `new`: `docs/WEB.md` section 4's block, a record put
in the account's repository. The body is the text, `replyto` an id in
`home`, whose post the record then answers, its parent and root by URI
and CID, and `attach` a path, uploaded as a blob first and embedded as
an image. The write waits for the server, and the record lands in
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

MAX_ATTACH :: 4
ATTACH_MAX :: 1024 * 1024

// One record on its way out: the held write, the record, the id of the
// post it answers, and the files to upload and embed before it goes.
Post :: struct {
	tag:     vectra9.Tag,
	count:   int,
	io:      ^libthread.Ioproc,
	record:  [dynamic]u8, // The record, as JSON, its embed put in on the way
	text:    string, // Its text, owned
	date:    i64,
	parent:  string, // The id in home it answers, owned, or ""
	attach:  [MAX_ATTACH][256]u8,
	alen:    [MAX_ATTACH]int,
	nattach: int,
	why:     string,
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
	p.text = libmsg.clone(body)
	p.date = libmsg.now_seconds()
	p.record = make([dynamic]u8, 0, 512)
	when_: [32]u8
	libmsg.put(&p.record, "{\"$type\": \"app.bsky.feed.post\", \"text\": ")
	libmsg.put_json_string(&p.record, body)
	libmsg.put(&p.record, ", \"createdAt\": \"")
	libmsg.put(&p.record, libmsg.format_3339(p.date, when_[:]))
	libmsg.put(&p.record, "\"")
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
		libmsg.put(&p.record, ", \"reply\": {\"root\": {\"uri\": \"")
		libmsg.put(&p.record, ruri)
		libmsg.put(&p.record, "\", \"cid\": \"")
		libmsg.put(&p.record, rcid)
		libmsg.put(&p.record, "\"}, \"parent\": {\"uri\": \"")
		libmsg.put(&p.record, puri)
		libmsg.put(&p.record, "\", \"cid\": \"")
		libmsg.put(&p.record, pcid)
		libmsg.put(&p.record, "\"}}")
		p.parent = libmsg.clone(replyto)
	}
	for k in 0 ..< MAX_ATTACH {
		path, has := libmsg.new_attach(&n, k)
		if !has {
			break
		}
		p.alen[k] = copy(p.attach[k][:], path)
		p.nattach += 1
	}
	// The record is closed once the blobs are in, on the thread.
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
	// The blobs first, each embedded as an image, then the record closes.
	if p.nattach > 0 {
		libmsg.put(&p.record, ", \"embed\": {\"$type\": \"app.bsky.embed.images\", \"images\": [")
		for k in 0 ..< p.nattach {
			blob := make([dynamic]u8, 0, 256)
			defer delete(blob)
			if !upload_blob(p, string(p.attach[k][:p.alen[k]]), &blob) {
				p.why = "the server would not take the blob"
				return vectra9.EIO
			}
			if k > 0 {
				libmsg.put(&p.record, ", ")
			}
			libmsg.put(&p.record, "{\"alt\": \"\", \"image\": ")
			append(&p.record, ..blob[:])
			libmsg.put(&p.record, "}")
		}
		libmsg.put(&p.record, "]}")
	}
	libmsg.put(&p.record, "}")
	body := make([dynamic]u8, 0, len(p.record) + 256)
	defer delete(body)
	libmsg.put(&body, "{\"repo\": \"")
	libmsg.put(&body, string(account.did[:account.dlen]))
	libmsg.put(&body, "\", \"collection\": \"app.bsky.feed.post\", \"record\": ")
	append(&body, ..p.record[:])
	libmsg.put(&body, "}")
	url: [BASE_MAX + 64]u8
	text, status, ok := as_account(p.io, "POST", libuser.cat_into(url[:], string(account.base[:account.blen]), "/xrpc/com.atproto.repo.createRecord"), "Content-Type: application/json\n", string(body[:]))
	defer delete(text)
	if !ok {
		p.why = "factotum holds no token for the account, or the wire would not"
		return vectra9.EPERM
	}
	if status != 200 {
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
	libmsg.put(&view, "{\"uri\": \"")
	libmsg.put(&view, string(uri[:ulen]))
	libmsg.put(&view, "\", \"cid\": \"")
	libmsg.put(&view, string(cid[:clen]))
	libmsg.put(&view, "\", \"author\": {\"did\": \"")
	libmsg.put(&view, string(account.did[:account.dlen]))
	libmsg.put(&view, "\", \"handle\": \"")
	libmsg.put(&view, string(account.user[:account.ulen]))
	libmsg.put(&view, "\"}, \"record\": ")
	append(&view, ..p.record[:])
	libmsg.put(&view, "}")
	m: libmsg.Msg
	idbuf: [128]u8
	m.id = libmsg.clone(libmsg.make_id(p.date, string(uri[:ulen]), idbuf[:]))
	m.from = libmsg.clone(string(account.user[:account.ulen]))
	m.date = p.date
	when_: [32]u8
	m.date_text = libmsg.clone(libmsg.format_3339(p.date, when_[:]))
	m.body = libmsg.clone(p.text)
	m.type = libmsg.clone("text/plain")
	m.replyto = libmsg.clone(p.parent)
	page: [256]u8
	m.links = libmsg.clone(libuser.cat_into(page[:], "https://bsky.app/profile/", string(account.user[:account.ulen]), "/post/", rkey_of(string(uri[:ulen]))))
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

// upload_blob sends one file to the server as it is and appends the blob
// the server answered, `{"$type": "blob", "ref": {...}, ...}`, to `into`.
upload_blob :: proc(p: ^Post, path: string, into: ^[dynamic]u8) -> bool {
	data, read := libuser.read_file(path, context.allocator)
	if !read || len(data) > ATTACH_MAX {
		return false
	}
	defer delete(data)
	url: [BASE_MAX + 64]u8
	ctype: [64]u8
	text, status, ok := as_account(p.io, "POST", libuser.cat_into(url[:], string(account.base[:account.blen]), "/xrpc/com.atproto.repo.uploadBlob"), libuser.cat_into(ctype[:], "Content-Type: ", media_type(path), "\n"), string(data))
	defer delete(text)
	if !ok || status != 200 {
		return false
	}
	// The blob object's own bytes, out of the answer.
	at := object_at(string(text), "blob")
	if at < 0 {
		return false
	}
	append(into, ..transmute([]u8)string(text)[at:libmsg.object_end(string(text), at)])
	return true
}

// media_type answers a file's media type by its suffix.
media_type :: proc "contextless" (path: string) -> string {
	for i := len(path) - 1; i >= 0 && path[i] != '/'; i -= 1 {
		if path[i] == '.' {
			switch path[i + 1:] {
			case "png":
				return "image/png"
			case "jpg", "jpeg":
				return "image/jpeg"
			case "gif":
				return "image/gif"
			case "webp":
				return "image/webp"
			}
			break
		}
	}
	return "application/octet-stream"
}

// object_at answers where the object under the top-level key `key`
// begins in `text`, its `{`, or -1; object_end where one ends.
object_at :: proc(text: string, key: string) -> int {
	depth := 0
	in_string := false
	i := 0
	for i < len(text) {
		c := text[i]
		if in_string {
			if c == '\\' {
				i += 1
			} else if c == '"' {
				in_string = false
			}
			i += 1
			continue
		}
		switch c {
		case '"':
			if depth == 1 && i + len(key) + 1 < len(text) && text[i + 1:i + 1 + len(key)] == key && text[i + 1 + len(key)] == '"' {
				j := i + len(key) + 2
				for j < len(text) && (text[j] == ' ' || text[j] == ':' || text[j] == '\n' || text[j] == '\r' || text[j] == '\t') {
					j += 1
				}
				if j < len(text) && text[j] == '{' {
					return j
				}
			}
			in_string = true
		case '[', '{':
			depth += 1
		case ']', '}':
			depth -= 1
		}
		i += 1
	}
	return -1
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
