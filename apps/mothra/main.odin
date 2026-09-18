/*
mothra -- the reader, `docs/WEB.md` section 5.

`mothra URL` or `mothra file` shows a page in a window. Gemtext, markdown,
HTML or plain text is laid out by `sys/libdoc` to the window's columns.
The rows are shown one selected, each in the ink its kind wears. A PNG or
a JPEG on a page is fetched, decoded by `sys/libimage`, and stood on rows
of its own under its caption. One on its own is shown as a picture fitted
to the window.

A form's parts are rows too. Tab selects the next one, typing fills a
field, Space turns a check, and Return sends the form, as a query or as a
POST body through `webfs`. A press on a link's row follows it, and the
page it leads to takes the window. `b` goes back, `j` and `k` move a row,
`n` and `p` a page, `r` fetches again, `q` and Escape close.

A URL is fetched through `/mnt/web`, `servers/webfs`. So every scheme it
speaks is one this reads, and the page lands in the store on the way. A
file is read from the namespace, its kind by its suffix.

A press on a link is a plumb message, `docs/GHOST.md` section 5. The URL
goes to `/mnt/plumb/send`, and the rules route it to the `web` port. This
reader holds that port open, reads it back and opens it. So what a
press does is what `plumb URL` from a shell does, and a page any program
plumbs opens here. With no plumber the press follows the link itself.

A directory of messages, `sys/libmsg`'s shape, is a timeline: one row a
message with its time, its author and its first line, and a press opens
the message in place, since a message under a timeline is the timeline's
own to show. A message is a page of its own: subject, sender, date, the
body by its type, its links, and its replies as rows. A plain directory
is a listing. `messages.odin` builds these.

The column stands beside the page, a third of the width: what points at
the page. A message's column is what it answers, its replies, and the
network's `notify/` messages that answer it. A page's column is its
backlinks, from the `links` index this reader keeps: one line per link
it laid out, the page and the page it names, read backwards. A press in
the column opens on the left. `column.odin` is the column.

This is the reader's first cut. The toolkit's list is the page, so every
row wears one face.
*/
package mothra

import "base:runtime"

import "vsys:abi"
import "vsys:libdoc"
import "vsys:libgemtext"
import "vsys:libhtml"
import "vsys:libimage"
import "vsys:libmark"
import "vsys:libmsg"
import "vsys:libmui"
import "vsys:libplumb"
import "vsys:libthread"
import "vsys:libuser"

MAX_BYTES :: 1024 * 1024
MAX_ROWS :: 16384
MAX_PICS :: 16
MAX_FIELDS :: 32
FIELD_TEXT :: 256
URL_MAX :: 1024
HISTORY :: 32

ctx: runtime.Context
win: libmui.Window
page: ^libmui.Object
pic: ^libmui.Object
page_root: ^libmui.Object
pic_root: ^libmui.Object
showing_pic: bool
doc: libdoc.Doc
lay: libdoc.Layout
rows: []string
styles: []u8

// The pictures a page names, fetched and decoded, each standing on rows
// under its caption.
Pic :: struct {
	block: int,
	img:   libimage.Image,
}
pics: [MAX_PICS]Pic
npics: int
row_pics: [MAX_PICS]libmui.Row_Picture

