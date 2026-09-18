/*
What a write to `new` says: header lines, an empty line, the body, the
same block on every network. `to` is an address, a room, a thread or
nothing. `replyto` is an id. `subject` is a title. `attach` is a path, and
may repeat. A network that cannot honour a header refuses the write by
name. `sys/libmime` reads the block, since it is mail's.
*/
package libmsg

import "vsys:libmime"

// A message as written to `new`.
New :: struct {
	headers: libmime.Headers,
	body:    string, // Into the text written
}

// parse_new reads the block. `to`, `replyto` and `subject` are answered
// by `new_header`, and `attach` lines by `new_attach`.
parse_new :: proc(text: string, allocator := context.allocator) -> (n: New) {
	context.allocator = allocator
	head, body := libmime.split_head(text)
	n.headers = libmime.parse_headers(head)
	n.body = body
	return n
}

new_free :: proc(n: ^New, allocator := context.allocator) {
	context.allocator = allocator
	delete(n.headers.text)
	delete(n.headers.list)
	n^ = New{}
}

new_header :: proc "contextless" (n: ^New, name: string) -> (string, bool) {
	return libmime.header(&n.headers, name)
}

// new_attach answers the i'th `attach` header's path, or false.
new_attach :: proc "contextless" (n: ^New, i: int) -> (string, bool) {
	k := 0
	for e in n.headers.list {
		if libmime.equal_fold(e.name, "attach") {
			if k == i {
				return e.value, true
			}
			k += 1
		}
	}
	return "", false
}

// new_unknown answers the first header that is none of the four, for a
// network to refuse by name, or false when every header is known.
new_unknown :: proc "contextless" (n: ^New) -> (string, bool) {
	for e in n.headers.list {
		known := libmime.equal_fold(e.name, "to") || libmime.equal_fold(e.name, "replyto") || libmime.equal_fold(e.name, "subject") || libmime.equal_fold(e.name, "attach")
		if !known {
			return e.name, true
		}
	}
	return "", false
}
