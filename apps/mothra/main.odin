/*
mothra -- the reader, `docs/WEB.md` section 5.

`mothra URL` or `mothra file` shows a page in a window. Gemtext, markdown,
HTML or plain text is laid out by `sys/libdoc` to the window's columns and
shown as rows, one selected. A press on a link's row follows it, and the
page it leads to takes the window. `b` goes back, `j` and `k` move a row,
`n` and `p` a page, `r` fetches again, `q` and Escape close.

A URL is fetched through `/mnt/web`, `servers/webfs`. So every scheme it
speaks is one this reads, and the page lands in the store on the way. A
file is read from the namespace, its kind by its suffix.

This is the reader's first cut. The toolkit's list is the page, so every
row wears one face. A click follows a link itself rather than through the
plumber, which `docs/GHOST.md` step 2 has yet to build. Images, messages
and the column come next.
*/
package mothra

import "base:runtime"

import "vsys:abi"
import "vsys:libdoc"
import "vsys:libgemtext"
import "vsys:libhtml"
import "vsys:libmark"
import "vsys:libmui"
import "vsys:libthread"
import "vsys:libuser"

MAX_BYTES :: 1024 * 1024
MAX_ROWS :: 16384
URL_MAX :: 1024
HISTORY :: 32

ctx: runtime.Context
win: libmui.Window
page: ^libmui.Object
doc: libdoc.Doc
lay: libdoc.Layout
rows: []string

// Where the reader is, and where it was.
current: [URL_MAX]u8
current_len: int
history: [HISTORY][URL_MAX]u8
history_len: [HISTORY]int
history_n: int

Kind :: enum {
	Plain,
	Gemtext,
	Markdown,
	Html,
}

@(export, link_name = "_start")
start :: proc "c" (block: ^abi.Args) {
	ctx = libuser.startup()
	context = ctx
	args := libuser.args(block)
	if len(args) < 2 {
		libuser.eprint("usage: mothra url|file\n")
		libuser.exits("usage")
	}
	current_len = copy(current[:], args[1])
	libthread.main(mothra_main, nil)
}

mothra_main :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = ctx
	rows = make([]string, MAX_ROWS)
	libdoc.doc_init(&doc)
	libdoc.layout_init(&lay)

	page = libmui.list(24)
	page.id = 1
	col := libmui.group(false)
	libmui.add(col, page)
	win.handler = on_press
	win.on_key = on_key
	win.want_w, win.want_h = 80 * libmui.FONT_W + 8, 30 * libmui.FONT_H + 8
	win.set_up = true
	win.kind = .Normal
	win.bind_dev = true
	win.own_exit = true

	if !load(string(current[:current_len])) {
		libuser.eprint("mothra: cannot read ", string(current[:current_len]), "\n")
		libthread.threadexitsall("read")
	}
	if !libmui.window_open(&win, page_title(), col) {
		libthread.threadexitsall("open")
	}
	// Now the window has a width, the page is laid out to it.
	relayout()
	libmui.window_paint(&win)
	libmui.window_run(&win)
	libthread.threadexits("")
}

page_title :: proc "contextless" () -> string {
	t := libdoc.title(&doc)
	return len(t) > 0 ? t : string(current[:current_len])
}

// relayout lays the document out to the list's width and hands the rows to
// the list, its top at the first row.
relayout :: proc "contextless" () {
	context = ctx
	cols := page.w > 0 ? (page.w - 2 * win.theme.well) / libmui.FONT_W : 78
	n := libdoc.layout(&lay, &doc, cols)
	n = libdoc.rows_as_strings(&lay, rows[:min(n, MAX_ROWS)])
	page.rows = rows[:n]
	page.top = 0
	page.sel = -1
}

// on_press follows the link a pressed row belongs to. Escape closes.
on_press :: proc "contextless" (w: ^libmui.Window, id: int) {
	context = ctx
	if id == -1 {
		w.done = true
		return
	}
	if id != 1 || w.arg < 0 || w.arg >= len(lay.rows) {
		return
	}
	b := lay.rows[w.arg].block
	if doc.blocks[b].kind != .Link {
		return
	}
	href := libdoc.block_href(&doc, b)
	target: [URL_MAX]u8
	n := resolve(href, target[:])
	if n <= 0 {
		return
	}
	go(string(target[:n]), true)
}

// on_key scrolls, goes back, fetches again, or closes.
on_key :: proc "contextless" (w: ^libmui.Window, k: u8) -> bool {
	context = ctx
	visible := libmui.list_visible(page, &w.theme)
	last := max(len(page.rows) - visible, 0)
	switch k {
	case 'j':
		page.top = min(page.top + 1, last)
	case 'k':
		page.top = max(page.top - 1, 0)
	case 'n':
		page.top = min(page.top + max(visible - 1, 1), last)
	case 'p':
		page.top = max(page.top - max(visible - 1, 1), 0)
	case 'b':
		back()
	case 'r':
		_ = load(string(current[:current_len]))
		relayout()
	case 'q':
		w.done = true
	case:
		return false
	}
	return true
}