// A form part's state: the block it is, what it holds now, and the row it
// sits on once laid out.
Field_State :: struct {
	block: int,
	row:   int,
	val:   [FIELD_TEXT]u8,
	n:     int,
	line:  [FIELD_TEXT + 64]u8, // The row's text as drawn
}
fields: [MAX_FIELDS]Field_State
nfields: int

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
	Picture, // PNG or JPEG, by libimage
	Directory, // A timeline, a message or a listing, by libmsg
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
	styles = make([]u8, MAX_ROWS)
	libdoc.doc_init(&doc)
	libdoc.layout_init(&lay)

	page = libmui.list(24)
	page.id = 1
	// Styled from the start, so the window prepares the styled inks' faces
	// when it opens, before the first page fills the styles in.
	page.styles = styles[:0]
	// The column beside the page, a third of the width: what points at it.
	col = libmui.list(24)
	col.id = 3
	col_rows = make([]string, MAX_COL)
	col_styles = make([]u8, MAX_COL)
	col.styles = col_styles[:0]
	page.weight = 2
	col.weight = 1
	page_root = libmui.group(true)
	libmui.add(page_root, page)
	libmui.add(page_root, col)
	pic = libmui.picture()
	pic.id = 2
	pic_root = libmui.group(false)
	libmui.add(pic_root, pic)
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
	if !libmui.window_open(&win, page_title(), showing_pic ? pic_root : page_root) {
		libthread.threadexitsall("open")
	}
	// Now the window has a width, the page is laid out to it.
	relayout()
	fill_column()
	libmui.window_paint(&win)
	// The plumber's web port, when there is a plumber: a page plumbed from
	// anywhere opens here.
	plumb_fd = libplumb.open_port("web")
	if plumb_fd >= 0 {
		_ = libthread.threadcreate(plumb_thread, nil)
	}
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
	// A picture stands on rows under its caption, as many as its height
	// takes once shrunk to the well's width.
	avail := max(cols * libmui.FONT_W - 2 * libmui.FONT_W, 1)
	for k in 0 ..< npics {
		p := &pics[k]
		dw := min(p.img.w, avail)
		dh := max(p.img.h * dw / p.img.w, 1)
		doc.blocks[p.block].tall = 1 + (dh + libmui.FONT_H - 1) / libmui.FONT_H
	}
	n := libdoc.layout(&lay, &doc, cols)
	n = libdoc.rows_as_strings(&lay, rows[:min(n, MAX_ROWS)])
	// Each row's style is its block's kind, and a picture's rows are its stand.
	np := 0
	for i in 0 ..< n {
		r := lay.rows[i]
		b := &doc.blocks[r.block]
		st := libmui.STYLE_PLAIN
		switch b.kind {
		case .Heading:
			st = libmui.STYLE_HEADING
		case .Link:
			st = libmui.STYLE_LINK
		case .Quote:
			st = libmui.STYLE_QUOTE
		case .Pre:
			st = libmui.STYLE_PRE
		case .Rule:
			st = libmui.STYLE_RULE
		case .Field, .Secret, .Check:
			st = libmui.STYLE_FIELD
			if r.first {
				if k := field_of(r.block); k >= 0 {
					fields[k].row = i
					rows[i] = render_field(k)
				}
			}
		case .Submit:
			st = libmui.STYLE_BUTTON
			if r.first {
				if k := field_of(r.block); k >= 0 {
					fields[k].row = i
					rows[i] = render_field(k)
				}
			}
		case .Hidden:
		case .Image:
			if !r.first {
				st = libmui.STYLE_PICTURE
			} else if b.tall > 1 && np < MAX_PICS {
				for k in 0 ..< npics {
					if pics[k].block == r.block {
						row_pics[np] = libmui.Row_Picture{row = i + 1, tall = b.tall - 1, pix = pics[k].img.pix, pw = pics[k].img.w, ph = pics[k].img.h}
						np += 1
						break
					}
				}
			}
		case .Text, .Item:
		}
		styles[i] = st
	}
	page.rows = rows[:n]
	page.styles = styles[:n]
	page.pics = row_pics[:np]
	page.top = 0
	page.sel = -1
}

// -- Forms ----------------------------------------------------------------------

// init_fields takes each form part's value off the page, for editing.
init_fields :: proc "contextless" () {
	nfields = 0
	for i in 0 ..< len(doc.blocks) {
		if !libdoc.is_form_part(doc.blocks[i].kind) || nfields >= MAX_FIELDS {
			continue
		}
		f := &fields[nfields]
		f.block = i
		f.row = -1
		f.n = copy(f.val[:], libdoc.block_value(&doc, i))
		nfields += 1
	}
}

field_of :: proc "contextless" (block: int) -> int {
	for k in 0 ..< nfields {
		if fields[k].block == block {
			return k
		}
	}
	return -1
}

