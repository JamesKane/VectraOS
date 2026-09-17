/*
libdoc -- a page as blocks, and the rows it lays out to.

`docs/WEB.md` section 5's reader draws eight kinds of thing, and the first
four are documents: gemtext, markdown, HTML and plain text. Each parser turns
its bytes into the same shape, a `Doc` of `Block`s. One layout turns that
into rows of a width. The reader shows the rows, and a test counts them. So a parser
knows its format and nothing of the screen, and the screen knows rows and
nothing of a format. Gemtext's line types are the shape, because they are the
readable minimum every richer format reduces to. A heading with a level, a
paragraph, a link on its own line, a list item, a quote, preformatted text,
an image, a rule.

A `Doc` owns the text of its blocks in one buffer, so a parser may join
lines or strip markers and the source can go. Blocks and rows name their
text by offset, which survives the buffer growing. `layout` wraps each block
at a column count, with the prefix its kind wears (`# ` for a heading, `=> `
for a link, `* ` for an item, `> ` for a quote). The continuation rows are
indented under it. Preformatted text is cut at the width, never wrapped.
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
}

Block :: struct {
	kind:     Kind,
	level:    int,
	text_off: int,
	text_len: int,
	href_off: int,
	href_len: int,
}

Doc :: struct {
	buf:       [dynamic]u8,
	blocks:    [dynamic]Block,
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
	d.title_len = 0
}

doc_free :: proc(d: ^Doc) {
	context.allocator = libuser.allocator()
	delete(d.buf)
	delete(d.blocks)
	d^ = Doc{}
}

// doc_add appends a block, copying `text` and `href` into the document.
doc_add :: proc(d: ^Doc, kind: Kind, text: string, href: string = "", level: int = 0) {
	context.allocator = libuser.allocator()
	b := Block{kind = kind, level = level}
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

// prefix_of is what a block's first row begins with, and how many columns its
// continuation rows are indented by.
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
	case .Text, .Pre, .Rule:
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
		case .Text, .Heading, .Link, .Item, .Quote, .Image:
			wrap(l, i, prefix_of(b), text, cols)
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

