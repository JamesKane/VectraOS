/*
Compose is one window. `docs/WEB.md` section 5.

A message to any network is the header block and a body, written to that
network's `new`, so the window is a form whose action is that file: `to`,
`subject`, a hidden `replyto`, the body, and a Send button. It opens on
`compose:/mnt/mail`, on `mailto:box@host` with the address filled, and on
`c` over a message, as a reply with `to`, `subject` and `replyto` filled.
Sent, the reader shows the network's `sent/` timeline. Refused, the page
says so. The body is one line, until the toolkit has a text editor.
*/
package mothra

import "vsys:abi"
import "vsys:libdoc"
import "vsys:libmime"
import "vsys:libmsg"
import "vsys:libuser"

COMPOSE_MAX :: 2048

// compose_load fills the document from a `compose:NET?to=..&subject=..&
// replyto=..` or `mailto:BOX?subject=..` target.
compose_load :: proc(target: string) -> bool {
	net := "/mnt/mail"
	to: [COMPOSE_MAX]u8
	subject: [COMPOSE_MAX]u8
	replyto: [COMPOSE_MAX]u8
	tn, sn, rn := 0, 0, 0
	rest := target
	query := ""
	for i in 0 ..< len(rest) {
		if rest[i] == '?' {
			query = rest[i + 1:]
			rest = rest[:i]
			break
		}
	}
	if starts_with(rest, "mailto:") {
		tn = copy(to[:], rest[len("mailto:"):])
	} else if starts_with(rest, "compose:") && len(rest) > len("compose:") {
		net = rest[len("compose:"):]
	}
	// The query's pairs, decoded.
	at := 0
	for at < len(query) {
		e := at
		for e < len(query) && query[e] != '&' {
			e += 1
		}
		pair := query[at:e]
		at = e + 1
		eq := -1
		for i in 0 ..< len(pair) {
			if pair[i] == '=' {
				eq = i
				break
			}
		}
		if eq < 0 {
			continue
		}
		switch pair[:eq] {
		case "to":
			tn = url_decode(pair[eq + 1:], to[:])
		case "subject":
			sn = url_decode(pair[eq + 1:], subject[:])
		case "replyto":
			rn = url_decode(pair[eq + 1:], replyto[:])
		}
	}
	line: [ROW_MAX]u8
	libdoc.doc_title(&doc, "New message")
	libdoc.doc_add(&doc, .Heading, "New message", "", 1)
	libdoc.doc_add(&doc, .Text, libuser.cat_into(line[:], "Through ", net, ". Tab moves between the parts, Return sends."))
	libdoc.doc_add(&doc, .Text, "")
	form := libdoc.doc_form(&doc, libuser.cat_into(line[:], net, "/new"), true)
	libdoc.doc_field(&doc, .Field, "To", "to", string(to[:tn]), form)
	libdoc.doc_field(&doc, .Field, "Subject", "subject", string(subject[:sn]), form)
	libdoc.doc_field(&doc, .Hidden, "", "replyto", string(replyto[:rn]), form)
	libdoc.doc_field(&doc, .Field, "Body", "body", "", form)
	libdoc.doc_field(&doc, .Submit, "Send", "send", "Send", form)
	return true
}

// is_compose says whether a form is a compose window's: its action is a
// network's `new`.
is_compose :: proc "contextless" (action: string) -> bool {
	return !has_scheme(action) && ends_with(action, "/new")
}

/*
compose_send writes the block to the network's `new` and shows what came
of it: the network's `sent/` when the write was taken, or the refusal.
`values` are the form's parts by block, as `submit` gathered them.
*/
compose_send :: proc(action: string, values: []string) {
	block: [4 * COMPOSE_MAX]u8
	n := 0
	body := ""
	for i in 0 ..< len(doc.blocks) {
		b := &doc.blocks[i]
		if !libdoc.is_form_part(b.kind) || b.kind == .Submit {
			continue
		}
		name := libdoc.block_href(&doc, i)
		value := values[i]
		if name == "body" {
			body = value
			continue
		}
		if len(value) == 0 {
			continue
		}
		n += copy(block[n:], name)
		n += copy(block[n:], ": ")
		n += copy(block[n:], value)
		n += copy(block[n:], "\n")
	}
	n += copy(block[n:], "\n")
	n += copy(block[n:], body)
	n += copy(block[n:], "\n")
	fd := libuser.open(action, abi.O_WRONLY)
	wrote := i64(-1)
	if fd >= 0 {
		wrote = libuser.write(int(fd), block[:n])
		_ = libuser.close(int(fd))
	}
	if wrote == i64(n) {
		sent: [ROW_MAX]u8
		go(libuser.cat_into(sent[:], parent_of(action), "/sent"), true)
		return
	}
	line: [ROW_MAX]u8
	libdoc.doc_add(&doc, .Text, "")
	libdoc.doc_add(&doc, .Quote, libuser.cat_into(line[:], "The network refused the message: ", fd < 0 ? "no new file there" : libuser.errstr(wrote)))
	relayout()
}

// compose_reply opens the window as a reply to the message the page shows.
compose_reply :: proc() {
	cur := string(current[:current_len])
	if !in_place || !libmsg.is_message(cur) {
		return
	}
	m, ok := libmsg.read_msg(cur)
	if !ok {
		return
	}
	defer libmsg.msg_free(&m)
	name_buf: [256]u8
	_, box := libmime.address(m.from, name_buf[:])
	target: [4 * COMPOSE_MAX]u8
	n := copy(target[:], "compose:")
	n += copy(target[n:], parent_of(parent_of(cur)))
	n += copy(target[n:], "?to=")
	n = libdoc.url_encode(target[:], n, box)
	n += copy(target[n:], "&subject=")
	if !starts_with(m.subject, "Re: ") {
		n = libdoc.url_encode(target[:], n, "Re: ")
	}
	n = libdoc.url_encode(target[:], n, m.subject)
	n += copy(target[n:], "&replyto=")
	n = libdoc.url_encode(target[:], n, m.id)
	go(string(target[:n]), true)
}

@(private = "file")
url_decode :: proc "contextless" (s: string, into: []u8) -> int {
	n := 0
	i := 0
	for i < len(s) && n < len(into) {
		c := s[i]
		if c == '%' && i + 2 < len(s) && is_hex(s[i + 1]) && is_hex(s[i + 2]) {
			into[n] = hex_val(s[i + 1]) << 4 | hex_val(s[i + 2])
			i += 3
		} else if c == '+' {
			into[n] = ' '
			i += 1
		} else {
			into[n] = c
			i += 1
		}
		n += 1
	}
	return n
}

@(private = "file")
is_hex :: proc "contextless" (c: u8) -> bool {
	return (c >= '0' && c <= '9') || (c >= 'a' && c <= 'f') || (c >= 'A' && c <= 'F')
}

@(private = "file")
hex_val :: proc "contextless" (c: u8) -> u8 {
	switch {
	case c >= '0' && c <= '9':
		return c - '0'
	case c >= 'a' && c <= 'f':
		return c - 'a' + 10
	case:
		return c - 'A' + 10
	}
}