// render_field is a part's row: its label and what it holds, a secret as
// stars, a check as its box, a button in brackets.
render_field :: proc "contextless" (k: int) -> string {
	f := &fields[k]
	b := &doc.blocks[f.block]
	label := libdoc.block_text(&doc, f.block)
	switch b.kind {
	case .Secret:
		stars: [FIELD_TEXT]u8
		for i in 0 ..< f.n {
			stars[i] = '*'
		}
		return libuser.cat_into(f.line[:], label, ": ", string(stars[:f.n]))
	case .Check:
		return libuser.cat_into(f.line[:], f.n > 0 ? "[x] " : "[ ] ", label)
	case .Submit:
		return libuser.cat_into(f.line[:], "[ ", label, " ]")
	case .Field, .Hidden, .Text, .Heading, .Link, .Item, .Quote, .Pre, .Image, .Rule:
		return libuser.cat_into(f.line[:], label, ": ", string(f.val[:f.n]))
	}
	return label
}

// refresh_field redraws a part's row after an edit.
refresh_field :: proc "contextless" (k: int) {
	if fields[k].row >= 0 && fields[k].row < len(page.rows) {
		rows[fields[k].row] = render_field(k)
	}
}

// field_at answers the part on a row, or -1.
field_at :: proc "contextless" (row: int) -> int {
	if row < 0 || row >= len(lay.rows) {
		return -1
	}
	return field_of(lay.rows[row].block)
}

// focus_next selects the next form part after `from`, wrapping, and
// scrolls it into view.
focus_next :: proc "contextless" (from: int) {
	n := len(page.rows)
	if n == 0 {
		return
	}
	for step in 1 ..= n {
		row := (from + step) % n
		if row < 0 {
			row += n
		}
		if field_at(row) >= 0 {
			page.sel = row
			visible := libmui.list_visible(page, &win.theme)
			if row < page.top || row >= page.top + visible {
				page.top = max(min(row, max(n - visible, 0)), 0)
			}
			return
		}
	}
}

// field_key gives a key to the selected part. Answers whether it took it.
field_key :: proc "contextless" (k: u8) -> bool {
	fk := field_at(page.sel)
	if fk < 0 {
		return false
	}
	f := &fields[fk]
	b := &doc.blocks[f.block]
	switch k {
	case '\n', '\r':
		submit(b.form)
		return true
	case libmui.KEY_ESCAPE:
		page.sel = -1
		return true
	}
	#partial switch b.kind {
	case .Field, .Secret:
		switch k {
		case 0x08, 0x7f:
			if f.n > 0 {
				f.n -= 1
			}
		case:
			if k >= 0x20 && k < 0x7f && f.n < FIELD_TEXT {
				f.val[f.n] = k
				f.n += 1
			} else {
				return false
			}
		}
	case .Check:
		if k != ' ' {
			return false
		}
		if f.n > 0 {
			f.n = 0
		} else {
			f.n = copy(f.val[:], "on")
		}
	case .Submit:
		if k != ' ' {
			return false
		}
		submit(b.form)
		return true
	}
	refresh_field(fk)
	return true
}

/*
submit sends a form. Its parts are encoded as a query, which a GET form
appends to its action and a POST form sends as its body. The action is
resolved against the page, and an empty one is the page itself.
*/
submit :: proc "contextless" (form: int) {
	context = ctx
	if form < 0 || form >= len(doc.forms) {
		return
	}
	values := make([]string, len(doc.blocks))
	defer delete(values)
	for i in 0 ..< len(doc.blocks) {
		values[i] = libdoc.block_value(&doc, i)
	}
	for k in 0 ..< nfields {
		values[fields[k].block] = string(fields[k].val[:fields[k].n])
	}
	body: [4096]u8
	n := libdoc.form_encode(&doc, form, values, body[:])
	if n < 0 {
		return
	}
	action := libdoc.form_action(&doc, form)
	target: [URL_MAX]u8
	tn := 0
	if len(action) == 0 {
		tn = copy(target[:], current[:current_len])
	} else {
		tn = resolve(action, target[:])
	}
	if tn <= 0 {
		return
	}
	if doc.forms[form].post {
		go(string(target[:tn]), true, body[:n])
		return
	}
	// A GET form: the query on the action, in place of any it had.
	for i in 0 ..< tn {
		if target[i] == '?' {
			tn = i
			break
		}
	}
	if tn + 1 + n > len(target) {
		return
	}
	target[tn] = '?'
	copy(target[tn + 1:], body[:n])
	go(string(target[:tn + 1 + n]), true)
}

