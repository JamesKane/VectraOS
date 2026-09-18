/*
libdoc -- a page as blocks, and the rows it lays out to.

`docs/WEB.md` section 5's reader draws eight kinds of thing, and the first
four are documents: gemtext, markdown, HTML and plain text. Each parser turns
its bytes into the same shape, a `Doc` of `Block`s. One layout turns that
into rows of a width. The reader shows the rows, and a test counts them. So a
parser knows its format and nothing of the screen, and the screen knows rows
and nothing of a format.

Gemtext's line types are the shape, because they are the readable minimum
every richer format reduces to. A heading with a level, a paragraph, a link
on its own line, a list item, a quote, preformatted text, an image, a rule.

A `Doc` owns the text of its blocks in one buffer, so a parser may join
lines or strip markers and the source can go. Blocks and rows name their
text by offset, which survives the buffer growing. `layout` wraps each block
at a column count, behind the prefix its kind wears. `# ` for a heading,
`=> ` for a link, `* ` for an item, `> ` for a quote. The continuation rows
sit indented under it. Preformatted text is cut at the width, never wrapped.
*/
package libdoc

import "vsys:libuser"

Kind :: enum u8 {
	Text, // A paragraph, wrapped
	Heading, // `level` 1 to 3
	Link, // `text` shown, `href` followed
	Item, // One entry of a list
	Quote,
	Pre, // Lines kept as they are
	Image, // `text` the alt, `href` the source
	Rule,
	// A form's parts, `docs/WEB.md` section 5: `text` the label shown,
	// `href` the name sent, `value` what is sent, and `form` the form.
	Field, // Typed text
	Secret, // Typed text shown as stars
	Check, // On or off: sent when its value is not empty
	Hidden, // Sent, never shown
	Submit, // A button that sends the form
}

// A form: where its parts go, and how.
Form :: struct {
	action_off: int,
	action_len: int,
	post:       bool,
}

Block :: struct {
	kind:     Kind,
	level:    int,
	text_off: int,
	text_len: int,
	href_off: int,
	href_len: int,
	// The rows an image stands on, when the reader fetched it: its caption
	// row and the rows its pixels take. Zero lays the caption out alone.
	tall:     int,
	// A form part's form, or -1, and its value as the page gave it.
	form:      int,
	value_off: int,
	value_len: int,
}

Doc :: struct {
	buf:       [dynamic]u8,
	blocks:    [dynamic]Block,
	forms:     [dynamic]Form,
	title_off: int,
	title_len: int,
}

// A row of a laid-out document: its text in the layout's buffer, and the
// block it came from. `first` marks a block's first row, so a press on any
// row of a link finds the link.
Row :: struct {
	off:   int,
	len:   int,
	block: int,
	first: bool,
}

Layout :: struct {
	buf:  [dynamic]u8,
	rows: [dynamic]Row,
	doc:  ^Doc, // The document laid out last, for a row's block
}

// The widest a row may be asked to be, and the least.
MAX_COLS :: 512
MIN_COLS :: 8

doc_init :: proc(d: ^Doc) {
	context.allocator = libuser.allocator()
	d.buf = make([dynamic]u8, 0, 4096)
	d.blocks = make([dynamic]Block, 0, 64)
	d.forms = make([dynamic]Form, 0, 4)
	d.title_len = 0
}

doc_free :: proc(d: ^Doc) {
	context.allocator = libuser.allocator()
	delete(d.buf)
	delete(d.blocks)
	delete(d.forms)
	d^ = Doc{}
}

// doc_add appends a block, copying `text` and `href` into the document.
doc_add :: proc(d: ^Doc, kind: Kind, text: string, href: string = "", level: int = 0) {
	context.allocator = libuser.allocator()
	b := Block{kind = kind, level = level, form = -1}
	b.text_off = len(d.buf)
	append(&d.buf, ..transmute([]u8)text)
	b.text_len = len(text)
	b.href_off = len(d.buf)
	append(&d.buf, ..transmute([]u8)href)
	b.href_len = len(href)
	append(&d.blocks, b)
	// The first heading is the title.
	if kind == .Heading && d.title_len == 0 && len(text) > 0 {
		d.title_off = b.text_off
		d.title_len = b.text_len
	}
}

// doc_form adds a form and answers its index. `post` says its parts go as
// a body rather than a query.
doc_form :: proc(d: ^Doc, action: string, post: bool) -> int {
	context.allocator = libuser.allocator()
	f := Form{post = post}
	f.action_off = len(d.buf)
	append(&d.buf, ..transmute([]u8)action)
	f.action_len = len(action)
	append(&d.forms, f)
	return len(d.forms) - 1
}

