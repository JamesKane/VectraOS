/*
httpd -- a directory served as HTTP/1.1, static and nothing else:
`docs/WEB.md` section 9. A person's site is the tree under `$home/www`,
and the machine that holds it is the site. A `.md` file is rendered to
HTML by `sys/libmark`, so a page is written once and read on the web
and, through `gemd`, on Gemini. A `/` asks for `index.html` or
`index.md`. Nothing is executed, no path climbs out of the root, and a
request that is not a GET or a POST to `/mention` is refused.

    httpd -r ROOT [port] [count]

With a port it announces `tcp!*!port` and serves `count` connections,
or forever when `count` is zero; the boot line gives a port and a
count. With no port it serves one connection on descriptors zero and
one, which is how `listen` runs it from `/lib/service/tcpNN`. A POST to
`/mention` is a Webmention: `mention.odin` takes it.
*/
package httpd

import "vsys:abi"
import "vsys:libmark"
import "vsys:libdoc"
import "vsys:libnet"
import "vsys:libodin"
import "vsys:libuser"

root: string
root_buf: [256]u8

say :: proc "contextless" (parts: ..string) {
	libuser.eprint(..parts)
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	context = libuser.startup()
	args := libuser.args(block)
	port := ""
	count := 1
	seen_count := false
	for i := 1; i < len(args); i += 1 {
		if args[i] == "-r" && i + 1 < len(args) {
			root = string(root_buf[:copy(root_buf[:], args[i + 1])])
			i += 1
		} else if port == "" {
			port = args[i]
		} else if !seen_count {
			if v, ok := libuser.atoi(args[i]); ok {
				count = int(v)
				seen_count = true
			}
		}
	}
	if root == "" {
		root = "/usr/glenda/www"
	}
	if port == "" {
		// A connection the listener handed us: descriptors zero and one.
		serve_conn(0, 1)
		libuser.exits("")
	}
	addr: [64]u8
	spec := libuser.cat_into(addr[:], "tcp!*!", port)
	dir: [libnet.DIAL_MAX]u8
	dirlen, ok := libnet.announce(spec, dir[:])
	if !ok {
		say("httpd: cannot announce ", spec, "\n")
		libuser.exits("announce")
	}
	served := string(dir[:dirlen])
	path: [160]u8
	lfd := libuser.open(libnet.join(path[:], served, "listen"), abi.O_RDONLY)
	if lfd < 0 {
		say("httpd: cannot listen\n")
		libuser.exits("listen")
	}
	say("httpd: serving ", root, " at ", served, "\n")
	for i := 0; count == 0 || i < count; i += 1 {
		accept_one(int(lfd), served)
	}
	_ = libuser.close(int(lfd))
	libuser.exits("")
}

// accept_one takes the next connection off `listen` and serves it.
accept_one :: proc(lfd: int, served: string) {
	line: [64]u8
	n := libuser.read(lfd, line[:])
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
	path: [200]u8
	dfd := libuser.open(libnet.join(path[:], accepted, "data"), abi.O_RDWR)
	if dfd < 0 {
		return
	}
	serve_conn(int(dfd), int(dfd))
	_ = libuser.close(int(dfd))
	libnet.hangup(accepted)
}

// serve_conn reads one request and answers it, from `rfd`, writing to `wfd`.
serve_conn :: proc(rfd: int, wfd: int) {
	req: [8192]u8
	got := 0
	for got < len(req) {
		m := libuser.read(rfd, req[got:])
		if m <= 0 {
			break
		}
		got += int(m)
		if blank_line_end(req[:got]) > 0 {
			break
		}
	}
	line := string(req[:got])
	// The request line: METHOD SP PATH SP VERSION.
	method, rest := libodin_word(line)
	target, _ := libodin_word(rest)
	if method == "POST" {
		body := ""
		if he := blank_line_end(req[:got]); he > 0 {
			want := header_int(line, "content-length")
			for got < he + want && got < len(req) {
				m := libuser.read(rfd, req[got:])
				if m <= 0 {
					break
				}
				got += int(m)
			}
			body = string(req[he:min(he + want, got)])
		}
		take_post(wfd, target, line, body)
		return
	}
	if method != "GET" && method != "HEAD" {
		respond(wfd, 405, "text/plain", "method not allowed\n", method == "HEAD")
		return
	}
	serve_path(wfd, target, method == "HEAD")
}

