/*
Messages in the reader: a directory of messages is a timeline, a message
is a page, and a plain directory is a listing. `docs/WEB.md` section 5.

The shape is `sys/libmsg`'s, so a mailbox, a room, a feed and a union of
them all draw the same way. A timeline is one row a message: its time,
its author and its first line, and a press opens the message in place. A
message is its subject, sender and date, its body by the type it
declares, its links, and its replies as rows of their own.
*/
package mothra

import "vsys:libdoc"
import "vsys:libgemtext"
import "vsys:libhtml"
import "vsys:libmark"
import "vsys:libmsg"
import "vsys:libuser"

ROW_MAX :: 1024

// load_dir fills the document from a directory: a message, a timeline or
// a listing. False when the directory cannot be read.
load_dir :: proc(dir: string) -> bool {
	if libmsg.is_message(dir) {
		return load_message(dir)
	}
	rows, ok := libmsg.read_conv(dir)
	if !ok {
		return false
	}
	defer libmsg.rows_free(rows)
	libdoc.doc_title(&doc, libuser.basename(dir))
	if len(rows) > 0 {
		add_rows(dir, rows)
		return true
	}
	// No message in it: a listing, one row a name.
	names, found := libuser.read_dir(dir)
	if !found {
		return false
	}
	path: [ROW_MAX]u8
	for name in names {
		libdoc.doc_add(&doc, .Link, name, libuser.cat_into(path[:], dir, "/", name))
		delete(name)
	}
	delete(names)
	return true
}

// add_rows adds a timeline's rows, one link a message, under `dir`.
add_rows :: proc(dir: string, rows: []libmsg.Msg) {
	line: [ROW_MAX]u8
	path: [ROW_MAX]u8
	when_: [16]u8
	for &m in rows {
		text := libuser.cat_into(line[:], libmsg.format_time(m.date, when_[:]), "  ", m.from, ": ", libmsg.first_line(&m))
		libdoc.doc_add(&doc, .Link, text, libuser.cat_into(path[:], dir, "/", m.id))
	}
}

load_message :: proc(dir: string) -> bool {
	m, ok := libmsg.read_msg(dir)
	if !ok {
		return false
	}
	defer libmsg.msg_free(&m)
	line: [ROW_MAX]u8
	path: [ROW_MAX]u8
	when_: [16]u8
	subject := len(m.subject) > 0 ? m.subject : libmsg.first_line(&m)
	libdoc.doc_title(&doc, subject)
	libdoc.doc_add(&doc, .Heading, subject, "", 1)
	libdoc.doc_add(&doc, .Text, libuser.cat_into(line[:], "From ", m.from))
	date := len(m.date_text) > 0 ? m.date_text : libmsg.format_time(m.date, when_[:])
	libdoc.doc_add(&doc, .Text, libuser.cat_into(line[:], "Date ", date))
	if len(m.replyto) > 0 {
		parent := dir
		for i := len(parent) - 1; i > 0; i -= 1 {
			if parent[i] == '/' {
				parent = parent[:i]
				break
			}
		}
		libdoc.doc_add(&doc, .Link, libuser.cat_into(line[:], "In reply to ", m.replyto), libuser.cat_into(path[:], parent, "/", m.replyto))
	}
	libdoc.doc_add(&doc, .Text, "")
	switch {
	case starts_with(m.type, "text/html"):
		libhtml.parse(&doc, m.body)
	case starts_with(m.type, "text/gemini"):
		libgemtext.parse(&doc, m.body)
	case starts_with(m.type, "text/markdown"):
		libmark.parse(&doc, m.body)
	case:
		parse_plain(&doc, m.body)
	}
	// What it points at, one link a line.
	at := 0
	for at < len(m.links) {
		end := at
		for end < len(m.links) && m.links[end] != '\n' {
			end += 1
		}
		if end > at {
			libdoc.doc_add(&doc, .Link, m.links[at:end], m.links[at:end])
		}
		at = end + 1
	}
	// Its replies, the same rows a timeline has.
	replies, has := libmsg.read_conv(libuser.cat_into(path[:], dir, "/replies"))
	if has {
		if len(replies) > 0 {
			libdoc.doc_add(&doc, .Text, "")
			libdoc.doc_add(&doc, .Heading, "Replies", "", 2)
			add_rows(libuser.cat_into(path[:], dir, "/replies"), replies)
		}
		libmsg.rows_free(replies)
	}
	return true
}