// free_pics lets a page's pictures go, before the next page's.
free_pics :: proc "contextless" () {
	context = ctx
	for k in 0 ..< npics {
		libimage.image_free(&pics[k].img, context.allocator)
	}
	npics = 0
	page.pics = nil
}

/*
gather_pics fetches each picture a page names, through the same path as the
page, and keeps the ones that decode. A picture that is not a PNG, or is
not there, leaves its caption alone on the page. At most MAX_PICS, and each
within `sys/libimage`'s bound, which keeps a page's pictures inside the heap.
*/
gather_pics :: proc "contextless" () {
	context = ctx
	for i in 0 ..< len(doc.blocks) {
		if doc.blocks[i].kind != .Image || npics >= MAX_PICS {
			continue
		}
		href := libdoc.block_href(&doc, i)
		target: [URL_MAX]u8
		n := resolve(href, target[:])
		if n <= 0 {
			continue
		}
		t := string(target[:n])
		data: []u8
		ok: bool
		if has_scheme(t) {
			data, _, ok = fetch(t)
		} else {
			data, ok = libuser.read_file(t, context.allocator)
		}
		if !ok {
			continue
		}
		if libimage.is_png(data) || libimage.is_jpeg(data) {
			if img, dok := libimage.decode(data, context.allocator); dok {
				pics[npics] = Pic{block = i, img = img}
				npics += 1
			}
		}
		delete(data)
	}
}

// on_press follows the link a pressed row belongs to. Escape closes.
on_press :: proc "contextless" (w: ^libmui.Window, id: int) {
	context = ctx
	if id == -1 {
		w.done = true
		return
	}
	if id == 3 {
		column_press(w.arg)
		libmui.window_paint(w)
		return
	}
	if id != 1 || w.arg < 0 || w.arg >= len(lay.rows) {
		return
	}
	b := lay.rows[w.arg].block
	// A press on a check turns it, on a button sends its form, and on a
	// field selects it, which the list did already.
	if k := field_of(b); k >= 0 {
		#partial switch doc.blocks[b].kind {
		case .Check:
			_ = field_key(' ')
			libmui.window_paint(w)
		case .Submit:
			submit(doc.blocks[b].form)
			libmui.window_paint(w)
		}
		return
	}
	if doc.blocks[b].kind != .Link {
		return
	}
	href := libdoc.block_href(&doc, b)
	target: [URL_MAX]u8
	n := resolve(href, target[:])
	if n <= 0 {
		return
	}
	// A message under a timeline opens in place. Anything else goes through
	// the plumber when there is one and this reader is listening: the
	// message comes back on the web port, and plumb_thread opens it.
	if in_place && !has_scheme(href) {
		go(string(target[:n]), true)
		return
	}
	if plumb_fd >= 0 && libplumb.send_text("mothra", string(target[:n])) {
		return
	}
	go(string(target[:n]), true)
}

// in_place is set while the page is a directory's, whose own links are its
// to open rather than the plumber's.
in_place: bool

// plumb_fd is the web port, or -1 when there is no plumber.
plumb_fd: int = -1

// plumb_thread reads the web port and opens each page that arrives, until
// the plumber goes.
plumb_thread :: proc "contextless" (arg: rawptr) {
	_ = arg
	context = ctx
	io := libthread.ioproc()
	if io == nil {
		return
	}
	buf := make([]u8, libplumb.MAX)
	for {
		n := libthread.ioread(io, plumb_fd, buf)
		if n <= 0 {
			break
		}
		m, ok := libplumb.unpack(string(buf[:n]))
		if !ok || len(m.data) == 0 {
			continue
		}
		go(m.data, true)
		libmui.window_paint(&win)
	}
	_ = libuser.close(plumb_fd)
	plumb_fd = -1
	libthread.ioclose(io)
}