// doc_field adds a form part: its label as the text, its name as the href,
// its value, and the form it belongs to.
doc_field :: proc(d: ^Doc, kind: Kind, label: string, name: string, value: string, form: int) {
	context.allocator = libuser.allocator()
	doc_add(d, kind, label, name)
	b := &d.blocks[len(d.blocks) - 1]
	b.form = form
	b.value_off = len(d.buf)
	append(&d.buf, ..transmute([]u8)value)
	b.value_len = len(value)
}

block_value :: proc "contextless" (d: ^Doc, i: int) -> string #no_bounds_check {
	b := &d.blocks[i]
	return string(d.buf[b.value_off:][:b.value_len])
}

form_action :: proc "contextless" (d: ^Doc, f: int) -> string #no_bounds_check {
	if f < 0 || f >= len(d.forms) {
		return ""
	}
	fm := &d.forms[f]
	return string(d.buf[fm.action_off:][:fm.action_len])
}

// is_form_part says whether a kind is a form's.
is_form_part :: proc "contextless" (k: Kind) -> bool {
	return k == .Field || k == .Secret || k == .Check || k == .Hidden || k == .Submit
}

/*
form_encode writes a form's parts as `name=value&name=value` into `into`,
each escaped the way a URL's query is. Answers the length, or -1 when it
does not fit. `values[i]` is what block i sends. A check whose value is
empty is left out, and a part with no name is left out too.
*/
form_encode :: proc "contextless" (d: ^Doc, form: int, values: []string, into: []u8) -> int {
	at := 0
	first := true
	for i in 0 ..< len(d.blocks) {
		b := &d.blocks[i]
		if b.form != form || !is_form_part(b.kind) || b.href_len == 0 {
			continue
		}
		value := i < len(values) ? values[i] : block_value(d, i)
		if b.kind == .Check && len(value) == 0 {
			continue
		}
		if !first {
			if at >= len(into) {
				return -1
			}
			into[at] = '&'
			at += 1
		}
		first = false
		at = url_encode(into, at, block_href(d, i))
		if at < 0 || at >= len(into) {
			return -1
		}
		into[at] = '='
		at += 1
		at = url_encode(into, at, value)
		if at < 0 {
			return -1
		}
	}
	return at
}

// url_encode appends `s` to `into` at `at`, a space as `+` and anything
// but a letter, a digit or `-_.~` as `%XX`. Answers the new offset, or -1.
url_encode :: proc "contextless" (into: []u8, at: int, s: string) -> int {
	hex := "0123456789ABCDEF"
	at := at
	for i in 0 ..< len(s) {
		c := s[i]
		switch {
		case (c >= 'a' && c <= 'z') || (c >= 'A' && c <= 'Z') || (c >= '0' && c <= '9') || c == '-' || c == '_' || c == '.' || c == '~':
			if at >= len(into) {
				return -1
			}
			into[at] = c
			at += 1
		case c == ' ':
			if at >= len(into) {
				return -1
			}
			into[at] = '+'
			at += 1
		case:
			if at + 3 > len(into) {
				return -1
			}
			into[at] = '%'
			into[at + 1] = hex[c >> 4]
			into[at + 2] = hex[c & 15]
			at += 3
		}
	}
	return at
}

// doc_title sets the title outright, for a format that names its page apart
// from its headings, HTML's `<title>`. A heading added later does not replace
// it.
doc_title :: proc(d: ^Doc, text: string) {
	context.allocator = libuser.allocator()
	d.title_off = len(d.buf)
	append(&d.buf, ..transmute([]u8)text)
	d.title_len = len(text)
}

block_text :: proc "contextless" (d: ^Doc, i: int) -> string #no_bounds_check {
	b := &d.blocks[i]
	return string(d.buf[b.text_off:][:b.text_len])
}

block_href :: proc "contextless" (d: ^Doc, i: int) -> string #no_bounds_check {
	b := &d.blocks[i]
	return string(d.buf[b.href_off:][:b.href_len])
}

title :: proc "contextless" (d: ^Doc) -> string #no_bounds_check {
	return string(d.buf[d.title_off:][:d.title_len])
}

// -- Layout ---------------------------------------------------------------------

layout_init :: proc(l: ^Layout) {
	context.allocator = libuser.allocator()
	l.buf = make([dynamic]u8, 0, 8192)
	l.rows = make([dynamic]Row, 0, 256)
}

layout_free :: proc(l: ^Layout) {
	context.allocator = libuser.allocator()
	delete(l.buf)
	delete(l.rows)
	l^ = Layout{}
}

row_text :: proc "contextless" (l: ^Layout, i: int) -> string #no_bounds_check {
	r := &l.rows[i]
	return string(l.buf[r.off:][:r.len])
}