// serve_path answers a GET for `target` out of the root.
serve_path :: proc(wfd: int, target: string, head: bool) {
	// The path, its query cut, and no climb out of the root.
	p := target
	for i in 0 ..< len(p) {
		if p[i] == '?' || p[i] == '#' {
			p = p[:i]
			break
		}
	}
	if p == "" || p[0] != '/' || has_dotdot(p) {
		respond(wfd, 400, "text/plain", "bad request\n", head)
		return
	}
	full: [512]u8
	rel := p[1:]
	// A directory asks for its index.
	dir_target := len(rel) == 0 || rel[len(rel) - 1] == '/'
	if dir_target {
		if body, ctype, ok := read_index(full[:], rel); ok {
			respond(wfd, 200, ctype, body, head)
			delete_body(body, ctype)
			return
		}
		respond(wfd, 404, "text/plain", "not found\n", head)
		return
	}
	path := libuser.cat_into(full[:], root, "/", rel)
	// A `.md` is rendered; anything else is served as it is.
	if has_suffix(rel, ".md") {
		if body, ok := render_md(path); ok {
			respond(wfd, 200, "text/html; charset=utf-8", body, head)
			delete(body)
			return
		}
		respond(wfd, 404, "text/plain", "not found\n", head)
		return
	}
	data, ok := libuser.read_file(path, context.allocator)
	if !ok {
		respond(wfd, 404, "text/plain", "not found\n", head)
		return
	}
	respond(wfd, 200, content_type(rel), string(data), head)
	delete(data)
}

// read_index tries index.html then index.md under `rel`, and answers a
// body owned by the caller and whether it was rendered.
read_index :: proc(scratch: []u8, rel: string) -> (string, string, bool) {
	html := libuser.cat_into(scratch, root, "/", rel, "index.html")
	if data, ok := libuser.read_file(html, context.allocator); ok {
		return string(data), "text/html; charset=utf-8", true
	}
	md := libuser.cat_into(scratch, root, "/", rel, "index.md")
	if body, ok := render_md(md); ok {
		return body, "text/html; charset=utf-8", true
	}
	return "", "", false
}

delete_body :: proc(body: string, ctype: string) {
	delete(transmute([]u8)body)
}

// -- The Markdown page ------------------------------------------------------------

// render_md reads a `.md` file and answers it as an HTML page, owned by
// the caller, or false when the file is not there.
render_md :: proc(path: string) -> (string, bool) {
	src, ok := libuser.read_file(path, context.allocator)
	if !ok {
		return "", false
	}
	defer delete(src)
	d: libdoc.Doc
	libdoc.doc_init(&d)
	defer libdoc.doc_free(&d)
	libmark.parse(&d, string(src))
	out := make([dynamic]u8, 0, len(src) * 2 + 256)
	t := libdoc.title(&d)
	put(&out, "<!doctype html>\n<html><head><meta charset=\"utf-8\"><title>")
	put_escaped(&out, t == "" ? "page" : t)
	put(&out, "</title></head><body>\n")
	in_list := false
	for i in 0 ..< len(d.blocks) {
		b := &d.blocks[i]
		if b.kind == .Item {
			if !in_list {
				put(&out, "<ul>\n")
				in_list = true
			}
		} else if in_list {
			put(&out, "</ul>\n")
			in_list = false
		}
		text := libdoc.block_text(&d, i)
		href := libdoc.block_href(&d, i)
		#partial switch b.kind {
		case .Heading:
			lvl := b.level < 1 ? 1 : b.level > 3 ? 3 : b.level
			tag := lvl == 1 ? "h1" : lvl == 2 ? "h2" : "h3"
			put(&out, "<")
			put(&out, tag)
			put(&out, ">")
			put_escaped(&out, text)
			put(&out, "</")
			put(&out, tag)
			put(&out, ">\n")
		case .Text:
			put(&out, "<p>")
			put_escaped(&out, text)
			put(&out, "</p>\n")
		case .Link:
			put(&out, "<p><a href=\"")
			put_attr(&out, href)
			put(&out, "\">")
			put_escaped(&out, text == "" ? href : text)
			put(&out, "</a></p>\n")
		case .Item:
			put(&out, "<li>")
			put_escaped(&out, text)
			put(&out, "</li>\n")
		case .Quote:
			put(&out, "<blockquote>")
			put_escaped(&out, text)
			put(&out, "</blockquote>\n")
		case .Pre:
			put(&out, "<pre>")
			put_escaped(&out, text)
			put(&out, "</pre>\n")
		case .Image:
			put(&out, "<img src=\"")
			put_attr(&out, href)
			put(&out, "\" alt=\"")
			put_attr(&out, text)
			put(&out, "\">\n")
		case .Rule:
			put(&out, "<hr>\n")
		}
	}
	if in_list {
		put(&out, "</ul>\n")
	}
	put(&out, "</body></html>\n")
	return string(out[:]), true
}

// -- HTTP out ---------------------------------------------------------------------