// on_key scrolls, goes back, fetches again, or closes.
on_key :: proc "contextless" (w: ^libmui.Window, k: u8) -> bool {
	context = ctx
	// A form part that is selected takes the key first. Tab goes to the
	// next part, from wherever the selection is.
	if !showing_pic {
		if k == '\t' {
			focus_next(page.sel)
			return true
		}
		if field_key(k) {
			return true
		}
	}
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
		fill_column()
	case 'q':
		w.done = true
	case:
		return false
	}
	return true
}

// go leaves the current page in the history and loads `target`, with a
// body to POST when a form sent one.
go :: proc "contextless" (target: string, remember: bool, post: []u8 = nil) {
	context = ctx
	if remember && history_n < HISTORY {
		history_len[history_n] = copy(history[history_n][:], current[:current_len])
		history_n += 1
	}
	saved: [URL_MAX]u8
	saved_n := copy(saved[:], target)
	current_len = copy(current[:], saved[:saved_n])
	if !load(string(current[:current_len]), post) {
		libuser.eprint("mothra: cannot read ", string(current[:current_len]), "\n")
	}
	// A picture and a page are two roots, and the window takes the one
	// the load filled.
	root := showing_pic ? pic_root : page_root
	if win.root != root {
		win.root = root
		if win.cw > 0 {
			libmui.window_relayout(&win)
		}
	}
	relayout()
	fill_column()
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
load :: proc "contextless" (target: string, post: []u8 = nil) -> bool {
	context = ctx
	text: []u8
	kind: Kind
	ok: bool
	if has_scheme(target) {
		text, kind, ok = fetch(target, post)
	} else if libmsg.path_is_dir(target) {
		kind, ok = .Directory, true
	} else {
		text, ok = libuser.read_file(target, context.allocator)
		kind = kind_of_suffix(target)
	}
	if !ok {
		return false
	}
	defer delete(text)
	free_pics()
	libdoc.doc_free(&doc)
	libdoc.doc_init(&doc)
	showing_pic = false
	in_place = kind == .Directory
	switch kind {
	case .Directory:
		if !load_dir(target) {
			return false
		}
	case .Picture:
		img, dok := libimage.decode(text, context.allocator)
		if !dok {
			libdoc.doc_add(&doc, .Text, "This picture could not be decoded.")
			return true
		}
		if pic.pix != nil {
			delete(pic.pix)
		}
		pic.pix, pic.pw, pic.ph = img.pix, img.w, img.h
		showing_pic = true
	case .Gemtext:
		libgemtext.parse(&doc, string(text))
	case .Markdown:
		libmark.parse(&doc, string(text))
	case .Html:
		libhtml.parse(&doc, string(text))
	case .Plain:
		parse_plain(&doc, string(text))
	}
	if !showing_pic {
		gather_pics()
		init_fields()
		if kind != .Directory {
			record_links()
		}
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
	if ends_with(path, ".png") || ends_with(path, ".jpg") || ends_with(path, ".jpeg") {
		return .Picture
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
	if starts_with(ctype, "image/png") || starts_with(ctype, "image/jpeg") {
		return .Picture
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
fetch :: proc(url: string, post: []u8 = nil) -> (text: []u8, kind: Kind, ok: bool) {
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
	if wrote && post != nil {
		// A form's body: the method, its type, and the bytes before the fetch.
		wrote = libuser.write(int(ctl), transmute([]u8)string("method POST")) > 0
		wrote = wrote && libuser.write(int(ctl), transmute([]u8)string("header Content-Type: application/x-www-form-urlencoded")) > 0
	}
	_ = libuser.close(int(ctl))
	if !wrote {
		return nil, .Plain, false
	}
	if post != nil {
		pb := libuser.open(libuser.cat_into(path[:], "/mnt/web/", conv, "/postbody"), abi.O_WRONLY)
		if pb < 0 {
			return nil, .Plain, false
		}
		wrote = libuser.write(int(pb), post) == i64(len(post))
		_ = libuser.close(int(pb))
		if !wrote {
			return nil, .Plain, false
		}
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
