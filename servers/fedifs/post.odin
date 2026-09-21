/*
A status written to `new`: `docs/WEB.md` section 4's block, posted as
the account. The body is the status, `subject` its content warning,
`replyto` an id in `home`, whose status on the instance it then
answers, and `attach` a path, uploaded first and carried as media. The write waits for the instance, and the status the instance
answers lands in `home` and under `sent/` of the store, the activity as
the server sent it. The token comes from `factotum` for the request and
is not kept.
*/
package fedifs

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

// One status on its way out: the held write, the form it sends, and
// the attachments uploaded before it.
Post :: struct {
	tag:     vectra9.Tag,
	count:   int,
	io:      ^libthread.Ioproc,
	form:    [dynamic]u8,
	attach:  [MAX_ATTACH][256]u8,
	alen:    [MAX_ATTACH]int,
	nattach: int,
	why:     string,
}

// start_post reads the block, builds the form, and posts it on a thread
// while the write waits.
start_post :: proc(tag: vectra9.Tag, text: string) -> vectra9.Errno {
	if !account.set {
		return vectra9.EPERM
	}
	n := libmsg.parse_new(text)
	defer libmsg.new_free(&n)
	if bad, has_bad := libmsg.new_unknown(&n); has_bad {
		libuser.eprint("fedifs: new: no such header here: ", bad, "\n")
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
	p.form = make([dynamic]u8, 0, 512)
	append(&p.form, ..transmute([]u8)string("status="))
	form_encode(&p.form, body)
	if subject, has := libmsg.new_header(&n, "subject"); has && len(subject) > 0 {
		append(&p.form, ..transmute([]u8)string("&spoiler_text="))
		form_encode(&p.form, subject)
	}
	for k in 0 ..< MAX_ATTACH {
		path, has := libmsg.new_attach(&n, k)
		if !has {
			break
		}
		p.alen[k] = copy(p.attach[k][:], path)
		p.nattach += 1
	}
	if replyto, has := libmsg.new_header(&n, "replyto"); has && len(replyto) > 0 {
		// The status it answers, by the instance's own id, which is the
		// message's name past the date.
		home := libmsg.conv(&net, "home")
		i := libmsg.find(home, replyto)
		if i < 0 || len(replyto) < 18 {
			delete(p.form)
			free(p)
			return vectra9.ENOENT
		}
		append(&p.form, ..transmute([]u8)string("&in_reply_to_id="))
		form_encode(&p.form, replyto[17:])
	}
	if libthread.threadcreate(post_thread, p, 256 * 1024) < 0 {
		delete(p.form)
		free(p)
		return vectra9.ENOSPC
	}
	lib9p.hold(&net.srv)
	return 0
}

post_thread :: proc "contextless" (arg: rawptr) {
	context = libuser.heap_context()
	p := (^Post)(arg)
	err := vectra9.Errno(0)
	p.io = libthread.ioproc()
	if p.io == nil {
		err = vectra9.EIO
	} else {
		err = post(p)
		libthread.ioclose(p.io)
	}
	if err != 0 && p.why != "" {
		libuser.eprint("fedifs: ", p.why, "\n")
	}
	if req := lib9p.find_held_tag(&net.srv, p.tag); req != nil {
		if err == 0 {
			_ = lib9p.respond(req, vectra9.Rwrite{count = u32(p.count)})
		} else {
			_ = lib9p.respond(req, vectra9.error_reply(err))
		}
	}
	delete(p.form)
	free(p)
	libthread.threadexits("")
}

// post sends the form with the token and takes the status answered into
// home and the store.
post :: proc(p: ^Post) -> vectra9.Errno {
	tok: [256]u8
	token, has := libmsg.ask_token(string(account.user[:account.ulen]), libmsg.host_of(string(account.base[:account.blen])), tok[:])
	if !has {
		p.why = "factotum holds no token for the account"
		return vectra9.EPERM
	}
	url: [BASE_MAX + 64]u8
	auth: [400]u8
	// The attachments first, each an upload the instance names, and the
	// names go on the form.
	for k in 0 ..< p.nattach {
		id, uploaded := upload_media(p, token, string(p.attach[k][:p.alen[k]]))
		if !uploaded {
			p.why = "the instance would not take the attachment"
			return vectra9.EIO
		}
		append(&p.form, ..transmute([]u8)string("&media_ids[]="))
		form_encode(&p.form, id)
	}
	headers := libuser.cat_into(auth[:], "Authorization: Bearer ", token, "\nContent-Type: application/x-www-form-urlencoded\n")
	text, status, ok := libmsg.request(p.io, libuser.cat_into(url[:], string(account.base[:account.blen]), "/api/v1/statuses"), "POST", headers, string(p.form[:]))
	defer delete(text)
	if !ok || status != 200 {
		p.why = "the instance would not take the status"
		return vectra9.EIO
	}
	m, made := status_message(string(text))
	if !made {
		p.why = "the instance answered no status"
		return vectra9.EIO
	}
	id := m.id
	_ = libmsg.keep_sent(string(store[:store_len]), id, string(text))
	home := libmsg.conv(&net, "home")
	libmsg.add(&net, home, m)
	libmsg.resolve_replies(home)
	rebuild_status()
	return 0
}

/*
upload_media sends one file to the instance as multipart form data and
answers the id it gave it. The media type is the file's suffix's. The
id lives in `id_buf` until the next upload.
*/
upload_media :: proc(p: ^Post, token: string, path: string) -> (id: string, ok: bool) {
	@(static) id_buf: [64]u8
	data, read := libuser.read_file(path, context.allocator)
	if !read || len(data) > ATTACH_MAX {
		return "", false
	}
	defer delete(data)
	boundary := "vectra-part-7f3a9c"
	body := make([dynamic]u8, 0, len(data) + 512)
	defer delete(body)
	append(&body, ..transmute([]u8)string("--"))
	append(&body, ..transmute([]u8)boundary)
	append(&body, ..transmute([]u8)string("\r\nContent-Disposition: form-data; name=\"file\"; filename=\""))
	append(&body, ..transmute([]u8)libuser.basename(path))
	append(&body, ..transmute([]u8)string("\"\r\nContent-Type: "))
	append(&body, ..transmute([]u8)media_type(path))
	append(&body, ..transmute([]u8)string("\r\n\r\n"))
	append(&body, ..data)
	append(&body, ..transmute([]u8)string("\r\n--"))
	append(&body, ..transmute([]u8)boundary)
	append(&body, ..transmute([]u8)string("--\r\n"))
	url: [BASE_MAX + 64]u8
	auth: [400]u8
	headers := libuser.cat_into(auth[:], "Authorization: Bearer ", token, "\nContent-Type: multipart/form-data; boundary=", boundary, "\n")
	text, status, sent := libmsg.request(p.io, libuser.cat_into(url[:], string(account.base[:account.blen]), "/api/v2/media"), "POST", headers, string(body[:]))
	defer delete(text)
	if !sent || (status != 200 && status != 202) {
		return "", false
	}
	v, err := json.parse_string(string(text), .JSON)
	defer json.destroy_value(v)
	o, is_obj := v.(json.Object)
	if err != .None || !is_obj {
		return "", false
	}
	got := libmsg.str_of(o, "id")
	if got == "" {
		return "", false
	}
	n := copy(id_buf[:], got)
	return string(id_buf[:n]), true
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
			case "mp4":
				return "video/mp4"
			}
			break
		}
	}
	return "application/octet-stream"
}

// form_encode appends `s` as a form field's value: letters, digits and
// `-_.~` as they are, a space as `+`, and the rest as `%XX`.
form_encode :: proc(out: ^[dynamic]u8, s: string) {
	hex := "0123456789ABCDEF"
	for c in transmute([]u8)s {
		switch {
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~':
			append(out, c)
		case c == ' ':
			append(out, '+')
		case:
			append(out, '%', hex[c >> 4], hex[c & 15])
		}
	}
}
