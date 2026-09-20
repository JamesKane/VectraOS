/*
A status written to `new`: `docs/WEB.md` section 4's block, posted as
the account. The body is the status, `subject` its content warning,
and `replyto` an id in `home`, whose status on the instance it then
answers. The write waits for the instance, and the status the instance
answers lands in `home` and under `sent/` of the store, the activity as
the server sent it. The token comes from `factotum` for the request and
is not kept.
*/
package fedifs

import "vsys:lib9p"
import "vsys:libmsg"
import "vsys:libthread"
import "vsys:libuser"
import "vsys:vectra9"

// The store: `-s DIR`, where `sent/` keeps what went out.
store: [256]u8
store_len: int

// One status on its way out: the held write and the form it sends.
Post :: struct {
	tag:   vectra9.Tag,
	count: int,
	io:    ^libthread.Ioproc,
	form:  [dynamic]u8,
	why:   string,
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
	token, has := ask_token(tok[:])
	if !has {
		p.why = "factotum holds no token for the account"
		return vectra9.EPERM
	}
	url: [BASE_MAX + 64]u8
	auth: [400]u8
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
	resolve_replies(home)
	rebuild_status()
	return 0
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