// prefix_of is what a block's first row begins with. Its width is the indent
// of the continuation rows.
prefix_of :: proc "contextless" (b: ^Block) -> string {
	switch b.kind {
	case .Heading:
		switch b.level {
		case 1:
			return "# "
		case 2:
			return "## "
		case:
			return "### "
		}
	case .Link:
		return "=> "
	case .Item:
		return "* "
	case .Quote:
		return "> "
	case .Image:
		return "[image] "
	case .Text, .Pre, .Rule, .Field, .Secret, .Check, .Hidden, .Submit:
		return ""
	}
	return ""
}

/*
layout lays every block out to rows of at most `cols` columns, clearing what
was there. A paragraph breaks at spaces, and a word wider than the row is cut.
A preformatted block is one row per line, cut at the width. A rule is a row
of dashes. Answers the row count. A column count outside the bounds is
clamped, so a narrow window still lays out rather than loops.
*/
layout :: proc(l: ^Layout, d: ^Doc, cols_in: int) -> int {
	context.allocator = libuser.allocator()
	clear(&l.buf)
	clear(&l.rows)
	l.doc = d
	cols := clamp(cols_in, MIN_COLS, MAX_COLS)
	for i in 0 ..< len(d.blocks) {
		b := &d.blocks[i]
		text := block_text(d, i)
		switch b.kind {
		case .Rule:
			put_row(l, i, true, "", "", cols)
		case .Pre:
			first := true
			at := 0
			for at <= len(text) {
				end := at
				for end < len(text) && text[end] != '\n' {
					end += 1
				}
				line := text[at:end]
				if len(line) > cols {
					line = line[:cols]
				}
				put_row(l, i, first, "", line, cols)
				first = false
				at = end + 1
				if end == len(text) {
					break
				}
			}
		case .Hidden:
			// Sent with its form, never shown.
		case .Text, .Heading, .Link, .Item, .Quote, .Image, .Field, .Secret, .Check, .Submit:
			before := len(l.rows)
			wrap(l, i, prefix_of(b), text, cols)
			// An image with pixels stands on rows of its own under its caption.
			for len(l.rows) - before < b.tall {
				put_row(l, i, false, "", "", cols)
			}
		}
	}
	return len(l.rows)
}

// wrap breaks `text` into rows at spaces, the first row behind `prefix` and
// the rest indented as wide as the prefix. An empty text is one empty row.
wrap :: proc(l: ^Layout, block: int, prefix: string, text: string, cols: int) {
	width := max(cols - len(prefix), 1)
	at := 0
	first := true
	for {
		// Skip the spaces a break left behind.
		for at < len(text) && text[at] == ' ' {
			at += 1
		}
		rest := text[at:]
		if len(rest) <= width {
			put_row(l, block, first, prefix, rest, cols)
			return
		}
		// The last space within the width, or a cut if there is none.
		cut := -1
		for j := width; j > 0; j -= 1 {
			if rest[j] == ' ' {
				cut = j
				break
			}
		}
		if cut <= 0 {
			cut = width
		}
		put_row(l, block, first, prefix, rest[:cut], cols)
		at += cut
		first = false
	}
}

// put_row appends one row: the prefix on a block's first row, spaces as wide
// as it on the rest, then the text. A rule's row is dashes across the width.
put_row :: proc(l: ^Layout, block: int, first: bool, prefix: string, text: string, cols: int) {
	r := Row{off = len(l.buf), block = block, first = first}
	if len(prefix) > 0 {
		if first {
			append(&l.buf, ..transmute([]u8)prefix)
		} else {
			for _ in 0 ..< len(prefix) {
				append(&l.buf, ' ')
			}
		}
	}
	if block >= 0 && len(text) == 0 && len(prefix) == 0 && rule_at(l, block) {
		for _ in 0 ..< cols {
			append(&l.buf, '-')
		}
	} else {
		append(&l.buf, ..transmute([]u8)text)
	}
	r.len = len(l.buf) - r.off
	append(&l.rows, r)
}

// rule_at says whether a block index names a rule. layout keeps the document
// it lays out here so put_row can ask.
rule_at :: proc "contextless" (l: ^Layout, block: int) -> bool {
	return l.doc != nil && block < len(l.doc.blocks) && l.doc.blocks[block].kind == .Rule
}

// rows_as_strings fills `into` with each row's text, for a list that shows
// them, and answers how many fit.
rows_as_strings :: proc "contextless" (l: ^Layout, into: []string) -> int {
	n := min(len(into), len(l.rows))
	for i in 0 ..< n {
		into[i] = row_text(l, i)
	}
	return n
}