// respond writes a response: the status, the type, the length, and the
// body unless the request was a HEAD.
respond :: proc(wfd: int, status: int, ctype: string, body: string, head: bool) {
	head_buf: [512]u8
	num: [24]u8
	reason := status == 200 ? "OK" : status == 404 ? "Not Found" : status == 400 ? "Bad Request" : status == 202 ? "Accepted" : status == 405 ? "Method Not Allowed" : "Error"
	h := libuser.cat_into(head_buf[:], "HTTP/1.1 ", libuser.itoa(num[:], i64(status)), " ", reason, "\r\nContent-Type: ", ctype, "\r\nContent-Length: ", libuser.itoa(num[:], i64(len(body))), "\r\nConnection: close\r\n\r\n")
	_ = libuser.write_full(wfd, transmute([]u8)h)
	if !head && len(body) > 0 {
		_ = libuser.write_full(wfd, transmute([]u8)body)
	}
}

// content_type answers the media type by a file name's suffix.
content_type :: proc "contextless" (name: string) -> string {
	if has_suffix(name, ".html") || has_suffix(name, ".htm") {
		return "text/html; charset=utf-8"
	}
	if has_suffix(name, ".css") {
		return "text/css"
	}
	if has_suffix(name, ".txt") || has_suffix(name, ".gmi") {
		return "text/plain; charset=utf-8"
	}
	if has_suffix(name, ".png") {
		return "image/png"
	}
	if has_suffix(name, ".jpg") || has_suffix(name, ".jpeg") {
		return "image/jpeg"
	}
	if has_suffix(name, ".xml") || has_suffix(name, ".atom") {
		return "application/atom+xml"
	}
	return "application/octet-stream"
}

// -- Small things -----------------------------------------------------------------

put :: proc(out: ^[dynamic]u8, s: string) {
	append(out, ..transmute([]u8)s)
}

// put_escaped writes text as HTML content: `<`, `>` and `&` made safe.
put_escaped :: proc(out: ^[dynamic]u8, s: string) {
	for c in transmute([]u8)s {
		switch c {
		case '<':
			put(out, "&lt;")
		case '>':
			put(out, "&gt;")
		case '&':
			put(out, "&amp;")
		case:
			append(out, c)
		}
	}
}

// put_attr writes text inside a double-quoted attribute: `"` and `&` safe.
put_attr :: proc(out: ^[dynamic]u8, s: string) {
	for c in transmute([]u8)s {
		switch c {
		case '"':
			put(out, "&quot;")
		case '&':
			put(out, "&amp;")
		case '<':
			put(out, "&lt;")
		case:
			append(out, c)
		}
	}
}

has_suffix :: proc "contextless" (s, suffix: string) -> bool {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}

has_dotdot :: proc "contextless" (p: string) -> bool {
	for i in 0 ..< len(p) {
		if p[i] == '.' && i + 1 < len(p) && p[i + 1] == '.' {
			return true
		}
	}
	return false
}

libodin_word :: proc "contextless" (s: string) -> (first: string, rest: string) {
	i := 0
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i += 1
	}
	start := i
	for i < len(s) && s[i] != ' ' && s[i] != '\t' && s[i] != '\r' && s[i] != '\n' {
		i += 1
	}
	first = s[start:i]
	for i < len(s) && (s[i] == ' ' || s[i] == '\t') {
		i += 1
	}
	return first, s[i:]
}

// blank_line_end answers the index just past the header's blank line, or 0.
blank_line_end :: proc "contextless" (buf: []u8) -> int {
	for i in 0 ..< len(buf) {
		if buf[i] == '\n' && i >= 3 && buf[i - 1] == '\r' && buf[i - 2] == '\n' && buf[i - 3] == '\r' {
			return i + 1
		}
		if buf[i] == '\n' && i >= 1 && buf[i - 1] == '\n' {
			return i + 1
		}
	}
	return 0
}

// header_int answers a header's value as a number, its name lower case.
header_int :: proc "contextless" (text: string, name: string) -> int {
	at := 0
	for at < len(text) {
		e := at
		for e < len(text) && text[e] != '\n' {
			e += 1
		}
		line := text[at:e]
		if len(line) > len(name) + 1 && lower_eq(line[:len(name)], name) && line[len(name)] == ':' {
			v := 0
			for i := len(name) + 1; i < len(line); i += 1 {
				c := line[i]
				if c >= '0' && c <= '9' {
					v = v * 10 + int(c - '0')
				} else if c != ' ' && c != '\t' && c != '\r' {
					break
				}
			}
			return v
		}
		at = e + 1
	}
	return 0
}

lower_eq :: proc "contextless" (a, b: string) -> bool {
	if len(a) != len(b) {
		return false
	}
	for i in 0 ..< len(a) {
		ca := a[i]
		if ca >= 'A' && ca <= 'Z' {
			ca += 32
		}
		if ca != b[i] {
			return false
		}
	}
	return true
}

_ :: libodin