// go leaves the current page in the history and loads `target`.
go :: proc "contextless" (target: string, remember: bool) {
	context = ctx
	if remember && history_n < HISTORY {
		history_len[history_n] = copy(history[history_n][:], current[:current_len])
		history_n += 1
	}
	saved: [URL_MAX]u8
	saved_n := copy(saved[:], target)
	current_len = copy(current[:], saved[:saved_n])
	if !load(string(current[:current_len])) {
		libuser.eprint("mothra: cannot read ", string(current[:current_len]), "\n")
	}
	relayout()
}

back :: proc "contextless" () {
	if history_n == 0 {
		return
	}
	history_n -= 1
	saved: [URL_MAX]u8
	n := copy(saved[:], history[history_n][:history_len[history_n]])
	go(string(saved[:n]), false)
}

/*
resolve makes `href` absolute against the current page. A scheme keeps it. A
leading slash is a path on the current host. Anything else is relative to
the current page's directory. A file path resolves the same way, its
"host" being nothing.
*/
resolve :: proc "contextless" (href: string, into: []u8) -> int {
	cur := string(current[:current_len])
	if has_scheme(href) {
		return copy(into, href)
	}
	// The current page's scheme and host, and its path.
	base_end := 0
	if has_scheme(cur) {
		sep := 0
		for i in 0 ..< len(cur) - 2 {
			if cur[i] == ':' && cur[i + 1] == '/' && cur[i + 2] == '/' {
				sep = i + 3
				break
			}
		}
		base_end = len(cur)
		for i := sep; i < len(cur); i += 1 {
			if cur[i] == '/' {
				base_end = i
				break
			}
		}
	}
	if len(href) > 0 && href[0] == '/' {
		n := copy(into, cur[:base_end])
		return n + copy(into[n:], href)
	}
	// The directory of the current path.
	dir_end := len(cur)
	for dir_end > base_end && cur[dir_end - 1] != '/' {
		dir_end -= 1
	}
	if dir_end == base_end {
		n := copy(into, cur[:base_end])
		n += copy(into[n:], "/")
		return n + copy(into[n:], href)
	}
	n := copy(into, cur[:dir_end])
	return n + copy(into[n:], href)
}

has_scheme :: proc "contextless" (s: string) -> bool {
	for i in 0 ..< len(s) {
		if s[i] == ':' {
			return i + 2 < len(s) && s[i + 1] == '/' && s[i + 2] == '/'
		}
		if s[i] == '/' {
			return false
		}
	}
	return false
}

// -- Loading a page -------------------------------------------------------------

// load reads `target`, a URL through webfs or a file, parses it by its kind
// into a fresh document, and answers whether there was one.
load :: proc "contextless" (target: string) -> bool {
	context = ctx
	text: []u8
	kind: Kind
	ok: bool
	if has_scheme(target) {
		text, kind, ok = fetch(target)
	} else {
		text, ok = libuser.read_file(target, context.allocator)
		kind = kind_of_suffix(target)
	}
	if !ok {
		return false
	}
	defer delete(text)
	libdoc.doc_free(&doc)
	libdoc.doc_init(&doc)
	switch kind {
	case .Gemtext:
		libgemtext.parse(&doc, string(text))
	case .Markdown:
		libmark.parse(&doc, string(text))
	case .Html:
		libhtml.parse(&doc, string(text))
	case .Plain:
		parse_plain(&doc, string(text))
	}
	return true
}

// parse_plain makes each line a paragraph, so long lines wrap.
parse_plain :: proc(d: ^libdoc.Doc, src: string) {
	at := 0
	for at < len(src) {
		end := at
		for end < len(src) && src[end] != '\n' {
			end += 1
		}
		line := src[at:end]
		if len(line) > 0 && line[len(line) - 1] == '\r' {
			line = line[:len(line) - 1]
		}
		libdoc.doc_add(d, .Text, line)
		at = end + 1
	}
}

kind_of_suffix :: proc "contextless" (path: string) -> Kind {
	if ends_with(path, ".gmi") || ends_with(path, ".gemini") {
		return .Gemtext
	}
	if ends_with(path, ".md") || ends_with(path, ".markdown") {
		return .Markdown
	}
	if ends_with(path, ".html") || ends_with(path, ".htm") {
		return .Html
	}
	return .Plain
}

kind_of_type :: proc "contextless" (ctype: string, url: string) -> Kind {
	if starts_with(ctype, "text/gemini") {
		return .Gemtext
	}
	if starts_with(ctype, "text/markdown") {
		return .Markdown
	}
	if starts_with(ctype, "text/html") || starts_with(ctype, "application/xhtml") {
		return .Html
	}
	if len(ctype) == 0 {
		return kind_of_suffix(url)
	}
	return .Plain
}

is_digit :: proc "contextless" (c: u8) -> bool {
	return c >= '0' && c <= '9'
}

ends_with :: proc "contextless" (s, suffix: string) -> bool {
	return len(s) >= len(suffix) && s[len(s) - len(suffix):] == suffix
}

starts_with :: proc "contextless" (s, prefix: string) -> bool {
	return len(s) >= len(prefix) && s[:len(prefix)] == prefix
}

/*
fetch takes a conversation off `/mnt/web/clone`, writes the URL, and reads
the body to its end, then the status and the headers. It answers the body
with the kind its media type says. When `/mnt/web` is not mounted yet,
it is mounted here from `/srv/web`.
*/
fetch :: proc(url: string) -> (text: []u8, kind: Kind, ok: bool) {
	num: [16]u8
	n := read_small("/mnt/web/clone", num[:])
	if n <= 0 {
		_ = libuser.mount("/srv/web", "/mnt/web", 0)
		n = read_small("/mnt/web/clone", num[:])
		if n <= 0 {
			return nil, .Plain, false
		}
	}
	conv := string(num[:n])
	path: [128]u8
	line: [URL_MAX + 8]u8
	ctl := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/ctl"), abi.O_WRONLY)
	if ctl < 0 {
		return nil, .Plain, false
	}
	req := libuser.cat_into(line[:], "url ", url)
	wrote := libuser.write(int(ctl), transmute([]u8)req) == i64(len(req))
	_ = libuser.close(int(ctl))
	if !wrote {
		return nil, .Plain, false
	}
	body := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/body"), abi.O_RDONLY)
	if body < 0 {
		return nil, .Plain, false
	}
	text = make([]u8, MAX_BYTES)
	total := 0
	for total < len(text) {
		got := libuser.read(int(body), text[total:])
		if got <= 0 {
			break
		}
		total += int(got)
	}
	_ = libuser.close(int(body))
	// The media type, off the status line for gemini and the headers for http.
	ctype: [128]u8
	status: [128]u8
	sn := read_small(libuser.cat_into(path[:], "/mnt/web/", conv, "/status"), status[:])
	// A gemini status is two digits and the media type. An http one is
	// three digits and a reason, its media type in the headers.
	kind = .Plain
	if sn > 3 && status[2] == ' ' && is_digit(status[0]) && is_digit(status[1]) {
		kind = kind_of_type(string(status[3:sn]), url)
	} else {
		headers := make([]u8, 16384)
		defer delete(headers)
		hn := read_small(libuser.cat_into(path[:], "/mnt/web/", conv, "/headers"), headers[:])
		cn := header_value(string(headers[:max(hn, 0)]), "content-type", ctype[:])
		kind = kind_of_type(string(ctype[:cn]), url)
	}
	// The conversation is done with, and its slot goes back.
	if hctl := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/ctl"), abi.O_WRONLY); hctl >= 0 {
		_ = libuser.write(int(hctl), transmute([]u8)string("hangup"))
		_ = libuser.close(int(hctl))
	}
	return text[:total], kind, true
}

read_small :: proc "contextless" (path: string, into: []u8) -> int {
	fd := libuser.open(path, abi.O_RDONLY)
	if fd < 0 {
		return -1
	}
	total := 0
	for total < len(into) {
		n := libuser.read(int(fd), into[total:])
		if n <= 0 {
			break
		}
		total += int(n)
	}
	_ = libuser.close(int(fd))
	for total > 0 && (into[total - 1] == '\n' || into[total - 1] == '\r') {
		total -= 1
	}
	return total
}

// header_value copies a header's value, found without case, into `into`.
header_value :: proc "contextless" (headers: string, name: string, into: []u8) -> int {
	at := 0
	for at < len(headers) {
		eol := at
		for eol < len(headers) && headers[eol] != '\n' {
			eol += 1
		}
		line := headers[at:eol]
		at = eol + 1
		if len(line) <= len(name) || line[len(name)] != ':' {
			continue
		}
		same := true
		for i in 0 ..< len(name) {
			c := line[i]
			if c >= 'A' && c <= 'Z' {
				c += 'a' - 'A'
			}
			if c != name[i] {
				same = false
				break
			}
		}
		if !same {
			continue
		}
		v := line[len(name) + 1:]
		for len(v) > 0 && v[0] == ' ' {
			v = v[1:]
		}
		for len(v) > 0 && (v[len(v) - 1] == '\r' || v[len(v) - 1] == ' ') {
			v = v[:len(v) - 1]
		}
		return copy(into, v)
	}
	return 0
}
